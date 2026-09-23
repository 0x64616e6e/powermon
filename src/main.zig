//! powermon - minimal power monitor with a built-in time series store.
const std = @import("std");
const sys = @import("sys.zig");
const db = @import("db.zig");
const report = @import("report.zig");
const Sampler = @import("sampler.zig").Sampler;
const rapl_names = @import("sampler.zig").rapl_names;
const out = sys.out;

const DEFAULT_DB = "/var/lib/powermon/power.db";
const DEFAULT_PID = "/run/powermon/pid";

const usage =
    \\usage: powermon <command> [options]
    \\
    \\  record              sample every --interval seconds, store in --db (run as a service)
    \\  now                 take one 1-second sample and print it
    \\  stats               min / p50 / mean / p95 / max per metric, energy, drain by profile
    \\  plot [metric...]    terminal chart (default: bat); metrics listed below
    \\  svg [metric...]     SVG chart to stdout (default: bat psys pkg cpu temp)
    \\  csv                 export samples as CSV for other tools
    \\  info                database and recorder status
    \\
    \\options:
    \\  --db PATH           database (default /var/lib/powermon/power.db)
    \\  --since DUR         start of range: 90s 30m 6h 2d 1w, or "all" (stats 24h, plot 6h, svg 24h, csv all)
    \\  --until DUR         end of range, as time ago (default now)
    \\  --interval SEC      record: seconds between samples (default 5)
    \\  --flush N           record: samples buffered in memory between writes (default 60)
    \\  --width N --height N   plot size (default terminal width x 12)
    \\  --no-flush          query without asking the recorder to write its buffer first
    \\
    \\metrics:
    \\
;

const Opts = struct {
    db_path: []const u8 = DEFAULT_DB,
    pid_path: []const u8 = DEFAULT_PID,
    since_ms: ?i64 = null, // null = command default, maxInt = all
    until_ms: i64 = 0,
    interval_s: u32 = 5,
    flush_n: u32 = 60,
    width: ?usize = null,
    height: usize = 12,
    no_flush: bool = false,
    pos: [16][]const u8 = undefined,
    npos: usize = 0,
};

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    defer sys.flush();
    if (argv.len < 2) {
        printUsage();
        return 2;
    }
    const cmd = std.mem.span(argv[1]);
    var o = Opts{};
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        const val = struct {
            fn get(v: []const [*:0]const u8, idx: *usize, name: []const u8) ?[]const u8 {
                idx.* += 1;
                if (idx.* >= v.len) {
                    sys.err("powermon: {s} needs a value\n", .{name});
                    return null;
                }
                return std.mem.span(v[idx.*]);
            }
        }.get;
        if (std.mem.eql(u8, a, "--db")) {
            o.db_path = val(argv, &i, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--since")) {
            const v = val(argv, &i, a) orelse return 2;
            o.since_ms = if (std.mem.eql(u8, v, "all")) std.math.maxInt(i64) else parseDur(v) orelse return badArg(a, v);
        } else if (std.mem.eql(u8, a, "--until")) {
            const v = val(argv, &i, a) orelse return 2;
            o.until_ms = parseDur(v) orelse return badArg(a, v);
        } else if (std.mem.eql(u8, a, "--interval")) {
            const v = val(argv, &i, a) orelse return 2;
            o.interval_s = std.fmt.parseInt(u32, v, 10) catch return badArg(a, v);
            if (o.interval_s == 0) return badArg(a, v);
        } else if (std.mem.eql(u8, a, "--flush")) {
            const v = val(argv, &i, a) orelse return 2;
            o.flush_n = std.fmt.parseInt(u32, v, 10) catch return badArg(a, v);
            if (o.flush_n == 0 or o.flush_n > 100_000) return badArg(a, v);
        } else if (std.mem.eql(u8, a, "--width")) {
            const v = val(argv, &i, a) orelse return 2;
            o.width = std.fmt.parseInt(usize, v, 10) catch return badArg(a, v);
        } else if (std.mem.eql(u8, a, "--height")) {
            const v = val(argv, &i, a) orelse return 2;
            o.height = std.math.clamp(std.fmt.parseInt(usize, v, 10) catch return badArg(a, v), 2, 100);
        } else if (std.mem.eql(u8, a, "--no-flush")) {
            o.no_flush = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            return 0;
        } else if (a.len > 0 and a[0] == '-') {
            sys.err("powermon: unknown option {s}\n", .{a});
            return 2;
        } else if (o.npos < o.pos.len) {
            o.pos[o.npos] = a;
            o.npos += 1;
        }
    }
    report.initTime();

    if (std.mem.eql(u8, cmd, "record")) return record(&o);
    if (std.mem.eql(u8, cmd, "now")) return now();
    if (std.mem.eql(u8, cmd, "stats")) return query(&o, .stats);
    if (std.mem.eql(u8, cmd, "plot")) return query(&o, .plot);
    if (std.mem.eql(u8, cmd, "svg")) return query(&o, .svg);
    if (std.mem.eql(u8, cmd, "csv")) return query(&o, .csv);
    if (std.mem.eql(u8, cmd, "info")) return info(&o);
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        printUsage();
        return 0;
    }
    sys.err("powermon: unknown command {s}\n", .{cmd});
    return 2;
}

