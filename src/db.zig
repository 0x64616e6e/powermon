//! On-disk time series: a 64-byte header followed by fixed 48-byte little-endian records in time
//! order. Append-only; readers mmap the file and binary-search on the timestamp.
const std = @import("std");
const sys = @import("sys.zig");

pub const NA32: u32 = 0xFFFF_FFFF;
pub const NA16: u16 = 0xFFFF;
pub const NA_TEMP: i16 = std.math.minInt(i16);
pub const NA8: u8 = 0xFF;

pub const Status = enum(u8) { unknown = 0, discharging = 1, charging = 2, not_charging = 3, full = 4 };
pub const Profile = enum(u8) { unknown = 0, low_power = 1, balanced = 2, performance = 3 };

pub const FLAG_GAP: u8 = 1; // first sample after start or resume: deltas span a long gap

pub const Record = extern struct {
    ts_ms: i64, // unix time, milliseconds
    bat_mw: u32, // battery power_now (charge or discharge, see status)
    bat_mwh: u32, // battery energy_now
    pkg_mw: u32, // RAPL package, mean over the interval
    cores_mw: u32, // RAPL cores
    gpu_mw: u32, // RAPL integrated GPU
    psys_mw: u32, // RAPL psys: whole platform (SoC + memory + ...)
    temp_dc: i16, // CPU package temperature, 0.1 °C
    fan_rpm: u16,
    cpu_pm: u16, // CPU busy, per mille over the interval
    bat_pct: u8,
    status: u8, // Status
    ac: u8, // 1 on mains
    profile: u8, // Profile (ACPI platform profile)
    bright_pct: u8, // backlight
    flags: u8,
    reserved: [4]u8 = .{ 0, 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(Record) == 48);
    std.debug.assert(@sizeOf(Header) == 64);
}

pub const MAGIC = "PWRMON\x00\x01".*;

pub const Header = extern struct {
    magic: [8]u8 = MAGIC,
    version: u32 = 1,
    rec_size: u32 = @sizeOf(Record),
    interval_ms: u32,
    _pad: u32 = 0,
    created_ms: i64,
    reserved: [32]u8 = [_]u8{0} ** 32,
};

pub const Writer = struct {
    fd: i32,

    /// Open for appending, creating the file with a header if it is new or empty.
    pub fn open(path: []const u8, interval_ms: u32) !Writer {
        const fd = try sys.openPath(path, sys.O_RDWR | sys.O_CREAT | sys.O_APPEND, 0o644);
        const size = try sys.fileSize(fd);
        if (size == 0) {
            const h = Header{ .interval_ms = interval_ms, .created_ms = @divTrunc(sys.nowNs(sys.CLOCK_REALTIME), std.time.ns_per_ms) };
            try sys.writeAll(fd, std.mem.asBytes(&h));
            sys.fsync(fd);
        } else {
            var h: Header = undefined;
            const n = try sys.pread(fd, std.mem.asBytes(&h), 0);
            if (n != @sizeOf(Header) or !std.mem.eql(u8, &h.magic, &MAGIC) or h.rec_size != @sizeOf(Record)) return error.BadDatabase;
            // A torn write from a crash would leave a partial record; refuse rather than misalign.
            if ((size - @sizeOf(Header)) % @sizeOf(Record) != 0) return error.TornDatabase;
        }
        return .{ .fd = fd };
    }

    pub fn append(self: Writer, recs: []const Record) !void {
        if (recs.len == 0) return;
        try sys.writeAll(self.fd, std.mem.sliceAsBytes(recs));
        sys.fsync(self.fd);
    }
};

pub const Reader = struct {
    header: *const Header,
    recs: []const Record,
    size: u64,

    pub fn open(path: []const u8) !Reader {
        const fd = try sys.openPath(path, sys.O_RDONLY, 0);
        defer sys.close(fd);
        const size = try sys.fileSize(fd);
        if (size < @sizeOf(Header)) return error.BadDatabase;
        const base = try sys.mmapRead(fd, size);
        const h: *const Header = @ptrCast(@alignCast(base));
        if (!std.mem.eql(u8, &h.magic, &MAGIC) or h.rec_size != @sizeOf(Record)) return error.BadDatabase;
        const n = (size - @sizeOf(Header)) / @sizeOf(Record);
        const p: [*]const Record = @ptrCast(@alignCast(base + @sizeOf(Header)));
        return .{ .header = h, .recs = p[0..n], .size = size };
    }

    /// Records with from_ms <= ts_ms < to_ms.
    pub fn range(self: Reader, from_ms: i64, to_ms: i64) []const Record {
        const a = lowerBound(self.recs, from_ms);
        const b = lowerBound(self.recs, to_ms);
        return self.recs[a..@max(a, b)];
    }
};

fn lowerBound(recs: []const Record, ts: i64) usize {
    var lo: usize = 0;
    var hi: usize = recs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (recs[mid].ts_ms < ts) lo = mid + 1 else hi = mid;
    }
    return lo;
}
