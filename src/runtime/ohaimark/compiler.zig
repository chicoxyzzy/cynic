//! Transactional compile/install boundary for Ohaimark.
//!
//! All IR and physical plans live only for this synchronous call. Machine code
//! is installed into the shared W^X allocator only after every pass and the
//! emitter succeeds, then ownership moves into the chunk's T2 state in one
//! publication step. The realm-facing entry records opt-in rollout telemetry;
//! lower-level compile tests remain free to exercise installation directly.

const std = @import("std");
const builtin = @import("builtin");

const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const code_alloc = @import("../jit/code_alloc.zig");
const masm = @import("../jit/masm.zig");
const x86 = @import("../jit/asm_x86_64.zig");
const Realm = @import("../realm.zig").Realm;
const allocation = @import("allocation.zig");
const codegen_aarch64 = @import("codegen_aarch64.zig");
const codegen_x86_64 = @import("codegen_x86_64.zig");
const control_fusion = @import("control_fusion.zig");
const deopt = @import("deopt.zig");
const deopt_physical = @import("deopt_physical.zig");
const feedback_retry = @import("feedback_retry.zig");
const ir = @import("ir.zig");
const lowering = @import("lowering_aarch64.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");
const stats_mod = @import("stats.zig");
const policy = @import("policy.zig");

pub const supported = policy.supported;

/// Realm-facing entry for the runtime dispatcher. Keeping allocator lookup here
/// makes unavailable executable memory a T2-local refusal like every other
/// compile failure.
pub fn compile(realm: *Realm, chunk: *const Chunk) bool {
    const state = chunk.jit_state orelse return false;
    switch (state.ohaimark.tier) {
        .compiled => return true,
        .dont_compile => return false,
        .cold => {},
    }
    const telemetry = &realm.heap.ohaimark_stats;
    const timer = telemetry.beginCompile();
    if (comptime !supported) {
        state.ohaimark.refuse();
        telemetry.finishCompile(timer, .{ .refused = .{ .stage = .unsupported_target } });
        return false;
    }
    const executable_allocator = realm.heap.jitCodeAllocator() orelse {
        state.ohaimark.refuse();
        telemetry.finishCompile(timer, .{ .refused = .{ .stage = .executable_allocator } });
        return false;
    };
    var refusal: stats_mod.Refusal = .{ .stage = .ir };
    const success = compileAndInstallDiagnosed(
        realm.heap.allocator,
        chunk,
        executable_allocator,
        &refusal,
    );
    const installed_bytes = if (success)
        state.ohaimark.executable.bytes().?.len
    else
        0;
    telemetry.finishCompile(
        timer,
        if (success)
            .{ .installed = installed_bytes }
        else
            .{ .refused = refusal },
    );
    return success;
}

/// Compile and publish T2 code, degrading to the lower tiers on every failure.
/// A compiled state is idempotent; a refused state is not retried until a
/// future invalidation policy explicitly resets it.
pub fn compileAndInstall(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    executable_allocator: *code_alloc.CodeAllocator,
) bool {
    var refusal: stats_mod.Refusal = .{ .stage = .ir };
    return compileAndInstallDiagnosed(
        allocator,
        chunk,
        executable_allocator,
        &refusal,
    );
}

fn compileAndInstallDiagnosed(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    executable_allocator: *code_alloc.CodeAllocator,
    refusal: *stats_mod.Refusal,
) bool {
    const state = chunk.jit_state orelse return false;
    switch (state.ohaimark.tier) {
        .compiled => return true,
        .dont_compile => return false,
        .cold => {},
    }
    if (comptime !supported) {
        refusal.* = .{ .stage = .unsupported_target };
        state.ohaimark.refuse();
        return false;
    }

    var retryable_feedback: ?feedback_retry.Site = null;
    var artifacts = compileUnpublished(
        allocator,
        chunk,
        executable_allocator,
        refusal,
        &retryable_feedback,
    ) catch |err| {
        if (err == feedback_retry.Error.RetryableFeedback) {
            const feedback = retryable_feedback orelse {
                state.ohaimark.refuse();
                return false;
            };
            const fingerprint = feedback_retry.fingerprint(
                chunk,
                feedback.key(),
            ) orelse {
                state.ohaimark.refuse();
                return false;
            };
            state.ohaimark.deferForFeedback(feedback.key(), fingerprint);
        } else {
            state.ohaimark.refuse();
        }
        return false;
    };
    defer artifacts.executable.deinit();
    defer artifacts.osr_table.deinit();
    state.publishOhaimark(
        &artifacts.executable,
        if (artifacts.osr_count != 0) &artifacts.osr_table else null,
        artifacts.osr_count,
        artifacts.requires_frame_scope,
    );
    return state.ohaimark.tier == .compiled;
}