fn printUsage() void {
    sys.outRaw(usage);
    for (&report.metrics) |*m| out("  {s:<8} {s:<4} {s}\n", .{ m.name, m.unit, m.desc });
}

fn badArg(name: []const u8, v: []const u8) u8 {
    sys.err("powermon: bad value for {s}: {s}\n", .{ name, v });
    return 2;
}

/// "90s" "30m" "6h" "2d" "1w" -> milliseconds
fn parseDur(s: []const u8) ?i64 {
    if (s.len < 2) return null;
    const n = std.fmt.parseInt(i64, s[0 .. s.len - 1], 10) catch return null;
    const unit: i64 = switch (s[s.len - 1]) {
        's' => 1000,
        'm' => 60_000,
        'h' => 3_600_000,
        'd' => 86_400_000,
        'w' => 7 * 86_400_000,
        else => return null,
    };
    return n * unit;
}

// ---- record ----
fn record(o: *const Opts) u8 {
    const interval_ns: i64 = @as(i64, o.interval_s) * std.time.ns_per_s;
    const w = db.Writer.open(o.db_path, o.interval_s * 1000) catch |e| {
        sys.err("powermon: cannot open {s}: {s} (errno {d})\n", .{ o.db_path, @errorName(e), sys.last_errno });
        return 1;
    };
    writePid(o.pid_path);
    const mask = sys.sigmask(&.{ sys.SIGTERM, sys.SIGINT, sys.SIGHUP, sys.SIGUSR1 });
    sys.blockSignals(mask);

    var s = Sampler.init();
    for (s.rapl_fd, 0..) |fd, i| if (fd < 0) sys.err("powermon: RAPL {s} unavailable (errno {d}; needs CAP_PERFMON)\n", .{ rapl_names[i], s.rapl_err[i] });
    _ = s.sample(interval_ns * 3); // prime the deltas; not stored

    const buf = std.heap.page_allocator.alloc(db.Record, o.flush_n) catch return 1;
    var n: usize = 0;
    sys.err("powermon: recording to {s} every {d} s, writing every {d} samples\n", .{ o.db_path, o.interval_s, o.flush_n });

    var next = sys.nowNs(sys.CLOCK_BOOTTIME) + interval_ns;
    while (true) {
        const t = sys.nowNs(sys.CLOCK_BOOTTIME);
        if (t < next) {
            switch (sys.waitSignal(mask, next - t)) {
                0 => {},
                sys.SIGUSR1 => {
                    flushBuf(w, buf, &n);
                    continue;
                },
                else => {
                    flushBuf(w, buf, &n);
                    sys.err("powermon: stopped\n", .{});
                    return 0;
                },
            }
            continue;
        }
        buf[n] = s.sample(interval_ns * 3);
        n += 1;
        if (n == buf.len) flushBuf(w, buf, &n);
        next += interval_ns;
        if (next < t) next = t + interval_ns; // woke from suspend or fell behind: realign
    }
}

fn flushBuf(w: db.Writer, buf: []db.Record, n: *usize) void {
    w.append(buf[0..n.*]) catch sys.err("powermon: write failed (errno {d}); dropping {d} samples\n", .{ sys.last_errno, n.* });
    n.* = 0;
}

fn writePid(path: []const u8) void {
    const fd = sys.openPath(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 0o644) catch return;
    defer sys.close(fd);
    var b: [16]u8 = undefined;
    sys.writeAll(fd, std.fmt.bufPrint(&b, "{d}\n", .{sys.getpid()}) catch return) catch {};
}

/// Ask a running recorder to write its in-memory buffer so queries see the latest samples.
fn requestFlush(path: []const u8) bool {
    const fd = sys.openPath(path, sys.O_RDONLY, 0) catch return false;
    var b: [16]u8 = undefined;
    const n = sys.pread(fd, &b, 0) catch 0;
    sys.close(fd);
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, b[0..n], " \n"), 10) catch return false;
    sys.kill(pid, sys.SIGUSR1) catch return false;
    sys.sleepNs(150 * std.time.ns_per_ms);
    return true;
}

