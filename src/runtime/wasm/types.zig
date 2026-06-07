//! WebAssembly types — the value, function, and external types of
//! §2.3-§2.5, in their §5.3 binary encoding.

const std = @import("std");

/// §5.3.1-§5.3.4 — value types. The discriminant byte is the wire
/// encoding, so `@intFromEnum` is also the binary opcode.
pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,
    funcref = 0x70,
    externref = 0x6f,

    /// Decode a value-type byte. Returns null for an unrecognized tag.
    pub fn fromByte(b: u8) ?ValType {
        return switch (b) {
            0x7f => .i32,
            0x7e => .i64,
            0x7d => .f32,
            0x7c => .f64,
            0x7b => .v128,
            0x70 => .funcref,
            0x6f => .externref,
            else => null,
        };
    }

    /// §2.3.1 — i32/i64/f32/f64.
    pub fn isNum(self: ValType) bool {
        return switch (self) {
            .i32, .i64, .f32, .f64 => true,
            else => false,
        };
    }

    /// §2.3.2 — v128.
    pub fn isVec(self: ValType) bool {
        return self == .v128;
    }

    /// §2.3.3 — funcref/externref.
    pub fn isRef(self: ValType) bool {
        return switch (self) {
            .funcref, .externref => true,
            else => false,
        };
    }
};

/// §5.3.3 — reference types. A subset of `ValType` admitted where the
/// grammar only allows a reference (table element types, `ref.null`).
pub const RefType = enum(u8) {
    funcref = 0x70,
    externref = 0x6f,

    pub fn fromByte(b: u8) ?RefType {
        return switch (b) {
            0x70 => .funcref,
            0x6f => .externref,
            else => null,
        };
    }

    pub fn toValType(self: RefType) ValType {
        return switch (self) {
            .funcref => .funcref,
            .externref => .externref,
        };
    }
};

/// §5.3.6 — a function type maps a vector of parameters to a vector of
/// results. Both slices are owned by the decode arena.
pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// §5.3.7 — resizable limits. `max` is null when the bound is open.
/// `shared` carries the threads-proposal flag; the validator decides
/// where a shared limit is admissible (memories only). `is_64` marks a
/// 64-bit address space (memory64 / table64 proposal): the memory's
/// addresses and a table's indices are i64 rather than i32.
pub const Limits = struct {
    min: u64,
    max: ?u64 = null,
    shared: bool = false,
    is_64: bool = false,
};

/// §5.3.9 — a table type pairs an element reference type with limits.
pub const TableType = struct {
    elem: RefType,
    limits: Limits,
};

/// §5.3.10 — a memory type is just its limits (in units of 64 KiB
/// pages).
pub const MemType = struct {
    limits: Limits,
};

/// §5.3.11 — mutability flag for globals.
pub const Mutability = enum(u8) {
    immutable = 0x00,
    mutable = 0x01,

    pub fn fromByte(b: u8) ?Mutability {
        return switch (b) {
            0x00 => .immutable,
            0x01 => .mutable,
            else => null,
        };
    }
};

/// §5.3.12 — a global type pairs a value type with mutability.
pub const GlobalType = struct {
    val: ValType,
    mut: Mutability,
};