const CompileArtifacts = struct {
    executable: code_alloc.InstalledCode,
    osr_table: code_alloc.InstalledCode,
    osr_count: u32,
    requires_frame_scope: bool,
};

fn compileUnpublished(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    executable_allocator: *code_alloc.CodeAllocator,
    refusal: *stats_mod.Refusal,
    retryable_feedback: *?feedback_retry.Site,
) !CompileArtifacts {
    if (comptime builtin.cpu.arch == .x86_64) {
        return compileUnpublishedX86(
            allocator,
            chunk,
            executable_allocator,
            refusal,
            retryable_feedback,
        );
    }
    return compileUnpublishedAarch64(
        allocator,
        chunk,
        executable_allocator,
        refusal,
        retryable_feedback,
    );
}

fn compileUnpublishedAarch64(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    executable_allocator: *code_alloc.CodeAllocator,
    refusal: *stats_mod.Refusal,
    retryable_feedback: *?feedback_retry.Site,
) !CompileArtifacts {
    refusal.* = .{ .stage = .ir };
    var ir_diagnostics: ir.BuildDiagnostics = .{};
    var graph = ir.Graph.buildWithDiagnostics(
        allocator,
        chunk,
        &ir_diagnostics,
    ) catch |err| {
        refusal.unsupported_opcode = ir_diagnostics.unsupported_opcode;
        return err;
    };
    defer graph.deinit();
    refusal.* = .{ .stage = .specialization };
    var specialization = try specialize.Plan.build(allocator, &graph);
    defer specialization.deinit();
    refusal.* = .{ .stage = .representation };
    var representations = try representation.Plan.build(
        allocator,
        &graph,
        &specialization,
    );
    defer representations.deinit();
    refusal.* = .{ .stage = .control_fusion };
    var fused_control = try control_fusion.Plan.build(
        allocator,
        &graph,
        &specialization,
        &representations,
    );
    defer fused_control.deinit();
    refusal.* = .{ .stage = .logical_deopt };
    var logical = try deopt.Metadata.build(allocator, &graph, &specialization);
    defer logical.deinit();
    refusal.* = .{ .stage = .physical_homes };
    var homes = try deopt_physical.Homes.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
    );
    defer homes.deinit();
    refusal.* = .{ .stage = .physical_deopt };
    var physical_deopt = try deopt_physical.Metadata.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
        &homes,
    );
    defer physical_deopt.deinit();
    refusal.* = .{ .stage = .allocation };
    var allocated = try allocation.Plan.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &fused_control,
        &homes,
        .{ .register_count = lowering.value_registers.len },
    );
    defer allocated.deinit();
    refusal.* = .{ .stage = .lowering };
    var lowered = try lowering.Plan.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &fused_control,
        &homes,
        &allocated,
    );
    defer lowered.deinit();

    var machine = masm.Masm.init(allocator);
    defer machine.deinit();
    var osr_entries: std.ArrayListUnmanaged(Chunk.JitState.OsrEntry) = .empty;
    defer osr_entries.deinit(allocator);
    refusal.* = .{ .stage = .codegen };
    try codegen_aarch64.emitGraphCollectingOsrDiagnosed(
        allocator,
        &machine,
        chunk,
        &graph,
        &specialization,
        &representations,
        &fused_control,
        &logical,
        &homes,
        &physical_deopt,
        &allocated,
        &lowered,
        &osr_entries,
        retryable_feedback,
    );
    refusal.* = .{ .stage = .code_install };
    var executable = try executable_allocator.installOwned(machine.code.items);
    errdefer executable.deinit();
    var osr_table: code_alloc.InstalledCode = .{};
    const osr_count: u32 = @intCast(osr_entries.items.len);
    if (osr_count != 0) {
        const bytes = std.mem.sliceAsBytes(osr_entries.items);
        osr_table = try executable_allocator.installOwned(bytes);
    }
    return .{
        .executable = executable,
        .osr_table = osr_table,
        .osr_count = osr_count,
        .requires_frame_scope = true,
    };
}

