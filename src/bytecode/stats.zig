//! Opt-in bytecode vocabulary and dispatch statistics.

const std = @import("std");
const build_options = @import("build_options");
const Op = @import("op.zig").Op;
const OperandKind = @import("op.zig").OperandKind;
const Builder = @import("chunk.zig").Builder;
const Chunk = @import("chunk.zig").Chunk;
const Span = @import("../source.zig").Span;

const opcode_slots = 256;
const opcode_count = @typeInfo(Op).@"enum".field_names.len;
const operand_kind_count = @typeInfo(OperandKind).@"enum".field_names.len;

pub const enabled = build_options.bytecode_stats;

pub const WidthClass = enum { u8, u16, u32 };

pub const StaticStats = struct {
    opcode_counts: [opcode_slots]u64 = @splat(0),
    operand_width_counts: [operand_kind_count][3]u64 = @splat(@splat(0)),
    instructions: u64 = 0,
    encoded_bytes: u64 = 0,
    chunks: u64 = 0,
    max_register_count: u8 = 0,

    pub const Error = error{ OutOfMemory, InvalidBytecode };

    pub fn observeChunk(self: *StaticStats, allocator: std.mem.Allocator, root: *const Chunk) Error!void {
        var pending: std.ArrayListUnmanaged(*const Chunk) = .empty;
        defer pending.deinit(allocator);
        try pending.append(allocator, root);

        while (pending.pop()) |chunk| {
            try self.observeCode(chunk);
            for (chunk.function_templates) |*template| try pending.append(allocator, &template.chunk);
            for (chunk.class_templates) |*template| {
                try pending.append(allocator, &template.constructor_chunk);
                for (template.instance_methods) |*method| try pending.append(allocator, &method.chunk);
                for (template.static_methods) |*method| try pending.append(allocator, &method.chunk);
                for (template.instance_fields) |*field| if (field.init_chunk) |*init| try pending.append(allocator, init);
                for (template.static_fields) |*field| if (field.init_chunk) |*init| try pending.append(allocator, init);
                for (template.static_blocks) |*block| try pending.append(allocator, block);
            }
        }
    }

    fn observeCode(self: *StaticStats, chunk: *const Chunk) Error!void {
        self.chunks += 1;
        self.max_register_count = @max(self.max_register_count, chunk.register_count);
        var pc: usize = 0;
        while (pc < chunk.code.len) {
            if (chunk.code[pc] >= opcode_count) return error.InvalidBytecode;
            const op: Op = @enumFromInt(chunk.code[pc]);
            const spec = op.spec();
            const size = spec.layout.operandSize();
            const next = std.math.add(usize, pc + 1, size) catch return error.InvalidBytecode;
            if (next > chunk.code.len) return error.InvalidBytecode;

            self.instructions += 1;
            self.encoded_bytes += 1 + size;
            self.opcode_counts[@intFromEnum(op)] += 1;

            var cursor = pc + 1;
            for (spec.layout.operands()) |kind| {
                const width = classifyOperand(kind, chunk.code, cursor);
                self.operand_width_counts[@intFromEnum(kind)][@intFromEnum(width)] += 1;
                cursor += kind.byteSize();
            }
            pc = next;
        }
    }

    pub fn opcodeCount(self: *const StaticStats, op: Op) u64 {
        return self.opcode_counts[@intFromEnum(op)];
    }

    pub fn operandCount(self: *const StaticStats, kind: OperandKind, width: WidthClass) u64 {
        return self.operand_width_counts[@intFromEnum(kind)][@intFromEnum(width)];
    }
};

const SequenceCell = struct {
    encoded_key: u32 = 0,
    count: u64 = 0,
};

const pair_capacity = 8192;
const trigram_capacity = 16384;

