//! Sanitizer-coverage hooks for the Fuzzilli REPRL host. Only
//! the `cynic-fuzz` build target imports this module — the
//! regular `cynic` binary stays uninstrumented and ships none of
//! these symbols.
//!
//! Two pieces:
//!   1. Two `export fn`s the LLVM coverage runtime calls when the
//!      binary is built with `-fsanitize-coverage=trace-pc-guard`:
//!      `__sanitizer_cov_trace_pc_guard_init` once before main()
//!      to enumerate the `__sancov_guards` section, and
//!      `__sanitizer_cov_trace_pc_guard` on every edge taken.
//!   2. `mapShm` + `reset` helpers the REPRL loop calls to
//!      attach Fuzzilli's coverage bitmap (POSIX `shm_open` +
//!      `mmap` of the region named by `$SHM_ID`) and to clear
//!      it between iterations.
//!
//! Wire layout matches every other Fuzzilli engine integration so
//! the upstream profile stays portable: a 4-byte `num_edges`
//! header followed by a bit-packed bitmap (one bit per edge).
//! Default region size 1 MiB — Fuzzilli's `SHM_SIZE` constant;
//! comfortably above cynic's edge count even with every Temporal /
//! Intrinsic file linked in.

const std = @import("std");

/// Fuzzilli's SHM region size. Must match the parent's `mmap` size
/// — the parent maps the same region and reads from it directly.
pub const SHM_SIZE: usize = 0x100000; // 1 MiB

/// Bytes reserved before the bitmap for the `num_edges` u32 header.
pub const HEADER_BYTES: usize = 4;

const Environ = std.process.Environ;

// Guard region bounds + edge count, populated by the LLVM coverage
// runtime via `__sanitizer_cov_trace_pc_guard_init`. Module-level
// vars are correct here: the export fns and the helpers all need
// to share state and the callbacks have no other place to stash it.
var edges_start: ?[*]u32 = null;
var edges_stop: ?[*]u32 = null;
var num_edges: u32 = 0;

/// Base of the mmap'd SHM region. `null` outside REPRL (or when
/// `$SHM_ID` is unset) — the per-edge callback then short-circuits
/// and the binary runs with the LLVM instrumentation present but
/// unobserved. That's useful for a non-Fuzzilli smoke test of
/// `cynic-fuzz` (e.g. piping `HELO` + `exec` manually).
var shmem_base: ?[*]align(@alignOf(u32)) volatile u8 = null;

// `__sancov_lowest_stack` (LLVM's per-function stack-depth
// probe destination) is defined in `fuzz_coverage_sancov.c`,
// not here — see that file for the rationale. `build.zig`
// links the C source into `cynic-fuzz` alongside this module.

/// LLVM coverage runtime calls this once, before main(), with the
/// `__sancov_guards` section bounds. We assign each guard a unique
/// 1-based edge index — index 0 doubles as "already consumed this
/// iteration" so `__sanitizer_cov_trace_pc_guard` can short-circuit
/// without touching memory after the first hit per sample.
export fn __sanitizer_cov_trace_pc_guard_init(start: [*]u32, stop: [*]u32) callconv(.c) void {
    // Critical: the callback itself must NOT be instrumented, or
    // each instrumented edge inside it would re-enter through
    // `__sanitizer_cov_trace_pc_guard`, recursing into a stack
    // overflow on the very first call. `@disableInstrumentation`
    // strips the coverage probes from this function's body.
    @disableInstrumentation();
    var p = start;
    var n: u32 = 0;
    while (@intFromPtr(p) < @intFromPtr(stop)) : (p += 1) {
        n += 1;
        p[0] = n;
    }
    edges_start = start;
    edges_stop = stop;
    num_edges = n;
}

/// LLVM coverage runtime calls this on every edge taken. Hot path —
/// stays branch-light. Sets the bit in Fuzzilli's bitmap and clears
/// the guard so subsequent traversals of the same edge in this
/// iteration are no-ops; `reset` re-arms before the next sample.
export fn __sanitizer_cov_trace_pc_guard(guard: *u32) callconv(.c) void {
    // Same reason as `__sanitizer_cov_trace_pc_guard_init`:
    // recursive instrumentation would blow the stack on the
    // first edge hit. This is also the hottest function in the
    // binary — striking the instrumentation makes it cheap.
    @disableInstrumentation();
    const idx = guard.*;
    if (idx == 0) return;
    if (shmem_base) |base| {
        const bitmap = base + HEADER_BYTES;
        const byte_idx = (idx - 1) / 8;
        const bit_idx: u3 = @intCast((idx - 1) % 8);
        bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
    }
    guard.* = 0;
}

