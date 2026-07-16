//! Transactional compile/install boundary for Ohaimark.
//!
//! All IR and physical plans live only for this synchronous call. Machine code
//! is installed into the shared W^X allocator only after every pass and the
//! emitter succeeds, then ownership moves into the chunk's T2 state in one
//! publication step. Runtime dispatch deliberately does not consult that state
//! yet; this module establishes lifetime independently of tier-up policy.

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

pub const supported = masm.native_aarch64;

/// Realm-facing entry for the future dispatcher. Keeping allocator lookup here
/// makes unavailable executable memory a T2-local refusal like every other
/// compile failure.
pub fn compile(realm: *Realm, chunk: *const Chunk) bool {
    const state = chunk.jit_state orelse return false;
    switch (state.ohaimark.tier) {
        .compiled => return true,
        .dont_compile => return false,
        .cold => {},
    }
    if (comptime !supported) {
        state.ohaimark.refuse();
        return false;
    }
    const executable_allocator = realm.heap.jitCodeAllocator() orelse {
        state.ohaimark.refuse();
        return false;
    };
    return compileAndInstall(realm.heap.allocator, chunk, executable_allocator);
}

/// Compile and publish T2 code, degrading to the lower tiers on every failure.
/// A compiled state is idempotent; a refused state is not retried until a
/// future invalidation policy explicitly resets it.
pub fn compileAndInstall(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    executable_allocator: *code_alloc.CodeAllocator,
) bool {
    const state = chunk.jit_state orelse return false;
    switch (state.ohaimark.tier) {
        .compiled => return true,
        .dont_compile => return false,
        .cold => {},
    }
    if (comptime !supported) {
        state.ohaimark.refuse();
        return false;
    }

    var executable = compileUnpublished(
        allocator,
        chunk,
        executable_allocator,
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
) !code_alloc.InstalledCode {
    var graph = try ir.Graph.build(allocator, chunk);
    defer graph.deinit();
    var specialization = try specialize.Plan.build(allocator, &graph);
    defer specialization.deinit();
    var representations = try representation.Plan.build(
        allocator,
        &graph,
        &specialization,
    );
    defer representations.deinit();
    var logical = try deopt.Metadata.build(allocator, &graph, &specialization);
    defer logical.deinit();
    var homes = try deopt_physical.Homes.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
    );
    defer homes.deinit();
    var physical_deopt = try deopt_physical.Metadata.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
        &homes,
    );
    defer physical_deopt.deinit();
    var allocated = try allocation.Plan.build(
        allocator,
        &graph,
        &specialization,
        &representations,
        &homes,
        .{ .register_count = lowering.value_registers.len },
    );
    defer allocated.deinit();
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
    return executable_allocator.installOwned(machine.code.items);
}
