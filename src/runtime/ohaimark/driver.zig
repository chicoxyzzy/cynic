//! Function-entry and loop-header OSR runtime drivers for Ohaimark.
//!
//! T2 is an additional realm-local gate under the existing JIT master switch.
//! A cold or refused chunk falls through untouched so Bistromath can enter it;
//! a guard exit reports `resumed` separately because Ohaimark has already
//! reconstructed the live Lantern frame and T1 must not restart it at ip 0.
//! Loop-header OSR is a separate default-off policy (`Realm.ohaimark_osr_enabled`).

const std = @import("std");

const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const codegen = @import("codegen_aarch64.zig");
const compiler = @import("compiler.zig");

pub const supported = compiler.supported;

/// Starting T2 heat policy. T1 gets the first chance to amortize its much
/// cheaper compiler; Ohaimark waits for mature feedback and sustained heat.
/// These constants remain provisional until the differential and benchmark
/// gates in docs/ohaimark.md §5 complete.
pub const tier_up_base: u32 = 8 * 1024;

/// An installed T2 entry that repeatedly reconstructs the interpreter frame
/// is no longer paying for itself. Four exits preserve a short transient
/// window while bounding entry-and-bail overhead for a permanently changed
/// site. The code remains owned by the chunk; lower tiers simply bypass it.
pub const guard_exit_limit: u8 = 4;

/// Same shape as Bistromath's OSR strike budget: enter-and-bail on every
/// iteration is worse than staying in the lower tier.
pub const osr_strike_limit: u8 = 8;

pub fn tierUpThreshold(code_len: usize) u32 {
    const len: u32 = @intCast(@min(code_len, 1 << 20));
    return tier_up_base +| (32 *| len);
}

pub const EnterOutcome = union(enum) {
    /// T2 did not touch the frame. The shared dispatcher may try T1.
    not_entered,
    /// Generated code reconstructed the frame at a bytecode offset. Resume
    /// Lantern exactly there; restarting in another tier would be incorrect.
    resumed,
    /// The ordinary function frame completed and was popped.
    completed: Value,
};

/// Ohaimark uses the established frame-compatible JIT ABI. The register-file
/// base is explicit so generated code never depends on Zig slice layout.
const EntryFn = *const fn (
    *Realm,
    *lantern.CallFrame,
    [*]Value,
) callconv(.c) u64;

inline fn frameKindOrdinary(frame: *const lantern.CallFrame) bool {
    // Constructor result coercion, generator ownership, and async Promise
    // wrapping stay in Lantern for both function-entry and OSR.
    return !frame.is_construct and
        frame.generator == null and
        !frame.wrap_return_in_promise;
}

inline fn frameKindCompilable(frame: *const lantern.CallFrame) bool {
    return frame.ip == 0 and frameKindOrdinary(frame);
}

/// Try T2 at a freshly-pushed top frame. Compilation is synchronous and
/// transactional; every refusal leaves the lower tiers executable.
pub fn tryEnterTop(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(lantern.CallFrame),
) lantern.RunError!EnterOutcome {
    if (frames.items.len == 0) return .not_entered;

    const frame = &frames.items[frames.items.len - 1];
    // Observe every fresh call before either compiled tier gets a chance to
    // consume it. Heating only from Lantern would freeze the counter as soon
    // as T1 compiled and make a higher natural T2 threshold unreachable.
    if (frame.ip == 0) {
        if (frame.chunk.jit_state) |state| {
            state.warmth +|= Chunk.JitState.entry_weight;
        }
    }
    if (comptime !supported) return .not_entered;
    if (!realm.jit_enabled or !realm.ohaimark_enabled) return .not_entered;
    if (!frameKindCompilable(frame)) return .not_entered;
    const state = frame.chunk.jit_state orelse return .not_entered;
    if (state.ohaimark_guard_exits >= guard_exit_limit) return .not_entered;
    if (state.ohaimark.entry() == null) {
        if (state.ohaimark.tier != .cold) return .not_entered;
        const threshold = realm.ohaimark_threshold_override orelse
            tierUpThreshold(frame.chunk.code.len);
        if (state.warmth < threshold) return .not_entered;
        if (!compiler.compile(realm, frame.chunk)) return .not_entered;
    }

    const raw_entry = state.ohaimark.entry() orelse return .not_entered;
    const entry: EntryFn = @ptrCast(@alignCast(raw_entry));
    const telemetry = &realm.heap.ohaimark_stats;
    telemetry.recordEntry();
    const result_bits = entry(realm, frame, frame.registers.ptr);
    if (result_bits == codegen.resume_sentinel_bits) {
        state.ohaimark_guard_exits +|= 1;
        telemetry.recordGuardExit();
        return .resumed;
    }
    telemetry.recordCompletion();
    const value = Value{ .bits = result_bits };
    frame.releaseRegisters(realm, allocator);
    _ = frames.pop();
    return .{ .completed = value };
}

