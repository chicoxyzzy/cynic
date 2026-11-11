//! Language-neutral SSA experiment. Cross-block values use block
//! arguments; there are no implicit heap effects or language-specific nodes.
pub const max_values = 2048;
pub const max_nodes = 4096;
pub const max_blocks = 256;
/// Physical 64-bit words per argument/result/edge/capture payload.
pub const max_arguments = 64;
pub const max_memories = 64;
pub const Type = enum {
    i32,
    i64,
    f32,
    f64,
    v128,

    pub fn words(self: Type) usize {
        return if (self == .v128) 2 else 1;
    }
};
pub const VectorLane = enum {
    i8x16,
    i16x8,
    i32x4,
    i64x2,
    f32x4,
    f64x2,

    pub fn bytes(self: VectorLane) usize {
        return switch (self) {
            .i8x16 => 1,
            .i16x8 => 2,
            .i32x4, .f32x4 => 4,
            .i64x2, .f64x2 => 8,
        };
    }

    pub fn count(self: VectorLane) usize {
        return 16 / self.bytes();
    }

    pub fn scalarType(self: VectorLane) Type {
        return switch (self) {
            .i8x16, .i16x8, .i32x4 => .i32,
            .i64x2 => .i64,
            .f32x4 => .f32,
            .f64x2 => .f64,
        };
    }
};

