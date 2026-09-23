//! Queries over the stored series: statistics, terminal charts, SVG and CSV export.
const std = @import("std");
const sys = @import("sys.zig");
const db = @import("db.zig");
const out = sys.out;

pub const Metric = struct {
    name: []const u8,
    unit: []const u8,
    desc: []const u8,
    get: *const fn (*const db.Record) ?f64,
};

fn mw(v: u32) ?f64 {
    return if (v == db.NA32) null else @as(f64, @floatFromInt(v)) / 1000.0;
}
fn getBat(r: *const db.Record) ?f64 {
    const w = mw(r.bat_mw) orelse return null;
    return switch (@as(db.Status, @enumFromInt(r.status))) {
        .charging => -w,
        else => w,
    };
}
fn getPsys(r: *const db.Record) ?f64 {
    return mw(r.psys_mw);
}
fn getPkg(r: *const db.Record) ?f64 {
    return mw(r.pkg_mw);
}
fn getCores(r: *const db.Record) ?f64 {
    return mw(r.cores_mw);
}
fn getGpu(r: *const db.Record) ?f64 {
    return mw(r.gpu_mw);
}
fn getCpu(r: *const db.Record) ?f64 {
    return if (r.cpu_pm == db.NA16) null else @as(f64, @floatFromInt(r.cpu_pm)) / 10.0;
}
fn getTemp(r: *const db.Record) ?f64 {
    return if (r.temp_dc == db.NA_TEMP) null else @as(f64, @floatFromInt(r.temp_dc)) / 10.0;
}
fn getFan(r: *const db.Record) ?f64 {
    return if (r.fan_rpm == db.NA16) null else @floatFromInt(r.fan_rpm);
}
fn getPct(r: *const db.Record) ?f64 {
    return if (r.bat_pct == db.NA8) null else @floatFromInt(r.bat_pct);
}
fn getBright(r: *const db.Record) ?f64 {
    return if (r.bright_pct == db.NA8) null else @floatFromInt(r.bright_pct);
}
fn getWh(r: *const db.Record) ?f64 {
    return mw(r.bat_mwh);
}

pub const metrics = [_]Metric{
    .{ .name = "bat", .unit = "W", .desc = "battery power (+ discharging, - charging)", .get = getBat },
    .{ .name = "psys", .unit = "W", .desc = "RAPL platform (SoC, memory, ...)", .get = getPsys },
    .{ .name = "pkg", .unit = "W", .desc = "RAPL CPU package", .get = getPkg },
    .{ .name = "cores", .unit = "W", .desc = "RAPL CPU cores", .get = getCores },
    .{ .name = "gpu", .unit = "W", .desc = "RAPL integrated GPU", .get = getGpu },
    .{ .name = "cpu", .unit = "%", .desc = "CPU busy", .get = getCpu },
    .{ .name = "temp", .unit = "C", .desc = "CPU package temperature", .get = getTemp },
    .{ .name = "fan", .unit = "rpm", .desc = "fan speed", .get = getFan },
    .{ .name = "pct", .unit = "%", .desc = "battery charge", .get = getPct },
    .{ .name = "wh", .unit = "Wh", .desc = "battery energy remaining", .get = getWh },
    .{ .name = "bright", .unit = "%", .desc = "backlight", .get = getBright },
};

pub fn findMetric(name: []const u8) ?*const Metric {
    for (&metrics) |*m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

// ---- time formatting (local time through libc) ----
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const i64, tm: *Tm) ?*Tm;
extern "c" fn tzset() void;

pub fn fmtTime(buf: []u8, ms: i64) []const u8 {
    const t: i64 = @divFloor(ms, 1000);
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return "?";
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.mday)), @as(u32, @intCast(tm.hour)), @as(u32, @intCast(tm.min)),
    }) catch "?";
}

pub fn fmtDur(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(@max(ms, 0), 1000);
    const d = @divTrunc(s, 86400);
    const h = @divTrunc(@mod(s, 86400), 3600);
    const m = @divTrunc(@mod(s, 3600), 60);
    if (d > 0) return std.fmt.bufPrint(buf, "{d}d {d}h {d}m", .{ d, h, m }) catch "?";
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch "?";
    return std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, @mod(s, 60) }) catch "?";
}

