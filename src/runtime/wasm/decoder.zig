//! WebAssembly binary-format decoder (§5).
//!
//! Decodes the §5.2.2 preamble, then the §5.5 section sequence into a
//! `Module`. Declarative sections (types, imports, functions, tables,
//! memories, globals, exports, start, code, data count) are decoded
//! eagerly; the element and data sections — whose per-segment shape
//! intertwines with constant-expression evaluation — are captured raw
//! and parsed at instantiation time.
//!
//! Error policy: every failure surfaces as a `DecodeError`, which the
//! JS-API boundary maps to `WebAssembly.CompileError`. The decoder
//! never panics on malformed input.

const std = @import("std");
const module_mod = @import("module.zig");
const types = @import("types.zig");
const reader = @import("reader.zig");

const Module = module_mod.Module;
const Import = module_mod.Import;
const Export = module_mod.Export;
const Global = module_mod.Global;
const FuncBody = module_mod.FuncBody;
const ExternKind = module_mod.ExternKind;
const ValType = types.ValType;
const RefType = types.RefType;
const FuncType = types.FuncType;
const Limits = types.Limits;
const TableType = types.TableType;
const MemType = types.MemType;
const GlobalType = types.GlobalType;
const Mutability = types.Mutability;
const Reader = reader.Reader;

pub const DecodeError = error{
    // — preamble —
    Truncated,
    BadMagic,
    BadVersion,
    // — reader (LEB / names) —
    IntTooLarge,
    LebTooLong,
    BadUtf8,
    // — sections —
    BadSectionId,
    SectionOrder,
    SectionSizeMismatch,
    // — type encodings —
    BadValType,
    BadRefType,
    BadFuncForm,
    BadLimitsFlag,
    BadMutability,
    BadImportDesc,
    BadExportDesc,
    BadConstExpr,
    // — cross-section consistency —
    FuncCodeMismatch,
    DataCountMismatch,
    OutOfMemory,
};

/// §5.5.1 — section ids. Custom (0) may appear any number of times,
/// anywhere; the rest appear at most once and in a fixed order.
const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    _,
};

/// Canonical ordering position. Note the data-count section (id 12)
/// sits between elements (9) and code (10), so this is not the numeric
/// id order. A non-custom section must have a strictly greater position
/// than every section before it.
fn orderPos(id: SectionId) ?u32 {
    return switch (id) {
        .type => 1,
        .import => 2,
        .function => 3,
        .table => 4,
        .memory => 5,
        .global => 6,
        .@"export" => 7,
        .start => 8,
        .element => 9,
        .data_count => 10,
        .code => 11,
        .data => 12,
        .custom, _ => null,
    };
}

