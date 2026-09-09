//! Shared scalar floating-point semantics used by Sarcasm and native tiers.

const std = @import("std");

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
