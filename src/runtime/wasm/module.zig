//! Parsed WebAssembly module representation (§2.5).
//!
//! Each indexable space arrives as a slice owned by the decode arena.
//! Slices that are pure bytes — code bodies, the element/data section
//! payloads, constant-expression bytes — borrow the input buffer and
//! are parsed on demand by the validator and interpreter; the
//! structured slices (types, imports, exports, …) are decoded eagerly.

const std = @import("std");
const types = @import("types.zig");

pub const FuncType = types.FuncType;
pub const TableType = types.TableType;
pub const MemType = types.MemType;
pub const GlobalType = types.GlobalType;

/// §5.2.2 — every well-formed module begins with the 4-byte magic
/// number `\0asm` followed by a little-endian u32 version. Version 1
/// is the only value defined by the Core specification.
pub const magic: [4]u8 = .{ 0x00, 0x61, 0x73, 0x6d };
pub const version: u32 = 1;

/// §2.5.11 — the four import/export sorts.
pub const ExternKind = enum { func, table, mem, global };

/// §5.5.5 — an import names a module/field pair and the type of the
/// imported entity.
pub const Import = struct {
    module: []const u8,
    name: []const u8,
    desc: Desc,

    pub const Desc = union(ExternKind) {
        /// Type index into `Module.types`.
        func: u32,
        table: TableType,
        mem: MemType,
        global: GlobalType,
    };
};

/// §5.5.10 — an export names a field and points at one of the index
/// spaces.
pub const Export = struct {
    name: []const u8,
    desc: Desc,

    pub const Desc = union(ExternKind) {
        func: u32,
        table: u32,
        mem: u32,
        global: u32,
    };
};

/// §5.5.9 — a global's declared type plus the raw bytes of its
/// constant initializer expression (including the terminating `end`).
/// The expression is parsed by the validator/interpreter.
pub const Global = struct {
    type: GlobalType,
    init_expr: []const u8,
};

/// §5.5.13 — one function body from the code section: the raw bytes of
/// its local declarations followed by its expression (including the
/// terminating `end`). Borrowed from the input buffer.
pub const FuncBody = struct {
    bytes: []const u8,
};

/// A decoded module. All slices are owned by the allocator passed to
/// `decode`; byte slices additionally borrow the input buffer, so the
/// caller keeps that buffer alive for the module's lifetime.
pub const Module = struct {
    version: u32 = version,

    /// §5.5.4 — function signatures.
    types: []const FuncType = &.{},
    /// §5.5.5 — imports, in declaration order.
    imports: []const Import = &.{},
    /// §5.5.6 — type index per locally-defined function. Paired
    /// positionally with `code`.
    funcs: []const u32 = &.{},
    /// §5.5.7 — table definitions.
    tables: []const TableType = &.{},
    /// §5.5.8 — memory definitions.
    mems: []const MemType = &.{},
    /// §5.5.9 — global definitions.
    globals: []const Global = &.{},
    /// §5.5.10 — exports.
    exports: []const Export = &.{},
    /// §5.5.11 — optional start function index.
    start: ?u32 = null,
    /// §5.5.13 — function bodies, paired positionally with `funcs`.
    code: []const FuncBody = &.{},

    /// §5.5.12 — element section payload, captured raw (its per-segment
    /// structure is parsed when tables are instantiated).
    elements_raw: []const u8 = &.{},
    elements_count: u32 = 0,

    /// §5.5.14 — data section payload, captured raw.
    data_raw: []const u8 = &.{},
    data_count_in_section: u32 = 0,

    /// §5.5.15 — the declared data-segment count, present iff a data
    /// count section appeared. Cross-checked against the data section.
    data_count: ?u32 = null,
};
