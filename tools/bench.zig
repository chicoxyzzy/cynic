//! Micro-bench driver — spawns `zig-out/bin/cynic run` per fixture
//! in `bench/micros/`, captures wall time + peak RSS via rusage on
//! the child, runs each fixture 5× after a discarded warmup,
//! reports the median.
//!
//! Phase 1 of docs/benchmarking.md — single-engine perf telemetry
//! to surface regressions per commit. Cross-engine (jsvu /
//! eshost-cli) integration is Phase 2.
//!
//! Usage:
//!   zig build bench
//!
//! Bench host expectations (see docs/benchmarking.md §Stability):
//!   - Quiet machine; CPU affinity helps on Linux (`taskset -c 0`)
//!   - macOS: `sudo pmset -a sleep 0 disablesleep 1` for the bench
//!     window
//! Numbers across hosts are not directly comparable.

const std = @import("std");

const RUNS_PER_FIXTURE = 5;
const WARMUP_RUNS = 1;

const Bench = struct {
    name: []const u8,
    path: []const u8,
};

const BENCHES = [_]Bench{
    .{ .name = "arith_loop", .path = "bench/micros/arith_loop.js" },
    .{ .name = "prop_access", .path = "bench/micros/prop_access.js" },
    .{ .name = "prop_write", .path = "bench/micros/prop_write.js" },
    .{ .name = "array_iter", .path = "bench/micros/array_iter.js" },
    .{ .name = "string_concat", .path = "bench/micros/string_concat.js" },
    .{ .name = "promise_chain", .path = "bench/micros/promise_chain.js" },
    .{ .name = "object_alloc", .path = "bench/micros/object_alloc.js" },
};

const Sample = struct {
    wall_us: i64,
    rss_bytes: usize,
};

const Stats = struct {
    median_wall_ms: f64,
    median_rss_kb: usize,
    min_wall_ms: f64,
    max_wall_ms: f64,
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
) !Sample {
    const t0 = std.Io.Clock.now(.awake, io);
    var child = try std.process.spawn(io, .{
        .argv = &.{ cynic_bin, "run", fixture },
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

fn medianStats(samples: []Sample) Stats {
    std.mem.sort(Sample, samples, {}, struct {
        fn lt(_: void, a: Sample, b: Sample) bool {
            return a.wall_us < b.wall_us;
        }
    }.lt);
    const mid = samples.len / 2;
    return .{
        .median_wall_ms = @as(f64, @floatFromInt(samples[mid].wall_us)) / 1000.0,
        .median_rss_kb = samples[mid].rss_bytes / 1024,
        .min_wall_ms = @as(f64, @floatFromInt(samples[0].wall_us)) / 1000.0,
        .max_wall_ms = @as(f64, @floatFromInt(samples[samples.len - 1].wall_us)) / 1000.0,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

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

    var line: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &line,
        "{s:<16} {s:>10} {s:>10} {s:>10} {s:>10}\n",
        .{ "bench", "median_ms", "min_ms", "max_ms", "rss_kb" },
    );
    try std.Io.File.stdout().writeStreamingAll(io, header);
    const sep = try std.fmt.bufPrint(
        &line,
        "{s:<16} {s:>10} {s:>10} {s:>10} {s:>10}\n",
        .{ "-----", "---------", "------", "------", "------" },
    );
    try std.Io.File.stdout().writeStreamingAll(io, sep);

    for (BENCHES) |b| {
        // Warmup — discarded so cold-start cache effects don't
        // skew the first recorded sample.
        var w: usize = 0;
        while (w < WARMUP_RUNS) : (w += 1) {
            _ = runOnce(io, cynic_bin, b.path) catch |err| {
                const fail = try std.fmt.bufPrint(&line, "{s:<16}  warmup failed: {s}\n", .{ b.name, @errorName(err) });
                try std.Io.File.stderr().writeStreamingAll(io, fail);
            };
        }

        var samples: [RUNS_PER_FIXTURE]Sample = undefined;
        var any_failed = false;
        var i: usize = 0;
        while (i < RUNS_PER_FIXTURE) : (i += 1) {
            samples[i] = runOnce(io, cynic_bin, b.path) catch |err| {
                const fail = try std.fmt.bufPrint(&line, "{s:<16}  run {d} failed: {s}\n", .{ b.name, i, @errorName(err) });
                try std.Io.File.stderr().writeStreamingAll(io, fail);
                any_failed = true;
                samples[i] = .{ .wall_us = std.math.maxInt(i64), .rss_bytes = 0 };
                continue;
            };
        }
        if (any_failed) continue;

        const stats = medianStats(&samples);
        const row = try std.fmt.bufPrint(
            &line,
            "{s:<16} {d:>10.2} {d:>10.2} {d:>10.2} {d:>10}\n",
            .{
                b.name,
                stats.median_wall_ms,
                stats.min_wall_ms,
                stats.max_wall_ms,
                stats.median_rss_kb,
            },
        );
        try std.Io.File.stdout().writeStreamingAll(io, row);
    }
}
