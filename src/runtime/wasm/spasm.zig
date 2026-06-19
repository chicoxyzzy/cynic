//! Spasm — the WebAssembly baseline JIT (T1). docs/jit.md §6.
//!
//! A single forward pass over validated wasm bytecode (the
//! `CompiledFunc` the validator already produced, plus its O(1) branch
//! side-table — §6). The operand stack is an abstract state machine of
//! `{const, register, spill}` locations: constants fold into their
//! consumers, registers cache recent results, merges spill everything
//! (the Liftoff/Wizard-SPC simplification). No ICs, no speculation, no
//! deopt — wasm is statically typed, so the tier's only job is erasing
//! dispatch.
//!
//! Spasm shares the codegen substrate in `src/runtime/jit/` with
//! Bistromath — the per-ISA encoders, the masm facade, the
//! executable-memory allocator (§7). What it does NOT share is the
//! abstract state above the assembler: Bistromath mirrors the
//! interpreter's `CallFrame`; Spasm's operand-stack machine is its
//! whole compiler, and wasm frames live on the native stack with no GC
//! walking them.
//!
//! Build-up is incremental, like Bistromath's: each increment grows the
//! compilable function class and is gated by the wasm spec-testsuite
//! differential (a force-tier-up run must produce the identical
//! pass-set). This first increment compiles the trivial class — a body
//! that pushes constants and returns them.

const std = @import("std");
const builtin = @import("builtin");

const code_alloc = @import("../jit/code_alloc.zig");
const masm_mod = @import("../jit/masm.zig");
const a64 = @import("../jit/asm_aarch64.zig");
const CompiledFunc = @import("code.zig").CompiledFunc;
const FuncType = @import("types.zig").FuncType;
const ValType = @import("types.zig").ValType;
const Module = @import("module.zig").Module;

/// Whether this target can host Spasm. Bistromath's gate, verbatim:
/// the substrate emits aarch64 today (docs/jit.md §8/§14 keep x86_64
/// a mechanical follow-up); elsewhere the tier is a comptime no-op and
/// the interpreter runs everything.
pub const supported = code_alloc.supported and builtin.cpu.arch == .aarch64;

/// The interpreter's value cell — a 16-byte slot holding any wasm
/// scalar (low bits) or a `v128`.
pub const Cell = u128;

/// v1 boundary ABI. The interpreter already marshals a call's
/// arguments and results as `Cell` arrays (`interpreter.invoke`), so
/// the first boundary reuses that representation verbatim: `locals`
/// (x0) is the param+local cell array the caller seeded, `results`
/// (x1) is where the compiled body writes its result cells. `mem_base`
/// (x2) and `mem_len` (x3) are the active linear memory's byte pointer
/// and length — every memory op bounds-checks against `mem_len` and
/// addresses off `mem_base`. They are stable for the body's duration:
/// the only ops that resize memory (`memory.grow`) or could call into
/// resizing code (`call`) are outside the emittable class, so a compiled
/// body never observes a mid-execution change. The optimized
/// native-register boundary (the per-signature §7.1 thunks) is a later
/// increment; correctness first.
///
/// The `u32` return (w0) is the trap channel: `trap_ok` (0) means the
/// body completed and `results` is valid; a non-zero `TrapCode` means
/// the body trapped before writing results, and the caller maps it to
/// the matching `TrapError` (so a Spasm trap is indistinguishable from
/// an interpreter trap at the boundary). This is the mechanism every
/// trapping op reuses — divide-by-zero and memory bounds today.
///
/// `instance` (x5 on entry) is the opaque `*Instance` the compiled body
/// passes to the call helper when it emits a `call` (§5.4.1); a leaf body
/// never touches it. It is the 6th argument so the boundary stays
/// append-only across increments.
pub const EntryFn = *const fn (locals: [*]Cell, results: [*]Cell, mem_base: [*]u8, mem_len: u64, globals: [*]const *anyopaque, instance: *anyopaque) callconv(.c) u32;

/// Trap status codes returned in w0 (see `EntryFn`). Kept in lockstep
/// with the `w0` immediates the epilogue's trap exits emit.
pub const trap_ok: u32 = 0;
pub const trap_divide_by_zero: u32 = 1;
pub const trap_int_overflow: u32 = 2;
pub const trap_out_of_bounds: u32 = 3;
pub const trap_invalid_conversion: u32 = 4;
/// A nested `call` (§5.4.1) trapped: the call helper stored the concrete
/// `Error` (any of the 17 `TrapError` variants, or `OutOfMemory`) on the
/// instance and returned this status so `spasmRun` re-raises it without
/// the channel having to enumerate each variant.
pub const trap_pending: u32 = 5;

pub const CompileError = error{ OutOfMemory, UnsupportedOp };

/// The native call helper a compiled `call` (§5.4.1) branches to:
/// `(instance, func_index, buf) -> status`. It marshals the args staged
/// in `buf` into a nested `invoke` and writes the results back over
/// `buf`, returning `trap_ok` or `trap_pending` (the concrete error is
/// stashed on the instance — see `EntryFn`). The interpreter owns the
/// body (it re-enters `invoke`); spasm.zig only emits the `blr` to it, so
/// the address is injected here at startup to keep the module dependency
/// one-directional (interpreter imports spasm, never the reverse).
pub const CallHelperFn = *const fn (instance: *anyopaque, func_index: u32, buf: [*]Cell) callconv(.c) u32;
pub var call_helper: ?CallHelperFn = null;

// ── wasm opcodes this increment understands ─────────────────────────
const op_end: u8 = 0x0b;
const op_nop: u8 = 0x01;
const op_block: u8 = 0x02;
const op_loop: u8 = 0x03;
const op_if: u8 = 0x04;
const op_else: u8 = 0x05;
const op_br: u8 = 0x0c;
const op_br_if: u8 = 0x0d;
const op_br_table: u8 = 0x0e;
const op_return: u8 = 0x0f;
const op_call: u8 = 0x10;
const op_drop: u8 = 0x1a;
const op_select: u8 = 0x1b;
const op_local_get: u8 = 0x20;
const op_i32_const: u8 = 0x41;
const op_local_set: u8 = 0x21;
const op_local_tee: u8 = 0x22;
const op_global_get: u8 = 0x23;
const op_global_set: u8 = 0x24;
const op_i32_clz: u8 = 0x67;
const op_i32_ctz: u8 = 0x68;
const op_i32_popcnt: u8 = 0x69;
const op_i64_clz: u8 = 0x79;
const op_i64_ctz: u8 = 0x7a;
const op_i64_popcnt: u8 = 0x7b;
const op_i32_extend8_s: u8 = 0xc0;
const op_i32_extend16_s: u8 = 0xc1;
const op_i64_extend8_s: u8 = 0xc2;
const op_i64_extend16_s: u8 = 0xc3;
const op_i64_extend32_s: u8 = 0xc4;
const op_i32_add: u8 = 0x6a;
const op_i32_sub: u8 = 0x6b;
const op_i32_mul: u8 = 0x6c;
const op_i32_eqz: u8 = 0x45;
const op_i32_eq: u8 = 0x46;
const op_i32_ne: u8 = 0x47;
const op_i32_lt_s: u8 = 0x48;
const op_i32_lt_u: u8 = 0x49;
const op_i32_gt_s: u8 = 0x4a;
const op_i32_gt_u: u8 = 0x4b;
const op_i32_le_s: u8 = 0x4c;
const op_i32_le_u: u8 = 0x4d;
const op_i32_ge_s: u8 = 0x4e;
const op_i32_ge_u: u8 = 0x4f;
const op_i32_and: u8 = 0x71;
const op_i32_or: u8 = 0x72;
const op_i32_xor: u8 = 0x73;
const op_i32_rotl: u8 = 0x77;
const op_i32_rotr: u8 = 0x78;
const op_i64_rotl: u8 = 0x89;
const op_i64_rotr: u8 = 0x8a;
const op_i32_shl: u8 = 0x74;
const op_i32_shr_s: u8 = 0x75;
const op_i32_shr_u: u8 = 0x76;
const op_i32_div_s: u8 = 0x6d;
const op_i32_div_u: u8 = 0x6e;
const op_i32_rem_s: u8 = 0x6f;
const op_i32_rem_u: u8 = 0x70;
const op_i32_load: u8 = 0x28;
const op_i32_load8_s: u8 = 0x2c;
const op_i32_load8_u: u8 = 0x2d;
const op_i32_load16_s: u8 = 0x2e;
const op_i32_load16_u: u8 = 0x2f;
const op_i32_store: u8 = 0x36;
const op_i32_store8: u8 = 0x3a;
const op_i32_store16: u8 = 0x3b;
const op_i64_const: u8 = 0x42;
const op_i64_add: u8 = 0x7c;
const op_i64_sub: u8 = 0x7d;
const op_i64_mul: u8 = 0x7e;
const op_i64_and: u8 = 0x83;
const op_i64_or: u8 = 0x84;
const op_i64_xor: u8 = 0x85;
const op_i64_shl: u8 = 0x86;
const op_i64_shr_s: u8 = 0x87;
const op_i64_shr_u: u8 = 0x88;
const op_i64_eqz: u8 = 0x50;
const op_i64_eq: u8 = 0x51;
const op_i64_ne: u8 = 0x52;
const op_i64_lt_s: u8 = 0x53;
const op_i64_lt_u: u8 = 0x54;
const op_i64_gt_s: u8 = 0x55;
const op_i64_gt_u: u8 = 0x56;
const op_i64_le_s: u8 = 0x57;
const op_i64_le_u: u8 = 0x58;
const op_i64_ge_s: u8 = 0x59;
const op_i64_ge_u: u8 = 0x5a;
const op_i64_div_s: u8 = 0x7f;
const op_i64_div_u: u8 = 0x80;
const op_i64_rem_s: u8 = 0x81;
const op_i64_rem_u: u8 = 0x82;
const op_i64_load: u8 = 0x29;
const op_i64_load8_s: u8 = 0x30;
const op_i64_load8_u: u8 = 0x31;
const op_i64_load16_s: u8 = 0x32;
const op_i64_load16_u: u8 = 0x33;
const op_i64_load32_s: u8 = 0x34;
const op_i64_load32_u: u8 = 0x35;
const op_i64_store: u8 = 0x37;
const op_i64_store8: u8 = 0x3c;
const op_i64_store16: u8 = 0x3d;
const op_i64_store32: u8 = 0x3e;
const op_i32_wrap_i64: u8 = 0xa7;
const op_i64_extend_i32_s: u8 = 0xac;
const op_i64_extend_i32_u: u8 = 0xad;
const op_f64_const: u8 = 0x44;
const op_f64_abs: u8 = 0x99;
const op_f64_neg: u8 = 0x9a;
const op_f64_ceil: u8 = 0x9b;
const op_f64_floor: u8 = 0x9c;
const op_f64_trunc: u8 = 0x9d;
const op_f64_nearest: u8 = 0x9e;
const op_f64_sqrt: u8 = 0x9f;
const op_f64_add: u8 = 0xa0;
const op_f64_sub: u8 = 0xa1;
const op_f64_mul: u8 = 0xa2;
const op_f64_div: u8 = 0xa3;
const op_f64_min: u8 = 0xa4;
const op_f64_max: u8 = 0xa5;
const op_f64_copysign: u8 = 0xa6;
const op_f64_eq: u8 = 0x61;
const op_f64_ne: u8 = 0x62;
const op_f64_lt: u8 = 0x63;
const op_f64_gt: u8 = 0x64;
const op_f64_le: u8 = 0x65;
const op_f64_ge: u8 = 0x66;
const op_f32_load: u8 = 0x2a;
const op_f64_load: u8 = 0x2b;
const op_f32_store: u8 = 0x38;
const op_f64_store: u8 = 0x39;
const op_f32_const: u8 = 0x43;
const op_f32_abs: u8 = 0x8b;
const op_f32_neg: u8 = 0x8c;
const op_f32_ceil: u8 = 0x8d;
const op_f32_floor: u8 = 0x8e;
const op_f32_trunc: u8 = 0x8f;
const op_f32_nearest: u8 = 0x90;
const op_f32_sqrt: u8 = 0x91;
const op_f32_eq: u8 = 0x5b;
const op_f32_ne: u8 = 0x5c;
const op_f32_lt: u8 = 0x5d;
const op_f32_gt: u8 = 0x5e;
const op_f32_le: u8 = 0x5f;
const op_f32_ge: u8 = 0x60;
const op_f32_add: u8 = 0x92;
const op_f32_sub: u8 = 0x93;
const op_f32_mul: u8 = 0x94;
const op_f32_div: u8 = 0x95;
const op_f32_min: u8 = 0x96;
const op_f32_max: u8 = 0x97;
const op_f32_copysign: u8 = 0x98;
const op_f32_convert_i32_s: u8 = 0xb2;
const op_f32_convert_i32_u: u8 = 0xb3;
const op_f32_convert_i64_s: u8 = 0xb4;
const op_f32_convert_i64_u: u8 = 0xb5;
const op_f32_demote_f64: u8 = 0xb6;
const op_f64_convert_i32_s: u8 = 0xb7;
const op_f64_convert_i32_u: u8 = 0xb8;
const op_f64_convert_i64_s: u8 = 0xb9;
const op_f64_convert_i64_u: u8 = 0xba;
const op_f64_promote_f32: u8 = 0xbb;
const op_i32_reinterpret_f32: u8 = 0xbc;
const op_i64_reinterpret_f64: u8 = 0xbd;
const op_f32_reinterpret_i32: u8 = 0xbe;
const op_f64_reinterpret_i64: u8 = 0xbf;
// §5.4.6 — the 0xFC prefix introduces a second opcode byte (a varuint32).
// The baseline handles only the saturating truncations (sub-opcodes 0..7).
const op_misc_prefix: u8 = 0xfc;
const op_memory_size: u8 = 0x3f;
const op_i32_trunc_f32_s: u8 = 0xa8;
const op_i32_trunc_f32_u: u8 = 0xa9;
const op_i32_trunc_f64_s: u8 = 0xaa;
const op_i32_trunc_f64_u: u8 = 0xab;
const op_i64_trunc_f32_s: u8 = 0xae;
const op_i64_trunc_f32_u: u8 = 0xaf;
const op_i64_trunc_f64_s: u8 = 0xb0;
const op_i64_trunc_f64_u: u8 = 0xb1;

/// An operand-stack location in the abstract state (§6 constant
/// tracking). A `const_i32` carries a folded immediate that has not
/// touched a register; a `reg` value lives in this stack slot's fixed
/// register (depth d → x9+d, see `regForDepth`). Spill slots arrive
/// with control flow.
const Loc = union(enum) {
    const_i32: i32,
    reg: a64.Reg,
};

/// The native register caching the value at operand-stack depth `d`.
/// x9..x15 (7 slots) are the wasm operand-stack registers; x16/x17 are
/// the masm/materialization scratch, x0/x1 the boundary args. A body
/// whose stack runs deeper than the bank tiers down (returns null).
const operand_reg_count = 7;
fn regForDepth(d: usize) a64.Reg {
    return @enumFromInt(@as(u5, @intCast(9 + d)));
}

/// One open structured-control frame (§6 — the operand-stack machine's
/// control oracle). `block`/`loop`/`if` push a frame and `end` pops it;
/// a `br`/`br_if` to relative depth N targets the Nth-from-top frame.
/// The `label` is the native branch destination: bound at `end` for a
/// `block` (a forward merge), bound at the header for a `loop` (the
/// back-edge target). `height` is the operand-stack depth when the
/// frame opened, so carried values land in the canonical depth
/// registers `regForDepth(height ..)`.
const Ctrl = struct {
    label: masm_mod.Masm.Label,
    /// The `else`-arm target of an `if` (unused — and left `.empty` — for
    /// `block`/`loop`). Bound at `else`, or at the `if`'s `end` when it
    /// has no `else` (a false condition then falls straight through).
    else_label: masm_mod.Masm.Label,
    height: usize,
    /// Values a `br`/`br_if` to this frame carries. A `block`/`if`
    /// branches forward to its `end`, carrying its result arity; a
    /// `loop` branches backward to its header, carrying its param arity
    /// — 0 for every block type Spasm compiles (only a type-index block
    /// has params, and those degrade), so a back-edge carries nothing
    /// and loop-carried state lives in locals.
    branch_arity: u32,
    /// Values on the stack when the frame's `end` is reached by
    /// fall-through (the result arity). Equals `branch_arity` for a
    /// `block`/`if`; a `loop` differs (params vs results).
    result_arity: u32,
    kind: Kind,

    /// `if_then`/`if_else` track which arm of an `if` is being compiled
    /// (the `else` opcode flips one to the other).
    const Kind = enum { block, loop, if_then, if_else };
};

