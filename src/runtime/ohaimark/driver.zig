//! Function-entry and loop-header OSR runtime drivers for Ohaimark.
//!
//! T2 is an additional realm-local gate under the existing JIT master switch.
//! A cold or refused chunk falls through untouched so Bistromath can enter it;
//! a guard exit reports `resumed` separately because Ohaimark has already
//! reconstructed the live Lantern frame and T1 must not restart it at ip 0.
//! Loop-header OSR is a separate host policy (`Realm.ohaimark_osr_enabled`),
//! default-on with production Ohaimark and independently disableable for
//! function-entry diagnosis.

const std = @import("std");

const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const call_mod = @import("../lantern/call.zig");
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const codegen = @import("codegen_aarch64.zig");
const compiler = @import("compiler.zig");
const policy = @import("policy.zig");

pub const supported = compiler.supported;

pub const tier_up_base = policy.tier_up_base;
pub const guard_exit_limit = policy.guard_exit_limit;
pub const osr_strike_limit = policy.osr_strike_limit;
pub const tierUpThreshold = policy.tierUpThreshold;

pub const EnterOutcome = union(enum) {
    /// T2 did not touch the frame. The shared dispatcher may try T1.
    not_entered,
    /// Generated code reconstructed the frame at a bytecode offset. Resume
    /// Lantern exactly there; restarting in another tier would be incorrect.
    resumed,
    /// Generated code reconstructed a loop header because its execution poll
    /// found pending work. Lantern must run its canonical safe point before
    /// dispatching that frame.
    safe_point,
    /// Generated code staged its caller, appended an ordinary bytecode callee
    /// to this same frame list, and yielded to Lantern to drive that callee.
    /// The caller stays parked at the bytecode after the call.
    handed_off,
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

/// A property-feedback refusal remains a normal `dont_compile` state until
/// Lantern changes the relevant IC footprint. This keeps cold feedback from
/// freezing T2 permanently without turning every rejected entry/backedge into
/// another compile attempt.
fn retryFeedbackDeferredTier(chunk: *const Chunk, state: *Chunk.JitState) void {
    const site = state.ohaimark.retryFeedbackSite() orelse return;
    const fingerprint = codegen.retryFeedbackFingerprint(chunk, site) orelse {
        state.ohaimark.refuse();
        return;
    };
    _ = state.ohaimark.retryForFeedbackIfChanged(fingerprint);
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
    const state = frame.chunk.jit_state orelse return .not_entered;

    // Permanent refusal is the common lower-tier path while a backend grows
    // opcode coverage. Check its one-byte status before frame-kind, exit-budget,
    // executable-handle, or retry machinery. Feedback-deferred refusals must
    // still reach the fingerprint refresh below.
    if (state.ohaimark.tier == .dont_compile and
        state.ohaimark.retryFeedbackSite() == null)
    {
        return .not_entered;
    }
    if (!frameKindCompilable(frame)) return .not_entered;
    if (state.ohaimark_guard_exits >= guard_exit_limit) return .not_entered;

    // A feedback-deferred refusal may become cold again, so refresh its one
    // relevant fingerprint before deciding whether compilation is due.
    const needs_compile = blk: {
        if (state.ohaimark.entry() != null) break :blk false;
        retryFeedbackDeferredTier(frame.chunk, state);
        if (state.ohaimark.tier != .cold) return .not_entered;
        const threshold = realm.ohaimark_threshold_override orelse
            tierUpThreshold(frame.chunk.code.len);
        if (state.warmth < threshold) return .not_entered;
        break :blk true;
    };

    if (needs_compile and !compiler.compile(realm, frame.chunk)) {
        return .not_entered;
    }
    if (state.ohaimark_requires_frame_scope) {
        // Generated helpers may allocate or hand off a callee. The compiler
        // publishes this capability with the entry so helper-free x86 code
        // keeps the direct fast path.
        var frame_scope = call_mod.JitFrameScope.init(realm, frames) catch
            return .not_entered;
        defer frame_scope.deinit();
        return enterPublished(allocator, realm, frames, state);
    }
    return enterPublished(allocator, realm, frames, state);
}

fn enterPublished(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(lantern.CallFrame),
    state: *Chunk.JitState,
) lantern.RunError!EnterOutcome {
    if (realm.terminationReason() != null) return .safe_point;
    const raw_entry = state.ohaimark.entry() orelse return .not_entered;
    const entry: EntryFn = @ptrCast(@alignCast(raw_entry));
    const frame = &frames.items[frames.items.len - 1];
    const telemetry = &realm.heap.ohaimark_stats;
    telemetry.recordEntry();
    const result_bits = entry(realm, frame, frame.registers.ptr);
    if (result_bits == codegen.call_pushed_sentinel_bits) return .handed_off;
    if (result_bits == codegen.host_oom_sentinel_bits) return error.OutOfMemory;
    if (result_bits == codegen.safepoint_sentinel_bits) return .safe_point;
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
        .dont_compile => blk: {
            const site = state.ohaimark.retryFeedbackSite() orelse break :blk false;
            const fingerprint = codegen.retryFeedbackFingerprint(chunk, site) orelse
                break :blk false;
            break :blk state.ohaimark.canRetryForFeedback(fingerprint);
        },
        // Match tryOsrEnterTop / Bistromath probe so the precheck is a true
        // no-call filter (not a floor that still calls compile every edge).
        .cold => state.warmth >= (realm.ohaimark_threshold_override orelse
            tierUpThreshold(chunk.code.len)),
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
    var frame_scope = call_mod.JitFrameScope.init(realm, frames) catch return .not_entered;
    defer frame_scope.deinit();

    if (state.ohaimark.entry() == null) {
        retryFeedbackDeferredTier(frame.chunk, state);
        if (state.ohaimark.tier != .cold) return .not_entered;
        const threshold = realm.ohaimark_threshold_override orelse
            tierUpThreshold(frame.chunk.code.len);
        if (state.warmth < threshold) return .not_entered;
        if (!compiler.compile(realm, frame.chunk)) return .not_entered;
    }

    const header_bc = std.math.cast(u32, frame.ip) orelse return .not_entered;
    const code_off = state.ohaimarkOsrCodeOffset(header_bc) orelse {
        // Compiled without a stub for this header (or no loops). Do not strike
        // — the backedge simply stays in the lower tier.
        return .not_entered;
    };
    const base: [*]const u8 = @ptrCast(state.ohaimark.entry().?);
    const stub: EntryFn = @ptrCast(@alignCast(base + code_off));
    if (realm.terminationReason() != null) return .safe_point;
    const telemetry = &realm.heap.ohaimark_stats;
    telemetry.recordEntry();
    const result_bits = stub(realm, frame, frame.registers.ptr);
    if (result_bits == codegen.call_pushed_sentinel_bits) return .handed_off;
    if (result_bits == codegen.host_oom_sentinel_bits) return error.OutOfMemory;
    if (result_bits == codegen.safepoint_sentinel_bits) return .safe_point;
    if (result_bits == codegen.osr_bail_sentinel_bits) {
        // True enter-and-bail (failed header materialization). Do not charge
        // function-entry guard_exits — OSR is independent of that budget.
        state.ohaimark_osr_strikes +|= 1;
        telemetry.recordGuardExit();
        return .resumed;
    }
    if (result_bits == codegen.resume_sentinel_bits) {
        // A mid-body guard exit after successful OSR is still an enter-and-bail
        // cycle. Charge the OSR budget so a stale shape/type assumption cannot
        // ping-pong between Lantern and this entry on every iteration.
        state.ohaimark_osr_strikes +|= 1;
        telemetry.recordGuardExit();
        return .resumed;
    }
    telemetry.recordCompletion();
    const value = Value{ .bits = result_bits };
    frame.releaseRegisters(realm, allocator);
    _ = frames.pop();
    return .{ .completed = value };
}
