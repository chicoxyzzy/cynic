//! Differential evaluator for Ohaimark's currently supported pure SSA subset.
//!
//! This is a correctness oracle before native code generation, not a shipping
//! execution tier. It applies the specialization and representation plans,
//! keeps the immutable entry frame available alongside stable deopt homes, and
//! reconstructs a Lantern continuation from physical metadata when a guard
//! fails. A mandatory step limit keeps malformed or non-terminating graphs
//! from hanging the host.

const std = @import("std");

const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const arith = @import("../lantern/arith.zig");
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const deopt = @import("deopt.zig");
const deopt_physical = @import("deopt_physical.zig");
const ir = @import("ir.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");

pub const Entry = struct {
    accumulator: Value,
    registers: []const Value,
    this_value: Value = Value.undefined_,
    /// Optional because the evaluator still covers realm-independent graph
    /// shapes. `typeof_` supplies it to share Lantern's cached-string logic.
    realm: ?*Realm = null,
    step_limit: usize,
};

pub const DeoptState = struct {
    allocator: std.mem.Allocator,
    node: ir.ValueId,
    bytecode_offset: u32,
    accumulator: Value,
    registers: []Value,
    this_value: Value,

    pub fn deinit(self: *DeoptState) void {
        self.allocator.free(self.registers);
        self.* = undefined;
    }

    /// Resume the failed operation in Lantern. The recovered register slice is
    /// state-owned, so the synthetic frame must not return it to Realm's pool.
    pub fn resumeLantern(
        self: *DeoptState,
        allocator: std.mem.Allocator,
        realm: *Realm,
        chunk: *const Chunk,
    ) lantern.RunError!lantern.RunResult {
        var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
        defer {
            for (frames.items) |*frame| frame.releaseRegisters(realm, allocator);
            frames.deinit(allocator);
        }
        try frames.append(allocator, .{
            .chunk = chunk,
            .ip = self.bytecode_offset,
            .accumulator = self.accumulator,
            .registers = self.registers,
            .env = null,
            .this_value = self.this_value,
            .owns_registers = false,
            .argc = 0,
        });
        return lantern.runFrames(allocator, realm, &frames);
    }
};

pub const Outcome = union(enum) {
    returned: Value,
    deopt: DeoptState,

    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .returned => {},
            .deopt => |*state| state.deinit(),
        }
        self.* = undefined;
    }
};

pub fn evaluate(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    logical: *const deopt.Metadata,
    homes: *const deopt_physical.Homes,
    physical: *const deopt_physical.Metadata,
    entry: Entry,
) !Outcome {
    try physical.verify(
        graph,
        specialization,
        representations,
        logical,
        homes,
    );
    if (graph.blocks.len == 0 or entry.registers.len != graph.register_count) {
        return error.MalformedGraph;
    }

    var runner = try Runner.init(
        allocator,
        chunk,
        graph,
        specialization,
        representations,
        homes,
        physical,
        entry,
    );
    defer runner.deinit();
    return runner.run(entry);
}

const RuntimeValue = union(enum) {
    none,
    tagged: Value,
    int32: i32,
};

const Input = union(enum) {
    value: RuntimeValue,
    guard_failed,
};

const NodeResult = union(enum) {
    value: RuntimeValue,
    guard_failed,
};