pub fn wordCount(types: []const Type) usize {
    var count: usize = 0;
    for (types) |ty| count += ty.words();
    return count;
}
pub const Value = u32;
pub const Op = enum {
    constant,
    add,
    sub,
    mul,
    div_s,
    div_u,
    rem_s,
    rem_u,
    bit_and,
    bit_or,
    bit_xor,
    vector_add,
    vector_sub,
    vector_mul,
    vector_fsub,
    vector_fmul,
    vector_fdiv,
    vector_fmin,
    vector_fmax,
    /// Pseudo min/max retain the first input bits on ties and unordered inputs.
    vector_fpmin,
    vector_fpmax,
    vector_fabs,
    vector_fneg,
    vector_fsqrt,
    vector_fceil,
    vector_ffloor,
    vector_ftrunc,
    vector_fnearest,
    /// Float lane shape is the destination; source lanes are i32 (low two for f64).
    vector_convert_s,
    vector_convert_u,
    /// Float lane shape is the source; destination is i32 with unused lanes zeroed.
    vector_trunc_sat_s,
    vector_trunc_sat_u,
    vector_promote_f32,
    vector_demote_f64,
    /// Source lane width; immediate selects low (0) or high (1) half.
    vector_extmul_s,
    vector_extmul_u,
    /// Adjacent signed i16 products, summed with i32 wrapping.
    vector_dot_s,
    /// Adjacent signed i8 products, summed with i16 saturation.
    vector_dot_sat_s,
    vector_q15mulr_sat_s,
    vector_add_sat_s,
    vector_add_sat_u,
    vector_sub_sat_s,
    vector_sub_sat_u,
    vector_abs,
    vector_neg,
    vector_popcnt,
    vector_min_s,
    vector_min_u,
    vector_max_s,
    vector_max_u,
    vector_avgr_u,
    // The scalar i32 count is reduced modulo the lane bit width.
    vector_shl,
    vector_shr_s,
    vector_shr_u,
    vector_splat,
    /// Narrow integer lanes are zero-extended; signed extension is explicit.
    vector_extract,
    vector_replace,
    /// Sixteen byte selectors in immediate/immediate_hi, each in [0, 32).
    vector_shuffle,
    /// Byte indices outside [0, 16) produce zero.
    vector_swizzle,
    /// Lane shape describes the source; immediate selects low (0) or high (1).
    vector_extend_s,
    vector_extend_u,
    /// Lane shape describes the destination; both inputs are signed lanes.
    vector_narrow_s,
    vector_narrow_u,
    /// Extend source lanes, then add adjacent pairs into double-width lanes.
    vector_pairwise_add_s,
    vector_pairwise_add_u,
    /// True lanes contain all ones, not the scalar Boolean value one.
    vector_eq,
    vector_ne,
    vector_lt_s,
    vector_lt_u,
    vector_le_s,
    vector_le_u,
    vector_flt,
    vector_fle,
    /// Reductions return i32; any_true is independent of lane shape.
    vector_any_true,
    vector_all_true,
    vector_bitmask,
    shl,
    shr_s,
    shr_u,
    rotl,
    rotr,
    clz,
    ctz,
    popcnt,
    sext8,
    sext16,
    sext32,
    eq,
    ne,
    lt_s,
    lt_u,
    gt_s,
    gt_u,
    le_s,
    le_u,
    ge_s,
    ge_u,
    sext_i32,
    zext_i32,
    trunc_i64,
    fadd,
    fsub,
    fmul,
    fdiv,
    fmin,
    fmax,
    fcopysign,
    fabs,
    fneg,
    fsqrt,
    fceil,
    ffloor,
    ftrunc,
    fnearest,
    convert_s,
    convert_u,
    trunc_s,
    trunc_u,
    trunc_sat_s,
    trunc_sat_u,
    feq,
    fne,
    flt,
    fgt,
    fle,
    fge,
    reinterpret,
    promote_f32,
    demote_f64,
    load,
    store,
    /// Sequentially consistent integer accesses. Narrow results zero-extend.
    atomic_load,
    atomic_store,
    atomic_add,
    atomic_sub,
    atomic_and,
    atomic_or,
    atomic_xor,
    atomic_exchange,
    atomic_compare_exchange,
    atomic_fence,
    /// Current byte length of the view selected by Node.immediate, as i64.
    memory_length,
    call,
    guard,
};
pub const MemoryWidth = enum(u8) {
    byte = 1,
    half = 2,
    word = 4,
    double = 8,
    quad = 16,

    pub fn bytes(self: MemoryWidth) usize {
        return @backingInt(self);
    }
};
/// Bounded little-endian byte access. Region IDs select frontend-provided
/// views; they are not non-aliasing promises. Offset addition never wraps.
pub const MemoryAccess = struct { region: u32 = 0, width: MemoryWidth, offset: u64 = 0, signed: bool = false };
/// An opaque frontend-owned recovery key and values captured at this exact
/// point. Guards are ordered effects, not removable unused computations.
pub const SideExit = struct { id: u32, values: []const Value };
/// Symbolic runtime call. The frontend owns the target and root interpretation;
/// snapshots are read-only because the current collector does not move objects.
pub const Call = struct {
    target: u64,
    arguments: []const Value,
    parameter_types: []const Type,
    results: []const Value,
    result_types: []const Type,
    /// Raw host callbacks see caller controls; language helpers keep strict FP.
    fp_mode: enum { host, strict } = .host,
    safepoint: SideExit,
};
pub const TrapReason = enum(u32) {
    division_by_zero = 1,
    integer_overflow = 2,
    unreachable_code = 3,
    invalid_conversion = 4,
    memory_out_of_bounds = 5,
    unaligned_atomic = 6,

    pub fn toError(self: TrapReason) error{ IntegerDivideByZero, IntegerOverflow, Unreachable, InvalidConversionToInteger, OutOfBoundsMemoryAccess, UnalignedAtomicAccess } {
        return switch (self) {
            .division_by_zero => error.IntegerDivideByZero,
            .integer_overflow => error.IntegerOverflow,
            .unreachable_code => error.Unreachable,
            .invalid_conversion => error.InvalidConversionToInteger,
            .memory_out_of_bounds => error.OutOfBoundsMemoryAccess,
            .unaligned_atomic => error.UnalignedAtomicAccess,
        };
    }
};
/// The location is opaque to the backend; Wasm uses an instruction byte offset.
pub const Trap = struct { reason: TrapReason, site: u32 };
pub const Node = struct {
    op: Op,
    out: ?Value = null,
    lhs: Value = 0,
    rhs: Value = 0,
    /// Compare-exchange alone: lhs is address, rhs is replacement.
    expected: ?Value = null,
    immediate: u64 = 0,
    immediate_hi: u64 = 0,
    vector_lane: ?VectorLane = null,
    exit: ?SideExit = null,
    trap_site: ?u32 = null,
    memory: ?MemoryAccess = null,
    call: ?Call = null,

    pub fn outputs(self: Node) OutputIterator {
        return if (self.call) |call| .{ .many = call.results } else .{ .single = self.out };
    }
};
pub const OutputIterator = struct {
    single: ?Value = null,
    many: []const Value = &.{},

    pub fn next(self: *OutputIterator) ?Value {
        if (self.single) |value| {
            self.single = null;
            return value;
        }
        if (self.many.len == 0) return null;
        const value = self.many[0];
        self.many = self.many[1..];
        return value;
    }
};
pub const Edge = struct { target: u32, args: []const Value };
/// The frontend owns exception state and catchability. Call results are only
/// available to the normal successor; the exceptional edge uses pre-call values.
pub const Invoke = struct { site: u32, call: Call, normal: Edge, exceptional: Edge };
pub const Terminator = union(enum) {
    trap: Trap,
    /// Unconditional transfer to an opaque frontend-owned continuation.
    exit: SideExit,
    return_: []const Value,
    jump: Edge,
    branch: struct { condition: Value, taken: Edge, fallthrough: Edge },
    invoke: Invoke,
};
pub const Block = struct {
    params: []const Value,
    nodes: []const Node = &.{},
    terminator: Terminator = .{ .return_ = &.{} },
};

