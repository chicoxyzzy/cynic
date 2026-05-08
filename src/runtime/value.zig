//! NaN-boxed `Value` — Cynic's runtime tagged union, 64 bits wide.
//!
//! Encoding lineage: JavaScriptCore (Pizlo, "Speculation in
//! JavaScriptCore", 2020). Doubles are stored unboxed; non-doubles
//! occupy NaN-payload bit patterns reserved by an offset trick.
//!
//! Doubles are pre-offset by `double_encode_offset` on store and
//! restored on load. The offset is chosen so that every IEEE-754
//! double maps into the range `[0x0001_…, 0xFFF8_…]` — leaving the
//! top six 16-bit "tag slots" `0xFFF9..0xFFFE` free for our use.
//! The free range is exactly large enough to hold the variants
//! ECMA-262 §6.1 distinguishes (Object, String, Int32-fast-path,
//! Bool, Null, Undefined).
//!
//! 64-bit hosts only (see `docs/handbook/zig.md` and the later plan).
//! 32-bit support, if it ever comes up, needs a separate
//! representation.

const std = @import("std");

/// A NaN-boxed JavaScript value. `extern struct` keeps the layout
/// stable so the JIT (M5+) and any FFI can read these fields by
/// offset without surprises.
pub const Value = extern struct {
    bits: u64,

    // ── Tag layout ──────────────────────────────────────────────────────
    //
    // Top 16 bits select the variant for non-double values.
    // Doubles span every other top-16 pattern after the offset.
    //
    // tag = 0xFFF9: Object pointer (low 48 bits)
    // tag = 0xFFFA: String pointer (low 48 bits)
    // tag = 0xFFFB: Int32 (low 32 bits)
    // tag = 0xFFFC: Bool (low bit: 0 = false, 1 = true)
    // tag = 0xFFFD: Null (payload ignored, set to 0)
    // tag = 0xFFFE: Undefined (payload ignored, set to 0)
    // tag = 0xFFFF: Hole (TDZ sentinel for let/const,
    // §13.3.1 — never observable
    // to user code; throws on read)
    //
    // Doubles: any bit pattern with top-16 < 0xFFF9 (after offset).
    pub const tag_object: u16 = 0xFFF9;
    pub const tag_string: u16 = 0xFFFA;
    pub const tag_int32: u16 = 0xFFFB;
    pub const tag_bool: u16 = 0xFFFC;
    pub const tag_null: u16 = 0xFFFD;
    pub const tag_undefined: u16 = 0xFFFE;
    pub const tag_hole: u16 = 0xFFFF;

    /// Added to a double's bit pattern on store, subtracted on load.
    /// Pushes the NaN range out of the way of our tag slots.
    pub const double_encode_offset: u64 = 1 << 49;

    /// Low-48-bit pointer mask used to reconstruct a heap pointer
    /// from a tagged Object / String value. Hosts where userspace
    /// pointers exceed 48 bits need a different scheme.
    pub const pointer_mask: u64 = 0x0000_FFFF_FFFF_FFFF;

    // ── Singletons ──────────────────────────────────────────────────────

    pub const undefined_: Value = .{ .bits = @as(u64, tag_undefined) << 48 };
    pub const null_: Value = .{ .bits = @as(u64, tag_null) << 48 };
    pub const true_: Value = .{ .bits = (@as(u64, tag_bool) << 48) | 1 };
    pub const false_: Value = .{ .bits = (@as(u64, tag_bool) << 48) | 0 };
    /// TDZ sentinel — `let` / `const` bindings hold this between
    /// block entry and the binding's initialiser. Reading it
    /// raises a `ReferenceError`; the runtime's `throw_if_hole`
    /// opcode is the gate.
    pub const hole_: Value = .{ .bits = @as(u64, tag_hole) << 48 };

    // ── Constructors ────────────────────────────────────────────────────

    pub fn fromInt32(i: i32) Value {
        const u: u32 = @bitCast(i);
        return .{ .bits = (@as(u64, tag_int32) << 48) | @as(u64, u) };
    }

    pub fn fromDouble(d: f64) Value {
        // NaN canonicalisation. NaNs cover a wide range of bit
        // patterns (any sign, any non-zero mantissa with all-ones
        // exponent). Some of those patterns land on our tag slots
        // post-offset — e.g. a negative quiet NaN (`0xFFF8…`) plus
        // the 2^49 offset becomes `0xFFFA…` which the predicate
        // for `isString` accepts. Coerce every NaN to a single
        // safe representation before storing.
        // §6.1.6.1 NumberValue makes all NaNs equivalent, so this
        // is observably a no-op for user code.
        if (std.math.isNan(d)) {
            return .{ .bits = canonical_nan_bits +% double_encode_offset };
        }
        const raw: u64 = @bitCast(d);
        return .{ .bits = raw +% double_encode_offset };
    }

    /// Canonical NaN pre-offset. Positive-sign quiet NaN. After the
    /// `+ double_encode_offset`, this lands at `0x7FFA…` — well
    /// inside the double range (`< 0xFFF9`), so it can't collide
    /// with any tag.
    const canonical_nan_bits: u64 = 0x7FF8_0000_0000_0000;

    pub fn fromBool(b: bool) Value {
        return if (b) Value.true_ else Value.false_;
    }

    pub fn fromObject(ptr: *anyopaque) Value {
        const p: u64 = @intFromPtr(ptr);
        std.debug.assert(p & ~pointer_mask == 0); // host pointer fits in 48 bits
        return .{ .bits = (@as(u64, tag_object) << 48) | p };
    }

    pub fn fromString(ptr: *anyopaque) Value {
        const p: u64 = @intFromPtr(ptr);
        std.debug.assert(p & ~pointer_mask == 0);
        return .{ .bits = (@as(u64, tag_string) << 48) | p };
    }

    // ── Predicates ──────────────────────────────────────────────────────

    fn topTag(self: Value) u16 {
        return @intCast(self.bits >> 48);
    }

    pub fn isDouble(self: Value) bool {
        return self.topTag() < tag_object;
    }

    pub fn isObject(self: Value) bool {
        return self.topTag() == tag_object;
    }

    pub fn isString(self: Value) bool {
        return self.topTag() == tag_string;
    }

    pub fn isInt32(self: Value) bool {
        return self.topTag() == tag_int32;
    }

    pub fn isBool(self: Value) bool {
        return self.topTag() == tag_bool;
    }

    pub fn isNull(self: Value) bool {
        return self.topTag() == tag_null;
    }

    pub fn isUndefined(self: Value) bool {
        return self.topTag() == tag_undefined;
    }

    /// True if this is the TDZ sentinel. Used by `throw_if_hole`
    /// in the interpreter to gate `let`/`const` reads before the
    /// binding's initialiser runs (§13.3.1).
    pub fn isHole(self: Value) bool {
        return self.topTag() == tag_hole;
    }

    /// True for any "number-typed" value — int32-fast-path or double.
    /// The spec doesn't distinguish; this is purely an interpreter
    /// optimisation flag.
    pub fn isNumber(self: Value) bool {
        return self.topTag() <= tag_int32 and self.topTag() != tag_object and self.topTag() != tag_string;
    }

    /// `null` or `undefined`. §7.2.3 IsNullOrUndefined.
    pub fn isNullish(self: Value) bool {
        const t = self.topTag();
        return t == tag_null or t == tag_undefined;
    }

    // ── Accessors ───────────────────────────────────────────────────────

    pub fn asInt32(self: Value) i32 {
        std.debug.assert(self.isInt32());
        const u: u32 = @truncate(self.bits);
        return @bitCast(u);
    }

    pub fn asDouble(self: Value) f64 {
        std.debug.assert(self.isDouble());
        const raw = self.bits -% double_encode_offset;
        return @bitCast(raw);
    }

    pub fn asBool(self: Value) bool {
        std.debug.assert(self.isBool());
        return (self.bits & 1) == 1;
    }

    pub fn asObject(self: Value) *anyopaque {
        std.debug.assert(self.isObject());
        return @ptrFromInt(self.bits & pointer_mask);
    }

    pub fn asString(self: Value) *anyopaque {
        std.debug.assert(self.isString());
        return @ptrFromInt(self.bits & pointer_mask);
    }

    /// Number coercion: returns the value as `f64`. Int32 values
    /// widen losslessly. Caller should handle non-number cases
    /// separately (this is the fast path used inside arithmetic
    /// opcodes after a number predicate).
    pub fn numberToDouble(self: Value) f64 {
        if (self.isInt32()) return @floatFromInt(self.asInt32());
        return self.asDouble();
    }

    // ── Coercions (§7.1) ────────────────────────────────────────────────
    //
    // Object-typed coercions (which need to call user code via
    // ToPrimitive) are deferred to the interpreter; the helpers here
    // cover the primitive cases that arithmetic and short-circuits
    // need.

    /// §7.1.2 ToBoolean — primitive cases. Object-typed values are
    /// always `true`; strings need a length check that depends on
    /// the runtime String layout, so callers handle those.
    pub fn toBooleanPrimitive(self: Value) bool {
        return switch (self.topTag()) {
            tag_undefined, tag_null => false,
            tag_bool => self.asBool(),
            tag_int32 => self.asInt32() != 0,
            tag_object => true,
            tag_string => true, // empty-string check happens at the call site
            else => blk: {
                // Double — falsy when zero or NaN, truthy otherwise.
                const d = self.asDouble();
                break :blk d != 0.0 and !std.math.isNan(d);
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Tests — round-trips, predicates, edge cases, and a sanity check on the
// offset trick. Per the project's tests-first rule (docs/handbook/tdd.md),
// these exist in the same file as the production code.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Value: int32 round-trip across the full range" {
    const cases = [_]i32{
        std.math.minInt(i32),
        -1,
        0,
        1,
        std.math.maxInt(i32),
    };
    for (cases) |c| {
        const v = Value.fromInt32(c);
        try testing.expect(v.isInt32());
        try testing.expect(!v.isDouble());
        try testing.expect(!v.isObject());
        try testing.expectEqual(c, v.asInt32());
    }
}

test "Value: double round-trip including NaN, infinities, and signed zero" {
    const cases = [_]f64{
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.1 + 0.2,
        std.math.inf(f64),
        -std.math.inf(f64),
        std.math.floatMin(f64),
        std.math.floatMax(f64),
    };
    for (cases) |c| {
        const v = Value.fromDouble(c);
        try testing.expect(v.isDouble());
        try testing.expect(!v.isInt32());
        const got = v.asDouble();
        // Bit-equal so `-0.0` doesn't compare equal to `+0.0`.
        try testing.expectEqual(@as(u64, @bitCast(c)), @as(u64, @bitCast(got)));
    }
}

test "Value: NaN round-trips and stays a double" {
    // The whole point of the offset is that real NaNs still classify
    // as doubles after encoding.
    const nan = std.math.nan(f64);
    const v = Value.fromDouble(nan);
    try testing.expect(v.isDouble());
    try testing.expect(!v.isUndefined());
    try testing.expect(std.math.isNan(v.asDouble()));
}

test "Value: singletons have distinct, predictable encodings" {
    try testing.expect(Value.undefined_.isUndefined());
    try testing.expect(Value.null_.isNull());
    try testing.expect(Value.true_.isBool());
    try testing.expect(Value.false_.isBool());
    try testing.expect(Value.true_.asBool());
    try testing.expect(!Value.false_.asBool());

    // Distinctness — every singleton's bits differ.
    try testing.expect(Value.undefined_.bits != Value.null_.bits);
    try testing.expect(Value.true_.bits != Value.false_.bits);
    try testing.expect(Value.true_.bits != Value.null_.bits);
    try testing.expect(Value.true_.bits != Value.undefined_.bits);
}

test "Value: predicates are mutually exclusive across the variant set" {
    const samples = [_]Value{
        Value.fromInt32(42),
        Value.fromDouble(3.14),
        Value.true_,
        Value.false_,
        Value.null_,
        Value.undefined_,
        Value.hole_,
    };
    for (samples) |v| {
        // Exactly one of these is true for any sample.
        var hits: u8 = 0;
        if (v.isInt32()) hits += 1;
        if (v.isDouble()) hits += 1;
        if (v.isBool()) hits += 1;
        if (v.isNull()) hits += 1;
        if (v.isUndefined()) hits += 1;
        if (v.isHole()) hits += 1;
        if (v.isObject()) hits += 1;
        if (v.isString()) hits += 1;
        try testing.expectEqual(@as(u8, 1), hits);
    }
}

test "Value: object pointer round-trip" {
    var dummy: u32 = 0xDEAD_BEEF;
    const v = Value.fromObject(&dummy);
    try testing.expect(v.isObject());
    try testing.expect(!v.isString());
    const got: *u32 = @ptrCast(@alignCast(v.asObject()));
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), got.*);
}

test "Value: string pointer round-trip" {
    var dummy: u32 = 0xCAFE_F00D;
    const v = Value.fromString(&dummy);
    try testing.expect(v.isString());
    try testing.expect(!v.isObject());
    const got: *u32 = @ptrCast(@alignCast(v.asString()));
    try testing.expectEqual(@as(u32, 0xCAFE_F00D), got.*);
}

test "Value: isNullish covers null and undefined only" {
    try testing.expect(Value.null_.isNullish());
    try testing.expect(Value.undefined_.isNullish());
    try testing.expect(!Value.true_.isNullish());
    try testing.expect(!Value.false_.isNullish());
    try testing.expect(!Value.fromInt32(0).isNullish());
    try testing.expect(!Value.fromDouble(0.0).isNullish());
    try testing.expect(!Value.hole_.isNullish());
}

test "Value: hole_ is its own variant" {
    try testing.expect(Value.hole_.isHole());
    try testing.expect(!Value.undefined_.isHole());
    try testing.expect(!Value.null_.isHole());
    try testing.expect(!Value.fromInt32(0).isHole());
}

test "Value: numberToDouble widens int32 losslessly" {
    try testing.expectEqual(@as(f64, 0.0), Value.fromInt32(0).numberToDouble());
    try testing.expectEqual(@as(f64, -1.0), Value.fromInt32(-1).numberToDouble());
    try testing.expectEqual(@as(f64, 1.5), Value.fromDouble(1.5).numberToDouble());
}

test "Value: negative-NaN doubles do not collide with the string tag" {
    // Regression: a quiet -NaN (`0xFFF8_0000_0000_0000`) plus the
    // double-encode offset lands on `0xFFFA_…` — exactly our
    // `tag_string`. Without canonicalisation, `isString` would
    // accept a stored -NaN and the next `asString` would
    // dereference a null pointer. Triggers in real test262 code
    // like `-new Number(-1)`.
    const neg_nan_bits: u64 = 0xFFF8_0000_0000_0000;
    const neg_nan: f64 = @bitCast(neg_nan_bits);
    const v = Value.fromDouble(neg_nan);
    try testing.expect(!v.isString());
    try testing.expect(v.isDouble());
    try testing.expect(std.math.isNan(v.asDouble()));
}

test "Value: toBooleanPrimitive matches §7.1.2 for primitives" {
    try testing.expect(!Value.undefined_.toBooleanPrimitive());
    try testing.expect(!Value.null_.toBooleanPrimitive());
    try testing.expect(Value.true_.toBooleanPrimitive());
    try testing.expect(!Value.false_.toBooleanPrimitive());

    try testing.expect(!Value.fromInt32(0).toBooleanPrimitive());
    try testing.expect(Value.fromInt32(1).toBooleanPrimitive());
    try testing.expect(Value.fromInt32(-1).toBooleanPrimitive());

    try testing.expect(!Value.fromDouble(0.0).toBooleanPrimitive());
    try testing.expect(!Value.fromDouble(-0.0).toBooleanPrimitive());
    try testing.expect(!Value.fromDouble(std.math.nan(f64)).toBooleanPrimitive());
    try testing.expect(Value.fromDouble(1.0).toBooleanPrimitive());
    try testing.expect(Value.fromDouble(std.math.inf(f64)).toBooleanPrimitive());
}
