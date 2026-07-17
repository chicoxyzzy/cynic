//! Micro-bench driver — spawns `zig-out/bin/cynic run` per fixture
//! in `bench/micros/`, captures wall time + peak RSS via rusage on
//! the child, runs each fixture N× (default 10) after a discarded
//! warmup, and reports p50 (true median), min, max, relative spread,
//! and a Tukey-fence outlier count.
//!
//! Tail percentiles (p95 / p99) are mitata-inspired but honest about
//! sample size: with only 10 samples the 95th/99th percentile
//! collapses onto `max` (nearest-rank index N-1), so those columns
//! stay hidden until the budget supports them — p95 at N ≥ 20,
//! p99 at N ≥ 100. Raise the budget with `--runs=<N>` (which then
//! lights up the columns automatically).
//!
//! Outliers are *reported, never deleted*: p50 / min / max are
//! computed over the full sample set. The count is how many samples
//! sit above the Tukey fence Q3 + 1.5·IQR — a quick "is this
//! fixture's median trustworthy this run" signal.
//!
//! Phase 1 of docs/benchmarking.md — single-engine perf telemetry
//! to surface regressions per commit. Cross-engine (jsvu /
//! eshost-cli) integration is Phase 2.
//!
//! Cold-start semantics, by design: every sample is a fresh
//! process, so the JIT cannot persist across runs — the only
//! in-process warmup is the fixture's own loop, and the discarded
//! warmup run warms OS caches, not the tier. Default-posture
//! numbers are therefore "cold start, what a user gets," NOT
//! steady-state JIT throughput. The fixed run count serves both
//! postures: measured spreads have been comparable (the variance
//! is machine-dominated); if the default column's spread% ever
//! diverges from the --no-jit column's, bump --runs for it.
//!
//! Usage:
//!   zig build bench                 # engine default (Bistromath on)
//!   zig build bench -- --no-jit     # Lantern-only baseline column
//!   zig build bench -- --runs=40    # wider budget; lights up p95
//!   zig build bench -- --runs=200   # lights up p95 + p99
//!   zig build bench -- --macros     # Octane macro set (bench/macros/),
//!                                   # run --unhardened; Splay is heavy,
//!                                   # so --runs=3 for a quick pass
//!
//! Bench host expectations (see the "Stability hardening" section of
//! docs/benchmarking.md):
//!   - Quiet machine; CPU affinity helps on Linux (`taskset -c 0`)
//!   - macOS: `sudo pmset -a sleep 0 disablesleep 1` for the bench
//!     window
//! Numbers across hosts are not directly comparable.

const std = @import("std");

// Default 10 timed runs + 1 discarded warmup. Matched with the
// cross-engine harness in `tools/bench-cross.sh` so single-engine
// and cross-engine numbers come out of the same sample budget.
// 5-run medians were too sensitive to one-off OS scheduling jitter
// on a shared machine (parallel agent's bench / GC pulse landing
// during one iteration); 10 samples halve the per-fixture variance
// without doubling the wall-time. Even count means the p50 path
// returns the average of the two middle samples — a true
// statistical median, not the upper-middle pick used by simpler
// implementations.
//
// `--runs=<N>` overrides the default at runtime (clamped to
// MAX_RUNS). The samples live in a fixed stack buffer, so no
// allocation — MAX_RUNS just caps it.
const DEFAULT_RUNS = 10;
const MAX_RUNS = 1024;
const WARMUP_RUNS = 1;

// Percentile gating: a percentile is only worth printing when its
// nearest-rank index lands strictly below `max` (index N-1).
//   p95 distinct when ceil(0.95·N) < N  ⇒  N ≥ 20
//   p99 distinct when ceil(0.99·N) < N  ⇒  N ≥ 100
const P95_MIN_SAMPLES = 20;
const P99_MIN_SAMPLES = 100;

const Bench = struct {
    name: []const u8,
    path: []const u8,
};

