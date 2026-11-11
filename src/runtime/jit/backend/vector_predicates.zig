//! Native SIMD masks and scalar reductions. Only fixed temporary homes change.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const scratch = @import("scratch.zig");
const arm = @import("../asm_aarch64.zig");
const x86 = @import("../simd_x86_64.zig");

pub fn emit(m: *scratch.Machine, node: ir.Node) !void {
    if (ir.isVectorComparison(node.op)) {
        const relation: x86.Comparison = switch (node.op) {
            .vector_eq => .eq,
            .vector_ne => .ne,
            .vector_lt_s, .vector_lt_u, .vector_flt => .lt,
            .vector_le_s, .vector_le_u, .vector_fle => .le,
            else => return error.InvalidGraph,
        };
        const lane = node.vector_lane.?;
        const floating = ir.isFloat(lane.scalarType());
        const signed = node.op == .vector_lt_s or node.op == .vector_le_s;
        if (comptime builtin.cpu.arch == .x86_64) {
            try x86.compare(m, @intCast(lane.bytes()), relation, signed, floating);
        } else {
            const reverse = relation == .lt or relation == .le;
            const left: arm.Reg = if (reverse) .x1 else .x0;
            const right: arm.Reg = if (reverse) .x0 else .x1;
            const condition: arm.VectorComparison = switch (relation) {
                .eq, .ne => .eq,
                .lt, .gt => .gt,
                .le, .ge => .ge,
            };
            if (floating) {
                try m.emit(arm.compareFloatV128(.x0, left, right, lane == .f64x2, condition));
            } else {
                try m.emit(arm.compareIntegerV128(.x0, left, right, try integerSize(lane), condition, signed));
            }
            if (relation == .ne) try m.emit(arm.notV128(.x0, .x0));
        }
        return;
    }
    if (comptime builtin.cpu.arch == .x86_64) {
        if (node.op == .vector_any_true) return x86.anyTrue(m);
        return x86.reduce(m, @intCast(node.vector_lane.?.bytes()), node.op == .vector_bitmask);
    } else if (node.op == .vector_any_true) {
        try m.emit(arm.extractUnsignedIntegerLane(.x2, .x0, .double, 0));
        try m.emit(arm.extractUnsignedIntegerLane(.x3, .x0, .double, 1));
        try m.emit(arm.orrReg(.x2, .x2, .x3));
        try m.emit(arm.cmpImm(.x2, 0, false));
        try m.emit(arm.csetW(.x2, .ne));
    } else {
        const lane = node.vector_lane.?;
        const width = lane.bytes();
        if (node.op == .vector_all_true) {
            if (width == 8) {
                try m.emit(arm.extractUnsignedIntegerLane(.x2, .x0, .double, 0));
                try m.emit(arm.extractUnsignedIntegerLane(.x3, .x0, .double, 1));
                try m.emit(arm.cmpImm(.x2, 0, false));
                try m.emit(arm.csetW(.x2, .ne));
                try m.emit(arm.cmpImm(.x3, 0, false));
                try m.emit(arm.csetW(.x3, .ne));
                try m.emit(arm.andRegW(.x2, .x2, .x3));
            } else {
                try m.emit(arm.uminv128(.x0, .x0, if (width == 1) .byte else if (width == 2) .half else .word));
                try m.emit(arm.fmovStoW(.x2, .x0));
                try m.emit(arm.cmpImm(.x2, 0, false));
                try m.emit(arm.csetW(.x2, .ne));
            }
        } else if (width >= 4) {
            try m.movImm64(.x2, 0);
            for (0..lane.count()) |i| {
                try m.emit(arm.extractUnsignedIntegerLane(.x3, .x0, try integerSize(lane), @intCast(i)));
                try m.emit(arm.lsrImm(.x3, .x3, @intCast(width * 8 - 1)));
                if (i != 0) try m.emit(arm.lslImm(.x3, .x3, @intCast(i)));
                try m.emit(arm.orrReg(.x2, .x2, .x3));
            }
        } else {
            // Weight sign-filled lanes and sum. Byte interleaving creates two
            // independent mask bytes without carries between the halves.
            try m.emit(arm.sshrSign128(.x0, .x0, if (width == 1) .byte else .half));
            try m.movImm64(.x2, if (width == 1) 0x8040201008040201 else 0x0008000400020001);
            try m.emit(arm.fmovXtoD(.x1, .x2));
            if (width == 2) try m.movImm64(.x2, 0x0080004000200010);
            try m.emit(arm.insDFromX(.x1, 1, .x2));
            try m.emit(arm.andV16b(.x0, .x0, .x1));
            if (width == 1) {
                try m.emit(arm.extV16b(.x1, .x0, .x0, 8));
                try m.emit(arm.zip1V16b(.x0, .x0, .x1));
            }
            try m.emit(arm.addv8h(.x0, .x0));
            try m.emit(arm.fmovStoW(.x2, .x0));
        }
    }
}

fn integerSize(lane: ir.VectorLane) !arm.VectorIntegerSize {
    return switch (lane) {
        .i8x16 => .byte,
        .i16x8 => .half,
        .i32x4 => .word,
        .i64x2 => .double,
        else => error.InvalidGraph,
    };
}