/// Nesting cap. Deeper structured control degrades to the interpreter
/// (never aborts — AGENTS.md robustness contract); real bodies nest far
/// shallower than this.
const max_ctrl_depth = 64;

/// Compile `func` to native code, or return `null` when the body uses
/// anything this increment can't emit yet — exactly Bistromath's
/// `dont_compile` contract: degrading to the interpreter is always
/// correct, aborting never is. `ftype` supplies the result arity/types
/// the body's final stack must match.
pub fn compile(
    gpa: std.mem.Allocator,
    ca: *code_alloc.CodeAllocator,
    func: *const CompiledFunc,
    ftype: *const FuncType,
    module: *const Module,
) CompileError!?EntryFn {
    if (comptime !supported) return null;
    // The operand-stack bank is fixed (regForDepth); a deeper body
    // tiers down.
    if (func.max_stack > operand_reg_count) return null;

    var m = masm_mod.Masm.init(gpa);
    defer m.deinit();

    // Non-leaf prologue (§5.4.1 — Spasm now emits `call`). A compiled body
    // may `blr` the call helper, which clobbers the link register x30, so
    // save it; and x5 carries the `*Instance` argument the helper needs,
    // which a `blr` also clobbers, so move it into the callee-saved x19
    // and keep it live for the body's duration. The pair push keeps SP
    // 16-byte aligned (AAPCS64). Every return path — the normal epilogue
    // and each trap exit — pops this frame before `ret`. Gating the
    // prologue on whether the body actually contains a `call` is a
    // follow-up optimization; emitting it always is correct (a leaf body
    // just pushes/pops a pair it never reads).
    try m.emit(a64.stpPreIdxSp(.x19, .lr, -16));
    try m.emit(a64.movReg(.x19, .x5));

    // The abstract operand stack (§6) — Locs are emitted into their
    // depth's register on demand. The boundary args: x0 = locals
    // (param+local cells), x1 = results, x2 = mem_base, x3 = mem_len,
    // x4 = globals base (an array of *Global). All five stay live across
    // the body; codegen scratch is x5/x16/x17.
    var stack: [operand_reg_count]Loc = undefined;
    var sp: usize = 0;

    // The structured-control stack. Frames hold a native merge label
    // bound at their `end`; an early degrade (`return null`) with frames
    // still open frees their forward-fixup buffers here.
    var ctrl: [max_ctrl_depth]Ctrl = undefined;
    var ctrl_len: usize = 0;
    defer for (ctrl[0..ctrl_len]) |*c| {
        c.label.deinit(gpa);
        c.else_label.deinit(gpa); // `.empty` for non-`if` frames — safe
    };

    // Shared out-of-line trap exits (the §trap-channel mechanism). A
    // trapping op forward-branches to one of these; each is bound and
    // emitted after the epilogue, but only if some op actually used it
    // (an unused label is never bound, so no dead exit is emitted). The
    // exit loads w0 with the `TrapCode` and returns, skipping the result
    // writes — the caller reads w0 and raises the matching `TrapError`.
    var trap_div0: masm_mod.Masm.Label = .{};
    var trap_overflow: masm_mod.Masm.Label = .{};
    var trap_oob: masm_mod.Masm.Label = .{};
    var trap_invalid: masm_mod.Masm.Label = .{};
    // §5.4.1 — the shared epilogue every return path jumps to. It pops
    // the non-leaf frame (the prologue's `stp`) and `ret`s, returning w0
    // unchanged. A trapping `call` lands here too — after the call arm
    // has released its own buffer reservation — with w0 holding the
    // helper's status.
    var epilogue: masm_mod.Masm.Label = .{};
    defer trap_div0.deinit(gpa);
    defer trap_overflow.deinit(gpa);
    defer trap_oob.deinit(gpa);
    defer trap_invalid.deinit(gpa);
    defer epilogue.deinit(gpa);
    var trap_div0_used = false;
    var trap_overflow_used = false;
    var trap_oob_used = false;
    var trap_invalid_used = false;

    const body = func.body;
    var i: usize = 0;
    while (i < body.len) {
        const op = body[i];
        i += 1;
        switch (op) {
            op_i32_const => {
                const v = readSleb32(body, &i) orelse return null;
                if (sp >= operand_reg_count) return null;
                stack[sp] = .{ .const_i32 = v };
                sp += 1;
            },
            op_nop => {},
            op_drop => {
                // Pop and discard. The only side-effecting ops (memory,
                // calls) aren't in the set, so a drop is pure stack
                // bookkeeping — the abandoned register/const just frees.
                if (sp < 1) return null;
                sp -= 1;
            },
            op_select => {
                // wasm `select`: [v1, v2, c] -> c != 0 ? v1 : v2.
                if (sp < 3) return null;
                const c = stack[sp - 1];
                const v2 = stack[sp - 2];
                const v1 = stack[sp - 3];
                sp -= 2; // pop 3, push 1; result slot is now sp-1
                if (c == .const_i32 and v1 == .const_i32 and v2 == .const_i32) {
                    stack[sp - 1] = .{ .const_i32 = if (c.const_i32 != 0) v1.const_i32 else v2.const_i32 };
                    continue;
                }
                const r1 = try materialize(&m, v1, sp - 1);
                const r2 = try materialize(&m, v2, sp);
                const rc = try materialize(&m, c, sp + 1);
                try m.movImm64(.x16, 0);
                try m.emit(a64.cmpRegW(rc, .x16));
                // r1 = (c != 0) ? v1 : v2. X-form keeps all 64 bits so an
                // i64/f64 select doesn't truncate (i32 stays zero-extended).
                try m.emit(a64.csel(r1, r1, r2, .ne));
                stack[sp - 1] = .{ .reg = r1 };
            },
            op_local_get => {
                const idx = readUleb32(body, &i) orelse return null;
                if (sp >= operand_reg_count) return null;
                if (idx >= func.local_types.len) return null;
                const cell_off = @as(u64, idx) * @sizeOf(Cell);
                switch (func.local_types[idx]) {
                    // 32-bit load zero-extends the i32 (or f32 bit pattern)
                    // from the cell's low word into the slot register.
                    .i32, .f32 => {
                        if (cell_off > 16380 or cell_off % 4 != 0) return null; // ldrImmW ceiling
                        try m.emit(a64.ldrImmW(regForDepth(sp), .x0, @intCast(cell_off)));
                    },
                    // 64-bit load reads the whole i64/f64 from the cell's low
                    // 8 bytes (an f64 is its raw bit pattern in the GP slot).
                    .i64, .f64 => {
                        if (cell_off > 32760 or cell_off % 8 != 0) return null; // ldrImm ceiling
                        try m.emit(a64.ldrImm(regForDepth(sp), .x0, @intCast(cell_off)));
                    },
                    else => return null, // f32/v128/ref locals — degrade
                }
                stack[sp] = .{ .reg = regForDepth(sp) };
                sp += 1;
            },
            op_local_set, op_local_tee => {
                const idx = readUleb32(body, &i) orelse return null;
                if (sp < 1) return null;
                if (idx >= func.local_types.len) return null;
                const lt = func.local_types[idx];
                if (lt != .i32 and lt != .i64 and lt != .f64 and lt != .f32) return null; // i32/i64/f32/f64 locals
                const cell_off = @as(u64, idx) * @sizeOf(Cell);
                if (cell_off > 32760) return null; // strImm scaled-imm ceiling
                // Materialize the top value (its slot register, or a
                // scratch for a folded constant) and store its low 64
                // bits (i32 in the low word, zeros above) to the local
                // cell. `tee` leaves the value on the stack; `set` pops.
                const reg = switch (stack[sp - 1]) {
                    .reg => |r| r,
                    .const_i32 => |v| blk: {
                        try m.movImm64(.x16, @as(u32, @bitCast(v)));
                        break :blk .x16;
                    },
                };
                try m.emit(a64.strImm(reg, .x0, @intCast(cell_off)));
                if (op == op_local_set) sp -= 1;
            },
            op_global_get => {
                // §4.4.5 global.get — x4 holds the instance globals base, an
                // array of `*Global` pointers. Load the global's pointer
                // (`[x4 + idx*8]`), then its value's low 64 bits (.value is at
                // offset 0); a scalar global's high word is canonically zero,
                // so the 64-bit read zero-extends an i32/f32. A v128 global
                // would truncate, but it has no emittable consumer, so the
                // function degrades at the op that would use it (or its result
                // type at the epilogue).
                const idx = readUleb32(body, &i) orelse return null;
                if (@as(u64, idx) * 8 > 32760) return null; // ldrImm scaled-imm ceiling
                if (sp >= operand_reg_count) return null;
                const ra = regForDepth(sp);
                try m.emit(a64.ldrImm(.x16, .x4, @intCast(idx * 8))); // *Global
                try m.emit(a64.ldrImm(ra, .x16, 0)); // .value low 64
                stack[sp] = .{ .reg = ra };
                sp += 1;
            },
            op_global_set => {
                // §4.4.6 global.set — store the top value's low 64 bits into
                // the global's value slot, then pop. Validation guarantees the
                // global is mutable, so no runtime check. x16 holds the
                // `*Global`; a folded constant materializes into x17 first so
                // the pointer load doesn't clobber it.
                const idx = readUleb32(body, &i) orelse return null;
                if (@as(u64, idx) * 8 > 32760) return null;
                if (sp < 1) return null;
                const reg = switch (stack[sp - 1]) {
                    .reg => |r| r,
                    .const_i32 => |v| blk: {
                        try m.movImm64(.x17, @as(u32, @bitCast(v)));
                        break :blk .x17;
                    },
                };
                try m.emit(a64.ldrImm(.x16, .x4, @intCast(idx * 8))); // *Global
                try m.emit(a64.strImm(reg, .x16, 0)); // store .value
                sp -= 1;
            },
            op_i32_eqz => {
                // §4.3.10 i32.eqz — unary: 1 if the operand is zero.
                if (sp < 1) return null;
                if (stack[sp - 1] == .const_i32) {
                    stack[sp - 1] = .{ .const_i32 = @intFromBool(stack[sp - 1].const_i32 == 0) };
                    continue;
                }
                const ra = stack[sp - 1].reg;
                try m.movImm64(.x16, 0);
                try m.emit(a64.cmpRegW(ra, .x16));
                try m.emit(a64.csetW(ra, .eq));
            },
            op_i32_clz, op_i32_ctz, op_i64_clz, op_i64_ctz => {
                // §4.3.2 clz/ctz. clz is the native CLZ; ctz has no direct
                // instruction, so it's RBIT (bit reverse) then CLZ — the
                // leading zeros of the reversed value are the trailing zeros
                // of the original. clz(0)/ctz(0) yield the bit width, matching
                // @clz/@ctz and the spec.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                switch (op) {
                    op_i32_clz => try m.emit(a64.clzW(ra, ra)),
                    op_i32_ctz => {
                        try m.emit(a64.rbitW(ra, ra));
                        try m.emit(a64.clzW(ra, ra));
                    },
                    op_i64_clz => try m.emit(a64.clzX(ra, ra)),
                    else => { // i64.ctz
                        try m.emit(a64.rbitX(ra, ra));
                        try m.emit(a64.clzX(ra, ra));
                    },
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_popcnt, op_i64_popcnt => {
                // §4.3.2 popcnt — no scalar GP population count, so bridge the
                // value into the vector unit (fmov to v16) and use NEON: CNT
                // counts bits per byte, ADDV sums the eight byte lanes. For
                // i32 the fmov W->S zeroes the upper four bytes, so the 8-byte
                // sum still equals the 32-bit popcount; the result bridges
                // back through the low word.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                if (op == op_i32_popcnt)
                    try m.emit(a64.fmovWtoS(.x16, ra))
                else
                    try m.emit(a64.fmovXtoD(.x16, ra));
                try m.emit(a64.cnt8b(.x16, .x16));
                try m.emit(a64.addvB(.x16, .x16));
                if (op == op_i32_popcnt)
                    try m.emit(a64.fmovStoW(ra, .x16))
                else
                    try m.emit(a64.fmovDtoX(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_extend8_s, op_i32_extend16_s, op_i64_extend8_s, op_i64_extend16_s, op_i64_extend32_s => {
                // §4.3.2 sign-extension ops — take the low byte/half/word of
                // the operand and replicate its sign bit through the result
                // (SXTB/SXTH/SXTW). The W-form result clears the cell's high
                // word; the X-form fills all 64 bits.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                switch (op) {
                    op_i32_extend8_s => try m.emit(a64.sxtbW(ra, ra)),
                    op_i32_extend16_s => try m.emit(a64.sxthW(ra, ra)),
                    op_i64_extend8_s => try m.emit(a64.sxtbX(ra, ra)),
                    op_i64_extend16_s => try m.emit(a64.sxthX(ra, ra)),
                    else => try m.emit(a64.sxtwX(ra, ra)), // i64.extend32_s
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_eq, op_i32_ne, op_i32_lt_s, op_i32_lt_u, op_i32_gt_s, op_i32_gt_u, op_i32_le_s, op_i32_le_u, op_i32_ge_s, op_i32_ge_u => {
                // §4.3.10 i32 relops — push 1/0. The signed ops use the
                // AArch64 signed conditions (lt/gt/le/ge), the unsigned
                // ops the carry-based ones (cc/hi/ls/cs).
                if (sp < 2) return null;
                const b = stack[sp - 1];
                const a = stack[sp - 2];
                sp -= 1;
                if (a == .const_i32 and b == .const_i32) {
                    const x = a.const_i32;
                    const y = b.const_i32;
                    const xu: u32 = @bitCast(x);
                    const yu: u32 = @bitCast(y);
                    const r: i32 = @intFromBool(switch (op) {
                        op_i32_eq => x == y,
                        op_i32_ne => x != y,
                        op_i32_lt_s => x < y,
                        op_i32_lt_u => xu < yu,
                        op_i32_gt_s => x > y,
                        op_i32_gt_u => xu > yu,
                        op_i32_le_s => x <= y,
                        op_i32_le_u => xu <= yu,
                        op_i32_ge_s => x >= y,
                        else => xu >= yu,
                    });
                    stack[sp - 1] = .{ .const_i32 = r };
                    continue;
                }
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.emit(a64.cmpRegW(ra, rb));
                const cond: a64.Cond = switch (op) {
                    op_i32_eq => .eq,
                    op_i32_ne => .ne,
                    op_i32_lt_s => .lt,
                    op_i32_lt_u => .cc,
                    op_i32_gt_s => .gt,
                    op_i32_gt_u => .hi,
                    op_i32_le_s => .le,
                    op_i32_le_u => .ls,
                    op_i32_ge_s => .ge,
                    else => .cs,
                };
                try m.emit(a64.csetW(ra, cond));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_shl, op_i32_shr_s, op_i32_shr_u => {
                // §4.3.10 i32 shifts — the count is masked to 5 bits
                // (mod 32), which the AArch64 variable-shift W-forms do
                // for free. Operands: [value, count].
                if (sp < 2) return null;
                const b = stack[sp - 1]; // count
                const a = stack[sp - 2]; // value
                sp -= 1;
                if (a == .const_i32 and b == .const_i32) {
                    const sh: u5 = @intCast(b.const_i32 & 31);
                    const xu: u32 = @bitCast(a.const_i32);
                    stack[sp - 1] = .{
                        .const_i32 = switch (op) {
                            op_i32_shl => @bitCast(xu << sh),
                            op_i32_shr_u => @bitCast(xu >> sh),
                            else => a.const_i32 >> sh, // shr_s arithmetic
                        },
                    };
                    continue;
                }
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                switch (op) {
                    op_i32_shl => try m.emit(a64.lslvW(ra, ra, rb)),
                    op_i32_shr_u => try m.emit(a64.lsrvW(ra, ra, rb)),
                    else => try m.emit(a64.asrvW(ra, ra, rb)), // shr_s
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_rotl, op_i32_rotr => {
                // §4.3.10 i32 rotates. RORV rotates right (count masked to 5
                // bits, matching `& 31`); AArch64 has no rotate-left, so rotl
                // is RORV by (32 - count) — RORV's mod-32 masking turns that
                // into a left rotate. Operands: [value, count].
                if (sp < 2) return null;
                const b = stack[sp - 1]; // count
                const a = stack[sp - 2]; // value
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                if (op == op_i32_rotr) {
                    try m.emit(a64.rorvW(ra, ra, rb));
                } else { // rotl = ror by (32 - count)
                    try m.movImm64(.x16, 32);
                    try m.emit(a64.subsReg(.x16, .x16, rb));
                    try m.emit(a64.rorvW(ra, ra, .x16));
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_add, op_i32_sub, op_i32_mul, op_i32_and, op_i32_or, op_i32_xor => {
                if (sp < 2) return null;
                const b = stack[sp - 1];
                const a = stack[sp - 2];
                sp -= 1;
                // Both folded — compute at compile time, wrapping per
                // wasm i32 (§4.3 iadd/isub/imul are mod 2^32).
                if (a == .const_i32 and b == .const_i32) {
                    const x: i32 = a.const_i32;
                    const y: i32 = b.const_i32;
                    stack[sp - 1] = .{ .const_i32 = switch (op) {
                        op_i32_add => x +% y,
                        op_i32_sub => x -% y,
                        op_i32_mul => x *% y,
                        op_i32_and => x & y,
                        op_i32_or => x | y,
                        else => x ^ y,
                    } };
                    continue;
                }
                // Materialize both operands into their depth registers,
                // then emit the 32-bit op writing the result into the
                // lower operand's slot.
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                switch (op) {
                    op_i32_add => try m.emit(a64.addsRegW(ra, ra, rb)),
                    op_i32_sub => try m.emit(a64.subsRegW(ra, ra, rb)),
                    op_i32_and => try m.emit(a64.andRegW(ra, ra, rb)),
                    op_i32_or => try m.emit(a64.orrRegW(ra, ra, rb)),
                    op_i32_xor => try m.emit(a64.eorRegW(ra, ra, rb)),
                    else => {
                        // §4.3 imul wants the low 32 bits of the product;
                        // smull's full 64-bit product holds them, then a
                        // W-move truncates + zero-extends for the cell.
                        try m.emit(a64.smull(ra, ra, rb));
                        try m.emit(a64.movRegW(ra, ra));
                    },
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_div_s, op_i32_div_u, op_i32_rem_s, op_i32_rem_u => {
                // §4.3.10 i32 div/rem. AArch64 division never faults, so
                // wasm's traps are explicit checks before the divide: a
                // zero divisor traps for all four ops, and INT_MIN / -1
                // overflows only div_s (rem_s of that pair is 0, which
                // sdiv+msub produce on their own). Both operands are
                // always materialized — a constant divide is rare, and
                // folding it would have to replicate this trap predicate.
                if (sp < 2) return null;
                const a = stack[sp - 2]; // dividend
                const b = stack[sp - 1]; // divisor
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);

                // Divide-by-zero trap (all four ops).
                try m.jumpCbz(rb, &trap_div0);
                trap_div0_used = true;

                if (op == op_i32_div_s) {
                    // INT_MIN / -1 overflow trap (div_s only): skip it
                    // unless the divisor is exactly -1.
                    var skip: masm_mod.Masm.Label = .{};
                    defer skip.deinit(gpa);
                    try m.movImm64(.x16, 0xFFFF_FFFF); // -1 in the low word
                    try m.emit(a64.cmpRegW(rb, .x16));
                    try m.jumpCond(.ne, &skip);
                    try m.movImm64(.x16, 0x8000_0000); // INT_MIN
                    try m.emit(a64.cmpRegW(ra, .x16));
                    try m.jumpCond(.eq, &trap_overflow);
                    trap_overflow_used = true;
                    m.bind(&skip);
                }

                switch (op) {
                    op_i32_div_s => try m.emit(a64.sdivW(ra, ra, rb)),
                    op_i32_div_u => try m.emit(a64.udivW(ra, ra, rb)),
                    op_i32_rem_s => {
                        // rem = a - (a/b)*b; the quotient lands in scratch.
                        try m.emit(a64.sdivW(.x16, ra, rb));
                        try m.emit(a64.msubW(ra, .x16, rb, ra));
                    },
                    else => { // rem_u
                        try m.emit(a64.udivW(.x16, ra, rb));
                        try m.emit(a64.msubW(ra, .x16, rb, ra));
                    },
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_load, op_i32_load8_s, op_i32_load8_u, op_i32_load16_s, op_i32_load16_u, op_f32_load => {
                // §4.4.7 i32 loads — pop the address, bounds-check the
                // effective address for the access width, then load from
                // mem_base + ea into the address's slot (consumes addr,
                // produces the value). The narrow forms zero- or
                // sign-extend into the i32 (LDRB/LDRSB, LDRH/LDRSH); the W
                // destination clears the cell's high word either way.
                const offset = readMemArg(body, &i) orelse return null;
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                const n: u32 = switch (op) {
                    op_i32_load8_s, op_i32_load8_u => 1,
                    op_i32_load16_s, op_i32_load16_u => 2,
                    else => 4,
                };
                try emitMemBounds(&m, ra, offset, n, &trap_oob);
                trap_oob_used = true;
                switch (op) {
                    op_i32_load, op_f32_load => try m.emit(a64.ldrRegW(ra, .x2, .x16)),
                    op_i32_load8_u => try m.emit(a64.ldrbRegW(ra, .x2, .x16)),
                    op_i32_load8_s => try m.emit(a64.ldrsbRegW(ra, .x2, .x16)),
                    op_i32_load16_u => try m.emit(a64.ldrhRegW(ra, .x2, .x16)),
                    else => try m.emit(a64.ldrshRegW(ra, .x2, .x16)), // load16_s
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_store, op_i32_store8, op_i32_store16, op_f32_store => {
                // §4.4.7 i32 stores — operands [addr, value]; bounds-check
                // ea for the access width, then store value's low bytes at
                // mem_base + ea (STR/STRB/STRH). Pops both, pushes nothing.
                const offset = readMemArg(body, &i) orelse return null;
                if (sp < 2) return null;
                const ra = try materialize(&m, stack[sp - 2], sp - 2); // addr
                const rv = try materialize(&m, stack[sp - 1], sp - 1); // value
                sp -= 2;
                const n: u32 = switch (op) {
                    op_i32_store8 => 1,
                    op_i32_store16 => 2,
                    else => 4,
                };
                try emitMemBounds(&m, ra, offset, n, &trap_oob);
                trap_oob_used = true;
                switch (op) {
                    op_i32_store, op_f32_store => try m.emit(a64.strRegW(rv, .x2, .x16)),
                    op_i32_store8 => try m.emit(a64.strbRegW(rv, .x2, .x16)),
                    else => try m.emit(a64.strhRegW(rv, .x2, .x16)), // store16
                }
            },
            op_i64_const => {
                // §4.4.1 i64.const — the Loc model only folds i32 consts,
                // so materialize the 64-bit immediate straight into the
                // slot's register.
                const v = readSleb64(body, &i) orelse return null;
                if (sp >= operand_reg_count) return null;
                try m.movImm64(regForDepth(sp), @bitCast(v));
                stack[sp] = .{ .reg = regForDepth(sp) };
                sp += 1;
            },
            op_i64_add, op_i64_sub, op_i64_mul, op_i64_and, op_i64_or, op_i64_xor => {
                // §4.3 i64 ALU — the X-form mirror of the i32 ops. i64
                // operands are always register-resident (no i64 const
                // folding), so there is no compile-time fold path.
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                switch (op) {
                    op_i64_add => try m.emit(a64.addReg(ra, ra, rb)),
                    op_i64_sub => try m.emit(a64.subsReg(ra, ra, rb)), // SUBS; flags unused
                    op_i64_and => try m.emit(a64.andReg(ra, ra, rb)),
                    op_i64_or => try m.emit(a64.orrReg(ra, ra, rb)),
                    op_i64_xor => try m.emit(a64.eorReg(ra, ra, rb)),
                    else => try m.emit(a64.mul(ra, ra, rb)), // i64.mul — low 64 bits
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i64_shl, op_i64_shr_s, op_i64_shr_u => {
                // §4.3.10 i64 shifts — the count masks to 6 bits (mod 64),
                // which the AArch64 variable-shift X-forms do for free.
                if (sp < 2) return null;
                const b = stack[sp - 1]; // count
                const a = stack[sp - 2]; // value
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                switch (op) {
                    op_i64_shl => try m.emit(a64.lslv(ra, ra, rb)),
                    op_i64_shr_u => try m.emit(a64.lsrv(ra, ra, rb)),
                    else => try m.emit(a64.asrv(ra, ra, rb)), // shr_s
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i64_rotl, op_i64_rotr => {
                // §4.3.10 i64 rotates — the X-form RORV (count masked to 6
                // bits); rotl is RORV by (64 - count).
                if (sp < 2) return null;
                const b = stack[sp - 1]; // count
                const a = stack[sp - 2]; // value
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                if (op == op_i64_rotr) {
                    try m.emit(a64.rorv(ra, ra, rb));
                } else { // rotl = ror by (64 - count)
                    try m.movImm64(.x16, 64);
                    try m.emit(a64.subsReg(.x16, .x16, rb));
                    try m.emit(a64.rorv(ra, ra, .x16));
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i64_eqz => {
                // §4.3.10 i64.eqz — unary; 1 if the 64-bit operand is zero.
                // The i32 result lands zero-extended in the slot register.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                try m.movImm64(.x16, 0);
                try m.emit(a64.cmpReg(ra, .x16));
                try m.emit(a64.csetW(ra, .eq));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i64_eq, op_i64_ne, op_i64_lt_s, op_i64_lt_u, op_i64_gt_s, op_i64_gt_u, op_i64_le_s, op_i64_le_u, op_i64_ge_s, op_i64_ge_u => {
                // §4.3.10 i64 relops — a full 64-bit compare producing the
                // i32 0/1 result (csetW zero-extends into the slot). The
                // signed forms use the AArch64 signed conditions, the
                // unsigned forms the carry-based ones, exactly as i32.
                if (sp < 2) return null;
                const b = stack[sp - 1];
                const a = stack[sp - 2];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.emit(a64.cmpReg(ra, rb));
                const cond: a64.Cond = switch (op) {
                    op_i64_eq => .eq,
                    op_i64_ne => .ne,
                    op_i64_lt_s => .lt,
                    op_i64_lt_u => .cc,
                    op_i64_gt_s => .gt,
                    op_i64_gt_u => .hi,
                    op_i64_le_s => .le,
                    op_i64_le_u => .ls,
                    op_i64_ge_s => .ge,
                    else => .cs, // ge_u
                };
                try m.emit(a64.csetW(ra, cond));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i64_div_s, op_i64_div_u, op_i64_rem_s, op_i64_rem_u => {
                // §4.3.10 i64 div/rem — the X-form mirror of the i32 forms,
                // reusing the same trap exits. AArch64 64-bit division
                // never faults, so a zero divisor (all four) and INT64_MIN
                // / -1 (div_s only; rem_s of that pair is 0 from sdiv+msub)
                // are explicit pre-checks. Operands are always materialized.
                if (sp < 2) return null;
                const a = stack[sp - 2]; // dividend
                const b = stack[sp - 1]; // divisor
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);

                // Divide-by-zero trap (all four). cbz is X-form, so it
                // tests the full 64-bit divisor.
                try m.jumpCbz(rb, &trap_div0);
                trap_div0_used = true;

                if (op == op_i64_div_s) {
                    // INT64_MIN / -1 overflow trap: skip unless b == -1.
                    var skip: masm_mod.Masm.Label = .{};
                    defer skip.deinit(gpa);
                    try m.movImm64(.x16, 0xFFFF_FFFF_FFFF_FFFF); // -1
                    try m.emit(a64.cmpReg(rb, .x16));
                    try m.jumpCond(.ne, &skip);
                    try m.movImm64(.x16, 0x8000_0000_0000_0000); // INT64_MIN
                    try m.emit(a64.cmpReg(ra, .x16));
                    try m.jumpCond(.eq, &trap_overflow);
                    trap_overflow_used = true;
                    m.bind(&skip);
                }

                switch (op) {
                    op_i64_div_s => try m.emit(a64.sdiv(ra, ra, rb)),
                    op_i64_div_u => try m.emit(a64.udiv(ra, ra, rb)),
                    op_i64_rem_s => {
                        try m.emit(a64.sdiv(.x16, ra, rb));
                        try m.emit(a64.msub(ra, .x16, rb, ra));
                    },
                    else => { // rem_u
                        try m.emit(a64.udiv(.x16, ra, rb));
                        try m.emit(a64.msub(ra, .x16, rb, ra));
                    },
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i64_load, op_i64_load8_s, op_i64_load8_u, op_i64_load16_s, op_i64_load16_u, op_i64_load32_s, op_i64_load32_u, op_f64_load => {
                // §4.4.7 i64 loads — bounds-check the access width, then load
                // from mem_base + ea into the address's slot. The zero-
                // extending forms reuse the W-form ldrb/ldrh/ldr (the W
                // destination clears bits 32..63, i.e. the i64 zero-extend);
                // the signed forms sign-extend to the full 64.
                const offset = readMemArg(body, &i) orelse return null;
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                const n: u32 = switch (op) {
                    op_i64_load8_s, op_i64_load8_u => 1,
                    op_i64_load16_s, op_i64_load16_u => 2,
                    op_i64_load32_s, op_i64_load32_u => 4,
                    else => 8, // i64.load
                };
                try emitMemBounds(&m, ra, offset, n, &trap_oob);
                trap_oob_used = true;
                switch (op) {
                    op_i64_load, op_f64_load => try m.emit(a64.ldrReg(ra, .x2, .x16)),
                    op_i64_load8_u => try m.emit(a64.ldrbRegW(ra, .x2, .x16)),
                    op_i64_load8_s => try m.emit(a64.ldrsbReg(ra, .x2, .x16)),
                    op_i64_load16_u => try m.emit(a64.ldrhRegW(ra, .x2, .x16)),
                    op_i64_load16_s => try m.emit(a64.ldrshReg(ra, .x2, .x16)),
                    op_i64_load32_u => try m.emit(a64.ldrRegW(ra, .x2, .x16)),
                    else => try m.emit(a64.ldrswReg(ra, .x2, .x16)), // load32_s
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i64_store, op_i64_store8, op_i64_store16, op_i64_store32, op_f64_store => {
                // §4.4.7 i64 stores — operands [addr, value]; bounds-check ea,
                // then store the value's low bytes at mem_base + ea.
                const offset = readMemArg(body, &i) orelse return null;
                if (sp < 2) return null;
                const ra = try materialize(&m, stack[sp - 2], sp - 2); // addr
                const rv = try materialize(&m, stack[sp - 1], sp - 1); // value
                sp -= 2;
                const n: u32 = switch (op) {
                    op_i64_store8 => 1,
                    op_i64_store16 => 2,
                    op_i64_store32 => 4,
                    else => 8, // i64.store
                };
                try emitMemBounds(&m, ra, offset, n, &trap_oob);
                trap_oob_used = true;
                switch (op) {
                    op_i64_store, op_f64_store => try m.emit(a64.strReg(rv, .x2, .x16)),
                    op_i64_store8 => try m.emit(a64.strbRegW(rv, .x2, .x16)),
                    op_i64_store16 => try m.emit(a64.strhRegW(rv, .x2, .x16)),
                    else => try m.emit(a64.strRegW(rv, .x2, .x16)), // store32 (low 4)
                }
            },
            op_i64_extend_i32_s => {
                // §4.3.7 i64.extend_i32_s — sign-extend the i32 operand to
                // i64; `sxtw` widens the low 32 bits across the register.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                try m.emit(a64.sxtw(ra, ra));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i64_extend_i32_u, op_i32_wrap_i64 => {
                // §4.3.7 i64.extend_i32_u and §4.3.8 i32.wrap_i64 both keep
                // the low 32 bits zero-extended — extend_i32_u widens an i32
                // (already zero-extended), wrap_i64 truncates an i64 — so a
                // W-form mov (takes the low word, clears bits 32..63) does both.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                try m.emit(a64.movRegW(ra, ra));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f64_const => {
                // §4.4.1 f64.const — an 8-byte little-endian IEEE-754 bit
                // pattern, materialized as raw bits into the slot's GP
                // register (a float lives as bits in a GP reg; FP ops bridge).
                const bits = readF64Bits(body, &i) orelse return null;
                if (sp >= operand_reg_count) return null;
                try m.movImm64(regForDepth(sp), bits);
                stack[sp] = .{ .reg = regForDepth(sp) };
                sp += 1;
            },
            op_f64_add, op_f64_sub, op_f64_mul, op_f64_div => {
                // §4.3 f64 ALU — bridge the GP-resident bit patterns into the
                // FP unit (fmov to v16/v17, distinct from GP x16/x17), compute
                // in double precision, and bridge the result back to the GP
                // slot. The operand stack stays GP-resident throughout.
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.emit(a64.fmovXtoD(.x16, ra));
                try m.emit(a64.fmovXtoD(.x17, rb));
                switch (op) {
                    op_f64_add => try m.emit(a64.faddD(.x16, .x16, .x17)),
                    op_f64_sub => try m.emit(a64.fsubD(.x16, .x16, .x17)),
                    op_f64_mul => try m.emit(a64.fmulD(.x16, .x16, .x17)),
                    else => try m.emit(a64.fdivD(.x16, .x16, .x17)), // f64.div
                }
                try m.emit(a64.fmovDtoX(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f64_abs, op_f64_neg, op_f64_ceil, op_f64_floor, op_f64_trunc, op_f64_nearest, op_f64_sqrt => {
                // §4.3.3 f64 unary — bridge the GP-resident bits into the FP
                // unit, apply the one-source op, bridge back. abs/neg are
                // sign-bit ops (FABS/FNEG preserve NaN payloads); ceil/floor/
                // trunc/nearest are the FRINTP/FRINTM/FRINTZ/FRINTN rounding
                // modes (nearest = ties-to-even); sqrt is FSQRT.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                try m.emit(a64.fmovXtoD(.x16, ra));
                switch (op) {
                    op_f64_abs => try m.emit(a64.fabsD(.x16, .x16)),
                    op_f64_neg => try m.emit(a64.fnegD(.x16, .x16)),
                    op_f64_ceil => try m.emit(a64.frintpD(.x16, .x16)),
                    op_f64_floor => try m.emit(a64.frintmD(.x16, .x16)),
                    op_f64_trunc => try m.emit(a64.frintzD(.x16, .x16)),
                    op_f64_nearest => try m.emit(a64.frintnD(.x16, .x16)),
                    else => try m.emit(a64.fsqrtD(.x16, .x16)), // f64.sqrt
                }
                try m.emit(a64.fmovDtoX(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f64_min, op_f64_max => {
                // §4.3.3 f64.min/max — the FP unit's FMIN/FMAX (the plain
                // NaN-propagating ones, not FMINNM/FMAXNM): min(-0, +0) = -0
                // and max(-0, +0) = +0, matching the spec's signed-zero rule.
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.emit(a64.fmovXtoD(.x16, ra));
                try m.emit(a64.fmovXtoD(.x17, rb));
                if (op == op_f64_min)
                    try m.emit(a64.fminD(.x16, .x16, .x17))
                else
                    try m.emit(a64.fmaxD(.x16, .x16, .x17));
                try m.emit(a64.fmovDtoX(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f64_copysign => {
                // §4.3.3 f64.copysign — magnitude of a with the sign of b, a
                // pure bit op on the GP-resident patterns (no FP unit): clear
                // a's sign (`bic` against the sign mask), extract b's sign
                // (`and`), combine (`orr`).
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.movImm64(.x16, 0x8000000000000000);
                try m.emit(a64.bicReg(ra, ra, .x16)); // |a|
                try m.emit(a64.andReg(.x17, rb, .x16)); // sign(b)
                try m.emit(a64.orrReg(ra, ra, .x17));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f64_eq, op_f64_ne, op_f64_lt, op_f64_gt, op_f64_le, op_f64_ge => {
                // §4.3.4 f64 relops — bridge both operands into the FP unit,
                // `fcmp`, then `cset` the i32 0/1 result. The ordered
                // conditions are the FP mapping (lt→mi, gt→gt, le→ls, ge→ge);
                // ne→ne is true for unordered (NaN), matching the spec.
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.emit(a64.fmovXtoD(.x16, ra));
                try m.emit(a64.fmovXtoD(.x17, rb));
                try m.emit(a64.fcmpD(.x16, .x17));
                const cond: a64.Cond = switch (op) {
                    op_f64_eq => .eq,
                    op_f64_ne => .ne,
                    op_f64_lt => .mi,
                    op_f64_gt => .gt,
                    op_f64_le => .ls,
                    else => .ge, // f64.ge
                };
                try m.emit(a64.csetW(ra, cond));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f32_const => {
                // §4.4.1 f32.const — a 4-byte little-endian pattern, the f32
                // bits materialized into the low word of the slot register.
                const bits = readF32Bits(body, &i) orelse return null;
                if (sp >= operand_reg_count) return null;
                try m.movImm64(regForDepth(sp), bits);
                stack[sp] = .{ .reg = regForDepth(sp) };
                sp += 1;
            },
            op_f32_add, op_f32_sub, op_f32_mul, op_f32_div => {
                // §4.3 f32 ALU — the S-form bridge: the f32 bits live in the
                // low word of the GP slot register, so `fmov` W→S into the
                // FP unit, compute, and `fmov` S→W back.
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.emit(a64.fmovWtoS(.x16, ra));
                try m.emit(a64.fmovWtoS(.x17, rb));
                switch (op) {
                    op_f32_add => try m.emit(a64.faddS(.x16, .x16, .x17)),
                    op_f32_sub => try m.emit(a64.fsubS(.x16, .x16, .x17)),
                    op_f32_mul => try m.emit(a64.fmulS(.x16, .x16, .x17)),
                    else => try m.emit(a64.fdivS(.x16, .x16, .x17)), // f32.div
                }
                try m.emit(a64.fmovStoW(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f32_abs, op_f32_neg, op_f32_ceil, op_f32_floor, op_f32_trunc, op_f32_nearest, op_f32_sqrt => {
                // §4.3.3 f32 unary — the S-form mirror of the f64 unary ops:
                // the f32 bits bridge W→S into the FP unit, the one-source op
                // applies, and the result bridges S→W back. abs/neg are the
                // sign-bit FABS/FNEG; ceil/floor/trunc/nearest the FRINT modes
                // (nearest = ties-to-even); sqrt is FSQRT.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                try m.emit(a64.fmovWtoS(.x16, ra));
                switch (op) {
                    op_f32_abs => try m.emit(a64.fabsS(.x16, .x16)),
                    op_f32_neg => try m.emit(a64.fnegS(.x16, .x16)),
                    op_f32_ceil => try m.emit(a64.frintpS(.x16, .x16)),
                    op_f32_floor => try m.emit(a64.frintmS(.x16, .x16)),
                    op_f32_trunc => try m.emit(a64.frintzS(.x16, .x16)),
                    op_f32_nearest => try m.emit(a64.frintnS(.x16, .x16)),
                    else => try m.emit(a64.fsqrtS(.x16, .x16)), // f32.sqrt
                }
                try m.emit(a64.fmovStoW(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f32_min, op_f32_max => {
                // §4.3.3 f32.min/max — the S-form FMIN/FMAX, same NaN-
                // propagating, signed-zero semantics as the f64 pair.
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.emit(a64.fmovWtoS(.x16, ra));
                try m.emit(a64.fmovWtoS(.x17, rb));
                if (op == op_f32_min)
                    try m.emit(a64.fminS(.x16, .x16, .x17))
                else
                    try m.emit(a64.fmaxS(.x16, .x16, .x17));
                try m.emit(a64.fmovStoW(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f32_copysign => {
                // §4.3.3 f32.copysign — the W-form bit op: |a| (bic) | sign(b)
                // (and), combined with orr. The W-form ops zero the high word,
                // leaving the canonical 32-bit f32 pattern.
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.movImm64(.x16, 0x80000000);
                try m.emit(a64.bicRegW(ra, ra, .x16)); // |a|
                try m.emit(a64.andRegW(.x17, rb, .x16)); // sign(b)
                try m.emit(a64.orrRegW(ra, ra, .x17));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f32_eq, op_f32_ne, op_f32_lt, op_f32_gt, op_f32_le, op_f32_ge => {
                // §4.3.4 f32 relops — the S-form mirror of the f64 compares,
                // same FP condition mapping (NaN makes ordered relops false).
                if (sp < 2) return null;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                sp -= 1;
                const ra = try materialize(&m, a, sp - 1);
                const rb = try materialize(&m, b, sp);
                try m.emit(a64.fmovWtoS(.x16, ra));
                try m.emit(a64.fmovWtoS(.x17, rb));
                try m.emit(a64.fcmpS(.x16, .x17));
                const cond: a64.Cond = switch (op) {
                    op_f32_eq => .eq,
                    op_f32_ne => .ne,
                    op_f32_lt => .mi,
                    op_f32_gt => .gt,
                    op_f32_le => .ls,
                    else => .ge, // f32.ge
                };
                try m.emit(a64.csetW(ra, cond));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f32_convert_i32_s, op_f32_convert_i32_u, op_f32_convert_i64_s, op_f32_convert_i64_u => {
                // §4.3.3 f32.convert_i{32,64}_{s,u} — SCVTF/UCVTF read the
                // integer straight from the GP slot (no input bridge) and
                // write the FP unit; the f32 result bridges back through the
                // low word. The W-form reads the low 32 of an i32 operand;
                // the X-form reads all 64 of an i64.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                switch (op) {
                    op_f32_convert_i32_s => try m.emit(a64.scvtfSfromW(.x16, ra)),
                    op_f32_convert_i32_u => try m.emit(a64.ucvtfSfromW(.x16, ra)),
                    op_f32_convert_i64_s => try m.emit(a64.scvtfSfromX(.x16, ra)),
                    else => try m.emit(a64.ucvtfSfromX(.x16, ra)), // f32.convert_i64_u
                }
                try m.emit(a64.fmovStoW(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f64_convert_i32_s, op_f64_convert_i32_u, op_f64_convert_i64_s, op_f64_convert_i64_u => {
                // §4.3.3 f64.convert_i{32,64}_{s,u} — the D-form mirror.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                switch (op) {
                    op_f64_convert_i32_s => try m.emit(a64.scvtfDfromW(.x16, ra)),
                    op_f64_convert_i32_u => try m.emit(a64.ucvtfDfromW(.x16, ra)),
                    op_f64_convert_i64_s => try m.emit(a64.scvtfDfromX(.x16, ra)),
                    else => try m.emit(a64.ucvtfDfromX(.x16, ra)), // f64.convert_i64_u
                }
                try m.emit(a64.fmovDtoX(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_i32_reinterpret_f32, op_i64_reinterpret_f64, op_f32_reinterpret_i32, op_f64_reinterpret_i64 => {
                // §4.3.5 reinterpret — a pure type relabel. The value already
                // lives as raw bits in its GP slot, so changing how those bits
                // are read costs no instructions; leave the location as-is.
                if (sp < 1) return null;
            },
            op_i32_trunc_f32_s, op_i32_trunc_f32_u, op_i32_trunc_f64_s, op_i32_trunc_f64_u, op_i64_trunc_f32_s, op_i64_trunc_f32_u, op_i64_trunc_f64_s, op_i64_trunc_f64_u => {
                // §4.3.3 trapping float→int truncation. FCVTZS/FCVTZU alone
                // would saturate / map NaN to 0, but these ops must trap, so
                // an explicit NaN test (→ invalid-conversion) and range test
                // (→ overflow) precede the convert. The [lo, hi) bounds are
                // the interpreter's exact representable limits per (Int, Float)
                // pair (see truncTrap), so the in-range FCVTZ never saturates.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                trap_invalid_used = true;
                trap_overflow_used = true;
                switch (op) {
                    op_i32_trunc_f32_s => try emitTruncTrap(&m, ra, true, false, true, -2147483648.0, true, 2147483648.0, &trap_invalid, &trap_overflow),
                    op_i32_trunc_f32_u => try emitTruncTrap(&m, ra, true, false, false, -1.0, false, 4294967296.0, &trap_invalid, &trap_overflow),
                    op_i32_trunc_f64_s => try emitTruncTrap(&m, ra, false, false, true, -2147483649.0, false, 2147483648.0, &trap_invalid, &trap_overflow),
                    op_i32_trunc_f64_u => try emitTruncTrap(&m, ra, false, false, false, -1.0, false, 4294967296.0, &trap_invalid, &trap_overflow),
                    op_i64_trunc_f32_s => try emitTruncTrap(&m, ra, true, true, true, -9223372036854775808.0, true, 9223372036854775808.0, &trap_invalid, &trap_overflow),
                    op_i64_trunc_f32_u => try emitTruncTrap(&m, ra, true, true, false, -1.0, false, 18446744073709551616.0, &trap_invalid, &trap_overflow),
                    op_i64_trunc_f64_s => try emitTruncTrap(&m, ra, false, true, true, -9223372036854775808.0, true, 9223372036854775808.0, &trap_invalid, &trap_overflow),
                    else => try emitTruncTrap(&m, ra, false, true, false, -1.0, false, 18446744073709551616.0, &trap_invalid, &trap_overflow), // i64.trunc_f64_u
                }
                stack[sp - 1] = .{ .reg = ra };
            },
            op_memory_size => {
                // §4.4.9 memory.size — the current size in 64 KiB pages, i.e.
                // mem_len >> 16 (x3 carries the byte length). The result type
                // (i32 for a 32-bit memory, i64 for memory64) is validation's
                // concern; the page count is the same shift either way.
                const mem_idx = readUleb32(body, &i) orelse return null;
                if (mem_idx != 0) return null; // single memory only
                if (sp >= operand_reg_count) return null;
                const ra = regForDepth(sp);
                try m.emit(a64.lsrImm(ra, .x3, 16));
                stack[sp] = .{ .reg = ra };
                sp += 1;
            },
            op_misc_prefix => {
                // The 0xFC prefix. Sub-opcodes 0..7 are the saturating
                // truncations; 10/11 are memory.copy/memory.fill. Anything
                // else (the rest of bulk memory, tables) degrades.
                const sub = readUleb32(body, &i) orelse return null;
                if (sub <= 7) {
                    // §4.3.3 saturating truncations. FCVTZS/FCVTZU round toward
                    // zero and, on NaN or out-of-range, yield 0 / saturate to
                    // the integer min/max — exactly trunc_sat, no trap needed.
                    if (sp < 1) return null;
                    const ra = try materialize(&m, stack[sp - 1], sp - 1);
                    // Bridge the float in by its source width: f32 (sub
                    // 0/1/4/5) through the low word, f64 (2/3/6/7) full slot.
                    if ((sub & 0x2) == 0)
                        try m.emit(a64.fmovWtoS(.x16, ra))
                    else
                        try m.emit(a64.fmovXtoD(.x16, ra));
                    switch (sub) {
                        0 => try m.emit(a64.fcvtzsWfromS(ra, .x16)), // i32.trunc_sat_f32_s
                        1 => try m.emit(a64.fcvtzuWfromS(ra, .x16)), // i32.trunc_sat_f32_u
                        2 => try m.emit(a64.fcvtzsWfromD(ra, .x16)), // i32.trunc_sat_f64_s
                        3 => try m.emit(a64.fcvtzuWfromD(ra, .x16)), // i32.trunc_sat_f64_u
                        4 => try m.emit(a64.fcvtzsXfromS(ra, .x16)), // i64.trunc_sat_f32_s
                        5 => try m.emit(a64.fcvtzuXfromS(ra, .x16)), // i64.trunc_sat_f32_u
                        6 => try m.emit(a64.fcvtzsXfromD(ra, .x16)), // i64.trunc_sat_f64_s
                        else => try m.emit(a64.fcvtzuXfromD(ra, .x16)), // i64.trunc_sat_f64_u
                    }
                    stack[sp - 1] = .{ .reg = ra };
                } else if (sub == 11) {
                    // §4.4.8 memory.fill — set n bytes at dst to the low byte
                    // of val. The operands are [dst, val, n] (n on top). The
                    // bounds check is up-front and overflow-safe (the spec's
                    // rangeInBounds: dst > len or n > len - dst traps before any
                    // write), then an inline byte loop keeps the op leaf — no
                    // helper, no frame.
                    const mem_idx = readUleb32(body, &i) orelse return null;
                    if (mem_idx != 0) return null; // single memory only
                    if (sp < 3) return null;
                    const r_n = try materialize(&m, stack[sp - 1], sp - 1);
                    const r_val = try materialize(&m, stack[sp - 2], sp - 2);
                    const r_dst = try materialize(&m, stack[sp - 3], sp - 3);
                    try m.emit(a64.subsReg(.x17, .x3, r_dst)); // x17 = mem_len - dst
                    try m.jumpCond(.cc, &trap_oob); // dst > mem_len
                    try m.emit(a64.cmpReg(.x17, r_n));
                    try m.jumpCond(.cc, &trap_oob); // (mem_len - dst) < n
                    trap_oob_used = true;
                    // while (n != 0) { mem_base[dst] = val; dst += 1; n -= 1; }
                    var fill_loop: masm_mod.Masm.Label = .{};
                    var fill_done: masm_mod.Masm.Label = .{};
                    defer fill_loop.deinit(gpa);
                    defer fill_done.deinit(gpa);
                    m.bind(&fill_loop);
                    try m.jumpCbz(r_n, &fill_done);
                    try m.emit(a64.strbRegW(r_val, .x2, r_dst));
                    try m.emit(a64.addImm(r_dst, r_dst, 1, false));
                    try m.emit(a64.subImm(r_n, r_n, 1, false));
                    try m.jump(&fill_loop);
                    m.bind(&fill_done);
                    sp -= 3;
                } else if (sub == 10) {
                    // §4.4.7 memory.copy — move n bytes from src to dst
                    // (memmove). Operands [dst, src, n]; the encoding carries
                    // two memory indices (dst, src), only single-memory
                    // compiles. Bounds-check both ranges up front, then copy in
                    // the overlap-safe direction: forward (low→high) when
                    // dst <= src, else backward (high→low) so an overlapping
                    // copy never reads a byte it already overwrote. Inline
                    // loops keep it leaf.
                    const dst_mi = readUleb32(body, &i) orelse return null;
                    const src_mi = readUleb32(body, &i) orelse return null;
                    if (dst_mi != 0 or src_mi != 0) return null;
                    if (sp < 3) return null;
                    const r_n = try materialize(&m, stack[sp - 1], sp - 1);
                    const r_src = try materialize(&m, stack[sp - 2], sp - 2);
                    const r_dst = try materialize(&m, stack[sp - 3], sp - 3);
                    // Both [src, src+n) and [dst, dst+n) must lie in [0, len).
                    try m.emit(a64.subsReg(.x17, .x3, r_src));
                    try m.jumpCond(.cc, &trap_oob);
                    try m.emit(a64.cmpReg(.x17, r_n));
                    try m.jumpCond(.cc, &trap_oob);
                    try m.emit(a64.subsReg(.x17, .x3, r_dst));
                    try m.jumpCond(.cc, &trap_oob);
                    try m.emit(a64.cmpReg(.x17, r_n));
                    try m.jumpCond(.cc, &trap_oob);
                    trap_oob_used = true;
                    var fwd_loop: masm_mod.Masm.Label = .{};
                    var bwd_loop: masm_mod.Masm.Label = .{};
                    var copy_done: masm_mod.Masm.Label = .{};
                    defer fwd_loop.deinit(gpa);
                    defer bwd_loop.deinit(gpa);
                    defer copy_done.deinit(gpa);
                    try m.emit(a64.cmpReg(r_dst, r_src));
                    try m.jumpCond(.ls, &fwd_loop); // dst <= src -> forward
                    // backward: start past the end and walk down.
                    try m.emit(a64.addReg(r_dst, r_dst, r_n));
                    try m.emit(a64.addReg(r_src, r_src, r_n));
                    m.bind(&bwd_loop);
                    try m.jumpCbz(r_n, &copy_done);
                    try m.emit(a64.subImm(r_dst, r_dst, 1, false));
                    try m.emit(a64.subImm(r_src, r_src, 1, false));
                    try m.emit(a64.ldrbRegW(.x16, .x2, r_src));
                    try m.emit(a64.strbRegW(.x16, .x2, r_dst));
                    try m.emit(a64.subImm(r_n, r_n, 1, false));
                    try m.jump(&bwd_loop);
                    m.bind(&fwd_loop);
                    try m.jumpCbz(r_n, &copy_done);
                    try m.emit(a64.ldrbRegW(.x16, .x2, r_src));
                    try m.emit(a64.strbRegW(.x16, .x2, r_dst));
                    try m.emit(a64.addImm(r_src, r_src, 1, false));
                    try m.emit(a64.addImm(r_dst, r_dst, 1, false));
                    try m.emit(a64.subImm(r_n, r_n, 1, false));
                    try m.jump(&fwd_loop);
                    m.bind(&copy_done);
                    sp -= 3;
                } else return null;
            },
            op_f32_demote_f64 => {
                // §4.3.5 f32.demote_f64 — narrow the double to single via FCVT,
                // bridging the f64 bits into the FP unit and the f32 result back.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                try m.emit(a64.fmovXtoD(.x16, ra));
                try m.emit(a64.fcvtDtoS(.x16, .x16));
                try m.emit(a64.fmovStoW(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_f64_promote_f32 => {
                // §4.3.5 f64.promote_f32 — widen the single to double via FCVT.
                if (sp < 1) return null;
                const ra = try materialize(&m, stack[sp - 1], sp - 1);
                try m.emit(a64.fmovWtoS(.x16, ra));
                try m.emit(a64.fcvtStoD(.x16, .x16));
                try m.emit(a64.fmovDtoX(ra, .x16));
                stack[sp - 1] = .{ .reg = ra };
            },
            op_block => {
                // §3.3.5 — push a control frame. The block's result
                // arity comes from its block type; a `block` consumes no
                // operand values (only multi-value param blocks would,
                // and those degrade), so the merge base is the current
                // height. The label binds forward, at the block's `end`.
                const arity = readBlockArity(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                ctrl[ctrl_len] = .{ .label = .{}, .else_label = .{}, .height = sp, .branch_arity = arity, .result_arity = arity, .kind = .block };
                ctrl_len += 1;
            },
            op_loop => {
                // §3.3.5 — a loop's branch target is its header, so the
                // label binds here, at the back-edge destination, before
                // the body. The compilable block types have no params, so
                // a back-edge carries nothing (branch_arity 0) and the
                // header merge stays register-resident: the operand
                // registers below `height` are frozen across the loop
                // (validation forbids the body reaching beneath its base)
                // and nothing is carried in, so entry and every back-edge
                // agree with no spill.
                const arity = readBlockArity(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                ctrl[ctrl_len] = .{ .label = .{}, .else_label = .{}, .height = sp, .branch_arity = 0, .result_arity = arity, .kind = .loop };
                m.bind(&ctrl[ctrl_len].label);
                ctrl_len += 1;
            },
            op_if => {
                // §3.3.5 — pop the condition; when it is zero, branch to
                // the `else` arm (or, for an `if` with no `else`, straight
                // to the `end`). The then-arm runs on the fall-through.
                if (sp < 1) return null;
                sp -= 1;
                const cond = stack[sp];
                const arity = readBlockArity(body, &i) orelse return null;
                if (ctrl_len >= max_ctrl_depth) return null;
                const rc = try materialize(&m, cond, sp);
                ctrl[ctrl_len] = .{ .label = .{}, .else_label = .{}, .height = sp, .branch_arity = arity, .result_arity = arity, .kind = .if_then };
                try m.jumpCbz(rc, &ctrl[ctrl_len].else_label);
                ctrl_len += 1;
            },
            op_else => {
                // §3.3.5 — end of the then-arm: canonicalize its results,
                // jump past the else-arm to the merge, then bind the
                // else label so a false condition lands at the else-arm.
                if (ctrl_len == 0) return null;
                const c = &ctrl[ctrl_len - 1];
                if (c.kind != .if_then) return null;
                if (sp != c.height + c.result_arity) return null;
                var d: usize = c.height;
                while (d < c.height + c.result_arity) : (d += 1) {
                    const r = try materialize(&m, stack[d], d);
                    stack[d] = .{ .reg = r };
                }
                try m.jump(&c.label);
                m.bind(&c.else_label);
                c.kind = .if_else;
                sp = c.height; // the else-arm starts with a fresh stack
            },
            op_br => {
                // §3.3.8 — unconditional branch. Canonicalize the carried
                // values into the target frame's merge registers, jump,
                // then skip the now-unreachable rest of the current frame.
                const depth = readUleb32(body, &i) orelse return null;
                if (depth >= ctrl_len) return null;
                const target = &ctrl[ctrl_len - 1 - depth];
                const arity = target.branch_arity;
                if (sp < arity) return null;
                // v1 register-resident merge (pop_count == 0), as br_if.
                if (sp != target.height + arity) return null;
                var d: usize = target.height;
                while (d < target.height + arity) : (d += 1) {
                    const r = try materialize(&m, stack[d], d);
                    stack[d] = .{ .reg = r };
                }
                try m.jump(&target.label);
                // The rest of the current frame is dead (§3.3 — code
                // after an unconditional branch is unreachable until the
                // frame closes). The terminator is the frame's `end` for
                // a block/loop; for an `if`'s then-arm it is the `else`,
                // which the skipper doesn't track — so a `br` directly
                // inside an `if` arm degrades for now.
                const cur = &ctrl[ctrl_len - 1];
                if (cur.kind == .if_then or cur.kind == .if_else) return null;
                skipToFrameEnd(body, &i) orelse return null;
                // The skipper consumed the current frame's `end`. No
                // fall-through reaches it, so bind the label (resolving
                // any forward branch that targeted it) without
                // materializing, then restore the stack to the frame's
                // result type for the continuation — those result values
                // were placed in the canonical registers by whatever
                // branch reaches the merge.
                if (cur.kind == .block) m.bind(&cur.label);
                cur.label.deinit(gpa);
                cur.else_label.deinit(gpa); // `.empty` for block/loop — safe
                sp = cur.height + cur.result_arity;
                var r: usize = cur.height;
                while (r < cur.height + cur.result_arity) : (r += 1) {
                    stack[r] = .{ .reg = regForDepth(r) };
                }
                ctrl_len -= 1;
            },
            op_br_if => {
                // §3.3.8 — pop the condition, branch to the target
                // frame's merge label when it is non-zero, else fall
                // through (always reachable — no dead code follows).
                const depth = readUleb32(body, &i) orelse return null;
                if (sp < 1) return null;
                sp -= 1;
                const cond = stack[sp];
                if (depth >= ctrl_len) return null;
                const target = &ctrl[ctrl_len - 1 - depth];
                const arity = target.branch_arity;
                // v1 keeps the merge entirely register-resident: require
                // the stack to sit exactly at the target's base + arity
                // (pop_count == 0), so the carried values already occupy
                // their canonical depth registers. Live values beneath
                // the carried set degrade to the interpreter.
                if (sp != target.height + arity) return null;
                // Canonicalize the carried values (materialize folded
                // constants; a `.reg` is already in place by the
                // depth→register invariant). The register is hoisted out
                // of the union initializer on purpose: writing
                // `stack[d] = .{ .reg = materialize(.., stack[d], ..) }`
                // would let result-location semantics stamp the `.reg` tag
                // onto stack[d] before `materialize` reads it, turning a
                // folded constant into a garbage register.
                var d: usize = target.height;
                while (d < target.height + arity) : (d += 1) {
                    const r = try materialize(&m, stack[d], d);
                    stack[d] = .{ .reg = r };
                }
                // The condition lands in its own register, disjoint and
                // above the carried set; branch when non-zero.
                const rc = try materialize(&m, cond, sp);
                try m.jumpCbnz(rc, &target.label);
            },
            op_br_table => {
                // §3.3.8 — pop the index and dispatch: a linear compare
                // chain branches to table[index] for index < n, else to
                // the default label. v1 requires every target to carry no
                // values (the common switch shape — a switch dispatches on
                // a scalar, carrying no operands), so the targets' differing
                // merge bases need no register shuffle.
                if (sp < 1) return null;
                sp -= 1;
                const index_reg = try materialize(&m, stack[sp], sp);
                const n = readUleb32(body, &i) orelse return null;
                var j: u32 = 0;
                while (j < n) : (j += 1) {
                    const lbl = readUleb32(body, &i) orelse return null;
                    if (lbl >= ctrl_len) return null;
                    const t = &ctrl[ctrl_len - 1 - lbl];
                    if (t.branch_arity != 0) return null;
                    if (j > std.math.maxInt(u12)) return null; // cmpImm imm12 ceiling
                    try m.emit(a64.cmpImm(index_reg, @intCast(j), false));
                    try m.jumpCond(.eq, &t.label);
                }
                const def = readUleb32(body, &i) orelse return null;
                if (def >= ctrl_len) return null;
                const dt = &ctrl[ctrl_len - 1 - def];
                if (dt.branch_arity != 0) return null;
                try m.jump(&dt.label);
                // An unconditional multi-branch — the rest of the current
                // frame is unreachable. Close it exactly as `br` does.
                const cur = &ctrl[ctrl_len - 1];
                if (cur.kind == .if_then or cur.kind == .if_else) return null;
                skipToFrameEnd(body, &i) orelse return null;
                if (cur.kind == .block) m.bind(&cur.label);
                cur.label.deinit(gpa);
                cur.else_label.deinit(gpa);
                sp = cur.height + cur.result_arity;
                var r: usize = cur.height;
                while (r < cur.height + cur.result_arity) : (r += 1) {
                    stack[r] = .{ .reg = regForDepth(r) };
                }
                ctrl_len -= 1;
            },
            op_call => {
                // §5.4.1 call — the first non-leaf Spasm op. Read the
                // callee index and its signature, marshal the top
                // `nparams` operand-stack values into a per-frame buffer,
                // `blr` the native call helper (which re-enters `invoke`),
                // then load the `nresults` result cells back onto the
                // operand stack. A non-zero status from the helper (a
                // nested trap) is propagated through the shared epilogue.
                if (call_helper == null) return null; // helper not wired
                const fidx = readUleb32(body, &i) orelse return null;
                const callee = calleeFuncType(module, fidx) orelse return null;
                const nparams: usize = callee.params.len;
                const nresults: usize = callee.results.len;
                // Increment 1: only scalar params/results travel through
                // the cell buffer (the low 64 bits carry the value; an i32
                // is zero-extended). A v128/ref operand degrades.
                for (callee.params) |t| if (t != .i32 and t != .i64 and t != .f32 and t != .f64) return null;
                for (callee.results) |t| if (t != .i32 and t != .i64 and t != .f32 and t != .f64) return null;
                // Operands live *below* the args (a call whose result feeds
                // a pending operand) must survive the helper call: its
                // callconv(.c) clobbers the whole operand bank (x9..x15) and
                // the caller-saved boundary scratch. `below` is how many,
                // spilled into the frame alongside the boundary registers and
                // reloaded after. Validation guarantees sp >= nparams; every
                // live operand is a scalar (a v128/ref producer degraded
                // upstream), so each fits one 8-byte slot.
                if (sp < nparams) return null;
                const below = sp - nparams;
                // The post-call stack is the survivors plus the results; it
                // must fit the operand bank.
                if (below + nresults > operand_reg_count) return null;

                // Per-frame buffer, three regions:
                //   [0 .. bufcells*16)         args-in / results-out cells
                //   [spill_off .. +40)         the five caller-saved boundary
                //                              registers x0..x4
                //   [op_spill_off .. +below*8) the live operands below the
                //                              args, one 8-byte slot each
                // Round the whole reservation up to a 16-byte multiple
                // (AAPCS64 SP alignment).
                const bufcells = @max(nparams, nresults);
                const spill_off: u15 = @intCast(bufcells * @sizeOf(Cell));
                const op_spill_off: u15 = spill_off + 40;
                const raw_frame = @as(usize, bufcells) * @sizeOf(Cell) + 40 + below * 8;
                const framebytes: u12 = @intCast((raw_frame + 15) & ~@as(usize, 15));

                // Materialize the args into their slot registers (a
                // `.const_i32` arg becomes regForDepth(below+k); a `.reg` arg
                // already is) before any boundary shuffle clobbers the
                // scratch. Args are the top `nparams`: depth below..sp-1.
                // Below-operands are handled separately — a constant one is
                // never put in a register (see the spill below).
                {
                    var k: usize = 0;
                    while (k < nparams) : (k += 1) _ = try materialize(&m, stack[below + k], below + k);
                }

                // Reserve the frame and take its base in x6 (a free
                // scratch, not an operand register). The args in x9.. are
                // untouched by the SP move.
                try m.emit(a64.subSpImm(framebytes));
                try m.emit(a64.addRegSp(.x6, 0));

                // Spill every caller-saved boundary register the helper's
                // callconv(.c) body may clobber: x0 locals, x1 results,
                // x2 mem_base, x3 mem_len, x4 globals.
                try m.emit(a64.strImm(.x0, .x6, spill_off));
                try m.emit(a64.strImm(.x1, .x6, spill_off + 8));
                try m.emit(a64.strImm(.x2, .x6, spill_off + 16));
                try m.emit(a64.strImm(.x3, .x6, spill_off + 24));
                try m.emit(a64.strImm(.x4, .x6, spill_off + 32));

                // Spill the live operands below the args. Only those already
                // in a register (regForDepth(d)) need saving across the call;
                // a `.const_i32` below-operand is re-materialized when later
                // consumed, so it is left entirely untouched. Crucially its
                // Loc is NOT mutated to `.reg`: doing so would leak a
                // then-arm-only materialization into a sibling else-arm that
                // never ran the `mov` (an operand below an `if` must look
                // identical to both arms — they compile from one entry state).
                {
                    var d: usize = 0;
                    while (d < below) : (d += 1) {
                        if (stack[d] != .reg) continue;
                        const off: u15 = @intCast(op_spill_off + d * 8);
                        try m.emit(a64.strImm(regForDepth(d), .x6, off));
                    }
                }

                // Stage each arg as a full cell: low 64 = the value
                // (an i32 is zero-extended in its register), high 64 = 0.
                // Arg k is the operand at depth below+k (the top `nparams`).
                var k: usize = 0;
                while (k < nparams) : (k += 1) {
                    const cell_off: u15 = @intCast(k * @sizeOf(Cell));
                    try m.emit(a64.strImm(regForDepth(below + k), .x6, cell_off));
                    try m.emit(a64.strZeroImm(.x6, cell_off + 8));
                }

                // Helper ABI: x0 = instance (callee-saved x19), x1 = func
                // index, x2 = buffer pointer. Setting x2 destroys mem_base,
                // but it is already spilled (and reloaded after the call).
                try m.emit(a64.movReg(.x0, .x19));
                try m.movImm64(.x1, fidx);
                try m.emit(a64.movReg(.x2, .x6));
                try m.callAbs(.x16, @intFromPtr(call_helper.?));

                // The helper returns the trap status in w0. On a nested
                // trap, release this frame's reservation and fall into the
                // shared epilogue (which pops the prologue frame and
                // returns w0 unchanged).
                var call_ok: masm_mod.Masm.Label = .{};
                defer call_ok.deinit(gpa);
                try m.jumpCbz(.x0, &call_ok); // status == 0 -> success
                try m.emit(a64.addSpImm(framebytes)); // release buffer
                try m.jump(&epilogue); // propagate w0 (the status)
                m.bind(&call_ok);

                // Success. x6 is caller-saved, so the helper may have
                // clobbered it — but AAPCS64 guarantees SP is callee-
                // restored, and nothing moved SP between reserving the
                // frame and the `blr`, so SP again equals the buffer base.
                // Recompute x6 from SP before any reload.
                try m.emit(a64.addRegSp(.x6, 0));
                // Reload the results onto the operand bank *above* the
                // survivors (low 64 bits per cell): result r lands at depth
                // below+r. Then restore the spilled boundary registers, the
                // survivors (regForDepth(0..below)), and release the frame.
                var r: usize = 0;
                while (r < nresults) : (r += 1) {
                    const cell_off: u15 = @intCast(r * @sizeOf(Cell));
                    try m.emit(a64.ldrImm(regForDepth(below + r), .x6, cell_off));
                    stack[below + r] = .{ .reg = regForDepth(below + r) };
                }
                try m.emit(a64.ldrImm(.x0, .x6, spill_off));
                try m.emit(a64.ldrImm(.x1, .x6, spill_off + 8));
                try m.emit(a64.ldrImm(.x2, .x6, spill_off + 16));
                try m.emit(a64.ldrImm(.x3, .x6, spill_off + 24));
                try m.emit(a64.ldrImm(.x4, .x6, spill_off + 32));
                {
                    var d: usize = 0;
                    while (d < below) : (d += 1) {
                        if (stack[d] != .reg) continue; // const: nothing was spilled
                        const off: u15 = @intCast(op_spill_off + d * 8);
                        try m.emit(a64.ldrImm(regForDepth(d), .x6, off));
                        // Loc stays `.reg regForDepth(d)` — unchanged.
                    }
                }
                try m.emit(a64.addSpImm(framebytes));
                sp = below + nresults;
            },
            op_end => {
                // An `end` with no open frame terminates the function
                // body; otherwise it closes the innermost block.
                if (ctrl_len == 0) break;
                ctrl_len -= 1;
                const c = &ctrl[ctrl_len];
                // Validation guarantees the fallthrough reaches `end`
                // with the stack at base + arity. Canonicalize the
                // results into the merge registers so this path agrees
                // with every `br_if` that jumped here, then bind the
                // label at the merge point (after the materializing
                // moves, which only the fallthrough path executes).
                if (sp != c.height + c.result_arity) return null;
                var d: usize = c.height;
                while (d < c.height + c.result_arity) : (d += 1) {
                    const r = try materialize(&m, stack[d], d);
                    stack[d] = .{ .reg = r };
                }
                switch (c.kind) {
                    // A `block`/`if` `end` is a forward-branch merge —
                    // bind it here. A `loop`'s label was already bound at
                    // its header (no back-edge fixups: a back-edge jumps
                    // to an already-bound label).
                    .block, .if_else => m.bind(&c.label),
                    .loop => {},
                    // An `if` with no `else`: a false condition jumped to
                    // the else label, which lands straight at the `end`
                    // alongside the then-arm's fall-through.
                    .if_then => {
                        m.bind(&c.label);
                        m.bind(&c.else_label);
                    },
                }
                c.label.deinit(gpa);
                c.else_label.deinit(gpa);
            },
            else => return null, // not yet emittable — stay interpreted
        }
    }

    const results = ftype.results;
    if (sp != results.len) return null;
    // i32 and i64 results both store from the slot register's low bytes
    // (an i32 is zero-extended in its register), high cell word cleared.
    for (results) |rt| if (rt != .i32 and rt != .i64 and rt != .f64 and rt != .f32) return null;

    // Materialize the residual stack into result cells. Wasm results
    // map bottom-of-stack → results[0]; an i32 cell is the value
    // zero-extended into the low 64 bits with the high 64 cleared.
    try m.movImm64(.x17, 0); // reused zero for every cell's high half
    for (results, 0..) |_, ri| {
        const cell_off: u15 = @intCast(ri * @sizeOf(Cell));
        switch (stack[ri]) {
            .const_i32 => |v| {
                try m.movImm64(.x16, @as(u32, @bitCast(v)));
                try m.emit(a64.strImm(.x16, .x1, cell_off));
            },
            .reg => |r| try m.emit(a64.strImm(r, .x1, cell_off)),
        }
        try m.emit(a64.strImm(.x17, .x1, cell_off + 8));
    }
    // Normal return: w0 = trap_ok; results are already written to x1.
    // x0 (the now-dead locals pointer) carries the status back. Fall
    // through into the shared epilogue, which restores the frame and
    // returns.
    try m.movImm64(.x0, trap_ok);

    // The shared epilogue: every return path lands here with w0 set, so
    // the frame teardown (the non-leaf prologue's pop) is emitted once.
    // The normal return falls in; each trap exit jumps in after loading
    // its status. Pop x19 + the link register, then `ret`.
    m.bind(&epilogue);
    try m.emit(a64.ldpPostIdxSp(.x19, .lr, 16));
    try m.emit(a64.ret());

    // Out-of-line trap exits, bound only if some op forward-branched to
    // them: load the TrapCode into w0 and jump to the shared epilogue
    // (which restores the frame), writing no result (the caller raises
    // the matching TrapError and ignores x1).
    if (trap_div0_used) {
        m.bind(&trap_div0);
        try m.movImm64(.x0, trap_divide_by_zero);
        try m.jump(&epilogue);
    }
    if (trap_overflow_used) {
        m.bind(&trap_overflow);
        try m.movImm64(.x0, trap_int_overflow);
        try m.jump(&epilogue);
    }
    if (trap_oob_used) {
        m.bind(&trap_oob);
        try m.movImm64(.x0, trap_out_of_bounds);
        try m.jump(&epilogue);
    }
    if (trap_invalid_used) {
        m.bind(&trap_invalid);
        try m.movImm64(.x0, trap_invalid_conversion);
        try m.jump(&epilogue);
    }

    const installed = m.install(ca) catch return null;
    return code_alloc.asFn(EntryFn, installed);
}

/// Resolve `call fidx` (§5.4.1) to the callee's `FuncType` by walking the
/// function index space: imported functions first (their type index is
/// the import's `desc.func`), then the module's own defined functions
/// (`module.funcs[local]` is the type index). Returns null on an
/// out-of-range index — the function then degrades to the interpreter
/// rather than misread, which is always correct.
fn calleeFuncType(module: *const Module, fidx: u32) ?*const FuncType {
    var seen: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc != .func) continue;
        if (seen == fidx) {
            const ti = imp.desc.func;
            if (ti >= module.types.len) return null;
            return &module.types[ti];
        }
        seen += 1;
    }
    const local = fidx - seen;
    if (local >= module.funcs.len) return null;
    const ti = module.funcs[local];
    if (ti >= module.types.len) return null;
    return &module.types[ti];
}

/// Place `loc`'s value into the register for stack `depth`, emitting a
/// `movz`/`movk` sequence for a folded constant (a `reg` value is
/// already in its slot register by the depth invariant). Returns the
/// register.
fn materialize(m: *masm_mod.Masm, loc: Loc, depth: usize) CompileError!a64.Reg {
    const reg = regForDepth(depth);
    switch (loc) {
        .reg => |r| return r,
        .const_i32 => |v| {
            try m.movImm64(reg, @as(u32, @bitCast(v)));
            return reg;
        },
    }
}

/// Emit a memory access's effective-address computation and bounds check
/// (§4.4.7): `x16 = addr_reg + offset`, then trap to `oob` when the
/// `n`-byte access runs past `mem_len` (x3). The check is overflow-safe —
/// `addr_reg` is an i32 address on a 32-bit memory but a full i64 on a
/// memory64 module, so `ea` can be near 2^64. An `ea + n > len` form would
/// let `ea + n` wrap a huge address back under the bound and then load off
/// `[x2, ea]` out of bounds; instead this mirrors `rangeInBounds`: `subs`
/// computes `mem_len - ea`, whose unsigned borrow (carry clear) catches
/// `ea > mem_len` directly, then a second compare rejects `mem_len - ea <
/// n`. The boundary keeps the memory base in x2 and length in x3, untouched
/// by codegen (x4 now carries the globals base); x5 is a free scratch.
/// x16 holds the effective address on
/// return — the load/store then addresses `[x2, x16]`.
fn emitMemBounds(m: *masm_mod.Masm, addr_reg: a64.Reg, offset: u32, n: u32, oob: *masm_mod.Masm.Label) CompileError!void {
    if (offset <= 4095) {
        try m.emit(a64.addImm(.x16, addr_reg, @intCast(offset), false));
    } else {
        try m.movImm64(.x16, offset);
        try m.emit(a64.addReg(.x16, addr_reg, .x16));
    }
    try m.emit(a64.subsReg(.x17, .x3, .x16)); // x17 = mem_len - ea; carry clear iff ea > len
    try m.jumpCond(.cc, oob); // ea > mem_len -> out of bounds
    try m.movImm64(.x5, n); // x5 scratch: x4 now carries the globals base
    try m.emit(a64.cmpReg(.x17, .x5));
    try m.jumpCond(.cc, oob); // (mem_len - ea) < n -> out of bounds
}

/// Emit a §4.3.3 trapping float→int truncation. The float operand is in
/// `ra`'s slot; bridge it into FP scratch v16, trap to `invalid` on NaN
/// and to `overflow` outside `[lo, hi)` (lo half-open per `lo_inclusive`),
/// then `FCVTZS`/`FCVTZU` the in-range value back into `ra`. GP x16 is
/// reused to materialize each bound's bit pattern (a different register
/// file from FP v16, so the operand survives), bridged into FP v17 for the
/// compare. The bounds are passed as comptime literals matching the
/// interpreter's `truncTrap` call sites exactly.
fn emitTruncTrap(
    m: *masm_mod.Masm,
    ra: a64.Reg,
    comptime src_f32: bool,
    comptime to_i64: bool,
    comptime signed: bool,
    comptime lo: f64,
    comptime lo_inclusive: bool,
    comptime hi: f64,
    invalid: *masm_mod.Masm.Label,
    overflow: *masm_mod.Masm.Label,
) CompileError!void {
    const lo_bits: u64 = if (src_f32) @as(u32, @bitCast(@as(f32, @floatCast(lo)))) else @as(u64, @bitCast(lo));
    const hi_bits: u64 = if (src_f32) @as(u32, @bitCast(@as(f32, @floatCast(hi)))) else @as(u64, @bitCast(hi));

    // Bridge the operand f into FP scratch v16.
    if (src_f32) try m.emit(a64.fmovWtoS(.x16, ra)) else try m.emit(a64.fmovXtoD(.x16, ra));

    // NaN → invalid conversion. `fcmp f, f` leaves V set iff unordered.
    if (src_f32) try m.emit(a64.fcmpS(.x16, .x16)) else try m.emit(a64.fcmpD(.x16, .x16));
    try m.jumpCond(.vs, invalid);

    // lo bound: overflow if f < lo (inclusive) or f <= lo (exclusive).
    try m.movImm64(.x16, lo_bits);
    if (src_f32) try m.emit(a64.fmovWtoS(.x17, .x16)) else try m.emit(a64.fmovXtoD(.x17, .x16));
    if (src_f32) try m.emit(a64.fcmpS(.x16, .x17)) else try m.emit(a64.fcmpD(.x16, .x17));
    try m.jumpCond(if (lo_inclusive) .mi else .ls, overflow);

    // hi bound: overflow if f >= hi.
    try m.movImm64(.x16, hi_bits);
    if (src_f32) try m.emit(a64.fmovWtoS(.x17, .x16)) else try m.emit(a64.fmovXtoD(.x17, .x16));
    if (src_f32) try m.emit(a64.fcmpS(.x16, .x17)) else try m.emit(a64.fcmpD(.x16, .x17));
    try m.jumpCond(.ge, overflow);

    // In range: round toward zero. The result width (W/X) and signedness
    // pick the FCVTZ variant; the W-form zero-extends an i32 result.
    if (to_i64) {
        if (src_f32) {
            try m.emit(if (signed) a64.fcvtzsXfromS(ra, .x16) else a64.fcvtzuXfromS(ra, .x16));
        } else {
            try m.emit(if (signed) a64.fcvtzsXfromD(ra, .x16) else a64.fcvtzuXfromD(ra, .x16));
        }
    } else {
        if (src_f32) {
            try m.emit(if (signed) a64.fcvtzsWfromS(ra, .x16) else a64.fcvtzuWfromS(ra, .x16));
        } else {
            try m.emit(if (signed) a64.fcvtzsWfromD(ra, .x16) else a64.fcvtzuWfromD(ra, .x16));
        }
    }
}

/// Skip the unreachable code following an unconditional `br` (or
/// `return`) up to and including the `end` that closes the current
/// control frame, advancing `i` past it. Tracks structured nesting so a
/// nested `block`/`loop`/`if` inside the dead region is skipped whole.
/// Returns null — degrading the whole function to the interpreter, which
/// is always correct — on any opcode whose immediate width this baseline
/// doesn't know, rather than risk misreading an immediate byte as an
/// opcode.
fn skipToFrameEnd(body: []const u8, i: *usize) ?void {
    var depth: usize = 0;
    while (i.* < body.len) {
        const op = body[i.*];
        i.* += 1;
        switch (op) {
            op_block, op_loop, op_if => {
                _ = readSleb32(body, i) orelse return null; // block type
                depth += 1;
            },
            op_end => {
                if (depth == 0) return; // closes the current frame
                depth -= 1;
            },
            op_else => {}, // stays within the enclosing `if`'s nesting
            op_br, op_br_if, op_local_get, op_local_set, op_local_tee, op_global_get, op_global_set, op_memory_size, op_call => {
                _ = readUleb32(body, i) orelse return null;
            },
            op_br_table => {
                const n = readUleb32(body, i) orelse return null;
                var k: u32 = 0;
                while (k <= n) : (k += 1) { // n table labels + 1 default
                    _ = readUleb32(body, i) orelse return null;
                }
            },
            op_i32_const => {
                _ = readSleb32(body, i) orelse return null;
            },
            op_i64_const => {
                _ = readSleb64(body, i) orelse return null;
            },
            op_misc_prefix => {
                // Saturating truncations (sub 0..7) take no further immediate;
                // memory.fill (sub 11) takes a memory index. Any other 0xFC op
                // degrades.
                const sub = readUleb32(body, i) orelse return null;
                if (sub <= 7) {
                    // no further immediate
                } else if (sub == 11) {
                    _ = readUleb32(body, i) orelse return null; // memory index
                } else if (sub == 10) {
                    _ = readUleb32(body, i) orelse return null; // dst memory index
                    _ = readUleb32(body, i) orelse return null; // src memory index
                } else return null;
            },
            op_f64_const => {
                _ = readF64Bits(body, i) orelse return null; // 8 raw bytes
            },
            op_f32_const => {
                _ = readF32Bits(body, i) orelse return null; // 4 raw bytes
            },
            op_i32_load, op_i32_load8_s, op_i32_load8_u, op_i32_load16_s, op_i32_load16_u, op_i32_store, op_i32_store8, op_i32_store16, op_i64_load, op_i64_load8_s, op_i64_load8_u, op_i64_load16_s, op_i64_load16_u, op_i64_load32_s, op_i64_load32_u, op_i64_store, op_i64_store8, op_i64_store16, op_i64_store32, op_f32_load, op_f64_load, op_f32_store, op_f64_store => {
                const flags = readUleb32(body, i) orelse return null;
                if (flags & 0x40 != 0) return null; // multi-memory — degrade
                _ = readUleb32(body, i) orelse return null; // offset
            },
            // No-immediate opcodes in the baseline's set.
            op_nop, op_drop, op_select, op_return, op_i32_eqz, op_i32_clz, op_i32_ctz, op_i64_clz, op_i64_ctz, op_i32_eq, op_i32_ne, op_i32_lt_s, op_i32_lt_u, op_i32_gt_s, op_i32_gt_u, op_i32_le_s, op_i32_le_u, op_i32_ge_s, op_i32_ge_u, op_i32_add, op_i32_sub, op_i32_mul, op_i32_and, op_i32_or, op_i32_xor, op_i32_shl, op_i32_shr_s, op_i32_shr_u, op_i32_rotl, op_i32_rotr, op_i64_rotl, op_i64_rotr, op_i32_div_s, op_i32_div_u, op_i32_rem_s, op_i32_rem_u, op_i64_add, op_i64_sub, op_i64_mul, op_i64_and, op_i64_or, op_i64_xor, op_i64_shl, op_i64_shr_s, op_i64_shr_u, op_i64_eqz, op_i64_eq, op_i64_ne, op_i64_lt_s, op_i64_lt_u, op_i64_gt_s, op_i64_gt_u, op_i64_le_s, op_i64_le_u, op_i64_ge_s, op_i64_ge_u, op_i64_div_s, op_i64_div_u, op_i64_rem_s, op_i64_rem_u, op_i32_wrap_i64, op_i64_extend_i32_s, op_i64_extend_i32_u, op_i32_trunc_f32_s, op_i32_trunc_f32_u, op_i32_trunc_f64_s, op_i32_trunc_f64_u, op_i64_trunc_f32_s, op_i64_trunc_f32_u, op_i64_trunc_f64_s, op_i64_trunc_f64_u, op_f32_convert_i32_s, op_f32_convert_i32_u, op_f32_convert_i64_s, op_f32_convert_i64_u, op_f32_demote_f64, op_f64_convert_i32_s, op_f64_convert_i32_u, op_f64_convert_i64_s, op_f64_convert_i64_u, op_f64_promote_f32, op_i32_reinterpret_f32, op_i64_reinterpret_f64, op_f32_reinterpret_i32, op_f64_reinterpret_i64, op_f64_abs, op_f64_neg, op_f64_ceil, op_f64_floor, op_f64_trunc, op_f64_nearest, op_f64_sqrt, op_f64_add, op_f64_sub, op_f64_mul, op_f64_div, op_f64_min, op_f64_max, op_f64_copysign, op_f64_eq, op_f64_ne, op_f64_lt, op_f64_gt, op_f64_le, op_f64_ge, op_f32_abs, op_f32_neg, op_f32_ceil, op_f32_floor, op_f32_trunc, op_f32_nearest, op_f32_sqrt, op_f32_add, op_f32_sub, op_f32_mul, op_f32_div, op_f32_min, op_f32_max, op_f32_copysign, op_f32_eq, op_f32_ne, op_f32_lt, op_f32_gt, op_f32_le, op_f32_ge, op_i32_extend8_s, op_i32_extend16_s, op_i64_extend8_s, op_i64_extend16_s, op_i64_extend32_s, op_i32_popcnt, op_i64_popcnt => {},
            else => return null, // unknown immediate width — degrade
        }
    }
    return null; // ran off the body without closing the frame — degrade
}

/// Parse a block type (§5.3.6) and return the block's result arity,
/// advancing `i` past it. The empty type (`0x40`) carries nothing; a
/// single `i32` value type carries one result. Any other value type,
/// or a (positive sLEB128) type-index block — which can take params and
/// return many — degrades the whole function to the interpreter by
/// returning null, keeping this increment's merges single-i32 and
/// param-free.
fn readBlockArity(body: []const u8, i: *usize) ?u32 {
    if (i.* >= body.len) return null;
    const b = body[i.*];
    switch (b) {
        0x40 => {
            i.* += 1;
            return 0;
        },
        0x7f => {
            i.* += 1;
            return 1;
        },
        else => return null,
    }
}

/// Read an i32 load/store memarg (§5.4.7): the align/flags uleb followed
/// by the offset uleb, returning the offset. Degrades (null) on the
/// multi-memory form (flags bit 6 sets an explicit memory index) — the
/// baseline addresses memory 0 only. The align field is a hint only;
/// AArch64 handles unaligned 4-byte access, so it is ignored.
fn readMemArg(body: []const u8, i: *usize) ?u32 {
    const flags = readUleb32(body, i) orelse return null;
    if (flags & 0x40 != 0) return null; // explicit memidx — multi-memory
    return readUleb32(body, i); // offset
}

/// Unsigned LEB128 (§5.2.2) — `local.get`'s index. Null on a malformed
/// / over-long sequence (never aborts; AGENTS.md robustness contract).
fn readUleb32(body: []const u8, i: *usize) ?u32 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (i.* < body.len) {
        const byte = body[i.*];
        i.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            if (result > std.math.maxInt(u32)) return null;
            return @intCast(result);
        }
        shift += 7;
        if (shift >= 35) return null;
    }
    return null;
}

/// Signed LEB128 (§5.2.2) — the encoding of `i32.const`'s immediate.
/// Returns null on a malformed / over-long sequence rather than
/// trapping; a validated body never produces one, but Spasm must never
/// abort the host on a surprising byte (AGENTS.md robustness contract).
fn readSleb32(body: []const u8, i: *usize) ?i32 {
    var result: i64 = 0;
    var shift: u6 = 0;
    while (i.* < body.len) {
        const byte = body[i.*];
        i.* += 1;
        result |= @as(i64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            if (shift < 63 and (byte & 0x40) != 0) {
                result |= @as(i64, -1) << (shift + 7);
            }
            if (result < std.math.minInt(i32) or result > std.math.maxInt(i32)) return null;
            return @intCast(result);
        }
        shift += 7;
        if (shift >= 35) return null; // i32 LEB is at most 5 bytes
    }
    return null;
}

/// Signed LEB128 decoding an i64 (§5.2.2) — `i64.const`'s immediate.
/// Null on a malformed / over-long sequence; the shift always stays ≤ 63
/// at the point it is applied (the over-long guard fires first), so the
/// casts never trap on a surprising byte (AGENTS.md robustness contract).
fn readSleb64(body: []const u8, i: *usize) ?i64 {
    var result: i64 = 0;
    var shift: u7 = 0;
    while (i.* < body.len) {
        const byte = body[i.*];
        i.* += 1;
        result |= @as(i64, byte & 0x7f) << @as(u6, @intCast(shift));
        if (byte & 0x80 == 0) {
            if (shift < 63 and (byte & 0x40) != 0) {
                result |= @as(i64, -1) << @as(u6, @intCast(shift + 7));
            }
            return result;
        }
        shift += 7;
        if (shift >= 70) return null; // i64 LEB is at most 10 bytes
    }
    return null;
}

/// Read an `f64.const`'s 8-byte little-endian IEEE-754 bit pattern (§5.4.1
/// — floats are NOT LEB-encoded, they are the raw little-endian value),
/// advancing `i` past it. Null on a short read (a validated body always
/// has the eight bytes; Spasm never aborts on a surprising one).
fn readF64Bits(body: []const u8, i: *usize) ?u64 {
    if (i.* + 8 > body.len) return null;
    var bits: u64 = 0;
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        bits |= @as(u64, body[i.* + k]) << @intCast(k * 8);
    }
    i.* += 8;
    return bits;
}

/// Read an `f32.const`'s 4-byte little-endian IEEE-754 bit pattern (§5.4.1),
/// returning it zero-extended into a u64 for `movImm64`. Null on a short read.
fn readF32Bits(body: []const u8, i: *usize) ?u64 {
    if (i.* + 4 > body.len) return null;
    var bits: u64 = 0;
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        bits |= @as(u64, body[i.* + k]) << @intCast(k * 8);
    }
    i.* += 4;
    return bits;
}

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

/// Compile `func` against a throwaway single-type module — the unit tests
/// here build a `CompiledFunc`/`FuncType` directly and never emit a
/// `call`, so `compile` only dereferences the module inside the (unused)
/// call arm; a one-type module satisfies its pointer parameter. The
/// module borrows `ftype`, so the caller must keep it alive across the
/// call (every site does — it is a local that outlives `compile`).
fn compileT(
    ca: *code_alloc.CodeAllocator,
    func: *const CompiledFunc,
    ftype: *const FuncType,
) CompileError!?EntryFn {
    const types_arr = [_]FuncType{ftype.*};
    const module: Module = .{ .types = &types_arr, .funcs = &.{0} };
    return compile(testing.allocator, ca, func, ftype, &module);
}

test "spasm: a const-return function compiles and returns its constant" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    // `(func (result i32) i32.const 42)` — body with the locals header
    // already stripped (CompiledFunc.body starts at the first
    // instruction), an explicit `end` at the tail.
    const body = [_]u8{ op_i32_const, 42, op_end };
    const func: CompiledFunc = .{
        .type_index = 0,
        .local_types = &.{},
        .body = &body,
        .side_table = &.{},
        .max_stack = 1,
    };
    const ftype: FuncType = .{ .params = &.{}, .results = &.{.i32} };

    const entry = (try compileT(&ca, &func, &ftype)) orelse
        return error.SpasmRefusedTrivialFunction;

    var results: [1]Cell = .{0};
    var locals: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(results[0])));
}

test "spasm: a negative constant sign-extends through the LEB path" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    // `i32.const -7` — signed LEB byte 0x79 (value bits 0x39, sign bit
    // 0x40 set, no continuation).
    const body = [_]u8{ op_i32_const, 0x79, op_end };
    const func: CompiledFunc = .{
        .type_index = 0,
        .local_types = &.{},
        .body = &body,
        .side_table = &.{},
        .max_stack = 1,
    };
    const ftype: FuncType = .{ .params = &.{}, .results = &.{.i32} };

    const entry = (try compileT(&ca, &func, &ftype)) orelse
        return error.SpasmRefusedTrivialFunction;
    var results: [1]Cell = .{0};
    var locals: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(i32, -7), @as(i32, @bitCast(@as(u32, @truncate(results[0])))));
}

test "spasm: i32 add of two params compiles and computes" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32 i32) (result i32) local.get 0; local.get 1; i32.add)
    const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x6a, op_end };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = &.{}, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [2]Cell = .{ 7, 35 };
    var results: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(results[0])));
}

test "spasm: i32 sub and mul of params compute" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    const ftype: FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    // sub: 50 - 8 = 42
    {
        const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x6b, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = &.{}, .max_stack = 2 };
        const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [2]Cell = .{ 50, 8 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(results[0])));
    }
    // mul: 6 * 7 = 42 (and the low-32 truncation is clean)
    {
        const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x6c, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = &.{}, .max_stack = 2 };
        const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [2]Cell = .{ 6, 7 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(results[0])));
    }
}

test "spasm: i32 arithmetic folds two constants at compile time" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (result i32) i32.const 40; i32.const 2; i32.add) -> 42, no runtime add
    const body = [_]u8{ op_i32_const, 40, op_i32_const, 2, 0x6a, op_end };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{}, .body = &body, .side_table = &.{}, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{0};
    var results: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(results[0])));
}

test "spasm: i32 bitwise and/or/xor compute and fold" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    const ftype: FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    // and: 0b1110 & 0b1011 = 0b1010 = 10
    {
        const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x71, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = &.{}, .max_stack = 2 };
        const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [2]Cell = .{ 0b1110, 0b1011 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, 0b1010), @as(u32, @truncate(results[0])));
    }
    // or | xor folded: (5 | 2) ^ 3 = 7 ^ 3 = 4, all constant
    {
        const body = [_]u8{ op_i32_const, 5, op_i32_const, 2, 0x72, op_i32_const, 3, 0x73, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{}, .body = &body, .side_table = &.{}, .max_stack = 2 };
        const fty: FuncType = .{ .params = &.{}, .results = &.{.i32} };
        const entry = (try compileT(&ca, &func, &fty)) orelse return error.SpasmRefused;
        var locals: [1]Cell = .{0};
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, 4), @as(u32, @truncate(results[0])));
    }
}

test "spasm: local.set writes a local that local.get reads back" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32) i32.const 5; local.set 0; local.get 0)
    const body = [_]u8{ op_i32_const, 5, 0x21, 0x00, 0x20, 0x00, op_end };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{.i32}, .body = &body, .side_table = &.{}, .max_stack = 1 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{99}; // overwritten by local.set
    var results: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 5), @as(u32, @truncate(results[0])));
}

test "spasm: local.tee stores and leaves the value on the stack" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32) i32.const 7; local.tee 0; local.get 0; i32.add) -> 14
    const body = [_]u8{ op_i32_const, 7, 0x22, 0x00, 0x20, 0x00, 0x6a, op_end };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{.i32}, .body = &body, .side_table = &.{}, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{99};
    var results: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 14), @as(u32, @truncate(results[0])));
}

test "spasm: i32 comparisons distinguish signed from unsigned" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    const ftype: FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    const local2: []const ValType = &.{ .i32, .i32 };
    // -1 (0xFFFFFFFF) vs 0: lt_s true (1), lt_u false (0).
    const cases = [_]struct { op: u8, a: i32, b: i32, want: u32 }{
        .{ .op = 0x48, .a = -1, .b = 0, .want = 1 }, // lt_s: -1 < 0
        .{ .op = 0x49, .a = -1, .b = 0, .want = 0 }, // lt_u: 0xFFFFFFFF < 0
        .{ .op = 0x4b, .a = -1, .b = 0, .want = 1 }, // gt_u: 0xFFFFFFFF > 0
        .{ .op = 0x4e, .a = -1, .b = -1, .want = 1 }, // ge_s: -1 >= -1
        .{ .op = 0x46, .a = 42, .b = 42, .want = 1 }, // eq
        .{ .op = 0x47, .a = 42, .b = 42, .want = 0 }, // ne
    };
    for (cases) |c| {
        const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, c.op, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = local2, .body = &body, .side_table = &.{}, .max_stack = 2 };
        const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [2]Cell = .{ @as(u32, @bitCast(c.a)), @as(u32, @bitCast(c.b)) };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(c.want, @as(u32, @truncate(results[0])));
    }
}

test "spasm: i32.eqz computes and folds" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    inline for (.{ .{ 0, 1 }, .{ 5, 0 } }) |pair| {
        const body = [_]u8{ 0x20, 0x00, 0x45, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{.i32}, .body = &body, .side_table = &.{}, .max_stack = 1 };
        const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [1]Cell = .{pair[0]};
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
    // folded: i32.const 0; i32.eqz -> 1
    const body = [_]u8{ op_i32_const, 0, 0x45, op_end };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{}, .body = &body, .side_table = &.{}, .max_stack = 1 };
    const fty: FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &fty)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{0};
    var results: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(results[0])));
}

test "spasm: i32 shifts (shl, shr_s, shr_u) with count mod 32 and folding" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    const ftype: FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    const local2: []const ValType = &.{ .i32, .i32 };
    const cases = [_]struct { op: u8, a: i32, b: i32, want: u32 }{
        .{ .op = 0x74, .a = 1, .b = 4, .want = 16 }, // shl: 1<<4
        .{ .op = 0x74, .a = 1, .b = 33, .want = 2 }, // shl: count mod 32 -> 1<<1
        .{ .op = 0x75, .a = -16, .b = 2, .want = @bitCast(@as(i32, -4)) }, // shr_s arithmetic
        .{ .op = 0x76, .a = -16, .b = 2, .want = 0x3ffffffc }, // shr_u logical
    };
    for (cases) |c| {
        const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, c.op, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = local2, .body = &body, .side_table = &.{}, .max_stack = 2 };
        const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [2]Cell = .{ @as(u32, @bitCast(c.a)), @as(u32, @bitCast(c.b)) };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(c.want, @as(u32, @truncate(results[0])));
    }
    // folded: i32.const 3; i32.const 2; i32.shl -> 12
    const body = [_]u8{ op_i32_const, 3, op_i32_const, 2, 0x74, op_end };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{}, .body = &body, .side_table = &.{}, .max_stack = 2 };
    const fty: FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &fty)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{0};
    var results: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 12), @as(u32, @truncate(results[0])));
}

test "spasm: select picks an operand by the condition (branchless)" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32 i32 i32) (result i32)
    //   local.get 0; local.get 1; local.get 2; select)
    // -> cond (param2) != 0 ? val1 (param0) : val2 (param1)
    const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x20, 0x02, 0x1b, op_end };
    const local3: []const ValType = &.{ .i32, .i32, .i32 };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = local3, .body = &body, .side_table = &.{}, .max_stack = 3 };
    const ftype: FuncType = .{ .params = local3, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 1, 10 }, .{ 0, 20 } }) |pair| {
        var locals: [3]Cell = .{ 10, 20, pair[0] };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: drop pops a value; nop is a no-op" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32 i32) (result i32) nop; local.get 0; local.get 1; drop; nop)
    // -> drops param1, leaves param0.
    const body = [_]u8{ 0x01, 0x20, 0x00, 0x20, 0x01, 0x1a, 0x01, op_end };
    const local2: []const ValType = &.{ .i32, .i32 };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = local2, .body = &body, .side_table = &.{}, .max_stack = 2 };
    const ftype: FuncType = .{ .params = local2, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [2]Cell = .{ 42, 99 };
    var results: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(results[0])));
}