pub const Graph = struct {
    types: []const Type,
    blocks: []const Block,
    argument_types: []const Type,
    result_types: []const Type,
    memory_count: u32 = 0,

    pub fn verify(self: Graph) !void {
        if (self.types.len > max_values or self.blocks.len > max_blocks or
            self.argument_types.len > max_arguments or self.result_types.len > max_arguments or self.memory_count > max_memories) return error.PrototypeLimit;
        if (wordCount(self.argument_types) > max_arguments or wordCount(self.result_types) > max_arguments) return error.PrototypeLimit;
        if (self.blocks.len == 0 or self.blocks[0].params.len != self.argument_types.len)
            return error.InvalidGraph;
        var defined: [max_values]bool = @splat(false);
        var node_count: usize = 0;
        for (self.blocks, 0..) |block, block_index| {
            if (block.params.len > max_arguments) return error.PrototypeLimit;
            if (block.nodes.len > max_nodes - node_count) return error.PrototypeLimit;
            node_count += block.nodes.len;
            var available: [max_values]bool = @splat(false);
            for (block.params, 0..) |param, i| {
                try self.define(param, &defined, &available);
                if (block_index == 0 and self.types[param] != self.argument_types[i]) return error.InvalidGraph;
            }
            if (self.valueWords(block.params) > max_arguments) return error.PrototypeLimit;
            for (block.nodes) |node| {
                if (hasVectorLane(node.op) != (node.vector_lane != null)) return error.InvalidGraph;
                if (node.immediate_hi != 0 and node.op != .vector_shuffle and (node.op != .constant or node.out == null or node.out.? >= self.types.len or self.types[node.out.?] != .v128)) return error.InvalidGraph;
                if (mayTrap(node.op) != (node.trap_site != null)) return error.InvalidGraph;
                if (isMemoryOp(node.op) != (node.memory != null)) return error.InvalidGraph;
                if ((node.op == .call) != (node.call != null)) return error.InvalidGraph;
                if ((node.op == .atomic_compare_exchange) != (node.expected != null)) return error.InvalidGraph;
                if (node.op == .guard) {
                    if (node.out != null) return error.InvalidGraph;
                    try self.use(node.lhs, &available);
                    if (self.types[node.lhs] != .i32) return error.InvalidGraph;
                    const side_exit = node.exit orelse return error.InvalidGraph;
                    if (side_exit.values.len > max_arguments) return error.PrototypeLimit;
                    for (side_exit.values) |value| try self.use(value, &available);
                    if (self.valueWords(side_exit.values) > max_arguments) return error.PrototypeLimit;
                    continue;
                }
                if (node.exit != null) return error.InvalidGraph;
                if (node.op == .atomic_fence) {
                    if (node.out != null) return error.InvalidGraph;
                    continue;
                }
                if (node.call) |call| {
                    if (node.out != null) return error.InvalidGraph;
                    try self.verifyCallInputs(call, &available);
                    try self.defineCallResults(call, &defined, &available);
                    continue;
                }
                if (node.memory) |access| {
                    if (access.region >= self.memory_count) return error.InvalidGraph;
                    try self.use(node.lhs, &available);
                    if (!isInteger(self.types[node.lhs])) return error.InvalidGraph;
                    if (isAtomicAccess(node.op)) {
                        const value = if (node.op == .atomic_load) node.out orelse return error.InvalidGraph else node.rhs;
                        if (value >= self.types.len) return error.InvalidGraph;
                        const ty = self.types[value];
                        if (!isInteger(ty) or access.signed or access.width.bytes() > (if (ty == .i32) @as(usize, 4) else 8)) return error.InvalidGraph;
                        if (node.op != .atomic_load) try self.use(value, &available);
                        if (node.expected) |expected| {
                            try self.use(expected, &available);
                            if (self.types[expected] != ty) return error.InvalidGraph;
                        }
                        if (node.op == .atomic_store) {
                            if (node.out != null) return error.InvalidGraph;
                        } else {
                            const out = node.out orelse return error.InvalidGraph;
                            try self.define(out, &defined, &available);
                            if (self.types[out] != ty) return error.InvalidGraph;
                        }
                        continue;
                    }
                    const value = if (node.op == .load) node.out orelse return error.InvalidGraph else node.rhs;
                    if (value >= self.types.len) return error.InvalidGraph;
                    const ty = self.types[value];
                    const width: usize = if (ty == .v128) 16 else if (is32(ty)) 4 else 8;
                    if (access.width.bytes() > width or
                        (!isInteger(ty) and access.width.bytes() != width) or
                        (access.signed and (node.op == .store or !isInteger(ty) or access.width.bytes() == width))) return error.InvalidGraph;
                    if (node.op == .load) {
                        try self.define(value, &defined, &available);
                    } else {
                        if (node.out != null) return error.InvalidGraph;
                        try self.use(value, &available);
                    }
                    continue;
                }
                const out = node.out orelse return error.InvalidGraph;
                if (out >= self.types.len) return error.InvalidGraph;
                const out_type = self.types[out];
                if (node.op == .constant) {
                    if (normalize(out_type, node.immediate) != node.immediate) return error.InvalidGraph;
                } else if (node.op == .memory_length) {
                    if (out_type != .i64 or node.immediate >= self.memory_count) return error.InvalidGraph;
                } else if (conversionTypes(node.op)) |conversion| {
                    try self.use(node.lhs, &available);
                    if (self.types[node.lhs] != conversion.input or out_type != conversion.output) return error.InvalidGraph;
                } else if (isNumericConversion(node.op)) {
                    try self.use(node.lhs, &available);
                    const to_float = node.op == .convert_s or node.op == .convert_u;
                    if (self.types[node.lhs] == .v128 or out_type == .v128 or isFloat(self.types[node.lhs]) == to_float or isFloat(out_type) != to_float) return error.InvalidGraph;
                } else if (node.op == .reinterpret) {
                    try self.use(node.lhs, &available);
                    const source = self.types[node.lhs];
                    if (source == .v128 or out_type == .v128 or isFloat(source) == isFloat(out_type) or is32(source) != is32(out_type)) return error.InvalidGraph;
                } else if (isVectorOp(node.op)) {
                    try self.use(node.lhs, &available);
                    const scalar = if (node.vector_lane) |lane| lane.scalarType() else Type.v128;
                    if (self.types[node.lhs] != (if (node.op == .vector_splat) scalar else .v128)) return error.InvalidGraph;
                    if (out_type != (if (isVectorReduction(node.op)) Type.i32 else if (node.op == .vector_extract) scalar else .v128)) return error.InvalidGraph;
                    if (inputCount(node.op) == 2) {
                        try self.use(node.rhs, &available);
                        if (self.types[node.rhs] != (if (isVectorShift(node.op)) Type.i32 else if (node.op == .vector_replace) scalar else .v128)) return error.InvalidGraph;
                    }
                    if (isVectorFloat(node.op)) {
                        if (!isFloat(scalar) or node.immediate != 0) return error.InvalidGraph;
                        if (node.op == .vector_promote_f32 and node.vector_lane != .f32x4) return error.InvalidGraph;
                        if (node.op == .vector_demote_f64 and node.vector_lane != .f64x2) return error.InvalidGraph;
                    } else if (isVectorInteger(node.op)) {
                        const extended = node.op == .vector_extmul_s or node.op == .vector_extmul_u;
                        if (node.immediate > @as(u64, if (extended) 1 else 0) or isFloat(scalar)) return error.InvalidGraph;
                        const width = node.vector_lane.?.bytes();
                        switch (node.op) {
                            .vector_extmul_s, .vector_extmul_u => if (width > 4) return error.InvalidGraph,
                            .vector_dot_s, .vector_q15mulr_sat_s => if (width != 2) return error.InvalidGraph,
                            .vector_dot_sat_s => if (width != 1) return error.InvalidGraph,
                            .vector_mul => if (width == 1) return error.InvalidGraph,
                            .vector_add_sat_s, .vector_add_sat_u, .vector_sub_sat_s, .vector_sub_sat_u, .vector_avgr_u => if (width > 2) return error.InvalidGraph,
                            .vector_min_s, .vector_min_u, .vector_max_s, .vector_max_u => if (width > 4) return error.InvalidGraph,
                            .vector_popcnt => if (width != 1) return error.InvalidGraph,
                            else => {},
                        }
                    } else if (isVectorComparison(node.op)) {
                        const floating = isFloat(scalar);
                        if (node.immediate != 0) return error.InvalidGraph;
                        if (node.op != .vector_eq and node.op != .vector_ne and floating != (node.op == .vector_flt or node.op == .vector_fle)) return error.InvalidGraph;
                    } else if (isVectorReduction(node.op)) {
                        if (node.immediate != 0 or isFloat(scalar)) return error.InvalidGraph;
                    } else if (node.op == .vector_extend_s or node.op == .vector_extend_u) {
                        if (node.immediate > 1 or (node.vector_lane != .i8x16 and node.vector_lane != .i16x8 and node.vector_lane != .i32x4)) return error.InvalidGraph;
                    } else if (node.op == .vector_narrow_s or node.op == .vector_narrow_u or node.op == .vector_pairwise_add_s or node.op == .vector_pairwise_add_u) {
                        if (node.immediate != 0 or (node.vector_lane != .i8x16 and node.vector_lane != .i16x8)) return error.InvalidGraph;
                    } else if (node.op == .vector_extract or node.op == .vector_replace) {
                        if (node.immediate >= node.vector_lane.?.count()) return error.InvalidGraph;
                    } else if (node.op == .vector_shuffle) {
                        for ([_]u64{ node.immediate, node.immediate_hi }) |word| for (0..8) |byte| {
                            if ((word >> @as(u6, @intCast(byte * 8))) & 255 >= 32) return error.InvalidGraph;
                        };
                    } else if (node.immediate != 0) return error.InvalidGraph;
                } else {
                    try self.use(node.lhs, &available);
                    const input_type = self.types[node.lhs];
                    if (input_type == .v128 and node.op != .bit_and and node.op != .bit_or and node.op != .bit_xor) return error.InvalidGraph;
                    if (node.op == .sext32 and input_type != .i64) return error.InvalidGraph;
                    if (isFloatOp(node.op) != isFloat(input_type)) return error.InvalidGraph;
                    if (inputCount(node.op) == 2) {
                        try self.use(node.rhs, &available);
                        if (input_type != self.types[node.rhs]) return error.InvalidGraph;
                    }
                    const expected = if (isComparison(node.op)) Type.i32 else input_type;
                    if (out_type != expected) return error.InvalidGraph;
                }
                try self.define(out, &defined, &available);
            }
            switch (block.terminator) {
                .trap => {},
                .exit => |side_exit| {
                    if (side_exit.values.len > max_arguments) return error.PrototypeLimit;
                    for (side_exit.values) |value| try self.use(value, &available);
                    if (self.valueWords(side_exit.values) > max_arguments) return error.PrototypeLimit;
                },
                .return_ => |values| {
                    if (values.len != self.result_types.len) return error.InvalidGraph;
                    for (values, self.result_types) |value, ty| {
                        try self.use(value, &available);
                        if (self.types[value] != ty) return error.InvalidGraph;
                    }
                },
                .jump => |edge| try self.verifyEdge(edge, &available),
                .branch => |branch| {
                    try self.use(branch.condition, &available);
                    if (self.types[branch.condition] != .i32) return error.InvalidGraph;
                    try self.verifyEdge(branch.taken, &available);
                    try self.verifyEdge(branch.fallthrough, &available);
                },
                .invoke => |invocation| {
                    try self.verifyCallInputs(invocation.call, &available);
                    try self.verifyEdge(invocation.exceptional, &available);
                    try self.defineCallResults(invocation.call, &defined, &available);
                    try self.verifyEdge(invocation.normal, &available);
                },
            }
        }
        for (defined[0..self.types.len]) |present| if (!present) return error.InvalidGraph;
    }

    fn define(self: Graph, value: Value, defined: *[max_values]bool, available: *[max_values]bool) !void {
        if (value >= self.types.len or defined[value]) return error.InvalidGraph;
        defined[value] = true;
        available[value] = true;
    }

    fn verifyCallInputs(self: Graph, call: Call, available: *const [max_values]bool) !void {
        if (call.arguments.len > max_arguments or call.results.len > max_arguments or call.result_types.len > max_arguments or call.safepoint.values.len > max_arguments) return error.PrototypeLimit;
        if (call.arguments.len != call.parameter_types.len or call.results.len != call.result_types.len) return error.InvalidGraph;
        for (call.arguments, call.parameter_types) |value, ty| {
            try self.use(value, available);
            if (self.types[value] != ty) return error.InvalidGraph;
        }
        for (call.safepoint.values) |value| try self.use(value, available);
        if (wordCount(call.parameter_types) > max_arguments or wordCount(call.result_types) > max_arguments or self.valueWords(call.safepoint.values) > max_arguments) return error.PrototypeLimit;
    }

    fn defineCallResults(self: Graph, call: Call, defined: *[max_values]bool, available: *[max_values]bool) !void {
        for (call.results, call.result_types) |out, ty| {
            try self.define(out, defined, available);
            if (self.types[out] != ty) return error.InvalidGraph;
        }
    }

    /// Only call after validating every value ID.
    pub fn valueWords(self: Graph, values: []const Value) usize {
        var count: usize = 0;
        for (values) |value| count += self.types[value].words();
        return count;
    }

    fn use(self: Graph, value: Value, available: *const [max_values]bool) !void {
        if (value >= self.types.len or !available[value]) return error.InvalidGraph;
    }

    fn verifyEdge(self: Graph, edge: Edge, available: *const [max_values]bool) !void {
        if (edge.target == 0 or edge.target >= self.blocks.len) return error.InvalidGraph;
        const params = self.blocks[edge.target].params;
        if (edge.args.len != params.len) return error.InvalidGraph;
        for (edge.args, params) |arg, param| {
            try self.use(arg, available);
            if (param >= self.types.len or self.types[arg] != self.types[param]) return error.InvalidGraph;
        }
    }
};

