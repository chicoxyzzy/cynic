//! AArch64 (A64) instruction encoders for the JIT substrate — pure
//! functions from operands to 32-bit instruction words. Buffering,
//! labels, and branch fixups live in masm.zig; this file knows only
//! bit layouts. Encodings follow the Arm ARM (DDI 0487) A64 ISA;
//! every encoder is pinned by a golden test, and masm.zig's
//! execution tests run the same words on real silicon.
//! Design record: docs/jit.md §7.
//!
//! Scope grows on demand (docs/jit.md §12 step 1): the set below is
//! what the substrate smoke and the Bistromath MVP need — moves,
//! 64-bit immediate halves, add/sub (register + immediate, flag
//! variants), logical ops, shifts, scaled loads/stores, and branches.

const std = @import("std");

/// General-purpose X registers. Encodings that need register 31
/// (XZR as operand, SP never) spell it internally — keeping 31 out
/// of the public enum avoids the classic XZR/SP confusion.
pub const Reg = enum(u5) {
    // zig fmt: off
    x0, x1, x2, x3, x4, x5, x6, x7,
    x8, x9, x10, x11, x12, x13, x14, x15,
    x16, x17, x18, x19, x20, x21, x22, x23,
    x24, x25, x26, x27, x28,
    /// x29 — the frame pointer in the AAPCS64 ABI.
    fp,
    /// x30 — the link register.
    lr,
    // zig fmt: on
};

/// Condition codes for `b.cond` (Arm ARM C1.2.4).
pub const Cond = enum(u4) {
    eq,
    ne,
    cs,
    cc,
    mi,
    pl,
    vs,
    vc,
    hi,
    ls,
    ge,
    lt,
    gt,
    le,
    al,
    nv,
};

const xzr: u32 = 31;

inline fn r(reg: Reg) u32 {
    return @intFromEnum(reg);
}

// ---- moves and immediates -------------------------------------------------

/// MOVZ Xd, #imm16, LSL #(hw*16)
pub fn movz(rd: Reg, imm16: u16, hw: u2) u32 {
    return 0xD2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | r(rd);
}

/// MOVK Xd, #imm16, LSL #(hw*16)
pub fn movk(rd: Reg, imm16: u16, hw: u2) u32 {
    return 0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | r(rd);
}

/// MOVN Xd, #imm16, LSL #(hw*16)
pub fn movn(rd: Reg, imm16: u16, hw: u2) u32 {
    return 0x92800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | r(rd);
}

/// MOV Xd, Xm — alias of ORR Xd, XZR, Xm.
pub fn movReg(rd: Reg, rm: Reg) u32 {
    return 0xAA000000 | (r(rm) << 16) | (xzr << 5) | r(rd);
}

// ---- arithmetic ------------------------------------------------------------