pub const DynamicStats = struct {
    opcode_counts: [opcode_slots]u64 = @splat(0),
    pairs: [pair_capacity]SequenceCell = @splat(.{}),
    trigrams: [trigram_capacity]SequenceCell = @splat(.{}),
    instructions: u64 = 0,
    dropped_pairs: u64 = 0,
    dropped_trigrams: u64 = 0,
    previous: [2]Op = undefined,
    previous_len: u2 = 0,

    pub fn observe(self: *DynamicStats, op: Op) void {
        self.instructions +|= 1;
        self.opcode_counts[@intFromEnum(op)] +|= 1;
        if (self.previous_len >= 1) {
            const key = pairKey(self.previous[1], op);
            if (!incrementSequence(pair_capacity, &self.pairs, key)) self.dropped_pairs +|= 1;
        }
        if (self.previous_len == 2) {
            const key = trigramKey(self.previous[0], self.previous[1], op);
            if (!incrementSequence(trigram_capacity, &self.trigrams, key)) self.dropped_trigrams +|= 1;
        }
        if (self.previous_len == 0) {
            self.previous[1] = op;
            self.previous_len = 1;
        } else {
            self.previous[0] = self.previous[1];
            self.previous[1] = op;
            self.previous_len = 2;
        }
    }

    pub fn resetSequence(self: *DynamicStats) void {
        self.previous_len = 0;
    }

    pub fn opcodeCount(self: *const DynamicStats, op: Op) u64 {
        return self.opcode_counts[@intFromEnum(op)];
    }

    pub fn pairCount(self: *const DynamicStats, first: Op, second: Op) u64 {
        return sequenceCount(pair_capacity, &self.pairs, pairKey(first, second));
    }

    pub fn trigramCount(self: *const DynamicStats, first: Op, second: Op, third: Op) u64 {
        return sequenceCount(trigram_capacity, &self.trigrams, trigramKey(first, second, third));
    }
};

threadlocal var active_dynamic: ?*DynamicStats = null;

pub const Activation = struct {
    previous: ?*DynamicStats = null,

    pub fn deinit(self: Activation) void {
        if (comptime enabled) active_dynamic = self.previous;
    }
};

pub fn activate(stats: *DynamicStats) Activation {
    if (comptime enabled) {
        const previous = active_dynamic;
        active_dynamic = stats;
        stats.resetSequence();
        return .{ .previous = previous };
    }
    return .{};
}

pub noinline fn observeActive(op: Op) void {
    if (comptime enabled) {
        if (active_dynamic) |stats| stats.observe(op);
    }
}

fn classifyOperand(kind: OperandKind, code: []const u8, at: usize) WidthClass {
    return switch (kind) {
        .register, .u8, .i8 => .u8,
        .u16 => if (readU16(code, at) <= std.math.maxInt(u8)) .u8 else .u16,
        .i16 => if (std.math.lossyCast(i8, readI16(code, at)) == readI16(code, at)) .u8 else .u16,
        .i32 => blk: {
            const value = readI32(code, at);
            if (std.math.lossyCast(i8, value) == value) break :blk .u8;
            if (std.math.lossyCast(i16, value) == value) break :blk .u16;
            break :blk .u32;
        },
        .u32 => blk: {
            const value = readU32(code, at);
            if (value <= std.math.maxInt(u8)) break :blk .u8;
            if (value <= std.math.maxInt(u16)) break :blk .u16;
            break :blk .u32;
        },
    };
}

fn incrementSequence(comptime capacity: usize, cells: *[capacity]SequenceCell, key: u32) bool {
    const encoded = key + 1;
    var slot: usize = @intCast((key *% 2_654_435_761) & (capacity - 1));
    var probes: usize = 0;
    while (probes < capacity) : (probes += 1) {
        const cell = &cells[slot];
        if (cell.encoded_key == 0) {
            cell.* = .{ .encoded_key = encoded, .count = 1 };
            return true;
        }
        if (cell.encoded_key == encoded) {
            cell.count +|= 1;
            return true;
        }
        slot = (slot + 1) & (capacity - 1);
    }
    return false;
}