pub fn normalize(ty: Type, value: u64) u64 {
    return if (is32(ty)) @as(u32, @truncate(value)) else value;
}

pub fn is32(ty: Type) bool {
    return ty == .i32 or ty == .f32;
}

pub fn isFloat(ty: Type) bool {
    return ty == .f32 or ty == .f64;
}

pub fn isInteger(ty: Type) bool {
    return ty == .i32 or ty == .i64;
}

pub fn conversionTypes(op: Op) ?struct { input: Type, output: Type } {
    return switch (op) {
        .sext_i32, .zext_i32 => .{ .input = .i32, .output = .i64 },
        .trunc_i64 => .{ .input = .i64, .output = .i32 },
        .promote_f32 => .{ .input = .f32, .output = .f64 },
        .demote_f64 => .{ .input = .f64, .output = .f32 },
        else => null,
    };
}

pub fn isFloatOp(op: Op) bool {
    return switch (op) {
        .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcopysign, .fabs, .fneg, .fsqrt, .fceil, .ffloor, .ftrunc, .fnearest, .feq, .fne, .flt, .fgt, .fle, .fge, .promote_f32, .demote_f64 => true,
        else => false,
    };
}

pub fn isNumericConversion(op: Op) bool {
    return switch (op) {
        .convert_s, .convert_u, .trunc_s, .trunc_u, .trunc_sat_s, .trunc_sat_u => true,
        else => false,
    };
}