test "spasm: block with br_if picks a result by condition (forward branch)" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32)
    //   (block (result i32)
    //     i32.const 10
    //     local.get 0      ;; cond
    //     br_if 0          ;; cond != 0 -> exit block carrying 10
    //     drop
    //     i32.const 20))   ;; -> cond ? 10 : 20
    const body = [_]u8{
        0x02,         0x7f, // block (result i32)
        op_i32_const, 10,
        0x20, 0x00, // local.get 0
        0x0d,    0x00, // br_if 0
        op_drop, op_i32_const,
        20,
        op_end, // end block
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 1, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{.i32}, .body = &body, .side_table = side, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 1, 10 }, .{ 0, 20 } }) |pair| {
        var locals: [1]Cell = .{pair[0]};
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: empty block with br_if as an early break (arity 0)" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32) (local i32)
    //   i32.const 42  local.set 1
    //   (block                      ;; empty block type
    //     local.get 0  br_if 0      ;; cond != 0 -> break, keep 42
    //     i32.const 99  local.set 1) ;; else override with 99
    //   local.get 1))               ;; -> cond ? 42 : 99
    const body = [_]u8{
        op_i32_const, 42, 0x21, 0x01, // i32.const 42 ; local.set 1
        0x02, 0x40, // block (empty)
        0x20, 0x00, 0x0d, 0x00, // local.get 0 ; br_if 0
        op_i32_const, 0xe3, 0x00, 0x21, 0x01, // i32.const 99 (2-byte SLEB) ; local.set 1
        op_end, // end block
        0x20, 0x01, // local.get 1
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = side, .max_stack = 1 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 1, 42 }, .{ 0, 99 } }) |pair| {
        var locals: [2]Cell = .{ pair[0], 0 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: nested block, br_if 1 exits two levels carrying a result" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32)
    //   (block (result i32)         ;; outer, arity 1
    //     i32.const 10
    //     (block                    ;; inner, empty
    //       local.get 0  br_if 1)   ;; cond -> outer end carrying 10
    //     drop  i32.const 20))      ;; else -> 20
    const body = [_]u8{
        0x02,         0x7f, // outer block (result i32)
        op_i32_const, 10,
        0x02, 0x40, // inner block (empty)
        0x20, 0x00, 0x0d, 0x01, // local.get 0 ; br_if 1
        op_end, // end inner
        op_drop,
        op_i32_const,
        20,
        op_end, // end outer
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 1, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{.i32}, .body = &body, .side_table = side, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 1, 10 }, .{ 0, 20 } }) |pair| {
        var locals: [1]Cell = .{pair[0]};
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: loop with backward br_if accumulates (do-while)" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32) (local i32)
    //   (loop                               ;; empty block type
    //     local.get 1  local.get 0  i32.add  local.set 1   ;; sum += n
    //     local.get 0  i32.const 1  i32.sub  local.set 0   ;; n  -= 1
    //     local.get 0  br_if 0)             ;; repeat while n != 0
    //   local.get 1))                       ;; -> n + (n-1) + ... + 1
    const body = [_]u8{
        0x03, 0x40, // loop (empty)
        0x20, 0x01, 0x20, 0x00, 0x6a, 0x21, 0x01, // local.get 1 ; local.get 0 ; i32.add ; local.set 1
        0x20, 0x00, 0x41, 0x01, 0x6b, 0x21, 0x00, // local.get 0 ; i32.const 1 ; i32.sub ; local.set 0
        0x20, 0x00, 0x0d, 0x00, // local.get 0 ; br_if 0
        op_end, // end loop
        0x20, 0x01, // local.get 1
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = side, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 1, 1 }, .{ 3, 6 }, .{ 5, 15 }, .{ 10, 55 } }) |pair| {
        var locals: [2]Cell = .{ pair[0], 0 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: loop (result i32) iterates then yields its result" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32) (local i32)
    //   (loop (result i32)            ;; result arity 1, branch arity 0
    //     local.get 1 local.get 0 i32.add local.set 1   ;; sum += n
    //     local.get 0 i32.const 1 i32.sub local.set 0   ;; n -= 1
    //     local.get 0 br_if 0          ;; repeat while n != 0 (back-edge carries 0)
    //     local.get 1))                ;; fall-through: yield sum (result)
    const body = [_]u8{
        0x03, 0x7f, // loop (result i32)
        0x20, 0x01, 0x20, 0x00, 0x6a, 0x21, 0x01, // sum += n
        0x20, 0x00, 0x41, 0x01, 0x6b, 0x21, 0x00, // n -= 1
        0x20, 0x00, 0x0d, 0x00, // local.get 0 ; br_if 0
        0x20, 0x01, // local.get 1 (loop result)
        op_end, // end loop
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = side, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 4, 10 }, .{ 6, 21 } }) |pair| {
        var locals: [2]Cell = .{ pair[0], 0 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: while loop — br as continue, br_if as break" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32) (local i32)        ;; n = p0, sum = l1
    //   (block
    //     (loop
    //       local.get 0  i32.eqz  br_if 1     ;; if n == 0, break out of block
    //       local.get 1  local.get 0  i32.add  local.set 1   ;; sum += n
    //       local.get 0  i32.const 1  i32.sub  local.set 0   ;; n  -= 1
    //       br 0)))                            ;; continue the loop
    //   local.get 1)                           ;; -> n*(n+1)/2 (0 when n == 0)
    const body = [_]u8{
        0x02, 0x40, // block
        0x03, 0x40, // loop
        0x20, 0x00, 0x45, 0x0d, 0x01, // local.get 0 ; i32.eqz ; br_if 1
        0x20, 0x01, 0x20, 0x00, 0x6a, 0x21, 0x01, // sum += n
        0x20, 0x00, 0x41, 0x01, 0x6b, 0x21, 0x00, // n -= 1
        0x0c, 0x00, // br 0 (continue)
        op_end, // end loop
        op_end, // end block
        0x20, 0x01, // local.get 1
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 }, // br_if 1
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 }, // br 0
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = side, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 0, 0 }, .{ 1, 1 }, .{ 5, 15 }, .{ 6, 21 } }) |pair| {
        var locals: [2]Cell = .{ pair[0], 0 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: br exits a block forward; dead code (nested block) is skipped" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (result i32)
    //   (block (result i32)
    //     i32.const 42  br 0       ;; exit the block carrying 42
    //     ;; --- unreachable ---
    //     (block i32.const 7 drop) ;; nested dead block (depth tracking)
    //     i32.const 99))           ;; dead 2-byte SLEB -> 42
    const body = [_]u8{
        0x02, 0x7f, // block (result i32)
        op_i32_const, 42, op_br, 0x00, // i32.const 42 ; br 0
        0x02, 0x40, op_i32_const, 7, op_drop, op_end, // dead nested block
        op_i32_const, 0xe3, 0x00, // dead i32.const 99 (2-byte SLEB)
        op_end, // end block
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 1, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{}, .body = &body, .side_table = side, .max_stack = 1 };
    const ftype: FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{0};
    var results: [1]Cell = .{0};
    _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(results[0])));
}