fn sequenceCount(comptime capacity: usize, cells: *const [capacity]SequenceCell, key: u32) u64 {
    const encoded = key + 1;
    var slot: usize = @intCast((key *% 2_654_435_761) & (capacity - 1));
    var probes: usize = 0;
    while (probes < capacity) : (probes += 1) {
        const cell = &cells[slot];
        if (cell.encoded_key == 0) return 0;
        if (cell.encoded_key == encoded) return cell.count;
        slot = (slot + 1) & (capacity - 1);
    }
    return 0;
}

fn pairKey(first: Op, second: Op) u32 {
    return (@as(u32, @intFromEnum(first)) << 8) | @intFromEnum(second);
}

fn trigramKey(first: Op, second: Op, third: Op) u32 {
    return (@as(u32, @intFromEnum(first)) << 16) |
        (@as(u32, @intFromEnum(second)) << 8) |
        @intFromEnum(third);
}

fn readU16(code: []const u8, at: usize) u16 {
    return @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
}

fn readI16(code: []const u8, at: usize) i16 {
    return @bitCast(readU16(code, at));
}

fn readU32(code: []const u8, at: usize) u32 {
    return @as(u32, code[at]) |
        (@as(u32, code[at + 1]) << 8) |
        (@as(u32, code[at + 2]) << 16) |
        (@as(u32, code[at + 3]) << 24);
}

fn readI32(code: []const u8, at: usize) i32 {
    return @bitCast(readU32(code, at));
}

const OpcodeRow = struct { op: Op, count: u64 };
const SequenceRow = struct { key: u32, count: u64 };

pub fn formatReport(
    allocator: std.mem.Allocator,
    static: *const StaticStats,
    dynamic: *const DynamicStats,
    requested_top: usize,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const top = @max(@as(usize, 1), requested_top);

    try out.print(allocator, "bytecode statistics\n", .{});
    try out.print(allocator, "static: chunks={d} instructions={d} bytes={d} max-registers={d}\n", .{
        static.chunks,
        static.instructions,
        static.encoded_bytes,
        static.max_register_count,
    });
    try out.print(allocator, "operand widths (fits):\n", .{});
    inline for (@typeInfo(OperandKind).@"enum".field_names) |name| {
        const kind: OperandKind = @field(OperandKind, name);
        try out.print(allocator, "  {s}: u8={d} u16={d} u32={d}\n", .{
            name,
            static.operandCount(kind, .u8),
            static.operandCount(kind, .u16),
            static.operandCount(kind, .u32),
        });
    }

    var op_rows: std.ArrayListUnmanaged(OpcodeRow) = .empty;
    defer op_rows.deinit(allocator);
    inline for (@typeInfo(Op).@"enum".field_names) |name| {
        const op: Op = @field(Op, name);
        const count = dynamic.opcodeCount(op);
        if (count != 0) try op_rows.append(allocator, .{ .op = op, .count = count });
    }
    std.mem.sort(OpcodeRow, op_rows.items, {}, rowLessThan(OpcodeRow));
    try out.print(allocator, "dynamic: instructions={d} dropped-pairs={d} dropped-trigrams={d}\n", .{
        dynamic.instructions,
        dynamic.dropped_pairs,
        dynamic.dropped_trigrams,
    });
    try out.print(allocator, "top opcodes:\n", .{});
    for (op_rows.items[0..@min(top, op_rows.items.len)]) |row| {
        try out.print(allocator, "  {s} {d}\n", .{ row.op.mnemonic(), row.count });
    }

    var pair_rows: std.ArrayListUnmanaged(SequenceRow) = .empty;
    defer pair_rows.deinit(allocator);
    for (dynamic.pairs) |cell| if (cell.encoded_key != 0) {
        try pair_rows.append(allocator, .{ .key = cell.encoded_key - 1, .count = cell.count });
    };
    std.mem.sort(SequenceRow, pair_rows.items, {}, rowLessThan(SequenceRow));
    try out.print(allocator, "top pairs:\n", .{});
    for (pair_rows.items[0..@min(top, pair_rows.items.len)]) |row| {
        const first: Op = @enumFromInt(@as(u8, @truncate(row.key >> 8)));
        const second: Op = @enumFromInt(@as(u8, @truncate(row.key)));
        try out.print(allocator, "  {s} -> {s} {d}\n", .{ first.mnemonic(), second.mnemonic(), row.count });
    }

    var trigram_rows: std.ArrayListUnmanaged(SequenceRow) = .empty;
    defer trigram_rows.deinit(allocator);
    for (dynamic.trigrams) |cell| if (cell.encoded_key != 0) {
        try trigram_rows.append(allocator, .{ .key = cell.encoded_key - 1, .count = cell.count });
    };
    std.mem.sort(SequenceRow, trigram_rows.items, {}, rowLessThan(SequenceRow));
    try out.print(allocator, "top trigrams:\n", .{});
    for (trigram_rows.items[0..@min(top, trigram_rows.items.len)]) |row| {
        const first: Op = @enumFromInt(@as(u8, @truncate(row.key >> 16)));
        const second: Op = @enumFromInt(@as(u8, @truncate(row.key >> 8)));
        const third: Op = @enumFromInt(@as(u8, @truncate(row.key)));
        try out.print(allocator, "  {s} -> {s} -> {s} {d}\n", .{ first.mnemonic(), second.mnemonic(), third.mnemonic(), row.count });
    }
    return out.toOwnedSlice(allocator);
}