pub fn isMemoryOp(op: Op) bool {
    return op == .load or op == .store or isAtomicAccess(op);
}

pub fn isAtomicAccess(op: Op) bool {
    return switch (op) {
        .atomic_load, .atomic_store, .atomic_add, .atomic_sub, .atomic_and, .atomic_or, .atomic_xor, .atomic_exchange, .atomic_compare_exchange => true,
        else => false,
    };
}

pub fn isComparison(op: Op) bool {
    return switch (op) {
        .eq, .ne, .lt_s, .lt_u, .gt_s, .gt_u, .le_s, .le_u, .ge_s, .ge_u, .feq, .fne, .flt, .fgt, .fle, .fge => true,
        else => false,
    };
}

pub fn inputCount(op: Op) u2 {
    return switch (op) {
        .vector_fsub, .vector_fmul, .vector_fdiv, .vector_fmin, .vector_fmax, .vector_fpmin, .vector_fpmax => 2,
        .vector_fabs, .vector_fneg, .vector_fsqrt, .vector_fceil, .vector_ffloor, .vector_ftrunc, .vector_fnearest, .vector_convert_s, .vector_convert_u, .vector_trunc_sat_s, .vector_trunc_sat_u, .vector_promote_f32, .vector_demote_f64 => 1,
        .vector_extmul_s, .vector_extmul_u, .vector_dot_s, .vector_dot_sat_s, .vector_q15mulr_sat_s => 2,
        .vector_abs, .vector_neg, .vector_popcnt => 1,
        .vector_sub, .vector_mul, .vector_add_sat_s, .vector_add_sat_u, .vector_sub_sat_s, .vector_sub_sat_u, .vector_min_s, .vector_min_u, .vector_max_s, .vector_max_u, .vector_avgr_u, .vector_shl, .vector_shr_s, .vector_shr_u => 2,
        .vector_eq, .vector_ne, .vector_lt_s, .vector_lt_u, .vector_le_s, .vector_le_u, .vector_flt, .vector_fle => 2,
        .vector_any_true, .vector_all_true, .vector_bitmask => 1,
        .vector_add, .vector_replace, .vector_shuffle, .vector_swizzle, .vector_narrow_s, .vector_narrow_u => 2,
        .vector_splat, .vector_extract, .vector_extend_s, .vector_extend_u, .vector_pairwise_add_s, .vector_pairwise_add_u => 1,
        .constant, .call, .memory_length, .atomic_fence => 0,
        .load, .atomic_load => 1,
        .store, .atomic_store, .atomic_add, .atomic_sub, .atomic_and, .atomic_or, .atomic_xor, .atomic_exchange, .atomic_compare_exchange => 2,
        .fceil, .ffloor, .ftrunc, .fnearest, .convert_s, .convert_u, .trunc_s, .trunc_u, .trunc_sat_s, .trunc_sat_u => 1,
        .guard, .sext_i32, .zext_i32, .trunc_i64, .reinterpret, .promote_f32, .demote_f64, .fabs, .fneg, .fsqrt, .clz, .ctz, .popcnt, .sext8, .sext16, .sext32 => 1,
        .add, .sub, .mul, .div_s, .div_u, .rem_s, .rem_u, .bit_and, .bit_or, .bit_xor, .shl, .shr_s, .shr_u, .rotl, .rotr, .eq, .ne, .lt_s, .lt_u, .gt_s, .gt_u, .le_s, .le_u, .ge_s, .ge_u, .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcopysign, .feq, .fne, .flt, .fgt, .fle, .fge => 2,
    };
}