pub fn initTime() void {
    tzset();
}

// ---- statistics ----
pub fn stats(recs: []const db.Record, interval_ms: u32, width: usize) void {
    const wide = width >= 100; // room for the description column
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    if (recs.len == 0) {
        out("no samples in range\n", .{});
        return;
    }
    const first = recs[0].ts_ms;
    const last = recs[recs.len - 1].ts_ms;
    out("{s} .. {s}   {s}, {d} samples every {d} s\n\n", .{ fmtTime(&b1, first), fmtTime(&b2, last), fmtDur(&b3, last - first), recs.len, interval_ms / 1000 });

    const vals = std.heap.page_allocator.alloc(f64, recs.len) catch return;
    defer std.heap.page_allocator.free(vals);
    out("{s:<7} {s:<4} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{ "metric", "unit", "min", "p50", "mean", "p95", "max" });
    for (&metrics) |*m| {
        var n: usize = 0;
        var sum: f64 = 0;
        for (recs) |*r| if (m.get(r)) |v| {
            vals[n] = v;
            n += 1;
            sum += v;
        };
        if (n == 0) continue;
        const s = vals[0..n];
        std.mem.sort(f64, s, {}, std.sort.asc(f64));
        out("{s:<7} {s:<4} {d:>8.2} {d:>8.2} {d:>8.2} {d:>8.2} {d:>8.2}", .{ m.name, m.unit, s[0], pct(s, 0.5), sum / @as(f64, @floatFromInt(n)), pct(s, 0.95), s[n - 1] });
        if (wide) out("   {s}\n", .{m.desc}) else sys.outRaw("\n");
    }

    // energy: integrate each sample over the interval it closes; skip gaps (suspend, recorder down)
    const max_dt: i64 = @as(i64, interval_ms) * 3;
    var t_bat: i64 = 0;
    var t_ac: i64 = 0;
    var e_dis: f64 = 0;
    var e_chg: f64 = 0;
    var e_psys: f64 = 0;
    var e_pkg: f64 = 0;
    var t_psys: i64 = 0;
    var prof_t = [_]i64{0} ** 4;
    var prof_e = [_]f64{0} ** 4;
    var i: usize = 1;
    while (i < recs.len) : (i += 1) {
        const r = &recs[i];
        const dt = r.ts_ms - recs[i - 1].ts_ms;
        if (dt <= 0 or dt > max_dt or r.flags & db.FLAG_GAP != 0) continue;
        const h = @as(f64, @floatFromInt(dt)) / 3.6e6;
        const st: db.Status = @enumFromInt(r.status);
        if (st == .discharging) {
            t_bat += dt;
            if (mw(r.bat_mw)) |w| {
                e_dis += w * h;
                const p = @min(r.profile, 3);
                prof_t[p] += dt;
                prof_e[p] += w * h;
            }
        } else t_ac += dt;
        if (st == .charging) if (mw(r.bat_mw)) |w| {
            e_chg += w * h;
        };
        if (mw(r.psys_mw)) |w| {
            e_psys += w * h;
            t_psys += dt;
        }
        if (mw(r.pkg_mw)) |w| e_pkg += w * h;
    }
    out("\nenergy\n", .{});
    out("  on battery      {s:<12} {d:>7.2} Wh drawn", .{ fmtDur(&b1, t_bat), e_dis });
    if (t_bat > 0) {
        const mean = e_dis / (@as(f64, @floatFromInt(t_bat)) / 3.6e6);
        out(", mean {d:.2} W", .{mean});
        if (batteryFullWh()) |full| if (mean > 0) {
            if (wide) out(", {d:.1} h per full charge ({d:.1} Wh)", .{ full / mean, full }) else out("\n                  {d:.1} h per full charge ({d:.1} Wh)", .{ full / mean, full });
        };
    }
    out("\n  on AC           {s:<12} {d:>7.2} Wh charged\n", .{ fmtDur(&b1, t_ac), e_chg });
    if (t_psys > 0) out("  platform (psys) {s:<12} {d:>7.2} Wh, CPU package {d:.2} Wh\n", .{ fmtDur(&b1, t_psys), e_psys, e_pkg });
    if (t_bat > 0) {
        out("\nbattery drain by platform profile\n", .{});
        const names = [_][]const u8{ "unknown", "low-power", "balanced", "performance" };
        for (prof_t, 0..) |t, p| if (t > 0) {
            out("  {s:<12} {s:<12} mean {d:.2} W\n", .{ names[p], fmtDur(&b1, t), prof_e[p] / (@as(f64, @floatFromInt(t)) / 3.6e6) });
        };
    }
}

fn pct(sorted: []const f64, q: f64) f64 {
    const idx = q * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(idx));
    const hi = @min(lo + 1, sorted.len - 1);
    const f = idx - @floor(idx);
    return sorted[lo] * (1 - f) + sorted[hi] * f;
}

