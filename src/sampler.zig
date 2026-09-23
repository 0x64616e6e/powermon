//! Metric collection. Every source is opened once in init(); a sample is then a few pread()s on
//! sysfs/procfs attributes (served from kernel memory, never the disk) plus one read() per RAPL
//! perf counter. No path lookups, no allocation, no file system traffic per sample.
const std = @import("std");
const sys = @import("sys.zig");
const db = @import("db.zig");

// Machine-specific names (ThinkPad T14 Gen 6); a missing source just records "n/a".
const BAT = "/sys/class/power_supply/BAT0/";
const AC = "/sys/class/power_supply/AC/online";
const BACKLIGHT = "/sys/class/backlight/intel_backlight/";
const PROFILE = "/sys/firmware/acpi/platform_profile";
const RAPL_PMU = "/sys/bus/event_source/devices/power/";
pub const rapl_names = [_][]const u8{ "pkg", "cores", "gpu", "psys" };

pub const Sampler = struct {
    bat_power: i32 = -1,
    bat_energy: i32 = -1,
    bat_cap: i32 = -1,
    bat_status: i32 = -1,
    ac: i32 = -1,
    temp: i32 = -1,
    fan: i32 = -1,
    bright: i32 = -1,
    bright_max: u64 = 0,
    profile: i32 = -1,
    stat: i32 = -1,
    rapl_fd: [4]i32 = .{ -1, -1, -1, -1 },
    rapl_scale: [4]f64 = .{ 0, 0, 0, 0 },
    rapl_err: [4]u16 = .{ 0, 0, 0, 0 },

    prev_ns: i64 = 0,
    prev_rapl: [4]u64 = .{ 0, 0, 0, 0 },
    prev_busy: u64 = 0,
    prev_total: u64 = 0,
    primed: bool = false,

    pub fn init() Sampler {
        var s = Sampler{};
        s.bat_power = openRo(BAT ++ "power_now");
        s.bat_energy = openRo(BAT ++ "energy_now");
        s.bat_cap = openRo(BAT ++ "capacity");
        s.bat_status = openRo(BAT ++ "status");
        s.ac = openRo(AC);
        s.profile = openRo(PROFILE);
        s.stat = openRo("/proc/stat");
        s.bright = openRo(BACKLIGHT ++ "brightness");
        const bm = openRo(BACKLIGHT ++ "max_brightness");
        if (bm >= 0) {
            s.bright_max = readUint(bm) orelse 0;
            sys.close(bm);
        }
        s.temp = hwmonAttr("coretemp", "temp1_input"); // temp1 = "Package id 0"
        s.fan = hwmonAttr("thinkpad", "fan1_input");
        s.openRapl();
        return s;
    }

    fn openRapl(self: *Sampler) void {
        const tfd = openRo(RAPL_PMU ++ "type");
        if (tfd < 0) return;
        const pmu_type = readUint(tfd) orelse return;
        sys.close(tfd);
        var cpu: i32 = 0;
        const cfd = openRo(RAPL_PMU ++ "cpumask");
        if (cfd >= 0) {
            cpu = @intCast(readUint(cfd) orelse 0);
            sys.close(cfd);
        }
        inline for (rapl_names, 0..) |name, i| {
            const ev = openRo(RAPL_PMU ++ "events/energy-" ++ name);
            const sc = openRo(RAPL_PMU ++ "events/energy-" ++ name ++ ".scale");
            if (ev >= 0 and sc >= 0) blk: {
                var b1: [64]u8 = undefined;
                var b2: [64]u8 = undefined;
                const evs = readText(ev, &b1) orelse break :blk; // "event=0x02"
                const eq = std.mem.indexOfScalar(u8, evs, '=') orelse break :blk;
                const hex = std.mem.trim(u8, evs[eq + 1 ..], " \n");
                const config = std.fmt.parseInt(u64, if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex, 16) catch break :blk;
                const scale = std.fmt.parseFloat(f64, readText(sc, &b2) orelse break :blk) catch break :blk;
                var attr = sys.PerfAttr{ .type = @intCast(pmu_type), .config = config };
                if (sys.perfEventOpen(&attr, -1, cpu)) |fd| {
                    self.rapl_fd[i] = fd;
                    self.rapl_scale[i] = scale;
                } else |_| self.rapl_err[i] = sys.last_errno;
            }
            if (ev >= 0) sys.close(ev);
            if (sc >= 0) sys.close(sc);
        }
    }

    /// Take a sample. Values that need a previous reading (RAPL power, CPU busy) are n/a on the
    /// first call; samples spanning more than `gap_ns` (suspend) are flagged.
    pub fn sample(self: *Sampler, gap_ns: i64) db.Record {
        const now = sys.nowNs(sys.CLOCK_BOOTTIME);
        var r = db.Record{
            .ts_ms = @divTrunc(sys.nowNs(sys.CLOCK_REALTIME), std.time.ns_per_ms),
            .bat_mw = if (readInt(self.bat_power)) |v| @intCast(@divTrunc(@max(v, 0), 1000)) else db.NA32,
            .bat_mwh = if (readInt(self.bat_energy)) |v| @intCast(@divTrunc(@max(v, 0), 1000)) else db.NA32,
            .pkg_mw = db.NA32,
            .cores_mw = db.NA32,
            .gpu_mw = db.NA32,
            .psys_mw = db.NA32,
            .temp_dc = if (readInt(self.temp)) |v| @intCast(@divTrunc(v, 100)) else db.NA_TEMP,
            .fan_rpm = if (readInt(self.fan)) |v| @intCast(@min(@max(v, 0), 0xFFFE)) else db.NA16,
            .cpu_pm = db.NA16,
            .bat_pct = if (readInt(self.bat_cap)) |v| @intCast(@min(@max(v, 0), 100)) else db.NA8,
            .status = @intFromEnum(self.readStatus()),
            .ac = if (readInt(self.ac)) |v| @intCast(@min(@max(v, 0), 1)) else db.NA8,
            .profile = @intFromEnum(self.readProfile()),
            .bright_pct = db.NA8,
            .flags = 0,
        };
        if (self.bright_max > 0) {
            if (readUint(self.bright)) |v| r.bright_pct = @intCast(@min(v * 100 / self.bright_max, 100));
        }

        var rapl: [4]u64 = .{ 0, 0, 0, 0 };
        for (self.rapl_fd, 0..) |fd, i| {
            if (fd < 0) continue;
            var v: u64 = 0;
            if ((sys.read(fd, std.mem.asBytes(&v)) catch 0) == 8) rapl[i] = v;
        }
        const busy_total = self.readCpu();

        if (self.primed) {
            const dt = now - self.prev_ns;
            if (dt > gap_ns) r.flags |= db.FLAG_GAP;
            const secs = @as(f64, @floatFromInt(dt)) / 1e9;
            const outs = [4]*u32{ &r.pkg_mw, &r.cores_mw, &r.gpu_mw, &r.psys_mw };
            for (self.rapl_fd, 0..) |fd, i| {
                if (fd < 0 or rapl[i] < self.prev_rapl[i] or secs <= 0) continue;
                const joules = @as(f64, @floatFromInt(rapl[i] - self.prev_rapl[i])) * self.rapl_scale[i];
                outs[i].* = @intFromFloat(@min(joules / secs * 1000.0, 4.0e9));
            }
            if (busy_total) |bt| {
                const db_ = bt[0] -% self.prev_busy;
                const dtot = bt[1] -% self.prev_total;
                if (dtot > 0 and bt[1] >= self.prev_total) r.cpu_pm = @intCast(@min(db_ * 1000 / dtot, 1000));
            }
        } else r.flags |= db.FLAG_GAP;

        self.prev_ns = now;
        self.prev_rapl = rapl;
        if (busy_total) |bt| {
            self.prev_busy = bt[0];
            self.prev_total = bt[1];
        }
        self.primed = true;
        return r;
    }

    fn readStatus(self: *Sampler) db.Status {
        var b: [32]u8 = undefined;
        const t = readText(self.bat_status, &b) orelse return .unknown;
        if (std.mem.eql(u8, t, "Discharging")) return .discharging;
        if (std.mem.eql(u8, t, "Charging")) return .charging;
        if (std.mem.eql(u8, t, "Not charging")) return .not_charging;
        if (std.mem.eql(u8, t, "Full")) return .full;
        return .unknown;
    }

    fn readProfile(self: *Sampler) db.Profile {
        var b: [32]u8 = undefined;
        const t = readText(self.profile, &b) orelse return .unknown;
        if (std.mem.eql(u8, t, "low-power")) return .low_power;
        if (std.mem.eql(u8, t, "balanced")) return .balanced;
        if (std.mem.eql(u8, t, "performance")) return .performance;
        return .unknown;
    }

    /// {busy, total} jiffies from the aggregate "cpu" line of /proc/stat.
    fn readCpu(self: *Sampler) ?[2]u64 {
        if (self.stat < 0) return null;
        var b: [256]u8 = undefined;
        const n = sys.pread(self.stat, &b, 0) catch return null;
        const line_end = std.mem.indexOfScalar(u8, b[0..n], '\n') orelse n;
        var it = std.mem.tokenizeScalar(u8, b[0..line_end], ' ');
        _ = it.next(); // "cpu"
        var total: u64 = 0;
        var idle: u64 = 0;
        var i: usize = 0;
        while (it.next()) |tok| : (i += 1) {
            if (i >= 8) break; // user nice system idle iowait irq softirq steal
            const v = std.fmt.parseInt(u64, tok, 10) catch 0;
            total += v;
            if (i == 3 or i == 4) idle += v;
        }
        return .{ total - idle, total };
    }
};

