//! Bistromath — the T1 baseline JIT (docs/jit.md §4). A single
//! forward pass over Lantern bytecode emitting machine code per
//! opcode: inline fast paths for Smi arithmetic and moves, and a
//! tier-down to the interpreter for everything the fast path can't
//! prove. No IR, no register allocation, no speculation, no deopt
//! metadata — the frame-identity rule (docs/jit.md §4.2) makes
//! "give up" a synced store and a return.
//!
//! Execution contract: a compiled activation drives the SAME
//! `CallFrame` Lantern would (registers in the same pooled slice,
//! accumulator flushed on every exit), so the GC, the watchdog,
//! and the unwinder cannot tell which tier is running. The entry
//! returns either `done` (function completed; result in
//! `frame.accumulator`; caller pops, mirroring the interpreter's
//! plain `return_` path) or `resume_interp` (`frame.ip` set to a
//! bytecode offset; the frame stays pushed and `reEnterDispatch`
//! resumes it in Lantern mid-chunk).
//!
//! MVP scope (docs/jit.md §12 step 2): moves, constants, int32
//! arithmetic/bitwise/compares, branches, `loop_inc_lt`, and
//! `return_`. A chunk containing anything else is `dont_compile`
//! — function-granularity fallback means no mid-function bailout
//! machinery exists or is needed. Calls, property ICs, and OSR
//! arrive with step 3.

const std = @import("std");
const builtin = @import("builtin");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const op_mod = @import("../../bytecode/op.zig");
const Op = op_mod.Op;
const Value = @import("../value.zig").Value;
const Realm = @import("../realm.zig").Realm;
const interpreter = @import("../lantern/interpreter.zig");
const CallFrame = interpreter.CallFrame;
const code_alloc = @import("../jit/code_alloc.zig");
const masm_mod = @import("../jit/masm.zig");
const Masm = masm_mod.Masm;
const a64 = @import("../jit/asm_aarch64.zig");

/// Bistromath needs both an executable-memory target and an
/// emitter for the host ISA. x86_64 hosts run the engine fine but
/// stay interpreter-only until the second encoder lands
/// (docs/jit.md §14).
pub const supported = code_alloc.supported and builtin.cpu.arch == .aarch64;

/// What compiled code reports back to the dispatcher.
pub const EntryResult = enum(u32) {
    /// `frame.ip` / `frame.accumulator` are synced; resume the
    /// frame in Lantern (tier-down — docs/jit.md §4.5/§4.6).
    resume_interp = 0,
    /// The function ran to completion; the return value is in
    /// `frame.accumulator` and the caller pops the frame.
    done = 1,
};

/// Entry ABI: `(realm, frame, registers_base)`. The register-file
/// base rides as its own argument so machine code never assumes
/// Zig's slice layout.
pub const EntryFn = *const fn (*Realm, *CallFrame, [*]Value) callconv(.c) u32;

/// Size-scaled tier-up threshold (docs/jit.md §4.7): a tiny helper
/// compiles after ~30 calls, a big function waits for real heat.
/// Starting constants, tuned against the bench suite — not gospel.
pub fn tierUpThreshold(code_len: usize) u32 {
    const len: u32 = @intCast(@min(code_len, 1 << 20));
    return 512 +| (8 *| len);
}

