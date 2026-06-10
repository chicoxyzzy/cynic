//! MacroAssembler facade for the JIT substrate — the instruction
//! buffer, labels with forward-fixup patching, and multi-instruction
//! helpers (64-bit immediate materialization, absolute calls).
//! Call sites stay target-independent; bodies are per-ISA
//! (docs/jit.md §7 — the SpiderMonkey model). aarch64 only today;
//! the x86_64 body is a mechanical port behind the same surface
//! (docs/jit.md §14).
//!
//! The buffer is plain heap memory — code is assembled here in
//! full, then copied into executable pages by
//! `CodeAllocator.install` (the W^X discipline lives there, not
//! here).

const std = @import("std");
const builtin = @import("builtin");
const a64 = @import("asm_aarch64.zig");
const code_alloc = @import("code_alloc.zig");

pub const Reg = a64.Reg;
pub const Cond = a64.Cond;

/// True when this build can both emit for and execute on the host —
/// what the execution tests below require.
pub const native_aarch64 = code_alloc.supported and builtin.cpu.arch == .aarch64;

pub const Masm = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Masm {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Masm) void {
        self.code.deinit(self.gpa);
        self.* = undefined;
    }

    /// Current end of the buffer, in bytes — the address the next
    /// instruction will land at.
    pub fn offset(self: *const Masm) usize {
        return self.code.items.len;
    }

    /// Append one A64 instruction word (little-endian).
    pub fn emit(self: *Masm, word: u32) error{OutOfMemory}!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        try self.code.appendSlice(self.gpa, &bytes);
    }

    /// A branch target. Branches to a not-yet-bound label emit a
    /// zero-offset placeholder and record a fixup; `bind` patches
    /// every recorded site. Every label must be bound before
    /// `install` — `finalize` asserts it.
    pub const Label = struct {
        bound: ?usize = null,
        fixups: std.ArrayListUnmanaged(Fixup) = .empty,

        const Fixup = struct {
            /// Byte offset of the branch instruction to patch.
            at: usize,
            kind: Kind,
        };
        const Kind = enum { imm26, imm19 };

        pub fn deinit(self: *Label, gpa: std.mem.Allocator) void {
            self.fixups.deinit(gpa);
            self.* = undefined;
        }
    };

    pub fn bind(self: *Masm, label: *Label) void {
        std.debug.assert(label.bound == null);
        label.bound = self.offset();
        for (label.fixups.items) |fixup| self.patch(fixup, label.bound.?);
        label.fixups.clearRetainingCapacity();
    }

    /// B <label>
    pub fn jump(self: *Masm, label: *Label) error{OutOfMemory}!void {
        if (label.bound) |target| {
            try self.emit(a64.b(deltaWords(i26, self.offset(), target)));
        } else {
            try label.fixups.append(self.gpa, .{ .at = self.offset(), .kind = .imm26 });
            try self.emit(a64.b(0));
        }
    }

    /// B.cond <label>
    pub fn jumpCond(self: *Masm, cond: Cond, label: *Label) error{OutOfMemory}!void {
        if (label.bound) |target| {
            try self.emit(a64.bCond(cond, deltaWords(i19, self.offset(), target)));
        } else {
            try label.fixups.append(self.gpa, .{ .at = self.offset(), .kind = .imm19 });
            try self.emit(a64.bCond(cond, 0));
        }
    }

    /// Materialize a 64-bit immediate with MOVZ + minimal MOVKs
    /// (zero half-words are skipped).
    pub fn movImm64(self: *Masm, rd: Reg, value: u64) error{OutOfMemory}!void {
        var emitted = false;
        var i: u3 = 0;
        while (i < 4) : (i += 1) {
            const half: u16 = @truncate(value >> (@as(u6, i) * 16));
            if (half == 0) continue;
            const hw: u2 = @intCast(i);
            try self.emit(if (emitted) a64.movk(rd, half, hw) else a64.movz(rd, half, hw));
            emitted = true;
        }
        if (!emitted) try self.emit(a64.movz(rd, 0, 0));
    }

    /// Call an absolute address through a scratch register —
    /// the helper-call shape Bistromath leans on (docs/jit.md §4.3).
    pub fn callAbs(self: *Masm, scratch: Reg, target: usize) error{OutOfMemory}!void {
        try self.movImm64(scratch, target);
        try self.emit(a64.blr(scratch));
    }

    /// Hand the finished buffer to the code allocator and get back
    /// an executable slice.
    pub fn install(self: *Masm, ca: *code_alloc.CodeAllocator) code_alloc.Error![]const u8 {
        return ca.install(self.code.items);
    }

    fn deltaWords(comptime T: type, from: usize, to: usize) T {
        const delta = @divExact(@as(isize, @intCast(to)) - @as(isize, @intCast(from)), 4);
        return @intCast(delta);
    }

    fn patch(self: *Masm, fixup: Label.Fixup, target: usize) void {
        const slot = self.code.items[fixup.at..][0..4];
        var word = std.mem.readInt(u32, slot, .little);
        switch (fixup.kind) {
            .imm26 => {
                const d = deltaWords(i26, fixup.at, target);
                word |= @as(u32, @as(u26, @bitCast(d)));
            },
            .imm19 => {
                const d = deltaWords(i19, fixup.at, target);
                word |= @as(u32, @as(u19, @bitCast(d))) << 5;
            },
        }
        std.mem.writeInt(u32, slot, word, .little);
    }
};

// ---- execution tests --------------------------------------------------------
// Encoder words running on real silicon — the strongest golden test
// there is. aarch64 hosts only; other targets skip.

const testing = std.testing;