/// ADD Xd, Xn, Xm
pub fn addReg(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x8B000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// SUB Xd, Xn, Xm
pub fn subReg(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0xCB000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// ADDS Xd, Xn, Xm (flag-setting — the Smi overflow check's friend)
pub fn addsReg(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0xAB000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// SUBS Xd, Xn, Xm
pub fn subsReg(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0xEB000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// CMP Xn, Xm — alias of SUBS XZR, Xn, Xm.
pub fn cmpReg(rn: Reg, rm: Reg) u32 {
    return 0xEB000000 | (r(rm) << 16) | (r(rn) << 5) | xzr;
}

/// ADD Xd, Xn, #imm12 (optionally LSL #12)
pub fn addImm(rd: Reg, rn: Reg, imm12: u12, lsl12: bool) u32 {
    return 0x91000000 | (@as(u32, @intFromBool(lsl12)) << 22) |
        (@as(u32, imm12) << 10) | (r(rn) << 5) | r(rd);
}

/// SUB Xd, Xn, #imm12 (optionally LSL #12)
pub fn subImm(rd: Reg, rn: Reg, imm12: u12, lsl12: bool) u32 {
    return 0xD1000000 | (@as(u32, @intFromBool(lsl12)) << 22) |
        (@as(u32, imm12) << 10) | (r(rn) << 5) | r(rd);
}

/// CMP Xn, #imm12 — alias of SUBS XZR, Xn, #imm12.
pub fn cmpImm(rn: Reg, imm12: u12, lsl12: bool) u32 {
    return 0xF1000000 | (@as(u32, @intFromBool(lsl12)) << 22) |
        (@as(u32, imm12) << 10) | (r(rn) << 5) | xzr;
}

// ---- logical and shifts ----------------------------------------------------

/// ADDS Wd, Wn, Wm — 32-bit flag-setting add (the Smi fast path's
/// overflow detector: V flags an i32 overflow).
pub fn addsRegW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x2B000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// SUBS Wd, Wn, Wm
pub fn subsRegW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x6B000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// CMP Wn, Wm — alias of SUBS WZR, Wn, Wm (32-bit signed compare).
pub fn cmpRegW(rn: Reg, rm: Reg) u32 {
    return 0x6B000000 | (r(rm) << 16) | (r(rn) << 5) | xzr;
}

/// ADDS Wd, Wn, #imm12
pub fn addsImmW(rd: Reg, rn: Reg, imm12: u12) u32 {
    return 0x31000000 | (@as(u32, imm12) << 10) | (r(rn) << 5) | r(rd);
}

/// CSET Wd, cond — alias of CSINC Wd, WZR, WZR, invert(cond).
pub fn csetW(rd: Reg, cond: Cond) u32 {
    const inverted: u32 = @as(u32, @intFromEnum(cond)) ^ 1;
    return 0x1A9F07E0 | (inverted << 12) | r(rd);
}

/// SMULL Xd, Wn, Wm — 64-bit product of 32-bit operands; pair with
/// `sxtw` + a 64-bit compare to detect i32 overflow.
pub fn smull(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x9B207C00 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// SXTW Xd, Wn — alias of SBFM Xd, Xn, #0, #31.
pub fn sxtw(rd: Reg, rn: Reg) u32 {
    return 0x93407C00 | (r(rn) << 5) | r(rd);
}

/// AND Xd, Xn, Xm
pub fn andReg(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x8A000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// AND Wd, Wn, Wm
pub fn andRegW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x0A000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// BIC Xd, Xn, Xm — Xn AND NOT Xm (AND with the N bit set). Used by
/// `copysign` to clear the sign bit (`bic` against the sign mask).
pub fn bicReg(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x8A200000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// BIC Wd, Wn, Wm — the W-form of `bicReg` (f32 copysign).
pub fn bicRegW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x0A200000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

// Data-processing (1 source) bit-count ops. `clz` counts leading zeros;
// `ctz` has no direct instruction — it's `rbit` (bit reverse) then `clz`.
// Both yield the bit width for a zero input, matching wasm's clz/ctz.

/// CLZ Wd, Wn — count leading zeros (32-bit).
pub fn clzW(rd: Reg, rn: Reg) u32 {
    return 0x5AC01000 | (r(rn) << 5) | r(rd);
}

/// CLZ Xd, Xn — count leading zeros (64-bit).
pub fn clzX(rd: Reg, rn: Reg) u32 {
    return 0xDAC01000 | (r(rn) << 5) | r(rd);
}

/// RBIT Wd, Wn — reverse the bit order (32-bit); paired with `clzW` for ctz.
pub fn rbitW(rd: Reg, rn: Reg) u32 {
    return 0x5AC00000 | (r(rn) << 5) | r(rd);
}

/// RBIT Xd, Xn — reverse the bit order (64-bit); paired with `clzX` for ctz.
pub fn rbitX(rd: Reg, rn: Reg) u32 {
    return 0xDAC00000 | (r(rn) << 5) | r(rd);
}

// Sign-extension ops (SBFM aliases) for the wasm `extend{8,16,32}_s`
// family: take the low byte/half/word of the source and replicate its
// sign bit through the rest of the W- or X-form result.

/// SXTB Wd, Wn — sign-extend the low byte to 32 bits.
pub fn sxtbW(rd: Reg, rn: Reg) u32 {
    return 0x13001C00 | (r(rn) << 5) | r(rd);
}

/// SXTH Wd, Wn — sign-extend the low halfword to 32 bits.
pub fn sxthW(rd: Reg, rn: Reg) u32 {
    return 0x13003C00 | (r(rn) << 5) | r(rd);
}

/// SXTB Xd, Wn — sign-extend the low byte to 64 bits.
pub fn sxtbX(rd: Reg, rn: Reg) u32 {
    return 0x93401C00 | (r(rn) << 5) | r(rd);
}

/// SXTH Xd, Wn — sign-extend the low halfword to 64 bits.
pub fn sxthX(rd: Reg, rn: Reg) u32 {
    return 0x93403C00 | (r(rn) << 5) | r(rd);
}

/// SXTW Xd, Wn — sign-extend the low word to 64 bits.
pub fn sxtwX(rd: Reg, rn: Reg) u32 {
    return 0x93407C00 | (r(rn) << 5) | r(rd);
}

// NEON vector ops used to synthesize `popcnt` — there is no scalar GP
// population count on AArch64. The operands are v-registers (the `Reg`
// number selects v0..v31, as with the FP ops); the value bridges in via
// `fmov` from a GP register. The `.8B` arrangement covers the low 64 bits.

/// CNT Vd.8B, Vn.8B — per-byte population count of the low eight bytes.
pub fn cnt8b(vd: Reg, vn: Reg) u32 {
    return 0x0E205800 | (r(vn) << 5) | r(vd);
}

/// ADDV Bd, Vn.8B — horizontal add of the eight byte lanes into byte 0
/// (zeroing the rest), summing the per-byte counts into the total.
pub fn addvB(vd: Reg, vn: Reg) u32 {
    return 0x0E31B800 | (r(vn) << 5) | r(vd);
}

/// ORR Wd, Wn, Wm
pub fn orrRegW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x2A000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// MOV Wd, Wm — alias of ORR Wd, WZR, Wm; zero-extends into the
/// 64-bit register (the cheap "drop the high bits" move).
pub fn movRegW(rd: Reg, rm: Reg) u32 {
    return 0x2A000000 | (r(rm) << 16) | (xzr << 5) | r(rd);
}

/// EOR Wd, Wn, Wm
pub fn eorRegW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x4A000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// LSLV Wd, Wn, Wm — logical shift left by the low 5 bits of Wm
/// (i.e. count mod 32), which is exactly wasm i32.shl's masking.
pub fn lslvW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x1AC02000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// LSRV Wd, Wn, Wm — logical (zero-fill) shift right; wasm i32.shr_u.
pub fn lsrvW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x1AC02400 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// ASRV Wd, Wn, Wm — arithmetic (sign-fill) shift right; wasm i32.shr_s.
pub fn asrvW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x1AC02800 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// UDIV Wd, Wn, Wm — unsigned divide. AArch64 division never faults:
/// Wm == 0 yields 0 (so wasm's divide-by-zero trap must be an explicit
/// check before this), and there is no unsigned overflow case.
pub fn udivW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x1AC00800 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// SDIV Wd, Wn, Wm — signed divide. Also non-faulting: Wm == 0 yields 0
/// and INT_MIN / -1 yields INT_MIN, so both of wasm's i32.div_s traps
/// (divide-by-zero, overflow) must be explicit checks before this.
pub fn sdivW(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x1AC00C00 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// MSUB Wd, Wn, Wm, Wa — Wd = Wa - Wn*Wm. Pairs with a divide to form a
/// remainder (`rem = a - (a/b)*b`).
pub fn msubW(rd: Reg, rn: Reg, rm: Reg, ra: Reg) u32 {
    return 0x1B008000 | (r(rm) << 16) | (r(ra) << 10) | (r(rn) << 5) | r(rd);
}

/// UDIV Xd, Xn, Xm — 64-bit unsigned divide (non-faulting; wasm i64.div_u
/// needs an explicit divide-by-zero check before it).
pub fn udiv(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x9AC00800 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// SDIV Xd, Xn, Xm — 64-bit signed divide (non-faulting; wasm i64.div_s
/// needs explicit divide-by-zero and INT64_MIN / -1 overflow checks).
pub fn sdiv(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x9AC00C00 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// MSUB Xd, Xn, Xm, Xa — Xd = Xa - Xn*Xm, for the 64-bit remainder.
pub fn msub(rd: Reg, rn: Reg, rm: Reg, ra: Reg) u32 {
    return 0x9B008000 | (r(rm) << 16) | (r(ra) << 10) | (r(rn) << 5) | r(rd);
}

/// CSEL Wd, Wn, Wm, cond — Wd = cond ? Wn : Wm. Branchless select,
/// wasm `select` (cond on top picks the deeper-but-one operand).
pub fn cselW(rd: Reg, rn: Reg, rm: Reg, cond: Cond) u32 {
    return 0x1A800000 | (r(rm) << 16) | (@as(u32, @intFromEnum(cond)) << 12) | (r(rn) << 5) | r(rd);
}

/// CSEL Xd, Xn, Xm, cond — the 64-bit select. wasm `select` on an i64 or
/// f64 (or an f32 reinterpreted in a GP register) must preserve all 64
/// bits; the W-form would truncate. Correct for i32 too — its operands are
/// zero-extended, so the full-width select keeps the high word clear.
pub fn csel(rd: Reg, rn: Reg, rm: Reg, cond: Cond) u32 {
    return 0x9A800000 | (r(rm) << 16) | (@as(u32, @intFromEnum(cond)) << 12) | (r(rn) << 5) | r(rd);
}

/// ORR Xd, Xn, Xm
pub fn orrReg(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0xAA000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// EOR Xd, Xn, Xm
pub fn eorReg(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0xCA000000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// MUL Xd, Xn, Xm — alias of MADD Xd, Xn, Xm, XZR. The low 64 bits of the
/// product, which is exactly wasm i64.mul (mod 2^64).
pub fn mul(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x9B007C00 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// LSLV Xd, Xn, Xm — shift left by the low 6 bits of Xm (count mod 64),
/// exactly wasm i64.shl's masking.
pub fn lslv(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x9AC02000 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// LSRV Xd, Xn, Xm — logical (zero-fill) shift right; wasm i64.shr_u.
pub fn lsrv(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x9AC02400 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// ASRV Xd, Xn, Xm — arithmetic (sign-fill) shift right; wasm i64.shr_s.
pub fn asrv(rd: Reg, rn: Reg, rm: Reg) u32 {
    return 0x9AC02800 | (r(rm) << 16) | (r(rn) << 5) | r(rd);
}

/// LSL Xd, Xn, #shift — alias of UBFM Xd, Xn, #(-shift MOD 64), #(63-shift).
pub fn lslImm(rd: Reg, rn: Reg, shift: u6) u32 {
    const immr: u32 = @as(u32, 64 - @as(u32, shift)) & 0x3F;
    const imms: u32 = 63 - @as(u32, shift);
    return 0xD3400000 | (immr << 16) | (imms << 10) | (r(rn) << 5) | r(rd);
}

/// LSR Xd, Xn, #shift — alias of UBFM Xd, Xn, #shift, #63.
pub fn lsrImm(rd: Reg, rn: Reg, shift: u6) u32 {
    return 0xD340FC00 | (@as(u32, shift) << 16) | (r(rn) << 5) | r(rd);
}

// ---- memory ----------------------------------------------------------------

/// LDR Xt, [Xn, #byte_off] — unsigned scaled offset; `byte_off`
/// must be 8-byte aligned and ≤ 32760 (imm12 × 8).
pub fn ldrImm(rt: Reg, rn: Reg, byte_off: u15) u32 {
    std.debug.assert(byte_off % 8 == 0);
    return 0xF9400000 | (@as(u32, byte_off / 8) << 10) | (r(rn) << 5) | r(rt);
}

/// STR Xt, [Xn, #byte_off] — unsigned scaled offset, same limits.
pub fn strImm(rt: Reg, rn: Reg, byte_off: u15) u32 {
    std.debug.assert(byte_off % 8 == 0);
    return 0xF9000000 | (@as(u32, byte_off / 8) << 10) | (r(rn) << 5) | r(rt);
}

/// LDR Wt, [Xn, #byte_off] — 32-bit load, unsigned scaled offset;
/// `byte_off` must be 4-byte aligned and ≤ 16380 (imm12 × 4).
pub fn ldrImmW(rt: Reg, rn: Reg, byte_off: u14) u32 {
    std.debug.assert(byte_off % 4 == 0);
    return 0xB9400000 | (@as(u32, byte_off / 4) << 10) | (r(rn) << 5) | r(rt);
}

/// LDRB Wt, [Xn, #imm12] — unsigned byte load (atomic-flag reads;
/// plain monotonic load is enough for a monitor flag the consumer
/// re-checks with proper ordering after tier-down).
pub fn ldrbImm(rt: Reg, rn: Reg, imm12: u12) u32 {
    return 0x39400000 | (@as(u32, imm12) << 10) | (r(rn) << 5) | r(rt);
}

/// LDR Wt, [Xn, Xm] — 32-bit load from base Xn + register offset Xm
/// (no scaling, LSL #0), zero-extended into Wt. The wasm memory load:
/// Xn is the memory base, Xm the bounds-checked effective address.
pub fn ldrRegW(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0xB8606800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// STR Wt, [Xn, Xm] — store Wt's low 4 bytes at base Xn + register
/// offset Xm (no scaling). The wasm memory store.
pub fn strRegW(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0xB8206800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// LDRB Wt, [Xn, Xm] — load one byte, zero-extended into Wt (i32.load8_u).
pub fn ldrbRegW(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0x38606800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// LDRSB Wt, [Xn, Xm] — load one byte, sign-extended into the 32-bit Wt
/// (i32.load8_s). The W form clears bits 32..63 of the cell.
pub fn ldrsbRegW(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0x38E06800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// LDRH Wt, [Xn, Xm] — load a halfword, zero-extended into Wt (i32.load16_u).
pub fn ldrhRegW(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0x78606800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// LDRSH Wt, [Xn, Xm] — load a halfword, sign-extended into the 32-bit Wt
/// (i32.load16_s).
pub fn ldrshRegW(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0x78E06800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// STRB Wt, [Xn, Xm] — store Wt's low byte (i32.store8).
pub fn strbRegW(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0x38206800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// STRH Wt, [Xn, Xm] — store Wt's low halfword (i32.store16).
pub fn strhRegW(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0x78206800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// LDR Xt, [Xn, Xm] — 64-bit load (i64.load). The zero-extending narrow
/// i64 loads reuse the W-form ldrb/ldrh/ldr (the W destination clears bits
/// 32..63, which is the i64 zero-extension); only the sign-extending forms
/// need a distinct 64-bit-destination encoding below.
pub fn ldrReg(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0xF8606800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// STR Xt, [Xn, Xm] — 64-bit store (i64.store).
pub fn strReg(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0xF8206800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// LDRSB Xt, [Xn, Xm] — load a byte, sign-extended to 64 bits (i64.load8_s).
pub fn ldrsbReg(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0x38A06800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// LDRSH Xt, [Xn, Xm] — load a halfword, sign-extended to 64 (i64.load16_s).
pub fn ldrshReg(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0x78A06800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

/// LDRSW Xt, [Xn, Xm] — load a word, sign-extended to 64 (i64.load32_s).
pub fn ldrswReg(rt: Reg, rn: Reg, rm: Reg) u32 {
    return 0xB8A06800 | (r(rm) << 16) | (r(rn) << 5) | r(rt);
}

// ── floating-point (the GP↔FP bridge for the wasm float tier) ────────
// Spasm keeps the operand stack in GP registers, so a float value lives
// as raw bits in its slot's GP register; an FP op bridges those bits into
// a v-register, computes, and bridges back. The `Reg` argument's *number*
// (0..31) selects the v-register — passing `.x16`/`.x17` means v16/v17
// (caller-saved FP scratch, a different register file from GP x16/x17).

/// FMOV Dd, Xn — move a GP register's 64 bits into an FP double register.
pub fn fmovXtoD(fd: Reg, xn: Reg) u32 {
    return 0x9E670000 | (r(xn) << 5) | r(fd);
}

/// FMOV Xd, Dn — move an FP double register's 64 bits into a GP register.
pub fn fmovDtoX(xd: Reg, dn: Reg) u32 {
    return 0x9E660000 | (r(dn) << 5) | r(xd);
}

/// FADD Dd, Dn, Dm — double-precision add.
pub fn faddD(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E602800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FSUB Dd, Dn, Dm — double-precision subtract.
pub fn fsubD(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E603800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FMUL Dd, Dn, Dm — double-precision multiply.
pub fn fmulD(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E600800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FDIV Dd, Dn, Dm — double-precision divide.
pub fn fdivD(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E601800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FMIN Dd, Dn, Dm — double-precision minimum (NaN-propagating, and
/// `min(-0, +0) = -0` — the plain FMIN, not the IEEE-numeric FMINNM,
/// so it matches §4.3.3 f64.min).
pub fn fminD(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E605800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FMAX Dd, Dn, Dm — double-precision maximum (`max(-0, +0) = +0`).
pub fn fmaxD(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E604800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FCMP Dn, Dm — double-precision compare, setting NZCV. A wasm relop then
/// `cset`s the result: ordered `<` is `mi`, `>` is `gt`, `<=` is `ls`,
/// `>=` is `ge`, `==` is `eq`, and `!=` is `ne` (NaN leaves Z clear, so
/// `ne` is true and the ordered conditions are false — exactly the spec).
pub fn fcmpD(dn: Reg, dm: Reg) u32 {
    return 0x1E602000 | (r(dm) << 16) | (r(dn) << 5);
}

// Double-precision one-source ops (§4.3.3 f64 unary). FABS/FNEG are
// non-arithmetic sign-bit ops that preserve NaN payloads; FRINTP/M/Z/N
// are the directed rounding modes (toward +inf / -inf / zero / nearest-
// ties-to-even); FSQRT is the IEEE square root.

/// FABS Dd, Dn — double-precision absolute value (sign-bit clear).
pub fn fabsD(fd: Reg, dn: Reg) u32 {
    return 0x1E60C000 | (r(dn) << 5) | r(fd);
}

/// FNEG Dd, Dn — double-precision negate (sign-bit flip).
pub fn fnegD(fd: Reg, dn: Reg) u32 {
    return 0x1E614000 | (r(dn) << 5) | r(fd);
}

/// FSQRT Dd, Dn — double-precision square root.
pub fn fsqrtD(fd: Reg, dn: Reg) u32 {
    return 0x1E61C000 | (r(dn) << 5) | r(fd);
}

/// FRINTP Dd, Dn — round to integral toward +inf (f64.ceil).
pub fn frintpD(fd: Reg, dn: Reg) u32 {
    return 0x1E64C000 | (r(dn) << 5) | r(fd);
}

/// FRINTM Dd, Dn — round to integral toward -inf (f64.floor).
pub fn frintmD(fd: Reg, dn: Reg) u32 {
    return 0x1E654000 | (r(dn) << 5) | r(fd);
}

/// FRINTZ Dd, Dn — round to integral toward zero (f64.trunc).
pub fn frintzD(fd: Reg, dn: Reg) u32 {
    return 0x1E65C000 | (r(dn) << 5) | r(fd);
}

/// FRINTN Dd, Dn — round to nearest integral, ties to even (f64.nearest).
pub fn frintnD(fd: Reg, dn: Reg) u32 {
    return 0x1E644000 | (r(dn) << 5) | r(fd);
}

// Single-precision (f32) — the S-form mirror of the D-form ops above. An
// f32 lives in the low 32 bits of its GP slot register; the bridge uses
// the W↔S moves, and arithmetic/compare operate on s16/s17.

/// FMOV Sd, Wn — move a GP register's low 32 bits into an FP single.
pub fn fmovWtoS(fs: Reg, wn: Reg) u32 {
    return 0x1E270000 | (r(wn) << 5) | r(fs);
}

/// FMOV Wd, Sn — move an FP single's bits into a GP register's low 32.
pub fn fmovStoW(wd: Reg, fs: Reg) u32 {
    return 0x1E260000 | (r(fs) << 5) | r(wd);
}

/// FADD Sd, Sn, Sm — single-precision add.
pub fn faddS(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E202800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FSUB Sd, Sn, Sm — single-precision subtract.
pub fn fsubS(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E203800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FMUL Sd, Sn, Sm — single-precision multiply.
pub fn fmulS(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E200800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FDIV Sd, Sn, Sm — single-precision divide.
pub fn fdivS(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E201800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FMIN Sd, Sn, Sm — single-precision minimum (the S-form of fminD).
pub fn fminS(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E205800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

/// FMAX Sd, Sn, Sm — single-precision maximum (the S-form of fmaxD).
pub fn fmaxS(fd: Reg, fn_: Reg, fm: Reg) u32 {
    return 0x1E204800 | (r(fm) << 16) | (r(fn_) << 5) | r(fd);
}

// Cross-precision float conversions (the FCVT 1-source forms): narrow a
// double to single (f32.demote_f64) or widen a single to double
// (f64.promote_f32). The source's ptype picks the input precision; the
// opcode's low bits pick the output.

/// FCVT Sd, Dn — narrow a double to single (f32.demote_f64).
pub fn fcvtDtoS(fs: Reg, dn: Reg) u32 {
    return 0x1E624000 | (r(dn) << 5) | r(fs);
}

/// FCVT Dd, Sn — widen a single to double (f64.promote_f32).
pub fn fcvtStoD(fd: Reg, sn: Reg) u32 {
    return 0x1E22C000 | (r(sn) << 5) | r(fd);
}

// Integer→float conversions (SCVTF/UCVTF). These read the integer
// straight from a GP register (Rn) and write the FP register (Rd) — no
// input bridge — so the wasm `convert` ops only `fmov` the result back.
// `sf` (the 0x80000000 bit) selects a 64-bit (X) vs 32-bit (W) source;
// `type` (the 0x400000 bit) selects a double (D) vs single (S) result.

/// SCVTF Sd, Wn — signed i32 → f32.
pub fn scvtfSfromW(fd: Reg, wn: Reg) u32 {
    return 0x1E220000 | (r(wn) << 5) | r(fd);
}

/// SCVTF Sd, Xn — signed i64 → f32.
pub fn scvtfSfromX(fd: Reg, xn: Reg) u32 {
    return 0x9E220000 | (r(xn) << 5) | r(fd);
}

/// SCVTF Dd, Wn — signed i32 → f64.
pub fn scvtfDfromW(fd: Reg, wn: Reg) u32 {
    return 0x1E620000 | (r(wn) << 5) | r(fd);
}

/// SCVTF Dd, Xn — signed i64 → f64.
pub fn scvtfDfromX(fd: Reg, xn: Reg) u32 {
    return 0x9E620000 | (r(xn) << 5) | r(fd);
}

/// UCVTF Sd, Wn — unsigned i32 → f32.
pub fn ucvtfSfromW(fd: Reg, wn: Reg) u32 {
    return 0x1E230000 | (r(wn) << 5) | r(fd);
}

/// UCVTF Sd, Xn — unsigned i64 → f32.
pub fn ucvtfSfromX(fd: Reg, xn: Reg) u32 {
    return 0x9E230000 | (r(xn) << 5) | r(fd);
}

/// UCVTF Dd, Wn — unsigned i32 → f64.
pub fn ucvtfDfromW(fd: Reg, wn: Reg) u32 {
    return 0x1E630000 | (r(wn) << 5) | r(fd);
}

/// UCVTF Dd, Xn — unsigned i64 → f64.
pub fn ucvtfDfromX(fd: Reg, xn: Reg) u32 {
    return 0x9E630000 | (r(xn) << 5) | r(fd);
}

// Float→integer truncations (FCVTZS/FCVTZU, round toward zero). These
// read the FP register (Rn) and write a GP register (Rd); on NaN they
// yield 0 and on out-of-range they saturate to the integer min/max —
// exactly the wasm `trunc_sat` semantics. `sf` selects an i64 (X) vs i32
// (W) result; `type` selects a double (D) vs single (S) source.

/// FCVTZS Wd, Sn — f32 → i32, signed, toward zero (saturating).
pub fn fcvtzsWfromS(wd: Reg, sn: Reg) u32 {
    return 0x1E380000 | (r(sn) << 5) | r(wd);
}

/// FCVTZU Wd, Sn — f32 → i32, unsigned, toward zero (saturating).
pub fn fcvtzuWfromS(wd: Reg, sn: Reg) u32 {
    return 0x1E390000 | (r(sn) << 5) | r(wd);
}

/// FCVTZS Wd, Dn — f64 → i32, signed, toward zero (saturating).
pub fn fcvtzsWfromD(wd: Reg, dn: Reg) u32 {
    return 0x1E780000 | (r(dn) << 5) | r(wd);
}

/// FCVTZU Wd, Dn — f64 → i32, unsigned, toward zero (saturating).
pub fn fcvtzuWfromD(wd: Reg, dn: Reg) u32 {
    return 0x1E790000 | (r(dn) << 5) | r(wd);
}

/// FCVTZS Xd, Sn — f32 → i64, signed, toward zero (saturating).
pub fn fcvtzsXfromS(xd: Reg, sn: Reg) u32 {
    return 0x9E380000 | (r(sn) << 5) | r(xd);
}

/// FCVTZU Xd, Sn — f32 → i64, unsigned, toward zero (saturating).
pub fn fcvtzuXfromS(xd: Reg, sn: Reg) u32 {
    return 0x9E390000 | (r(sn) << 5) | r(xd);
}

/// FCVTZS Xd, Dn — f64 → i64, signed, toward zero (saturating).
pub fn fcvtzsXfromD(xd: Reg, dn: Reg) u32 {
    return 0x9E780000 | (r(dn) << 5) | r(xd);
}

/// FCVTZU Xd, Dn — f64 → i64, unsigned, toward zero (saturating).
pub fn fcvtzuXfromD(xd: Reg, dn: Reg) u32 {
    return 0x9E790000 | (r(dn) << 5) | r(xd);
}

/// FCMP Sn, Sm — single-precision compare (same condition mapping as fcmpD).
pub fn fcmpS(sn: Reg, sm: Reg) u32 {
    return 0x1E202000 | (r(sm) << 16) | (r(sn) << 5);
}

// Single-precision one-source ops — the S-form mirror of the f64 unary
// group above (FABS/FNEG sign-bit, FRINTP/M/Z/N rounding, FSQRT).

/// FABS Sd, Sn — single-precision absolute value (sign-bit clear).
pub fn fabsS(fs: Reg, sn: Reg) u32 {
    return 0x1E20C000 | (r(sn) << 5) | r(fs);
}

/// FNEG Sd, Sn — single-precision negate (sign-bit flip).
pub fn fnegS(fs: Reg, sn: Reg) u32 {
    return 0x1E214000 | (r(sn) << 5) | r(fs);
}

/// FSQRT Sd, Sn — single-precision square root.
pub fn fsqrtS(fs: Reg, sn: Reg) u32 {
    return 0x1E21C000 | (r(sn) << 5) | r(fs);
}

/// FRINTP Sd, Sn — round to integral toward +inf (f32.ceil).
pub fn frintpS(fs: Reg, sn: Reg) u32 {
    return 0x1E24C000 | (r(sn) << 5) | r(fs);
}

/// FRINTM Sd, Sn — round to integral toward -inf (f32.floor).
pub fn frintmS(fs: Reg, sn: Reg) u32 {
    return 0x1E254000 | (r(sn) << 5) | r(fs);
}

/// FRINTZ Sd, Sn — round to integral toward zero (f32.trunc).
pub fn frintzS(fs: Reg, sn: Reg) u32 {
    return 0x1E25C000 | (r(sn) << 5) | r(fs);
}

/// FRINTN Sd, Sn — round to nearest integral, ties to even (f32.nearest).
pub fn frintnS(fs: Reg, sn: Reg) u32 {
    return 0x1E244000 | (r(sn) << 5) | r(fs);
}

/// STP Xt, Xt2, [SP, #simm7×8]! — pre-indexed pair push through SP.
pub fn stpPreIdxSp(rt: Reg, rt2: Reg, byte_off: i10) u32 {
    std.debug.assert(@rem(byte_off, 8) == 0);
    const imm7: u32 = @as(u32, @as(u7, @bitCast(@as(i7, @intCast(@divExact(byte_off, 8))))));
    const sp: u32 = 31;
    return 0xA9800000 | (imm7 << 15) | (r(rt2) << 10) | (sp << 5) | r(rt);
}

/// LDP Xt, Xt2, [SP], #simm7×8 — post-indexed pair pop through SP.
pub fn ldpPostIdxSp(rt: Reg, rt2: Reg, byte_off: i10) u32 {
    std.debug.assert(@rem(byte_off, 8) == 0);
    const imm7: u32 = @as(u32, @as(u7, @bitCast(@as(i7, @intCast(@divExact(byte_off, 8))))));
    const sp: u32 = 31;
    return 0xA8C00000 | (imm7 << 15) | (r(rt2) << 10) | (sp << 5) | r(rt);
}

/// STR Xt, [SP, #simm9]! — pre-indexed push through SP. Keep SP
/// 16-byte aligned per AAPCS64 (use multiples of -16).
pub fn strPreIdxSp(rt: Reg, simm9: i9) u32 {
    const sp: u32 = 31;
    return 0xF8000C00 | (@as(u32, @as(u9, @bitCast(simm9))) << 12) | (sp << 5) | r(rt);
}

/// LDR Xt, [SP], #simm9 — post-indexed pop through SP.
pub fn ldrPostIdxSp(rt: Reg, simm9: i9) u32 {
    const sp: u32 = 31;
    return 0xF8400400 | (@as(u32, @as(u9, @bitCast(simm9))) << 12) | (sp << 5) | r(rt);
}

// ---- branches --------------------------------------------------------------

/// B #(off_words*4) — PC-relative, in instruction words.
pub fn b(off_words: i26) u32 {
    return 0x14000000 | (@as(u32, @as(u26, @bitCast(off_words))));
}

/// BL #(off_words*4)
pub fn bl(off_words: i26) u32 {
    return 0x94000000 | (@as(u32, @as(u26, @bitCast(off_words))));
}

/// B.cond #(off_words*4)
pub fn bCond(cond: Cond, off_words: i19) u32 {
    return 0x54000000 | (@as(u32, @as(u19, @bitCast(off_words))) << 5) |
        @intFromEnum(cond);
}

/// CBZ Xt, #(off_words*4)
pub fn cbz(rt: Reg, off_words: i19) u32 {
    return 0xB4000000 | (@as(u32, @as(u19, @bitCast(off_words))) << 5) | r(rt);
}

/// TBZ Xt, #bit, #(off_words*4) — test bit and branch if zero.
pub fn tbz(rt: Reg, bit: u6, off_words: i14) u32 {
    const b5: u32 = @as(u32, bit >> 5) << 31;
    const b40: u32 = @as(u32, bit & 0x1F) << 19;
    return 0x36000000 | b5 | b40 |
        (@as(u32, @as(u14, @bitCast(off_words))) << 5) | r(rt);
}

/// TBNZ Xt, #bit, #(off_words*4)
pub fn tbnz(rt: Reg, bit: u6, off_words: i14) u32 {
    const b5: u32 = @as(u32, bit >> 5) << 31;
    const b40: u32 = @as(u32, bit & 0x1F) << 19;
    return 0x37000000 | b5 | b40 |
        (@as(u32, @as(u14, @bitCast(off_words))) << 5) | r(rt);
}

/// CBNZ Xt, #(off_words*4)
pub fn cbnz(rt: Reg, off_words: i19) u32 {
    return 0xB5000000 | (@as(u32, @as(u19, @bitCast(off_words))) << 5) | r(rt);
}

/// BR Xn
pub fn br(rn: Reg) u32 {
    return 0xD61F0000 | (r(rn) << 5);
}

/// BLR Xn
pub fn blr(rn: Reg) u32 {
    return 0xD63F0000 | (r(rn) << 5);
}

/// RET (x30)
pub fn ret() u32 {
    return 0xD65F03C0;
}

/// NOP
pub fn nop() u32 {
    return 0xD503201F;
}

/// BRK #imm16 — debug trap; handy as a poison filler in tests.
pub fn brk(imm16: u16) u32 {
    return 0xD4200000 | (@as(u32, imm16) << 5);
}

// ---- golden tests ----------------------------------------------------------
// Byte-exact encodings, cross-checked against `llvm-mc -triple
// arm64 -show-encoding` output. These pin the bit layouts; the
// execution tests in masm.zig prove them on hardware.

test "jit asm_aarch64: golden encodings" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(u32, 0xD65F03C0), ret());
    try expectEqual(@as(u32, 0xD503201F), nop());
    try expectEqual(@as(u32, 0xD2800540), movz(.x0, 42, 0)); // movz x0, #42
    try expectEqual(@as(u32, 0xF2B7DDE0), movk(.x0, 0xBEEF, 1)); // movk x0, #0xbeef, lsl #16
    try expectEqual(@as(u32, 0xAA0103E0), movReg(.x0, .x1)); // mov x0, x1
    try expectEqual(@as(u32, 0x8B010000), addReg(.x0, .x0, .x1)); // add x0, x0, x1
    try expectEqual(@as(u32, 0xCB020021), subReg(.x1, .x1, .x2)); // sub x1, x1, x2
    try expectEqual(@as(u32, 0xEB02003F), cmpReg(.x1, .x2)); // cmp x1, x2
    try expectEqual(@as(u32, 0x91000820), addImm(.x0, .x1, 2, false)); // add x0, x1, #2
    try expectEqual(@as(u32, 0xF100043F), cmpImm(.x1, 1, false)); // cmp x1, #1
    try expectEqual(@as(u32, 0x8A020020), andReg(.x0, .x1, .x2)); // and x0, x1, x2
    try expectEqual(@as(u32, 0xD370BC20), lslImm(.x0, .x1, 16)); // lsl x0, x1, #16
    try expectEqual(@as(u32, 0xD350FC20), lsrImm(.x0, .x1, 16)); // lsr x0, x1, #16
    try expectEqual(@as(u32, 0xF9400020), ldrImm(.x0, .x1, 0)); // ldr x0, [x1]
    try expectEqual(@as(u32, 0xF9000020), strImm(.x0, .x1, 0)); // str x0, [x1]
    try expectEqual(@as(u32, 0xF9400C20), ldrImm(.x0, .x1, 24)); // ldr x0, [x1, #24]
    try expectEqual(@as(u32, 0xB9400020), ldrImmW(.x0, .x1, 0)); // ldr w0, [x1]
    try expectEqual(@as(u32, 0xB9400420), ldrImmW(.x0, .x1, 4)); // ldr w0, [x1, #4]
    try expectEqual(@as(u32, 0xF81F0FFE), strPreIdxSp(.lr, -16)); // str x30, [sp, #-16]!
    try expectEqual(@as(u32, 0xF84107FE), ldrPostIdxSp(.lr, 16)); // ldr x30, [sp], #16
    try expectEqual(@as(u32, 0xA9BF7BFD), stpPreIdxSp(.fp, .lr, -16)); // stp x29, x30, [sp, #-16]!
    try expectEqual(@as(u32, 0xA8C17BFD), ldpPostIdxSp(.fp, .lr, 16)); // ldp x29, x30, [sp], #16
    try expectEqual(@as(u32, 0x2B010002), addsRegW(.x2, .x0, .x1)); // adds w2, w0, w1
    try expectEqual(@as(u32, 0x6B02003F), cmpRegW(.x1, .x2)); // cmp w1, w2
    try expectEqual(@as(u32, 0x31000420), addsImmW(.x0, .x1, 1)); // adds w0, w1, #1
    try expectEqual(@as(u32, 0x1A9F17E0), csetW(.x0, .eq)); // cset w0, eq
    try expectEqual(@as(u32, 0x1A9FA7E0), csetW(.x0, .lt)); // cset w0, lt
    try expectEqual(@as(u32, 0x1AC22020), lslvW(.x0, .x1, .x2)); // lslv w0, w1, w2
    try expectEqual(@as(u32, 0x1AC22420), lsrvW(.x0, .x1, .x2)); // lsrv w0, w1, w2
    try expectEqual(@as(u32, 0x1AC22820), asrvW(.x0, .x1, .x2)); // asrv w0, w1, w2
    try expectEqual(@as(u32, 0x1A821020), cselW(.x0, .x1, .x2, .ne)); // csel w0, w1, w2, ne
    try expectEqual(@as(u32, 0x9B227C20), smull(.x0, .x1, .x2)); // smull x0, w1, w2
    try expectEqual(@as(u32, 0x93407C20), sxtw(.x0, .x1)); // sxtw x0, w1
    try expectEqual(@as(u32, 0x2A020020), orrRegW(.x0, .x1, .x2)); // orr w0, w1, w2
    try expectEqual(@as(u32, 0x0A020020), andRegW(.x0, .x1, .x2)); // and w0, w1, w2
    try expectEqual(@as(u32, 0x4A020020), eorRegW(.x0, .x1, .x2)); // eor w0, w1, w2
    try expectEqual(@as(u32, 0x6B020020), subsRegW(.x0, .x1, .x2)); // subs w0, w1, w2
    try expectEqual(@as(u32, 0x2A0103E0), movRegW(.x0, .x1)); // mov w0, w1
    try expectEqual(@as(u32, 0x39400020), ldrbImm(.x0, .x1, 0)); // ldrb w0, [x1]
    try expectEqual(@as(u32, 0x36000040), tbz(.x0, 0, 2)); // tbz x0, #0, .+8
    try expectEqual(@as(u32, 0x37000041), tbnz(.x1, 0, 2)); // tbnz x1, #0, .+8
    try expectEqual(@as(u32, 0x14000001), b(1)); // b .+4
    try expectEqual(@as(u32, 0x17FFFFFF), b(-1)); // b .-4
    try expectEqual(@as(u32, 0x54000040), bCond(.eq, 2)); // b.eq .+8
    try expectEqual(@as(u32, 0x54FFFFEB), bCond(.lt, -1)); // b.lt .-4
    try expectEqual(@as(u32, 0xB4000041), cbz(.x1, 2)); // cbz x1, .+8
    try expectEqual(@as(u32, 0xD63F0200), blr(.x16)); // blr x16
    try expectEqual(@as(u32, 0xD61F0220), br(.x17)); // br x17
    try expectEqual(@as(u32, 0xD43E0000), brk(0xF000)); // brk #0xf000
}