// ---- now ----
fn now() u8 {
    var s = Sampler.init();
    _ = s.sample(std.math.maxInt(i64));
    sys.sleepNs(std.time.ns_per_s);
    const r = s.sample(std.math.maxInt(i64));
    for (&report.metrics) |*m| {
        if (m.get(&r)) |v| out("{s:<7} {d:>9.2} {s:<4} {s}\n", .{ m.name, v, m.unit, m.desc }) else out("{s:<7} {s:>9} {s:<4} {s}\n", .{ m.name, "n/a", m.unit, m.desc });
    }
    const st = [_][]const u8{ "unknown", "discharging", "charging", "not charging", "full" };
    const pr = [_][]const u8{ "unknown", "low-power", "balanced", "performance" };
    out("status  {s}, profile {s}\n", .{ st[@min(r.status, 4)], pr[@min(r.profile, 3)] });
    for (s.rapl_fd, 0..) |fd, i| if (fd < 0) out("note: RAPL {s} unavailable (errno {d}); run with CAP_PERFMON or as root\n", .{ rapl_names[i], s.rapl_err[i] });
    return 0;
}

// ---- queries ----
const Kind = enum { stats, plot, svg, csv };

fn query(o: *const Opts, kind: Kind) u8 {
    if (!o.no_flush) _ = requestFlush(o.pid_path);
    const rd = db.Reader.open(o.db_path) catch |e| {
        sys.err("powermon: cannot read {s}: {s} (errno {d})\n", .{ o.db_path, @errorName(e), sys.last_errno });
        return 1;
    };
    const t = @divTrunc(sys.nowNs(sys.CLOCK_REALTIME), std.time.ns_per_ms);
    const default_since: i64 = switch (kind) {
        .stats => 86_400_000,
        .plot => 6 * 3_600_000,
        .svg => 86_400_000,
        .csv => std.math.maxInt(i64),
    };
    const since = o.since_ms orelse default_since;
    const from = if (since == std.math.maxInt(i64)) std.math.minInt(i64) else t - since;
    const recs = rd.range(from, t - o.until_ms + 1);
    switch (kind) {
        .stats => report.stats(recs, rd.header.interval_ms),
        .csv => report.csv(recs),
        .plot => {
            const width = o.width orelse (sys.termWidth() orelse 100);
            if (o.npos == 0) report.plot(recs, report.findMetric("bat").?, width, o.height, rd.header.interval_ms);
            for (o.pos[0..o.npos], 0..) |name, k| {
                const m = report.findMetric(name) orelse {
                    sys.err("powermon: unknown metric {s}\n", .{name});
                    return 2;
                };
                if (k > 0) sys.outRaw("\n");
                report.plot(recs, m, width, o.height, rd.header.interval_ms);
            }
        },
        .svg => {
            for (o.pos[0..o.npos]) |name| if (report.findMetric(name) == null) {
                sys.err("powermon: unknown metric {s}\n", .{name});
                return 2;
            };
            const def = [_][]const u8{ "bat", "psys", "pkg", "cpu", "temp" };
            report.svg(recs, if (o.npos > 0) o.pos[0..o.npos] else &def, rd.header.interval_ms);
        },
    }
    return 0;
}

fn info(o: *const Opts) u8 {
    const flushed = !o.no_flush and requestFlush(o.pid_path);
    const rd = db.Reader.open(o.db_path) catch |e| {
        sys.err("powermon: cannot read {s}: {s} (errno {d})\n", .{ o.db_path, @errorName(e), sys.last_errno });
        return 1;
    };
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    out("database   {s}\n", .{o.db_path});
    out("size       {d:.2} MiB, {d} samples of {d} bytes, interval {d} s\n", .{ @as(f64, @floatFromInt(rd.size)) / 1048576.0, rd.recs.len, @sizeOf(db.Record), rd.header.interval_ms / 1000 });
    out("created    {s}\n", .{report.fmtTime(&b1, rd.header.created_ms)});
    if (rd.recs.len > 0) {
        const f = rd.recs[0].ts_ms;
        const l = rd.recs[rd.recs.len - 1].ts_ms;
        out("range      {s} .. {s} ({s})\n", .{ report.fmtTime(&b1, f), report.fmtTime(&b2, l), report.fmtDur(&b3, l - f) });
        const per_day = 86_400.0 / (@as(f64, @floatFromInt(rd.header.interval_ms)) / 1000.0) * @sizeOf(db.Record);
        out("growth     {d:.2} MiB/day\n", .{per_day / 1048576.0});
    }
    out("recorder   {s}\n", .{if (flushed) "running (buffer flushed)" else "not reachable (no pidfile or not running)"});
    return 0;
}
