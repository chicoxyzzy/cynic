//! SIMD scalar/vector shapes shared by Spasm's native backends.
//! WebAssembly Core vector instructions, 0xfd subopcodes 15 through 34.

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