pub const Effects = struct {
    reads_memory: bool = false,
    writes_memory: bool = false,
    may_trap: bool = false,
    exits: bool = false,
    safepoint: bool = false,
    ordered: bool = false,

    pub fn isPure(self: Effects) bool {
        return !self.reads_memory and !self.writes_memory and !self.may_trap and !self.exits and !self.safepoint and !self.ordered;
    }
};

pub fn effects(op: Op) Effects {
    // Exhaustive: new operations must declare their observable effects.
    return switch (op) {
        .vector_fsub, .vector_fmul, .vector_fdiv, .vector_fmin, .vector_fmax, .vector_fpmin, .vector_fpmax, .vector_fabs, .vector_fneg, .vector_fsqrt, .vector_fceil, .vector_ffloor, .vector_ftrunc, .vector_fnearest, .vector_convert_s, .vector_convert_u, .vector_trunc_sat_s, .vector_trunc_sat_u, .vector_promote_f32, .vector_demote_f64 => .{},
        .vector_extmul_s, .vector_extmul_u, .vector_dot_s, .vector_dot_sat_s, .vector_q15mulr_sat_s => .{},
        .vector_sub, .vector_mul, .vector_add_sat_s, .vector_add_sat_u, .vector_sub_sat_s, .vector_sub_sat_u, .vector_abs, .vector_neg, .vector_popcnt, .vector_min_s, .vector_min_u, .vector_max_s, .vector_max_u, .vector_avgr_u, .vector_shl, .vector_shr_s, .vector_shr_u => .{},
        .vector_eq, .vector_ne, .vector_lt_s, .vector_lt_u, .vector_le_s, .vector_le_u, .vector_flt, .vector_fle, .vector_any_true, .vector_all_true, .vector_bitmask => .{},
        .vector_add, .vector_splat, .vector_extract, .vector_replace, .vector_shuffle, .vector_swizzle, .vector_extend_s, .vector_extend_u, .vector_narrow_s, .vector_narrow_u, .vector_pairwise_add_s, .vector_pairwise_add_u => .{},
        .guard => .{ .exits = true },
        .div_s, .div_u, .rem_s, .rem_u, .trunc_s, .trunc_u => .{ .may_trap = true },
        .load => .{ .reads_memory = true, .may_trap = true },
        .memory_length => .{ .reads_memory = true },
        .store => .{ .writes_memory = true, .may_trap = true },
        .atomic_load => .{ .reads_memory = true, .may_trap = true, .ordered = true },
        .atomic_store => .{ .writes_memory = true, .may_trap = true, .ordered = true },
        .atomic_add, .atomic_sub, .atomic_and, .atomic_or, .atomic_xor, .atomic_exchange, .atomic_compare_exchange => .{ .reads_memory = true, .writes_memory = true, .may_trap = true, .ordered = true },
        .atomic_fence => .{ .reads_memory = true, .writes_memory = true, .ordered = true },
        .call => .{ .reads_memory = true, .writes_memory = true, .may_trap = true, .safepoint = true },
        .fceil, .ffloor, .ftrunc, .fnearest, .convert_s, .convert_u, .trunc_sat_s, .trunc_sat_u => .{},
        .constant, .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr_s, .shr_u, .rotl, .rotr, .clz, .ctz, .popcnt, .sext8, .sext16, .sext32, .eq, .ne, .lt_s, .lt_u, .gt_s, .gt_u, .le_s, .le_u, .ge_s, .ge_u, .sext_i32, .zext_i32, .trunc_i64, .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcopysign, .fabs, .fneg, .fsqrt, .feq, .fne, .flt, .fgt, .fle, .fge, .reinterpret, .promote_f32, .demote_f64 => .{},
    };
}

