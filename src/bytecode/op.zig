//! Opcode set for Cynic's bytecode.
//!
//! Cynic uses an Ignition-style register file with an implicit
//! accumulator (`acc`). Every binary opcode reads its left-hand
//! operand from a named register and its right-hand operand from
//! the accumulator, writing the result back to the accumulator.
//! Unary opcodes operate on the accumulator in place. Loads /
//! stores shuttle values between registers, the constant pool,
//! and the accumulator.
//!
//! Operand encoding (little-endian on the wire):
//! `r:u8` — register index, max 255 per frame.
//! `k:u16` — index into `Chunk.constants`.
//! `i:i32` — Smi immediate (small-int fast path, §6.1.6.1).
//! `o:i8|i16|i32` — relaxed signed branch offset, relative to the
//! byte immediately after the displacement. Canonical compiler
//! emission uses i16; `Builder.finish` selects the narrowest lossless
//! variant and remaps every offset-bearing side table.
//!
//! `Op.spec()` is the authoritative instruction schema. Compiler,
//! disassembler, liveness, statistics, Lantern, and Bistromath derive
//! operand widths and control-flow contracts from it; a second opcode
//! metadata switch is a bug.
//!
//! See the [compiler-engineering handbook](../../docs/handbook/compiler-engineering.md)
//! for the design rationale (Ignition / Hermes lineage; why
//! register file + accumulator beats a pure stack here).

const std = @import("std");

/// Primitive fields used by bytecode operand layouts. Keeping register
/// operands distinct from generic one-byte fields is what lets a later wide
/// prefix scale registers without also widening argument counts and flags.
pub const OperandKind = enum {
    register,
    u8,
    i8,
    u16,
    i16,
    i32,
    u32,

    pub fn byteSize(kind: OperandKind) u8 {
        return switch (kind) {
            .register, .u8, .i8 => 1,
            .u16, .i16 => 2,
            .i32, .u32 => 4,
        };
    }
};

/// Wire layouts shared by the compiler, decoder, disassembler, analyses and
/// execution tiers. The names describe operand kinds in stream order.
pub const OperandLayout = enum {
    none,
    reg,
    reg_reg,
    reg_reg_reg,
    reg_u8,
    reg_u8_u8,
    reg_reg_u8,
    reg_reg_u8_u8,
    reg_u16,
    reg_reg_u16,
    reg_u8_u16,
    reg_reg_u8_u16,
    reg_i16,
    reg_i8,
    reg_reg_i16,
    reg_reg_i8,
    reg_i32,
    reg_reg_i32,
    u8,
    u8_u8,
    u8_reg_u8,
    u8_reg_u8_u8_u8,
    u16,
    u16_u16,
    u16_reg,
    u16_reg_reg,
    u16_reg_u8,
    u16_reg_u16,
    u16_reg_u8_u16_u16,
    i16,
    i8,
    i32,
    u32,

    pub fn operands(layout: OperandLayout) []const OperandKind {
        return switch (layout) {
            .none => &.{},
            .reg => &.{.register},
            .reg_reg => &.{ .register, .register },
            .reg_reg_reg => &.{ .register, .register, .register },
            .reg_u8 => &.{ .register, .u8 },
            .reg_u8_u8 => &.{ .register, .u8, .u8 },
            .reg_reg_u8 => &.{ .register, .register, .u8 },
            .reg_reg_u8_u8 => &.{ .register, .register, .u8, .u8 },
            .reg_u16 => &.{ .register, .u16 },
            .reg_reg_u16 => &.{ .register, .register, .u16 },
            .reg_u8_u16 => &.{ .register, .u8, .u16 },
            .reg_reg_u8_u16 => &.{ .register, .register, .u8, .u16 },
            .reg_i16 => &.{ .register, .i16 },
            .reg_i8 => &.{ .register, .i8 },
            .reg_reg_i16 => &.{ .register, .register, .i16 },
            .reg_reg_i8 => &.{ .register, .register, .i8 },
            .reg_i32 => &.{ .register, .i32 },
            .reg_reg_i32 => &.{ .register, .register, .i32 },
            .u8 => &.{.u8},
            .u8_u8 => &.{ .u8, .u8 },
            .u8_reg_u8 => &.{ .u8, .register, .u8 },
            .u8_reg_u8_u8_u8 => &.{ .u8, .register, .u8, .u8, .u8 },
            .u16 => &.{.u16},
            .u16_u16 => &.{ .u16, .u16 },
            .u16_reg => &.{ .u16, .register },
            .u16_reg_reg => &.{ .u16, .register, .register },
            .u16_reg_u8 => &.{ .u16, .register, .u8 },
            .u16_reg_u16 => &.{ .u16, .register, .u16 },
            .u16_reg_u8_u16_u16 => &.{ .u16, .register, .u8, .u16, .u16 },
            .i16 => &.{.i16},
            .i8 => &.{.i8},
            .i32 => &.{.i32},
            .u32 => &.{.u32},
        };
    }

    pub fn operandSize(layout: OperandLayout) u8 {
        var size: u8 = 0;
        for (layout.operands()) |operand| size += operand.byteSize();
        return size;
    }
};

pub const ControlFlow = enum {
    fallthrough,
    jump,
    conditional_jump,
    multiway_jump,
    suspend_,
    terminator,
};

/// Contract between the bytecode vocabulary and Bistromath. `inline_` means
/// the baseline compiler must understand the opcode; `unsupported` is an
/// intentional tier boundary, never an accidental omission.
pub const BaselineStrategy = enum {
    inline_,
    helper,
    canonical_expansion,
    unsupported,
};

pub const BranchWidth = enum(u8) {
    i8 = 1,
    i16 = 2,
    i32 = 4,

    pub fn byteSize(width: BranchWidth) u8 {
        return @intFromEnum(width);
    }
};

pub const BranchInfo = struct {
    /// Semantic opcode independent of the encoded displacement width. The
    /// canonical forms use i16 and keep the original opcode identities.
    canonical: Op,
    width: BranchWidth,
    /// Byte offset of the signed displacement within the operand stream.
    operand_offset: u8,

    pub fn displacement(info: BranchInfo, code: []const u8, op_start: usize) i32 {
        const at = op_start + 1 + info.operand_offset;
        return switch (info.width) {
            .i8 => @as(i8, @bitCast(code[at])),
            .i16 => std.mem.readInt(i16, code[at..][0..2], .little),
            .i32 => std.mem.readInt(i32, code[at..][0..4], .little),
        };
    }

    pub fn target(info: BranchInfo, code: []const u8, op_start: usize) u32 {
        const after = op_start + 1 + info.operand_offset + info.width.byteSize();
        return @intCast(@as(i64, @intCast(after)) + info.displacement(code, op_start));
    }
};

pub const InstructionSpec = struct {
    mnemonic: []const u8,
    layout: OperandLayout,
    control_flow: ControlFlow = .fallthrough,
    baseline: BaselineStrategy = .unsupported,
};

fn instruction(mnemonic_text: []const u8, layout: OperandLayout) InstructionSpec {
    return .{ .mnemonic = mnemonic_text, .layout = layout };
}

fn baselineInstruction(mnemonic_text: []const u8, layout: OperandLayout) InstructionSpec {
    return .{ .mnemonic = mnemonic_text, .layout = layout, .baseline = .inline_ };
}

fn controlInstruction(mnemonic_text: []const u8, layout: OperandLayout, control_flow: ControlFlow, baseline: BaselineStrategy) InstructionSpec {
    return .{ .mnemonic = mnemonic_text, .layout = layout, .control_flow = control_flow, .baseline = baseline };
}