fn batteryFullWh() ?f64 {
    const fd = sys.open("/sys/class/power_supply/BAT0/energy_full", sys.O_RDONLY, 0) catch return null;
    defer sys.close(fd);
    var b: [32]u8 = undefined;
    const n = sys.pread(fd, &b, 0) catch return null;
    const v = std.fmt.parseInt(u64, std.mem.trim(u8, b[0..n], " \n"), 10) catch return null;
    return @as(f64, @floatFromInt(v)) / 1e6;
}

// ---- bucketing shared by plot and svg ----
const Bucket = struct { sum: f64 = 0, n: u32 = 0 };

fn bucketize(recs: []const db.Record, m: *const Metric, from: i64, to: i64, out_b: []Bucket) void {
    for (out_b) |*b| b.* = .{};
    const span: f64 = @floatFromInt(@max(to - from, 1));
    for (recs) |*r| if (m.get(r)) |v| {
        const x = @as(f64, @floatFromInt(r.ts_ms - from)) / span * @as(f64, @floatFromInt(out_b.len));
        const idx: usize = @intFromFloat(@min(@max(x, 0), @as(f64, @floatFromInt(out_b.len - 1))));
        out_b[idx].sum += v;
        out_b[idx].n += 1;
    };
}

/// Columns narrower than the sampling interval come out empty; bridge them with the value to the
/// left when the neighbouring samples are no more than `max_gap_ms` apart. Real gaps stay blank.
fn fillGaps(bk: []Bucket, bucket_ms: f64, max_gap_ms: f64) void {
    var last: ?usize = null;
    for (bk, 0..) |b, j| {
        if (b.n == 0) continue;
        if (last) |li| if (j > li + 1 and @as(f64, @floatFromInt(j - li)) * bucket_ms <= max_gap_ms) {
            const v = bk[li].sum / @as(f64, @floatFromInt(bk[li].n));
            for (bk[li + 1 .. j]) |*e| e.* = .{ .sum = v, .n = 1 };
        };
        last = j;
    }
}

