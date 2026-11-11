//! SSE2 integer arithmetic shared by native frontends. Inputs are XMM0/XMM1,
//! result XMM0; shifts take R10. Only RAX/R10 and XMM0-XMM3 are scratch.
const x64 = @import("asm_x86_64.zig");
const Error = error{ OutOfMemory, UnsupportedOp };
pub const Binary = enum { add, sub, mul };
pub const Shift = enum { shl, shr_s, shr_u };

pub fn binary(m: *x64.Masm, width: u4, kind: Binary, saturating: bool, signed: bool) Error!void {
    if (saturating) {
        if ((width != 1 and width != 2) or kind == .mul) return error.UnsupportedOp;
        return m.saturatingAddSubtractPacked128(.xmm0, .xmm1, width == 2, signed, kind == .sub);
    }
    switch (kind) {
        .add => try m.addPackedInteger(.xmm0, .xmm1, switch (width) {
            1 => .byte,
            2 => .half,
            4 => .word,
            8 => .double,
            else => return error.UnsupportedOp,
        }),
        .sub => try m.subtractPackedInteger(.xmm0, .xmm1, switch (width) {
            1 => .byte,
            2 => .half,
            4 => .word,
            8 => .double,
            else => return error.UnsupportedOp,
        }),
        .mul => switch (width) {
            2 => try m.multiplyLowPackedI16(.xmm0, .xmm1),
            4 => {
                try m.shufflePackedI32(.xmm2, .xmm0, 0xb1);
                try m.shufflePackedI32(.xmm3, .xmm1, 0xb1);
                try m.multiplyEvenPackedU32(.xmm0, .xmm1);
                try m.multiplyEvenPackedU32(.xmm2, .xmm3);
                try m.shufflePackedI32(.xmm0, .xmm0, 0x88);
                try m.shufflePackedI32(.xmm2, .xmm2, 0x88);
                try m.unpackLowPackedInteger(.xmm0, .xmm2, .word);
            },
            8 => {
                // Low qword product: lo*lo + ((hi*lo + lo*hi) << 32).
                try m.shufflePackedI32(.xmm2, .xmm0, 0xb1);
                try m.shufflePackedI32(.xmm3, .xmm1, 0xb1);
                try m.multiplyEvenPackedU32(.xmm2, .xmm1);
                try m.multiplyEvenPackedU32(.xmm3, .xmm0);
                try m.addPackedInteger(.xmm2, .xmm3, .double);
                try m.movImm32(.rax, 32);
                try m.movDXmmFromReg(.xmm3, .rax);
                try m.shiftPackedInteger(.xmm2, .xmm3, .shl64);
                try m.multiplyEvenPackedU32(.xmm0, .xmm1);
                try m.addPackedInteger(.xmm0, .xmm2, .double);
            },
            else => return error.UnsupportedOp,
        },
    }
}

pub fn unary(m: *x64.Masm, width: u4, negate: bool) Error!void {
    const size: x64.Masm.PackedSubtractSize = switch (width) {
        1 => .byte,
        2 => .half,
        4 => .word,
        8 => .double,
        else => return error.UnsupportedOp,
    };
    if (negate) {
        try m.xorPacked128(.xmm1, .xmm1);
        try m.subtractPackedInteger(.xmm1, .xmm0, size);
        return m.movVector128(.xmm0, .xmm1);
    }
    if (width == 8) {
        try m.shufflePackedI32(.xmm1, .xmm0, 0xf5);
        try m.shiftRightArithmeticPackedI32(.xmm1, 31);
    } else {
        try m.xorPacked128(.xmm1, .xmm1);
        try m.compareGreaterSignedPacked(.xmm1, .xmm0, if (width == 1) .byte else if (width == 2) .half else .word);
    }
    try m.xorPacked128(.xmm0, .xmm1);
    try m.subtractPackedInteger(.xmm0, .xmm1, size);
}

