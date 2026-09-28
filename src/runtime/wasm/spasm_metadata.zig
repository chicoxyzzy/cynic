//! Module-index queries shared by Spasm's native backends.
const Module = @import("module.zig").Module;
const ValType = @import("types.zig").ValType;

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
