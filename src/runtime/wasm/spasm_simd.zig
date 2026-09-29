//! SIMD scalar/vector shapes shared by Spasm's native backends.
//! WebAssembly Core vector instructions (0xfd prefix).

pub const WideningLoadOp = struct { width: u4, signed: bool };

pub const ConversionOp = struct {
    kind: enum { trunc_sat, convert, demote, promote },
    input_width: u4,
    output_width: u4,
    signed: bool = false,
};

pub fn conversionOp(sub: u32) ?ConversionOp {
    return switch (sub) {
        94 => .{ .kind = .demote, .input_width = 8, .output_width = 4 },
        95 => .{ .kind = .promote, .input_width = 4, .output_width = 8 },
        248, 249, 257, 258 => .{ .kind = .trunc_sat, .input_width = 4, .output_width = 4, .signed = sub == 248 or sub == 257 },
        250, 251 => .{ .kind = .convert, .input_width = 4, .output_width = 4, .signed = sub == 250 },
        252, 253, 259, 260 => .{ .kind = .trunc_sat, .input_width = 8, .output_width = 4, .signed = sub == 252 or sub == 259 },
        254, 255 => .{ .kind = .convert, .input_width = 4, .output_width = 8, .signed = sub == 254 },
        else => null,
    };
}

pub fn wideningLoadOp(sub: u32) ?WideningLoadOp {
    return switch (sub) {
        1, 2 => .{ .width = 1, .signed = sub == 1 },
        3, 4 => .{ .width = 2, .signed = sub == 3 },
        5, 6 => .{ .width = 4, .signed = sub == 5 },
        else => null,
    };
}

/// Width is the destination lane width in bytes; sources are always signed.
pub const NarrowOp = struct { width: u4, signed: bool };

pub fn narrowOp(sub: u32) ?NarrowOp {
    return switch (sub) {
        101, 102 => .{ .width = 1, .signed = sub == 101 },
        133, 134 => .{ .width = 2, .signed = sub == 133 },
        else => null,
    };
}

/// Width is the source lane width in bytes.
pub const ExtendOp = struct { width: u4, signed: bool, high: bool };

pub fn extendOp(sub: u32) ?ExtendOp {
    return switch (sub) {
        135...138, 167...170, 199...202 => .{
            .width = @as(u4, 1) << @as(u2, @intCast((sub - 135) / 32)),
            .signed = (sub - 135) % 32 < 2,
            .high = (sub - 135) % 2 == 1,
        },
        else => null,
    };
}

pub const PairwiseAddOp = struct { width: u4, signed: bool };

pub fn pairwiseAddOp(sub: u32) ?PairwiseAddOp {
    return switch (sub) {
        124...127 => .{ .width = if (sub < 126) 1 else 2, .signed = sub % 2 == 0 },
        else => null,
    };
}

pub const ProductOp = struct {
    width: u4,
    kind: enum { extmul, dot, q15 },
    signed: bool = true,
    high: bool = false,
};

pub fn productOp(sub: u32) ?ProductOp {
    return switch (sub) {
        156...159, 188...191, 220...223 => .{
            .width = @as(u4, 1) << @as(u2, @intCast((sub - 156) / 32)),
            .kind = .extmul,
            .signed = (sub - 156) % 32 < 2,
            .high = sub % 2 == 1,
        },
        186 => .{ .width = 2, .kind = .dot },
        130, 273 => .{ .width = 2, .kind = .q15 },
        else => null,
    };
}

pub const ScalarLoadOp = struct { width: u4, splat: bool };

pub fn scalarLoadOp(sub: u32) ?ScalarLoadOp {
    return switch (sub) {
        7...10 => .{ .width = @as(u4, 1) << @as(u2, @intCast(sub - 7)), .splat = true },
        92, 93 => .{ .width = if (sub == 92) 4 else 8, .splat = false },
        else => null,
    };
}

pub fn splatWidth(sub: u32) ?u4 {
    return switch (sub) {
        15 => 1,
        16 => 2,
        17, 19 => 4,
        18, 20 => 8,
        else => null,
    };
}

