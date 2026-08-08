//! Ohaimark's bytecode-to-SSA entry layer. The graph uses block arguments as
//! phi nodes: every reachable block pre-creates an accumulator parameter and
//! parameters for its live-in Lantern registers, then predecessor edges carry
//! the corresponding values. Pre-creation makes backward edges ordinary and
//! avoids a separate loop-phi repair pass.
//!
//! This first layer is intentionally small. Unsupported bytecode returns an
//! explicit error so the tiering driver can leave the chunk in Lantern;
//! exception-only handler blocks also remain in Lantern, while normal paths
//! retain exceptional liveness for exact pre-operation replay. Optimizer input
//! must never turn valid JavaScript into a host abort.

const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const environment_elision = @import("../../bytecode/environment_elision.zig");
const Op = @import("../../bytecode/op.zig").Op;
const liveness = @import("../../bytecode/liveness.zig");
const feedback_mod = @import("feedback.zig");
const Heap = @import("../heap.zig").Heap;

pub const ValueId = u32;
const invalid_value: ValueId = std.math.maxInt(ValueId);
pub const FrameStateId = u32;

pub const BuildDiagnostics = struct {
    unsupported_opcode: ?Op = null,
};

pub const NodeKind = enum {
    block_parameter,
    constant,
    add,
    sub,
    mul,
    div,
    strict_eq,
    logical_not,
    /// §7.1.4 ToNumeric's tagged-Int32 subset. Every other input resumes the
    /// original coercion bytecode before it can invoke user code or produce a
    /// Double/BigInt result.
    to_numeric,
    /// §7.1.17's already-string identity lane. Every conversion that could
    /// allocate, invoke ToPrimitive, or throw resumes Lantern first.
    to_string,
    /// §7.2.1 identity lane for every non-nullish value. Null and undefined
    /// resume Lantern so its canonical TypeError unwinder owns the failure.
    require_object_coercible,
    less_than,
    load_named,
    /// `obj.name = value` writable-own-data StoreIC hit. The inputs preserve
    /// the receiver and assignment value for exact pre-op replay.
    store_named,
    /// `obj[key]` own-data IC hit. The input order is receiver then dynamic
    /// key, preserving the key in the deopt accumulator for full §7.1.19.
    load_computed,
    /// `obj[key] = value` writable-own-data IC hit. The inputs preserve the
    /// receiver, dynamic key, and assignment value for exact pre-op replay.
    store_computed,
    /// §13.5.1.2 ordinary `delete obj[key]`. The native helper accepts only
    /// primitive keys and ordinary receivers, then resumes Lantern before any
    /// observable coercion, exotic [[Delete]], or strict failure.
    delete_computed_property,
    load_this,
    load_global,
    /// §9.1.1.4 object-record SetMutableBinding. The native helper accepts
    /// only an existing writable own data slot on the executing realm's
    /// global object; every lexical, dictionary, missing, or frozen case
    /// resumes the original `sta_global` bytecode before it mutates state.
    store_global,
    load_global_slot,
    /// §9.1.1.4 InitializeBinding for a known top-level lexical slot. The
    /// write fills the TDZ Hole and only needs the realm-slice bounds guard.
    store_global_slot_init,
    /// §9.1.1.4 SetMutableBinding for a known top-level lexical slot. Hole
    /// and immutable bindings guard-exit before the slot write so Lantern owns
    /// the canonical ReferenceError / TypeError path.
    store_global_slot,
    load_environment,
    allocate_environment,
    store_environment,
    /// §14.7.5.6 / §14.12.3 lexical-environment restoration. The operation
    /// only rewrites the executing Lantern frame's environment pointer; it
    /// never allocates, invokes JavaScript, or changes the accumulator.
    pop_environment,
    /// §10.4.4 CreateUnmappedArgumentsObject. The helper reads the pinned
    /// incoming caller-argument window from the rooted Lantern CallFrame and
    /// returns one fresh Arguments exotic object.
    create_unmapped_arguments_object,
    /// §10.2.3 ordinary synchronous function materialisation. The helper
    /// allocates engine-owned closure state, publishes the new function through
    /// the rooted Lantern accumulator, and never invokes JavaScript.
    create_ordinary_function,
    /// §10.2.5 `[[HomeObject]]` installation for an object-literal method.
    /// The node preserves both the function accumulator and its enclosing
    /// object register in the pre-operation Lantern frame before the shared,
    /// non-reentrant helper records the home object.
    set_home,
    /// §13.2.5's static object-method data-property install. The graph admits
    /// only the direct `make_object → make_function → set_home → def_property`
    /// sequence, then stages its exact frame before the shared ordinary-object
    /// helper mutates storage.
    define_object_method_property,
    /// §13.2.5 ObjectLiteral allocation. The helper builds either a plain
    /// object or a chunk-template shape, publishes the fresh object through
    /// the rooted Lantern accumulator, and never invokes JavaScript.
    create_object_literal,
    /// §13.2.4.1 fused, hole-free Array literal allocation. The helper copies
    /// a validated contiguous frame-register window into a fresh Array exotic
    /// after publishing the pre-operation frame as GC roots.
    create_dense_array_literal,
    /// §13.2.4.2's general ArrayCreate(0) form for literals that cannot use
    /// the fused register window.
    create_array_literal,
    /// §13.2.4.1's sequential CreateDataPropertyOrThrow fast path for a
    /// fresh Array literal. Every nonsequential or generic receiver resumes
    /// Lantern before it mutates state.
    append_dense_array_literal_element,
    /// §7.3.7 CreateDataPropertyOrThrow's static literal-slot fast path.
    /// A guard failure resumes Lantern at the original bytecode so the full
    /// generic property-definition path retains ownership of semantics.
    define_template_property,
    /// §14.14 ThrowStatement. The native tier never creates or unwinds a
    /// throw completion: it reconstructs the pre-operation Lantern frame and
    /// resumes this opcode so the canonical unwinder owns catch/finally.
    throw_,
    /// §9.1.1.1.6 GetBindingValue TDZ probe. The non-Hole path is an
    /// accumulator identity; a Hole guard exit resumes Lantern so it creates
    /// and unwinds the required ReferenceError through the canonical path.
    throw_if_hole,
    /// §13.5.3 pure value classification. The generated path dispatches on
    /// the NaN-boxed tag and loads the realm's cached immutable result string;
    /// a cold uninitialized cache exits to Lantern to allocate it.
    typeof_,
    /// §13.3.6 EvaluateCall, direct IC-hit ordinary-call subset. The generated
    /// path stages the caller frame then yields to Lantern to drive the
    /// callee; this includes fused property calls after their data LoadIC and
    /// CallIC validate. Cold, mismatched, and exotic cases resume this opcode
    /// in Lantern before user code runs.
    direct_call,
    /// §15.10 proper-tail-call boundary. Native code restores the exact
    /// pre-tail frame then resumes Lantern, whose canonical dispatcher reuses
    /// the frame without growing the native stack.
    tail_dispatch,
    jump,
    branch,
    return_,
};

pub const Immediate = union(enum) {
    undefined_,
    null_,
    true_,
    false_,
    hole,
    int32: i32,
    constant_pool: u16,
};

pub const BranchCondition = enum {
    truthy,
    falsy,
    nullish,
};

pub const NamedLoad = struct {
    key_constant: u16,
    feedback_index: u16,
};

pub const NamedStore = struct {
    key_constant: u16,
    feedback_index: u16,
};

pub const ComputedLoad = struct {
    feedback_index: u16,
};

pub const ComputedStore = struct {
    feedback_index: u16,
};

pub const ComputedDelete = struct {
    object_register: u8,
    key_register: u8,
};