/// x86_64 shares target-independent control-fusion, allocation, physical
/// deopt, call-handoff, and OSR metadata with the mature backend.
/// Straight-line leaves retain their compact matcher while the general CFG
/// path owns spills, block transfers, loop OSR, and rooted helper boundaries.
fn compileUnpublishedX86(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    executable_allocator: *code_alloc.CodeAllocator,
    refusal: *stats_mod.Refusal,
    retryable_feedback: *?feedback_retry.Site,
) !CompileArtifacts {
    refusal.* = .{ .stage = .ir };
    var ir_diagnostics: ir.BuildDiagnostics = .{};
    var graph = ir.Graph.buildWithDiagnostics(
        allocator,
        chunk,
        &ir_diagnostics,
    ) catch |err| {
        refusal.unsupported_opcode = ir_diagnostics.unsupported_opcode;
        return err;
    };
    defer graph.deinit();
    refusal.* = .{ .stage = .specialization };
    var specialization = try specialize.Plan.build(allocator, &graph);
    defer specialization.deinit();
    refusal.* = .{ .stage = .representation };
    var representations = try representation.Plan.build(
        allocator,
        &graph,
        &specialization,
    );
    defer representations.deinit();
    refusal.* = .{ .stage = .control_fusion };
    var fused_control = try control_fusion.Plan.build(
        allocator,
        &graph,
        &specialization,
        &representations,
    );
    defer fused_control.deinit();

    refusal.* = .{ .stage = .logical_deopt };
    var logical = try deopt.Metadata.build(allocator, &graph, &specialization);
    defer logical.deinit();
    refusal.* = .{ .stage = .physical_homes };
    var homes = try deopt_physical.Homes.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
    );
    defer homes.deinit();
    refusal.* = .{ .stage = .physical_deopt };
    var physical_deopt = try deopt_physical.Metadata.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
        &homes,
    );
    defer physical_deopt.deinit();
    refusal.* = .{ .stage = .allocation };
    var allocated = try allocation.Plan.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &fused_control,
        &homes,
        .{ .register_count = codegen_x86_64.value_register_count },
    );
    defer allocated.deinit();

    refusal.* = .{ .stage = .codegen };
    var machine = x86.Masm.init(allocator);
    defer machine.deinit();
    var osr_entries: std.ArrayListUnmanaged(Chunk.JitState.OsrEntry) = .empty;
    defer osr_entries.deinit(allocator);
    try codegen_x86_64.emitGraphCollectingOsrDiagnosed(
        allocator,
        &machine,
        chunk,
        &graph,
        &specialization,
        &representations,
        &fused_control,
        &logical,
        &homes,
        &physical_deopt,
        &allocated,
        &osr_entries,
        retryable_feedback,
    );
    refusal.* = .{ .stage = .code_install };
    var executable = try executable_allocator.installOwned(machine.code.items);
    errdefer executable.deinit();
    var osr_table: code_alloc.InstalledCode = .{};
    const osr_count = std.math.cast(u32, osr_entries.items.len) orelse
        return error.GraphTooLarge;
    const requires_frame_scope = codegen_x86_64.graphRequiresFrameScope(&graph);
    if (osr_count != 0) {
        osr_table = try executable_allocator.installOwned(
            std.mem.sliceAsBytes(osr_entries.items),
        );
    }
    return .{
        .executable = executable,
        .osr_table = osr_table,
        .osr_count = osr_count,
        .requires_frame_scope = requires_frame_scope,
    };
}
