//! Shared scalar floating-point semantics used by Sarcasm and native tiers.

const std = @import("std");

pub const RoundMode = enum(u32) { ceil, floor, trunc, nearest };

/// Core fceil/ffloor/ftrunc/fnearest require arithmetic (quiet) NaN results.
/// SSE2/libc rounding may pass signaling NaNs through without quieting them.
pub fn round(comptime T: type, x: T, mode: RoundMode) T {
    const U = if (T == f32) u32 else u64;
    const quiet: U = if (T == f32) 0x0040_0000 else 0x0008_0000_0000_0000;
    if (std.math.isNan(x)) return @bitCast(@as(U, @bitCast(x)) | quiet);
    return switch (mode) {
        .ceil => @ceil(x),
        .floor => @floor(x),
        .trunc => @trunc(x),
        .nearest => roundEven(T, x),
    };
}

/// Round to nearest, ties to even (WebAssembly §4.3.3). Zig's `@round`
/// rounds ties away from zero, so correct the odd tie and preserve zero's sign.
pub fn roundEven(comptime T: type, x: T) T {
    const rounded = @round(x);
    var result = rounded;
    if (@abs(x - @trunc(x)) == 0.5 and @rem(rounded, 2) != 0) {
        result = rounded - std.math.sign(rounded);
    }
    if (result == 0) return std.math.copysign(@as(T, 0), x);
    return result;
}