test "jit masm: movImm64 round-trips a full 64-bit pattern" {
    if (comptime !native_aarch64) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    var m = Masm.init(testing.allocator);
    defer m.deinit();
    try m.movImm64(.x0, 0x0123_4567_89AB_CDEF);
    try m.emit(a64.ret());

    const f = code_alloc.asFn(*const fn () callconv(.c) u64, try m.install(&ca));
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), f());

    // And the sparse-halves path (skipped MOVKs).
    var m2 = Masm.init(testing.allocator);
    defer m2.deinit();
    try m2.movImm64(.x0, 0x0000_BEEF_0000_002A);
    try m2.emit(a64.ret());
    const g = code_alloc.asFn(*const fn () callconv(.c) u64, try m2.install(&ca));
    try testing.expectEqual(@as(u64, 0x0000_BEEF_0000_002A), g());
}

test "jit masm: AAPCS64 two-arg add" {
    if (comptime !native_aarch64) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    var m = Masm.init(testing.allocator);
    defer m.deinit();
    try m.emit(a64.addReg(.x0, .x0, .x1));
    try m.emit(a64.ret());

    const f = code_alloc.asFn(*const fn (u64, u64) callconv(.c) u64, try m.install(&ca));
    try testing.expectEqual(@as(u64, 42), f(40, 2));
    try testing.expectEqual(@as(u64, 0), f(0, 0));
}

test "jit masm: loads and stores through a pointer" {
    if (comptime !native_aarch64) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    // fn (p: *u64) void { p.* += 1; }
    var m = Masm.init(testing.allocator);
    defer m.deinit();
    try m.emit(a64.ldrImm(.x1, .x0, 0));
    try m.emit(a64.addImm(.x1, .x1, 1, false));
    try m.emit(a64.strImm(.x1, .x0, 0));
    try m.emit(a64.ret());

    const f = code_alloc.asFn(*const fn (*u64) callconv(.c) void, try m.install(&ca));
    var cell: u64 = 41;
    f(&cell);
    try testing.expectEqual(@as(u64, 42), cell);
}

test "jit masm: labels — backward and forward branches in a loop" {
    if (comptime !native_aarch64) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    // fn (n: u64) u64 { sum = 0; for (i = 0; i != n; i += 1) sum += i; }
    var m = Masm.init(testing.allocator);
    defer m.deinit();
    var head = Masm.Label{};
    defer head.deinit(testing.allocator);
    var done = Masm.Label{};
    defer done.deinit(testing.allocator);

    try m.movImm64(.x2, 0); // sum
    try m.movImm64(.x3, 0); // i
    m.bind(&head);
    try m.emit(a64.cmpReg(.x3, .x0));
    try m.jumpCond(.eq, &done); // forward fixup
    try m.emit(a64.addReg(.x2, .x2, .x3));
    try m.emit(a64.addImm(.x3, .x3, 1, false));
    try m.jump(&head); // backward, already bound
    m.bind(&done);
    try m.emit(a64.movReg(.x0, .x2));
    try m.emit(a64.ret());

    const f = code_alloc.asFn(*const fn (u64) callconv(.c) u64, try m.install(&ca));
    try testing.expectEqual(@as(u64, 45), f(10));
    try testing.expectEqual(@as(u64, 0), f(0));
    try testing.expectEqual(@as(u64, 4950), f(100));
}

test "jit masm: add two Smis at the Value level" {
    if (comptime !native_aarch64) return error.SkipZigTest;
    const Value = @import("../value.zig").Value;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    // fn (a: Value, b: Value) Value — both known int32-tagged.
    // Payloads add (wrapping) in the low 32 bits; the tag is
    // re-stamped on top. The real tier guards tags and overflow
    // before taking this path (docs/jit.md §4.3); this is the
    // substrate smoke of docs/jit.md §12 step 1.
    var m = Masm.init(testing.allocator);
    defer m.deinit();
    try m.emit(a64.addReg(.x2, .x0, .x1));
    try m.emit(a64.lslImm(.x2, .x2, 32));
    try m.emit(a64.lsrImm(.x2, .x2, 32));
    try m.movImm64(.x3, @as(u64, Value.tag_int32) << 48);
    try m.emit(a64.orrReg(.x0, .x2, .x3));
    try m.emit(a64.ret());

    const f = code_alloc.asFn(*const fn (u64, u64) callconv(.c) u64, try m.install(&ca));
    const sum = Value{ .bits = f(Value.fromInt32(40).bits, Value.fromInt32(2).bits) };
    try testing.expect(sum.isInt32());
    try testing.expectEqual(@as(i32, 42), sum.asInt32());
    // Negative payloads exercise the carry-masking.
    const neg = Value{ .bits = f(Value.fromInt32(-5).bits, Value.fromInt32(3).bits) };
    try testing.expect(neg.isInt32());
    try testing.expectEqual(@as(i32, -2), neg.asInt32());
}

test "jit masm: callAbs reaches a Zig helper and back" {
    if (comptime !native_aarch64) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    const Helper = struct {
        fn double(x: u64) callconv(.c) u64 {
            return x * 2;
        }
    };

    // fn (x: u64) u64 { return double(x) + 1; } — lr is
    // caller-saved state here, so push it across the call.
    var m = Masm.init(testing.allocator);
    defer m.deinit();
    try m.emit(a64.strPreIdxSp(.lr, -16));
    try m.callAbs(.x16, @intFromPtr(&Helper.double));
    try m.emit(a64.addImm(.x0, .x0, 1, false));
    try m.emit(a64.ldrPostIdxSp(.lr, 16));
    try m.emit(a64.ret());

    const f = code_alloc.asFn(*const fn (u64) callconv(.c) u64, try m.install(&ca));
    try testing.expectEqual(@as(u64, 85), f(42));
}