/// Decode the bytes of a WebAssembly binary into a `Module`. Structured
/// slices are allocated from `allocator`; byte slices borrow `bytes`.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Module {
    var r = Reader.init(bytes);

    // §5.2.2 preamble: magic + version.
    const preamble = try r.bytesN(8);
    if (!std.mem.eql(u8, preamble[0..4], &module_mod.magic)) return error.BadMagic;
    const wire_version = std.mem.readInt(u32, preamble[4..8], .little);
    if (wire_version != module_mod.version) return error.BadVersion;

    var m: Module = .{ .version = wire_version };
    var last_pos: u32 = 0;
    var saw_func_section = false;

    // §5.5 section sequence.
    while (!r.atEnd()) {
        const id_byte = try r.byte();
        const size = try r.uleb(u32);
        const payload = try r.bytesN(size);
        const id: SectionId = @enumFromInt(id_byte);

        // Ordering: custom sections are exempt; everything else must
        // strictly advance the canonical position (which also makes
        // each non-custom section unique).
        if (orderPos(id)) |pos| {
            if (pos <= last_pos) return error.SectionOrder;
            last_pos = pos;
        } else if (id != .custom) {
            return error.BadSectionId;
        }

        var sr = Reader.init(payload);
        switch (id) {
            .custom => sr.pos = payload.len, // §5.5.3 — opaque payload, consumed wholesale.
            .type => m.types = try decodeTypeSection(allocator, &sr),
            .import => m.imports = try decodeImportSection(allocator, &sr),
            .function => {
                m.funcs = try decodeFunctionSection(allocator, &sr);
                saw_func_section = true;
            },
            .table => m.tables = try decodeTableSection(allocator, &sr),
            .memory => m.mems = try decodeMemorySection(allocator, &sr),
            .global => m.globals = try decodeGlobalSection(allocator, &sr),
            .@"export" => m.exports = try decodeExportSection(allocator, &sr),
            .start => m.start = try sr.uleb(u32),
            .element => {
                m.elements_count = try sr.uleb(u32);
                m.elements_raw = payload[sr.pos..];
                sr.pos = payload.len; // payload consumed structurally
            },
            .code => m.code = try decodeCodeSection(allocator, &sr),
            .data => {
                m.data_count_in_section = try sr.uleb(u32);
                m.data_raw = payload[sr.pos..];
                sr.pos = payload.len;
            },
            .data_count => m.data_count = try sr.uleb(u32),
            _ => return error.BadSectionId,
        }

        // Every byte of a section's declared size must be consumed.
        if (sr.pos != payload.len) return error.SectionSizeMismatch;
    }

    // §5.5.13 — the function and code sections must agree in count. A
    // function section with no code section (or vice versa) is only
    // legal when both are absent.
    if (saw_func_section or m.code.len != 0) {
        if (m.funcs.len != m.code.len) return error.FuncCodeMismatch;
    }

    // §5.5.15 — when a data count section is present, it must match the
    // number of segments the data section declares.
    if (m.data_count) |dc| {
        if (dc != m.data_count_in_section) return error.DataCountMismatch;
    }

    return m;
}

// ── per-section decoders ────────────────────────────────────────────