/// Cheap precheck for Lantern/Bistromath backedges. Avoids a function call on
/// cold loops when OSR cannot fire.
pub fn osrWorth(realm: *const Realm, chunk: *const Chunk) bool {
    if (comptime !supported) return false;
    if (!realm.jit_enabled or !realm.ohaimark_enabled or !realm.ohaimark_osr_enabled) {
        return false;
    }
    const state = chunk.jit_state orelse return false;
    if (state.ohaimark_osr_strikes >= osr_strike_limit) return false;
    return switch (state.ohaimark.tier) {
        .dont_compile => false,
        .cold => state.warmth >= (realm.ohaimark_threshold_override orelse tier_up_base),
        .compiled => state.hasOhaimarkOsr(),
    };
}

/// Loop-header OSR: the caller has just run `loopSafePoint`, so `frame.ip`
/// and the accumulator/registers are the live header state. Compilation is
/// synchronous; refusal never mutates the frame.
pub fn tryOsrEnterTop(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(lantern.CallFrame),
) lantern.RunError!EnterOutcome {
    if (comptime !supported) return .not_entered;
    if (!realm.jit_enabled or !realm.ohaimark_enabled or !realm.ohaimark_osr_enabled) {
        return .not_entered;
    }
    if (frames.items.len == 0) return .not_entered;
    const frame = &frames.items[frames.items.len - 1];
    if (!frameKindOrdinary(frame)) return .not_entered;
    const state = frame.chunk.jit_state orelse return .not_entered;
    if (state.ohaimark_osr_strikes >= osr_strike_limit) return .not_entered;

    if (state.ohaimark.entry() == null) {
        if (state.ohaimark.tier != .cold) return .not_entered;
        const threshold = realm.ohaimark_threshold_override orelse
            tierUpThreshold(frame.chunk.code.len);
        if (state.warmth < threshold) return .not_entered;
        if (!compiler.compile(realm, frame.chunk)) return .not_entered;
    }

    const code_off = state.ohaimarkOsrCodeOffset(@intCast(frame.ip)) orelse {
        // Compiled without a stub for this header (or no loops). Do not strike
        // — the backedge simply stays in the lower tier.
        return .not_entered;
    };
    const base: [*]const u8 = @ptrCast(state.ohaimark.entry().?);
    const stub: EntryFn = @ptrCast(@alignCast(base + code_off));
    const telemetry = &realm.heap.ohaimark_stats;
    telemetry.recordEntry();
    const result_bits = stub(realm, frame, frame.registers.ptr);
    if (result_bits == codegen.resume_sentinel_bits) {
        state.ohaimark_osr_strikes +|= 1;
        state.ohaimark_guard_exits +|= 1;
        telemetry.recordGuardExit();
        return .resumed;
    }
    telemetry.recordCompletion();
    const value = Value{ .bits = result_bits };
    frame.releaseRegisters(realm, allocator);
    _ = frames.pop();
    return .{ .completed = value };
}
