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
//!         with the same focused error `cynic fuzz-reprl` prints
//!         — useful for protocol smoke tests.

const std = @import("std");
const coverage = @import("fuzz_coverage");
const fuzz_reprl = @import("fuzz_reprl");

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

    // The regular CLI's `--gc-threshold` knob isn't surfaced yet —
    // Fuzzilli has no syntax for engine-specific args. Default
    // GC posture is fine for the first fuzzing pass; a future
    // commit can add a `FUZZ_GC_THRESHOLD` env-var if pairing
    // Fuzzilli with `--gc-threshold=1` stress mode pays off.
    fuzz_reprl.run(init.gpa, null, coverage.reset) catch |err| switch (err) {
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

// Force test discovery into the coverage module so its unit tests
// run under `zig build test`. Same dodge as `main.zig` for the
// REPRL protocol tests.
test {
    _ = @import("fuzz_coverage");
}
