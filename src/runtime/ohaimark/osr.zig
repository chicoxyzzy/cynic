//! Loop-header OSR-entry metadata for Ohaimark.
//!
//! Every unique IR backedge target is a candidate OSR entry: its block
//! parameters are exactly the Lantern accumulator and liveness-derived live-in
//! registers at that bytecode offset. The metadata is pure and verified; native
//! entry stubs and the runtime driver live elsewhere (docs/ohaimark.md §3.17).

const std = @import("std");

const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const ir = @import("ir.zig");
const representation = @import("representation.zig");

/// One eligible loop header. Parameter roles are ordered exactly as the IR
/// block parameter table so codegen can materialize them without re-deriving
/// liveness.
pub const Header = struct {
    bytecode_offset: u32,
    block_index: u32,
    param_start: u32,
    param_count: u16,
};

pub const Metadata = struct {
    allocator: std.mem.Allocator,
    headers: []Header,
    /// Flattened ParamRole stream owned by this table; each header owns a
    /// contiguous slice via param_start/param_count.
    roles: []ir.ParamRole,

    pub fn build(allocator: std.mem.Allocator, graph: *const ir.Graph) !Metadata {
        var headers: std.ArrayListUnmanaged(Header) = .empty;
        errdefer headers.deinit(allocator);
        var roles: std.ArrayListUnmanaged(ir.ParamRole) = .empty;
        errdefer roles.deinit(allocator);

        // One entry per unique target block, ordered by bytecode offset for
        // deterministic tables and golden tests.
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(allocator);

        var candidates: std.ArrayListUnmanaged(struct { block: u32, bc: u32 }) = .empty;
        defer candidates.deinit(allocator);

        for (graph.edges) |edge| {
            if (edge.from >= graph.blocks.len or edge.to >= graph.blocks.len) {
                return error.MalformedGraph;
            }
            const source = graph.blocks[edge.from];
            const target = graph.blocks[edge.to];
            if (!source.reachable or !target.reachable) continue;
            // Same backedge rule as codegen: a jump to an earlier-or-equal
            // bytecode leader is a loop edge. Equal covers self-loops.
            if (target.start > source.start) continue;
            if (try seen.fetchPut(allocator, @intCast(edge.to), {})) |_| continue;
            try candidates.append(allocator, .{
                .block = @intCast(edge.to),
                .bc = target.start,
            });
        }

        std.mem.sort(
            @TypeOf(candidates.items[0]),
            candidates.items,
            {},
            struct {
                fn less(_: void, a: @TypeOf(candidates.items[0]), b: @TypeOf(candidates.items[0])) bool {
                    return a.bc < b.bc or (a.bc == b.bc and a.block < b.block);
                }
            }.less,
        );

        for (candidates.items) |candidate| {
            const block = graph.blocks[candidate.block];
            const params = try checkedParamRange(graph, block);
            try validateHeaderParams(graph, block, params);
            const role_start: u32 = @intCast(roles.items.len);
            for (graph.params[params.start..params.end()]) |param| {
                try roles.append(allocator, param.role);
            }
            const role_count: u16 = @intCast(roles.items.len - role_start);
            if (role_count != params.len) return error.MalformedGraph;
            try headers.append(allocator, .{
                .bytecode_offset = candidate.bc,
                .block_index = candidate.block,
                .param_start = role_start,
                .param_count = role_count,
            });
        }

        return .{
            .allocator = allocator,
            .headers = try headers.toOwnedSlice(allocator),
            .roles = try roles.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Metadata) void {
        self.allocator.free(self.headers);
        self.allocator.free(self.roles);
        self.* = undefined;
    }

    pub fn rolesFor(self: *const Metadata, header_index: usize) ![]const ir.ParamRole {
        if (header_index >= self.headers.len) return error.InvalidMetadata;
        const header = self.headers[header_index];
        return checkedRoleSlice(self.roles, header.param_start, header.param_count);
    }

    /// Independent recomputation. Mutated tables return InvalidMetadata; graphs
    /// that disagree with their own edges return MalformedGraph.
    pub fn verify(self: *const Metadata, graph: *const ir.Graph) !void {
        var expected = try Metadata.build(self.allocator, graph);
        defer expected.deinit();
        if (self.headers.len != expected.headers.len or self.roles.len != expected.roles.len) {
            return error.InvalidMetadata;
        }
        for (self.headers, expected.headers) |got, want| {
            if (got.bytecode_offset != want.bytecode_offset or
                got.block_index != want.block_index or
                got.param_count != want.param_count)
            {
                return error.InvalidMetadata;
            }
            const got_roles = try self.rolesFor(
                // index by scanning — param_start may differ after rebuild
                indexOfHeader(self, got.bytecode_offset) orelse return error.InvalidMetadata,
            );
            const want_roles = try expected.rolesFor(
                indexOfHeader(&expected, want.bytecode_offset) orelse return error.InvalidMetadata,
            );
            if (got_roles.len != want_roles.len) return error.InvalidMetadata;
            for (got_roles, want_roles) |g, w| {
                if (!paramRoleEql(g, w)) return error.InvalidMetadata;
            }
            _ = got.param_start;
        }
        // Cross-check each header against the live graph block parameters.
        for (self.headers) |header| {
            if (header.block_index >= graph.blocks.len) return error.InvalidMetadata;
            const block = graph.blocks[header.block_index];
            if (!block.reachable or block.start != header.bytecode_offset) {
                return error.InvalidMetadata;
            }
            const params = try checkedParamRange(graph, block);
            if (params.len != header.param_count) return error.InvalidMetadata;
            const roles = try checkedRoleSlice(self.roles, header.param_start, header.param_count);
            for (roles, graph.params[params.start..params.end()]) |role, param| {
                if (!paramRoleEql(role, param.role)) return error.InvalidMetadata;
            }
            try validateHeaderParams(graph, block, params);
        }
    }

    /// When representation info is available, report whether every parameter
    /// can be loaded from a tagged Lantern frame slot (always true for tagged
    /// params; int32 params need a runtime check_int32 on entry).
    pub fn headerNeedsInt32Checks(
        self: *const Metadata,
        graph: *const ir.Graph,
        representations: *const representation.Plan,
        header_index: usize,
    ) !bool {
        if (header_index >= self.headers.len) return error.InvalidMetadata;
        const header = self.headers[header_index];
        if (header.block_index >= graph.blocks.len) return error.MalformedGraph;
        const block = graph.blocks[header.block_index];
        const params = try checkedParamRange(graph, block);
        for (graph.params[params.start..params.end()]) |param| {
            if (param.value >= representations.outputs.len) return error.MalformedGraph;
            switch (representations.outputs[param.value]) {
                .int32 => return true,
                .tagged => {},
                .none => return error.MalformedGraph,
            }
        }
        return false;
    }
};

fn indexOfHeader(meta: *const Metadata, bc: u32) ?usize {
    for (meta.headers, 0..) |header, index| {
        if (header.bytecode_offset == bc) return index;
    }
    return null;
}

fn paramRoleEql(a: ir.ParamRole, b: ir.ParamRole) bool {
    return switch (a) {
        .accumulator => b == .accumulator,
        .register => |reg| switch (b) {
            .register => |other| reg == other,
            .accumulator => false,
        },
    };
}

const Range = struct {
    start: usize,
    len: usize,
    fn end(self: Range) usize {
        return self.start + self.len;
    }
};

fn checkedParamRange(graph: *const ir.Graph, block: ir.Block) !Range {
    const start: usize = block.param_start;
    const len: usize = block.param_count;
    if (start > graph.params.len or len > graph.params.len - start) {
        return error.MalformedGraph;
    }
    return .{ .start = start, .len = len };
}

fn checkedRoleSlice(roles: []const ir.ParamRole, start: u32, count: u16) ![]const ir.ParamRole {
    const s: usize = start;
    const n: usize = count;
    if (s > roles.len or n > roles.len - s) return error.InvalidMetadata;
    return roles[s..][0..n];
}

fn validateHeaderParams(graph: *const ir.Graph, block: ir.Block, params: Range) !void {
    if (params.len == 0) return error.MalformedGraph;
    var saw_accumulator = false;
    var seen_registers: [256]bool = @splat(false);
    for (graph.params[params.start..params.end()], 0..) |param, offset| {
        if (param.value >= graph.nodes.len) return error.MalformedGraph;
        const node = graph.nodes[param.value];
        if (node.kind != .block_parameter or node.input_count != 0) {
            return error.MalformedGraph;
        }
        const parameter_index = switch (node.payload) {
            .parameter => |index| index,
            else => return error.MalformedGraph,
        };
        if (parameter_index != block.param_start + offset) return error.MalformedGraph;
        switch (param.role) {
            .accumulator => {
                if (saw_accumulator) return error.MalformedGraph;
                saw_accumulator = true;
            },
            .register => |register| {
                if (register >= graph.register_count or seen_registers[register]) {
                    return error.MalformedGraph;
                }
                seen_registers[register] = true;
            },
        }
    }
    if (!saw_accumulator) return error.MalformedGraph;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const Builder = @import("../../bytecode/chunk.zig").Builder;
const Span = @import("../../source.zig").Span;
const span: Span = .{ .start = 0, .end = 1 };

fn simpleLoopChunk() !struct { chunk: Chunk, header: u32, root: u8 } {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const root = try builder.reserveRegister();
    try builder.emitOp(.lda_one, span);
    const header = builder.here();
    try builder.emitOp(.jmp_if_false, span);
    const exit_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitOp(.lda_zero, span);
    try builder.emitOp(.jmp, span);
    const back_patch = builder.here();
    try builder.emitI16(0);
    const exit_target = builder.here();
    try builder.emitLoadReg(span, root);
    try builder.emitOp(.return_, span);
    try builder.patchI16(exit_patch, exit_target);
    try builder.patchI16(back_patch, header);
    return .{
        .chunk = try builder.finish(),
        .header = @intCast(header),
        .root = root,
    };
}

fn multiBackedgeLoopChunk() !struct { chunk: Chunk, header: u32, flag: u8 } {
    // Two distinct backedges into the same header (diamond body).
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const flag = try builder.reserveRegister();
    try builder.emitOp(.lda_true, span);
    try builder.emitStoreReg(span, flag);
    try builder.emitOp(.lda_one, span);
    const header = builder.here();
    try builder.emitOp(.jmp_if_false, span);
    const exit_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadReg(span, flag);
    try builder.emitOp(.jmp_if_false, span);
    const else_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitOp(.lda_zero, span);
    try builder.emitOp(.jmp, span);
    const back_a = builder.here();
    try builder.emitI16(0);
    const else_target = builder.here();
    try builder.emitOp(.lda_zero, span);
    try builder.emitOp(.jmp, span);
    const back_b = builder.here();
    try builder.emitI16(0);
    const exit_target = builder.here();
    try builder.emitLoadReg(span, flag);
    try builder.emitOp(.return_, span);
    try builder.patchI16(exit_patch, exit_target);
    try builder.patchI16(else_patch, else_target);
    try builder.patchI16(back_a, header);
    try builder.patchI16(back_b, header);
    return .{
        .chunk = try builder.finish(),
        .header = @intCast(header),
        .flag = flag,
    };
}

fn diamondThenLoopChunk() !struct { chunk: Chunk, header: u32, reg: u8 } {
    // Diamond join feeds a loop header — entry path + backedge.
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const reg = try builder.reserveRegister();
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp_if_false, span);
    const else_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.jmp, span);
    const join_patch = builder.here();
    try builder.emitI16(0);
    const else_target = builder.here();
    try builder.emitLoadSmi(span, 2);
    const header = builder.here();
    try builder.emitStoreReg(span, reg);
    try builder.emitOp(.jmp_if_false, span);
    const exit_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitOp(.lda_zero, span);
    try builder.emitOp(.jmp, span);
    const back_patch = builder.here();
    try builder.emitI16(0);
    const exit_target = builder.here();
    try builder.emitLoadReg(span, reg);
    try builder.emitOp(.return_, span);
    try builder.patchI16(else_patch, else_target);
    try builder.patchI16(join_patch, header);
    try builder.patchI16(exit_patch, exit_target);
    try builder.patchI16(back_patch, header);
    return .{
        .chunk = try builder.finish(),
        .header = @intCast(header),
        .reg = reg,
    };
}