// ---- terminal chart ----
pub fn plot(recs: []const db.Record, m: *const Metric, width: usize, height: usize, interval_ms: u32) void {
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    if (recs.len == 0) {
        out("{s}: no samples in range\n", .{m.name});
        return;
    }
    const cols = @max(width, 20) - 9;
    var buckets: [1024]Bucket = undefined;
    const bk = buckets[0..@min(cols, buckets.len)];
    const from = recs[0].ts_ms;
    const to = recs[recs.len - 1].ts_ms + 1;
    bucketize(recs, m, from, to, bk);
    fillGaps(bk, @as(f64, @floatFromInt(to - from)) / @as(f64, @floatFromInt(bk.len)), @as(f64, @floatFromInt(interval_ms)) * 3);
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    for (bk) |b| if (b.n > 0) {
        const v = b.sum / @as(f64, @floatFromInt(b.n));
        lo = @min(lo, v);
        hi = @max(hi, v);
    };
    if (lo == std.math.inf(f64)) {
        out("{s}: no values in range\n", .{m.name});
        return;
    }
    // Bars grow from a baseline: zero when the range allows it (power, percent), else the minimum
    // (temperature). With mixed signs zero sits on a row boundary: positive bars rise from it with
    // lower-eighth blocks, negative bars hang from it with upper blocks.
    if (m.unit[0] != 'C') {
        if (lo > 0) lo = 0;
        if (hi < 0) hi = 0;
    }
    if (hi - lo < 1e-9) hi = lo + 1;
    var neg_rows: usize = 0;
    if (lo < 0 and hi > 0) {
        const want = @as(f64, @floatFromInt(height)) * (-lo) / (hi - lo);
        neg_rows = std.math.clamp(@as(usize, @intFromFloat(@round(want))), 1, height - 1);
        const per_row = @max(hi / @as(f64, @floatFromInt(height - neg_rows)), -lo / @as(f64, @floatFromInt(neg_rows)));
        hi = per_row * @as(f64, @floatFromInt(height - neg_rows));
        lo = -per_row * @as(f64, @floatFromInt(neg_rows));
    } else if (hi <= 0 and lo < 0) neg_rows = height;
    const base: f64 = if (lo < 0) 0 else lo;
    const row_h = (hi - lo) / @as(f64, @floatFromInt(height));
    out("{s} ({s}) - {s}\n", .{ m.name, m.unit, m.desc });
    const lower = [_][]const u8{ " ", "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}" };
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const cell_top = hi - @as(f64, @floatFromInt(row)) * row_h;
        const cell_bot = cell_top - row_h;
        const zero_row = neg_rows > 0 and neg_rows < height and row == height - neg_rows; // first row below zero
        if (row == 0) out("{d:>7.1} \u{2502}", .{hi}) else if (row == height - 1) out("{d:>7.1} \u{2502}", .{lo}) else if (zero_row) out("{d:>7.1} \u{2502}", .{@as(f64, 0)}) else if (neg_rows == 0 and row == height / 2) out("{d:>7.1} \u{2502}", .{(hi + lo) / 2}) else out("        \u{2502}", .{});
        for (bk) |b| {
            if (b.n == 0) {
                sys.outRaw(" ");
                continue;
            }
            const v = b.sum / @as(f64, @floatFromInt(b.n));
            if (v >= base) {
                // rising bar [base, v]: covers this cell from its bottom if the cell is above base
                if (cell_bot < base - 1e-9 or v <= cell_bot) {
                    sys.outRaw(" ");
                    continue;
                }
                const f = std.math.clamp((v - cell_bot) / row_h, 0, 1);
                sys.outRaw(lower[@intFromFloat(@round(f * 8))]);
            } else {
                // hanging bar [v, base]: covers this cell from its top if the cell is below base
                if (cell_top > base + 1e-9 or v >= cell_top) {
                    sys.outRaw(" ");
                    continue;
                }
                const f = std.math.clamp((cell_top - v) / row_h, 0, 1);
                sys.outRaw(if (f >= 0.875) "\u{2588}" else if (f >= 0.375) "\u{2580}" else if (f >= 0.125) "\u{2594}" else " ");
            }
        }
        sys.outRaw("\n");
    }
    out("        \u{2514}", .{});
    for (bk) |_| sys.outRaw("\u{2500}");
    const l = fmtTime(&b1, from);
    const r = fmtTime(&b2, to);
    out("\n         {s}", .{l});
    var pad = @as(isize, @intCast(bk.len)) - @as(isize, @intCast(l.len + r.len));
    while (pad > 0) : (pad -= 1) sys.outRaw(" ");
    out("{s}\n", .{r});
}