pub fn hasVectorLane(op: Op) bool {
    if (isVectorInteger(op) or isVectorFloat(op)) return true;
    return switch (op) {
        .vector_eq, .vector_ne, .vector_lt_s, .vector_lt_u, .vector_le_s, .vector_le_u, .vector_flt, .vector_fle, .vector_all_true, .vector_bitmask => true,
        .vector_add, .vector_splat, .vector_extract, .vector_replace, .vector_extend_s, .vector_extend_u, .vector_narrow_s, .vector_narrow_u, .vector_pairwise_add_s, .vector_pairwise_add_u => true,
        else => false,
    };
}

pub fn isVectorFloat(op: Op) bool {
    return switch (op) {
        .vector_fsub, .vector_fmul, .vector_fdiv, .vector_fmin, .vector_fmax, .vector_fpmin, .vector_fpmax, .vector_fabs, .vector_fneg, .vector_fsqrt, .vector_fceil, .vector_ffloor, .vector_ftrunc, .vector_fnearest, .vector_convert_s, .vector_convert_u, .vector_trunc_sat_s, .vector_trunc_sat_u, .vector_promote_f32, .vector_demote_f64 => true,
        else => false,
    };
}

pub fn isVectorInteger(op: Op) bool {
    return switch (op) {
        .vector_extmul_s, .vector_extmul_u, .vector_dot_s, .vector_dot_sat_s, .vector_q15mulr_sat_s => true,
        .vector_sub, .vector_mul, .vector_add_sat_s, .vector_add_sat_u, .vector_sub_sat_s, .vector_sub_sat_u, .vector_abs, .vector_neg, .vector_popcnt, .vector_min_s, .vector_min_u, .vector_max_s, .vector_max_u, .vector_avgr_u, .vector_shl, .vector_shr_s, .vector_shr_u => true,
        else => false,
    };
}