pub const GlobalLoad = struct {
    key_constant: u16,
    feedback_index: u16,
    or_undefined: bool,
};

pub const GlobalStore = struct {
    key_constant: u16,
};

pub const EnvironmentLoad = struct {
    depth: u8,
    slot: u8,
};

pub const EnvironmentAllocation = struct {
    slot_count: u8,
};

pub const EnvironmentStore = struct {
    depth: u8,
    slot: u8,
};

pub const FunctionTemplateRef = struct {
    template_index: u16,
};

pub const HomeObject = struct {
    object_register: u8,
};

pub const ObjectMethodProperty = struct {
    key_constant: u16,
    object_register: u8,
};

pub const ObjectLiteral = union(enum) {
    plain,
    shape: u16,
};

pub const DenseArrayLiteral = struct {
    base: u8,
    count: u8,
};

pub const DenseArrayAppend = struct {
    key_constant: u16,
    object_register: u8,
};

pub const TemplateProperty = struct {
    key_constant: u16,
    object_register: u8,
    slot: u16,
};

/// A compact call/construct handoff site. `this_register == null` represents
/// the strict free-call `this` value, `undefined`; a present register
/// represents the receiver supplied by `call_method8`. Constructors never use
/// a receiver register: Lantern allocates and binds `this` from the CallIC's
/// cached prototype.
pub const DirectCall = struct {
    pub const Kind = enum { call, construct };

    kind: Kind,
    this_register: ?u8,
    callee: u8,
    argc: u8,
    feedback_index: u16,
};

/// A compact fused `obj.method(args)` handoff. `receiver` is both the
/// `this` value and the register immediately preceding its contiguous
/// argument window. The LoadIC and CallIC remain distinct because the same
/// receiver shape can expose a different callee through a slot rewrite.
pub const DirectPropertyCall = struct {
    receiver: u8,
    argc: u8,
    load_feedback_index: u16,
    call_feedback_index: u16,
};

/// Direct ordinary calls/constructs and fused property calls share the same
/// staged-frame result, but their operands are intentionally distinct: a
/// property call has no callee register until its LoadIC hit resolves one.
pub const DirectCallSite = union(enum) {
    direct: DirectCall,
    property: DirectPropertyCall,
};

pub const Payload = union(enum) {
    none,
    immediate: Immediate,
    parameter: u32,
    branch: BranchCondition,
    named_load: NamedLoad,
    named_store: NamedStore,
    computed_load: ComputedLoad,
    computed_store: ComputedStore,
    computed_delete: ComputedDelete,
    global_load: GlobalLoad,
    global_store: GlobalStore,
    global_slot: u32,
    environment_load: EnvironmentLoad,
    environment_allocation: EnvironmentAllocation,
    environment_store: EnvironmentStore,
    function_template: FunctionTemplateRef,
    home_object: HomeObject,
    object_method_property: ObjectMethodProperty,
    object_literal: ObjectLiteral,
    dense_array_literal: DenseArrayLiteral,
    dense_array_append: DenseArrayAppend,
    template_property: TemplateProperty,
    direct_call: DirectCallSite,
    binary_profile: u16,
};

pub const Node = struct {
    kind: NodeKind,
    bytecode_offset: u32,
    input_start: u32,
    input_count: u16,
    payload: Payload = .none,
    frame_state: ?FrameStateId = null,
};

pub const FrameSlot = struct {
    register: u8,
    value: ValueId,
};

/// Interpreter-visible state immediately before a speculative node executes.
/// Deopt resumes at `bytecode_offset`, so the accumulator and register values
/// are the inputs to that opcode, never its partially-computed outputs.
pub const FrameState = struct {
    block: u32,
    bytecode_offset: u32,
    accumulator: ValueId,
    slot_start: u32,
    slot_count: u16,
};

pub const ParamRole = union(enum) {
    accumulator,
    register: u8,
};

pub const Param = struct {
    role: ParamRole,
    value: ValueId,
};

pub const EdgeKind = enum {
    fallthrough,
    jump,
    branch_taken,
    branch_fallthrough,
};

pub const Edge = struct {
    kind: EdgeKind,
    from: usize,
    to: usize,
    argument_start: u32,
    argument_count: u16,
};

pub const Block = struct {
    start: u32,
    end: u32,
    node_start: u32 = 0,
    node_count: u32 = 0,
    param_start: u32 = 0,
    param_count: u16 = 0,
    edge_start: u32 = 0,
    edge_count: u16 = 0,
    predecessor_count: u32 = 0,
    reachable: bool,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    register_count: u8,
    /// A non-elidable `make_environment` at bytecode offset zero. The native
    /// entry helper performs it before materializing any SSA values, keeping
    /// every JS root in the authoritative Lantern frame.
    entry_environment_slots: ?u8 = null,
    blocks: []Block,
    nodes: []Node,
    inputs: []ValueId,
    params: []Param,
    edges: []Edge,
    frame_states: []FrameState,
    frame_slots: []FrameSlot,
    feedback: feedback_mod.Snapshot,

    pub fn build(allocator: std.mem.Allocator, chunk: *const Chunk) !Graph {
        return buildImpl(allocator, chunk, null);
    }

    pub fn buildWithDiagnostics(
        allocator: std.mem.Allocator,
        chunk: *const Chunk,
        diagnostics: *BuildDiagnostics,
    ) !Graph {
        diagnostics.* = .{};
        return buildImpl(allocator, chunk, diagnostics);
    }

    fn buildImpl(
        allocator: std.mem.Allocator,
        chunk: *const Chunk,
        diagnostics: ?*BuildDiagnostics,
    ) !Graph {
        const environment_summary = environment_elision.analyze(chunk.code) catch
            return error.MalformedBytecode;
        const elide_make_environments = environment_summary.canElideMakeEnvironments();
        const entry_environment_slots = if (elide_make_environments)
            null
        else
            environment_summary.entryAllocationSlots();

        var analysis = try liveness.analyze(
            allocator,
            chunk.code,
            chunk.register_count,
            chunk.handlers,
            chunk.switch_tables,
        );
        defer analysis.deinit();

        var feedback = try feedback_mod.Snapshot.capture(allocator, chunk);
        errdefer feedback.deinit();

        var builder: Builder = .{
            .allocator = allocator,
            .chunk = chunk,
            .analysis = &analysis,
            .diagnostics = diagnostics,
            .entry_environment_slots = entry_environment_slots,
            .elide_make_environments = elide_make_environments,
        };
        defer builder.deinit();
        try builder.createBlocks();
        try builder.createParameters();
        try builder.translateBlocks();

        const blocks = try builder.blocks.toOwnedSlice(allocator);
        errdefer allocator.free(blocks);
        const nodes = try builder.nodes.toOwnedSlice(allocator);
        errdefer allocator.free(nodes);
        const inputs = try builder.inputs.toOwnedSlice(allocator);
        errdefer allocator.free(inputs);
        const params = try builder.params.toOwnedSlice(allocator);
        errdefer allocator.free(params);
        const edges = try builder.edges.toOwnedSlice(allocator);
        errdefer allocator.free(edges);
        const frame_states = try builder.frame_states.toOwnedSlice(allocator);
        errdefer allocator.free(frame_states);
        const frame_slots = try builder.frame_slots.toOwnedSlice(allocator);
        errdefer allocator.free(frame_slots);

        return .{
            .allocator = allocator,
            .register_count = chunk.register_count,
            .entry_environment_slots = entry_environment_slots,
            .blocks = blocks,
            .nodes = nodes,
            .inputs = inputs,
            .params = params,
            .edges = edges,
            .frame_states = frame_states,
            .frame_slots = frame_slots,
            .feedback = feedback,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.nodes);
        self.allocator.free(self.inputs);
        self.allocator.free(self.params);
        self.allocator.free(self.edges);
        self.allocator.free(self.frame_states);
        self.allocator.free(self.frame_slots);
        self.feedback.deinit();
        self.* = undefined;
    }

    pub fn nodeInputs(self: *const Graph, id: ValueId) []const ValueId {
        const node = self.nodes[id];
        return self.inputs[node.input_start..][0..node.input_count];
    }

    pub fn blockParams(self: *const Graph, block: usize) []const Param {
        const b = self.blocks[block];
        return self.params[b.param_start..][0..b.param_count];
    }

    pub fn edgeArguments(self: *const Graph, edge: Edge) []const ValueId {
        return self.inputs[edge.argument_start..][0..edge.argument_count];
    }

    pub fn blockEdges(self: *const Graph, block: usize) []const Edge {
        const b = self.blocks[block];
        return self.edges[b.edge_start..][0..b.edge_count];
    }

    pub fn frameSlots(self: *const Graph, state: FrameState) []const FrameSlot {
        return self.frame_slots[state.slot_start..][0..state.slot_count];
    }
};