const BENCHES = [_]Bench{
    .{ .name = "arith_loop", .path = "bench/micros/arith_loop.js" },
    .{ .name = "div_loop", .path = "bench/micros/div_loop.js" },
    .{ .name = "prop_access", .path = "bench/micros/prop_access.js" },
    .{ .name = "prop_write", .path = "bench/micros/prop_write.js" },
    .{ .name = "array_iter", .path = "bench/micros/array_iter.js" },
    .{ .name = "string_concat", .path = "bench/micros/string_concat.js" },
    .{ .name = "promise_chain", .path = "bench/micros/promise_chain.js" },
    .{ .name = "object_alloc", .path = "bench/micros/object_alloc.js" },
    .{ .name = "method_call", .path = "bench/micros/method_call.js" },
    .{ .name = "class_instantiate", .path = "bench/micros/class_instantiate.js" },
    // Constructor `this.x = …` write IC surviving an array literal
    // built in the same loop — guards the make_array proto-struct-epoch
    // false-positive deopt.
    .{ .name = "ctor_array_build", .path = "bench/micros/ctor_array_build.js" },
    .{ .name = "json_stringify", .path = "bench/micros/json_stringify.js" },
    // §15.10 PTC — recurses past the 1024-frame stack ceiling;
    // proves the tail_call opcodes keep the spine at depth 1.
    .{ .name = "tail_recursion", .path = "bench/micros/tail_recursion.js" },
};

// Macro benchmarks — the compute core of the retired V8 Octane 2.0
// suite (bench/macros/, vendored verbatim; see its README). Selected
// with `--macros`; run under `--unhardened` because the ES5-era
// bodies monkey-patch primordials. Heavier than the micros — Splay
// alone allocates ~250k objects — so they are a separate set, not
// folded into the default fast micro inner-loop.
const MACROS = [_]Bench{
    .{ .name = "richards", .path = "bench/macros/richards.js" },
    .{ .name = "deltablue", .path = "bench/macros/deltablue.js" },
    .{ .name = "crypto", .path = "bench/macros/crypto.js" },
    .{ .name = "raytrace", .path = "bench/macros/raytrace.js" },
    .{ .name = "navier_stokes", .path = "bench/macros/navier-stokes.js" },
    .{ .name = "splay", .path = "bench/macros/splay.js" },
};

const Sample = struct {
    wall_us: i64,
    rss_bytes: usize,
};

const Stats = struct {
    p50_wall_ms: f64,
    /// Present only when the sample count supports it (N ≥ 20 / 100);
    /// otherwise null and the column is hidden so it can't masquerade
    /// as a distinct value when it's really just `max`.
    p95_wall_ms: ?f64,
    p99_wall_ms: ?f64,
    min_wall_ms: f64,
    max_wall_ms: f64,
    /// (max − min) / p50 × 100. Dispersion at a glance; works at any N.
    spread_pct: f64,
    /// Count of samples above the Tukey fence Q3 + 1.5·IQR. Reported,
    /// not deleted — every sample still feeds p50 / min / max.
    outliers: usize,
    median_rss_kb: usize,
};

/// Run `cynic run <fixture>` once. Capture wall time across the
/// spawn / wait pair and the child's peak RSS via
/// `request_resource_usage_statistics`. Clock is `.awake`
/// (monotonic, suspended time excluded — closest to "how long the
/// child actually ran on this CPU").
fn runOnce(
    io: std.Io,
    cynic_bin: []const u8,
    fixture: []const u8,
    jit: bool,
    no_jit: bool,
    unhardened: bool,
) !Sample {
    const t0 = std.Io.Clock.now(.awake, io);
    // `--enable-experimental` flips every tracked pre-Stage-4
    // proposal on (ShadowRealm today; joint-iteration and upsert
    // graduated to default-on at Stage 4) so fixtures gated on
    // those flags execute the gated path. No
    // effect on the older arith / alloc / promise fixtures, which
    // don't touch any gated surface. `--jit` (opt-in, mirroring the
    // engine default) measures the Bistromath posture with its
    // natural tier-up thresholds — what a user gets, not a forced
    // compile. `--unhardened --allow=eval` is the bench posture for every
    // fixture: the Octane workloads monkey-patch primordial prototypes
    // (rejected by the default frozen-primordials SES posture) and use the
    // Function constructor (gated behind --allow=eval).
    var argv_buf: [7][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = cynic_bin;
    argc += 1;
    argv_buf[argc] = "--enable-experimental";
    argc += 1;
    if (unhardened) {
        argv_buf[argc] = "--unhardened";
        argc += 1;
        argv_buf[argc] = "--allow=eval";
        argc += 1;
    }
    if (jit) {
        argv_buf[argc] = "--jit";
        argc += 1;
    } else if (no_jit) {
        argv_buf[argc] = "--no-jit";
        argc += 1;
    }
    argv_buf[argc] = "run";
    argc += 1;
    argv_buf[argc] = fixture;
    argc += 1;
    var child = try std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
        // Suppress the fixture's print() output — the bench harness
        // doesn't care, and dumping it would scramble the report.
        .stdout = .ignore,
        .stderr = .ignore,
        .request_resource_usage_statistics = true,
    });
    const term = try child.wait(io);
    const wall_us = t0.untilNow(io, .awake).toMicroseconds();

    switch (term) {
        .exited => |code| if (code != 0) return error.FixtureFailed,
        else => return error.FixtureFailed,
    }

    const rss_bytes = child.resource_usage_statistics.getMaxRss() orelse 0;

    return .{
        .wall_us = wall_us,
        .rss_bytes = rss_bytes,
    };
}

