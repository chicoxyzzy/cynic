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
const op_local_get: u8 = 0x20;
const op_i32_const: u8 = 0x41;
const op_local_set: u8 = 0x21;
const op_local_tee: u8 = 0x22;
const op_i32_add: u8 = 0x6a;
const op_i32_sub: u8 = 0x6b;
const op_i32_mul: u8 = 0x6c;
const op_i32_and: u8 = 0x71;
const op_i32_or: u8 = 0x72;
const op_i32_xor: u8 = 0x73;

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
    // The operand-stack bank is fixed (regForDepth); a deeper body
    // tiers down. Leaf arithmetic functions touch only caller-saved
    // scratch, so no prologue/epilogue is needed.
    if (func.max_stack > operand_reg_count) return null;

    var m = masm_mod.Masm.init(gpa);
    defer m.deinit();

    // The abstract operand stack (§6) — Locs are emitted into their
    // depth's register on demand. x0 = locals (param+local cells),
    // x1 = results (the boundary ABI).
    var stack: [operand_reg_count]Loc = undefined;
    var sp: usize = 0;

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
            op_local_get => {
                const idx = readUleb32(body, &i) orelse return null;
                if (sp >= operand_reg_count) return null;
                if (idx >= func.local_types.len) return null;
                if (func.local_types[idx] != .i32) return null; // i32 locals only this increment
                const cell_off = @as(u64, idx) * @sizeOf(Cell);
                if (cell_off > 16380 or cell_off % 4 != 0) return null; // ldrImmW scaled-imm ceiling
                // 32-bit load zero-extends the i32 from the cell's low
                // word into the slot's register.
                try m.emit(a64.ldrImmW(regForDepth(sp), .x0, @intCast(cell_off)));
                stack[sp] = .{ .reg = regForDepth(sp) };
                sp += 1;
            },
            op_local_set, op_local_tee => {
                const idx = readUleb32(body, &i) orelse return null;
                if (sp < 1) return null;
                if (idx >= func.local_types.len) return null;
                if (func.local_types[idx] != .i32) return null;
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
            op_end => break,
            else => return null, // not yet emittable — stay interpreted
        }
    }

    const results = ftype.results;
    if (sp != results.len) return null;
    for (results) |rt| if (rt != .i32) return null;

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
    try m.emit(a64.ret());

    const installed = m.install(ca) catch return null;
    return code_alloc.asFn(EntryFn, installed);
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

test "spasm: i32 add of two params compiles and computes" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();
    // (func (param i32 i32) (result i32) local.get 0; local.get 1; i32.add)
    const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x6a, op_end };
    const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = &.{}, .max_stack = 2 };
    const ftype: FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [2]Cell = .{ 7, 35 };
    var results: [1]Cell = .{0};
    entry(&locals, &results);
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
        const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [2]Cell = .{ 50, 8 };
        var results: [1]Cell = .{0};
        entry(&locals, &results);
        try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(results[0])));
    }
    // mul: 6 * 7 = 42 (and the low-32 truncation is clean)
    {
        const body = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x6c, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{ .i32, .i32 }, .body = &body, .side_table = &.{}, .max_stack = 2 };
        const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [2]Cell = .{ 6, 7 };
        var results: [1]Cell = .{0};
        entry(&locals, &results);
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
    const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{0};
    var results: [1]Cell = .{0};
    entry(&locals, &results);
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
        const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse return error.SpasmRefused;
        var locals: [2]Cell = .{ 0b1110, 0b1011 };
        var results: [1]Cell = .{0};
        entry(&locals, &results);
        try testing.expectEqual(@as(u32, 0b1010), @as(u32, @truncate(results[0])));
    }
    // or | xor folded: (5 | 2) ^ 3 = 7 ^ 3 = 4, all constant
    {
        const body = [_]u8{ op_i32_const, 5, op_i32_const, 2, 0x72, op_i32_const, 3, 0x73, op_end };
        const func: CompiledFunc = .{ .type_index = 0, .local_types = &.{}, .body = &body, .side_table = &.{}, .max_stack = 2 };
        const fty: FuncType = .{ .params = &.{}, .results = &.{.i32} };
        const entry = (try compile(testing.allocator, &ca, &func, &fty)) orelse return error.SpasmRefused;
        var locals: [1]Cell = .{0};
        var results: [1]Cell = .{0};
        entry(&locals, &results);
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
    const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{99}; // overwritten by local.set
    var results: [1]Cell = .{0};
    entry(&locals, &results);
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
    const entry = (try compile(testing.allocator, &ca, &func, &ftype)) orelse return error.SpasmRefused;
    var locals: [1]Cell = .{99};
    var results: [1]Cell = .{0};
    entry(&locals, &results);
    try testing.expectEqual(@as(u32, 14), @as(u32, @truncate(results[0])));
}

test "spasm: an unsupported opcode degrades to null (stay interpreted)" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer ca.deinit();

    // `i32.eqz` (0x45) is not in this increment's set — Spasm must
    // refuse the whole function, not abort. The interpreter runs it.
    const body = [_]u8{ op_i32_const, 1, 0x45, op_end };
    const func: CompiledFunc = .{
        .type_index = 0,
        .local_types = &.{},
        .body = &body,
        .side_table = &.{},
        .max_stack = 1,
    };
    const ftype: FuncType = .{ .params = &.{}, .results = &.{.i32} };
    try testing.expectEqual(@as(?EntryFn, null), try compile(testing.allocator, &ca, &func, &ftype));
}
