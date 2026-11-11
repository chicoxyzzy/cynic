//! SSE2 floating SIMD shared by native frontends. XMM0/XMM1 -> XMM0;
//! RAX and XMM0-XMM3 are scratch. Allocated register homes remain untouched.
const x64 = @import("asm_x86_64.zig");
pub const Arithmetic = enum { abs, neg, sqrt, add, sub, mul, div };

pub fn arithmetic(m: *x64.Masm, wide: bool, kind: Arithmetic) !void {
    if (kind == .abs or kind == .neg) {
        // Sign operations preserve signaling NaNs and payloads bit-for-bit.
        const sign: u64 = if (wide) 0x8000000000000000 else 0x8000000080000000;
        try m.movImm64(.rax, if (kind == .abs) ~sign else sign);
        try m.movQXmmFromReg(.xmm1, .rax);
        try m.shufflePackedI32(.xmm1, .xmm1, 0x44);
        if (kind == .abs) try m.andPacked128(.xmm0, .xmm1) else try m.xorPacked128(.xmm0, .xmm1);
        return;
    }
    try m.arithmeticPackedFloat128(.xmm0, if (kind == .sqrt) .xmm0 else .xmm1, wide, switch (kind) {
        .sqrt => .sqrt,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        else => unreachable,
    });
}

pub fn minMax(m: *x64.Masm, wide: bool, maximum: bool, pseudo: bool) !void {
    if (pseudo) {
        // SSE selects its second operand on ties/NaNs, including sNaNs.
        try m.minMaxPackedFloat128(.xmm1, .xmm0, wide, maximum);
        return m.movVector128(.xmm0, .xmm1);
    }
    try m.movVector128(.xmm2, .xmm0);
    try m.compareUnorderedPackedFloat128(.xmm2, .xmm1, wide);
    try m.movVector128(.xmm3, .xmm0);
    try m.minMaxPackedFloat128(.xmm3, .xmm1, wide, maximum);
    try m.minMaxPackedFloat128(.xmm1, .xmm0, wide, maximum);
    if (maximum) try m.andPacked128(.xmm3, .xmm1) else try m.orPacked128(.xmm3, .xmm1);
    // Combine both orders for signed-zero ties; unordered lanes become a
    // negative canonical NaN without disturbing ordered/subnormal payloads.
    try m.orPacked128(.xmm3, .xmm2);
    try m.shiftRightLogicalPacked128(.xmm2, if (wide) 13 else 10, wide);
    try m.andNotPacked128(.xmm2, .xmm3);
    try m.movVector128(.xmm0, .xmm2);
}
