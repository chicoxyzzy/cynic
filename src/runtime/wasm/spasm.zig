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
/// (x1) is where the compiled body writes its result cells. The
/// optimized native-register boundary (the per-signature §7.1 thunks)
/// is a later increment; correctness first.
pub const EntryFn = *const fn (locals: [*]Cell, results: [*]Cell) callconv(.c) void;

pub const CompileError = error{ OutOfMemory, UnsupportedOp };

// ── wasm opcodes this increment understands ─────────────────────────
const op_end: u8 = 0x0b;
const op_i32_const: u8 = 0x41;

/// An operand-stack location in the abstract state (§6 constant
/// tracking). This increment models only folded constants; registers
/// and spill slots arrive with arithmetic.
const Loc = union(enum) {
    const_i32: i32,
};

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
) CompileError!?EntryFn {
    if (comptime !supported) return null;

    // The abstract operand stack (§6). This increment only ever holds
    // folded constants; a fixed cap keeps the first cut allocation-free
    // and refuses anything deeper.
    var stack: [16]Loc = undefined;
    var sp: usize = 0;

    const body = func.body;
    var i: usize = 0;
    while (i < body.len) {
        const op = body[i];
        i += 1;
        switch (op) {
            op_i32_const => {
                const v = readSleb32(body, &i) orelse return null;
                if (sp >= stack.len) return null;
                stack[sp] = .{ .const_i32 = v };
                sp += 1;
            },
            op_end => {
                // The function-level `end`. Everything past here would
                // be dead code in a validated single-`end` body; stop.
                break;
            },
            else => return null, // not yet emittable — stay interpreted
        }
    }

    // The residual stack must match the result signature exactly: one
    // location per result, each an i32 constant (this increment's only
    // value class). Anything else degrades to the interpreter.
    const results = ftype.results;
    if (sp != results.len) return null;
    for (results) |rt| if (rt != .i32) return null;

    var m = masm_mod.Masm.init(gpa);
    defer m.deinit();

    // Boundary ABI: x0 = locals (unused this increment), x1 = results.
    // Wasm function results map bottom-of-stack → results[0], so the
    // deepest stack location is result 0 and the top is the last.
    for (results, 0..) |_, ri| {
        const loc = stack[ri];
        const cell_off: u15 = @intCast(ri * @sizeOf(Cell));
        // i32 cell: the value zero-extended into the low 64 bits, the
        // high 64 bits cleared.
        const bits: u64 = @as(u32, @bitCast(loc.const_i32));
        try m.movImm64(.x9, bits);
        try m.emit(a64.strImm(.x9, .x1, cell_off));
        try m.movImm64(.x10, 0);
        try m.emit(a64.strImm(.x10, .x1, cell_off + 8));
    }
    try m.emit(a64.ret());

    const installed = m.install(ca) catch return null;
    return code_alloc.asFn(EntryFn, installed);
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

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

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

    const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse
        return error.SpasmRefusedTrivialFunction;

    var results: [1]Cell = .{0};
    var locals: [1]Cell = .{0};
    entry(&locals, &results);
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

    const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse
        return error.SpasmRefusedTrivialFunction;
    var results: [1]Cell = .{0};
    var locals: [1]Cell = .{0};
    entry(&locals, &results);
    try testing.expectEqual(@as(i32, -7), @as(i32, @bitCast(@as(u32, @truncate(results[0])))));
}

test "spasm: an unsupported opcode degrades to null (stay interpreted)" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    // `local.get 0` (0x20) is not in this increment's set — Spasm must
    // refuse the whole function, not abort. The interpreter runs it.
    const body = [_]u8{ 0x20, 0x00, op_end };
    const func: CompiledFunc = .{
        .type_index = 0,
        .local_types = &.{.i32},
        .body = &body,
        .side_table = &.{},
        .max_stack = 1,
    };
    const ftype: FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    try testing.expectEqual(@as(?EntryFn, null), try compile(testing.allocator, &ca, &func, &ftype));
}
