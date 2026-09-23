//! Thin Linux syscall layer. The app talks to the kernel directly so that the sampling path is a
//! handful of pread()/read() calls on descriptors opened once, and no std I/O machinery.
const std = @import("std");
const linux = std.os.linux;

pub var last_errno: u16 = 0;

pub fn check(rc: usize) error{Sys}!usize {
    const s: isize = @bitCast(rc);
    if (s < 0 and s > -4096) {
        last_errno = @intCast(-s);
        return error.Sys;
    }
    return rc;
}

pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_CREAT: u32 = 0o100;
pub const O_TRUNC: u32 = 0o1000;
pub const O_APPEND: u32 = 0o2000;
pub const O_CLOEXEC: u32 = 0o2000000;

const AT_FDCWD: isize = -100;

pub fn open(path: [*:0]const u8, flags: u32, mode: u32) !i32 {
    const rc = linux.syscall4(.openat, @bitCast(AT_FDCWD), @intFromPtr(path), flags | O_CLOEXEC, mode);
    return @intCast(try check(rc));
}

/// open() with a runtime path (copied into a NUL-terminated stack buffer).
pub fn openPath(path: []const u8, flags: u32, mode: u32) !i32 {
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return error.Sys;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return open(@ptrCast(&buf), flags, mode);
}

pub fn close(fd: i32) void {
    _ = linux.syscall1(.close, @bitCast(@as(isize, fd)));
}

pub fn pread(fd: i32, buf: []u8, off: u64) !usize {
    return check(linux.syscall4(.pread64, @bitCast(@as(isize, fd)), @intFromPtr(buf.ptr), buf.len, off));
}

pub fn read(fd: i32, buf: []u8) !usize {
    return check(linux.syscall3(.read, @bitCast(@as(isize, fd)), @intFromPtr(buf.ptr), buf.len));
}

pub fn writeAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = try check(linux.syscall3(.write, @bitCast(@as(isize, fd)), @intFromPtr(data.ptr + off), data.len - off));
        if (n == 0) return error.Sys;
        off += n;
    }
}

pub fn fsync(fd: i32) void {
    _ = linux.syscall1(.fsync, @bitCast(@as(isize, fd)));
}

pub fn fileSize(fd: i32) !u64 {
    return check(linux.syscall3(.lseek, @bitCast(@as(isize, fd)), 0, 2));
}

pub fn mmapRead(fd: i32, len: usize) ![*]const u8 {
    const rc = try check(linux.syscall6(.mmap, 0, len, 1, 2, @bitCast(@as(isize, fd)), 0)); // PROT_READ, MAP_PRIVATE
    return @ptrFromInt(rc);
}

pub const Timespec = extern struct { sec: i64, nsec: i64 };
pub const CLOCK_REALTIME: usize = 0;
pub const CLOCK_BOOTTIME: usize = 7;