fn decodeTypeSection(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const FuncType {
    const n = try r.uleb(u32);
    var out: std.ArrayListUnmanaged(FuncType) = .empty;
    try out.ensureTotalCapacityPrecise(allocator, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (try r.byte() != 0x60) return error.BadFuncForm; // §5.3.6
        const params = try decodeValTypeVec(allocator, r);
        const results = try decodeValTypeVec(allocator, r);
        out.appendAssumeCapacity(.{ .params = params, .results = results });
    }
    return out.toOwnedSlice(allocator);
}

fn decodeValTypeVec(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const ValType {
    const n = try r.uleb(u32);
    const vts = try allocator.alloc(ValType, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        vts[i] = ValType.fromByte(try r.byte()) orelse return error.BadValType;
    }
    return vts;
}

fn decodeImportSection(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const Import {
    const n = try r.uleb(u32);
    var out: std.ArrayListUnmanaged(Import) = .empty;
    try out.ensureTotalCapacityPrecise(allocator, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const mod_name = try r.name();
        const field = try r.name();
        const kind = try r.byte();
        const desc: Import.Desc = switch (kind) {
            0x00 => .{ .func = try r.uleb(u32) },
            0x01 => .{ .table = try decodeTableType(r) },
            0x02 => .{ .mem = try decodeMemType(r) },
            0x03 => .{ .global = try decodeGlobalType(r) },
            else => return error.BadImportDesc,
        };
        out.appendAssumeCapacity(.{ .module = mod_name, .name = field, .desc = desc });
    }
    return out.toOwnedSlice(allocator);
}

fn decodeFunctionSection(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const u32 {
    const n = try r.uleb(u32);
    const idxs = try allocator.alloc(u32, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) idxs[i] = try r.uleb(u32);
    return idxs;
}

fn decodeTableSection(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const TableType {
    const n = try r.uleb(u32);
    const tabs = try allocator.alloc(TableType, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) tabs[i] = try decodeTableType(r);
    return tabs;
}

fn decodeMemorySection(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const MemType {
    const n = try r.uleb(u32);
    const mems = try allocator.alloc(MemType, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) mems[i] = try decodeMemType(r);
    return mems;
}

fn decodeGlobalSection(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const Global {
    const n = try r.uleb(u32);
    var out: std.ArrayListUnmanaged(Global) = .empty;
    try out.ensureTotalCapacityPrecise(allocator, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const gt = try decodeGlobalType(r);
        const expr = try captureConstExpr(r);
        out.appendAssumeCapacity(.{ .type = gt, .init_expr = expr });
    }
    return out.toOwnedSlice(allocator);
}

fn decodeExportSection(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const Export {
    const n = try r.uleb(u32);
    var out: std.ArrayListUnmanaged(Export) = .empty;
    try out.ensureTotalCapacityPrecise(allocator, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const field = try r.name();
        const kind = try r.byte();
        const idx = try r.uleb(u32);
        const desc: Export.Desc = switch (kind) {
            0x00 => .{ .func = idx },
            0x01 => .{ .table = idx },
            0x02 => .{ .mem = idx },
            0x03 => .{ .global = idx },
            else => return error.BadExportDesc,
        };
        out.appendAssumeCapacity(.{ .name = field, .desc = desc });
    }
    return out.toOwnedSlice(allocator);
}

fn decodeCodeSection(allocator: std.mem.Allocator, r: *Reader) DecodeError![]const FuncBody {
    const n = try r.uleb(u32);
    var out: std.ArrayListUnmanaged(FuncBody) = .empty;
    try out.ensureTotalCapacityPrecise(allocator, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // §5.5.13 — each entry is size-prefixed; capture the body raw.
        const body_len = try r.uleb(u32);
        const body = try r.bytesN(body_len);
        out.appendAssumeCapacity(.{ .bytes = body });
    }
    return out.toOwnedSlice(allocator);
}

// ── shared type decoders ────────────────────────────────────────────

fn decodeLimits(r: *Reader) DecodeError!Limits {
    // §5.3.7, extended by the threads proposal's shared flag.
    const flag = try r.byte();
    return switch (flag) {
        0x00 => .{ .min = try r.uleb(u32) },
        0x01 => blk: {
            const min = try r.uleb(u32);
            const max = try r.uleb(u32);
            break :blk .{ .min = min, .max = max };
        },
        0x02 => .{ .min = try r.uleb(u32), .shared = true },
        0x03 => blk: {
            const min = try r.uleb(u32);
            const max = try r.uleb(u32);
            break :blk .{ .min = min, .max = max, .shared = true };
        },
        else => error.BadLimitsFlag,
    };
}

fn decodeTableType(r: *Reader) DecodeError!TableType {
    const elem = RefType.fromByte(try r.byte()) orelse return error.BadRefType;
    return .{ .elem = elem, .limits = try decodeLimits(r) };
}

fn decodeMemType(r: *Reader) DecodeError!MemType {
    return .{ .limits = try decodeLimits(r) };
}

fn decodeGlobalType(r: *Reader) DecodeError!GlobalType {
    const vt = ValType.fromByte(try r.byte()) orelse return error.BadValType;
    const mut = Mutability.fromByte(try r.byte()) orelse return error.BadMutability;
    return .{ .val = vt, .mut = mut };
}

/// Capture the raw bytes of a constant expression (§3.3.7), including
/// the terminating `end` (0x0B). MVP-plus constant expressions cannot
/// nest blocks, so this skips each instruction's immediates and stops
/// at the first `end`. The bytes are re-parsed by the validator.
fn captureConstExpr(r: *Reader) DecodeError![]const u8 {
    const start = r.pos;
    while (true) {
        const op = try r.byte();
        switch (op) {
            0x0b => break, // end
            0x41 => _ = try r.sleb(i32), // i32.const
            0x42 => _ = try r.sleb(i64), // i64.const
            0x43 => _ = try r.bytesN(4), // f32.const
            0x44 => _ = try r.bytesN(8), // f64.const
            0x23 => _ = try r.uleb(u32), // global.get
            0xd0 => _ = try r.byte(), // ref.null reftype
            0xd2 => _ = try r.uleb(u32), // ref.func
            else => return error.BadConstExpr,
        }
    }
    return r.bytes[start..r.pos];
}