test "spasm: if/else picks a result arm by the condition" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32)
    //   local.get 0
    //   (if (result i32) (then i32.const 10) (else i32.const 20)))
    //   -> cond ? 10 : 20
    const body = [_]u8{
        0x20, 0x00, // local.get 0 (cond)
        op_if,        0x7f, // if (result i32)
        op_i32_const, 10,
        op_else,      op_i32_const,
        20,
        op_end, // end if
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 1, .pop_count = 0 },
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 1, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{.i32}, .body = &body, .side_table = side, .max_stack = 1 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 1, 10 }, .{ 0, 20 } }) |pair| {
        var locals: [1]Cell = .{pair[0]};
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: if without else conditionally overwrites a local" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32) (local i32)
    //   i32.const 5  local.set 1
    //   local.get 0  (if (then i32.const 9  local.set 1))
    //   local.get 1)                  ;; cond ? 9 : 5
    const body = [_]u8{
        op_i32_const, 5, 0x21, 0x01, // i32.const 5 ; local.set 1
        0x20, 0x00, // local.get 0
        op_if, 0x40, // if (empty)
        op_i32_const, 9, 0x21, 0x01, // i32.const 9 ; local.set 1
        op_end, // end if
        0x20, 0x01, // local.get 1
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = side, .max_stack = 1 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 1, 9 }, .{ 0, 5 } }) |pair| {
        var locals: [2]Cell = .{ pair[0], 0 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: br_table dispatches by index to distinct block ends" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32) (result i32) (local i32)         ;; i=p0, r=l1
    //   i32.const 7  local.set 1            ;; r = 7 (default)
    //   (block            ;; B_outer (default target)
    //     (block          ;; B0
    //       local.get 0
    //       br_table 0 1) ;; i==0 -> B0.end ; else -> B_outer.end
    //     i32.const 10  local.set 1)        ;; B0.end: r = 10, fall to B_outer.end
    //   local.get 1)                        ;; -> i==0 ? 10 : 7
    const body = [_]u8{
        op_i32_const, 7, 0x21, 0x01, // i32.const 7 ; local.set 1
        0x02, 0x40, // block B_outer
        0x02, 0x40, // block B0
        0x20, 0x00, // local.get 0
        0x0e, 0x01, 0x00, 0x01, // br_table {0} default 1
        op_end, // end B0
        op_i32_const, 10, 0x21, 0x01, // i32.const 10 ; local.set 1
        op_end, // end B_outer
        0x20, 0x01, // local.get 1
        op_end, // end function
    };
    const side: []const @import("code.zig").BranchEntry = &.{
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 },
        .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 },
    };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = side, .max_stack = 1 };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const entry = (try compileT(&ca, &func, &ftype)) orelse return error.SpasmRefused;
    inline for (.{ .{ 0, 10 }, .{ 1, 7 }, .{ 3, 7 } }) |pair| {
        var locals: [2]Cell = .{ pair[0], 0 };
        var results: [1]Cell = .{0};
        _ = entry(&locals, &results, @ptrCast(&locals), 0, @ptrCast(&locals), @ptrCast(&locals));
        try testing.expectEqual(@as(u32, pair[1]), @as(u32, @truncate(results[0])));
    }
}

test "spasm: an unsupported opcode degrades to null (stay interpreted)" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    // `memory.grow` (0x40) is outside the baseline's current set —
    // Spasm must refuse the whole function, not abort. The
    // interpreter runs it. (`call` is now emittable, so this guard
    // uses an op that still degrades.)
    const body = [_]u8{ 0x40, 0x00, op_end };
    const func: CompiledFunc = .{
        .type_index = 0,
        .local_types = &.{},
        .body = &body,
        .side_table = &.{},
        .max_stack = 1,
    };
    const ftype: FuncType = .{ .params = &.{}, .results = &.{.i32} };
    try testing.expectEqual(@as(?EntryFn, null), try compileT(&ca, &func, &ftype));
}