pub fn nowNs(clock: usize) i64 {
    var ts: Timespec = undefined;
    _ = linux.syscall2(.clock_gettime, clock, @intFromPtr(&ts));
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

pub fn sleepNs(ns: i64) void {
    var ts = Timespec{ .sec = @divTrunc(ns, std.time.ns_per_s), .nsec = @mod(ns, std.time.ns_per_s) };
    _ = linux.syscall2(.nanosleep, @intFromPtr(&ts), 0);
}

pub fn getpid() i32 {
    return @intCast(linux.syscall0(.getpid));
}

pub fn kill(pid: i32, sig: u6) !void {
    _ = try check(linux.syscall2(.kill, @bitCast(@as(isize, pid)), sig));
}

pub const SIGHUP: u6 = 1;
pub const SIGINT: u6 = 2;
pub const SIGUSR1: u6 = 10;
pub const SIGTERM: u6 = 15;

pub fn sigmask(sigs: []const u6) u64 {
    var m: u64 = 0;
    for (sigs) |s| m |= @as(u64, 1) << (s - 1);
    return m;
}

pub fn blockSignals(mask: u64) void {
    var m = mask;
    _ = linux.syscall4(.rt_sigprocmask, 0, @intFromPtr(&m), 0, 8); // SIG_BLOCK
}

/// Sleep up to `ns`, returning early with the signal number if one in `mask` arrives (0 = timeout).
pub fn waitSignal(mask: u64, ns: i64) u6 {
    var m = mask;
    var ts = Timespec{ .sec = @divTrunc(ns, std.time.ns_per_s), .nsec = @mod(ns, std.time.ns_per_s) };
    const rc = linux.syscall4(.rt_sigtimedwait, @intFromPtr(&m), 0, @intFromPtr(&ts), 8);
    const s: isize = @bitCast(rc);
    if (s <= 0) return 0;
    return @intCast(s);
}

pub const PerfAttr = extern struct {
    type: u32,
    size: u32 = 64, // PERF_ATTR_SIZE_VER0
    config: u64,
    rest: [48]u8 = [_]u8{0} ** 48,
};

pub fn perfEventOpen(attr: *PerfAttr, pid: i32, cpu: i32) !i32 {
    const rc = linux.syscall5(.perf_event_open, @intFromPtr(attr), @bitCast(@as(isize, pid)), @bitCast(@as(isize, cpu)), @bitCast(@as(isize, -1)), 8); // PERF_FLAG_FD_CLOEXEC
    return @intCast(try check(rc));
}

pub fn termWidth() ?u16 {
    var ws: [4]u16 = undefined;
    const rc = linux.syscall3(.ioctl, 1, 0x5413, @intFromPtr(&ws)); // TIOCGWINSZ on stdout
    const s: isize = @bitCast(rc);
    if (s < 0 or ws[1] == 0) return null;
    return ws[1];
}

// ---- buffered stdout / stderr ----
var out_buf: [1 << 16]u8 = undefined;
var out_len: usize = 0;

pub fn out(comptime fmt: []const u8, args: anytype) void {
    var tmp: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch tmp[0..];
    outRaw(s);
}

pub fn outRaw(s: []const u8) void {
    if (out_len + s.len > out_buf.len) flush();
    if (s.len > out_buf.len) {
        writeAll(1, s) catch {};
        return;
    }
    @memcpy(out_buf[out_len..][0..s.len], s);
    out_len += s.len;
}

pub fn flush() void {
    writeAll(1, out_buf[0..out_len]) catch {};
    out_len = 0;
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    var tmp: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch tmp[0..];
    writeAll(2, s) catch {};
}

// ---- privilege drop ----
pub fn setgroupsEmpty() !void {
    _ = try check(linux.syscall2(.setgroups, 0, 0));
}
pub fn setresgid(g: u32) !void {
    _ = try check(linux.syscall3(.setresgid, g, g, g));
}
pub fn setresuid(u: u32) !void {
    _ = try check(linux.syscall3(.setresuid, u, u, u));
}
pub fn getuid() u32 {
    return @intCast(linux.syscall0(.getuid));
}
/// Effective capability set of this process (first 32 bits suffice for the check).
pub fn capEffective() u64 {
    const Hdr = extern struct { version: u32 = 0x20080522, pid: i32 = 0 };
    const Data = extern struct { effective: u32, permitted: u32, inheritable: u32 };
    var h = Hdr{};
    var d: [2]Data = undefined;
    _ = linux.syscall2(.capget, @intFromPtr(&h), @intFromPtr(&d));
    return @as(u64, d[0].effective) | (@as(u64, d[1].effective) << 32);
}

// ---- event waiting: signalfd + FIFO under ppoll ----
pub fn signalfd(mask: u64) !i32 {
    var m = mask;
    return @intCast(try check(linux.syscall4(.signalfd4, @bitCast(@as(isize, -1)), @intFromPtr(&m), 8, O_CLOEXEC | 0o4000))); // SFD_NONBLOCK
}

pub const PollFd = extern struct { fd: i32, events: i16 = 1, revents: i16 = 0 }; // POLLIN

/// Wait up to `ns` for input on any of `fds`; returns the number ready (0 = timeout).
pub fn ppoll(fds: []PollFd, ns: i64) usize {
    var ts = Timespec{ .sec = @divTrunc(ns, std.time.ns_per_s), .nsec = @mod(ns, std.time.ns_per_s) };
    const rc = linux.syscall5(.ppoll, @intFromPtr(fds.ptr), fds.len, @intFromPtr(&ts), 0, 8);
    const s: isize = @bitCast(rc);
    return if (s < 0) 0 else @intCast(s);
}

/// Create (or recreate) a FIFO at `path` with exact `mode`, and hold it open read-write so
/// writers never block and the recorder never sees EOF.
pub fn fifo(path: [*:0]const u8, mode: u32) !i32 {
    _ = linux.syscall3(.unlinkat, @bitCast(AT_FDCWD), @intFromPtr(path), 0);
    _ = try check(linux.syscall4(.mknodat, @bitCast(AT_FDCWD), @intFromPtr(path), 0o010000 | mode, 0)); // S_IFIFO
    const fd = try open(path, O_RDWR | 0o4000, 0); // O_NONBLOCK
    _ = linux.syscall2(.fchmod, @bitCast(@as(isize, fd)), mode); // umask-proof
    return fd;
}

pub fn pwrite(fd: i32, data: []const u8, off: u64) !void {
    _ = try check(linux.syscall4(.pwrite64, @bitCast(@as(isize, fd)), @intFromPtr(data.ptr), data.len, off));
}