pub const LaneOp = struct {
    width: u4,
    replace: bool = false,
    signed: bool = false,
};

pub fn laneOp(sub: u32) ?LaneOp {
    return switch (sub) {
        21 => .{ .width = 1, .signed = true },
        22 => .{ .width = 1 },
        23 => .{ .width = 1, .replace = true },
        24 => .{ .width = 2, .signed = true },
        25 => .{ .width = 2 },
        26 => .{ .width = 2, .replace = true },
        27, 31 => .{ .width = 4 },
        28, 32 => .{ .width = 4, .replace = true },
        29, 33 => .{ .width = 8 },
        30, 34 => .{ .width = 8, .replace = true },
        else => null,
    };
}

pub const ReductionOp = struct { width: u4, bitmask: bool };

pub const Comparison = enum { eq, ne, lt, gt, le, ge };
pub const ComparisonOp = struct {
    width: u4,
    relation: Comparison,
    signed: bool = false,
    floating: bool = false,
};

pub fn comparisonOp(sub: u32) ?ComparisonOp {
    if (sub >= 35 and sub <= 64) {
        const index = (sub - 35) % 10;
        return .{
            .width = @as(u4, 1) << @as(u2, @intCast((sub - 35) / 10)),
            .relation = switch (index) {
                0 => .eq,
                1 => .ne,
                2, 3 => .lt,
                4, 5 => .gt,
                6, 7 => .le,
                8, 9 => .ge,
                else => return null,
            },
            .signed = index >= 2 and index % 2 == 0,
        };
    }
    if ((sub >= 65 and sub <= 76) or (sub >= 214 and sub <= 219)) {
        const floating = sub < 214;
        const index = if (floating) (sub - 65) % 6 else sub - 214;
        return .{
            .width = if (sub <= 70) 4 else 8,
            .relation = switch (index) {
                0 => .eq,
                1 => .ne,
                2 => .lt,
                3 => .gt,
                4 => .le,
                5 => .ge,
                else => return null,
            },
            .signed = !floating,
            .floating = floating,
        };
    }
    return null;
}

pub fn reductionOp(sub: u32) ?ReductionOp {
    return switch (sub) {
        99, 100 => .{ .width = 1, .bitmask = sub == 100 },
        131, 132 => .{ .width = 2, .bitmask = sub == 132 },
        163, 164 => .{ .width = 4, .bitmask = sub == 164 },
        195, 196 => .{ .width = 8, .bitmask = sub == 196 },
        else => null,
    };
}

pub const IntegerBinaryOp = struct {
    width: u4,
    kind: enum { add, sub, mul },
    saturating: bool = false,
    signed: bool = false,
};

pub fn integerBinaryOp(sub: u32) ?IntegerBinaryOp {
    return switch (sub) {
        110, 142, 174, 206 => .{ .width = @as(u4, 1) << @as(u2, @intCast((sub - 110) / 32)), .kind = .add },
        113, 145, 177, 209 => .{ .width = @as(u4, 1) << @as(u2, @intCast((sub - 113) / 32)), .kind = .sub },
        149, 181, 213 => .{ .width = @as(u4, 2) << @as(u2, @intCast((sub - 149) / 32)), .kind = .mul },
        111, 112, 143, 144 => .{ .width = if (sub < 128) 1 else 2, .kind = .add, .saturating = true, .signed = sub % 2 == 1 },
        114, 115, 146, 147 => .{ .width = if (sub < 128) 1 else 2, .kind = .sub, .saturating = true, .signed = sub % 2 == 0 },
        else => null,
    };
}

pub const ShiftOp = struct { width: u4, kind: enum { shl, shr_s, shr_u } };

pub fn shiftOp(sub: u32) ?ShiftOp {
    return switch (sub) {
        107...109, 139...141, 171...173, 203...205 => .{
            .width = @as(u4, 1) << @as(u2, @intCast((sub - 107) / 32)),
            .kind = switch ((sub - 107) % 32) {
                0 => .shl,
                1 => .shr_s,
                else => .shr_u,
            },
        },
        else => null,
    };
}