pub const Op = enum(u8) {
    // ── Loads ────────────────────────────────────────────────────────────
    /// Load `undefined` into acc. Encoding: `[op]`.
    lda_undefined,
    /// Load `null` into acc.
    lda_null,
    /// Load `true` into acc.
    lda_true,
    /// Load `false` into acc.
    lda_false,
    /// `[op] [i:i32]` — load a Smi immediate into acc.
    lda_smi,
    /// `[op] [k:u16]` — load `Chunk.constants[k]` into acc.
    lda_constant,
    /// `[op] [r:u8]` — copy register `r` into acc.
    ldar,
    /// `[op] [r:u8]` — copy acc into register `r`.
    star,
    /// `[op] [src:u8] [dst:u8]` — copy register `src` into
    /// register `dst` without disturbing the accumulator. The
    /// compiler emits this for binding initialisers that don't
    /// otherwise materialise a value through acc.
    mov,
    /// Load the TDZ Hole sentinel into acc. Block-entry init for
    /// every `let`/`const` binding (§13.3.1).
    lda_hole,
    /// `[op]` — load the Smi `0` into acc (operand-free). The two most
    /// frequent integer constants get a 1-byte load instead of the
    /// 5-byte `lda_smi` (cf. V8 `LdaZero`, Hermes `LoadConstZero`).
    lda_zero,
    /// `[op]` — load the Smi `1` into acc (operand-free).
    lda_one,
    /// `[op]` — copy register N into acc, with the register index
    /// (0..3) baked into the opcode (operand-free). Compact form of
    /// `ldar rN` for the hottest low slots — params and the first
    /// locals. MUST stay contiguous: the index is `op - ldar_0`.
    ldar_0,
    ldar_1,
    ldar_2,
    ldar_3,
    /// `[op]` — copy acc into register N (0..3), index baked into the
    /// opcode (operand-free). Compact form of `star rN`. MUST stay
    /// contiguous: the index is `op - star_0`.
    star_0,
    star_1,
    star_2,
    star_3,

    // ── Arithmetic (acc = reg OP acc) ────────────────────────────────────
    /// `[op] [r:u8]` — acc = reg + acc. §13.7.3.
    add,
    /// `[op] [r:u8]` — acc = reg - acc. §13.7.4.
    sub,
    /// `[op] [r:u8]` — acc = reg * acc. §13.7.2.
    mul,
    /// `[op] [r:u8]` — acc = reg / acc. §13.7.2.
    div,
    /// `[op] [r:u8]` — acc = reg % acc. §13.7.2.
    mod,
    /// `[op] [r:u8]` — acc = reg ** acc. §13.7.1.
    pow,
    /// `[op] [r:u8] [imm:i32]` — `acc = reg + imm`. Fused
    /// counterpart to the `LdaSmi imm; Add r` pair the
    /// `compileBinary` register peephole emits when LHS is a
    /// register-bound binding and RHS is a Smi-representable
    /// numeric literal. Int32 fast path: `@addWithOverflow` and
    /// fall back to f64 on overflow (bit-identical to `add`).
    /// Non-int32 register routes through `addValues` with the
    /// immediate wrapped as a Smi — string concat, BigInt
    /// TypeError, double + Smi all stay correct. Saves one
    /// dispatch + 1 byte vs the two-op sequence on every
    /// counting-loop body with the `<reg> + <literal>` shape
    /// (object_alloc, tail_recursion, JSON renumbering, etc.).
    add_smi,
    /// `[op]` — `acc = ToInt32(acc)`. Fused form of the
    /// `expr | 0` ToInt32 idiom. The compiler emits it when a
    /// `BitOr` binary has a Smi-literal-0 RHS — instead of the
    /// 3-op `Star r_tmp; LdaSmi 0; BitOr r_tmp` triple, the LHS
    /// stays in `acc` and a single `to_int32` op transforms it
    /// in place. Int32 fast path: identity (already int32, no
    /// shift). Anything else routes through the existing
    /// `bitwiseBinary(.bor, acc, 0)` slow path so § 7.1.6
    /// ToInt32's NaN/±∞ → +0, double truncate, string ToNumber,
    /// BigInt → TypeError all behave bit-identically to the
    /// un-fused triple. Headline arith_loop / int-coerce
    /// hot-path win.
    to_int32,
    /// `[op] [r:u8]` — `acc = ToInt32(reg + acc)`. Fused form of the
    /// `(a + b) | 0` idiom: a plain `Add r` immediately followed by
    /// the `to_int32` (`| 0`) op. The compiler collapses the pair by
    /// rewriting the just-emitted `add` in place (see
    /// `Builder.fuseAddToInt32`). Int32 fast path: ToInt32 of an
    /// `int32 + int32` sum IS the wrapping 32-bit sum
    /// (`@addWithOverflow`'s low result), so the fused op needs no
    /// overflow branch and no separate coercion — strictly less work
    /// than `add` alone. Anything else (double, string, object,
    /// BigInt) routes through the exact `addValues` + `bitwiseBinary
    /// (.bit_or, _, 0)` sequence the un-fused `Add r; ToInt32` pair
    /// runs, so § 7.1.6 ToInt32 / § 13.15 semantics — double
    /// truncate, NaN/±∞ → +0, string ToNumber, BigInt TypeError,
    /// throwing `valueOf` — all stay bit-identical. The per-iteration
    /// inner pair of the `arith_loop` micro (also array_iter /
    /// construct_loop / array_literal_loop).
    add_to_int32,

    // ── Bitwise (acc = reg OP acc, ToInt32 coercion) ─────────────────────
    /// `[op] [r:u8]` — acc = reg & acc. §13.12.
    bit_and,
    /// `[op] [r:u8]` — acc = reg | acc. §13.12.
    bit_or,
    /// `[op] [r:u8]` — acc = reg ^ acc. §13.12.
    bit_xor,
    /// `[op] [r:u8]` — acc = reg << acc.
    shl,
    /// `[op] [r:u8]` — acc = reg >> acc (sign-propagating).
    shr,
    /// `[op] [r:u8]` — acc = reg >>> acc (zero-fill).
    shr_u,

    // ── Unary (operate on acc) ───────────────────────────────────────────
    /// acc = -acc. §13.5.5.
    negate,
    /// acc = ~acc (ToInt32 then bit-NOT). §13.5.6.
    bit_not,
    /// acc = !acc (ToBoolean then negate). §13.5.7.
    logical_not,
    /// acc = +acc (ToNumber). §13.5.4. Rejects BigInt with
    /// TypeError (§7.1.4 ToNumber). Distinct from `to_numeric`,
    /// which accepts BigInt and is used by the `++` / `--` bump
    /// lowerings.
    to_number,
    /// acc = ToNumeric(acc). §7.1.4.1 — emitted by `++` / `--`
    /// to coerce the operand to a Number-or-BigInt primitive
    /// before the `inc` / `dec` bump runs. Unlike `to_number`,
    /// a BigInt operand passes through (so `0n++` doesn't
    /// TypeError on the coerce step).
    to_numeric,
    /// acc = ToString(acc). §7.1.17 — for an Object, runs
    /// §7.1.1 ToPrimitive with hint "string" which consults
    /// `Symbol.toPrimitive` / `toString` / `valueOf` in spec
    /// order. Symbol primitives throw TypeError. Used by the
    /// template-literal lowering so each substitution is
    /// coerced via the "string" hint per §13.2.8.6 step 7,
    /// not via the `+` operator's "default" hint (which
    /// would call `valueOf` first and surface a wrapped
    /// Symbol primitive that then crashes ToString).
    to_string,
    /// acc = acc + Type(acc)::unit (§13.4 PostfixExpression /
    /// PrefixUpdateExpression). The accumulator is assumed to
    /// already be ToNumeric-coerced; the bump dispatches on
    /// Number vs BigInt so the unit matches the operand's type.
    inc,
    /// acc = acc − Type(acc)::unit. Mirror of `inc`.
    dec,
    /// acc = typeof acc → JSString. §13.5.3.
    typeof_,

    // ── Comparison (acc = reg CMP acc → Bool) ────────────────────────────
    /// `[op] [r:u8]` — acc = reg == acc. §7.2.14 IsLooselyEqual.
    eq,
    /// `[op] [r:u8]` — acc = reg === acc. §7.2.15 IsStrictlyEqual.
    strict_eq,
    /// `[op] [r:u8]` — acc = reg != acc.
    neq,
    /// `[op] [r:u8]` — acc = reg !== acc.
    strict_neq,
    /// `[op] [r:u8]` — acc = reg < acc. §7.2.13 IsLessThan.
    lt,
    /// `[op] [r:u8]` — acc = reg > acc.
    gt,
    /// `[op] [r:u8]` — acc = reg <= acc.
    le,
    /// `[op] [r:u8]` — acc = reg >= acc.
    ge,

    // ── Control flow ─────────────────────────────────────────────────────
    /// `[op] [o:i16]` — unconditional jump.
    jmp,
    /// `[op] [o:i16]` — jump if `!ToBoolean(acc)`.
    jmp_if_false,
    /// `[op] [o:i16]` — jump if `ToBoolean(acc)`.
    jmp_if_true,
    /// `[op] [o:i16]` — jump if acc is `null` or `undefined`.
    /// §13.5.5 OptionalChain short-circuit: when `?.` LHS evaluates
    /// to nullish, the entire chain returns undefined.
    jmp_if_nullish,
    /// `[op] [r:u8] [o:i16]` — fused strict-equality compare-and-branch:
    /// jump (forward) when `registers[r] === acc`. Collapses the two-op
    /// `strict_eq r; jmp_if_true` pair a comparison condition emits. The
    /// compiler only emits these for forward branches (`if` / `while` /
    /// `for` tests), so there is no loop back-edge / OSR path here.
    jmp_if_strict_eq,
    /// `[op] [r:u8] [o:i16]` — jump (forward) when `registers[r] !== acc`.
    jmp_if_strict_neq,
    /// `[op] [r:u8] [o:i16]` — fused relational compare-and-branch for the
    /// jump-when-false (if/while/for skip) sense: jump (forward) when
    /// `!(registers[r] <op> acc)`, reusing the §13.10 relational semantics
    /// (int32 fast path; ToPrimitive/ToNumber coercion otherwise). Collapses
    /// `lt|le|gt|ge r; jmp_if_false`. The boolean negation is on the
    /// comparison RESULT, not the operator — `!(a<b)` is NOT `a>=b` when a
    /// NaN is involved (both are false), so the op cannot be a negated
    /// comparison; it tests the comparison and jumps when it is false.
    jmp_if_not_lt,
    jmp_if_not_le,
    jmp_if_not_gt,
    jmp_if_not_ge,
    /// `[op] [r_counter:u8] [r_bound:u8] [o:i16]` — fused
    /// counter-loop bottom: `r_counter += 1`, then branch back to
    /// the body when `r_counter < r_bound`. Fuses the seven-opcode
    /// canonical-for-loop tail (`lda_smi 1; add r_c; star r_c; ldar
    /// r_c; lt r_b; jmp_if_true`) into one dispatch. Emitted by the
    /// compiler for `for (let i = INT; i < BOUND; i++) BODY` when
    /// the body doesn't reassign or close over `i`. Hermes calls
    /// this `JLessNLong`; V8 Ignition has a `Jump…IncIfTrue` family.
    ///
    /// Fast path: both operands int32, no overflow → int32 inc +
    /// int32 compare. Slow path: routes through `arith.incOrDec`
    /// (ToNumeric → bump, BigInt-tolerant) and `relational(.lt,
    /// …)` so the spec-observable behaviour is identical to the
    /// unfused sequence the compiler would have emitted. Acc is
    /// preserved across the opcode — the body's last expression
    /// value still surfaces to the for-statement's caller in
    /// REPL contexts.
    loop_inc_lt,

    // ── Functions / calls ─────────────────────────────────────────
    /// `[op] [k:u16]` — instantiate a `JSFunction` from
    /// `Chunk.function_templates[k]`, capturing the current
    /// frame's environment chain. The instance lands in the
    /// accumulator.
    make_function,
    /// `[op] [k:u16]` — §15.6.5 InstantiateOrdinaryFunctionExpression
    /// for a NAMED function expression. Allocates a single-slot
    /// declarative env wrapping the current frame's env, instantiates
    /// the function with that env as its `[[Environment]]`, then
    /// stores the function into the env's slot 0 (the self-name
    /// binding). The binding is immutable: writes from inside the
    /// body compile to `throw_assign_const` so user-visible writes
    /// throw a TypeError per §8.1.1.1.4 SetMutableBinding step 9.b.
    make_named_function_expr,
    /// `[op] [r_callee:u8] [argc:u8] [ic:u16]` — invoke the function
    /// in register `r_callee` with `argc` arguments drawn from the
    /// consecutive registers `r_callee+1.. r_callee+argc`. The
    /// return value lands in the caller's accumulator after the
    /// callee's `Return`. The `ic` operand indexes
    /// `Chunk.inline_call_caches` — a hit on the cached callee
    /// pointer skips the proxy / revocable / bound / `valueAsFunction`
    /// dispatch chain and calls the function directly. Same cell
    /// shape as `call_method`'s call IC.
    call,
    /// `[op] [r_callee:u8] [ic:u16]` — free call with the argument
    /// count fixed by the opcode (`call0` = 0 args … `call3` = 3).
    /// Identical to `call` in every other respect — same callee
    /// register, same `r_callee + 1 ..` argument window, same call IC,
    /// same dispatch. Folding argc into the opcode drops the `argc:u8`
    /// operand byte for the common ≤3-arg case; calls with >3 args use
    /// the generic `call`. These share `call`'s interpreter arm (the
    /// handler can't be factored — its body is threaded with
    /// `continue :dispatch`), so the only saving is bytecode size.
    call0,
    call1,
    call2,
    call3,
    /// `[op] [r_recv:u8] [r_callee:u8] [argc:u8] [ic:u16]` — method
    /// call. Identical to `Call` except `this` is bound to the value
    /// in `r_recv` (§13.3.6 — `obj.method()` produces a Reference
    /// whose base is `obj`, so the call sees `this = obj`).
    /// Args are read from `r_callee + 1.. r_callee + argc`,
    /// matching `Call` so the compiler can share its argument-
    /// emission helper. The `ic` operand indexes
    /// `Chunk.inline_call_caches` — a hit on the cached callee
    /// pointer skips the proxy / revocable / bound / `valueAsFunction`
    /// dispatch chain and calls the function directly.
    call_method,
    /// `[op] [k:u16] [r_recv:u8] [argc:u8] [ic_load:u16] [ic_call:u16]`
    /// — fused property load + method call. Replaces the
    /// `ldar r_recv; lda_property k ic_load; star r_callee;
    /// call_method r_recv r_callee argc ic_call` 4-op sequence the
    /// compiler used to emit for `obj.method(args)` when the property
    /// name is a plain identifier (no private `#`, no computed key,
    /// no optional chain, no tail position, no `super.method`). Hermes
    /// ships the same fusion (its `CallBuiltin` / `CallPropertyN`);
    /// Ignition's `CallProperty0/1/2` is the per-argc specialised
    /// equivalent. Saves 3 dispatches + 5 wire bytes per call site —
    /// material on tight method loops (`c.inc()`, `arr.push(x)`).
    ///
    /// Args live at `r_recv + 1.. r_recv + 1 + argc`. The compiler
    /// reserves them contiguous to `r_recv` (no intervening
    /// `r_callee` slot — the callee is loaded inline and never spills
    /// to a register).
    ///
    /// Fast path: shape compare on the receiver, serve the cached
    /// own- or proto-slot, pointer-compare the loaded callee against
    /// the call IC cell, callJSFunction directly. Slow path: same
    /// receiver-type lookup arms as `lda_property` (plain / function /
    /// string / number / bool / bigint / symbol / proxy / namespace
    /// / null+undefined) followed by the same call-dispatch arms as
    /// `call_method` (proxy / bound / revocable / native / generator
    /// / async / regular).
    ///
    /// `ic_load` indexes `Chunk.inline_load_caches` (the same proto-load
    /// cache `lda_property` uses); `ic_call` indexes
    /// `Chunk.inline_call_caches` (the same callee cache
    /// `call_method` uses).
    call_property,
    /// `[op] [r_callee:u8] [argc:u8] [ic:u16]` — `new f(args)`
    /// (§13.3.5). Allocates a fresh ordinary object whose
    /// `[[Prototype]]` is `f.prototype`, calls `f` with `this`
    /// bound to the new object, and yields either the constructor's
    /// return value (if it's an object) or the new object
    /// (otherwise). The `ic` operand indexes
    /// `Chunk.inline_call_caches`; a hit on the cached
    /// `(callee, callee.prototype)` pair skips both the
    /// `valueAsFunction` decode AND the §10.1.14
    /// GetPrototypeFromConstructor accessor walk on every
    /// iteration of a hot `new C(…)` loop. The `proto` field on
    /// `CallICCell` is set only by this opcode.
    new_call,
    /// `[op] [r_callee:u8] [argc:u8]` — §15.10 PTC. Tail-call the
    /// function in register `r_callee` with `argc` arguments at
    /// `r_callee+1.. r_callee+argc`. Spec §14.6 PrepareForTailCall:
    /// the caller's frame is REUSED for the callee — no new
    /// dispatch frame is pushed, the caller's `Return` is skipped,
    /// and `function f(n) { return f(n - 1) }` recurses without
    /// stack growth. Falls back to ordinary `call` semantics
    /// (push + return) for proxies, bound functions, generators,
    /// async functions, and native callbacks — those cases either
    /// can't be flattened (the callee has its own frame allocation)
    /// or would require deeper reentrancy. Emitted by the compiler
    /// whenever (1) the call appears at a statically-detectable
    /// tail position per §15.10.1 IsInTailPosition (return
    /// expression, arrow concise body, conditional / logical /
    /// comma rhs in tail position), (2) the enclosing function is
    /// not a generator / async function, and (3) the call is not
    /// inside a try block whose catch or finally is in the same
    /// chunk.
    tail_call,
    /// `[op] [r_recv:u8] [r_callee:u8] [argc:u8]` — §15.10 PTC,
    /// method-call variant. Identical to `tail_call` except
    /// `this` is bound to the value in `r_recv` (§13.3.6).
    /// No inline-cache slot — the saved tail-call frame would
    /// invalidate the cache layout that `call_method` relies on,
    /// and tail-recursive method calls are rare enough that the
    /// extra IC isn't load-bearing. Falls back to ordinary
    /// `call_method` for exotic callees, same as `tail_call`.
    tail_call_method,
    /// `[op] [scope:u16] [r_callee:u8] [argc:u8]` — §19.2.1 direct
    /// eval. Emitted in place of `call` when the callee is the bare
    /// syntactic identifier `eval` that resolves to no in-scope
    /// binding (so it names the global %eval%). `scope` indexes
    /// `Chunk.direct_eval_scopes` (the caller's captured env-slot
    /// bindings); `r_callee` holds the resolved `eval` value, with
    /// args at `r_callee+1 .. r_callee+argc`.
    ///
    /// Runtime: if the callee is NOT this realm's %eval% intrinsic
    /// (e.g. `globalThis.eval` was reassigned), fall back to an
    /// ordinary call. Otherwise §19.2.1: a non-String arg[0] is
    /// returned unchanged; with the gate closed (`!allow_eval`) a
    /// String arg is the SES policy SyntaxError; with the gate open
    /// the source is compiled against a synthetic outer scope rebuilt
    /// from `scope` and run in a fresh frame whose environment is
    /// parented to the caller's, inheriting the caller's `this` /
    /// `new.target` / home object (Cynic is strict-only, so eval'd
    /// `var` / `let` stay in the eval body's own env per §19.2.1.3).
    direct_eval,
    /// §13.3.6.1 — direct eval whose argument list contains a spread.
    /// The args were materialised into a real array (the spread-call
    /// lowering); the first element is the source text. Encoding:
    /// `[op] [scope:u16] [r_callee:u8] [r_args:u8]`.
    direct_eval_spread,
    /// Load `this` from the current call frame into acc. Top-level
    /// `this` is `undefined` in strict mode (§10.2.1.2). Arrow
    /// functions inherit `this` from their captured frame; the
    /// compiler arranges for that by emitting `LdaThis` against
    /// the lexically enclosing frame's binding.
    lda_this,
    /// `[op]` — acc = new.target of the current frame.
    /// §13.3.12 NewTarget. Reads `f.new_target`, which is set
    /// to the constructing function when the frame was entered
    /// via `new f(args)` and stays `undefined` for plain calls.
    lda_new_target,
    /// `[op] [r:u8]` — acc = (reg instanceof acc).
    /// §13.10.2 InstanceofOperator. The right-hand side must be a
    /// callable; if it isn't, throws TypeError. Walks the LHS's
    /// prototype chain looking for `rhs.prototype`.
    instanceof_,
    /// `[op] [r:u8] [ic:u16]` — acc = (ToPropertyKey(reg) in acc).
    /// §13.10.1 RelationalExpression `in`. Right-hand side must be
    /// an object; if not, throws TypeError. Walks the prototype
    /// chain. On a proxy receiver, dispatches the `has` trap. The IC
    /// caches only the *own-positive* result (`key` is an own property
    /// of the object's shape), guarded by shape + the runtime key —
    /// sound because own presence ⟺ the shape contains the key. The
    /// negative / proto-positive / function / proxy cases never fill.
    in_op,
    /// `[op] [r:u8]` — §7.4.6 IteratorClose for the iterator in
    /// register `r`. Looks up `iter.return`; if callable, invokes
    /// it with no args. Errors thrown by the trap are silently
    /// swallowed (the spec re-throws when the abrupt completion is
    /// a return — Cynic's strict-only profile treats both as
    /// silent). The accumulator is preserved.
    iter_close,
    /// `[op] [r_src:u8] [start:u8]` — destructuring rest helper.
    /// Reads `src.length`, allocates a fresh Array, and copies
    /// `src[start..length]` into it (preserving holes). Used to
    /// implement `const [a, b,...rest] = src` and equivalents.
    /// The new array lands in `acc`.
    array_rest_from,
    /// `[op] [r_src:u8] [r_excl_arr:u8]` — copy every own
    /// enumerable property of `src` whose key is not among the
    /// strings in the array at `r_excl_arr` into a fresh object,
    /// leaving the result in `acc`. Used for `const {x, y,...rest} = src`.
    object_rest_from,
    /// `[op] [k:u16] [r_keys_base:u8] [inner_class_slot:u8]` —
    /// instantiate a class from `Chunk.class_templates[k]`. The
    /// heritage value (for `class … extends X`) is read from the
    /// accumulator on entry (the compiler emits the heritage
    /// expression immediately before this op); when the template's
    /// `has_heritage` is false, the accumulator is ignored.
    /// `r_keys_base` is the first register of a contiguous block
    /// holding the `to_property_key`-coerced computed-key values,
    /// one per member with `computed_key_index >= 0`, in source
    /// order; `make_class` reads them out of the enclosing frame's
    /// register file. Templates without computed keys leave
    /// `r_keys_base` as a don't-care (typically `0`).
    /// `inner_class_slot` (§15.7.14 step 27.b) is the
    /// classScopeEnvRec slot index where the runtime publishes the
    /// freshly constructed constructor BEFORE static fields /
    /// static blocks run, so a static initializer referencing the
    /// class name sees the binding live instead of in TDZ.
    /// Sentinel `0xFF` for anonymous classes (no inner env). The
    /// resulting class constructor lands in `acc`. §15.7.14
    /// OrdinaryClassDefinition mirrors in `runtime/class.zig`.
    make_class,
    /// `[op] [k:u16]` — `acc = home.[[Prototype]][key_k]`, where
    /// `home` is the home object of the executing function (its
    /// `.home_object` slot) and `key_k` is the JSString constant
    /// at index `k`. §13.3.7. Throws if the function has no
    /// home object (e.g. ordinary function) or the lookup walks
    /// off the chain.
    super_get,
    /// `[op]` — `acc = home.[[Prototype]][ToPropertyKey(acc)]`.
    /// §13.3.2 EvaluatePropertyAccessWithExpressionKey for
    /// `super[expr]`. Same semantics as `super_get` but the key
    /// is computed at runtime and arrives in the accumulator.
    super_get_computed,
    /// `[op] [k:u16] [r_value:u8]` — `super.<key> = registers[r_value]`.
    /// Walks `home.[[Prototype]]` to find a setter (or data
    /// property to override); calls the setter with `this` from
    /// the current frame. The new value lands in `acc` (so the
    /// surrounding assignment expression evaluates to it).
    /// §13.3.7.
    super_set,
    /// `[op] [r_key:u8] [r_value:u8]` — `super[r_key] = r_value`.
    /// Same shape as `super_set` but the key is computed at
    /// runtime.
    super_set_computed,
    /// `[op] [r_args:u8] [argc:u8]` — invoke the parent
    /// constructor (`home.[[Prototype]].constructor` of the
    /// executing function) with `this` from the current frame
    /// and `argc` arguments at registers `r_args.. r_args+argc`.
    /// The return value lands in `acc`. §13.3.7 super-call.
    super_call,
    /// Forward the *caller's* arguments to the parent
    /// constructor unchanged. Emitted by the compiler-synthesised
    /// default constructor for derived classes (§15.7.14
    /// step 14.f) — `class B extends A {}` is equivalent to
    /// `class B extends A { constructor(...args) { super(...args); } }`,
    /// but without rest-params support we read the frame's
    /// recorded `argc` directly. No operands.
    super_call_forward,
    /// `[op] [r_args_array:u8]` — `super(...spread)` form. The
    /// args list comes from a runtime-built Array at
    /// `registers[r_args_array]`; the parent constructor runs
    /// with `this` from the current frame and one positional
    /// arg per `arr[i]` for `i` in `[0, arr.length)`. The
    /// returned `this` lands in `acc`.
    super_call_spread,
    /// `[op]` — precondition guard for `super[expr]` / `super[expr] =
    /// v` / `super[expr]++` / `super[expr] op= v` in derived
    /// constructors. §13.3.7.1 SuperProperty evaluation step 2
    /// (`actualThis = ? env.GetThisBinding()`) runs *before*
    /// Expression evaluation; in a derived ctor before `super(...)`
    /// `this` is uninitialized and §9.1.1.3.4 throws ReferenceError.
    /// The compiler emits this op before evaluating the bracket
    /// expression so the throw is observed in the spec'd order
    /// (the inner expression doesn't run). A no-op outside derived
    /// ctor frames and after super has been called.
    super_check_this,
    /// Run the class instance-field initializers on the current
    /// frame's `this`. Reads the executing function's
    /// `home_object` (which is the class prototype), iterates
    /// `home_object.getInstanceFieldInits()`, and for each entry
    /// invokes `init_fn` with `this` bound to the instance and
    /// assigns the result to `this.name`. Also installs
    /// private-method bindings on the instance's
    /// `private_properties` from
    /// `home_object.getPrivateMethodInits()`. No operands.
    /// §15.7.10 InitializeInstanceElements.
    init_instance_fields,
    /// `[op] [k:u16]` — private-property read. The constant pool
    /// entry at `k` is the class-prefixed key (`"P<uid>#name"`);
    /// `acc` holds the receiver. Throws TypeError on brand-check
    /// miss (no such private slot on the receiver). §7.3.27
    /// PrivateElementFind.
    lda_private,
    /// `[op] [k:u16] [r_obj:u8]` — private-property write.
    /// `acc` holds the value, `r_obj` the receiver. Throws
    /// TypeError on brand-check miss.
    sta_private,
    /// `[op] [k:u16]` — `acc = (#name in acc)` for the private
    /// name at constant index `k`. §13.10.2 `PrivateIdentifier in
    /// ShiftExpression`: if Type(rval) is not Object, throw a
    /// TypeError; otherwise return Boolean indicating whether the
    /// private slot is present (field, method, or accessor).
    /// Unlike `lda_private`, a brand-check miss is **not** an
    /// error — it returns `false`. The class-fields-private-in
    /// proposal (stage 4) defines this; Cynic's `#x in y`
    /// fixtures rely on it.
    private_in,
    /// `[op] [k:u16] [r_obj:u8] [is_setter:u8]` — install the
    /// function in `acc` as a getter (`is_setter == 0`) or
    /// setter (`is_setter != 0`) on `r_obj.accessors[key_k]`.
    /// §13.2.5 PropertyDefinitionEvaluation for accessors.
    def_accessor,
    /// `[op] [r_obj:u8] [r_key:u8] [is_setter:u8]` — like
    /// `def_accessor` but the key is the string in `r_key`
    /// (after `computedKeyToString` coercion) rather than a
    /// constant index. Drives `{ get [expr](){} }` and the
    /// matching setter form.
    def_computed_accessor,
    /// `[op] [r_obj:u8]` — §B.3.1 `__proto__` literal — when an
    /// object literal contains `{ __proto__: v }` (and the key
    /// is *not* computed), the value is special: if `v` is an
    /// Object set `r_obj.[[Prototype]] = v`; if `v` is `null`
    /// set it to `null`; otherwise it's a no-op (the `__proto__`
    /// property is *not* created). The computed form
    /// `{ ["__proto__"]: v }` falls through to ordinary
    /// `sta_property` and so isn't routed here. The acc holds
    /// `v`; this op preserves acc.
    set_proto_literal,
    /// `[op] [r_obj:u8]` — §10.2.5 set [[HomeObject]]. If `acc` is
    /// a function, set its `home_object` slot to the object in
    /// `r_obj`. No-op for non-function `acc`. Emitted between
    /// `make_function` and `sta_property` / `def_accessor` for
    /// object-literal methods so `super.x` / `super[x]` /
    /// `super.x(...)` from inside the method walks
    /// `r_obj.[[Prototype]]` to find the parent property —
    /// matching the class-method machinery.
    set_home,

    /// `[op] [r_key:u8] [prefix:u8]` — §13.2.5.5 / §15.5.6.4
    /// SetFunctionName fix-up for computed property keys. If
    /// `acc` is an anonymous function-like (`.name === ""`), set
    /// its `.name` to the property-key derived from `r_key`:
    ///   - String / numeric / boolean / null / undefined → ToString
    ///   - Symbol with description `d`         → `"[" + d + "]"`
    ///   - Symbol with no description          → `""`
    ///   - Already-named function              → no-op
    /// `prefix` selects an accessor-style prefix:
    ///   - `0` → no prefix (plain method or value form)
    ///   - `1` → `"get "` (getter)
    ///   - `2` → `"set "` (setter)
    /// Drives the `name` inference for `{ [k]: function(){} }`,
    /// `{ [k]: () => x }`, `{ [k]: class{} }`, and the
    /// `{ get [k](){} }` / `{ set [k](){} }` accessor forms.
    /// The acc (the function/class) is preserved.
    set_fn_name_from,
    /// Build the implicit `arguments` array-like for the current
    /// non-arrow function frame. Reads registers[0..argc] and
    /// returns a JSObject with numeric-index properties + a
    /// `length` slot, in `acc`. §10.4.4. Emitted by the function
    /// prologue when the body references `arguments`.
    lda_arguments,
    /// `[op]` — §10.4.4 arguments elision. Snapshot the current
    /// non-arrow frame's incoming argument list (registers[0..argc])
    /// into a frame-owned buffer, so a later `call_forward_args` can
    /// replay it after the body's temporaries have overwritten the
    /// caller-arg registers. Emitted (in place of `lda_arguments`) by
    /// the function prologue when EVERY `arguments` reference is the
    /// second argument of a `callee.apply(thisArg, arguments)` forward
    /// — the §10.4.4 arguments object is then never materialised.
    arguments_snapshot,
    /// `[op] [r_callee:u8] [r_thisArg:u8]` — §10.4.4 arguments-elision
    /// forward site, replacing `callee.apply(thisArg, arguments)` when
    /// the enclosing frame elided its arguments object. Guards that
    /// `registers[r_callee].apply` still resolves to
    /// %Function.prototype.apply% (§20.2.3.1): on a hit it calls the
    /// callee directly with `this = registers[r_thisArg]` and the
    /// frame's argument snapshot as the argument list; on a miss (a
    /// shadowing own `.apply`, or a monkey-patched
    /// `Function.prototype.apply`) it builds the real §10.4.4 arguments
    /// object and invokes the resolved `.apply` verbatim. Result in
    /// `acc`.
    call_forward_args,
    /// `[op] [start:u8]` — §15.2.4 IteratorBindingInitialization
    /// for a rest parameter `function f(a, b,...rest) {}`. Build a
    /// fresh Array from the current frame's argument registers
    /// `start..argc`, with `length = argc - start`, leaving it in
    /// `acc`. When the caller passed fewer than `start` args, the
    /// resulting array is empty.
    rest_args_from,
    /// Suspend the current generator frame and surface `acc` as
    /// the yielded value. The runtime saves `ip`, `acc`, env,
    /// `this`, `home_object`, and the register file into the
    /// frame's owning `JSGenerator`, then unwinds the dispatch
    /// loop with `RunResult.yielded`. On resume (next call to
    /// `gen.next(arg)`), `acc` is overwritten with `arg` so the
    /// expression `let x = yield e` reads the sent value.
    /// §27.5.3.7 GeneratorYield.
    gen_yield,
    /// Like `gen_yield`, but the value in `acc` is already a
    /// spec-shaped IteratorResult object and must be returned
    /// from the outer `.next()` / `.return()` / `.throw()`
    /// unchanged — no fresh `CreateIterResultObject` wrap.
    /// Emitted by sync `yield*` per §15.5.5 step 7.a.iv — the
    /// inner iterator's result is yielded through verbatim so
    /// observers see `done` exactly as the inner produced it
    /// (e.g. `done: undefined` propagates instead of being
    /// coerced to `false`), and `value` is not eagerly read.
    gen_yield_iter_result,
    /// Initial suspension marker emitted between the param
    /// prologue and the body of every `function*` / `async function*`.
    /// `wrapGenerator` / `wrapAsyncGenerator` drive the chunk
    /// synchronously from PC=0 — so the param destructuring,
    /// defaults, and RequireObjectCoercible run at call time per
    /// §10.2.1.4 FunctionDeclarationInstantiation — until they hit
    /// this opcode, which saves frame state into the generator and
    /// unwinds via `RunResult.yielded`. The wrapper is returned to
    /// the caller; the first `.next(arg)` resumes from after this
    /// op, with `acc` overwritten by `arg`.
    gen_initial_suspend,
    /// Wait on the value in `acc` to settle, then resume with
    /// the resolved value (or throw the rejection). later
    /// implements this by tail-chaining `Promise.resolve(value)
    ///.then(resumeFn, rejectFn)` — the resumeFn captures the
    /// async function's saved frame state. §27.5.3.8 Await.
    await_,
    /// `[op]` — §7.4.1 GetIterator. Reads the iterable from acc;
    /// looks up its `@@iterator` method, calls it with the
    /// iterable as `this`, and writes the result into acc. If
    /// `@@iterator` is missing, synthesises an array-like
    /// iterator object that walks `length` + numeric-index
    /// access — matches the later for-of fallback so existing
    /// arrays / strings still iterate. Throws `TypeError` if
    /// `@@iterator` exists but isn't callable, or if its return
    /// value isn't an object. Used by for-of, array spread, and
    /// iterable destructuring.
    iter_open,
    /// `[op]` — §27.1.4.3 GetIterator(acc, async). Prefers
    /// `@@asyncIterator`; on absence falls back to the sync
    /// `@@iterator` (the surrounding for-await-of step `await`s
    /// each `next()` result, so a sync iter still composes).
    /// Result lands in `acc`.
    async_iter_open,
    /// `[op] [r_iter:u8] [r_done:u8]` — §7.4.4 IteratorStep on an
    /// iterator opened by `iter_open` (or any spec-shaped iterator
    /// in `r_iter`). If the iter is already marked done (via the
    /// typed `iter_record` slot), or `.next()` returns
    /// `{done: true}`, `acc` ends as `undefined` and the boolean
    /// in `r_done` is set to `true`. Otherwise `acc` holds the
    /// stepped `.value` and `r_done` is `false`. Reading `.done`
    /// and `.value` goes through accessor-aware property reads
    /// (§7.4.7 IteratorComplete / IteratorValue). Used by
    /// `[a, b, ...rest] = src` destructuring.
    iter_step,
    /// `[op] [r_iter:u8] [r_next:u8] [r_done:u8]` — one plain
    /// `for-of` step. Calls the iterator's `[[NextMethod]]`
    /// (cached in `r_next` at loop entry, §7.4.5 GetIteratorDirect)
    /// on the iterator in `r_iter`, then folds §7.4.2 IteratorNext
    /// step 4 (result-not-object → TypeError) and §7.4.8
    /// IteratorStepValue's `.done` / `.value` reads into the same
    /// op: the stepped value lands in `acc`, the boolean `done` in
    /// `r_done`. When `r_iter` is the unmodified built-in Array
    /// iterator (chains to `%ArrayIteratorPrototype%`, `r_next`
    /// still the original `next` native) a fast path steps the
    /// backing storage directly and skips the per-step
    /// CreateIterResultObject allocation. Emitted only for plain
    /// sync `for-of`; `for-await-of` and `for-in` keep the
    /// open-coded `call_method` + `lda_property` sequence.
    for_of_next,
    /// `[op] [ic:u16]` — §14.7.5.6 EnumerateObjectProperties. Reads
    /// the object from acc, walks its own + inherited string-keyed
    /// properties (deduplicated), and produces an iterator that
    /// yields each name. `null` / `undefined` produce an empty
    /// iterator (per §14.7.5.6 ForIn/OfHeadEvaluation step 7).
    /// Symbol-keyed properties are excluded (§14.7.5.6 step 4).
    /// Used by `for-in`. The `ic` operand indexes
    /// `Chunk.inline_forin_caches`: the cell caches the key snapshot
    /// keyed by the receiver shape + a frozen one-level prototype so
    /// a hot loop over a stable object skips the re-walk.
    for_in_open,
    /// `[op]` — discard the current frame's innermost
    /// environment, restoring its parent. Used by closure-per-
    /// iteration `for (let x of …)` (§14.7.5.6
    /// CreatePerIterationEnvironment): the loop body opens a
    /// fresh `make_environment 1` at each iteration's start
    /// and pops it at the end so the next iteration parents to
    /// the same outer env. Closures captured inside the body
    /// keep their reference to the popped env — the GC walks
    /// them through `JSFunction.captured_env`.
    pop_env,
    /// `[op] [k_spec:u16] [k_attr:u16]` — §16.2.1.5 module load.
    /// The constant at `k_spec` holds the import specifier
    /// string. The constant at `k_attr` holds the
    /// `with { type: "..." }` attribute value (e.g. "json" or
    /// "text") when present; `0xFFFF` is the sentinel for "no
    /// attribute" (the conventional default JavaScript import
    /// path). The runtime asks `realm.module_loader` to resolve
    /// the specifier against the executing chunk's `base_url`,
    /// parses + compiles + runs the loaded module if not cached,
    /// and writes the module's exports namespace object into acc.
    /// Subsequent `lda_property` ops read individual named imports
    /// off that namespace. Throws `TypeError` when the loader is
    /// unset or `error.ModuleNotFound` / similar from the loader
    /// itself; the attribute_type drives §16.2.1.8.x synthetic
    /// module dispatch (JSON / text modules) in the loader.
    module_load,
    /// `[op] [k_attr:u16]` — §13.3.10 dynamic `import(specifier)`.
    /// Reads the specifier from `acc` (ToString'd at the call
    /// site). The constant at `k_attr` is the `with { type: "..." }`
    /// attribute value parsed off the import() second arg literal
    /// (`{ with: { type: "..." } }`); `0xFFFF` means no attribute.
    /// Writes the resulting Promise into `acc`. The Promise is
    /// settled by a deferred microtask job (so the loader runs
    /// after the importer's static-DFS finishes per
    /// §16.2.1.10 EvaluateImportCall ordering); observation goes
    /// through the microtask queue — `.then(...)` / `await`
    /// reactions are queued like any other Promise reaction.
    /// TypeError on missing loader / failed load becomes a
    /// rejected Promise; the call itself never throws.
    dynamic_import,
    /// `[op] [r_spec:u8]` — §13.3.10 dynamic `import(specifier,
    /// options)` when `options` is anything other than a literal
    /// `{ with: { type: "..." } }` shape. The specifier was
    /// previously stored to `r_spec`; `options` arrives in `acc`.
    /// Implements §13.3.10.1 EvaluateImportCall steps 9-15:
    /// ToObject the options, `Get(options, "with")`, ToObject the
    /// `with` value, `EnumerableOwnProperties(withObj, key)`,
    /// `Get(withObj, key)` for each key, require each value to be
    /// a String, propagate every abrupt completion through
    /// `IfAbruptRejectPromise`. The compile-time literal-shape
    /// fast path (`.dynamic_import`) is preserved for the common
    /// case to skip the runtime walk.
    dynamic_import_with_options,
    /// `[op]` — §16.2.1.7 ImportMeta runtime semantics. Lazy-
    /// initialise `realm.current_module.import_meta` (an
    /// ordinary object with `[[Prototype]] = %Object.prototype%`)
    /// on first read, then return the cached object in `acc`.
    /// Every subsequent evaluation in the same module returns
    /// the same object (test262
    /// `language/expressions/import.meta/same-object-returned.js`,
    /// `distinct-for-each-module.js`). The parser guarantees this
    /// opcode is only emitted inside a Module goal, so
    /// `realm.current_module` is always set when it runs;
    /// defensive check throws a SyntaxError-class TypeError if
    /// it isn't (should be unreachable in practice).
    import_meta,
    /// `[op] [k:u16]` — publish acc as an export named `k` on
    /// the executing module's namespace
    /// (`realm.current_module.exports`). No-op outside module
    /// context. The compiler emits this for every `export`
    /// declaration so the import side picks up the value once
    /// the body finishes evaluating.
    module_export,
    /// `[op]` — §16.2.1.5 InnerModuleEvaluation link-complete
    /// marker. Emitted by the compiler after the hoisted import
    /// block in `compileModuleAsChunk` (only when the module
    /// declared at least one import). Drains the microtask queue
    /// so any async dependency whose body suspended at a top-level
    /// `await` during its `module_load` gets a chance to settle
    /// before the importer's body proper begins. After draining,
    /// iterates the importer's `pending_async_deps` list and, if
    /// any dep's evaluation Promise rejected, unwinds with the
    /// rejection value (matching §16.2.1.9
    /// AsyncModuleExecutionRejected's parent-propagation). This
    /// is Cynic's lightweight stand-in for the full
    /// [[PendingAsyncDependencies]] + GatherAvailableAncestors
    /// dance: sibling sync deps still run during the import
    /// hoist (so a sync module that destructures `globalThis`
    /// captures values from before any async sibling resumes),
    /// and the importer's body runs only after every async dep
    /// settles. No-op outside module context.
    module_link_complete,
    /// `[op]` — §16.2.3.7 ExportDeclaration : `export * from
    /// "src"` (no namespace binding). Reads the source-module
    /// namespace from `acc` (left there by the immediately-preceding
    /// `module_load`) and merges every own string-keyed export
    /// EXCEPT `"default"` (§16.2.3.7 step 8 of GetExportedNames
    /// skips the default export when traversing star-export
    /// entries) onto the executing module's
    /// `realm.current_module.exports` namespace. Keys already
    /// present on the importer's namespace win (matches the
    /// ResolveExport precedence between local / indirect entries
    /// and star entries — a star entry never overwrites a binding
    /// the module already exports under the same name). The
    /// `@@toStringTag` slot installed by §28.3.5 is also skipped,
    /// since it's a Module Namespace brand property rather than
    /// an export.
    ///
    /// This is a value-copy at re-export-evaluation time. A
    /// fully-spec ResolveExport chain (§15.2.1.16.3 step 10)
    /// would resolve lazily through the source's bindings on
    /// every read; copying at body time is observably equivalent
    /// for the non-mutation case the corpus exercises (the
    /// fixtures only check `name in ns`, presence semantics).
    /// Hole sentinels (TDZ) are forwarded verbatim so the
    /// importer's `lda_property + throw_if_hole` sequence still
    /// raises the spec ReferenceError when the source binding
    /// hasn't initialised yet.
    module_reexport_star,
    /// `[op] [local_k:u16] [exported_k:u16]` — §16.2.3.7
    /// ExportDeclaration : `export { local as exported } from
    /// "src"`. Reads the source-module namespace from `acc`
    /// (left there by the immediately-preceding `module_load`),
    /// fetches the raw value under `constants[local_k]`
    /// **WITHOUT** the §9.4.6.7 GetBindingValue Hole-throw
    /// dispatch — Hole sentinels are forwarded verbatim into
    /// the importer's namespace under `constants[exported_k]`.
    /// That preserves spec semantics: an importer reading
    /// `exported` before the source-module body has run its
    /// declaration site gets the ReferenceError on the
    /// downstream `lda_property + throw_if_hole` sequence,
    /// not at re-export-evaluation time (which would throw
    /// the moment the FROM-side body ran, even if the importer
    /// never observes the binding).
    ///
    /// Distinct from a generic `lda_property` + `module_export`
    /// pair specifically because `lda_property` on a module
    /// namespace promotes Hole into a runtime ReferenceError
    /// per §9.4.6.7 — the wrong policy at re-export time.
    /// No-op outside module context.
    module_reexport_named,

    // ── Globals ─────────────────────────────────────────────────
    /// `[op] [k:u16]` — load a global by name. The name is the
    /// `JSString` at `Chunk.constants[k]`; the value comes from
    /// `Realm.globals` (host-installed bindings like `print`,
    /// `console`, `globalThis`, plus user-declared top-level
    /// bindings as of later). Throws `ReferenceError` on miss.
    /// `let` / `const` reads emit a follow-up `throw_if_hole`
    /// for §13.3.1 TDZ; that's how the global-env declarative
    /// vs property semantics is approximated.
    ///
    /// Wire: `[op] [k:u16] [ic:u16]`. The `ic` operand indexes
    /// `Chunk.inline_load_caches`; a cell with `proto == null` and
    /// `shape == gt.shape` caches an object-env slot on
    /// `globalThis`. `proto_rev` is repurposed to record
    /// `GlobalBindings.decl_revision` at fill time so a new
    /// `let` / `const` / `class` declared at script scope
    /// invalidates the cell (the lex binding shadows the
    /// cached object-env slot per §9.1.1.4 lookup order).
    lda_global,
    /// `[op] [k:u16] [ic:u16]` — like `lda_global`, but produce
    /// `undefined` instead of raising `ReferenceError` when the
    /// global isn't present. Used to compile `typeof Identifier`
    /// where `Identifier` isn't a known binding (§13.5.3 step 3:
    /// an unresolvable Reference yields the string "undefined"
    /// rather than throwing). Shares the same IC cell shape and
    /// invalidation contract as `lda_global`.
    lda_global_or_undef,
    /// `[op] [k:u16]` — store acc into the realm's globals map
    /// under the name held in `Chunk.constants[k]` (a `JSString`).
    /// Creates the binding if it doesn't exist. Used by
    /// top-level `var x = e`, `let x = e`, and function-decl
    /// hoist. Inner-scope assignments still go through
    /// `sta_env`.
    sta_global,
    /// `[op] [k:u16] [r:u8]` — snapshot whether the binding
    /// named `Chunk.constants[k]` is currently present on the
    /// realm globals. Writes `true` into register `r` when the
    /// binding is *unresolved* (a later strict-mode PutValue
    /// would throw), `false` otherwise. Cynic is strict-only,
    /// so §13.15.2 step 1.a "Evaluation of the LHS produces a
    /// Reference Record { [[Base]]: unresolvable, … }" is
    /// captured *before* the RHS runs and consumed by
    /// `sta_global_strict` afterwards. Recording the snapshot
    /// in a register (rather than throwing eagerly) preserves
    /// the spec ordering — a side-effecting RHS that itself
    /// throws (e.g. `s = (new Number("a")).toFixed(Infinity)`
    /// raising RangeError) wins over the ReferenceError that
    /// PutValue would otherwise raise later.
    capture_unresolved_global,
    /// `[op] [k:u16] [r:u8]` — strict-mode store companion to
    /// `capture_unresolved_global`. If register `r` is truthy
    /// (the snapshot saw an unresolvable Reference) raise a
    /// ReferenceError on `Chunk.constants[k]` (§6.2.5.5 step
    /// 6); otherwise write `acc` into `realm.globals[name]`.
    /// Emitted in place of `sta_global` whenever the LHS of an
    /// assignment failed to resolve at compile time.
    sta_global_strict,
    /// `[op] [k:u16]` — initializer-only store for a top-level
    /// `let` / `const` / `class` binding. Writes `acc` into the
    /// realm's declarative env-record (§9.1.1.4 DeclarativeRecord)
    /// for the name held in `Chunk.constants[k]`. Bypasses the
    /// const-immutability check that `sta_global` applies — this
    /// IS the InitializeBinding step (§9.1.1.4 InitializeBinding /
    /// §13.3.1) that seeds the slot in the first place. Subsequent
    /// `sta_global` writes for the same name (re-assignment) still
    /// take the const-check path and throw TypeError when the
    /// binding is `const`.
    sta_global_init,
    /// `[op] [k:u16]` — store-and-stamp variant for top-level
    /// `function` declarations. §9.1.1.4.19
    /// CreateGlobalFunctionBinding: overwrites both the data
    /// slot AND the property flags on the global object with
    /// `{[[Writable]]:true, [[Enumerable]]:true,
    /// [[Configurable]]:false}`. Distinct from `sta_global`
    /// (which preserves existing flags) so a script like
    /// `Object.defineProperty(this, "x", {configurable:true,
    /// value:0}); function x(){}` ends with `x`'s descriptor
    /// matching the function-decl shape rather than the prior
    /// `defineProperty` shape.
    sta_global_fn_decl,
    /// `[op] [slot:u32]` — slot-indexed load of a top-level
    /// `let` / `const` / `class` binding. The runtime index is
    /// `chunk.global_lexical_base + slot`; the value is read by
    /// a bounds-checked array index into the declarative env-
    /// record's `decl_env.values()` — no name hash, no map
    /// lookup. The compiler emits this in place of `lda_global`
    /// only when the resolved binding is provably a global
    /// lexical with an assigned slot.
    ///
    /// Soundness: Cynic ships no `eval` / `Function(string)`, so
    /// the full set of global-lexical bindings is statically
    /// known at compile time — no runtime guard / ResolveType is
    /// needed before the index. This is the perf dividend of the
    /// SES no-dynamic-code stance.
    ///
    /// TDZ (§13.3.1): the slot holds the Hole until init; this
    /// op loads whatever is there and the compiler emits a
    /// following `throw_if_hole`, exactly as `lda_global` does.
    lda_global_slot,
    /// `[op] [slot:u32]` — slot-indexed non-init store to a
    /// top-level `let` / `const` binding. Runtime index is
    /// `chunk.global_lexical_base + slot`. If the slot holds the
    /// Hole → §13.3.1 ReferenceError; else if the binding is
    /// `const` (checked via `decl_consts.values()[idx]`) →
    /// §13.15.2 TypeError; else write `acc` into the slot.
    sta_global_slot,
    /// `[op] [slot:u32]` — slot-indexed initializer store for a
    /// top-level `let` / `const` / `class` binding. Runtime
    /// index is `chunk.global_lexical_base + slot`. Writes `acc`
    /// into the slot unconditionally (fills the TDZ Hole); no
    /// const check — this IS §9.1.1.4 InitializeBinding.
    sta_global_slot_init,

    // ── Objects / properties ────────────────────────────────────
    /// Allocate a fresh empty `JSObject` whose `[[Prototype]]` is
    /// `%Object.prototype%` (or `null` if the realm hasn't
    /// installed builtins). Result lands in acc. Object-literal
    /// compilation emits this followed by a series of
    /// `sta_property` ops to populate the bag.
    make_object,
    /// `[op] [k:u16]` — allocate a fresh `JSObject` with
    /// `[[Prototype]] = %Object.prototype%` AND stamp the literal
    /// shape from `Chunk.literal_shape_templates[k]` onto the
    /// receiver, pre-sizing `slots`. Used by object literals whose
    /// keys are all static identifiers (no computed keys, no
    /// methods, no spread, no `__proto__`, no shorthand
    /// getter/setter). The downstream `def_property` opcodes then
    /// take `shadowSet`'s same-attrs-update fast path on every
    /// iteration of a literal-allocating hot loop instead of
    /// re-walking the shape transition tree per key.
    make_object_shape,
    /// Allocate a fresh empty `JSObject` whose `[[Prototype]]` is
    /// `%Array.prototype%`. Cynic doesn't have a true `JSArray`
    /// kind yet — array literals desugar to a plain object with
    /// stringified-index keys and a `.length` slot, but the
    /// prototype is wired correctly so `arr.push(...)` etc.
    /// dispatch through `Array.prototype`. (later: a real
    /// `JSArray` heap kind for fast indexed access.)
    make_array,
    /// `[op] [r_base:u8] [n:u8]` — §13.2.4.1 fused dense array
    /// literal: allocate a fresh Array exotic and copy the `n`
    /// element values from consecutive registers `r_base ..
    /// r_base+n-1` into its packed elements in one arm. Emitted by
    /// the compiler only for hole-free, spread-free literals with
    /// `1 <= n <= max_fused_array_literal` — one dispatch instead of
    /// `make_array` + n× `def_property`, one exact-capacity reserve
    /// instead of growth reallocs, no per-element canonical-index
    /// parse, and no write barriers (the array is young by
    /// construction, so no old→young edge can form). Element
    /// expressions were already evaluated left-to-right into the
    /// registers, and the array is unreachable until this op
    /// completes, so the batching is unobservable (the JSC
    /// `new_array argv/argc` shape). Result in `acc`.
    make_array_n,
    /// `[op] [r_arr:u8]` — append every own indexed element of
    /// `acc` (the source iterable) to the array in `r_arr`,
    /// updating `r_arr.length`. §13.2.4 SpreadElement lowering.
    /// later treats any object with a numeric `.length` as
    /// spreadable; full Symbol.iterator dispatch is later.
    array_spread,
    /// `[op] [r_obj:u8]` — §13.2.5.5 / §7.3.26 CopyDataProperties.
    /// Read `acc` as the source. `null` / `undefined` are no-ops.
    /// Otherwise walk the source's own enumerable string and
    /// symbol keys (skipping the engine's `__cynic_*` slots),
    /// reading each via the regular property dispatch path
    /// (getters fire), and `[[Set]]` the result into the target
    /// in `r_obj`. Drives `{ ...src, k: v }` object-literal spread.
    object_spread,
    /// `[op] [k:u16]` — load property whose name is `JSString` at
    /// `Chunk.constants[k]` from the object currently in acc.
    /// Walks the prototype chain; missing keys yield `undefined`
    /// (§10.1.8). Throws if the receiver isn't object-typed —
    /// runtime check, like every other dynamic dispatch.
    lda_property,
    /// `[op] [k:u16] [r_obj:u8] [ic:u16]` — register-receiver form of
    /// `lda_property`. Load property `k` from the object in register
    /// `r_obj` (not the accumulator), leaving the result in acc. The
    /// register is only read, never written, so it survives for a
    /// following `call_method` to use as `this`. The compiler emits
    /// this when the receiver already sits in a register (a root/leaf
    /// access — `o.x`, an `obj.method(…)` receiver — where the acc
    /// form would otherwise pay a redundant `ldar`); chain
    /// continuations (`a.b.c`) and computed receivers keep the acc
    /// form. Identical IC shape, prototype walk, getter / Proxy-trap
    /// dispatch, and §10.1.8 missing-key `undefined` as `lda_property`
    /// — only the receiver SOURCE differs.
    lda_property_reg,
    /// `[op] [k:u16] [r_obj:u8] [ic:u16]` — store acc into property
    /// `k` of the object held in register `r_obj`. The compiler
    /// arranges for `obj.x = v` to leave `obj` in `r_obj` and `v`
    /// in acc. `ic` indexes the chunk's `inline_store_caches` table; the
    /// interpreter's hit path is a shape pointer compare + a direct
    /// `slots[cell.slot] = v` (paired with a `properties` bag
    /// update). Misses fall through to `strictSetProperty`, which
    /// re-probes the shape and refills the cell on existing own-data
    /// writable keys.
    sta_property,
    /// `[op] [k:u16] [r_obj:u8]` — §7.3.7 CreateDataPropertyOrThrow.
    /// Define an own data property on `r_obj` with the key `JSString`
    /// at `Chunk.constants[k]` and the value in `acc`, all attributes
    /// `{writable, enumerable, configurable} = true`. Does NOT walk
    /// the prototype chain (so inherited accessors don't fire) and
    /// does NOT respect `writable: false` on an existing slot. Throws
    /// TypeError if the receiver is non-extensible and the key isn't
    /// already own, or if an existing own slot is non-configurable.
    /// Drives ArrayLiteral element init (§13.2.4) and ObjectLiteral
    /// PropertyDefinitionEvaluation (§13.2.5).
    def_property,
    /// `[op] [k:u16] [r_obj:u8] [slot:u16]` — templatized
    /// CreateDataPropertyOrThrow. The companion `make_object_shape`
    /// op stamped a cached `Shape*` whose layout assigns the
    /// literal's `i`th static key to slot `i`, and pre-filled the
    /// receiver's `own_key_order`. This op writes `acc` directly
    /// into `obj.setSlot(slot, …)` with the generational write
    /// barrier — no `hasOwn`, no `flagsFor`, no `shadowSet` shape
    /// lookup, no `recordKey` linear scan. On a shape-guard miss
    /// (e.g. the literal hit a path that demoted the object), it
    /// falls back to the regular `def_property` path so semantics
    /// survive an unexpected demote. `k` is retained for the
    /// fallback's key resolution and for disassembler readability.
    def_template_property,
    /// `[op] [r_obj:u8] [ic:u16]` — `acc = obj[acc]` (computed
    /// property read). Coerces the key to a string at runtime;
    /// non-string keys go through ToPropertyKey (§7.1.19). Walks the
    /// prototype chain like `lda_property`. The `ic` operand indexes
    /// `Chunk.inline_computed_caches`; the cell caches `(shape, slot)` keyed by
    /// the dynamic string key (captured inline in the cell) so a hot
    /// monomorphic `obj[k]` collapses to a shape + key-bytes compare.
    lda_computed,
    /// `[op] [r_obj:u8] [r_key:u8] [ic:u16]` — `obj[key] = acc`
    /// (computed property write). Stores acc; the result of the
    /// expression is the assigned value (still in acc). The `ic`
    /// operand indexes `Chunk.inline_computed_caches`; the cell caches
    /// `(shape, slot)` keyed by the dynamic key so a hot
    /// same-shape `obj[k] = v` rewrite of an existing writable
    /// own-data slot skips ToPropertyKey + the shape hash + the
    /// `[[Set]]` accessor / proto walk.
    sta_computed,
    /// `[op] [r_obj:u8] [r_key:u8]` — §7.3.7 CreateDataPropertyOrThrow
    /// with a computed key. The key is in `r_key` (already
    /// ToPropertyKey'd by the emitting compiler), the value in `acc`.
    /// Same semantics as `def_property` (own-data-prop, no proto
    /// walk). Drives ObjectLiteral `[expr]: value` definitions.
    def_computed,
    /// `[op] [k:u16] [r_obj:u8]` — `delete obj.x` (named delete).
    /// §13.5.1.2 — removes the own property whose key is the
    /// `JSString` at `Chunk.constants[k]` from the object in
    /// `r_obj`. Sets `acc` to `true` on success (or when the
    /// property didn't exist), or throws TypeError when the
    /// property is non-configurable (strict-only path; Cynic is
    /// always strict). Throws TypeError when the receiver isn't
    /// object-typed (§7.1.18 ToObject prep).
    del_named_property,
    /// `[op] [r_obj:u8] [r_key:u8]` — `delete obj[key]` (computed
    /// delete). Same semantics as `del_named_property` with the
    /// key coerced from `r_key` via §7.1.19 ToPropertyKey.
    del_computed_property,

    // ── Environments / closures ─────────────────────────────────
    /// `[op] [slot_count:u8]` — allocate a fresh `Environment`
    /// chained to the current frame's env (or null if none),
    /// with `slot_count` slots all initialised to the TDZ Hole.
    /// Sets `frame.env` to the new env. Emitted at function /
    /// script entry when the body has any named bindings.
    make_environment,
    /// `[op] [depth:u8] [slot:u8]` — load `frame.env^depth.slots[slot]`
    /// into acc. depth=0 reads the current scope's env directly.
    /// Walks the parent chain `depth` times; the compiler
    /// guarantees the chain is long enough.
    lda_env,
    /// `[op] [depth:u8] [slot:u8]` — store acc into
    /// `frame.env^depth.slots[slot]`.
    sta_env,

    // ── Exceptions ───────────────────────────────────────────────────────
    /// Raise `acc` as a thrown value. The interpreter walks the
    /// chunk's exception-handler table to find the catch site;
    /// uncaught exceptions terminate the program. §14.14.
    throw_,
    /// If `acc` is the Hole sentinel, raise a `ReferenceError` —
    /// runtime check for §13.3.1 TDZ. Otherwise no-op. Emitted
    /// after `Ldar` of any `let` / `const` slot.
    throw_if_hole,
    /// §7.1.22 RequireObjectCoercible — if `acc` is null or
    /// undefined, raise a `TypeError`. Otherwise no-op. Emitted
    /// at the head of object destructuring (`const {…} = v`,
    /// `({…} = v)`) before any property reads, so `const {} = null`
    /// throws as the spec requires.
    require_object_coercible,
    /// Unconditional `TypeError` — emitted at runtime assignment
    /// targets that are statically known to be immutable. The
    /// motivating case is `<imported> = ...` where the LHS resolves
    /// to an import binding: §8.1.1.5.5 CreateImportBinding records
    /// the binding as immutable, and §8.1.1.1.4 SetMutableBinding
    /// throws TypeError on an immutable target. `const x = 1; x =
    /// 2;` in strict mode is the same shape, but we report that as
    /// a compile-time `assignment_to_const` diagnostic so the
    /// opcode only fires for import-store paths the parser can't
    /// reject statically (e.g. via destructuring).
    throw_assign_const,
    /// If `acc` is not an Object (per §7.2.5 IsObject — Object or
    /// callable Function), raise a `TypeError`. Otherwise no-op.
    /// Emitted after each `await_` inside async `yield*` to enforce
    /// §27.6.3.7 step 7.b.iv ("If Type(innerResult) is not Object,
    /// throw a TypeError exception") — a manually implemented async
    /// iterator can return a primitive (e.g. `42`) from `.next()` /
    /// `.return()` / `.throw()`; the await fulfils with that
    /// primitive, and we then reject the outer step.
    throw_if_not_object,
    /// §7.1.19 ToPropertyKey applied to `acc`. Runs
    /// ToPrimitive(hint "string") and, for non-Symbol results,
    /// ToString. Emitted right after the key expression of a
    /// computed PropertyName so a user-defined `toString` /
    /// `[@@toPrimitive]` fires BEFORE the property value is
    /// evaluated (matching §13.2.5.5 step 4.a sequencing —
    /// PropertyKey resolution happens before the
    /// AssignmentExpression on the right-hand side).
    to_property_key,

    // ── ES2026 explicit-resource-management — `using` ──────────────────
    /// `[op] [r_dst:u8]` — allocate a fresh internal disposable
    /// stack into `r_dst`. Faster than calling
    /// `new DisposableStack()` from JS: skips constructor dispatch,
    /// IC slots, and a property bag — the result is an engine-
    /// internal record that never escapes to user JS and has only
    /// the `[[DisposableState]]` + `[[DisposeCapability]]` slots set
    /// per §27.3.1.1 steps 4-5. Emitted at the head of a block that
    /// contains one or more `using` declarations.
    alloc_dispose_stack,
    /// `[op] [r_stack:u8] [r_value:u8] [hint:u8]` — register the
    /// value in `r_value` with the dispose stack in `r_stack`.
    /// Performs §9.5.3 AddDisposableResource. If the value is
    /// null / undefined, nothing is appended; otherwise
    /// GetDisposeMethod reads `Symbol.dispose` (hint=0,
    /// sync_dispose, emitted for `using x = ...`) or
    /// `Symbol.asyncDispose` then `Symbol.dispose` (hint=1,
    /// async_dispose, emitted for `await using x = ...` per
    /// §9.5.2 GetDisposeMethod step 1.a). Throws TypeError when
    /// missing or non-callable at the binding site (not later at
    /// dispose time). Emitted right after a `using` / `await
    /// using` declarator stores its value into the binding slot.
    register_using,
    /// `[op] [r_stack:u8] [mode:u8]` — perform §9.5.4 DisposeResources
    /// on the dispose stack in `r_stack`. Walks the resource list
    /// in REVERSE (LIFO); a fresh throw inside a disposer while
    /// another is pending wraps via SuppressedError (§9.5.4 step
    /// 2.b.iv-vi).
    ///
    /// `mode`:
    ///   0 — normal-completion arm. `acc` is preserved on exit
    ///       (so a stashed return value survives the dispose
    ///       walk). A disposer throw raises like `throw_`.
    ///   1 — throw-completion arm. `acc` holds the in-flight
    ///       throw. The dispose walk treats it as the pending
    ///       completion and wraps subsequent disposer throws
    ///       via SuppressedError. On exit `acc` holds the
    ///       outgoing throw (the original or a SuppressedError
    ///       chain); the surrounding bytecode rethrows.
    dispose_stack,
    /// `[op] [r_stack:u8] [mode:u8]` — async variant of
    /// `dispose_stack`. Used by blocks that contain at least one
    /// `await using` declaration. Returns a Promise in `acc` that
    /// fulfils with `undefined` after the LIFO walk awaits every
    /// async-hinted disposer; the caller emits an `await` opcode
    /// immediately after to suspend. Same SuppressedError
    /// chaining as the sync variant (§9.5.4 step 2.b.iv-vi).
    ///
    /// `mode`:
    ///   0 — normal-completion arm. The result Promise rejects
    ///       if a disposer throws (or settles a returned thenable
    ///       with a rejection); the outer `await` re-throws.
    ///   1 — throw-completion arm. `acc` holds the in-flight
    ///       throw on entry. The Promise still resolves with
    ///       undefined on a clean walk (the caller rethrows the
    ///       saved throw); a disposer throw wraps via
    ///       SuppressedError and rejects the result Promise.
    dispose_stack_async,

    // ── Termination ──────────────────────────────────────────────────────
    /// Halt with `acc` as the program's value. Top-level only in
    /// later; later distinguishes return-from-function.
    return_,

    // ── Appended specializations ────────────────────────────────────────
    // Keep new variants at the enum tail so existing byte values remain
    // stable for already-emitted chunks and diagnostic bytecode dumps.
    /// `[op] [r:u8]` — `registers[r] = acc =
    /// ToNumeric(registers[r]) + Type(oldValue)::unit`. §13.4 register-
    /// binding specialization for prefix and discarded postfix updates.
    inc_reg,
    /// `[op] [r:u8]` — decrement counterpart of `inc_reg`.
    dec_reg,
    /// Compact signed-immediate forms. Values outside the indicated width
    /// use the original i32 forms; semantics are identical.
    lda_smi8,
    lda_smi16,
    add_smi8,
    add_smi16,
    /// Compact hot-site forms used while every constant/cache index at the
    /// site fits in one byte. The original u16 forms remain the fallback.
    lda_property8,
    lda_property_reg8,
    sta_property8,
    lda_computed8,
    sta_computed8,
    in_op8,
    lda_global8,
    lda_global_or_undef8,
    for_in_open8,
    call8,
    call0_8,
    call1_8,
    call2_8,
    call3_8,
    call_method8,
    new_call8,
    call_property8,

    // Width-relaxed branch encodings. The original branch opcodes remain the
    // canonical i16 forms; these tails keep existing opcode numbers stable.
    jmp8,
    jmp32,
    jmp_if_false8,
    jmp_if_false32,
    jmp_if_true8,
    jmp_if_true32,
    jmp_if_nullish8,
    jmp_if_nullish32,
    jmp_if_strict_eq8,
    jmp_if_strict_eq32,
    jmp_if_strict_neq8,
    jmp_if_strict_neq32,
    jmp_if_not_lt8,
    jmp_if_not_lt32,
    jmp_if_not_le8,
    jmp_if_not_le32,
    jmp_if_not_gt8,
    jmp_if_not_gt32,
    jmp_if_not_ge8,
    jmp_if_not_ge32,
    loop_inc_lt8,
    loop_inc_lt32,
    /// `[op] [r_discriminant:u8] [table:u16]` — dense int32 switch.
    /// Targets live in `Chunk.switch_tables[table]`; every execution jumps to
    /// either one case body or the default target (no fallthrough edge).
    switch_smi,

    /// Authoritative instruction metadata. Adding an opcode requires one
    /// exhaustive entry here; consumers derive names, sizes and tier/control
    /// contracts from this table instead of maintaining parallel switches.
    pub fn spec(op: Op) InstructionSpec {
        return switch (op) {
            .lda_undefined => baselineInstruction("LdaUndefined", .none),
            .lda_null => baselineInstruction("LdaNull", .none),
            .lda_true => baselineInstruction("LdaTrue", .none),
            .lda_false => baselineInstruction("LdaFalse", .none),
            .lda_smi => baselineInstruction("LdaSmi", .i32),
            .lda_constant => baselineInstruction("LdaConstant", .u16),
            .lda_hole => baselineInstruction("LdaHole", .none),
            .lda_zero => baselineInstruction("LdaZero", .none),
            .lda_one => baselineInstruction("LdaOne", .none),
            .ldar => baselineInstruction("Ldar", .reg),
            .ldar_0 => baselineInstruction("Ldar0", .none),
            .ldar_1 => baselineInstruction("Ldar1", .none),
            .ldar_2 => baselineInstruction("Ldar2", .none),
            .ldar_3 => baselineInstruction("Ldar3", .none),
            .star => baselineInstruction("Star", .reg),
            .star_0 => baselineInstruction("Star0", .none),
            .star_1 => baselineInstruction("Star1", .none),
            .star_2 => baselineInstruction("Star2", .none),
            .star_3 => baselineInstruction("Star3", .none),
            .mov => baselineInstruction("Mov", .reg_reg),
            .add => baselineInstruction("Add", .reg),
            .sub => baselineInstruction("Sub", .reg),
            .mul => baselineInstruction("Mul", .reg),
            .div => instruction("Div", .reg_u16),
            .mod => instruction("Mod", .reg),
            .pow => instruction("Pow", .reg),
            .add_smi => baselineInstruction("AddSmi", .reg_i32),
            .to_int32 => baselineInstruction("ToInt32", .none),
            .add_to_int32 => baselineInstruction("AddToInt32", .reg),
            .bit_and => baselineInstruction("BitAnd", .reg),
            .bit_or => baselineInstruction("BitOr", .reg),
            .bit_xor => baselineInstruction("BitXor", .reg),
            .shl => instruction("Shl", .reg),
            .shr => instruction("Shr", .reg),
            .shr_u => instruction("ShrU", .reg),
            .negate => baselineInstruction("Negate", .none),
            .bit_not => baselineInstruction("BitNot", .none),
            .logical_not => baselineInstruction("LogicalNot", .none),
            .to_number => instruction("ToNumber", .none),
            .to_numeric => instruction("ToNumeric", .none),
            .to_string => instruction("ToString", .none),
            .inc => instruction("Inc", .none),
            .dec => instruction("Dec", .none),
            .inc_reg => baselineInstruction("IncReg", .reg),
            .dec_reg => baselineInstruction("DecReg", .reg),
            .lda_smi8 => baselineInstruction("LdaSmi8", .i8),
            .lda_smi16 => baselineInstruction("LdaSmi16", .i16),
            .add_smi8 => baselineInstruction("AddSmi8", .reg_i8),
            .add_smi16 => baselineInstruction("AddSmi16", .reg_i16),
            .lda_property8 => baselineInstruction("LdaProperty8", .u8_u8),
            .lda_property_reg8 => baselineInstruction("LdaPropertyReg8", .u8_reg_u8),
            .sta_property8 => baselineInstruction("StaProperty8", .u8_reg_u8),
            .lda_computed8 => baselineInstruction("LdaComputed8", .reg_u8),
            .sta_computed8 => instruction("StaComputed8", .reg_reg_u8),
            .in_op8 => instruction("In8", .reg_u8),
            .lda_global8 => baselineInstruction("LdaGlobal8", .u8_u8),
            .lda_global_or_undef8 => baselineInstruction("LdaGlobalOrUndef8", .u8_u8),
            .for_in_open8 => instruction("ForInOpen8", .u8),
            .call8 => baselineInstruction("Call8", .reg_u8_u8),
            .call0_8 => baselineInstruction("Call0_8", .reg_u8),
            .call1_8 => baselineInstruction("Call1_8", .reg_u8),
            .call2_8 => baselineInstruction("Call2_8", .reg_u8),
            .call3_8 => baselineInstruction("Call3_8", .reg_u8),
            .call_method8 => baselineInstruction("CallMethod8", .reg_reg_u8_u8),
            .new_call8 => baselineInstruction("NewCall8", .reg_u8_u8),
            .call_property8 => baselineInstruction("CallProperty8", .u8_reg_u8_u8_u8),
            .jmp8 => controlInstruction("Jmp8", .i8, .jump, .inline_),
            .jmp32 => controlInstruction("Jmp32", .i32, .jump, .inline_),
            .jmp_if_false8 => controlInstruction("JmpIfFalse8", .i8, .conditional_jump, .inline_),
            .jmp_if_false32 => controlInstruction("JmpIfFalse32", .i32, .conditional_jump, .inline_),
            .jmp_if_true8 => controlInstruction("JmpIfTrue8", .i8, .conditional_jump, .inline_),
            .jmp_if_true32 => controlInstruction("JmpIfTrue32", .i32, .conditional_jump, .inline_),
            .jmp_if_nullish8 => controlInstruction("JmpIfNullish8", .i8, .conditional_jump, .unsupported),
            .jmp_if_nullish32 => controlInstruction("JmpIfNullish32", .i32, .conditional_jump, .unsupported),
            .jmp_if_strict_eq8 => controlInstruction("JmpIfStrictEq8", .reg_i8, .conditional_jump, .inline_),
            .jmp_if_strict_eq32 => controlInstruction("JmpIfStrictEq32", .reg_i32, .conditional_jump, .inline_),
            .jmp_if_strict_neq8 => controlInstruction("JmpIfStrictNeq8", .reg_i8, .conditional_jump, .inline_),
            .jmp_if_strict_neq32 => controlInstruction("JmpIfStrictNeq32", .reg_i32, .conditional_jump, .inline_),
            .jmp_if_not_lt8 => controlInstruction("JmpIfNotLt8", .reg_i8, .conditional_jump, .inline_),
            .jmp_if_not_lt32 => controlInstruction("JmpIfNotLt32", .reg_i32, .conditional_jump, .inline_),
            .jmp_if_not_le8 => controlInstruction("JmpIfNotLe8", .reg_i8, .conditional_jump, .inline_),
            .jmp_if_not_le32 => controlInstruction("JmpIfNotLe32", .reg_i32, .conditional_jump, .inline_),
            .jmp_if_not_gt8 => controlInstruction("JmpIfNotGt8", .reg_i8, .conditional_jump, .inline_),
            .jmp_if_not_gt32 => controlInstruction("JmpIfNotGt32", .reg_i32, .conditional_jump, .inline_),
            .jmp_if_not_ge8 => controlInstruction("JmpIfNotGe8", .reg_i8, .conditional_jump, .inline_),
            .jmp_if_not_ge32 => controlInstruction("JmpIfNotGe32", .reg_i32, .conditional_jump, .inline_),
            .loop_inc_lt8 => controlInstruction("LoopIncLt8", .reg_reg_i8, .conditional_jump, .inline_),
            .loop_inc_lt32 => controlInstruction("LoopIncLt32", .reg_reg_i32, .conditional_jump, .inline_),
            .switch_smi => controlInstruction("SwitchSmi", .reg_u16, .multiway_jump, .inline_),
            .typeof_ => instruction("TypeOf", .none),
            .eq => baselineInstruction("Eq", .reg),
            .strict_eq => baselineInstruction("StrictEq", .reg),
            .neq => baselineInstruction("Neq", .reg),
            .strict_neq => baselineInstruction("StrictNeq", .reg),
            .lt => baselineInstruction("Lt", .reg),
            .gt => baselineInstruction("Gt", .reg),
            .le => baselineInstruction("Le", .reg),
            .ge => baselineInstruction("Ge", .reg),
            .jmp => controlInstruction("Jmp", .i16, .jump, .inline_),
            .jmp_if_false => controlInstruction("JmpIfFalse", .i16, .conditional_jump, .inline_),
            .jmp_if_true => controlInstruction("JmpIfTrue", .i16, .conditional_jump, .inline_),
            .jmp_if_nullish => controlInstruction("JmpIfNullish", .i16, .conditional_jump, .unsupported),
            .jmp_if_strict_eq => controlInstruction("JmpIfStrictEq", .reg_i16, .conditional_jump, .inline_),
            .jmp_if_strict_neq => controlInstruction("JmpIfStrictNeq", .reg_i16, .conditional_jump, .inline_),
            .jmp_if_not_lt => controlInstruction("JmpIfNotLt", .reg_i16, .conditional_jump, .inline_),
            .jmp_if_not_le => controlInstruction("JmpIfNotLe", .reg_i16, .conditional_jump, .inline_),
            .jmp_if_not_gt => controlInstruction("JmpIfNotGt", .reg_i16, .conditional_jump, .inline_),
            .jmp_if_not_ge => controlInstruction("JmpIfNotGe", .reg_i16, .conditional_jump, .inline_),
            .loop_inc_lt => controlInstruction("LoopIncLt", .reg_reg_i16, .conditional_jump, .inline_),
            .make_function => instruction("MakeFunction", .u16),
            .make_named_function_expr => instruction("MakeNamedFunctionExpr", .u16),
            .call => baselineInstruction("Call", .reg_u8_u16),
            .call0 => baselineInstruction("Call0", .reg_u16),
            .call1 => baselineInstruction("Call1", .reg_u16),
            .call2 => baselineInstruction("Call2", .reg_u16),
            .call3 => baselineInstruction("Call3", .reg_u16),
            .call_method => baselineInstruction("CallMethod", .reg_reg_u8_u16),
            .call_property => baselineInstruction("CallProperty", .u16_reg_u8_u16_u16),
            .new_call => baselineInstruction("NewCall", .reg_u8_u16),
            .tail_call => controlInstruction("TailCall", .reg_u8, .terminator, .inline_),
            .tail_call_method => controlInstruction("TailCallMethod", .reg_reg_u8, .terminator, .inline_),
            .direct_eval => instruction("DirectEval", .u16_reg_u8),
            .direct_eval_spread => instruction("DirectEvalSpread", .u16_reg_reg),
            .lda_this => baselineInstruction("LdaThis", .none),
            .lda_new_target => instruction("LdaNewTarget", .none),
            .instanceof_ => baselineInstruction("InstanceOf", .reg),
            .in_op => instruction("In", .reg_u16),
            .iter_close => instruction("IterClose", .reg_u8),
            .array_rest_from => instruction("ArrayRestFrom", .reg_u8),
            .object_rest_from => instruction("ObjectRestFrom", .reg_reg),
            .make_class => instruction("MakeClass", .u16_reg_u8),
            .super_get => instruction("SuperGet", .u16),
            .super_get_computed => instruction("SuperGetComputed", .none),
            .super_call => instruction("SuperCall", .reg_u8),
            .super_call_spread => instruction("SuperCallSpread", .reg),
            .super_set => instruction("SuperSet", .u16_reg),
            .super_set_computed => instruction("SuperSetComputed", .reg_reg),
            .super_call_forward => instruction("SuperCallForward", .none),
            .super_check_this => instruction("SuperCheckThis", .none),
            .init_instance_fields => instruction("InitInstanceFields", .none),
            .lda_private => instruction("LdaPrivate", .u16),
            .sta_private => instruction("StaPrivate", .u16_reg),
            .private_in => instruction("PrivateIn", .u16),
            .def_accessor => instruction("DefAccessor", .u16_reg_u8),
            .def_computed_accessor => instruction("DefComputedAccessor", .reg_reg_u8),
            .set_proto_literal => instruction("SetProtoLiteral", .reg),
            .set_home => instruction("SetHome", .reg),
            .set_fn_name_from => instruction("SetFnNameFrom", .reg_u8),
            .lda_arguments => instruction("LdaArguments", .none),
            .arguments_snapshot => instruction("ArgumentsSnapshot", .none),
            .call_forward_args => instruction("CallForwardArgs", .reg_reg),
            .rest_args_from => instruction("RestArgsFrom", .reg),
            .gen_yield => controlInstruction("GenYield", .none, .suspend_, .unsupported),
            .gen_yield_iter_result => controlInstruction("GenYieldIterResult", .none, .suspend_, .unsupported),
            .gen_initial_suspend => controlInstruction("GenInitialSuspend", .none, .suspend_, .unsupported),
            .await_ => controlInstruction("Await", .none, .suspend_, .unsupported),
            .iter_open => instruction("IterOpen", .none),
            .async_iter_open => instruction("AsyncIterOpen", .none),
            .iter_step => instruction("IterStep", .reg_reg),
            .for_of_next => instruction("ForOfNext", .reg_reg_reg),
            .for_in_open => instruction("ForInOpen", .u16),
            .pop_env => instruction("PopEnv", .none),
            .module_load => instruction("ModuleLoad", .u16_u16),
            .dynamic_import => instruction("DynamicImport", .u16),
            .dynamic_import_with_options => instruction("DynamicImportWithOptions", .reg),
            .import_meta => instruction("ImportMeta", .none),
            .module_export => instruction("ModuleExport", .u16),
            .module_link_complete => instruction("ModuleLinkComplete", .none),
            .module_reexport_star => instruction("ModuleReexportStar", .none),
            .module_reexport_named => instruction("ModuleReexportNamed", .u16_u16),
            .make_environment => baselineInstruction("MakeEnvironment", .u8),
            .lda_env => baselineInstruction("LdaEnv", .u8_u8),
            .sta_env => baselineInstruction("StaEnv", .u8_u8),
            .make_object => instruction("MakeObject", .none),
            .make_object_shape => instruction("MakeObjectShape", .u16),
            .make_array => instruction("MakeArray", .none),
            .make_array_n => baselineInstruction("MakeArrayN", .reg_u8),
            .array_spread => instruction("ArraySpread", .reg),
            .object_spread => instruction("ObjectSpread", .reg),
            .lda_property => baselineInstruction("LdaProperty", .u16_u16),
            .lda_property_reg => baselineInstruction("LdaPropertyReg", .u16_reg_u16),
            .sta_property => baselineInstruction("StaProperty", .u16_reg_u16),
            .def_property => instruction("DefProperty", .u16_reg),
            .def_template_property => instruction("DefTemplateProperty", .u16_reg_u16),
            .lda_computed => baselineInstruction("LdaComputed", .reg_u16),
            .sta_computed => instruction("StaComputed", .reg_reg_u16),
            .def_computed => instruction("DefComputed", .reg_reg),
            .del_named_property => instruction("DelNamedProperty", .u16_reg),
            .del_computed_property => instruction("DelComputedProperty", .reg_reg),
            .lda_global => baselineInstruction("LdaGlobal", .u16_u16),
            .lda_global_or_undef => baselineInstruction("LdaGlobalOrUndef", .u16_u16),
            .sta_global => instruction("StaGlobal", .u16),
            .sta_global_init => instruction("StaGlobalInit", .u16),
            .sta_global_fn_decl => instruction("StaGlobalFnDecl", .u16),
            .lda_global_slot => baselineInstruction("LdaGlobalSlot", .u32),
            .sta_global_slot => baselineInstruction("StaGlobalSlot", .u32),
            .sta_global_slot_init => baselineInstruction("StaGlobalSlotInit", .u32),
            .capture_unresolved_global => instruction("CaptureUnresolvedGlobal", .u16_reg),
            .sta_global_strict => instruction("StaGlobalStrict", .u16_reg),
            .throw_ => controlInstruction("Throw", .none, .terminator, .unsupported),
            .throw_if_hole => baselineInstruction("ThrowIfHole", .none),
            .require_object_coercible => instruction("RequireObjectCoercible", .none),
            .throw_assign_const => instruction("ThrowAssignConst", .none),
            .throw_if_not_object => instruction("ThrowIfNotObject", .none),
            .to_property_key => instruction("ToPropertyKey", .none),
            .alloc_dispose_stack => instruction("AllocDisposeStack", .reg),
            .register_using => instruction("RegisterUsing", .reg_reg_u8),
            .dispose_stack => instruction("DisposeStack", .reg_u8),
            .dispose_stack_async => controlInstruction("DisposeStackAsync", .reg_u8, .suspend_, .unsupported),
            .return_ => controlInstruction("Return", .none, .terminator, .inline_),
        };
    }

    /// Total operand bytes, derived from the authoritative layout.
    pub fn operandSize(op: Op) u8 {
        return op.spec().layout.operandSize();
    }

    /// Stable disassembly mnemonic, derived from the authoritative spec.
    pub fn mnemonic(op: Op) []const u8 {
        return op.spec().mnemonic;
    }

    /// Branch encoding metadata shared by relaxation, decoding, CFG analysis,
    /// disassembly, and Bistromath. `null` means ordinary fallthrough or a
    /// non-relative control transfer.
    pub fn branchInfo(op: Op) ?BranchInfo {
        return switch (op) {
            .jmp8 => .{ .canonical = .jmp, .width = .i8, .operand_offset = 0 },
            .jmp => .{ .canonical = .jmp, .width = .i16, .operand_offset = 0 },
            .jmp32 => .{ .canonical = .jmp, .width = .i32, .operand_offset = 0 },
            .jmp_if_false8 => .{ .canonical = .jmp_if_false, .width = .i8, .operand_offset = 0 },
            .jmp_if_false => .{ .canonical = .jmp_if_false, .width = .i16, .operand_offset = 0 },
            .jmp_if_false32 => .{ .canonical = .jmp_if_false, .width = .i32, .operand_offset = 0 },
            .jmp_if_true8 => .{ .canonical = .jmp_if_true, .width = .i8, .operand_offset = 0 },
            .jmp_if_true => .{ .canonical = .jmp_if_true, .width = .i16, .operand_offset = 0 },
            .jmp_if_true32 => .{ .canonical = .jmp_if_true, .width = .i32, .operand_offset = 0 },
            .jmp_if_nullish8 => .{ .canonical = .jmp_if_nullish, .width = .i8, .operand_offset = 0 },
            .jmp_if_nullish => .{ .canonical = .jmp_if_nullish, .width = .i16, .operand_offset = 0 },
            .jmp_if_nullish32 => .{ .canonical = .jmp_if_nullish, .width = .i32, .operand_offset = 0 },
            .jmp_if_strict_eq8 => .{ .canonical = .jmp_if_strict_eq, .width = .i8, .operand_offset = 1 },
            .jmp_if_strict_eq => .{ .canonical = .jmp_if_strict_eq, .width = .i16, .operand_offset = 1 },
            .jmp_if_strict_eq32 => .{ .canonical = .jmp_if_strict_eq, .width = .i32, .operand_offset = 1 },
            .jmp_if_strict_neq8 => .{ .canonical = .jmp_if_strict_neq, .width = .i8, .operand_offset = 1 },
            .jmp_if_strict_neq => .{ .canonical = .jmp_if_strict_neq, .width = .i16, .operand_offset = 1 },
            .jmp_if_strict_neq32 => .{ .canonical = .jmp_if_strict_neq, .width = .i32, .operand_offset = 1 },
            .jmp_if_not_lt8 => .{ .canonical = .jmp_if_not_lt, .width = .i8, .operand_offset = 1 },
            .jmp_if_not_lt => .{ .canonical = .jmp_if_not_lt, .width = .i16, .operand_offset = 1 },
            .jmp_if_not_lt32 => .{ .canonical = .jmp_if_not_lt, .width = .i32, .operand_offset = 1 },
            .jmp_if_not_le8 => .{ .canonical = .jmp_if_not_le, .width = .i8, .operand_offset = 1 },
            .jmp_if_not_le => .{ .canonical = .jmp_if_not_le, .width = .i16, .operand_offset = 1 },
            .jmp_if_not_le32 => .{ .canonical = .jmp_if_not_le, .width = .i32, .operand_offset = 1 },
            .jmp_if_not_gt8 => .{ .canonical = .jmp_if_not_gt, .width = .i8, .operand_offset = 1 },
            .jmp_if_not_gt => .{ .canonical = .jmp_if_not_gt, .width = .i16, .operand_offset = 1 },
            .jmp_if_not_gt32 => .{ .canonical = .jmp_if_not_gt, .width = .i32, .operand_offset = 1 },
            .jmp_if_not_ge8 => .{ .canonical = .jmp_if_not_ge, .width = .i8, .operand_offset = 1 },
            .jmp_if_not_ge => .{ .canonical = .jmp_if_not_ge, .width = .i16, .operand_offset = 1 },
            .jmp_if_not_ge32 => .{ .canonical = .jmp_if_not_ge, .width = .i32, .operand_offset = 1 },
            .loop_inc_lt8 => .{ .canonical = .loop_inc_lt, .width = .i8, .operand_offset = 2 },
            .loop_inc_lt => .{ .canonical = .loop_inc_lt, .width = .i16, .operand_offset = 2 },
            .loop_inc_lt32 => .{ .canonical = .loop_inc_lt, .width = .i32, .operand_offset = 2 },
            else => null,
        };
    }

    pub fn branchVariant(op: Op, width: BranchWidth) Op {
        const canonical = op.branchInfo().?.canonical;
        return switch (canonical) {
            .jmp => switch (width) {
                .i8 => .jmp8,
                .i16 => .jmp,
                .i32 => .jmp32,
            },
            .jmp_if_false => switch (width) {
                .i8 => .jmp_if_false8,
                .i16 => .jmp_if_false,
                .i32 => .jmp_if_false32,
            },
            .jmp_if_true => switch (width) {
                .i8 => .jmp_if_true8,
                .i16 => .jmp_if_true,
                .i32 => .jmp_if_true32,
            },
            .jmp_if_nullish => switch (width) {
                .i8 => .jmp_if_nullish8,
                .i16 => .jmp_if_nullish,
                .i32 => .jmp_if_nullish32,
            },
            .jmp_if_strict_eq => switch (width) {
                .i8 => .jmp_if_strict_eq8,
                .i16 => .jmp_if_strict_eq,
                .i32 => .jmp_if_strict_eq32,
            },
            .jmp_if_strict_neq => switch (width) {
                .i8 => .jmp_if_strict_neq8,
                .i16 => .jmp_if_strict_neq,
                .i32 => .jmp_if_strict_neq32,
            },
            .jmp_if_not_lt => switch (width) {
                .i8 => .jmp_if_not_lt8,
                .i16 => .jmp_if_not_lt,
                .i32 => .jmp_if_not_lt32,
            },
            .jmp_if_not_le => switch (width) {
                .i8 => .jmp_if_not_le8,
                .i16 => .jmp_if_not_le,
                .i32 => .jmp_if_not_le32,
            },
            .jmp_if_not_gt => switch (width) {
                .i8 => .jmp_if_not_gt8,
                .i16 => .jmp_if_not_gt,
                .i32 => .jmp_if_not_gt32,
            },
            .jmp_if_not_ge => switch (width) {
                .i8 => .jmp_if_not_ge8,
                .i16 => .jmp_if_not_ge,
                .i32 => .jmp_if_not_ge32,
            },
            .loop_inc_lt => switch (width) {
                .i8 => .loop_inc_lt8,
                .i16 => .loop_inc_lt,
                .i32 => .loop_inc_lt32,
            },
            else => unreachable,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Op: every variant has a stable mnemonic" {
    inline for (@typeInfo(Op).@"enum".field_names) |field_name| {
        const op: Op = @field(Op, field_name);
        const mnem = op.mnemonic();
        try testing.expect(mnem.len > 0);
    }
}

test "Op: every variant has one authoritative instruction spec" {
    inline for (@typeInfo(Op).@"enum".field_names) |field_name| {
        const op: Op = @field(Op, field_name);
        const spec = op.spec();
        try testing.expectEqualStrings(op.mnemonic(), spec.mnemonic);
        try testing.expectEqual(op.operandSize(), spec.layout.operandSize());
    }
}

test "Op: instruction specs classify representative execution contracts" {
    try testing.expectEqual(OperandLayout.none, Op.lda_undefined.spec().layout);
    try testing.expectEqual(OperandLayout.reg, Op.ldar.spec().layout);
    try testing.expectEqual(OperandLayout.reg_i32, Op.add_smi.spec().layout);
    try testing.expectEqual(OperandLayout.reg_i16, Op.jmp_if_strict_eq.spec().layout);
    try testing.expectEqual(OperandLayout.u16_reg_u8_u16_u16, Op.call_property.spec().layout);

    try testing.expectEqual(ControlFlow.jump, Op.jmp.spec().control_flow);
    try testing.expectEqual(ControlFlow.conditional_jump, Op.jmp_if_false.spec().control_flow);
    try testing.expectEqual(ControlFlow.terminator, Op.return_.spec().control_flow);
    try testing.expectEqual(ControlFlow.fallthrough, Op.add.spec().control_flow);

    try testing.expectEqual(BaselineStrategy.inline_, Op.add.spec().baseline);
    try testing.expectEqual(BaselineStrategy.inline_, Op.inc_reg.spec().baseline);
    try testing.expectEqual(BaselineStrategy.unsupported, Op.await_.spec().baseline);
}

test "Op: operandSize agrees with the documented encoding" {
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.lda_undefined));
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.lda_hole));
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.throw_));
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.throw_if_hole));
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.return_));
    try testing.expectEqual(@as(u8, 1), Op.operandSize(.ldar));
    try testing.expectEqual(@as(u8, 1), Op.operandSize(.add));
    // `div` carries a raw-operand type-profile index in addition to its lhs
    // register: `[op] [r:u8] [profile:u16]`.
    try testing.expectEqual(@as(u8, 3), Op.operandSize(.div));
    try testing.expectEqual(@as(u8, 2), Op.operandSize(.mov));
    try testing.expectEqual(@as(u8, 2), Op.operandSize(.lda_constant));
    try testing.expectEqual(@as(u8, 2), Op.operandSize(.jmp));
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.lda_smi));
    // `lda_property` is `[op] [k:u16] [ic:u16]` — 4 bytes of operand.
    // The IC operand was added with the monomorphic property cache;
    // a stale `operandSize` here would silently misalign the
    // disassembler's PC walk (the interpreter advances explicitly,
    // so unit-test failures stay hidden — playground/source-map
    // hover would be the user-visible signal).
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.lda_property));
    // `lda_property_reg` is the register-receiver counterpart:
    // `[op] [k:u16] [r_obj:u8] [ic:u16]` — 5 bytes, the same operand
    // shape as `sta_property`.
    try testing.expectEqual(@as(u8, 5), Op.operandSize(.lda_property_reg));
    // `lda_global` and `lda_global_or_undef` carry an IC slot
    // alongside the key constant index: `[op] [k:u16] [ic:u16]`,
    // 4 bytes of operand. The IC turns a `decl_env.get` +
    // `globalThis.lookupOwn` hash pair into a shape compare +
    // slot load on the hot `Math` / `Object` / `Array` / `console`
    // read sites.
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.lda_global));
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.lda_global_or_undef));
    // `call` carries the same call-IC slot `call_method` does, so
    // free-function calls (`f(x)`) get the cached-callee fast path
    // too: `[op] [r_callee:u8] [argc:u8] [ic:u16]` — 4 bytes.
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.call));
    // `new_call` reuses the same `CallICCell` table to cache
    // `(callee, callee.prototype)` so hot `new C(…)` loops skip
    // both `valueAsFunction` and §10.1.14
    // GetPrototypeFromConstructor: `[op] [r_callee:u8] [argc:u8]
    // [ic:u16]` — 4 bytes.
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.new_call));
    // `call_property` is `[op] [k:u16] [r_recv:u8] [argc:u8]
    // [ic_load:u16] [ic_call:u16]` — 8 bytes of operand. Fuses the
    // `ldar + lda_property + star + call_method` 4-op sequence into
    // one dispatch for the simple `obj.method(args)` shape.
    try testing.expectEqual(@as(u8, 8), Op.operandSize(.call_property));
    // `sta_property` is `[op] [k:u16] [r_obj:u8] [ic:u16]` — 5 bytes
    // of operand. Same disassembler-PC-walk hazard as `lda_property`
    // if this gets out of sync with the encoding.
    try testing.expectEqual(@as(u8, 5), Op.operandSize(.sta_property));
    // `make_class` is `[op] [k:u16] [r_keys_base:u8] [inner_class_slot:u8]`
    // — 4 bytes of operand (§15.7.14 step 27.b). Was 3 in an
    // earlier revision; disasm walked off any MakeClass boundary
    // (interpreter advances explicitly, so the bug was only
    // user-visible through `cynic run --dump-bytecode` / playground
    // hover). Pinned to catch any future operand-shape drift.
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.make_class));
    // `loop_inc_lt` is `[op] [r_counter:u8] [r_bound:u8] [back_offset:i16]`
    // — 4 bytes of operand. Counter-loop specialization (ROADMAP
    // item #6); fused increment + compare + back-jump for the
    // canonical `for (let i = INT; i < INT; i++)` shape.
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.loop_inc_lt));
    // `add_to_int32` is `[op] [r:u8]` — 1 byte of operand, same shape
    // as `add`. Fuses the `Add r; ToInt32` pair (the `(a + b) | 0`
    // idiom); a wrong size would walk the disassembler off the next
    // instruction boundary.
    try testing.expectEqual(@as(u8, 1), Op.operandSize(.add_to_int32));
    // Register update specializations are `[op] [r:u8]`. Keeping the
    // operand size pinned is load-bearing for disassembly, liveness, and
    // Bistromath's unsupported-op scan to stay aligned on the next opcode.
    try testing.expectEqual(@as(u8, 1), Op.operandSize(.inc_reg));
    try testing.expectEqual(@as(u8, 1), Op.operandSize(.dec_reg));
}
