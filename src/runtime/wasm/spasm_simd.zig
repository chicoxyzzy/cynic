//! SIMD scalar/vector shapes shared by Spasm's native backends.
//! WebAssembly Core vector instructions (0xfd prefix).

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

pub fn reductionOp(sub: u32) ?ReductionOp {
    return switch (sub) {
        99, 100 => .{ .width = 1, .bitmask = sub == 100 },
        131, 132 => .{ .width = 2, .bitmask = sub == 132 },
        163, 164 => .{ .width = 4, .bitmask = sub == 164 },
        195, 196 => .{ .width = 8, .bitmask = sub == 196 },
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

pub fn floatMinMaxOp(sub: u32) ?FloatMinMaxOp {
    return switch (sub) {
        232, 233 => .{ .double_precision = false, .maximum = sub == 233 },
        244, 245 => .{ .double_precision = true, .maximum = sub == 245 },
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
