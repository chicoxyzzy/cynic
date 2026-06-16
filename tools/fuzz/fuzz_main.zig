//! `cynic-fuzz` — the Fuzzilli REPRL host binary. Separate from
//! `cynic` so the LLVM `-fsanitize-coverage=trace-pc-guard`
//! instrumentation (every basic block carries an edge-tracking
//! call) lives only on this target. The regular `cynic` binary
//! stays at zero coverage overhead.
//!
//! Build:  `zig build fuzz`     → `zig-out/bin/cynic-fuzz`
//! Run:    Fuzzilli invokes it with FDs 100-103 preset and the
//!         `SHM_ID` env var pointing at a POSIX shared-memory
//!         coverage bitmap. Running directly (no FDs, no SHM_ID)
//!         maps no bitmap, then bombs out of `fuzz_reprl.run`
//!         with a focused error naming the expected FDs — useful
//!         for protocol smoke tests.

const std = @import("std");
const coverage = @import("fuzz_coverage.zig");
const fuzz_reprl = @import("fuzz_reprl.zig");

pub fn main(init: std.process.Init) !void {
    // Attach Fuzzilli's coverage bitmap when SHM_ID is set;
    // otherwise run uninstrumented. A failure mapping the SHM
    // is a soft warning, not fatal — the REPRL loop still runs
    // and reports per-iteration exit codes, just without
    // coverage feedback. (Fuzzilli does require the bitmap for
    // its corpus to evolve; a warning surfaces the
    // misconfiguration without masking it.)
    coverage.mapShm(init.minimal.environ) catch |err| {
        var line_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &line_buf,
            "warning: SHM mapping failed ({t}); running without coverage feedback\n",
            .{err},
        ) catch return err;
        try std.Io.File.stderr().writeStreamingAll(init.io, msg);
    };

    // `FUZZ_GC_THRESHOLD` env-var surfaces the CLI's `--gc-threshold`
    // knob to Fuzzilli (which has no syntax for engine-specific
    // args). Cynic slab-pools its GC objects, so a swept header
    // returns to a free-list rather than to the OS — meaning a
    // use-after-free on a borrowed slice (a dangling property key,
    // an unanchored cons-string leaf) is caught by the 0xaa free-
    // poison ONLY if the stale read beats the slab's reallocation.
    // Lowering the allocation-pressure GC threshold collects more
    // often, so swept memory spends more wall-clock poisoned and
    // the race tips toward detection. `FUZZ_GC_THRESHOLD=1`
    // collects on every allocation (maximal detection, slowest);
    // a mid value (e.g. 256) trades some sensitivity for exec-rate.
    // Unset ⇒ engine default, the fastest posture.
    const gc_threshold: ?u32 = blk: {
        const raw = init.minimal.environ.getPosix("FUZZ_GC_THRESHOLD") orelse break :blk null;
        break :blk std.fmt.parseInt(u32, raw, 10) catch null;
    };

    // Differential-mode flags (docs/fuzz-differential.md). These come
    // from argv rather than the environment because Fuzzilli shares
    // one `processEnv` across both halves of a differential pair —
    // only `processArgs` vs `processArgsReference` can differ, so the
    // interpreter and JIT runners are distinguished by these flags.
    // Unknown args are ignored: a fuzz host must not abort on a flag
    // it doesn't recognize (Fuzzilli may inject its own).
    var options = fuzz_reprl.Options{ .gc_threshold = gc_threshold };
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.skip(); // argv[0]
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--jit")) {
            options.jit = true;
        } else if (std.mem.eql(u8, arg, "--diff")) {
            options.emit_digest = true;
        } else if (std.mem.eql(u8, arg, "--diff-self-test")) {
            // A digest to perturb is a prerequisite for the self-test.
            options.emit_digest = true;
            options.self_test = true;
        }
    }

    fuzz_reprl.run(init.gpa, options, coverage.reset) catch |err| switch (err) {
        error.UnsupportedPlatform => {
            try std.Io.File.stderr().writeStreamingAll(init.io, "error: `cynic-fuzz` is not supported on this platform (Fuzzilli is POSIX-only)\n");
            std.process.exit(2);
        },
        error.NotOpenForReading, error.WriteFailed => {
            try std.Io.File.stderr().writeStreamingAll(init.io, "error: `cynic-fuzz` expects FDs 100/101/102/103 inherited from Fuzzilli; invoke via the Fuzzilli harness, not directly.\n");
            std.process.exit(2);
        },
        error.HandshakeFailed => {
            try std.Io.File.stderr().writeStreamingAll(init.io, "error: REPRL handshake failed — parent did not reply with `HELO`.\n");
            std.process.exit(2);
        },
        error.UnknownAction => {
            try std.Io.File.stderr().writeStreamingAll(init.io, "error: REPRL: unknown action code on control channel.\n");
            std.process.exit(2);
        },
        error.ScriptTooLarge => {
            try std.Io.File.stderr().writeStreamingAll(init.io, "error: REPRL: sample size exceeds 16 MiB cap (likely a corrupt control channel).\n");
            std.process.exit(2);
        },
        else => return err,
    };
}