const DeoptLivePoint = struct {
    bytecode_offset: u32,
    register_start: u32,
    register_count: u16,
};

const DeoptLiveness = struct {
    points: std.ArrayListUnmanaged(DeoptLivePoint) = .empty,
    registers: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *DeoptLiveness, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        self.registers.deinit(allocator);
    }

    /// Points were collected while scanning bytecode backwards, so forward
    /// graph translation consumes them from the end of the array.
    fn take(
        self: *const DeoptLiveness,
        cursor: *usize,
        bytecode_offset: u32,
    ) ![]const u8 {
        if (cursor.* == 0) return error.MalformedBytecode;
        cursor.* -= 1;
        const point = self.points.items[cursor.*];
        if (point.bytecode_offset != bytecode_offset) return error.MalformedBytecode;
        const start: usize = point.register_start;
        const count: usize = point.register_count;
        if (start > self.registers.items.len or count > self.registers.items.len - start) {
            return error.MalformedBytecode;
        }
        return self.registers.items[start..][0..count];
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    analysis: *const liveness.Analysis,
    diagnostics: ?*BuildDiagnostics,
    entry_environment_slots: ?u8,
    elide_make_environments: bool,
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    inputs: std.ArrayListUnmanaged(ValueId) = .empty,
    params: std.ArrayListUnmanaged(Param) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    frame_states: std.ArrayListUnmanaged(FrameState) = .empty,
    frame_slots: std.ArrayListUnmanaged(FrameSlot) = .empty,

    fn deinit(self: *Builder) void {
        self.blocks.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
        self.params.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.frame_states.deinit(self.allocator);
        self.frame_slots.deinit(self.allocator);
    }

    fn createBlocks(self: *Builder) !void {
        if (self.analysis.blockCount() > std.math.maxInt(u32)) return error.GraphTooLarge;
        var normal_reachable = try self.analysis.normalReachability();
        defer normal_reachable.deinit();
        try self.blocks.ensureTotalCapacity(self.allocator, self.analysis.blockCount());
        for (self.analysis.leaders, 0..) |start, index| {
            const end: u32 = if (index + 1 < self.analysis.leaders.len)
                self.analysis.leaders[index + 1]
            else
                @intCast(self.chunk.code.len);
            self.blocks.appendAssumeCapacity(.{
                .start = start,
                .end = end,
                .reachable = normal_reachable.isSet(index),
            });
        }

        for (self.analysis.succs, 0..) |successors, from| {
            if (!normal_reachable.isSet(from)) continue;
            for (successors.items) |to| {
                if (!normal_reachable.isSet(to)) continue;
                self.blocks.items[to].predecessor_count +|= 1;
            }
        }
    }

    fn createParameters(self: *Builder) !void {
        for (self.blocks.items, 0..) |*block, block_index| {
            block.param_start = try indexU32(self.params.items.len);
            if (!block.reachable) continue;
            try self.addParameter(block, .accumulator);
            var live = self.analysis.live_in[block_index].iterator(.{});
            while (live.next()) |register| {
                if (register > std.math.maxInt(u8)) return error.GraphTooLarge;
                try self.addParameter(block, .{ .register = @intCast(register) });
            }
        }
    }

    fn addParameter(self: *Builder, block: *Block, role: ParamRole) !void {
        if (block.param_count == std.math.maxInt(u16)) return error.GraphTooLarge;
        const param_index = try indexU32(self.params.items.len);
        const value = try self.addNode(
            .block_parameter,
            block.start,
            &.{},
            .{ .parameter = param_index },
        );
        try self.params.append(self.allocator, .{ .role = role, .value = value });
        block.param_count += 1;
    }

    fn translateBlocks(self: *Builder) !void {
        for (0..self.blocks.items.len) |block_index| {
            if (!self.blocks.items[block_index].reachable) continue;
            try self.translateBlock(block_index);
        }
    }

    fn translateBlock(self: *Builder, block_index: usize) !void {
        const start = self.blocks.items[block_index].start;
        const end = self.blocks.items[block_index].end;
        self.blocks.items[block_index].node_start = try indexU32(self.nodes.items.len);
        self.blocks.items[block_index].edge_start = try indexU32(self.edges.items.len);
        const body_start = self.nodes.items.len;
        const edge_start = self.edges.items.len;

        var deopt_liveness = try self.computeDeoptLiveness(block_index, start, end);
        defer deopt_liveness.deinit(self.allocator);
        var deopt_live_cursor = deopt_liveness.points.items.len;

        const registers = try self.allocator.alloc(ValueId, self.chunk.register_count);
        defer self.allocator.free(registers);
        @memset(registers, invalid_value);
        var accumulator = invalid_value;
        const block = self.blocks.items[block_index];
        for (self.params.items[block.param_start..][0..block.param_count]) |param| {
            switch (param.role) {
                .accumulator => accumulator = param.value,
                .register => |register| registers[register] = param.value,
            }
        }

        var terminated = false;
        var pc: usize = start;
        while (pc < end) {
            const op: Op = @enumFromInt(self.chunk.code[pc]);
            const next = pc + 1 + Op.operandSize(op);
            if (next > end) return error.MalformedBytecode;

            if (op == .tail_call or op == .tail_call_method) {
                const callee: u8 = if (op == .tail_call)
                    self.chunk.code[pc + 1]
                else
                    self.chunk.code[pc + 2];
                const argc: u8 = if (op == .tail_call)
                    self.chunk.code[pc + 2]
                else
                    self.chunk.code[pc + 3];
                if (op == .tail_call_method) {
                    _ = try readRegister(registers, self.chunk.code[pc + 1]);
                }
                const args_end = @as(usize, callee) + 1 + @as(usize, argc);
                if (args_end > registers.len) return error.MalformedBytecode;
                for (@as(usize, callee)..args_end) |register| {
                    _ = try readRegister(registers, @intCast(register));
                }
                const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                _ = try self.addDeoptNode(
                    .tail_dispatch,
                    @intCast(pc),
                    &.{},
                    .none,
                    block_index,
                    accumulator,
                    registers,
                    live_registers,
                );
                terminated = true;
                pc = next;
                break;
            }

            if (op.branchInfo()) |branch_info| {
                const target_offset = liveness.branchTarget(op, self.chunk.code, pc) orelse
                    return error.MalformedBytecode;
                if (target_offset >= self.chunk.code.len) return error.MalformedBytecode;
                const target = self.analysis.blockOf(target_offset);
                switch (branch_info.canonical) {
                    .jmp => {
                        _ = try self.addNode(.jump, @intCast(pc), &.{}, .none);
                        try self.addEdge(.jump, block_index, target, accumulator, registers);
                    },
                    .jmp_if_true, .jmp_if_false, .jmp_if_nullish => |canonical| {
                        const condition: BranchCondition = switch (canonical) {
                            .jmp_if_true => .truthy,
                            .jmp_if_false => .falsy,
                            .jmp_if_nullish => .nullish,
                            else => unreachable,
                        };
                        // Frame state lets codegen deopt when a tagged counter
                        // is not int32 (countdown `while (i)` after OSR).
                        const live_registers = try deopt_liveness.take(
                            &deopt_live_cursor,
                            @intCast(pc),
                        );
                        _ = try self.addDeoptNode(
                            .branch,
                            @intCast(pc),
                            &.{accumulator},
                            .{ .branch = condition },
                            block_index,
                            accumulator,
                            registers,
                            live_registers,
                        );
                        try self.addEdge(.branch_taken, block_index, target, accumulator, registers);
                        if (end >= self.chunk.code.len) return error.MalformedBytecode;
                        try self.addEdge(
                            .branch_fallthrough,
                            block_index,
                            self.analysis.blockOf(end),
                            accumulator,
                            registers,
                        );
                    },
                    .jmp_if_strict_eq, .jmp_if_strict_neq => |canonical| {
                        const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                        const live_registers = try deopt_liveness.take(
                            &deopt_live_cursor,
                            @intCast(pc),
                        );
                        const comparison = try self.addDeoptNode(
                            .strict_eq,
                            @intCast(pc),
                            &.{ lhs, accumulator },
                            .none,
                            block_index,
                            accumulator,
                            registers,
                            live_registers,
                        );
                        _ = try self.addNode(
                            .branch,
                            @intCast(pc),
                            &.{comparison},
                            .{ .branch = if (canonical == .jmp_if_strict_eq) .truthy else .falsy },
                        );
                        // The fused opcode branches on the comparison but preserves
                        // the accumulator.
                        try self.addEdge(.branch_taken, block_index, target, accumulator, registers);
                        if (end >= self.chunk.code.len) return error.MalformedBytecode;
                        try self.addEdge(
                            .branch_fallthrough,
                            block_index,
                            self.analysis.blockOf(end),
                            accumulator,
                            registers,
                        );
                    },
                    .jmp_if_not_lt,
                    .jmp_if_not_le,
                    .jmp_if_not_gt,
                    .jmp_if_not_ge,
                    => |canonical| {
                        const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                        const live_registers = try deopt_liveness.take(
                            &deopt_live_cursor,
                            @intCast(pc),
                        );
                        // The checked node only admits Int32, where the four
                        // relations reduce to `<` plus operand / branch-sense
                        // selection. Any Number, BigInt, string, or object
                        // exits before this transformation and Lantern
                        // evaluates the original relation, preserving its
                        // coercion order and NaN behaviour.
                        const inputs: []const ValueId = switch (canonical) {
                            .jmp_if_not_lt, .jmp_if_not_ge => &.{ lhs, accumulator },
                            .jmp_if_not_le, .jmp_if_not_gt => &.{ accumulator, lhs },
                            else => unreachable,
                        };
                        const comparison = try self.addDeoptNode(
                            .less_than,
                            @intCast(pc),
                            inputs,
                            .none,
                            block_index,
                            accumulator,
                            registers,
                            live_registers,
                        );
                        _ = try self.addNode(
                            .branch,
                            @intCast(pc),
                            &.{comparison},
                            .{ .branch = switch (canonical) {
                                .jmp_if_not_lt, .jmp_if_not_gt => .falsy,
                                .jmp_if_not_le, .jmp_if_not_ge => .truthy,
                                else => unreachable,
                            } },
                        );
                        // The fused opcode branches on the comparison but preserves
                        // the accumulator for either successor.
                        try self.addEdge(.branch_taken, block_index, target, accumulator, registers);
                        if (end >= self.chunk.code.len) return error.MalformedBytecode;
                        try self.addEdge(
                            .branch_fallthrough,
                            block_index,
                            self.analysis.blockOf(end),
                            accumulator,
                            registers,
                        );
                    },
                    else => {
                        if (self.diagnostics) |diagnostics| {
                            diagnostics.unsupported_opcode = op;
                        }
                        return error.UnsupportedOp;
                    },
                }
                terminated = true;
                pc = next;
                break;
            }

            switch (op) {
                .lda_undefined => accumulator = try self.addConstant(@intCast(pc), .undefined_),
                .lda_null => accumulator = try self.addConstant(@intCast(pc), .null_),
                .lda_true => accumulator = try self.addConstant(@intCast(pc), .true_),
                .lda_false => accumulator = try self.addConstant(@intCast(pc), .false_),
                .lda_hole => accumulator = try self.addConstant(@intCast(pc), .hole),
                .lda_zero => accumulator = try self.addConstant(@intCast(pc), .{ .int32 = 0 }),
                .lda_one => accumulator = try self.addConstant(@intCast(pc), .{ .int32 = 1 }),
                .lda_smi8 => accumulator = try self.addConstant(
                    @intCast(pc),
                    .{ .int32 = readI8(self.chunk.code, pc + 1) },
                ),
                .lda_smi16 => accumulator = try self.addConstant(
                    @intCast(pc),
                    .{ .int32 = readI16(self.chunk.code, pc + 1) },
                ),
                .lda_smi => accumulator = try self.addConstant(
                    @intCast(pc),
                    .{ .int32 = readI32(self.chunk.code, pc + 1) },
                ),
                .lda_constant => accumulator = try self.addConstant(
                    @intCast(pc),
                    .{ .constant_pool = readU16(self.chunk.code, pc + 1) },
                ),
                .ldar => accumulator = try readRegister(registers, self.chunk.code[pc + 1]),
                .ldar_0, .ldar_1, .ldar_2, .ldar_3 => |compact| {
                    const register: u8 = @intCast(@intFromEnum(compact) - @intFromEnum(Op.ldar_0));
                    accumulator = try readRegister(registers, register);
                },
                .star => try writeRegister(registers, self.chunk.code[pc + 1], accumulator),
                .star_0, .star_1, .star_2, .star_3 => |compact| {
                    const register: u8 = @intCast(@intFromEnum(compact) - @intFromEnum(Op.star_0));
                    try writeRegister(registers, register, accumulator);
                },
                .mov => {
                    const value = try readRegister(registers, self.chunk.code[pc + 1]);
                    try writeRegister(registers, self.chunk.code[pc + 2], value);
                },
                .star_ldar => {
                    try writeRegister(registers, self.chunk.code[pc + 1], accumulator);
                    accumulator = try readRegister(registers, self.chunk.code[pc + 2]);
                },
                .to_numeric => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .to_numeric,
                        @intCast(pc),
                        &.{accumulator},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .to_string => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .to_string,
                        @intCast(pc),
                        &.{accumulator},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .require_object_coercible => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .require_object_coercible,
                        @intCast(pc),
                        &.{accumulator},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .inc, .dec => |update| {
                    // The compiler emits `ToNumeric` directly before these
                    // bump opcodes (optionally separated by SSA-only Star).
                    // Do not admit arbitrary raw Inc/Dec bytecode: Lantern's
                    // opcode assumes its accumulator is already coerced.
                    if (accumulator >= self.nodes.items.len or
                        self.nodes.items[accumulator].kind != .to_numeric)
                    {
                        if (self.diagnostics) |out| out.unsupported_opcode = update;
                        return error.UnsupportedOp;
                    }
                    const unit = try self.addConstant(@intCast(pc), .{ .int32 = 1 });
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        if (update == .inc) .add else .sub,
                        @intCast(pc),
                        &.{ accumulator, unit },
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .inc_reg, .dec_reg, .post_inc_reg, .post_dec_reg => |update| {
                    const register = self.chunk.code[pc + 1];
                    const value = try readRegister(registers, register);
                    const unit = try self.addConstant(@intCast(pc), .{ .int32 = 1 });
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    const bumped = try self.addDeoptNode(
                        switch (update) {
                            .inc_reg, .post_inc_reg => .add,
                            .dec_reg, .post_dec_reg => .sub,
                            else => unreachable,
                        },
                        @intCast(pc),
                        &.{ value, unit },
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                    // §13.4 commits the bumped Number only after the checked
                    // operation succeeds. A guard exits with the pre-update
                    // frame state above, so Lantern owns coercion, BigInt,
                    // overflow, and the one observable binding write.
                    try writeRegister(registers, register, bumped);
                    // §13.4 postfix forms preserve the coerced old value as
                    // their expression result while committing the bumped
                    // value to the binding.
                    accumulator = switch (update) {
                        .post_inc_reg, .post_dec_reg => value,
                        .inc_reg, .dec_reg => bumped,
                        else => unreachable,
                    };
                },
                .add, .sub, .mul, .div => |binary| {
                    const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                    const payload: Payload = if (binary.hasBinaryTypeProfile()) blk: {
                        const profile_index = readU16(self.chunk.code, pc + 2);
                        if (profile_index >= self.chunk.inline_binary_profiles.len) {
                            return error.MalformedBytecode;
                        }
                        break :blk .{ .binary_profile = profile_index };
                    } else .none;
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        switch (binary) {
                            .add => .add,
                            .sub => .sub,
                            .mul => .mul,
                            .div => .div,
                            else => unreachable,
                        },
                        @intCast(pc),
                        &.{ lhs, accumulator },
                        payload,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .strict_eq, .strict_neq => |comparison| {
                    const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    const equal = try self.addDeoptNode(
                        .strict_eq,
                        @intCast(pc),
                        &.{ lhs, accumulator },
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                    accumulator = if (comparison == .strict_eq)
                        equal
                    else
                        try self.addNode(
                            .logical_not,
                            @intCast(pc),
                            &.{equal},
                            .none,
                        );
                },
                .logical_not => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .logical_not,
                        @intCast(pc),
                        &.{accumulator},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lt, .gt, .ge => |comparison| {
                    const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    const less_than = try self.addDeoptNode(
                        .less_than,
                        @intCast(pc),
                        switch (comparison) {
                            .gt => &.{ accumulator, lhs },
                            .lt, .ge => &.{ lhs, accumulator },
                            else => unreachable,
                        },
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                    // In the guarded Int32 lane `lhs >= rhs` is the logical
                    // negation of `lhs < rhs`; any other numeric/coercive case
                    // resumes the original `ge` bytecode before this point.
                    accumulator = if (comparison == .ge)
                        try self.addNode(.logical_not, @intCast(pc), &.{less_than}, .none)
                    else
                        less_than;
                },
                .add_smi8, .add_smi16, .add_smi => |add_smi| {
                    const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                    const immediate: i32 = switch (add_smi) {
                        .add_smi8 => readI8(self.chunk.code, pc + 2),
                        .add_smi16 => readI16(self.chunk.code, pc + 2),
                        .add_smi => readI32(self.chunk.code, pc + 2),
                        else => unreachable,
                    };
                    const rhs = try self.addConstant(@intCast(pc), .{ .int32 = immediate });
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .add,
                        @intCast(pc),
                        &.{ lhs, rhs },
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_property8, .lda_property => |load| {
                    const narrow = load == .lda_property8;
                    const key: u16 = if (narrow) self.chunk.code[pc + 1] else readU16(self.chunk.code, pc + 1);
                    const feedback_index: u16 = if (narrow) self.chunk.code[pc + 2] else readU16(self.chunk.code, pc + 3);
                    if (feedback_index >= self.chunk.inline_load_caches.len) return error.MalformedBytecode;
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_named,
                        @intCast(pc),
                        &.{accumulator},
                        .{ .named_load = .{
                            .key_constant = key,
                            .feedback_index = feedback_index,
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_property_reg8, .lda_property_reg => |load| {
                    const narrow = load == .lda_property_reg8;
                    const key: u16 = if (narrow) self.chunk.code[pc + 1] else readU16(self.chunk.code, pc + 1);
                    const register_at = pc + if (narrow) @as(usize, 2) else 3;
                    const receiver = try readRegister(registers, self.chunk.code[register_at]);
                    const feedback_index: u16 = if (narrow)
                        self.chunk.code[register_at + 1]
                    else
                        readU16(self.chunk.code, register_at + 1);
                    if (feedback_index >= self.chunk.inline_load_caches.len) return error.MalformedBytecode;
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_named,
                        @intCast(pc),
                        &.{receiver},
                        .{ .named_load = .{
                            .key_constant = key,
                            .feedback_index = feedback_index,
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .sta_property8, .sta_property => |store| {
                    const narrow = store == .sta_property8;
                    const key: u16 = if (narrow)
                        self.chunk.code[pc + 1]
                    else
                        readU16(self.chunk.code, pc + 1);
                    const register_at = pc + if (narrow) @as(usize, 2) else 3;
                    const receiver = try readRegister(registers, self.chunk.code[register_at]);
                    const feedback_index: u16 = if (narrow)
                        self.chunk.code[register_at + 1]
                    else
                        readU16(self.chunk.code, register_at + 1);
                    if (key >= self.chunk.constants.len or
                        !self.chunk.constants[key].isString() or
                        feedback_index >= self.chunk.inline_store_caches.len)
                    {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    _ = try self.addDeoptNode(
                        .store_named,
                        @intCast(pc),
                        &.{ receiver, accumulator },
                        .{ .named_store = .{
                            .key_constant = key,
                            .feedback_index = feedback_index,
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_computed8, .lda_computed => |load| {
                    const narrow = load == .lda_computed8;
                    const receiver = try readRegister(registers, self.chunk.code[pc + 1]);
                    const feedback_index: u16 = if (narrow)
                        self.chunk.code[pc + 2]
                    else
                        readU16(self.chunk.code, pc + 2);
                    if (feedback_index >= self.chunk.inline_computed_caches.len) {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_computed,
                        @intCast(pc),
                        &.{ receiver, accumulator },
                        .{ .computed_load = .{ .feedback_index = feedback_index } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .sta_computed8, .sta_computed => |store| {
                    const narrow = store == .sta_computed8;
                    const receiver = try readRegister(registers, self.chunk.code[pc + 1]);
                    const key = try readRegister(registers, self.chunk.code[pc + 2]);
                    const feedback_index: u16 = if (narrow)
                        self.chunk.code[pc + 3]
                    else
                        readU16(self.chunk.code, pc + 3);
                    if (feedback_index >= self.chunk.inline_computed_caches.len) {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    _ = try self.addDeoptNode(
                        .store_computed,
                        @intCast(pc),
                        &.{ receiver, key, accumulator },
                        .{ .computed_store = .{ .feedback_index = feedback_index } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .del_computed_property => {
                    const object_register = self.chunk.code[pc + 1];
                    const key_register = self.chunk.code[pc + 2];
                    const receiver = try readRegister(registers, object_register);
                    const key = try readRegister(registers, key_register);
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .delete_computed_property,
                        @intCast(pc),
                        &.{ receiver, key },
                        .{ .computed_delete = .{
                            .object_register = object_register,
                            .key_register = key_register,
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_this => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_this,
                        @intCast(pc),
                        &.{},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_global, .lda_global_or_undef, .lda_global8, .lda_global_or_undef8 => |load| {
                    const narrow = load == .lda_global8 or load == .lda_global_or_undef8;
                    const key: u16 = if (narrow)
                        self.chunk.code[pc + 1]
                    else
                        readU16(self.chunk.code, pc + 1);
                    const feedback_index: u16 = if (narrow)
                        self.chunk.code[pc + 2]
                    else
                        readU16(self.chunk.code, pc + 3);
                    if (key >= self.chunk.constants.len or
                        feedback_index >= self.chunk.inline_load_caches.len)
                    {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_global,
                        @intCast(pc),
                        &.{},
                        .{ .global_load = .{
                            .key_constant = key,
                            .feedback_index = feedback_index,
                            .or_undefined = load == .lda_global_or_undef or
                                load == .lda_global_or_undef8,
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .sta_global => {
                    const key = readU16(self.chunk.code, pc + 1);
                    if (key >= self.chunk.constants.len) return error.MalformedBytecode;
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    _ = try self.addDeoptNode(
                        .store_global,
                        @intCast(pc),
                        &.{accumulator},
                        .{ .global_store = .{ .key_constant = key } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_global_slot => {
                    const relative = readU32(self.chunk.code, pc + 1);
                    if (relative > std.math.maxInt(u32) - self.chunk.global_lexical_base) {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_global_slot,
                        @intCast(pc),
                        &.{},
                        .{ .global_slot = self.chunk.global_lexical_base + relative },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .sta_global_slot_init, .sta_global_slot => |store| {
                    const relative = readU32(self.chunk.code, pc + 1);
                    if (relative > std.math.maxInt(u32) - self.chunk.global_lexical_base) {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    _ = try self.addDeoptNode(
                        if (store == .sta_global_slot_init)
                            .store_global_slot_init
                        else
                            .store_global_slot,
                        @intCast(pc),
                        &.{accumulator},
                        .{ .global_slot = self.chunk.global_lexical_base + relative },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_env => {
                    const depth = self.chunk.code[pc + 1];
                    if (depth > 8) {
                        if (self.diagnostics) |out| out.unsupported_opcode = .lda_env;
                        return error.UnsupportedOp;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_environment,
                        @intCast(pc),
                        &.{},
                        .{ .environment_load = .{
                            .depth = depth,
                            .slot = self.chunk.code[pc + 2],
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .make_environment => {
                    if (!self.elide_make_environments and
                        !(pc == 0 and self.entry_environment_slots != null))
                    {
                        const live_registers = try deopt_liveness.take(
                            &deopt_live_cursor,
                            @intCast(pc),
                        );
                        _ = try self.addDeoptNode(
                            .allocate_environment,
                            @intCast(pc),
                            &.{},
                            .{ .environment_allocation = .{
                                .slot_count = self.chunk.code[pc + 1],
                            } },
                            block_index,
                            accumulator,
                            registers,
                            live_registers,
                        );
                    }
                },
                .pop_env => {
                    // A zero-slot make_environment and its paired pop are
                    // jointly unobservable. Dropping only the allocation
                    // would otherwise incorrectly pop an inherited caller
                    // environment.
                    if (!self.elide_make_environments) {
                        _ = try self.addNode(
                            .pop_environment,
                            @intCast(pc),
                            &.{},
                            .none,
                        );
                    }
                },
                .sta_env => {
                    const depth = self.chunk.code[pc + 1];
                    if (depth > 8) {
                        if (self.diagnostics) |out| out.unsupported_opcode = .sta_env;
                        return error.UnsupportedOp;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    _ = try self.addDeoptNode(
                        .store_environment,
                        @intCast(pc),
                        &.{accumulator},
                        .{ .environment_store = .{
                            .depth = depth,
                            .slot = self.chunk.code[pc + 2],
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_arguments => {
                    // The dynamic incoming-argument window is pinned in the
                    // Lantern frame; liveness intentionally does not model it
                    // as a normal bytecode register use. Publish the ordinary
                    // pre-op state before the allocation helper reads it.
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .create_unmapped_arguments_object,
                        @intCast(pc),
                        &.{},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .make_function => {
                    const template_index = readU16(self.chunk.code, pc + 1);
                    if (template_index >= self.chunk.function_templates.len) {
                        return error.MalformedBytecode;
                    }
                    const template = &self.chunk.function_templates[template_index];
                    // The ordinary synchronous subset owns no lexical-this,
                    // generator/async, or named-function-expression wrapper
                    // state. Those variants retain Lantern's canonical path.
                    if (template.is_arrow or template.is_generator or template.is_async) {
                        if (self.diagnostics) |out| out.unsupported_opcode = .make_function;
                        return error.UnsupportedOp;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .create_ordinary_function,
                        @intCast(pc),
                        &.{},
                        .{ .function_template = .{ .template_index = template_index } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .set_home => {
                    const object_register = self.chunk.code[pc + 1];
                    const home = try readRegister(registers, object_register);
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    _ = try self.addDeoptNode(
                        .set_home,
                        @intCast(pc),
                        &.{ accumulator, home },
                        .{ .home_object = .{ .object_register = object_register } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .make_object => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .create_object_literal,
                        @intCast(pc),
                        &.{},
                        .{ .object_literal = .plain },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .make_object_shape => {
                    const template_index = readU16(self.chunk.code, pc + 1);
                    if (template_index >= self.chunk.literal_shape_templates.len) {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .create_object_literal,
                        @intCast(pc),
                        &.{},
                        .{ .object_literal = .{ .shape = template_index } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .make_array_n => {
                    const base = self.chunk.code[pc + 1];
                    const count = self.chunk.code[pc + 2];
                    const base_index: usize = base;
                    const count_index: usize = count;
                    if (count == 0 or
                        count_index > Heap.element_buf_cap or
                        base_index > registers.len or
                        count_index > registers.len - base_index)
                    {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .create_dense_array_literal,
                        @intCast(pc),
                        &.{},
                        .{ .dense_array_literal = .{ .base = base, .count = count } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .make_array => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .create_array_literal,
                        @intCast(pc),
                        &.{},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .def_property => {
                    const key_constant = readU16(self.chunk.code, pc + 1);
                    const object_register = self.chunk.code[pc + 3];
                    if (key_constant >= self.chunk.constants.len or
                        !self.chunk.constants[key_constant].isString())
                    {
                        return error.MalformedBytecode;
                    }
                    const object = try readRegister(registers, object_register);
                    if (object < self.nodes.items.len and
                        self.nodes.items[object].kind == .create_array_literal)
                    {
                        const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                        _ = try self.addDeoptNode(
                            .append_dense_array_literal_element,
                            @intCast(pc),
                            &.{ object, accumulator },
                            .{ .dense_array_append = .{
                                .key_constant = key_constant,
                                .object_register = object_register,
                            } },
                            block_index,
                            accumulator,
                            registers,
                            live_registers,
                        );
                    } else if (self.isStaticObjectMethodDefinition(
                        object,
                        accumulator,
                        pc,
                        object_register,
                    )) {
                        const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                        _ = try self.addDeoptNode(
                            .define_object_method_property,
                            @intCast(pc),
                            &.{ object, accumulator },
                            .{ .object_method_property = .{
                                .key_constant = key_constant,
                                .object_register = object_register,
                            } },
                            block_index,
                            accumulator,
                            registers,
                            live_registers,
                        );
                    } else {
                        if (self.diagnostics) |out| out.unsupported_opcode = .def_property;
                        return error.UnsupportedOp;
                    }
                },
                .def_template_property => {
                    const key_constant = readU16(self.chunk.code, pc + 1);
                    const object_register = self.chunk.code[pc + 3];
                    const slot = readU16(self.chunk.code, pc + 4);
                    if (key_constant >= self.chunk.constants.len or
                        !self.chunk.constants[key_constant].isString())
                    {
                        return error.MalformedBytecode;
                    }
                    const object = try readRegister(registers, object_register);
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    _ = try self.addDeoptNode(
                        .define_template_property,
                        @intCast(pc),
                        &.{ object, accumulator },
                        .{ .template_property = .{
                            .key_constant = key_constant,
                            .object_register = object_register,
                            .slot = slot,
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .throw_ => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    _ = try self.addDeoptNode(
                        .throw_,
                        @intCast(pc),
                        &.{},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                    terminated = true;
                },
                .throw_if_hole => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .throw_if_hole,
                        @intCast(pc),
                        &.{accumulator},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .typeof_ => {
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .typeof_,
                        @intCast(pc),
                        &.{accumulator},
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .call_method8,
                .call8,
                .call0_8,
                .call1_8,
                .call2_8,
                .call3_8,
                .new_call8,
                => {
                    const site = try compactDirectCall(self.chunk, op, pc);
                    if (site.this_register) |receiver| {
                        _ = try readRegister(registers, receiver);
                    }
                    _ = try readRegister(registers, site.callee);
                    const args_end = @as(usize, site.callee) + 1 + @as(usize, site.argc);
                    if (args_end > registers.len or site.feedback_index >= self.chunk.inline_call_caches.len) {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .direct_call,
                        @intCast(pc),
                        &.{},
                        .{ .direct_call = .{ .direct = site } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .call_property8 => {
                    const site = try compactDirectPropertyCall(self.chunk, pc);
                    _ = try readRegister(registers, site.receiver);
                    const args_end = @as(usize, site.receiver) + 1 + @as(usize, site.argc);
                    if (args_end > registers.len or
                        site.load_feedback_index >= self.chunk.inline_load_caches.len or
                        site.call_feedback_index >= self.chunk.inline_call_caches.len)
                    {
                        return error.MalformedBytecode;
                    }
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .direct_call,
                        @intCast(pc),
                        &.{},
                        .{ .direct_call = .{ .property = site } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .return_ => {
                    _ = try self.addNode(.return_, @intCast(pc), &.{accumulator}, .none);
                    terminated = true;
                },
                else => {
                    if (self.diagnostics) |diagnostics| {
                        diagnostics.unsupported_opcode = op;
                    }
                    return error.UnsupportedOp;
                },
            }
            pc = next;
            if (terminated) break;
        }

        if (!terminated) {
            const successors = self.analysis.succs[block_index].items;
            if (successors.len != 1) return error.MalformedBytecode;
            _ = try self.addNode(.jump, end, &.{}, .none);
            try self.addEdge(.fallthrough, block_index, successors[0], accumulator, registers);
        }
        if (deopt_live_cursor != 0) return error.MalformedBytecode;
        self.blocks.items[block_index].node_count = try indexU32(self.nodes.items.len - body_start);
        const edge_count = self.edges.items.len - edge_start;
        if (edge_count > std.math.maxInt(u16)) return error.GraphTooLarge;
        self.blocks.items[block_index].edge_count = @intCast(edge_count);
    }

    fn addConstant(self: *Builder, pc: u32, immediate: Immediate) !ValueId {
        return self.addNode(.constant, pc, &.{}, .{ .immediate = immediate });
    }

    /// The native helper may bypass the generic `CreateDataPropertyOrThrow`
    /// only when bytecode dataflow proves a fresh ordinary object and the
    /// immediately preceding operation installed the same closure's
    /// `[[HomeObject]]`. Everything else remains Lantern-owned so duplicate
    /// data properties, accessors, computed keys, spreads, and `__proto__`
    /// retain their existing semantics.
    fn isStaticObjectMethodDefinition(
        self: *const Builder,
        object: ValueId,
        accumulator: ValueId,
        pc: usize,
        object_register: u8,
    ) bool {
        if (object >= self.nodes.items.len or accumulator >= self.nodes.items.len or
            self.nodes.items.len == 0 or pc < 2)
        {
            return false;
        }
        const object_node = self.nodes.items[object];
        if (object_node.kind != .create_object_literal or
            object_node.payload != .object_literal or
            object_node.payload.object_literal != .plain or
            self.nodes.items[accumulator].kind != .create_ordinary_function)
        {
            return false;
        }
        const home_node = self.nodes.items[self.nodes.items.len - 1];
        if (home_node.kind != .set_home or
            @as(usize, @intCast(home_node.bytecode_offset)) != pc - 2 or
            home_node.input_count != 2 or home_node.payload != .home_object)
        {
            return false;
        }
        const home_inputs = self.inputs.items[home_node.input_start..][0..home_node.input_count];
        return home_inputs[0] == accumulator and home_inputs[1] == object and
            home_node.payload.home_object.object_register == object_register;
    }

    fn addNode(
        self: *Builder,
        kind: NodeKind,
        pc: u32,
        node_inputs: []const ValueId,
        payload: Payload,
    ) !ValueId {
        if (node_inputs.len > std.math.maxInt(u16)) return error.GraphTooLarge;
        const id = try indexU32(self.nodes.items.len);
        const input_start = try indexU32(self.inputs.items.len);
        try self.inputs.appendSlice(self.allocator, node_inputs);
        try self.nodes.append(self.allocator, .{
            .kind = kind,
            .bytecode_offset = pc,
            .input_start = input_start,
            .input_count = @intCast(node_inputs.len),
            .payload = payload,
        });
        return id;
    }

    fn addDeoptNode(
        self: *Builder,
        kind: NodeKind,
        pc: u32,
        node_inputs: []const ValueId,
        payload: Payload,
        block_index: usize,
        accumulator: ValueId,
        registers: []const ValueId,
        live_registers: []const u8,
    ) !ValueId {
        const frame_state = try self.addFrameState(
            block_index,
            pc,
            accumulator,
            registers,
            live_registers,
        );
        const id = try self.addNode(kind, pc, node_inputs, payload);
        self.nodes.items[id].frame_state = frame_state;
        return id;
    }

    fn addFrameState(
        self: *Builder,
        block_index: usize,
        pc: u32,
        accumulator: ValueId,
        registers: []const ValueId,
        live_registers: []const u8,
    ) !FrameStateId {
        if (accumulator == invalid_value or accumulator >= self.nodes.items.len) {
            return error.MalformedBytecode;
        }
        const state_id = try indexU32(self.frame_states.items.len);
        const slot_start = try indexU32(self.frame_slots.items.len);
        for (live_registers) |register| {
            if (register >= registers.len) return error.MalformedBytecode;
            const value = registers[register];
            if (value >= self.nodes.items.len) return error.MalformedBytecode;
            try self.frame_slots.append(self.allocator, .{
                .register = register,
                .value = value,
            });
        }
        try self.frame_states.append(self.allocator, .{
            .block = try indexU32(block_index),
            .bytecode_offset = pc,
            .accumulator = accumulator,
            .slot_start = slot_start,
            .slot_count = @intCast(live_registers.len),
        });
        return state_id;
    }

    fn computeDeoptLiveness(
        self: *Builder,
        block_index: usize,
        start: u32,
        end: u32,
    ) !DeoptLiveness {
        var result: DeoptLiveness = .{};
        errdefer result.deinit(self.allocator);
        var offsets: std.ArrayListUnmanaged(u32) = .empty;
        defer offsets.deinit(self.allocator);

        var pc: usize = start;
        while (pc < end) {
            const op: Op = @enumFromInt(self.chunk.code[pc]);
            const next = pc + 1 + Op.operandSize(op);
            if (next > end) return error.MalformedBytecode;
            try offsets.append(self.allocator, @intCast(pc));
            pc = next;
        }

        var live = try std.DynamicBitSet.initEmpty(self.allocator, self.chunk.register_count);
        defer live.deinit();
        live.setUnion(self.analysis.live_out[block_index]);
        var offset_index = offsets.items.len;
        while (offset_index > 0) {
            offset_index -= 1;
            const offset = offsets.items[offset_index];
            const op: Op = @enumFromInt(self.chunk.code[offset]);
            liveness.applyReverseEffect(
                &live,
                liveness.effectOf(op, self.chunk.code, offset),
                self.chunk.register_count,
            );
            if (!self.isDeoptCandidate(op, offset)) continue;

            const register_start = try indexU32(result.registers.items.len);
            var iterator = live.iterator(.{});
            while (iterator.next()) |register| {
                if (register > std.math.maxInt(u8)) return error.GraphTooLarge;
                try result.registers.append(self.allocator, @intCast(register));
            }
            const register_count = result.registers.items.len - register_start;
            if (register_count > std.math.maxInt(u16)) return error.GraphTooLarge;
            try result.points.append(self.allocator, .{
                .bytecode_offset = offset,
                .register_start = register_start,
                .register_count = @intCast(register_count),
            });
        }
        return result;
    }

    fn addEdge(
        self: *Builder,
        kind: EdgeKind,
        from: usize,
        to: usize,
        accumulator: ValueId,
        registers: []const ValueId,
    ) !void {
        for (self.edges.items) |edge| {
            if (edge.kind == kind and edge.from == from and edge.to == to) return;
        }
        const target = self.blocks.items[to];
        const argument_start = try indexU32(self.inputs.items.len);
        const target_params = self.params.items[target.param_start..][0..target.param_count];
        for (target_params) |param| {
            const value = switch (param.role) {
                .accumulator => accumulator,
                .register => |register| try readRegister(registers, register),
            };
            if (value == invalid_value) return error.MalformedBytecode;
            try self.inputs.append(self.allocator, value);
        }
        try self.edges.append(self.allocator, .{
            .kind = kind,
            .from = from,
            .to = to,
            .argument_start = argument_start,
            .argument_count = target.param_count,
        });
    }

    fn isDeoptCandidate(self: *const Builder, op: Op, offset: u32) bool {
        return switch (op) {
            .make_environment => !self.elide_make_environments and
                !(offset == 0 and self.entry_environment_slots != null),
            .sta_env,
            .sta_computed,
            .sta_computed8,
            .del_computed_property,
            .add,
            .sub,
            .to_numeric,
            .to_string,
            .require_object_coercible,
            .inc,
            .dec,
            .inc_reg,
            .dec_reg,
            .post_inc_reg,
            .post_dec_reg,
            .mul,
            .div,
            .strict_eq,
            .strict_neq,
            .lt,
            .gt,
            .ge,
            .logical_not,
            .add_smi,
            .add_smi8,
            .add_smi16,
            .jmp_if_false,
            .jmp_if_false8,
            .jmp_if_false32,
            .jmp_if_true,
            .jmp_if_true8,
            .jmp_if_true32,
            .jmp_if_nullish,
            .jmp_if_nullish8,
            .jmp_if_nullish32,
            .jmp_if_strict_eq,
            .jmp_if_strict_eq8,
            .jmp_if_strict_eq32,
            .jmp_if_strict_neq,
            .jmp_if_strict_neq8,
            .jmp_if_strict_neq32,
            .jmp_if_not_lt,
            .jmp_if_not_lt8,
            .jmp_if_not_lt32,
            .jmp_if_not_le,
            .jmp_if_not_le8,
            .jmp_if_not_le32,
            .jmp_if_not_gt,
            .jmp_if_not_gt8,
            .jmp_if_not_gt32,
            .jmp_if_not_ge,
            .jmp_if_not_ge8,
            .jmp_if_not_ge32,
            .lda_property,
            .lda_property8,
            .lda_property_reg,
            .lda_property_reg8,
            .sta_property,
            .sta_property8,
            .lda_computed,
            .lda_computed8,
            .lda_this,
            .lda_global,
            .lda_global_or_undef,
            .lda_global8,
            .lda_global_or_undef8,
            .sta_global,
            .lda_global_slot,
            .sta_global_slot_init,
            .sta_global_slot,
            .lda_env,
            .lda_arguments,
            .make_function,
            .set_home,
            .make_object,
            .make_object_shape,
            .make_array,
            .make_array_n,
            .def_property,
            .def_template_property,
            .throw_,
            .throw_if_hole,
            .typeof_,
            .call_method8,
            .call8,
            .call0_8,
            .call1_8,
            .call2_8,
            .call3_8,
            .new_call8,
            .call_property8,
            .tail_call,
            .tail_call_method,
            => true,
            else => false,
        };
    }
};

fn indexU32(index: usize) !u32 {
    if (index > std.math.maxInt(u32)) return error.GraphTooLarge;
    return @intCast(index);
}

fn readRegister(registers: []const ValueId, register: u8) !ValueId {
    if (register >= registers.len) return error.MalformedBytecode;
    const value = registers[register];
    if (value == invalid_value) return error.MalformedBytecode;
    return value;
}

/// Decode compact call and construct forms into their one shared handoff shape.
/// Wide forms remain intentionally unsupported until their larger operand
/// indexes get dedicated coverage.
fn compactDirectCall(chunk: *const Chunk, op: Op, pc: usize) !DirectCall {
    const code = chunk.code;
    return switch (op) {
        .call_method8 => .{
            .kind = .call,
            .this_register = code[pc + 1],
            .callee = code[pc + 2],
            .argc = code[pc + 3],
            .feedback_index = code[pc + 4],
        },
        .call8 => .{
            .kind = .call,
            .this_register = null,
            .callee = code[pc + 1],
            .argc = code[pc + 2],
            .feedback_index = code[pc + 3],
        },
        .call0_8, .call1_8, .call2_8, .call3_8 => blk: {
            const argc: u8 = switch (op) {
                .call0_8 => 0,
                .call1_8 => 1,
                .call2_8 => 2,
                .call3_8 => 3,
                else => return error.MalformedBytecode,
            };
            break :blk .{
                .kind = .call,
                .this_register = null,
                .callee = code[pc + 1],
                .argc = argc,
                .feedback_index = code[pc + 2],
            };
        },
        .new_call8 => .{
            .kind = .construct,
            .this_register = null,
            .callee = code[pc + 1],
            .argc = code[pc + 2],
            .feedback_index = code[pc + 3],
        },
        else => error.MalformedBytecode,
    };
}

/// Decode the narrow fused property-call form. Wide `call_property` stays
/// outside this first slice so every operand used by native code is compactly
/// covered by the regression matrix.
fn compactDirectPropertyCall(chunk: *const Chunk, pc: usize) !DirectPropertyCall {
    const code = chunk.code;
    return .{
        .receiver = code[pc + 2],
        .argc = code[pc + 3],
        .load_feedback_index = code[pc + 4],
        .call_feedback_index = code[pc + 5],
    };
}

fn writeRegister(registers: []ValueId, register: u8, value: ValueId) !void {
    if (register >= registers.len or value == invalid_value) return error.MalformedBytecode;
    registers[register] = value;
}

fn readI8(code: []const u8, at: usize) i32 {
    return @as(i8, @bitCast(code[at]));
}

fn readI16(code: []const u8, at: usize) i32 {
    return std.mem.readInt(i16, code[at..][0..2], .little);
}

fn readI32(code: []const u8, at: usize) i32 {
    return std.mem.readInt(i32, code[at..][0..4], .little);
}

fn readU16(code: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, code[at..][0..2], .little);
}

fn readU32(code: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, code[at..][0..4], .little);
}