fn rowLessThan(comptime Row: type) fn (void, Row, Row) bool {
    return struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            if (a.count != b.count) return a.count > b.count;
            const a_key: u32 = if (Row == OpcodeRow) @intFromEnum(a.op) else a.key;
            const b_key: u32 = if (Row == OpcodeRow) @intFromEnum(b.op) else b.key;
            return a_key < b_key;
        }
    }.lessThan;
}

const testing = std.testing;

test "bytecode stats: static scan counts bytes opcodes and operand widths" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };
    const r0 = try b.reserveRegister();
    try b.emitOp(.add_smi, span);
    try b.emitU8(r0);
    try b.emitI32(300);
    try b.emitOp(.return_, span);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    var stats: StaticStats = .{};
    try stats.observeChunk(testing.allocator, &chunk);
    try testing.expectEqual(@as(u64, 2), stats.instructions);
    try testing.expectEqual(@as(u64, 7), stats.encoded_bytes);
    try testing.expectEqual(@as(u64, 1), stats.opcodeCount(.add_smi));
    try testing.expectEqual(@as(u64, 1), stats.opcodeCount(.return_));
    try testing.expectEqual(@as(u64, 1), stats.operandCount(.register, .u8));
    try testing.expectEqual(@as(u64, 1), stats.operandCount(.i32, .u16));
}

test "bytecode stats: dynamic scan records opcode pairs and trigrams" {
    var stats: DynamicStats = .{};
    stats.observe(.add);
    stats.observe(.star);
    stats.observe(.add);

    try testing.expectEqual(@as(u64, 2), stats.opcodeCount(.add));
    try testing.expectEqual(@as(u64, 1), stats.opcodeCount(.star));
    try testing.expectEqual(@as(u64, 1), stats.pairCount(.add, .star));
    try testing.expectEqual(@as(u64, 1), stats.pairCount(.star, .add));
    try testing.expectEqual(@as(u64, 1), stats.trigramCount(.add, .star, .add));
}

test "bytecode stats: report exposes encoding and dispatch hot spots" {
    var static: StaticStats = .{};
    static.instructions = 3;
    static.encoded_bytes = 7;
    static.opcode_counts[@intFromEnum(Op.add)] = 2;
    var dynamic: DynamicStats = .{};
    dynamic.observe(.add);
    dynamic.observe(.star);
    dynamic.observe(.add);

    const report = try formatReport(testing.allocator, &static, &dynamic, 8);
    defer testing.allocator.free(report);
    try testing.expect(std.mem.indexOf(u8, report, "static: chunks=0 instructions=3 bytes=7") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Add 2") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Add -> Star 1") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Add -> Star -> Add 1") != null);
}