/// Nearest-rank percentile over a wall-time-sorted slice. `p` in
/// 1..100. rank = ceil(p/100 · N); index = rank − 1, clamped.
fn percentileUs(sorted: []const Sample, p: u8) i64 {
    const n = sorted.len;
    var rank = (@as(usize, p) * n + 99) / 100; // ceil(p·n/100)
    if (rank < 1) rank = 1;
    if (rank > n) rank = n;
    return sorted[rank - 1].wall_us;
}

fn usToMs(us: i64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

/// Sort `samples` by wall time, then derive the full Stats. p50 uses
/// the interpolated true-median (avg of the two middles on even N)
/// for headline stability; the tail percentiles and quartiles use
/// nearest-rank, which is plenty for gated columns and an outlier
/// count.
fn computeStats(samples: []Sample) Stats {
    std.mem.sort(Sample, samples, {}, struct {
        fn lt(_: void, a: Sample, b: Sample) bool {
            return a.wall_us < b.wall_us;
        }
    }.lt);
    const n = samples.len;

    // True median: odd N → middle sample; even N → average of the two
    // middles. Avoids the upward bias of the `samples[len/2]` shortcut.
    const p50_us: i64 = if (n & 1 == 1)
        samples[n / 2].wall_us
    else
        @divTrunc(samples[n / 2 - 1].wall_us + samples[n / 2].wall_us, 2);
    const rss_median: usize = if (n & 1 == 1)
        samples[n / 2].rss_bytes
    else
        (samples[n / 2 - 1].rss_bytes + samples[n / 2].rss_bytes) / 2;

    const min_us = samples[0].wall_us;
    const max_us = samples[n - 1].wall_us;

    const p50_ms = usToMs(p50_us);
    const min_ms = usToMs(min_us);
    const max_ms = usToMs(max_us);
    const spread_pct: f64 = if (p50_ms > 0)
        (max_ms - min_ms) / p50_ms * 100.0
    else
        0.0;

    // Tukey fence: count samples above Q3 + 1.5·IQR. Never removed.
    const q1 = percentileUs(samples, 25);
    const q3 = percentileUs(samples, 75);
    const iqr = q3 - q1;
    const fence = q3 + @divTrunc(iqr * 3, 2);
    var outliers: usize = 0;
    for (samples) |s| {
        if (s.wall_us > fence) outliers += 1;
    }

    return .{
        .p50_wall_ms = p50_ms,
        .p95_wall_ms = if (n >= P95_MIN_SAMPLES) usToMs(percentileUs(samples, 95)) else null,
        .p99_wall_ms = if (n >= P99_MIN_SAMPLES) usToMs(percentileUs(samples, 99)) else null,
        .min_wall_ms = min_ms,
        .max_wall_ms = max_ms,
        .spread_pct = spread_pct,
        .outliers = outliers,
        .median_rss_kb = rss_median / 1024,
    };
}

fn medianUsOf(samples: []const Sample) i64 {
    var tmp: [MAX_RUNS]i64 = undefined;
    for (samples, 0..) |s, i| tmp[i] = s.wall_us;
    const slice = tmp[0..samples.len];
    std.mem.sort(i64, slice, {}, std.sort.asc(i64));
    return slice[slice.len / 2];
}

/// Interleaved A/B (`--ab-baseline=<binary>`). For each fixture, alternate
/// HEAD and baseline runs back-to-back so each pair sees the same
/// instantaneous host speed, then take the median of the per-iteration
/// ratios (head_i / base_i). Drift between the two halves cancels, so the
/// ratio is trustworthy even on a noisy shared host — far better than
/// running all of HEAD then all of baseline. `ratio < 1` = HEAD faster.
/// `spread%` is (max-min)/median of the per-iteration ratios: low = the
/// ratio is solid, high = genuinely unstable (re-run / suspect).
fn runInterleavedAb(
    io: std.Io,
    head_bin: []const u8,
    base_bin: []const u8,
    fixtures: []const Bench,
    runs: usize,
    jit: bool,
    no_jit: bool,
    unhardened: bool,
) !void {
    var buf: [512]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&buf, "{s:<16} {s:>10} {s:>10} {s:>9} {s:>8}\n", .{ "bench", "base_ms", "head_ms", "ratio", "spread%" });
    try std.Io.File.stdout().writeStreamingAll(io, hdr);
    const sep = try std.fmt.bufPrint(&buf, "{s:<16} {s:>10} {s:>10} {s:>9} {s:>8}\n", .{ "-----", "------", "------", "-----", "-------" });
    try std.Io.File.stdout().writeStreamingAll(io, sep);

    var head_buf: [MAX_RUNS]Sample = undefined;
    var base_buf: [MAX_RUNS]Sample = undefined;
    var ratio_buf: [MAX_RUNS]f64 = undefined;
    for (fixtures) |b| {
        // One warmup each, discarded.
        _ = runOnce(io, head_bin, b.path, jit, no_jit, unhardened) catch {};
        _ = runOnce(io, base_bin, b.path, jit, no_jit, unhardened) catch {};

        const head = head_buf[0..runs];
        const base = base_buf[0..runs];
        const ratios = ratio_buf[0..runs];
        var failed = false;
        var i: usize = 0;
        while (i < runs) : (i += 1) {
            head[i] = runOnce(io, head_bin, b.path, jit, no_jit, unhardened) catch {
                failed = true;
                break;
            };
            base[i] = runOnce(io, base_bin, b.path, jit, no_jit, unhardened) catch {
                failed = true;
                break;
            };
            const hf: f64 = @floatFromInt(head[i].wall_us);
            const bf: f64 = @floatFromInt(base[i].wall_us);
            ratios[i] = if (bf > 0) hf / bf else 1.0;
        }
        if (failed) {
            const fail = try std.fmt.bufPrint(&buf, "{s:<16}  run failed\n", .{b.name});
            try std.Io.File.stderr().writeStreamingAll(io, fail);
            continue;
        }

        const base_ms = usToMs(medianUsOf(base));
        const head_ms = usToMs(medianUsOf(head));
        std.mem.sort(f64, ratios, {}, std.sort.asc(f64));
        const ratio_med = ratios[ratios.len / 2];
        const r_spread = if (ratio_med > 0) (ratios[ratios.len - 1] - ratios[0]) / ratio_med * 100.0 else 0.0;
        const row = try std.fmt.bufPrint(&buf, "{s:<16} {d:>10.2} {d:>10.2} {d:>8.3}x {d:>8.1}\n", .{ b.name, base_ms, head_ms, ratio_med, r_spread });
        try std.Io.File.stdout().writeStreamingAll(io, row);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Parse `--runs=<N>` (default DEFAULT_RUNS, clamped to MAX_RUNS).
    // Anything else on the line is ignored — this driver has one knob.
    var runs: usize = DEFAULT_RUNS;
    var jit = false;
    var no_jit = false;
    var macros = false;
    var ab_baseline: ?[]const u8 = null;
    {
        var args_iter = init.minimal.args.iterate();
        _ = args_iter.next(); // skip the binary path
        while (args_iter.next()) |a| {
            if (std.mem.startsWith(u8, a, "--runs=")) {
                runs = std.fmt.parseInt(usize, a["--runs=".len..], 10) catch DEFAULT_RUNS;
                if (runs < 1) runs = 1;
                if (runs > MAX_RUNS) runs = MAX_RUNS;
            } else if (std.mem.eql(u8, a, "--jit")) {
                // The engine default since 2026-06-11 — accepted
                // for symmetry; spawns pass the flag through.
                jit = true;
            } else if (std.mem.eql(u8, a, "--no-jit")) {
                // Interpreter-only baseline column
                // (docs/jit.md §12 step 3b).
                no_jit = true;
            } else if (std.mem.eql(u8, a, "--macros")) {
                // Run the Octane macro set (bench/macros/) instead of
                // the default micros, under `--unhardened`.
                macros = true;
            } else if (std.mem.startsWith(u8, a, "--ab-baseline=")) {
                // Interleaved A/B vs this baseline cynic binary — see
                // runInterleavedAb. The argv memory is process-lifetime.
                ab_baseline = a["--ab-baseline=".len..];
            }
        }
    }
    // Run every fixture --unhardened --allow=eval: the Octane macro bodies
    // need it (they monkey-patch primordials and use the Function
    // constructor), and it keeps the comparison fair against the unhardened
    // peer engines — no SES tax on Cynic alone.
    const fixtures: []const Bench = if (macros) &MACROS else &BENCHES;
    const unhardened = true;
    const show_p95 = runs >= P95_MIN_SAMPLES;
    const show_p99 = runs >= P99_MIN_SAMPLES;

    // ReleaseFast cynic, installed by build.zig's bench step.
    // Don't fall back to the default `cynic` install since that's
    // likely Debug — 5-10× slower and useless for perf signal.
    const cynic_bin = "zig-out/bin/cynic-bench";
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, cynic_bin, .{}) catch {
        const msg = "bench: cynic-bench binary not found at zig-out/bin/cynic-bench — run `zig build bench` (it builds + runs in one step).\n";
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(1);
    };

    // Interleaved A/B mode: HEAD (cynic-bench) vs the given baseline
    // binary, alternating per iteration so host drift cancels.
    if (ab_baseline) |base_bin| {
        try runInterleavedAb(io, cynic_bin, base_bin, fixtures, runs, jit, no_jit, unhardened);
        return;
    }

    // Header + separator. Tail-percentile columns are inserted only
    // when the sample budget supports them.
    var buf: [512]u8 = undefined;
    {
        var n: usize = 0;
        n += (try std.fmt.bufPrint(buf[n..], "{s:<16} {s:>10}", .{ "bench", "p50_ms" })).len;
        if (show_p95) n += (try std.fmt.bufPrint(buf[n..], " {s:>10}", .{"p95_ms"})).len;
        if (show_p99) n += (try std.fmt.bufPrint(buf[n..], " {s:>10}", .{"p99_ms"})).len;
        n += (try std.fmt.bufPrint(buf[n..], " {s:>10} {s:>10} {s:>9} {s:>8} {s:>10}\n", .{ "min_ms", "max_ms", "spread%", "outliers", "rss_kb" })).len;
        try std.Io.File.stdout().writeStreamingAll(io, buf[0..n]);
    }
    {
        var n: usize = 0;
        n += (try std.fmt.bufPrint(buf[n..], "{s:<16} {s:>10}", .{ "-----", "------" })).len;
        if (show_p95) n += (try std.fmt.bufPrint(buf[n..], " {s:>10}", .{"------"})).len;
        if (show_p99) n += (try std.fmt.bufPrint(buf[n..], " {s:>10}", .{"------"})).len;
        n += (try std.fmt.bufPrint(buf[n..], " {s:>10} {s:>10} {s:>9} {s:>8} {s:>10}\n", .{ "------", "------", "-------", "--------", "------" })).len;
        try std.Io.File.stdout().writeStreamingAll(io, buf[0..n]);
    }

    var samples_buf: [MAX_RUNS]Sample = undefined;

    for (fixtures) |b| {
        // Warmup — discarded so cold-start cache effects don't skew
        // the first recorded sample.
        var w: usize = 0;
        while (w < WARMUP_RUNS) : (w += 1) {
            _ = runOnce(io, cynic_bin, b.path, jit, no_jit, unhardened) catch |err| {
                const fail = try std.fmt.bufPrint(&buf, "{s:<16}  warmup failed: {s}\n", .{ b.name, @errorName(err) });
                try std.Io.File.stderr().writeStreamingAll(io, fail);
            };
        }

        const samples = samples_buf[0..runs];
        var any_failed = false;
        var i: usize = 0;
        while (i < runs) : (i += 1) {
            samples[i] = runOnce(io, cynic_bin, b.path, jit, no_jit, unhardened) catch |err| {
                const fail = try std.fmt.bufPrint(&buf, "{s:<16}  run {d} failed: {s}\n", .{ b.name, i, @errorName(err) });
                try std.Io.File.stderr().writeStreamingAll(io, fail);
                any_failed = true;
                samples[i] = .{ .wall_us = std.math.maxInt(i64), .rss_bytes = 0 };
                continue;
            };
        }
        if (any_failed) continue;

        const stats = computeStats(samples);
        var n: usize = 0;
        n += (try std.fmt.bufPrint(buf[n..], "{s:<16} {d:>10.2}", .{ b.name, stats.p50_wall_ms })).len;
        if (show_p95) {
            // p95 is non-null whenever show_p95 is true (same gate).
            n += (try std.fmt.bufPrint(buf[n..], " {d:>10.2}", .{stats.p95_wall_ms.?})).len;
        }
        if (show_p99) {
            n += (try std.fmt.bufPrint(buf[n..], " {d:>10.2}", .{stats.p99_wall_ms.?})).len;
        }
        n += (try std.fmt.bufPrint(buf[n..], " {d:>10.2} {d:>10.2} {d:>9.1} {d:>8} {d:>10}\n", .{
            stats.min_wall_ms,
            stats.max_wall_ms,
            stats.spread_pct,
            stats.outliers,
            stats.median_rss_kb,
        })).len;
        try std.Io.File.stdout().writeStreamingAll(io, buf[0..n]);
    }
}