const Runner = struct {
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    homes: *const deopt_physical.Homes,
    physical: *const deopt_physical.Metadata,
    values: []RuntimeValue,
    edge_scratch: []RuntimeValue,
    tagged_spills: []Value,
    int32_spills: []i32,
    steps_left: usize,
    this_value: Value,
    realm: ?*Realm,
    entry_accumulator: Value,
    entry_registers: []const Value,

    fn init(
        allocator: std.mem.Allocator,
        chunk: *const Chunk,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        homes: *const deopt_physical.Homes,
        physical: *const deopt_physical.Metadata,
        entry: Entry,
    ) !Runner {
        const values = try allocator.alloc(RuntimeValue, graph.nodes.len);
        errdefer allocator.free(values);
        @memset(values, .none);
        const edge_scratch = try allocator.alloc(RuntimeValue, graph.params.len);
        errdefer allocator.free(edge_scratch);
        @memset(edge_scratch, .none);
        const tagged_spills = try allocator.alloc(Value, homes.tagged_slot_count);
        errdefer allocator.free(tagged_spills);
        @memset(tagged_spills, Value.undefined_);
        const int32_spills = try allocator.alloc(i32, homes.int32_slot_count);
        errdefer allocator.free(int32_spills);
        @memset(int32_spills, 0);
        return .{
            .allocator = allocator,
            .chunk = chunk,
            .graph = graph,
            .specialization = specialization,
            .representations = representations,
            .homes = homes,
            .physical = physical,
            .values = values,
            .edge_scratch = edge_scratch,
            .tagged_spills = tagged_spills,
            .int32_spills = int32_spills,
            .steps_left = entry.step_limit,
            .this_value = entry.this_value,
            .realm = entry.realm,
            .entry_accumulator = entry.accumulator,
            .entry_registers = entry.registers,
        };
    }

    fn deinit(self: *Runner) void {
        self.allocator.free(self.values);
        self.allocator.free(self.edge_scratch);
        self.allocator.free(self.tagged_spills);
        self.allocator.free(self.int32_spills);
        self.* = undefined;
    }

    fn run(self: *Runner, entry: Entry) !Outcome {
        try self.assignEntry(entry);
        var block_index: usize = 0;
        while (true) {
            if (block_index >= self.graph.blocks.len) return error.MalformedGraph;
            const block = self.graph.blocks[block_index];
            if (!block.reachable) return error.MalformedGraph;
            const nodes = try checkedRange(self.graph.nodes.len, block.node_start, block.node_count);
            var transferred = false;
            for (nodes.start..nodes.end()) |node_index| {
                if (self.steps_left == 0) return error.StepLimitExceeded;
                self.steps_left -= 1;
                const node_id: ir.ValueId = @intCast(node_index);
                const node = self.graph.nodes[node_index];
                switch (node.kind) {
                    .block_parameter => return error.MalformedGraph,
                    .constant,
                    .add,
                    .sub,
                    .mul,
                    .div,
                    .strict_eq,
                    .logical_not,
                    .less_than,
                    .load_named,
                    .load_this,
                    .load_global,
                    .load_global_slot,
                    .load_environment,
                    .throw_if_hole,
                    .typeof_,
                    => {
                        switch (try self.evaluateValueNode(node_id)) {
                            .value => |value| try self.define(node_id, value),
                            .guard_failed => return self.deoptAt(node_id),
                        }
                    },
                    .allocate_environment, .store_environment, .direct_call => return self.deoptAt(node_id),
                    .jump => {
                        const edge = try self.singleOutgoingEdge(block_index);
                        block_index = try self.transfer(edge);
                        transferred = true;
                        break;
                    },
                    .branch => {
                        const condition = try self.taggedNodeInput(node_id, 0);
                        const branch = switch (node.payload) {
                            .branch => |branch| branch,
                            else => return error.MalformedGraph,
                        };
                        const taken = switch (branch) {
                            .truthy => arith.toBoolean(condition),
                            .falsy => !arith.toBoolean(condition),
                            .nullish => condition.isNullish(),
                        };
                        const edge = try self.branchEdge(block_index, taken);
                        block_index = try self.transfer(edge);
                        transferred = true;
                        break;
                    },
                    .return_ => return .{
                        .returned = try self.taggedNodeInput(node_id, 0),
                    },
                }
            }
            if (!transferred) return error.MalformedGraph;
        }
    }

    fn assignEntry(self: *Runner, entry: Entry) !void {
        const block = self.graph.blocks[0];
        const params = try checkedRange(self.graph.params.len, block.param_start, block.param_count);
        for (params.start..params.end()) |param_index| {
            const param = self.graph.params[param_index];
            const raw = switch (param.role) {
                .accumulator => entry.accumulator,
                .register => |register| blk: {
                    if (register >= entry.registers.len) return error.MalformedGraph;
                    break :blk entry.registers[register];
                },
            };
            try self.define(param.value, try runtimeFromTagged(raw, self.outputKind(param.value)));
        }
    }

    fn evaluateValueNode(self: *Runner, node_id: ir.ValueId) !NodeResult {
        if (node_id >= self.graph.nodes.len or node_id >= self.specialization.node_info.len) {
            return error.MalformedGraph;
        }
        const node = self.graph.nodes[node_id];
        const info = self.specialization.node_info[node_id];
        return switch (node.kind) {
            .constant => .{ .value = try self.constantValue(node_id, node) },
            .add => self.arithmetic(node_id, info, .add),
            .sub => self.arithmetic(node_id, info, .sub),
            .mul => self.arithmetic(node_id, info, .mul),
            .div => self.arithmetic(node_id, info, .div),
            .strict_eq => self.strictEqual(node_id, info),
            .logical_not => self.logicalNot(node_id, info),
            .less_than => self.lessThan(node_id, info),
            .load_named => switch (info.lowering) {
                .load_named_own, .load_named_prototype, .load_named_synthetic => .guard_failed,
                .load_named_generic => error.UnsupportedNode,
                else => error.MalformedGraph,
            },
            .load_this => if (info.lowering == .load_this)
                .{ .value = .{ .tagged = self.this_value } }
            else
                error.MalformedGraph,
            .load_global => switch (info.lowering) {
                .load_global => .guard_failed,
                .load_global_generic => error.UnsupportedNode,
                else => error.MalformedGraph,
            },
            .load_global_slot => if (info.lowering == .load_global_slot)
                .guard_failed
            else
                error.MalformedGraph,
            .load_environment => if (info.lowering == .load_environment)
                .guard_failed
            else
                error.MalformedGraph,
            .throw_if_hole => if (info.lowering == .throw_if_hole) blk: {
                const value = try self.taggedNodeInput(node_id, 0);
                if (value.isHole()) break :blk .guard_failed;
                break :blk .{ .value = .{ .tagged = value } };
            } else error.MalformedGraph,
            .typeof_ => if (info.lowering == .typeof_) blk: {
                const realm = self.realm orelse return error.UnsupportedNode;
                break :blk .{ .value = .{ .tagged = try arith.typeOf(
                    realm,
                    try self.taggedNodeInput(node_id, 0),
                ) } };
            } else error.MalformedGraph,
            else => error.MalformedGraph,
        };
    }

    fn constantValue(self: *Runner, node_id: ir.ValueId, node: ir.Node) !RuntimeValue {
        const immediate = switch (node.payload) {
            .immediate => |immediate| immediate,
            else => return error.MalformedGraph,
        };
        return self.runtimeFromImmediate(immediate, self.outputKind(node_id));
    }

    const Arithmetic = enum { add, sub, mul, div };

    fn arithmetic(
        self: *Runner,
        node_id: ir.ValueId,
        info: specialize.NodeInfo,
        op: Arithmetic,
    ) !NodeResult {
        if (info.lowering == .constant) {
            return .{ .value = try self.runtimeFromImmediate(
                info.folded orelse return error.MalformedGraph,
                self.outputKind(node_id),
            ) };
        }
        const number_lowering: ?specialize.Lowering = switch (op) {
            .mul => .number_mul,
            .div => .number_div,
            .add, .sub => null,
        };
        if (number_lowering) |lowering| {
            if (info.lowering == lowering) {
                const lhs_value = try self.taggedNodeInput(node_id, 0);
                const rhs_value = try self.taggedNodeInput(node_id, 1);
                if ((!lhs_value.isInt32() and !lhs_value.isDouble()) or
                    (!rhs_value.isInt32() and !rhs_value.isDouble()))
                {
                    return .guard_failed;
                }
                const lhs = try numberValue(lhs_value);
                const rhs = try numberValue(rhs_value);
                const result = switch (op) {
                    .mul => lhs * rhs,
                    .div => lhs / rhs,
                    .add, .sub => return error.MalformedGraph,
                };
                // Value.fromDouble canonicalizes NaN. Leave that uncommon case to
                // Lantern so native and evaluator paths preserve identical bits.
                if (std.math.isNan(result)) return .guard_failed;
                return .{ .value = .{ .tagged = Value.fromDouble(result) } };
            }
        }
        const expected = switch (op) {
            .add => specialize.Lowering.checked_int32_add,
            .sub => specialize.Lowering.checked_int32_sub,
            .mul => specialize.Lowering.checked_int32_mul,
            .div => specialize.Lowering.checked_int32_div,
        };
        if (info.lowering != expected) {
            if (info.lowering == .generic) return error.UnsupportedNode;
            return error.MalformedGraph;
        }
        const lhs = (try self.int32NodeInput(node_id, 0)) orelse return .guard_failed;
        const rhs = (try self.int32NodeInput(node_id, 1)) orelse return .guard_failed;
        if (op == .div) {
            if (rhs == 0 or
                (lhs == std.math.minInt(i32) and rhs == -1) or
                (lhs == 0 and rhs < 0) or @rem(lhs, rhs) != 0)
            {
                return .guard_failed;
            }
            return .{ .value = .{ .int32 = @divTrunc(lhs, rhs) } };
        }
        const result = switch (op) {
            .add => @addWithOverflow(lhs, rhs),
            .sub => @subWithOverflow(lhs, rhs),
            .mul => @mulWithOverflow(lhs, rhs),
            .div => unreachable,
        };
        if (result[1] != 0 or
            (op == .mul and result[0] == 0 and ((lhs < 0) != (rhs < 0))))
        {
            return .guard_failed;
        }
        return .{ .value = .{ .int32 = result[0] } };
    }

    fn strictEqual(
        self: *Runner,
        node_id: ir.ValueId,
        info: specialize.NodeInfo,
    ) !NodeResult {
        if (info.lowering == .constant) {
            return .{ .value = try self.runtimeFromImmediate(
                info.folded orelse return error.MalformedGraph,
                self.outputKind(node_id),
            ) };
        }
        if (info.lowering != .strict_eq) return error.MalformedGraph;
        const lhs = (try self.int32NodeInput(node_id, 0)) orelse return .guard_failed;
        const rhs = (try self.int32NodeInput(node_id, 1)) orelse return .guard_failed;
        return .{ .value = .{ .tagged = Value.fromBool(lhs == rhs) } };
    }

    fn logicalNot(
        self: *Runner,
        node_id: ir.ValueId,
        info: specialize.NodeInfo,
    ) !NodeResult {
        if (info.lowering == .constant) {
            return .{ .value = try self.runtimeFromImmediate(
                info.folded orelse return error.MalformedGraph,
                self.outputKind(node_id),
            ) };
        }
        if (info.lowering != .logical_not and info.lowering != .checked_boolean_not) {
            return error.MalformedGraph;
        }
        const input = try self.taggedNodeInput(node_id, 0);
        if (!input.isBool()) {
            if (info.lowering == .checked_boolean_not) return .guard_failed;
            return error.MalformedGraph;
        }
        return .{ .value = .{ .tagged = Value.fromBool(!input.asBool()) } };
    }

    fn lessThan(
        self: *Runner,
        node_id: ir.ValueId,
        info: specialize.NodeInfo,
    ) !NodeResult {
        if (info.lowering == .constant) {
            return .{ .value = try self.runtimeFromImmediate(
                info.folded orelse return error.MalformedGraph,
                self.outputKind(node_id),
            ) };
        }
        if (info.lowering != .less_than) return error.MalformedGraph;
        const lhs = try numberValue(try self.taggedNodeInput(node_id, 0));
        const rhs = try numberValue(try self.taggedNodeInput(node_id, 1));
        return .{ .value = .{ .tagged = Value.fromBool(lhs < rhs) } };
    }

    fn define(self: *Runner, value_id: ir.ValueId, value: RuntimeValue) !void {
        if (value_id >= self.values.len) return error.MalformedGraph;
        const expected = self.outputKind(value_id);
        const actual: representation.Kind = switch (value) {
            .none => .none,
            .tagged => .tagged,
            .int32 => .int32,
        };
        if (actual != expected or actual == .none) return error.MalformedGraph;
        self.values[value_id] = value;
        if (value_id >= self.homes.values.len) return error.InvalidMetadata;
        const home = self.homes.values[value_id] orelse return;
        switch (home) {
            .tagged_stack => |slot| {
                if (slot >= self.tagged_spills.len or value != .tagged) {
                    return error.InvalidMetadata;
                }
                self.tagged_spills[slot] = value.tagged;
            },
            .int32_stack => |slot| {
                if (slot >= self.int32_spills.len or value != .int32) {
                    return error.InvalidMetadata;
                }
                self.int32_spills[slot] = value.int32;
            },
        }
    }

    fn outputKind(self: *const Runner, value_id: ir.ValueId) representation.Kind {
        if (value_id >= self.representations.outputs.len) return .none;
        return self.representations.outputs[value_id];
    }

    fn nodeInput(self: *Runner, node_id: ir.ValueId, operand: usize) !Input {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const node = self.graph.nodes[node_id];
        const inputs = try checkedRange(self.graph.inputs.len, node.input_start, node.input_count);
        if (operand >= inputs.len) return error.MalformedGraph;
        return self.inputAt(inputs.start + operand);
    }

    fn inputAt(self: *Runner, input_index: usize) !Input {
        if (input_index >= self.graph.inputs.len) return error.MalformedGraph;
        const producer = self.graph.inputs[input_index];
        if (producer >= self.values.len) return error.MalformedGraph;
        const source = self.values[producer];
        return switch (try self.representations.conversionAt(self.graph, input_index)) {
            .none => if (source == .none) error.MalformedGraph else .{ .value = source },
            .box_int32 => switch (source) {
                .int32 => |value| .{ .value = .{ .tagged = Value.fromInt32(value) } },
                else => error.MalformedGraph,
            },
            .check_int32 => switch (source) {
                .tagged => |value| if (value.isInt32())
                    .{ .value = .{ .int32 = value.asInt32() } }
                else
                    .guard_failed,
                else => error.MalformedGraph,
            },
        };
    }

    fn taggedNodeInput(self: *Runner, node_id: ir.ValueId, operand: usize) !Value {
        return switch (try self.nodeInput(node_id, operand)) {
            .guard_failed => error.MalformedGraph,
            .value => |value| switch (value) {
                .tagged => |tagged| tagged,
                else => error.MalformedGraph,
            },
        };
    }

    fn int32NodeInput(self: *Runner, node_id: ir.ValueId, operand: usize) !?i32 {
        return switch (try self.nodeInput(node_id, operand)) {
            .guard_failed => null,
            .value => |value| switch (value) {
                .int32 => |int32| int32,
                else => error.MalformedGraph,
            },
        };
    }

    fn singleOutgoingEdge(self: *Runner, block_index: usize) !ir.Edge {
        const edges = try self.blockEdges(block_index);
        if (edges.len != 1) return error.MalformedGraph;
        return self.graph.edges[edges.start];
    }

    fn branchEdge(self: *Runner, block_index: usize, taken: bool) !ir.Edge {
        const wanted: ir.EdgeKind = if (taken) .branch_taken else .branch_fallthrough;
        const edges = try self.blockEdges(block_index);
        var found: ?ir.Edge = null;
        for (self.graph.edges[edges.start..edges.end()]) |edge| {
            if (edge.kind != wanted) continue;
            if (found != null) return error.MalformedGraph;
            found = edge;
        }
        return found orelse error.MalformedGraph;
    }

    fn blockEdges(self: *Runner, block_index: usize) !Range {
        if (block_index >= self.graph.blocks.len) return error.MalformedGraph;
        const block = self.graph.blocks[block_index];
        return checkedRange(self.graph.edges.len, block.edge_start, block.edge_count);
    }

    fn transfer(self: *Runner, edge: ir.Edge) !usize {
        if (edge.to >= self.graph.blocks.len) return error.MalformedGraph;
        const target = self.graph.blocks[edge.to];
        const params = try checkedRange(self.graph.params.len, target.param_start, target.param_count);
        const arguments = try checkedRange(
            self.graph.inputs.len,
            edge.argument_start,
            edge.argument_count,
        );
        if (params.len != arguments.len or params.len > self.edge_scratch.len) {
            return error.MalformedGraph;
        }
        for (0..arguments.len) |offset| {
            self.edge_scratch[offset] = switch (try self.inputAt(arguments.start + offset)) {
                .value => |value| value,
                .guard_failed => return error.InvalidRepresentation,
            };
        }
        for (0..params.len) |offset| {
            try self.define(
                self.graph.params[params.start + offset].value,
                self.edge_scratch[offset],
            );
        }
        return edge.to;
    }

    fn deoptAt(self: *Runner, node_id: ir.ValueId) !Outcome {
        var point_index: ?usize = null;
        for (self.physical.points, 0..) |point, index| {
            if (point.node != node_id) continue;
            if (point_index != null) return error.InvalidMetadata;
            point_index = index;
        }
        var point = try self.physical.decode(
            self.allocator,
            point_index orelse return error.InvalidMetadata,
        );
        defer point.deinit();
        const registers = try self.allocator.alloc(Value, self.graph.register_count);
        errdefer self.allocator.free(registers);
        @memset(registers, Value.undefined_);
        for (point.slots) |slot| {
            if (slot.register >= registers.len) return error.InvalidMetadata;
            registers[slot.register] = try self.materialize(slot.recovery);
        }
        return .{ .deopt = .{
            .allocator = self.allocator,
            .node = node_id,
            .bytecode_offset = point.bytecode_offset,
            .accumulator = try self.materialize(point.accumulator),
            .registers = registers,
            .this_value = self.this_value,
        } };
    }

    fn materialize(self: *const Runner, recovery: deopt_physical.Recovery) !Value {
        return recovery.materialize(.{
            .frame_accumulator = self.entry_accumulator,
            .frame_registers = self.entry_registers,
            .tagged_spills = self.tagged_spills,
            .int32_spills = self.int32_spills,
            .constants = self.chunk.constants,
        });
    }

    fn runtimeFromImmediate(
        self: *const Runner,
        immediate: ir.Immediate,
        kind: representation.Kind,
    ) !RuntimeValue {
        return switch (kind) {
            .int32 => switch (immediate) {
                .int32 => |value| .{ .int32 = value },
                else => error.MalformedGraph,
            },
            .tagged => .{ .tagged = try immediateValue(self.chunk, immediate) },
            .none => error.MalformedGraph,
        };
    }
};