test "Ohaimark OSR metadata: empty graph has no headers" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitLoadSmi(span, 3);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var meta = try Metadata.build(testing.allocator, &graph);
    defer meta.deinit();
    try testing.expectEqual(@as(usize, 0), meta.headers.len);
    try meta.verify(&graph);
}

test "Ohaimark OSR metadata: single loop header records accumulator and live register" {
    var loop = try simpleLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &loop.chunk);
    defer graph.deinit();
    var meta = try Metadata.build(testing.allocator, &graph);
    defer meta.deinit();
    try testing.expectEqual(@as(usize, 1), meta.headers.len);
    try testing.expectEqual(loop.header, meta.headers[0].bytecode_offset);
    const roles = try meta.rolesFor(0);
    try testing.expect(roles.len >= 1);
    try testing.expect(roles[0] == .accumulator);
    var saw_root = false;
    for (roles) |role| switch (role) {
        .accumulator => {},
        .register => |r| {
            if (r == loop.root) saw_root = true;
        },
    };
    try testing.expect(saw_root);
    try meta.verify(&graph);
}

test "Ohaimark OSR metadata: multi-backedge collapses to one header" {
    var loop = try multiBackedgeLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &loop.chunk);
    defer graph.deinit();
    var meta = try Metadata.build(testing.allocator, &graph);
    defer meta.deinit();
    try testing.expectEqual(@as(usize, 1), meta.headers.len);
    try testing.expectEqual(loop.header, meta.headers[0].bytecode_offset);
    try meta.verify(&graph);
}