pub const IntegerUnaryOp = struct { width: u4, negate: bool };

pub fn integerUnaryOp(sub: u32) ?IntegerUnaryOp {
    return switch (sub) {
        96, 97 => .{ .width = 1, .negate = sub == 97 },
        128, 129 => .{ .width = 2, .negate = sub == 129 },
        160, 161 => .{ .width = 4, .negate = sub == 161 },
        192, 193 => .{ .width = 8, .negate = sub == 193 },
        else => null,
    };
}

pub fn roundingAverageWidth(sub: u32) ?u4 {
    return switch (sub) {
        123 => 1,
        155 => 2,
        else => null,
    };
}

pub const FloatMinMaxOp = struct { double_precision: bool, maximum: bool };

pub const FloatRoundOp = struct {
    double_precision: bool,
    mode: @import("float_ops.zig").RoundMode,
};

pub fn floatRoundOp(sub: u32) ?FloatRoundOp {
    return switch (sub) {
        103...106 => .{ .double_precision = false, .mode = @enumFromInt(sub - 103) },
        116 => .{ .double_precision = true, .mode = .ceil },
        117 => .{ .double_precision = true, .mode = .floor },
        122 => .{ .double_precision = true, .mode = .trunc },
        148 => .{ .double_precision = true, .mode = .nearest },
        else => null,
    };
}

pub fn floatPseudoMinMaxOp(sub: u32) ?FloatMinMaxOp {
    return switch (sub) {
        234, 235 => .{ .double_precision = false, .maximum = sub == 235 },
        246, 247 => .{ .double_precision = true, .maximum = sub == 247 },
        else => null,
    };
}

pub const FloatArithmeticOp = struct {
    double_precision: bool,
    kind: enum { abs, neg, sqrt, add, sub, mul, div },

    pub fn isUnary(self: FloatArithmeticOp) bool {
        return switch (self.kind) {
            .abs, .neg, .sqrt => true,
            else => false,
        };
    }
};

pub fn floatArithmeticOp(sub: u32) ?FloatArithmeticOp {
    return switch (sub) {
        224, 225, 227...231, 236, 237, 239...243 => .{
            .double_precision = sub >= 236,
            .kind = switch (sub - (if (sub < 236) @as(u32, 224) else 236)) {
                0 => .abs,
                1 => .neg,
                3 => .sqrt,
                4 => .add,
                5 => .sub,
                6 => .mul,
                7 => .div,
                else => return null,
            },
        },
        else => null,
    };
}

pub fn floatMinMaxOp(sub: u32) ?FloatMinMaxOp {
    return switch (sub) {
        232, 269 => .{ .double_precision = false, .maximum = false },
        233, 270 => .{ .double_precision = false, .maximum = true },
        244, 271 => .{ .double_precision = true, .maximum = false },
        245, 272 => .{ .double_precision = true, .maximum = true },
        else => null,
    };
}

pub const MinMaxOp = struct { width: u4, signed: bool, maximum: bool };

pub fn integerMinMaxOp(sub: u32) ?MinMaxOp {
    return switch (sub) {
        118 => .{ .width = 1, .signed = true, .maximum = false },
        119 => .{ .width = 1, .signed = false, .maximum = false },
        120 => .{ .width = 1, .signed = true, .maximum = true },
        121 => .{ .width = 1, .signed = false, .maximum = true },
        150 => .{ .width = 2, .signed = true, .maximum = false },
        151 => .{ .width = 2, .signed = false, .maximum = false },
        152 => .{ .width = 2, .signed = true, .maximum = true },
        153 => .{ .width = 2, .signed = false, .maximum = true },
        182 => .{ .width = 4, .signed = true, .maximum = false },
        183 => .{ .width = 4, .signed = false, .maximum = false },
        184 => .{ .width = 4, .signed = true, .maximum = true },
        185 => .{ .width = 4, .signed = false, .maximum = true },
        else => null,
    };
}
