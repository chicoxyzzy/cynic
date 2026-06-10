//! WebAssembly types — the value, function, and external types of
//! §2.3-§2.5, in their §5.3 binary encoding.

const std = @import("std");

/// Heap-type codes for constructed reference types (the payload of a
/// `(ref ht)` / `(ref null ht)` encoding). Values below
/// `heap_concrete_max` are concrete type-section indices; the named
/// sentinels mirror the abstract heap types' wire bytes.
pub const heap_concrete_max: u32 = 0x00ff_f000;
pub const heap_abs_func: u32 = 0x00ff_ff70; // (ref [null] func)
pub const heap_abs_extern: u32 = 0x00ff_ff6f; // (ref [null] extern)
pub const heap_abs_exn: u32 = 0x00ff_ff69; // (ref [null] exn)

const ref_flag: u32 = 0x4000_0000; // a constructed reference type
const null_flag: u32 = 0x2000_0000; // ... that admits null
const heap_mask: u32 = 0x00ff_ffff;

/// §5.3.1-§5.3.4 — value types. Scalars and the shorthand reference
/// types keep their wire byte as the tag, so `@intFromEnum` is also
/// the binary opcode for them. The function-references proposal's
/// constructed types — `(ref ht)` 0x64 / `(ref null ht)` 0x63 with a
/// heap-type payload — pack into the high bits of the non-exhaustive
/// tag (`refType` / `heapOf` / `isNullable` below), with the nullable
/// abstract forms canonicalized onto the shorthands: `(ref null
/// func)` IS `funcref` (§2.3.3), so `==` remains type equality.
pub const ValType = enum(u32) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,
    funcref = 0x70, // (ref null func)
    externref = 0x6f, // (ref null extern)
    exnref = 0x69, // exception-handling proposal — (ref null exn)
    _,

    /// Decode a single-byte value type. Returns null for an
    /// unrecognized tag — including 0x63/0x64, which need a heap-type
    /// payload (`readValType`).
    pub fn fromByte(b: u8) ?ValType {
        return switch (b) {
            0x7f => .i32,
            0x7e => .i64,
            0x7d => .f32,
            0x7c => .f64,
            0x7b => .v128,
            0x70 => .funcref,
            0x6f => .externref,
            0x69 => .exnref,
            else => null,
        };
    }

    /// Construct a reference type, canonicalizing nullable abstract
    /// forms onto the shorthand tags.
    pub fn refType(nullable: bool, heap: u32) ValType {
        if (nullable) switch (heap) {
            heap_abs_func => return .funcref,
            heap_abs_extern => return .externref,
            heap_abs_exn => return .exnref,
            else => {},
        };
        return @enumFromInt(ref_flag | (if (nullable) null_flag else @as(u32, 0)) | (heap & heap_mask));
    }

    /// The heap type of any reference type (shorthand or constructed);
    /// null for a non-reference.
    pub fn heapOf(self: ValType) ?u32 {
        return switch (self) {
            .funcref => heap_abs_func,
            .externref => heap_abs_extern,
            .exnref => heap_abs_exn,
            .i32, .i64, .f32, .f64, .v128 => null,
            _ => {
                const raw = @intFromEnum(self);
                if (raw & ref_flag == 0) return null;
                return raw & heap_mask;
            },
        };
    }

    /// Whether a reference type admits null. False for non-references.
    pub fn isNullable(self: ValType) bool {
        return switch (self) {
            .funcref, .externref, .exnref => true,
            .i32, .i64, .f32, .f64, .v128 => false,
            _ => @intFromEnum(self) & null_flag != 0,
        };
    }

    /// The concrete type-section index of a `(ref [null] $t)`; null
    /// for abstract heaps and non-references.
    pub fn concreteIndex(self: ValType) ?u32 {
        const h = self.heapOf() orelse return null;
        if (h >= heap_concrete_max) return null;
        return h;
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

    /// §2.3.3 — any reference type, shorthand or constructed.
    pub fn isRef(self: ValType) bool {
        return self.heapOf() != null;
    }

    /// A type a local can carry without an initializer (§3.4.12 — every
    /// value type but a non-nullable reference).
    pub fn isDefaultable(self: ValType) bool {
        return !self.isRef() or self.isNullable();
    }
};

/// Read a possibly multi-byte value type: a single-byte scalar /
/// shorthand, or 0x63 `(ref null ht)` / 0x64 `(ref ht)` followed by an
/// s33 heap type (negative = abstract, non-negative = concrete type
/// index). `r` is any reader exposing `byte()` and `sleb(T)`.
pub fn readValType(r: anytype) !ValType {
    const b = try r.byte();
    if (ValType.fromByte(b)) |vt| return vt;
    const nullable = switch (b) {
        0x63 => true,
        0x64 => false,
        else => return error.BadValType,
    };
    return ValType.refType(nullable, try readHeapType(r));
}

/// Read an s33 heap type into the internal heap code.
pub fn readHeapType(r: anytype) !u32 {
    const ht = r.sleb(i64) catch return error.BadValType;
    if (ht >= 0) {
        if (ht >= heap_concrete_max) return error.BadValType;
        return @intCast(ht);
    }
    // Abstract heap types encode as negative s33 values mirroring
    // their wire byte's 7-bit two's complement: -0x10 ↔ 0x70 (func),
    // -0x11 ↔ 0x6f (extern), -0x17 ↔ 0x69 (exn).
    return switch (ht) {
        -0x10 => heap_abs_func,
        -0x11 => heap_abs_extern,
        -0x17 => heap_abs_exn,
        else => error.BadValType,
    };
}

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
/// `init_expr` carries the raw bytes of an explicit element initializer
/// (the function-references `0x40 0x00` form), including the terminating
/// `end`; null for the plain form. `elem` is always a reference type
/// (`isRef`), possibly a constructed `(ref [null] $t)`.
pub const TableType = struct {
    elem: ValType,
    limits: Limits,
    init_expr: ?[]const u8 = null,
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