pub const MapError = error{
    ShmOpenFailed,
    MmapFailed,
};

/// Attach Fuzzilli's coverage bitmap. Reads `$SHM_ID` from `env`,
/// opens the POSIX shared-memory object, maps `SHM_SIZE` bytes,
/// and stamps the `num_edges` header. Silent no-op when `$SHM_ID`
/// is unset — that's the "running outside Fuzzilli" path
/// (`cynic-fuzz` is still a working REPRL host, just without
/// coverage feedback).
pub fn mapShm(env: Environ) MapError!void {
    const shm_id = env.getPosix("SHM_ID") orelse return;
    // `shm_open` is declared variadic on Darwin (`name, flag,
    // ...`), so the mode argument needs a concrete fixed-size
    // type — bare `0` would be rejected. `c_uint` matches
    // `mode_t` on both Darwin and Linux for our purposes (we
    // pass 0; the existing region was sized + chmod'd by
    // Fuzzilli, we just open it).
    const fd = std.c.shm_open(
        shm_id.ptr,
        @as(c_int, @bitCast(std.posix.O{ .ACCMODE = .RDWR })),
        @as(c_uint, 0),
    );
    if (fd < 0) return error.ShmOpenFailed;
    const slice = std.posix.mmap(
        null,
        SHM_SIZE,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch return error.MmapFailed;
    const base: [*]align(@alignOf(u32)) volatile u8 = @ptrCast(@alignCast(slice.ptr));
    shmem_base = base;
    // Header: `num_edges` written host-endian. Every host Fuzzilli
    // runs on is little-endian (x86_64, aarch64) — no portability
    // concern over the SHM boundary since both sides are the same
    // process group.
    @as(*volatile u32, @ptrCast(base)).* = num_edges;
}

/// Clear Fuzzilli's bitmap and re-arm every guard. Call at the
/// START of each REPRL iteration — Fuzzilli reads the previous
/// iteration's coverage between writing the status word and
/// sending the next sample, so resetting before execution leaves
/// the read intact.
pub fn reset() void {
    if (shmem_base) |base| {
        const bytes = num_edges / 8 + 1;
        const bitmap = base + HEADER_BYTES;
        var i: usize = 0;
        while (i < bytes) : (i += 1) bitmap[i] = 0;
    }
    if (edges_start) |start| if (edges_stop) |stop| {
        var p = start;
        var n: u32 = 0;
        while (@intFromPtr(p) < @intFromPtr(stop)) : (p += 1) {
            n += 1;
            p[0] = n;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — pure index arithmetic on a stand-in bitmap. The real SHM /
// shm_open / mmap paths only exercise on a Fuzzilli run; a unit test
// could fork off a child to drive the protocol end-to-end, but the
// bit-set math is the interesting failure mode (off-by-one between
// 1-based edge indices and 0-based bit positions) and that's testable
// without any I/O.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fuzz_coverage: bit-packing covers every position in a byte" {
    // Replicate the per-edge math without touching real SHM. Indices
    // 1, 4, 7, 8 land in byte 0 at bits 0, 3, 6, 7; 15 + 16 land in
    // byte 1 at bits 6 + 7.
    var bitmap: [4]u8 = .{ 0, 0, 0, 0 };
    inline for ([_]u32{ 1, 4, 7, 8, 15, 16 }) |idx| {
        const byte_idx = (idx - 1) / 8;
        const bit_idx: u3 = @intCast((idx - 1) % 8);
        bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
    }
    try testing.expectEqual(@as(u8, 0b1100_1001), bitmap[0]);
    try testing.expectEqual(@as(u8, 0b1100_0000), bitmap[1]);
}

test "fuzz_coverage: SHM_SIZE accommodates a million edges with room to spare" {
    // 1 MiB - 4-byte header = 1 048 572 bytes ⇒ 8 388 576 bits. The
    // 1M-edge floor is well above cynic's instrumented edge count
    // even with Temporal + Intl + the playground glue linked in
    // (V8 sits around 3-5M in a hardened build for comparison —
    // we're not close yet).
    try testing.expect(SHM_SIZE - HEADER_BYTES >= 1_000_000 / 8);
}

test "fuzz_coverage: HEADER_BYTES matches the u32 num_edges layout" {
    try testing.expectEqual(@as(usize, @sizeOf(u32)), HEADER_BYTES);
}