/// The dispatcher hook: called right after a frame push, before
/// dispatch enters it. Self-gating — returns null (and the caller
/// proceeds into Lantern as if no JIT existed) unless the realm
/// has the tier enabled, the frame is a plain call, and the chunk
/// is (or just became) compiled. On `.done` the callee frame is
/// popped here and the return value handed back; on tier-down the
/// frame stays pushed mid-chunk and `reEnterDispatch` picks it up.
pub fn tryEnterTop(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
) ?Value {
    if (comptime !supported) return null;
    if (!realm.jit_enabled) return null;
    const fr = &frames.items[frames.items.len - 1];
    // Plain calls only: constructor return verdicts (§10.2.2 steps
    // 7-11), generator resumes, and async Promise wrapping all stay
    // Lantern's business (docs/jit.md §4.5).
    if (fr.is_construct or fr.generator != null or fr.wrap_return_in_promise) return null;
    const js = fr.chunk.jit_state orelse return null;
    if (js.entry == null) {
        if (js.tier != .cold) return null;
        const threshold = realm.jit_threshold_override orelse
            tierUpThreshold(fr.chunk.code.len);
        if (js.warmth < threshold) return null;
        compile(realm, fr.chunk, js);
        if (js.entry == null) return null;
    }
    const entry: EntryFn = @ptrCast(@alignCast(js.entry.?));
    switch (@as(EntryResult, @enumFromInt(entry(realm, fr, fr.registers.ptr)))) {
        .done => {
            const ret = fr.accumulator;
            fr.releaseRegisters(realm, allocator);
            _ = frames.pop();
            return ret;
        },
        .resume_interp => return null,
    }
}

/// Compile `chunk` synchronously (Sparkplug-class cost —
/// docs/jit.md §4.7).
/// Every failure path — unsupported opcode, allocator exhaustion,
/// emit OOM — leaves the chunk `dont_compile` and the engine
/// interpreted: degrading is the contract, aborting never is.
fn compile(realm: *Realm, chunk: *const Chunk, js: *Chunk.JitState) void {
    js.tier = .dont_compile;
    if (comptime !supported) return;
    const ca = realm.heap.jitCodeAllocator() orelse return;
    var c = Compiler.init(realm.heap.allocator, chunk);
    defer c.deinit();
    c.run() catch return;
    const code = ca.install(c.m.code.items) catch return;
    js.entry = @ptrCast(code.ptr);
    js.tier = .compiled;
}

const CompileError = error{ OutOfMemory, UnsupportedOp };

// Pinned registers inside compiled code (docs/jit.md §4.2). x19-x24
// are callee-saved per AAPCS64 and restored in the epilogue;
// x9-x13 are scratch.
const realm_reg: a64.Reg = .x19;
const frame_reg: a64.Reg = .x20;
const regs_reg: a64.Reg = .x21;
const acc_reg: a64.Reg = .x22;
/// Pinned `Value.fromInt32(0).bits` — the int32 tag in the high
/// half-word. `eor` against it + `lsr #48` is the tag test.
const int32_tag_reg: a64.Reg = .x23;
/// Pinned `Value.false_.bits` — the bool tag for compare results
/// and `jmp_if_*` truthiness.
const bool_tag_reg: a64.Reg = .x24;

const acc_off: u15 = @offsetOf(CallFrame, "accumulator");
const ip_off: u15 = @offsetOf(CallFrame, "ip");
const step_budget_off: usize = @offsetOf(Realm, "step_budget");
const interrupt_off: usize =
    @offsetOf(Realm, "interrupt") + @offsetOf(std.atomic.Value(bool), "raw");

const int32_tag_bits: u64 = @as(u64, Value.tag_int32) << 48;
const bool_tag_bits: u64 = Value.false_.bits;