// ---- SVG ----
pub fn svg(recs: []const db.Record, names: []const []const u8, interval_ms: u32) void {
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const W: usize = 1000;
    const PH: usize = 140;
    const ML: usize = 70;
    const MR: usize = 20;
    const plot_w = W - ML - MR;
    const n_panels = names.len;
    const H = 40 + n_panels * (PH + 30) + 18; // bottom margin for the time labels
    out("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" font-family=\"IBM Plex Mono, monospace\" font-size=\"11\">\n", .{ W, H });
    out("<rect width=\"100%\" height=\"100%\" fill=\"#0B0C0E\"/>\n", .{});
    if (recs.len == 0) {
        out("<text x=\"20\" y=\"30\" fill=\"#A39C89\">no samples in range</text></svg>\n", .{});
        return;
    }
    const from = recs[0].ts_ms;
    const to = recs[recs.len - 1].ts_ms + 1;
    out("<text x=\"{d}\" y=\"24\" fill=\"#E8DFC9\" font-size=\"13\">powermon  {s} .. {s}</text>\n", .{ ML, fmtTime(&b1, from), fmtTime(&b2, to) });
    var buckets: [1024]Bucket = undefined;
    const bk = buckets[0..plot_w];
    for (names, 0..) |name, pi| {
        const m = findMetric(name) orelse continue;
        bucketize(recs, m, from, to, bk);
        fillGaps(bk, @as(f64, @floatFromInt(to - from)) / @as(f64, @floatFromInt(bk.len)), @as(f64, @floatFromInt(interval_ms)) * 3);
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (bk) |b| if (b.n > 0) {
            const v = b.sum / @as(f64, @floatFromInt(b.n));
            lo = @min(lo, v);
            hi = @max(hi, v);
        };
        const y0 = 40 + pi * (PH + 30);
        out("<text x=\"{d}\" y=\"{d}\" fill=\"#FFA028\">{s} ({s}) - {s}</text>\n", .{ ML, y0 + 12, m.name, m.unit, m.desc });
        const top = y0 + 20;
        out("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"#121417\" stroke=\"#2E333C\"/>\n", .{ ML, top, plot_w, PH });
        if (lo == std.math.inf(f64)) continue;
        if (m.unit[0] != 'C') {
            if (lo > 0) lo = 0;
            if (hi < 0) hi = 0;
        }
        if (hi - lo < 1e-9) hi = lo + 1;
        if (lo < 0 and hi > 0) {
            const zy = @as(f64, @floatFromInt(top + PH)) - (0 - lo) / (hi - lo) * @as(f64, @floatFromInt(PH));
            out("<line x1=\"{d}\" x2=\"{d}\" y1=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#6B675C\" stroke-dasharray=\"3 3\"/>\n", .{ ML, ML + plot_w, zy, zy });
            out("<text x=\"{d}\" y=\"{d:.1}\" fill=\"#A39C89\" text-anchor=\"end\">0</text>\n", .{ ML - 6, zy + 4 });
        }
        out("<text x=\"{d}\" y=\"{d}\" fill=\"#A39C89\" text-anchor=\"end\">{d:.1}</text>\n", .{ ML - 6, top + 10, hi });
        out("<text x=\"{d}\" y=\"{d}\" fill=\"#A39C89\" text-anchor=\"end\">{d:.1}</text>\n", .{ ML - 6, top + PH, lo });
        out("<polyline fill=\"none\" stroke=\"#FFA028\" stroke-width=\"1.2\" points=\"", .{});
        for (bk, 0..) |b, x| {
            if (b.n == 0) {
                out("\"/>\n<polyline fill=\"none\" stroke=\"#FFA028\" stroke-width=\"1.2\" points=\"", .{});
                continue;
            }
            const v = b.sum / @as(f64, @floatFromInt(b.n));
            const y = @as(f64, @floatFromInt(top + PH)) - (v - lo) / (hi - lo) * @as(f64, @floatFromInt(PH));
            out("{d},{d:.1} ", .{ ML + x, y });
        }
        out("\"/>\n", .{});
    }
    out("<text x=\"{d}\" y=\"{d}\" fill=\"#A39C89\">{s}</text>\n", .{ ML, H - 8, fmtTime(&b1, from) });
    out("<text x=\"{d}\" y=\"{d}\" fill=\"#A39C89\" text-anchor=\"end\">{s}</text>\n", .{ W - MR, H - 8, fmtTime(&b2, to) });
    out("</svg>\n", .{});
}

// ---- CSV ----
pub fn csv(recs: []const db.Record) void {
    out("time,ts_ms", .{});
    for (&metrics) |*m| out(",{s}_{s}", .{ m.name, m.unit });
    out(",status,ac,profile,gap\n", .{});
    var b1: [32]u8 = undefined;
    const st = [_][]const u8{ "unknown", "discharging", "charging", "not_charging", "full" };
    const pr = [_][]const u8{ "unknown", "low-power", "balanced", "performance" };
    for (recs) |*r| {
        out("{s},{d}", .{ fmtTime(&b1, r.ts_ms), r.ts_ms });
        for (&metrics) |*m| {
            if (m.get(r)) |v| out(",{d:.3}", .{v}) else sys.outRaw(",");
        }
        out(",{s},{d},{s},{d}\n", .{ st[@min(r.status, 4)], r.ac, pr[@min(r.profile, 3)], r.flags & db.FLAG_GAP });
    }
}
