//! Module-index queries shared by Spasm's native backends.
const Module = @import("module.zig").Module;
const ValType = @import("types.zig").ValType;
const Reader = @import("reader.zig").Reader;

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

/// Table helpers use u32 indices. Refuse table64 before narrowing an operand.
pub fn tableIs32(module: *const Module, index: u32) bool {
    var imported: u32 = 0;
    for (module.imports) |import| {
        if (import.desc != .table) continue;
        if (index == imported) return !import.desc.table.limits.is_64;
        imported += 1;
    }
    if (index < imported) return false;
    const local: usize = index - imported;
    return local < module.tables.len and !module.tables[local].limits.is_64;
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
