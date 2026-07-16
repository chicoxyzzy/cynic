//! Transactional compile/install boundary for Ohaimark.
//!
//! All IR and physical plans live only for this synchronous call. Machine code
//! is installed into the shared W^X allocator only after every pass and the
//! emitter succeeds, then ownership moves into the chunk's T2 state in one
//! publication step. The realm-facing entry records opt-in rollout telemetry;
//! lower-level compile tests remain free to exercise installation directly.

const std = @import("std");

const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const code_alloc = @import("../jit/code_alloc.zig");
const masm = @import("../jit/masm.zig");
const Realm = @import("../realm.zig").Realm;
const allocation = @import("allocation.zig");
const codegen = @import("codegen_aarch64.zig");
const deopt = @import("deopt.zig");
const deopt_physical = @import("deopt_physical.zig");
const ir = @import("ir.zig");
const lowering = @import("lowering_aarch64.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");
const stats_mod = @import("stats.zig");

pub const supported = masm.native_aarch64;

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

    var executable = compileUnpublished(
        allocator,
        chunk,
        executable_allocator,
        refusal,
    ) catch {
        state.ohaimark.refuse();
        return false;
    };
    defer executable.deinit();
    state.ohaimark.publish(&executable);
    return state.ohaimark.tier == .compiled;
}

fn compileUnpublished(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    executable_allocator: *code_alloc.CodeAllocator,
    refusal: *stats_mod.Refusal,
) !code_alloc.InstalledCode {
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
        &homes,
        &allocated,
    );
    defer lowered.deinit();

    var machine = masm.Masm.init(allocator);
    defer machine.deinit();
    refusal.* = .{ .stage = .codegen };
    try codegen.emitGraph(
        allocator,
        &machine,
        chunk,
        &graph,
        &specialization,
        &representations,
        &logical,
        &homes,
        &physical_deopt,
        &allocated,
        &lowered,
    );
    refusal.* = .{ .stage = .code_install };
    return executable_allocator.installOwned(machine.code.items);
}