test "Ohaimark OSR metadata: diamond-to-loop maps join header once" {
    var loop = try diamondThenLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &loop.chunk);
    defer graph.deinit();
    var meta = try Metadata.build(testing.allocator, &graph);
    defer meta.deinit();
    // Exactly one OSR header even though the diamond join and the backedge
    // both reach the loop; the recorded offset is the IR block leader (which
    // may sit at the join's first instruction rather than the store).
    try testing.expectEqual(@as(usize, 1), meta.headers.len);
    try testing.expect(meta.headers[0].bytecode_offset <= loop.header);
    const roles = try meta.rolesFor(0);
    try testing.expect(roles.len >= 1);
    try testing.expect(roles[0] == .accumulator);
    _ = loop.reg;
    try meta.verify(&graph);
}

test "Ohaimark OSR metadata: corrupted header count fails verify" {
    var loop = try simpleLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &loop.chunk);
    defer graph.deinit();
    var meta = try Metadata.build(testing.allocator, &graph);
    defer meta.deinit();
    // Corrupt: drop the header.
    const kept = meta.headers;
    meta.headers = try testing.allocator.alloc(Header, 0);
    defer {
        testing.allocator.free(meta.headers);
        meta.headers = kept;
    }
    try testing.expectError(error.InvalidMetadata, meta.verify(&graph));
}