const Compiler = struct {
    m: Masm,
    chunk: *const Chunk,
    /// One label per bytecode offset that is a branch target.
    target_labels: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    labels: std.ArrayListUnmanaged(Masm.Label) = .empty,
    /// Tier-down stubs, deduplicated by resume offset; emitted
    /// out-of-line after the body so the fast path stays straight.
    td_by_off: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    tds: std.ArrayListUnmanaged(Td) = .empty,
    done_label: Masm.Label = .{},
    tier_down_label: Masm.Label = .{},

    const Td = struct { label: Masm.Label, resume_off: u32 };

    fn init(gpa: std.mem.Allocator, chunk: *const Chunk) Compiler {
        return .{ .m = Masm.init(gpa), .chunk = chunk };
    }

    fn deinit(self: *Compiler) void {
        const gpa = self.m.gpa;
        self.target_labels.deinit(gpa);
        self.td_by_off.deinit(gpa);
        for (self.labels.items) |*l| l.fixups.deinit(gpa);
        self.labels.deinit(gpa);
        for (self.tds.items) |*t| t.label.fixups.deinit(gpa);
        self.tds.deinit(gpa);
        self.done_label.fixups.deinit(gpa);
        self.tier_down_label.fixups.deinit(gpa);
        self.m.deinit();
    }

    /// Branch-target label for a bytecode offset (created by the
    /// pre-pass; pass 2 binds it when emission reaches the offset).
    fn labelFor(self: *Compiler, bc_off: u32) !*Masm.Label {
        const gop = try self.target_labels.getOrPut(self.m.gpa, bc_off);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.labels.items.len);
            try self.labels.append(self.m.gpa, .{});
        }
        return &self.labels.items[gop.value_ptr.*];
    }

    /// Tier-down stub label for a resume offset (shared across
    /// every check that resumes at the same opcode).
    fn tdFor(self: *Compiler, resume_off: u32) !*Masm.Label {
        const gop = try self.td_by_off.getOrPut(self.m.gpa, resume_off);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.tds.items.len);
            try self.tds.append(self.m.gpa, .{ .label = .{}, .resume_off = resume_off });
        }
        return &self.tds.items[gop.value_ptr.*].label;
    }

    fn run(self: *Compiler) CompileError!void {
        try self.scanTargets();
        try self.prologue();
        try self.body();
        try self.tail();
    }

    /// Pass 1 — reject unsupported opcodes before any emission and
    /// collect branch targets so pass 2 can bind labels in order.
    fn scanTargets(self: *Compiler) CompileError!void {
        const code = self.chunk.code;
        var i: usize = 0;
        while (i < code.len) {
            const op: Op = @enumFromInt(code[i]);
            const after = i + 1 + Op.operandSize(op);
            switch (op) {
                // zig fmt: off
                .lda_undefined, .lda_null, .lda_true, .lda_false,
                .lda_hole, .lda_smi, .lda_constant, .ldar, .star,
                .mov, .add, .sub, .mul, .add_smi, .to_int32,
                .bit_and, .bit_or, .bit_xor,
                .lt, .gt, .le, .ge, .eq, .neq, .strict_eq, .strict_neq,
                .throw_if_hole, .return_ => {},
                // zig fmt: on
                .jmp, .jmp_if_true, .jmp_if_false => {
                    const off = readI16(code, i + 1);
                    _ = try self.labelFor(targetOf(after, off));
                },
                .loop_inc_lt => {
                    const off = readI16(code, i + 3);
                    _ = try self.labelFor(targetOf(after, off));
                },
                else => return error.UnsupportedOp,
            }
            i = after;
        }
    }

    fn prologue(self: *Compiler) CompileError!void {
        const m = &self.m;
        try m.emit(a64.stpPreIdxSp(.fp, .lr, -16));
        try m.emit(a64.stpPreIdxSp(.x19, .x20, -16));
        try m.emit(a64.stpPreIdxSp(.x21, .x22, -16));
        try m.emit(a64.stpPreIdxSp(.x23, .x24, -16));
        try m.emit(a64.movReg(realm_reg, .x0));
        try m.emit(a64.movReg(frame_reg, .x1));
        try m.emit(a64.movReg(regs_reg, .x2));
        try m.emit(a64.ldrImm(acc_reg, frame_reg, acc_off));
        try m.movImm64(int32_tag_reg, int32_tag_bits);
        try m.movImm64(bool_tag_reg, bool_tag_bits);
    }

    fn body(self: *Compiler) CompileError!void {
        const m = &self.m;
        const code = self.chunk.code;
        var i: usize = 0;
        while (i < code.len) {
            const bc: u32 = @intCast(i);
            if (self.target_labels.get(bc)) |idx| m.bind(&self.labels.items[idx]);
            const op: Op = @enumFromInt(code[i]);
            const after = i + 1 + Op.operandSize(op);
            switch (op) {
                .lda_undefined => try m.movImm64(acc_reg, Value.undefined_.bits),
                .lda_null => try m.movImm64(acc_reg, Value.null_.bits),
                .lda_true => try m.movImm64(acc_reg, Value.true_.bits),
                .lda_false => try m.movImm64(acc_reg, Value.false_.bits),
                .lda_hole => try m.movImm64(acc_reg, Value.hole_.bits),
                .lda_smi => {
                    const imm = readI32(code, i + 1);
                    try m.movImm64(acc_reg, Value.fromInt32(imm).bits);
                },
                .lda_constant => {
                    // Constants are chunk-owned, GC-rooted via
                    // markChunk, and the heap never moves — the
                    // Value bits are bakeable (docs/jit.md §9).
                    const k = readU16(code, i + 1);
                    try m.movImm64(acc_reg, self.chunk.constants[k].bits);
                },
                .ldar => try m.emit(a64.ldrImm(acc_reg, regs_reg, regSlot(code[i + 1]))),
                .star => try m.emit(a64.strImm(acc_reg, regs_reg, regSlot(code[i + 1]))),
                .mov => {
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try m.emit(a64.strImm(.x9, regs_reg, regSlot(code[i + 2])));
                },

                .add, .sub => {
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(acc_reg, td);
                    try m.emit(if (op == .add)
                        a64.addsRegW(.x11, .x9, acc_reg)
                    else
                        a64.subsRegW(.x11, .x9, acc_reg));
                    try m.jumpCond(.vs, td);
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },
                .mul => {
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(acc_reg, td);
                    // 64-bit product of the 32-bit payloads; the
                    // result is i32-representable iff it sign-
                    // extends to itself.
                    try m.emit(a64.smull(.x11, .x9, acc_reg));
                    try m.emit(a64.sxtw(.x12, .x11));
                    try m.emit(a64.cmpReg(.x12, .x11));
                    try m.jumpCond(.ne, td);
                    try m.emit(a64.movRegW(.x11, .x11));
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },
                .add_smi => {
                    const td = try self.tdFor(bc);
                    const imm = readI32(code, i + 2);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try m.movImm64(.x10, @as(u32, @bitCast(imm)));
                    try m.emit(a64.addsRegW(.x11, .x9, .x10));
                    try m.jumpCond(.vs, td);
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },
                .to_int32 => {
                    // §7.1.6 fast path: an int32 is its own ToInt32.
                    const td = try self.tdFor(bc);
                    try self.checkInt32(acc_reg, td);
                },
                .bit_and, .bit_or, .bit_xor => {
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(acc_reg, td);
                    try m.emit(switch (op) {
                        .bit_and => a64.andRegW(.x11, .x9, acc_reg),
                        .bit_or => a64.orrRegW(.x11, .x9, acc_reg),
                        else => a64.eorRegW(.x11, .x9, acc_reg),
                    });
                    try m.emit(a64.orrReg(acc_reg, .x11, int32_tag_reg));
                },

                .lt, .gt, .le, .ge, .eq, .neq, .strict_eq, .strict_neq => {
                    const td = try self.tdFor(bc);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(code[i + 1])));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(acc_reg, td);
                    // acc = reg CMP acc, on the int32 payloads.
                    try m.emit(a64.cmpRegW(.x9, acc_reg));
                    try m.emit(a64.csetW(.x11, switch (op) {
                        .lt => a64.Cond.lt,
                        .gt => .gt,
                        .le => .le,
                        .ge => .ge,
                        .eq, .strict_eq => .eq,
                        else => .ne,
                    }));
                    try m.emit(a64.orrReg(acc_reg, .x11, bool_tag_reg));
                },

                .jmp => {
                    const off = readI16(code, i + 1);
                    const target = targetOf(after, off);
                    if (off < 0) try self.backEdgeSafePoint(target);
                    try m.jump(try self.labelForExisting(target));
                },
                .jmp_if_true, .jmp_if_false => {
                    const td = try self.tdFor(bc);
                    const off = readI16(code, i + 1);
                    const target = targetOf(after, off);
                    // Bool-tagged accumulators only; anything else
                    // (numbers, strings, objects in a condition)
                    // tiers down to ToBoolean in Lantern.
                    try m.emit(a64.eorReg(.x11, acc_reg, bool_tag_reg));
                    try m.emit(a64.lsrImm(.x11, .x11, 48));
                    try m.jumpCbnz(.x11, td);
                    var skip = Masm.Label{};
                    defer skip.fixups.deinit(m.gpa);
                    // Invert: hop over the (possibly safepointed)
                    // taken path when the condition doesn't hold.
                    if (op == .jmp_if_true) {
                        try m.jumpTbz(acc_reg, 0, &skip);
                    } else {
                        try m.jumpTbnz(acc_reg, 0, &skip);
                    }
                    if (off < 0) try self.backEdgeSafePoint(target);
                    try m.jump(try self.labelForExisting(target));
                    m.bind(&skip);
                },
                .loop_inc_lt => {
                    const td = try self.tdFor(bc);
                    const r_counter = code[i + 1];
                    const r_bound = code[i + 2];
                    const off = readI16(code, i + 3);
                    const target = targetOf(after, off);
                    try m.emit(a64.ldrImm(.x9, regs_reg, regSlot(r_counter)));
                    try m.emit(a64.ldrImm(.x10, regs_reg, regSlot(r_bound)));
                    try self.checkInt32(.x9, td);
                    try self.checkInt32(.x10, td);
                    try m.emit(a64.addsImmW(.x11, .x9, 1));
                    try m.jumpCond(.vs, td);
                    try m.emit(a64.orrReg(.x12, .x11, int32_tag_reg));
                    try m.emit(a64.strImm(.x12, regs_reg, regSlot(r_counter)));
                    try m.emit(a64.cmpRegW(.x11, .x10));
                    var skip = Masm.Label{};
                    defer skip.fixups.deinit(m.gpa);
                    try m.jumpCond(.ge, &skip);
                    if (off < 0) try self.backEdgeSafePoint(target);
                    try m.jump(try self.labelForExisting(target));
                    m.bind(&skip);
                },

                .throw_if_hole => {
                    // §13.3.1 — a Hole in the accumulator is a TDZ
                    // read; tier down and let Lantern raise the
                    // ReferenceError with its proper message.
                    const td = try self.tdFor(bc);
                    try m.movImm64(.x9, Value.hole_.bits);
                    try m.emit(a64.cmpReg(acc_reg, .x9));
                    try m.jumpCond(.eq, td);
                },

                .return_ => try m.jump(&self.done_label),

                else => return error.UnsupportedOp,
            }
            i = after;
        }
        // Bytecode always ends in an explicit `return_`; if a chunk
        // ever falls off the end, complete with `undefined` rather
        // than running into the stubs.
        try m.movImm64(acc_reg, Value.undefined_.bits);
        try m.jump(&self.done_label);
    }

    /// The shared exits: per-resume-offset tier-down stubs (cold,
    /// out-of-line), then the done/tier-down tails and the one
    /// epilogue.
    fn tail(self: *Compiler) CompileError!void {
        const m = &self.m;
        for (self.tds.items) |*t| {
            m.bind(&t.label);
            try m.movImm64(.x9, t.resume_off);
            try m.jump(&self.tier_down_label);
        }
        m.bind(&self.done_label);
        try m.emit(a64.strImm(acc_reg, frame_reg, acc_off));
        try m.emit(a64.movz(.x0, 1, 0)); // EntryResult.done
        var epilogue = Masm.Label{};
        defer epilogue.fixups.deinit(m.gpa);
        try m.jump(&epilogue);
        // x9 = bytecode offset to resume at.
        m.bind(&self.tier_down_label);
        try m.emit(a64.strImm(.x9, frame_reg, ip_off));
        try m.emit(a64.strImm(acc_reg, frame_reg, acc_off));
        try m.emit(a64.movz(.x0, 0, 0)); // EntryResult.resume_interp
        m.bind(&epilogue);
        try m.emit(a64.ldpPostIdxSp(.x23, .x24, 16));
        try m.emit(a64.ldpPostIdxSp(.x21, .x22, 16));
        try m.emit(a64.ldpPostIdxSp(.x19, .x20, 16));
        try m.emit(a64.ldpPostIdxSp(.fp, .lr, 16));
        try m.emit(a64.ret());
    }

    /// docs/jit.md §4.6 — every loop back-edge re-checks the step
    /// budget and the host interrupt, exactly like Lantern's
    /// `loopSafePoint`. On either trigger the code tiers down to
    /// the BRANCH TARGET (state is fully committed there); Lantern
    /// then surfaces the RangeError through its own safe point.
    /// Compiled code allocates nothing, so the GC counters can't
    /// move mid-run and aren't checked here.
    fn backEdgeSafePoint(self: *Compiler, target: u32) CompileError!void {
        const m = &self.m;
        const td = try self.tdFor(target);
        try self.loadRealmU64(.x9, step_budget_off);
        try m.jumpCbz(.x9, td);
        try m.emit(a64.subImm(.x9, .x9, 1, false));
        try self.storeRealmU64(.x9, step_budget_off);
        try self.loadRealmU8(.x10, interrupt_off);
        try m.jumpCbnz(.x10, td);
    }

    /// `eor` against the pinned tag, shift the payload away, and
    /// tier down unless the high half-word matched int32.
    fn checkInt32(self: *Compiler, src: a64.Reg, td: *Masm.Label) CompileError!void {
        const m = &self.m;
        try m.emit(a64.eorReg(.x13, src, int32_tag_reg));
        try m.emit(a64.lsrImm(.x13, .x13, 48));
        try m.jumpCbnz(.x13, td);
    }

    fn labelForExisting(self: *Compiler, bc_off: u32) CompileError!*Masm.Label {
        const idx = self.target_labels.get(bc_off) orelse return error.UnsupportedOp;
        return &self.labels.items[idx];
    }

    fn loadRealmU64(self: *Compiler, dst: a64.Reg, off: usize) CompileError!void {
        const m = &self.m;
        if (off <= 32760) {
            try m.emit(a64.ldrImm(dst, realm_reg, @intCast(off)));
        } else {
            try m.emit(a64.addImm(.x13, realm_reg, @intCast(off >> 12), true));
            try m.emit(a64.ldrImm(dst, .x13, @intCast(off & 0xFFF)));
        }
    }

    fn storeRealmU64(self: *Compiler, src: a64.Reg, off: usize) CompileError!void {
        const m = &self.m;
        if (off <= 32760) {
            try m.emit(a64.strImm(src, realm_reg, @intCast(off)));
        } else {
            try m.emit(a64.addImm(.x13, realm_reg, @intCast(off >> 12), true));
            try m.emit(a64.strImm(src, .x13, @intCast(off & 0xFFF)));
        }
    }

    fn loadRealmU8(self: *Compiler, dst: a64.Reg, off: usize) CompileError!void {
        const m = &self.m;
        if (off <= 4095) {
            try m.emit(a64.ldrbImm(dst, realm_reg, @intCast(off)));
        } else {
            try m.emit(a64.addImm(.x13, realm_reg, @intCast(off >> 12), true));
            try m.emit(a64.ldrbImm(dst, .x13, @intCast(off & 0xFFF)));
        }
    }
};