pub fn minMax(m: *x64.Masm, width: u4, signed: bool, maximum: bool) Error!void {
    if (width == 1 and !signed) return m.minMaxPacked128(.xmm0, .xmm1, if (maximum) .max_u8 else .min_u8);
    if (width == 2) {
        if (signed) return m.minMaxPacked128(.xmm0, .xmm1, if (maximum) .max_i16 else .min_i16);
        try m.movVector128(.xmm2, .xmm0);
        try m.subtractSaturatingPackedU16(.xmm2, .xmm1);
        if (maximum) {
            try m.addPackedI16(.xmm1, .xmm2);
            return m.movVector128(.xmm0, .xmm1);
        }
        return m.subtractPackedI16(.xmm0, .xmm2);
    }
    const size: x64.Masm.PackedIntSize = switch (width) {
        1 => .byte,
        4 => .word,
        else => return error.UnsupportedOp,
    };
    try m.movVector128(.xmm2, if (maximum) .xmm1 else .xmm0);
    try m.compareGreaterSignedPacked(.xmm2, if (maximum) .xmm0 else .xmm1, size);
    if (!signed) {
        try m.movVector128(.xmm3, .xmm0);
        try m.xorPacked128(.xmm3, .xmm1);
        try m.shiftRightArithmeticPackedI32(.xmm3, 31);
        try m.xorPacked128(.xmm2, .xmm3);
    }
    try m.xorPacked128(.xmm1, .xmm0);
    try m.andPacked128(.xmm1, .xmm2);
    try m.xorPacked128(.xmm0, .xmm1);
}

pub fn shift(m: *x64.Masm, width: u4, kind: Shift) Error!void {
    if (width != 1 and width != 2 and width != 4 and width != 8) return error.UnsupportedOp;
    try m.movImm32(.rax, @as(u8, width) * 8 - 1);
    try m.andReg32(.r10, .rax);
    if (width == 1 and kind == .shr_s) {
        try m.movVector128(.xmm1, .xmm0);
        try m.unpackLowPackedInteger(.xmm0, .xmm0, .byte);
        try m.unpackHighPackedInteger(.xmm1, .xmm1, .byte);
        try m.addRegImm32(.r10, 8);
        try m.movDXmmFromReg(.xmm2, .r10);
        try m.shiftPackedInteger(.xmm0, .xmm2, .sar16);
        try m.shiftPackedInteger(.xmm1, .xmm2, .sar16);
        return m.packSigned16To8(.xmm0, .xmm1);
    }
    try m.movDXmmFromReg(.xmm1, .r10);
    if (width == 8 and kind == .shr_s) {
        // Complement negative lanes before/after logical shift. Unlike a CL
        // scalar sequence, this preserves every allocated GP home.
        try m.shufflePackedI32(.xmm2, .xmm0, 0xf5);
        try m.shiftRightArithmeticPackedI32(.xmm2, 31);
        try m.xorPacked128(.xmm0, .xmm2);
        try m.shiftPackedInteger(.xmm0, .xmm1, .shr64);
        return m.xorPacked128(.xmm0, .xmm2);
    }
    const instruction: x64.Masm.PackedShift = switch (kind) {
        .shl => if (width <= 2) .shl16 else if (width == 4) .shl32 else .shl64,
        .shr_u => if (width <= 2) .shr16 else if (width == 4) .shr32 else .shr64,
        .shr_s => if (width == 2) .sar16 else .sar32,
    };
    try m.shiftPackedInteger(.xmm0, .xmm1, instruction);
    if (width == 1) {
        // Build a byte mask from shifted 0x00ff words, then pack it. This
        // discards bits crossing byte boundaries without borrowing RCX/CL.
        try m.movImm32(.rax, 0x00ff00ff);
        try m.movDXmmFromReg(.xmm2, .rax);
        try m.shufflePackedI32(.xmm2, .xmm2, 0);
        try m.movVector128(.xmm3, .xmm2);
        try m.shiftPackedInteger(.xmm2, .xmm1, instruction);
        try m.andPacked128(.xmm2, .xmm3);
        try m.packUnsigned16To8(.xmm2, .xmm2);
        try m.andPacked128(.xmm0, .xmm2);
    }
}

pub fn popcount(m: *x64.Masm) Error!void {
    for ([_]u32{ 0x55555555, 0x33333333, 0x0f0f0f0f }, 0..) |mask, step| {
        try m.movImm32(.rax, mask);
        try m.movDXmmFromReg(.xmm2, .rax);
        try m.shufflePackedI32(.xmm2, .xmm2, 0);
        try m.movVector128(.xmm1, .xmm0);
        try m.shiftRightLogicalPacked128(.xmm1, @as(u8, 1) << @as(u3, @intCast(step)), false);
        if (step < 2) try m.andPacked128(.xmm1, .xmm2);
        if (step == 0) {
            try m.subtractPackedInteger(.xmm0, .xmm1, .byte);
        } else {
            if (step == 1) try m.andPacked128(.xmm0, .xmm2);
            try m.addPackedInteger(.xmm0, .xmm1, .byte);
            if (step == 2) try m.andPacked128(.xmm0, .xmm2);
        }
    }
}
