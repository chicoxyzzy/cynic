//! Module-index queries shared by Spasm's native backends.
const Module = @import("module.zig").Module;
const ValType = @import("types.zig").ValType;
const Reader = @import("reader.zig").Reader;
const types = @import("types.zig");

/// Core blocktype: empty, a single inline result, or a module function type.
/// Keep inline values by value; only module-owned signatures are borrowed.
pub const BlockType = union(enum) {
    empty,
    value: ValType,
    signature: *const types.FuncType,

    pub fn params(self: BlockType) []const ValType {
        return switch (self) {
            .signature => |signature| signature.params,
            else => &.{},
        };
    }

    pub fn resultCount(self: BlockType) usize {
        return switch (self) {
            .empty => 0,
            .value => 1,
            .signature => |signature| signature.results.len,
        };
    }

    pub fn resultType(self: BlockType, index: usize) ValType {
        return switch (self) {
            .value => |value| value,
            .signature => |signature| signature.results[index],
            .empty => unreachable, // callers iterate resultCount
        };
    }
};

pub fn readBlockType(module: *const Module, body: []const u8, pos: *usize) ?BlockType {
    if (pos.* >= body.len) return null;
    var reader: Reader = .{ .bytes = body, .pos = pos.* };
    const first = body[pos.*];
    const block: BlockType = if (first == 0x40) block: {
        reader.pos += 1;
        break :block .empty;
    } else if (ValType.fromByte(first) != null or first == 0x63 or first == 0x64) block: {
        const value = types.readValType(&reader) catch return null;
        break :block .{ .value = value };
    } else block: {
        const index = reader.sleb(i33) catch return null;
        if (index < 0 or @as(u64, @intCast(index)) >= module.types.len) return null;
        break :block .{ .signature = &module.types[@intCast(index)] };
    };
    pos.* = reader.pos;
    return block;
}

test "multivalue blocktype decoder distinguishes signatures and inline types" {
    const testing = @import("std").testing;
    const module: Module = .{ .types = &.{.{ .params = &.{.i32}, .results = &.{ .externref, .v128 } }} };
    var pos: usize = 0;
    const signature = readBlockType(&module, &.{0}, &pos).?;
    try testing.expectEqualSlices(ValType, &.{.i32}, signature.params());
    try testing.expectEqual(@as(usize, 2), signature.resultCount());
    try testing.expectEqual(ValType.v128, signature.resultType(1));
    for ([_][]const u8{ &.{0x6f}, &.{ 0x63, 0x6f } }) |bytes| {
        pos = 0;
        const inline_type = readBlockType(&module, bytes, &pos).?;
        try testing.expectEqual(@as(usize, 0), inline_type.params().len);
        try testing.expectEqual(ValType.externref, inline_type.resultType(0));
        try testing.expectEqual(bytes.len, pos);
    }
    for ([_][]const u8{ &.{}, &.{1}, &.{0x80}, &.{0x63}, &.{0x65}, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0 } }) |bytes| {
        pos = 0;
        try testing.expect(readBlockType(&module, bytes, &pos) == null);
        try testing.expectEqual(@as(usize, 0), pos);
    }
}

/// Memory indices include imported memories before module-defined memories.
pub fn memoryIs64(module: *const Module, index: u32) ?bool {
    var imported: u32 = 0;
    for (module.imports) |import| {
        if (import.desc != .mem) continue;
        if (index == imported) return import.desc.mem.limits.is_64;
        imported += 1;
    }
    if (index < imported) return null;
    const local: usize = index - imported;
    return if (local < module.mems.len) module.mems[local].limits.is_64 else null;
}

pub const MemoryAccess = struct {
    index: u32,
    offset: u64,
    memory64: bool,
};

/// Core binary memarg: alignment/flags, optional memory index, then offset.
/// The selected memory determines the offset's width, not memory zero.
pub fn readMemoryAccess(module: *const Module, body: []const u8, pos: *usize) ?MemoryAccess {
    var reader: Reader = .{ .bytes = body, .pos = pos.* };
    const flags = reader.uleb(u32) catch return null;
    const index = if (flags & 0x40 != 0) reader.uleb(u32) catch return null else 0;
    const memory64 = memoryIs64(module, index) orelse return null;
    const offset = if (memory64) reader.uleb(u64) catch return null else reader.uleb(u32) catch return null;
    pos.* = reader.pos;
    return .{ .index = index, .offset = offset, .memory64 = memory64 };
}

/// Table indices include imported tables before module-defined tables.
pub fn tableIs64(module: *const Module, index: u32) ?bool {
    var imported: u32 = 0;
    for (module.imports) |import| {
        if (import.desc != .table) continue;
        if (index == imported) return import.desc.table.limits.is_64;
        imported += 1;
    }
    if (index < imported) return null;
    const local: usize = index - imported;
    return if (local < module.tables.len) module.tables[local].limits.is_64 else null;
}

/// Global indices include imports before module-defined globals.
pub fn globalValType(module: *const Module, index: u32) ?ValType {
    var imported: u32 = 0;
    for (module.imports) |import| {
        if (import.desc != .global) continue;
        if (index == imported) return import.desc.global.val;
        imported += 1;
    }
    if (index < imported) return null;
    const local: usize = index - imported;
    return if (local < module.globals.len) module.globals[local].type.val else null;
}