fn regSlot(r: u8) u15 {
    return @as(u15, r) * 8;
}

fn targetOf(after_operand: usize, off: i16) u32 {
    return @intCast(@as(i64, @intCast(after_operand)) + off);
}

fn readI16(code: []const u8, at: usize) i16 {
    return std.mem.readInt(i16, code[at..][0..2], .little);
}

fn readU16(code: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, code[at..][0..2], .little);
}

fn readI32(code: []const u8, at: usize) i32 {
    return std.mem.readInt(i32, code[at..][0..4], .little);
}

// ── Tests ──────────────────────────────────────────────────────────
// End-to-end through the real pipeline: parse → compile → heat in
// Lantern → tier up → execute compiled → assert identical results.

const testing = std.testing;
const parser_mod = @import("../../parser/parser.zig");
const bc_compiler = @import("../../bytecode/compiler.zig");

test "jit bistromath: hot int function compiles and computes" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    const src =
        \\function f(a, b) { return (a * b + a - b) | 0; }
        \\let r = 0;
        \\let i = 0;
        \\while (i < 200) { r = f(i, 3); i = i + 1; }
        \\r;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expect(v.isInt32());
    try testing.expectEqual(@as(i32, 199 * 3 + 199 - 3), v.asInt32());
    const js = chunk.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, js.tier);
    try testing.expect(js.entry != null);
}