test "Ohaimark OSR metadata: corrupted bytecode offset fails verify" {
    var loop = try simpleLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &loop.chunk);
    defer graph.deinit();
    var meta = try Metadata.build(testing.allocator, &graph);
    defer meta.deinit();
    try testing.expect(meta.headers.len == 1);
    meta.headers[0].bytecode_offset +%= 1;
    try testing.expectError(error.InvalidMetadata, meta.verify(&graph));
    meta.headers[0].bytecode_offset -%= 1;
}

test "Ohaimark OSR metadata: corrupted role stream fails verify" {
    var loop = try simpleLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &loop.chunk);
    defer graph.deinit();
    var meta = try Metadata.build(testing.allocator, &graph);
    defer meta.deinit();
    try testing.expect(meta.roles.len >= 1);
    // Flip accumulator to a fake register role.
    meta.roles[0] = .{ .register = 0 };
    try testing.expectError(error.InvalidMetadata, meta.verify(&graph));
    meta.roles[0] = .accumulator;
}

test "Ohaimark OSR metadata: bogus param_count fails rolesFor and verify" {
    var loop = try simpleLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &loop.chunk);
    defer graph.deinit();
    var meta = try Metadata.build(testing.allocator, &graph);
    defer meta.deinit();
    meta.headers[0].param_count = 255;
    try testing.expectError(error.InvalidMetadata, meta.rolesFor(0));
    try testing.expectError(error.InvalidMetadata, meta.verify(&graph));
}
