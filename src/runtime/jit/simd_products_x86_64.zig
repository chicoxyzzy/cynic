//! SSE2 vector products shared by native frontends. XMM0/XMM1 -> XMM0.
//! RAX, XMM0-XMM3, XMM8-XMM9 are scratch; allocated homes stay untouched.
const x64 = @import("asm_x86_64.zig");
const simd = @import("simd_x86_64.zig");
const Error = error{ OutOfMemory, UnsupportedOp };

pub fn dot(m: *x64.Masm, saturating: bool) Error!void {
    if (!saturating) return m.multiplyAddPackedI16(.xmm0, .xmm1);
    // Sign-extend both byte halves, sum exact products in i32, then clamp.
    // The original Spasm sequence used XMM4/XMM5, which are allocated homes
    // in the shared backend. XMM8/XMM9 are caller-saved on supported hosts.
    try m.xorPacked128(.xmm2, .xmm2);
    try m.compareGreaterSignedPacked(.xmm2, .xmm0, .byte);
    try m.xorPacked128(.xmm3, .xmm3);
    try m.compareGreaterSignedPacked(.xmm3, .xmm1, .byte);
    try m.movVector128(.xmm8, .xmm0);
    try m.movVector128(.xmm9, .xmm1);
    try m.unpackLowPackedInteger(.xmm0, .xmm2, .byte);
    try m.unpackHighPackedInteger(.xmm8, .xmm2, .byte);
    try m.unpackLowPackedInteger(.xmm1, .xmm3, .byte);
    try m.unpackHighPackedInteger(.xmm9, .xmm3, .byte);
    try m.multiplyAddPackedI16(.xmm0, .xmm1);
    try m.multiplyAddPackedI16(.xmm8, .xmm9);
    try m.packSigned32To16(.xmm0, .xmm8);
}

pub fn q15(m: *x64.Masm) Error!void {
    // Exact signed i32 products + rounding bias, followed by arithmetic shift
    // and saturation. Only (-32768 * -32768) overflows the positive bound.
    try m.movVector128(.xmm2, .xmm0);
    try m.multiplyHighPacked16(.xmm2, .xmm1, true);
    try m.multiplyLowPackedI16(.xmm0, .xmm1);
    try m.movVector128(.xmm1, .xmm0);
    try m.unpackLowPackedInteger(.xmm0, .xmm2, .half);
    try m.unpackHighPackedInteger(.xmm1, .xmm2, .half);
    try m.movImm64(.rax, 0x0000400000004000);
    try m.movQXmmFromReg(.xmm2, .rax);
    try m.shufflePackedI32(.xmm2, .xmm2, 0x44);
    try m.addPackedInteger(.xmm0, .xmm2, .word);
    try m.addPackedInteger(.xmm1, .xmm2, .word);
    try m.shiftRightArithmeticPackedI32(.xmm0, 15);
    try m.shiftRightArithmeticPackedI32(.xmm1, 15);
    try m.packSigned32To16(.xmm0, .xmm1);
}

pub fn extended(m: *x64.Masm, width: u4, signed: bool, high: bool) Error!void {
    switch (width) {
        1 => {
            try m.movVector128(.xmm2, .xmm1);
            try simd.extend(m, 1, signed, high);
            try m.movVector128(.xmm3, .xmm0);
            try m.movVector128(.xmm0, .xmm2);
            try simd.extend(m, 1, signed, high);
            try m.multiplyLowPackedI16(.xmm0, .xmm3);
        },
        2 => {
            try m.movVector128(.xmm2, .xmm0);
            try m.multiplyHighPacked16(.xmm2, .xmm1, signed);
            try m.multiplyLowPackedI16(.xmm0, .xmm1);
            if (high) try m.unpackHighPackedInteger(.xmm0, .xmm2, .half) else try m.unpackLowPackedInteger(.xmm0, .xmm2, .half);
        },
        4 => {
            const order: u8 = if (high) 0xfa else 0x50;
            try m.shufflePackedI32(.xmm0, .xmm0, order);
            try m.shufflePackedI32(.xmm1, .xmm1, order);
            if (signed) {
                // PMULUDQ's unsigned products need a 2^32 correction for each
                // negative operand. Only the low dword of the correction counts.
                try m.movVector128(.xmm2, .xmm0);
                try m.movVector128(.xmm3, .xmm1);
                try m.shiftRightArithmeticPackedI32(.xmm2, 31);
                try m.shiftRightArithmeticPackedI32(.xmm3, 31);
                try m.andPacked128(.xmm2, .xmm1);
                try m.andPacked128(.xmm3, .xmm0);
                try m.addPackedInteger(.xmm2, .xmm3, .word);
                try m.movImm64(.rax, 32);
                try m.movDXmmFromReg(.xmm3, .rax);
                try m.shiftPackedInteger(.xmm2, .xmm3, .shl64);
            }
            try m.multiplyEvenPackedU32(.xmm0, .xmm1);
            if (signed) try m.subtractPackedInteger(.xmm0, .xmm2, .double);
        },
        else => return error.UnsupportedOp,
    }
}
