//! Sequentially consistent, naturally aligned integer accesses. No helper
//! calls or optional CPU extensions; compare-exchange is strong, not weak.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const memory = @import("memory.zig");
const scratch = @import("scratch.zig");
const arm = @import("../asm_aarch64.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else @import("../masm.zig").Masm;

pub fn fence(m: *Machine) !void {
    if (comptime is_x86) try m.memoryFence() else try m.emit(arm.dmbIsh());
}

pub fn emit(m: *Machine, node: ir.Node, views_slot: usize, temporary_slot: usize, oob: *Machine.Label, unaligned: *Machine.Label) !void {
    const access = node.memory.?;
    try memory.emitBounds(m, access, views_slot, oob);
    const descriptor = access.region * @sizeOf(memory.View);
    if (comptime is_x86) {
        // Check both the logical offset and the actual host pointer. A malformed
        // host view must not turn an ordinary trap into a hardware fault.
        if (access.width != .byte) {
            try m.movImm64(.r11, access.width.bytes() - 1);
            try m.testReg64(.rax, .r11);
            try m.jumpCond(.not_equal, unaligned);
        }
        try m.load64Disp32(.r11, .rdi, @intCast(views_slot * 8));
        try m.load64Disp32(.r11, .r11, @intCast(descriptor));
        try m.addReg64(.r11, .rax);
        if (access.width != .byte) {
            try m.movImm64(.rax, access.width.bytes() - 1);
            try m.testReg64(.rax, .r11);
            try m.jumpCond(.not_equal, unaligned);
        }
        const width: x86.Masm.AtomicWidth = switch (access.width) {
            .byte => .byte,
            .half => .half,
            .word => .word,
            .double => .double,
            .quad => return error.InvalidGraph,
        };
        if (node.op == .atomic_store or node.op == .atomic_exchange) {
            try m.atomicExchange(.r11, .r10, width);
            try m.movReg64(.rax, .r10);
            try narrowX86(m, access.width, temporary_slot);
        } else if (node.op == .atomic_compare_exchange) {
            try scratch.load(m, .rax, temporary_slot);
            try m.atomicCompareExchange(.r11, .r10, width);
            try narrowX86(m, access.width, temporary_slot);
        } else {
            switch (access.width) {
                .byte => try m.load8Disp32(.rax, .r11, 0),
                .half => try m.load16Disp32(.rax, .r11, 0),
                .word => try m.load32Disp32(.rax, .r11, 0),
                .double => try m.load64Disp32(.rax, .r11, 0),
                .quad => return error.InvalidGraph,
            }
            if (node.op == .atomic_load) return;
            // RCX may hold a live allocated value. No traps or calls occur
            // between this save and restore, including failed CAS retries.
            try m.pushReg(.rcx);
            var retry: Machine.Label = .{};
            defer retry.deinit(m.gpa);
            try m.bind(&retry);
            try m.movReg64(.rcx, .rax);
            switch (node.op) {
                .atomic_add => try m.addReg64(.rcx, .r10),
                .atomic_sub => try m.subReg64(.rcx, .r10),
                .atomic_and => try m.andReg64(.rcx, .r10),
                .atomic_or => try m.orReg64(.rcx, .r10),
                .atomic_xor => try m.xorReg64(.rcx, .r10),
                else => return error.InvalidGraph,
            }
            try m.atomicCompareExchange(.r11, .rcx, width);
            try m.jumpCond(.not_equal, &retry);
            try m.popReg(.rcx);
        }
    } else {
        if (access.width != .byte) {
            try m.movImm64(.x17, access.width.bytes() - 1);
            try m.emit(arm.andReg(.x17, .x2, .x17));
            try m.jumpCbnz(.x17, unaligned);
        }
        try scratch.load(m, .x16, views_slot);
        try m.emit(arm.ldrImm(.x16, .x16, @intCast(descriptor)));
        try m.emit(arm.addReg(.x16, .x16, .x2));
        if (access.width != .byte) {
            try m.movImm64(.x17, access.width.bytes() - 1);
            try m.emit(arm.andReg(.x17, .x16, .x17));
            try m.jumpCbnz(.x17, unaligned);
        }
        const width: arm.AtomicWidth = switch (access.width) {
            .byte => .byte,
            .half => .half,
            .word => .word,
            .double => .double,
            .quad => return error.InvalidGraph,
        };
        // Full barriers also order mixed ordinary/atomic accesses and failed
        // comparisons. Later relaxation requires memory-model qualification.
        try m.emit(arm.dmbIsh());
        if (node.op == .atomic_load) {
            try m.emit(arm.atomicLoad(.x2, .x16, width, false));
        } else if (node.op == .atomic_store) {
            try m.emit(arm.atomicStore(.x3, .x16, width));
        } else {
            var retry: Machine.Label = .{};
            defer retry.deinit(m.gpa);
            var mismatch: Machine.Label = .{};
            defer mismatch.deinit(m.gpa);
            var done: Machine.Label = .{};
            defer done.deinit(m.gpa);
            if (node.expected != null) {
                try scratch.load(m, .x9, temporary_slot);
                if (access.width != .double) {
                    try m.movImm64(.x17, (@as(u64, 1) << @as(u6, @intCast(access.width.bytes() * 8))) - 1);
                    try m.emit(arm.andReg(.x9, .x9, .x17));
                }
            }
            try m.bind(&retry);
            try m.emit(arm.atomicLoad(.x2, .x16, width, true));
            if (node.expected != null) {
                try m.emit(arm.cmpReg(.x2, .x9));
                try m.jumpCond(.ne, &mismatch);
            }
            try m.emit(switch (node.op) {
                .atomic_add => arm.addReg(.x17, .x2, .x3),
                .atomic_sub => arm.subReg(.x17, .x2, .x3),
                .atomic_and => arm.andReg(.x17, .x2, .x3),
                .atomic_or => arm.orrReg(.x17, .x2, .x3),
                .atomic_xor => arm.eorReg(.x17, .x2, .x3),
                .atomic_exchange, .atomic_compare_exchange => arm.movReg(.x17, .x3),
                else => return error.InvalidGraph,
            });
            try m.emit(arm.storeReleaseExclusive(.x8, .x17, .x16, width));
            try m.jumpCbnz(.x8, &retry);
            if (node.expected != null) {
                try m.jump(&done);
                try m.bind(&mismatch);
                try m.emit(arm.clrex());
                try m.bind(&done);
            }
        }
        try m.emit(arm.dmbIsh());
    }
}

fn narrowX86(m: *Machine, width: ir.MemoryWidth, temporary_slot: usize) !void {
    // Byte/halfword XCHG/CMPXCHG preserve the high register bits. Use a
    // dedicated scratch word to zero-extend without clobbering allocated homes.
    if (width == .double) return;
    if (width == .word) return m.movReg32(.rax, .rax);
    try scratch.store(m, .rax, temporary_slot);
    if (width == .byte) try m.load8Disp32(.rax, .rdi, @intCast(temporary_slot * 8)) else try m.load16Disp32(.rax, .rdi, @intCast(temporary_slot * 8));
}