fn openRo(path: [*:0]const u8) i32 {
    return sys.open(path, sys.O_RDONLY, 0) catch -1;
}

fn hwmonAttr(name: []const u8, attr: []const u8) i32 {
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var p: [96]u8 = undefined;
        const np = std.fmt.bufPrint(&p, "/sys/class/hwmon/hwmon{d}/name", .{i}) catch return -1;
        const fd = sys.openPath(np, sys.O_RDONLY, 0) catch continue;
        var b: [32]u8 = undefined;
        const got = readText(fd, &b);
        sys.close(fd);
        if (got) |g| if (std.mem.eql(u8, g, name)) {
            const ap = std.fmt.bufPrint(&p, "/sys/class/hwmon/hwmon{d}/{s}", .{ i, attr }) catch return -1;
            return sys.openPath(ap, sys.O_RDONLY, 0) catch -1;
        };
    }
    return -1;
}

fn readText(fd: i32, buf: []u8) ?[]const u8 {
    if (fd < 0) return null;
    const n = sys.pread(fd, buf, 0) catch return null;
    return std.mem.trim(u8, buf[0..n], " \n\t");
}

fn readInt(fd: i32) ?i64 {
    var b: [32]u8 = undefined;
    const t = readText(fd, &b) orelse return null;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

fn readUint(fd: i32) ?u64 {
    var b: [32]u8 = undefined;
    const t = readText(fd, &b) orelse return null;
    return std.fmt.parseInt(u64, t, 10) catch null;
}
