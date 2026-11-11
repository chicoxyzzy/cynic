//! Shared SSE2 width-changing sequences, independent of Wasm and SSA IR.
//! Inputs/results use XMM0/XMM1; RAX and XMM0-XMM3 are scratch. No allocated
//! shared-backend GP homes or XMM4-XMM7 homes are modified.
const x64 = @import("asm_x86_64.zig");
const Error = error{ OutOfMemory, UnsupportedOp };

/// Width is the source lane size in bytes; the result doubles it.
pub fn extend(m: *x64.Masm, width: u4, signed: bool, high: bool) Error!void {
    const size: x64.Masm.PackedIntSize = switch (width) {
        1 => .byte,
        2 => .half,
        4 => .word,
        else => return error.UnsupportedOp,
    };
    try m.xorPacked128(.xmm1, .xmm1);
    if (signed) try m.compareGreaterSignedPacked(.xmm1, .xmm0, size);
    if (high) try m.unpackHighPackedInteger(.xmm0, .xmm1, size) else try m.unpackLowPackedInteger(.xmm0, .xmm1, size);
}

/// Width is the destination lane size. Sources are signed even for unsigned
/// saturation: negative lanes must clamp to zero, not the unsigned maximum.
pub fn narrow(m: *x64.Masm, width: u4, signed: bool) Error!void {
    if (width == 1) {
        if (signed) try m.packSigned16To8(.xmm0, .xmm1) else try m.packUnsigned16To8(.xmm0, .xmm1);
    } else if (width != 2) {
        return error.UnsupportedOp;
    } else if (signed) {
        try m.packSigned32To16(.xmm0, .xmm1);
    } else {
        // PACKUSDW requires SSE4.1. Clamp negatives, bias by -32768,
        // PACKSSDW, then flip output sign bits to recover unsigned lanes.
        try m.movImm64(.rax, 0x0000800000008000);
        try m.movQXmmFromReg(.xmm3, .rax);
        try m.shufflePackedI32(.xmm3, .xmm3, 0x44);
        for ([_]x64.Xmm{ .xmm0, .xmm1 }) |input| {
            try m.xorPacked128(.xmm2, .xmm2);
            try m.compareGreaterSignedPacked(.xmm2, input, .word);
            try m.andNotPacked128(.xmm2, input);
            try m.movVector128(input, .xmm2);
            try m.subtractPackedInteger(input, .xmm3, .word);
        }
        try m.packSigned32To16(.xmm0, .xmm1);
        try m.movImm64(.rax, 0x8000800080008000);
        try m.movQXmmFromReg(.xmm1, .rax);
        try m.shufflePackedI32(.xmm1, .xmm1, 0x44);
        try m.xorPacked128(.xmm0, .xmm1);
    }
}

/// Width is the source lane size; adjacent extended lanes are added in pairs.
pub fn pairwiseAdd(m: *x64.Masm, width: u4, signed: bool) Error!void {
    if (width != 1 and width != 2) return error.UnsupportedOp;
    if (signed and width == 2) {
        try m.movImm64(.rax, 0x0001000100010001);
        try m.movQXmmFromReg(.xmm1, .rax);
        try m.shufflePackedI32(.xmm1, .xmm1, 0x44);
        try m.multiplyAddPackedI16(.xmm0, .xmm1);
        return;
    }
    try m.movVector128(.xmm1, .xmm0);
    if (signed) {
        try m.movImm64(.rax, 8);
        try m.movDXmmFromReg(.xmm2, .rax);
        try m.shiftPackedInteger(.xmm0, .xmm2, .shl16);
        try m.shiftPackedInteger(.xmm0, .xmm2, .sar16);
        try m.shiftPackedInteger(.xmm1, .xmm2, .sar16);
    } else {
        try m.shiftRightLogicalPacked128(.xmm1, @as(u8, width) * 8, false);
        try m.movImm64(.rax, if (width == 1) 0x00ff00ff00ff00ff else 0x0000ffff0000ffff);
        try m.movQXmmFromReg(.xmm2, .rax);
        try m.shufflePackedI32(.xmm2, .xmm2, 0x44);
        try m.andPacked128(.xmm0, .xmm2);
        if (width == 1) try m.andPacked128(.xmm1, .xmm2);
    }
    try m.addPackedInteger(.xmm0, .xmm1, if (width == 1) .half else .word);
}