pub fn isVectorShift(op: Op) bool {
    return op == .vector_shl or op == .vector_shr_s or op == .vector_shr_u;
}

pub fn isVectorOp(op: Op) bool {
    return hasVectorLane(op) or op == .vector_shuffle or op == .vector_swizzle or op == .vector_any_true;
}

pub fn isVectorComparison(op: Op) bool {
    return switch (op) {
        .vector_eq, .vector_ne, .vector_lt_s, .vector_lt_u, .vector_le_s, .vector_le_u, .vector_flt, .vector_fle => true,
        else => false,
    };
}

pub fn isVectorReduction(op: Op) bool {
    return op == .vector_any_true or op == .vector_all_true or op == .vector_bitmask;
}

pub fn mayTrap(op: Op) bool {
    return effects(op).may_trap;
}

test {
    _ = @import("tests.zig");
    _ = @import("float_test.zig");
    _ = @import("integer_test.zig");
    _ = @import("conversion_test.zig");
    _ = @import("fp_environment_test.zig");
    _ = @import("memory_test.zig");
    _ = @import("atomic_test.zig");
    _ = @import("call_test.zig");
    _ = @import("invoke_test.zig");
    _ = @import("results_test.zig");
    _ = @import("control_test.zig");
    _ = @import("vector_test.zig");
    _ = @import("vector_width_test.zig");
    _ = @import("vector_predicate_test.zig");
    _ = @import("vector_integer_test.zig");
    _ = @import("vector_product_test.zig");
    _ = @import("vector_float_test.zig");
}