fn runtimeFromTagged(value: Value, kind: representation.Kind) !RuntimeValue {
    return switch (kind) {
        .tagged => .{ .tagged = value },
        .int32 => if (value.isInt32()) .{ .int32 = value.asInt32() } else error.MalformedGraph,
        .none => error.MalformedGraph,
    };
}

fn immediateValue(chunk: *const Chunk, immediate: ir.Immediate) !Value {
    return switch (immediate) {
        .undefined_ => Value.undefined_,
        .null_ => Value.null_,
        .true_ => Value.true_,
        .false_ => Value.false_,
        .hole => Value.hole_,
        .int32 => |value| Value.fromInt32(value),
        .constant_pool => |index| blk: {
            if (index >= chunk.constants.len) return error.MalformedGraph;
            break :blk chunk.constants[index];
        },
    };
}

fn numberValue(value: Value) !f64 {
    if (value.isInt32()) return @floatFromInt(value.asInt32());
    if (value.isDouble()) return value.asDouble();
    return error.UnsupportedNode;
}

const Range = struct {
    start: usize,
    len: usize,

    fn end(self: Range) usize {
        return self.start + self.len;
    }
};

fn checkedRange(total: usize, raw_start: anytype, raw_len: anytype) !Range {
    const start: usize = @intCast(raw_start);
    const len: usize = @intCast(raw_len);
    if (start > total or len > total - start) return error.MalformedGraph;
    return .{ .start = start, .len = len };
}