test "jit bistromath: non-int operands tier down and stay correct" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Heat `f` on ints until compiled, then hand it strings: the
    // `mul` tag check tiers down mid-function and Lantern finishes
    // with the spec answer ("x" * "y" → NaN).
    const src =
        \\function f(a, b) { return a * b; }
        \\let i = 0;
        \\while (i < 200) { f(3, 4); i = i + 1; }
        \\f("x", "y");
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    const js = chunk.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, js.tier);
    try testing.expect(v.isDouble());
    try testing.expect(std.math.isNan(v.asDouble()));
}

test "jit bistromath: the step budget interrupts a compiled loop" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    // Heat + tier up: the first call's 2000 back-edges alone clear
    // the threshold; the second call runs compiled. The `let` local
    // is register-promoted (body-locals promotion), so the chunk
    // carries no env opcodes and compiles whole.
    const src1 =
        \\function spin(n) { let i = 0; while (i < n) { i = i + 1; } return i; }
        \\spin(2000); spin(10);
    ;
    const program1 = try parser_mod.parseScript(arena.allocator(), src1, null);
    var chunk1 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program1, src1, null);
    defer chunk1.deinit(testing.allocator);
    const out1 = try interpreter.run(testing.allocator, &realm, &chunk1);
    const v1 = switch (out1) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 10), v1.asInt32());
    const js = chunk1.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, js.tier);

    // A compiled unbounded loop must still honour the host's step
    // budget (docs/jit.md §4.6): the back-edge safepoint tiers
    // down and Lantern raises the catchable RangeError.
    realm.step_budget = 1_000;
    const src2 = "spin(1000000000);";
    const program2 = try parser_mod.parseScript(arena.allocator(), src2, null);
    var chunk2 = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program2, src2, null);
    defer chunk2.deinit(testing.allocator);
    const out2 = try interpreter.run(testing.allocator, &realm, &chunk2);
    try testing.expect(out2 == .thrown);
}

test "jit bistromath: unsupported opcodes mark the chunk dont_compile" {
    if (comptime !supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;

    const src =
        \\function g(o) { return o.x; }
        \\let i = 0;
        \\let r = 0;
        \\while (i < 200) { r = g({ x: i }); i = i + 1; }
        \\r;
    ;
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try bc_compiler.compileScriptAsChunk(testing.allocator, &realm, &program, src, null);
    defer chunk.deinit(testing.allocator);
    const out = try interpreter.run(testing.allocator, &realm, &chunk);
    const v = switch (out) {
        .value, .yielded => |val| val,
        .thrown => return error.UncaughtException,
    };
    try testing.expectEqual(@as(i32, 199), v.asInt32());
    const js = chunk.function_templates[0].chunk.jit_state.?;
    try testing.expectEqual(Chunk.JitState.Tier.dont_compile, js.tier);
    try testing.expect(js.entry == null);
}
