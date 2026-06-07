//! Sarcasm's in-place interpreter (the execution tier).
//!
//! Runs the original wasm bytecode directly — no rewrite — driving an
//! unboxed value stack and an explicit frame stack, with branches
//! resolved in O(1) through the validator-emitted side-table (see
//! code.zig and docs/wasm-engine.md). Operand cells are raw 64-bit
//! words read at the width validation proved; reference/v128 widening
//! and lazy GC tags arrive with later steps.
//!
//! Dispatch is a `while`/`switch` loop here for a correctness-first
//! first cut; converting it to the threaded `continue :dispatch` form
//! Lantern uses is the documented next optimization and is mechanical
//! once the conformance tests guard it.

const std = @import("std");
const types = @import("types.zig");
const module_mod = @import("module.zig");
const code_mod = @import("code.zig");
const opcodes = @import("opcodes.zig");
const validator = @import("validator.zig");
const reader_mod = @import("reader.zig");

const ValType = types.ValType;
const Module = module_mod.Module;
const CompiledFunc = code_mod.CompiledFunc;
const Op = opcodes.Op;

pub const TrapError = error{
    Unreachable,
    IntegerDivideByZero,
    IntegerOverflow,
    InvalidConversionToInteger,
    OutOfBoundsMemoryAccess,
    CallStackExhausted,
    ValueStackOverflow,
    UnsupportedImportCall,
};

pub const Error = TrapError || validator.ValidateError || error{ NoSuchExport, OutOfMemory };

const STACK_CELLS = 1 << 16;
const MAX_FRAMES = 1 << 12;

/// WebAssembly linear-memory page size (§2.5.2): 64 KiB.
pub const PAGE_SIZE = 1 << 16;

/// A runtime global cell. 128-bit to hold a `v128` (scalars use the
/// low bits).
const Global = struct {
    value: u128,
    mutable: bool,
};

/// Linear memory: a byte-addressable, page-granular buffer. (The
/// ArrayBuffer aliasing the JS API exposes arrives with that step;
/// here it is a plain owned buffer.)
pub const Memory = struct {
    data: []u8,
    max_pages: ?u32,

    fn pages(self: *const Memory) u32 {
        return @intCast(self.data.len / PAGE_SIZE);
    }
};

/// An instantiated module: its validated functions plus runtime state.
/// Linear memory and tables join in later steps; the integer+control
/// subset needs only globals and the function bodies.
pub const Instance = struct {
    module: *const Module,
    funcs: []const CompiledFunc,
    globals: []Global,
    /// Number of imported functions preceding the defined ones in the
    /// function index space.
    func_import_count: u32,
    /// The module's single linear memory (multi-memory is post-1.0).
    memory: ?Memory,
    /// Owns `globals` and `memory.data`; used to grow and free them.
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Instance) void {
        self.gpa.free(self.globals);
        if (self.memory) |m| self.gpa.free(m.data);
    }

    /// Read a global's raw cell by its index in the global index space
    /// (used by the conformance harness's `get` action). Returns null
    /// for an imported global, which is not yet wired.
    pub fn readGlobalByIndex(self: *const Instance, global_index: u32) ?u128 {
        var imported: u32 = 0;
        for (self.module.imports) |imp| {
            if (imp.desc == .global) imported += 1;
        }
        if (global_index < imported) return null;
        return self.globals[global_index - imported].value;
    }

    /// Resolve a function-index-space entry to a defined function, or
    /// null if it names an import (host calls land in a later step).
    fn definedFunc(self: *const Instance, func_index: u32) ?*const CompiledFunc {
        if (func_index < self.func_import_count) return null;
        const local = func_index - self.func_import_count;
        return &self.funcs[local];
    }
};

/// Validate every function and lay out runtime state. `arena` owns the
/// validated `CompiledFunc`s for the instance's lifetime; `allocator`
/// owns the mutable globals.
pub fn instantiate(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    module: *const Module,
) Error!Instance {
    const funcs = try validator.validateModule(arena, module);

    var func_imports: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .func) func_imports += 1;
    }

    const globals = try allocator.alloc(Global, module.globals.len);
    errdefer allocator.free(globals);
    for (module.globals, 0..) |g, i| {
        globals[i] = .{ .value = evalConstExpr(g.init_expr), .mutable = g.type.mut == .mutable };
    }

    // Create the single defined linear memory (if any), zero-filled to
    // its minimum size. Imported memories are not yet wired.
    var memory: ?Memory = null;
    if (module.mems.len > 0) {
        const lim = module.mems[0].limits;
        const bytes = try allocator.alloc(u8, @as(usize, lim.min) * PAGE_SIZE);
        @memset(bytes, 0);
        memory = .{ .data = bytes, .max_pages = lim.max };
    }

    return .{
        .module = module,
        .funcs = funcs,
        .globals = globals,
        .func_import_count = func_imports,
        .memory = memory,
        .gpa = allocator,
    };
}

/// Evaluate a global's constant initializer (§3.3.7) for the subset
/// that needs no other globals: `i32.const` / `i64.const`. The bytes
/// are validated; an unrecognized form yields 0 for now.
fn evalConstExpr(expr: []const u8) u64 {
    var r = reader_mod.Reader.init(expr);
    const op: Op = @enumFromInt(r.byte() catch return 0);
    return switch (op) {
        .i32_const => @as(u64, @as(u32, @bitCast(r.sleb(i32) catch 0))),
        .i64_const => @bitCast(r.sleb(i64) catch 0),
        else => 0,
    };
}

const Frame = struct {
    func: *const CompiledFunc,
    ip: usize,
    stp: usize,
    locals_base: usize,
    result_count: u32,
};

/// The operand/local stack cell. 128 bits so a single cell holds any
/// value type including `v128`; scalars occupy the low bits. Keeping
/// one value == one cell preserves the validator's value-count
/// bookkeeping (and the side-table's pop/keep counts) unchanged.
const Cell = u128;

const Interp = struct {
    instance: *Instance,
    stack: []Cell,
    sp: usize,
    frames: []Frame,
    nframes: usize,

    inline fn pushCell(self: *Interp, v: Cell) TrapError!void {
        if (self.sp >= self.stack.len) return error.ValueStackOverflow;
        self.stack[self.sp] = v;
        self.sp += 1;
    }
    inline fn popCell(self: *Interp) Cell {
        self.sp -= 1;
        return self.stack[self.sp];
    }
    inline fn pushI32(self: *Interp, v: i32) TrapError!void {
        try self.pushCell(@as(u32, @bitCast(v)));
    }
    inline fn popI32(self: *Interp) i32 {
        return @bitCast(@as(u32, @truncate(self.popCell())));
    }
    inline fn pushI64(self: *Interp, v: i64) TrapError!void {
        try self.pushCell(@as(u64, @bitCast(v)));
    }
    inline fn popI64(self: *Interp) i64 {
        return @bitCast(@as(u64, @truncate(self.popCell())));
    }
    inline fn pushF32(self: *Interp, v: f32) TrapError!void {
        try self.pushCell(@as(u32, @bitCast(v)));
    }
    inline fn popF32(self: *Interp) f32 {
        return @bitCast(@as(u32, @truncate(self.popCell())));
    }
    inline fn pushF64(self: *Interp, v: f64) TrapError!void {
        try self.pushCell(@as(u64, @bitCast(v)));
    }
    inline fn popF64(self: *Interp) f64 {
        return @bitCast(@as(u64, @truncate(self.popCell())));
    }
    inline fn pushV128(self: *Interp, v: u128) TrapError!void {
        try self.pushCell(v);
    }
    inline fn popV128(self: *Interp) u128 {
        return self.popCell();
    }

    /// Push a frame for a wasm call. The top `param_count` operands are
    /// already the callee's first locals (zero-copy); remaining locals
    /// are zero-initialized.
    fn pushFrame(self: *Interp, func: *const CompiledFunc, param_count: u32) TrapError!void {
        if (self.nframes >= self.frames.len) return error.CallStackExhausted;
        const locals_base = self.sp - param_count;
        // Zero-init declared (non-parameter) locals.
        const total_locals: u32 = @intCast(func.local_types.len);
        var i = param_count;
        while (i < total_locals) : (i += 1) try self.pushCell(0);
        // Reserve operand headroom check.
        if (locals_base + total_locals + func.max_stack > self.stack.len)
            return error.ValueStackOverflow;
        const rc: u32 = @intCast(self.instance.module.types[func.type_index].results.len);
        self.frames[self.nframes] = .{
            .func = func,
            .ip = 0,
            .stp = 0,
            .locals_base = locals_base,
            .result_count = rc,
        };
        self.nframes += 1;
    }

    /// Collapse the top frame: move its results down over the frame and
    /// pop it. Returns true when the call stack is now empty.
    fn popFrame(self: *Interp) bool {
        const f = self.frames[self.nframes - 1];
        const nres = f.result_count;
        var i: u32 = 0;
        while (i < nres) : (i += 1) {
            self.stack[f.locals_base + i] = self.stack[self.sp - nres + i];
        }
        self.sp = f.locals_base + nres;
        self.nframes -= 1;
        return self.nframes == 0;
    }
};

/// Invoke `func_index` (function-index space) with `args` already
/// encoded as raw 128-bit cells (scalars in the low bits). Returns the
/// result cells, allocated from `allocator`.
pub fn invoke(
    self: *Instance,
    allocator: std.mem.Allocator,
    func_index: u32,
    args: []const u128,
) Error![]u128 {
    const entry = self.definedFunc(func_index) orelse return error.UnsupportedImportCall;

    const stack = try allocator.alloc(Cell, STACK_CELLS);
    defer allocator.free(stack);
    const frames = try allocator.alloc(Frame, MAX_FRAMES);
    defer allocator.free(frames);

    var ip: Interp = .{ .instance = self, .stack = stack, .sp = 0, .frames = frames, .nframes = 0 };

    // Seed the entry function's parameters as its first locals.
    const param_count: u32 = @intCast(self.module.types[entry.type_index].params.len);
    if (args.len != param_count) return error.UnsupportedImportCall;
    for (args) |a| try ip.pushCell(a);
    try ip.pushFrame(entry, param_count);

    try run(&ip);

    // Results sit at the bottom of the stack after the final pop, one
    // 128-bit cell each (scalars in the low bits).
    const nres = ip.sp;
    const out = try allocator.alloc(u128, nres);
    @memcpy(out, ip.stack[0..nres]);
    return out;
}

fn run(ip: *Interp) Error!void {
    var f: *Frame = &ip.frames[ip.nframes - 1];
    // Outer loop reloads frame-local cache after a call / return.
    while (true) {
        const func = f.func;
        const body = func.body;
        const side_table = func.side_table;
        const locals_base = f.locals_base;
        var pc = f.ip;
        var stp = f.stp;

        const frame_changed = inner: while (true) {
            if (pc >= body.len) {
                // Implicit function `end` → return.
                f.ip = pc;
                f.stp = stp;
                if (ip.popFrame()) return;
                f = &ip.frames[ip.nframes - 1];
                break :inner true;
            }
            const op_ip = pc;
            const op: Op = @enumFromInt(body[pc]);
            pc += 1;
            switch (op) {
                .nop, .end => {},
                .@"unreachable" => return error.Unreachable,

                .block, .loop => pc = skipBlockType(body, pc),
                .@"if" => {
                    pc = skipBlockType(body, pc);
                    const cond = ip.popI32();
                    if (cond != 0) {
                        stp += 1; // enter the then-arm
                    } else {
                        const e = side_table[stp];
                        moveValues(ip, e);
                        pc = @intCast(@as(i64, @intCast(op_ip)) + e.delta_ip);
                        stp = @intCast(@as(i64, @intCast(stp)) + e.delta_stp);
                    }
                },
                .@"else" => {
                    const e = side_table[stp];
                    moveValues(ip, e);
                    pc = @intCast(@as(i64, @intCast(op_ip)) + e.delta_ip);
                    stp = @intCast(@as(i64, @intCast(stp)) + e.delta_stp);
                },
                .br => {
                    const e = side_table[stp];
                    moveValues(ip, e);
                    pc = @intCast(@as(i64, @intCast(op_ip)) + e.delta_ip);
                    stp = @intCast(@as(i64, @intCast(stp)) + e.delta_stp);
                },
                .br_if => {
                    _ = readU32(body, &pc); // label immediate (unused at runtime)
                    const cond = ip.popI32();
                    if (cond != 0) {
                        const e = side_table[stp];
                        moveValues(ip, e);
                        pc = @intCast(@as(i64, @intCast(op_ip)) + e.delta_ip);
                        stp = @intCast(@as(i64, @intCast(stp)) + e.delta_stp);
                    } else {
                        stp += 1;
                    }
                },
                .@"return" => {
                    f.ip = pc;
                    f.stp = stp;
                    if (ip.popFrame()) return;
                    f = &ip.frames[ip.nframes - 1];
                    break :inner true;
                },
                .call => {
                    const fidx = readU32(body, &pc);
                    const callee = ip.instance.definedFunc(fidx) orelse return error.UnsupportedImportCall;
                    const pcount: u32 = @intCast(ip.instance.module.types[callee.type_index].params.len);
                    f.ip = pc;
                    f.stp = stp;
                    try ip.pushFrame(callee, pcount);
                    f = &ip.frames[ip.nframes - 1];
                    break :inner true;
                },

                .drop => _ = ip.popCell(),
                .select => {
                    const c = ip.popI32();
                    const b = ip.popCell();
                    const a = ip.popCell();
                    try ip.pushCell(if (c != 0) a else b);
                },

                .local_get => {
                    const x = readU32(body, &pc);
                    try ip.pushCell(ip.stack[locals_base + x]);
                },
                .local_set => {
                    const x = readU32(body, &pc);
                    ip.stack[locals_base + x] = ip.popCell();
                },
                .local_tee => {
                    const x = readU32(body, &pc);
                    ip.stack[locals_base + x] = ip.stack[ip.sp - 1];
                },
                .global_get => {
                    const x = readU32(body, &pc);
                    try ip.pushCell(ip.instance.globals[x].value);
                },
                .global_set => {
                    const x = readU32(body, &pc);
                    ip.instance.globals[x].value = ip.popCell();
                },

                .i32_const => try ip.pushI32(readI32(body, &pc)),
                .i64_const => try ip.pushI64(readI64(body, &pc)),

                .i32_eqz => try ip.pushI32(@intFromBool(ip.popI32() == 0)),
                .i64_eqz => try ip.pushI32(@intFromBool(ip.popI64() == 0)),

                .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => {
                    const b = ip.popI32();
                    const a = ip.popI32();
                    try ip.pushI32(@intFromBool(compareI32(op, a, b)));
                },
                .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => {
                    const b = ip.popI64();
                    const a = ip.popI64();
                    try ip.pushI32(@intFromBool(compareI64(op, a, b)));
                },

                .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => {
                    const b = ip.popI32();
                    const a = ip.popI32();
                    try ip.pushI32(try arithI32(op, a, b));
                },
                .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => {
                    const b = ip.popI64();
                    const a = ip.popI64();
                    try ip.pushI64(try arithI64(op, a, b));
                },

                // ── integer unary + sign extension ──────────────────
                .i32_clz => try ip.pushI32(@intCast(@clz(@as(u32, @bitCast(ip.popI32()))))),
                .i32_ctz => try ip.pushI32(@intCast(@ctz(@as(u32, @bitCast(ip.popI32()))))),
                .i32_popcnt => try ip.pushI32(@intCast(@popCount(@as(u32, @bitCast(ip.popI32()))))),
                .i64_clz => try ip.pushI64(@intCast(@clz(@as(u64, @bitCast(ip.popI64()))))),
                .i64_ctz => try ip.pushI64(@intCast(@ctz(@as(u64, @bitCast(ip.popI64()))))),
                .i64_popcnt => try ip.pushI64(@intCast(@popCount(@as(u64, @bitCast(ip.popI64()))))),
                .i32_extend8_s => try ip.pushI32(@as(i8, @truncate(ip.popI32()))),
                .i32_extend16_s => try ip.pushI32(@as(i16, @truncate(ip.popI32()))),
                .i64_extend8_s => try ip.pushI64(@as(i8, @truncate(ip.popI64()))),
                .i64_extend16_s => try ip.pushI64(@as(i16, @truncate(ip.popI64()))),
                .i64_extend32_s => try ip.pushI64(@as(i32, @truncate(ip.popI64()))),

                // ── floating point ──────────────────────────────────
                .f32_const => try ip.pushF32(readF32(body, &pc)),
                .f64_const => try ip.pushF64(readF64(body, &pc)),

                .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => try ip.pushF32(floatUnop(f32, op, ip.popF32())),
                .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => try ip.pushF64(floatUnop(f64, op, ip.popF64())),
                .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => {
                    const b = ip.popF32();
                    const a = ip.popF32();
                    try ip.pushF32(floatBinop(f32, op, a, b));
                },
                .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => {
                    const b = ip.popF64();
                    const a = ip.popF64();
                    try ip.pushF64(floatBinop(f64, op, a, b));
                },
                .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => {
                    const b = ip.popF32();
                    const a = ip.popF32();
                    try ip.pushI32(@intFromBool(floatCmp(f32, op, a, b)));
                },
                .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => {
                    const b = ip.popF64();
                    const a = ip.popF64();
                    try ip.pushI32(@intFromBool(floatCmp(f64, op, a, b)));
                },

                // ── conversions ─────────────────────────────────────
                .i32_wrap_i64 => try ip.pushI32(@truncate(ip.popI64())),
                .i64_extend_i32_s => try ip.pushI64(ip.popI32()),
                .i64_extend_i32_u => try ip.pushI64(@bitCast(@as(u64, @as(u32, @bitCast(ip.popI32()))))),

                .i32_trunc_f32_s => try ip.pushI32(try truncTrap(i32, f32, ip.popF32(), -2147483648.0, true, 2147483648.0)),
                .i32_trunc_f32_u => try ip.pushI32(@bitCast(try truncTrap(u32, f32, ip.popF32(), -1.0, false, 4294967296.0))),
                .i32_trunc_f64_s => try ip.pushI32(try truncTrap(i32, f64, ip.popF64(), -2147483649.0, false, 2147483648.0)),
                .i32_trunc_f64_u => try ip.pushI32(@bitCast(try truncTrap(u32, f64, ip.popF64(), -1.0, false, 4294967296.0))),
                .i64_trunc_f32_s => try ip.pushI64(try truncTrap(i64, f32, ip.popF32(), -9223372036854775808.0, true, 9223372036854775808.0)),
                .i64_trunc_f32_u => try ip.pushI64(@bitCast(try truncTrap(u64, f32, ip.popF32(), -1.0, false, 18446744073709551616.0))),
                .i64_trunc_f64_s => try ip.pushI64(try truncTrap(i64, f64, ip.popF64(), -9223372036854775808.0, true, 9223372036854775808.0)),
                .i64_trunc_f64_u => try ip.pushI64(@bitCast(try truncTrap(u64, f64, ip.popF64(), -1.0, false, 18446744073709551616.0))),

                .f32_convert_i32_s => try ip.pushF32(@floatFromInt(ip.popI32())),
                .f32_convert_i32_u => try ip.pushF32(@floatFromInt(@as(u32, @bitCast(ip.popI32())))),
                .f32_convert_i64_s => try ip.pushF32(@floatFromInt(ip.popI64())),
                .f32_convert_i64_u => try ip.pushF32(@floatFromInt(@as(u64, @bitCast(ip.popI64())))),
                .f64_convert_i32_s => try ip.pushF64(@floatFromInt(ip.popI32())),
                .f64_convert_i32_u => try ip.pushF64(@floatFromInt(@as(u32, @bitCast(ip.popI32())))),
                .f64_convert_i64_s => try ip.pushF64(@floatFromInt(ip.popI64())),
                .f64_convert_i64_u => try ip.pushF64(@floatFromInt(@as(u64, @bitCast(ip.popI64())))),
                .f32_demote_f64 => try ip.pushF32(@floatCast(ip.popF64())),
                .f64_promote_f32 => try ip.pushF64(@floatCast(ip.popF32())),

                // Reinterpret is a bit-identity on the untyped cell.
                .i32_reinterpret_f32, .i64_reinterpret_f64, .f32_reinterpret_i32, .f64_reinterpret_i64 => {},

                // ── linear memory ───────────────────────────────────
                .i32_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u, .i64_load, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u, .f32_load, .f64_load => {
                    const ea = memEa(ip, body, &pc);
                    try execLoad(ip, op, ea);
                },
                .i32_store, .i32_store8, .i32_store16, .i64_store, .i64_store8, .i64_store16, .i64_store32, .f32_store, .f64_store => {
                    try execStore(ip, op, body, &pc);
                },
                .memory_size => {
                    pc += 1; // reserved memory index
                    const mem = ip.instance.memory.?;
                    try ip.pushI32(@bitCast(mem.pages()));
                },
                .memory_grow => {
                    pc += 1; // reserved memory index
                    try ip.pushI32(try memGrow(ip));
                },
                .prefix_fc => {
                    const sub = readU32(body, &pc);
                    switch (sub) {
                        10 => { // memory.copy
                            pc += 2; // dst, src reserved memidx
                            try memCopy(ip);
                        },
                        11 => { // memory.fill
                            pc += 1; // reserved memidx
                            try memFill(ip);
                        },
                        // Saturating float→int truncations.
                        0 => try ip.pushI32(truncSat(i32, f32, ip.popF32())),
                        1 => try ip.pushI32(@bitCast(truncSat(u32, f32, ip.popF32()))),
                        2 => try ip.pushI32(truncSat(i32, f64, ip.popF64())),
                        3 => try ip.pushI32(@bitCast(truncSat(u32, f64, ip.popF64()))),
                        4 => try ip.pushI64(truncSat(i64, f32, ip.popF32())),
                        5 => try ip.pushI64(@bitCast(truncSat(u64, f32, ip.popF32()))),
                        6 => try ip.pushI64(truncSat(i64, f64, ip.popF64())),
                        7 => try ip.pushI64(@bitCast(truncSat(u64, f64, ip.popF64()))),
                        else => return error.UnsupportedImportCall,
                    }
                },
                .prefix_fd => {
                    const sub = readU32(body, &pc);
                    try execSimd(ip, sub, body, &pc);
                },

                else => return error.UnsupportedImportCall, // unreachable: validation rejects
            }
        };
        _ = frame_changed;
    }
}

/// Shuffle the operand stack for a taken branch: keep the top
/// `val_count`, discard `pop_count` beneath them.
inline fn moveValues(ip: *Interp, e: code_mod.BranchEntry) void {
    if (e.pop_count == 0) return;
    const keep = e.val_count;
    const drop = e.pop_count;
    var i: u32 = 0;
    while (i < keep) : (i += 1) {
        ip.stack[ip.sp - keep - drop + i] = ip.stack[ip.sp - keep + i];
    }
    ip.sp -= drop;
}

// ── linear memory ───────────────────────────────────────────────────

/// Read a memarg (align, offset) and pop the i32 base address, giving
/// the effective byte address (§4.4.7).
inline fn memEa(ip: *Interp, body: []const u8, pc: *usize) u64 {
    _ = readU32(body, pc); // align hint (ignored)
    const offset = readU32(body, pc);
    const addr: u32 = @bitCast(ip.popI32());
    return @as(u64, addr) + offset;
}

inline fn checkBounds(len: usize, ea: u64, n: u64) TrapError!void {
    if (ea + n > len) return error.OutOfBoundsMemoryAccess;
}

fn execLoad(ip: *Interp, op: Op, ea: u64) TrapError!void {
    const data = ip.instance.memory.?.data;
    const e: usize = @intCast(ea);
    switch (op) {
        .i32_load => {
            try checkBounds(data.len, ea, 4);
            try ip.pushI32(@bitCast(std.mem.readInt(u32, data[e..][0..4], .little)));
        },
        .i32_load8_s => {
            try checkBounds(data.len, ea, 1);
            try ip.pushI32(@as(i8, @bitCast(data[e])));
        },
        .i32_load8_u => {
            try checkBounds(data.len, ea, 1);
            try ip.pushI32(@intCast(data[e]));
        },
        .i32_load16_s => {
            try checkBounds(data.len, ea, 2);
            try ip.pushI32(@as(i16, @bitCast(std.mem.readInt(u16, data[e..][0..2], .little))));
        },
        .i32_load16_u => {
            try checkBounds(data.len, ea, 2);
            try ip.pushI32(@intCast(std.mem.readInt(u16, data[e..][0..2], .little)));
        },
        .i64_load => {
            try checkBounds(data.len, ea, 8);
            try ip.pushI64(@bitCast(std.mem.readInt(u64, data[e..][0..8], .little)));
        },
        .i64_load8_s => {
            try checkBounds(data.len, ea, 1);
            try ip.pushI64(@as(i8, @bitCast(data[e])));
        },
        .i64_load8_u => {
            try checkBounds(data.len, ea, 1);
            try ip.pushI64(@intCast(data[e]));
        },
        .i64_load16_s => {
            try checkBounds(data.len, ea, 2);
            try ip.pushI64(@as(i16, @bitCast(std.mem.readInt(u16, data[e..][0..2], .little))));
        },
        .i64_load16_u => {
            try checkBounds(data.len, ea, 2);
            try ip.pushI64(@intCast(std.mem.readInt(u16, data[e..][0..2], .little)));
        },
        .i64_load32_s => {
            try checkBounds(data.len, ea, 4);
            try ip.pushI64(@as(i32, @bitCast(std.mem.readInt(u32, data[e..][0..4], .little))));
        },
        .i64_load32_u => {
            try checkBounds(data.len, ea, 4);
            try ip.pushI64(@intCast(std.mem.readInt(u32, data[e..][0..4], .little)));
        },
        .f32_load => {
            try checkBounds(data.len, ea, 4);
            try ip.pushCell(std.mem.readInt(u32, data[e..][0..4], .little));
        },
        .f64_load => {
            try checkBounds(data.len, ea, 8);
            try ip.pushCell(std.mem.readInt(u64, data[e..][0..8], .little));
        },
        else => unreachable,
    }
}

fn execStore(ip: *Interp, op: Op, body: []const u8, pc: *usize) TrapError!void {
    switch (op) {
        .i32_store, .i32_store8, .i32_store16 => {
            const v: u32 = @bitCast(ip.popI32());
            const ea = memEa(ip, body, pc);
            const data = ip.instance.memory.?.data;
            const e: usize = @intCast(ea);
            switch (op) {
                .i32_store => {
                    try checkBounds(data.len, ea, 4);
                    std.mem.writeInt(u32, data[e..][0..4], v, .little);
                },
                .i32_store8 => {
                    try checkBounds(data.len, ea, 1);
                    data[e] = @truncate(v);
                },
                .i32_store16 => {
                    try checkBounds(data.len, ea, 2);
                    std.mem.writeInt(u16, data[e..][0..2], @truncate(v), .little);
                },
                else => unreachable,
            }
        },
        .i64_store, .i64_store8, .i64_store16, .i64_store32 => {
            const v: u64 = @bitCast(ip.popI64());
            const ea = memEa(ip, body, pc);
            const data = ip.instance.memory.?.data;
            const e: usize = @intCast(ea);
            switch (op) {
                .i64_store => {
                    try checkBounds(data.len, ea, 8);
                    std.mem.writeInt(u64, data[e..][0..8], v, .little);
                },
                .i64_store8 => {
                    try checkBounds(data.len, ea, 1);
                    data[e] = @truncate(v);
                },
                .i64_store16 => {
                    try checkBounds(data.len, ea, 2);
                    std.mem.writeInt(u16, data[e..][0..2], @truncate(v), .little);
                },
                .i64_store32 => {
                    try checkBounds(data.len, ea, 4);
                    std.mem.writeInt(u32, data[e..][0..4], @truncate(v), .little);
                },
                else => unreachable,
            }
        },
        .f32_store => {
            const v: u32 = @truncate(ip.popCell());
            const ea = memEa(ip, body, pc);
            const data = ip.instance.memory.?.data;
            try checkBounds(data.len, ea, 4);
            std.mem.writeInt(u32, data[@intCast(ea)..][0..4], v, .little);
        },
        .f64_store => {
            const v: u64 = @truncate(ip.popCell());
            const ea = memEa(ip, body, pc);
            const data = ip.instance.memory.?.data;
            try checkBounds(data.len, ea, 8);
            std.mem.writeInt(u64, data[@intCast(ea)..][0..8], v, .little);
        },
        else => unreachable,
    }
}

/// memory.grow: returns the previous page count, or -1 if the request
/// exceeds the maximum or allocation fails (§4.4.7).
fn memGrow(ip: *Interp) TrapError!i32 {
    const delta: u32 = @bitCast(ip.popI32());
    const mem = &ip.instance.memory.?;
    const old_pages = mem.pages();
    const new_pages: u64 = @as(u64, old_pages) + delta;
    if (new_pages > 65536) return -1; // memory32 hard cap (4 GiB)
    if (mem.max_pages) |mx| {
        if (new_pages > mx) return -1;
    }
    const old_len = mem.data.len;
    const new_len: usize = @as(usize, @intCast(new_pages)) * PAGE_SIZE;
    const grown = ip.instance.gpa.realloc(mem.data, new_len) catch return -1;
    @memset(grown[old_len..], 0);
    mem.data = grown;
    return @bitCast(old_pages);
}

fn memCopy(ip: *Interp) TrapError!void {
    const n: u32 = @bitCast(ip.popI32());
    const src: u32 = @bitCast(ip.popI32());
    const dst: u32 = @bitCast(ip.popI32());
    const data = ip.instance.memory.?.data;
    try checkBounds(data.len, src, n);
    try checkBounds(data.len, dst, n);
    if (n == 0) return;
    // memmove semantics for overlapping ranges.
    if (dst <= src) {
        var i: usize = 0;
        while (i < n) : (i += 1) data[dst + i] = data[src + i];
    } else {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            data[dst + i] = data[src + i];
        }
    }
}

fn memFill(ip: *Interp) TrapError!void {
    const n: u32 = @bitCast(ip.popI32());
    const val: u32 = @bitCast(ip.popI32());
    const dst: u32 = @bitCast(ip.popI32());
    const data = ip.instance.memory.?.data;
    try checkBounds(data.len, dst, n);
    if (n == 0) return;
    @memset(data[dst..][0..n], @truncate(val));
}

// ── immediate readers (advance `pc`) ────────────────────────────────

fn skipBlockType(body: []const u8, pc: usize) usize {
    const b = body[pc];
    if (b == 0x40 or ValType.fromByte(b) != null) return pc + 1;
    // s33 type index — skip the LEB.
    var p = pc;
    while (body[p] & 0x80 != 0) p += 1;
    return p + 1;
}

fn readU32(body: []const u8, pc: *usize) u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        const b = body[pc.*];
        pc.* += 1;
        result |= @as(u32, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

fn readI32(body: []const u8, pc: *usize) i32 {
    var result: i32 = 0;
    var shift: u5 = 0;
    var b: u8 = 0;
    while (true) {
        b = body[pc.*];
        pc.* += 1;
        result |= @as(i32, @as(i32, b & 0x7f) << shift);
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    if (shift < 31 and (b & 0x40) != 0) result |= @as(i32, -1) << (shift + 7);
    return result;
}

fn readI64(body: []const u8, pc: *usize) i64 {
    var result: i64 = 0;
    var shift: u7 = 0;
    var b: u8 = 0;
    while (true) {
        b = body[pc.*];
        pc.* += 1;
        result |= @as(i64, @as(i64, b & 0x7f) << @as(u6, @intCast(shift)));
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    if (shift < 63 and (b & 0x40) != 0) result |= @as(i64, -1) << @as(u6, @intCast(shift + 7));
    return result;
}

fn readF32(body: []const u8, pc: *usize) f32 {
    const bits = std.mem.readInt(u32, body[pc.*..][0..4], .little);
    pc.* += 4;
    return @bitCast(bits);
}

fn readF64(body: []const u8, pc: *usize) f64 {
    const bits = std.mem.readInt(u64, body[pc.*..][0..8], .little);
    pc.* += 8;
    return @bitCast(bits);
}

// ── floating point ──────────────────────────────────────────────────

/// Round to nearest, ties to even (§4.3.3) — distinct from Zig's
/// `@round`, which rounds ties away from zero.
fn roundEven(comptime T: type, x: T) T {
    const r = @round(x);
    var result = r;
    if (@abs(x - @trunc(x)) == 0.5 and @rem(r, 2) != 0) {
        result = r - std.math.sign(r);
    }
    // Preserve the sign of a zero result (e.g. nearest(-0.4) = -0.0).
    if (result == 0) return std.math.copysign(@as(T, 0), x);
    return result;
}

/// wasm min: NaN-propagating, with min(-0, +0) = -0 (§4.3.3).
fn fmin(comptime T: type, a: T, b: T) T {
    if (a != a) return a;
    if (b != b) return b;
    if (a == 0 and b == 0) return if (std.math.signbit(a) or std.math.signbit(b)) -@as(T, 0) else @as(T, 0);
    return if (a < b) a else b;
}

/// wasm max: NaN-propagating, with max(-0, +0) = +0 (§4.3.3).
fn fmax(comptime T: type, a: T, b: T) T {
    if (a != a) return a;
    if (b != b) return b;
    if (a == 0 and b == 0) return if (std.math.signbit(a) and std.math.signbit(b)) -@as(T, 0) else @as(T, 0);
    return if (a > b) a else b;
}

fn floatUnop(comptime T: type, op: Op, x: T) T {
    return switch (op) {
        .f32_abs, .f64_abs => @abs(x),
        .f32_neg, .f64_neg => -x,
        .f32_ceil, .f64_ceil => @ceil(x),
        .f32_floor, .f64_floor => @floor(x),
        .f32_trunc, .f64_trunc => @trunc(x),
        .f32_nearest, .f64_nearest => roundEven(T, x),
        .f32_sqrt, .f64_sqrt => @sqrt(x),
        else => unreachable,
    };
}

fn floatBinop(comptime T: type, op: Op, a: T, b: T) T {
    return switch (op) {
        .f32_add, .f64_add => a + b,
        .f32_sub, .f64_sub => a - b,
        .f32_mul, .f64_mul => a * b,
        .f32_div, .f64_div => a / b,
        .f32_min, .f64_min => fmin(T, a, b),
        .f32_max, .f64_max => fmax(T, a, b),
        .f32_copysign, .f64_copysign => std.math.copysign(a, b),
        else => unreachable,
    };
}

fn floatCmp(comptime T: type, op: Op, a: T, b: T) bool {
    return switch (op) {
        .f32_eq, .f64_eq => a == b,
        .f32_ne, .f64_ne => a != b,
        .f32_lt, .f64_lt => a < b,
        .f32_gt, .f64_gt => a > b,
        .f32_le, .f64_le => a <= b,
        .f32_ge, .f64_ge => a >= b,
        else => unreachable,
    };
}

/// Trapping float→int truncation (§4.3.3): traps on NaN and on values
/// outside `[lo, hi)`. The bounds are the exact representable limits
/// for each (Int, Float) pair, so the subsequent `@intFromFloat` is in
/// range.
fn truncTrap(
    comptime Int: type,
    comptime Float: type,
    f: Float,
    comptime lo: Float,
    comptime lo_inclusive: bool,
    comptime hi: Float,
) TrapError!Int {
    if (std.math.isNan(f)) return error.InvalidConversionToInteger;
    const lo_ok = if (lo_inclusive) f >= lo else f > lo;
    if (!lo_ok or f >= hi) return error.IntegerOverflow;
    return @intFromFloat(@trunc(f));
}

/// Saturating float→int truncation (trunc_sat): NaN → 0, out-of-range
/// clamps to the integer min/max.
fn truncSat(comptime Int: type, comptime Float: type, f: Float) Int {
    if (std.math.isNan(f)) return 0;
    const t = @trunc(f);
    const min_f: Float = @floatFromInt(std.math.minInt(Int));
    const max_f: Float = @floatFromInt(std.math.maxInt(Int));
    if (t <= min_f) return std.math.minInt(Int);
    if (t >= max_f) return std.math.maxInt(Int);
    return @intFromFloat(t);
}

// ── SIMD (v128, §5.4.8) ─────────────────────────────────────────────
//
// A v128 lives in the 128-bit cell; each operation `@bitCast`s it to
// the relevant `@Vector` shape, computes with Zig's vector ops, and
// casts back. This is the wasm3/DrumBrake idiom expressed natively.

fn vsplat(comptime N: usize, comptime T: type, x: T) u128 {
    const vec: @Vector(N, T) = @splat(x);
    return @bitCast(vec);
}

const IOp = enum { add, sub, mul };
fn ibin(ip: *Interp, comptime N: usize, comptime T: type, comptime op: IOp) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const x: @Vector(N, T) = @bitCast(a);
    const y: @Vector(N, T) = @bitCast(b);
    const r = switch (op) {
        .add => x +% y,
        .sub => x -% y,
        .mul => x *% y,
    };
    return @bitCast(r);
}

fn ineg(comptime N: usize, comptime T: type, a: u128) u128 {
    const x: @Vector(N, T) = @bitCast(a);
    const z: @Vector(N, T) = @splat(0);
    return @bitCast(z -% x);
}

const FUn = enum { abs, neg, sqrt };
fn funary(comptime N: usize, comptime T: type, comptime op: FUn, a: u128) u128 {
    const x: @Vector(N, T) = @bitCast(a);
    const r = switch (op) {
        .abs => @abs(x),
        .neg => -x,
        .sqrt => @sqrt(x),
    };
    return @bitCast(r);
}

const FBin = enum { add, sub, mul, div, min, max };
fn fbin(ip: *Interp, comptime N: usize, comptime T: type, comptime op: FBin) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const x: @Vector(N, T) = @bitCast(a);
    const y: @Vector(N, T) = @bitCast(b);
    switch (op) {
        .add => return @bitCast(x + y),
        .sub => return @bitCast(x - y),
        .mul => return @bitCast(x * y),
        .div => return @bitCast(x / y),
        .min, .max => {
            // Per-lane NaN / signed-zero handling (the scalar rule).
            var r: @Vector(N, T) = undefined;
            inline for (0..N) |i| r[i] = if (op == .min) fmin(T, x[i], y[i]) else fmax(T, x[i], y[i]);
            return @bitCast(r);
        },
    }
}

fn maskBits(comptime N: usize, comptime U: type, mask: @Vector(N, bool)) u128 {
    const ones: @Vector(N, U) = @splat(~@as(U, 0));
    const zero: @Vector(N, U) = @splat(0);
    return @bitCast(@select(U, mask, ones, zero));
}

fn intCmp(ip: *Interp, comptime N: usize, comptime S: type, comptime U: type, op_idx: u32) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const as: @Vector(N, S) = @bitCast(a);
    const bs: @Vector(N, S) = @bitCast(b);
    const au: @Vector(N, U) = @bitCast(a);
    const bu: @Vector(N, U) = @bitCast(b);
    const mask = switch (op_idx) {
        0 => au == bu, // eq
        1 => au != bu, // ne
        2 => as < bs, // lt_s
        3 => au < bu, // lt_u
        4 => as > bs, // gt_s
        5 => au > bu, // gt_u
        6 => as <= bs, // le_s
        7 => au <= bu, // le_u
        8 => as >= bs, // ge_s
        9 => au >= bu, // ge_u
        else => unreachable,
    };
    return maskBits(N, U, mask);
}

fn floatCmpV(ip: *Interp, comptime N: usize, comptime T: type, comptime U: type, op_idx: u32) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const x: @Vector(N, T) = @bitCast(a);
    const y: @Vector(N, T) = @bitCast(b);
    const mask = switch (op_idx) {
        0 => x == y,
        1 => x != y,
        2 => x < y,
        3 => x > y,
        4 => x <= y,
        5 => x >= y,
        else => unreachable,
    };
    return maskBits(N, U, mask);
}

const ShOp = enum { shl, shr_s, shr_u };
fn ishift(comptime N: usize, comptime S: type, comptime U: type, comptime op: ShOp, count: u32, a: u128) u128 {
    const Log2 = std.math.Log2Int(U);
    const amt: Log2 = @intCast(count & (@bitSizeOf(U) - 1));
    const shv: @Vector(N, Log2) = @splat(amt);
    switch (op) {
        .shl => {
            const xu: @Vector(N, U) = @bitCast(a);
            return @bitCast(xu << shv);
        },
        .shr_s => {
            const xs: @Vector(N, S) = @bitCast(a);
            return @bitCast(xs >> shv);
        },
        .shr_u => {
            const xu: @Vector(N, U) = @bitCast(a);
            return @bitCast(xu >> shv);
        },
    }
}

fn execSimd(ip: *Interp, sub: u32, body: []const u8, pc: *usize) TrapError!void {
    switch (sub) {
        0 => { // v128.load
            const ea = memEa(ip, body, pc);
            const data = ip.instance.memory.?.data;
            try checkBounds(data.len, ea, 16);
            try ip.pushV128(std.mem.readInt(u128, data[@intCast(ea)..][0..16], .little));
        },
        11 => { // v128.store
            const val = ip.popV128();
            const ea = memEa(ip, body, pc);
            const data = ip.instance.memory.?.data;
            try checkBounds(data.len, ea, 16);
            std.mem.writeInt(u128, data[@intCast(ea)..][0..16], val, .little);
        },
        12 => { // v128.const
            const val = std.mem.readInt(u128, body[pc.*..][0..16], .little);
            pc.* += 16;
            try ip.pushV128(val);
        },

        15 => try ip.pushV128(vsplat(16, i8, @truncate(ip.popI32()))),
        16 => try ip.pushV128(vsplat(8, i16, @truncate(ip.popI32()))),
        17 => try ip.pushV128(vsplat(4, i32, ip.popI32())),
        18 => try ip.pushV128(vsplat(2, i64, ip.popI64())),
        19 => try ip.pushV128(vsplat(4, f32, ip.popF32())),
        20 => try ip.pushV128(vsplat(2, f64, ip.popF64())),

        21 => try ip.pushI32(laneI8(ip.popV128(), readLane(body, pc), true)),
        22 => try ip.pushI32(laneI8(ip.popV128(), readLane(body, pc), false)),
        24 => try ip.pushI32(laneI16(ip.popV128(), readLane(body, pc), true)),
        25 => try ip.pushI32(laneI16(ip.popV128(), readLane(body, pc), false)),
        27 => {
            const lane = readLane(body, pc);
            const arr: [4]i32 = @bitCast(ip.popV128());
            try ip.pushI32(arr[lane]);
        },
        29 => {
            const lane = readLane(body, pc);
            const arr: [2]i64 = @bitCast(ip.popV128());
            try ip.pushI64(arr[lane]);
        },
        31 => {
            const lane = readLane(body, pc);
            const arr: [4]f32 = @bitCast(ip.popV128());
            try ip.pushF32(arr[lane]);
        },
        33 => {
            const lane = readLane(body, pc);
            const arr: [2]f64 = @bitCast(ip.popV128());
            try ip.pushF64(arr[lane]);
        },

        23 => try ip.pushV128(replaceI8(body, pc, @truncate(ip.popI32()), ip.popV128())),
        26 => try ip.pushV128(replaceI16(body, pc, @truncate(ip.popI32()), ip.popV128())),
        28 => {
            const lane = readLane(body, pc);
            const x = ip.popI32();
            var arr: [4]i32 = @bitCast(ip.popV128());
            arr[lane] = x;
            try ip.pushV128(@bitCast(arr));
        },
        30 => {
            const lane = readLane(body, pc);
            const x = ip.popI64();
            var arr: [2]i64 = @bitCast(ip.popV128());
            arr[lane] = x;
            try ip.pushV128(@bitCast(arr));
        },
        32 => {
            const lane = readLane(body, pc);
            const x = ip.popF32();
            var arr: [4]f32 = @bitCast(ip.popV128());
            arr[lane] = x;
            try ip.pushV128(@bitCast(arr));
        },
        34 => {
            const lane = readLane(body, pc);
            const x = ip.popF64();
            var arr: [2]f64 = @bitCast(ip.popV128());
            arr[lane] = x;
            try ip.pushV128(@bitCast(arr));
        },

        // lane-wise comparisons
        35...44 => try ip.pushV128(intCmp(ip, 16, i8, u8, sub - 35)),
        45...54 => try ip.pushV128(intCmp(ip, 8, i16, u16, sub - 45)),
        55...64 => try ip.pushV128(intCmp(ip, 4, i32, u32, sub - 55)),
        65...70 => try ip.pushV128(floatCmpV(ip, 4, f32, u32, sub - 65)),
        71...76 => try ip.pushV128(floatCmpV(ip, 2, f64, u64, sub - 71)),

        77 => try ip.pushV128(~ip.popV128()), // v128.not
        78 => {
            const b = ip.popV128();
            try ip.pushV128(ip.popV128() & b);
        },
        79 => {
            const b = ip.popV128();
            try ip.pushV128(ip.popV128() & ~b);
        },
        80 => {
            const b = ip.popV128();
            try ip.pushV128(ip.popV128() | b);
        },
        81 => {
            const b = ip.popV128();
            try ip.pushV128(ip.popV128() ^ b);
        },
        82 => { // bitselect(a, b, mask) = (a & mask) | (b & ~mask)
            const mask = ip.popV128();
            const b = ip.popV128();
            const a = ip.popV128();
            try ip.pushV128((a & mask) | (b & ~mask));
        },
        83 => try ip.pushI32(@intFromBool(ip.popV128() != 0)), // any_true

        // unary integer negate
        97 => try ip.pushV128(ineg(16, i8, ip.popV128())),
        129 => try ip.pushV128(ineg(8, i16, ip.popV128())),
        161 => try ip.pushV128(ineg(4, i32, ip.popV128())),
        193 => try ip.pushV128(ineg(2, i64, ip.popV128())),

        // unary float
        224 => try ip.pushV128(funary(4, f32, .abs, ip.popV128())),
        225 => try ip.pushV128(funary(4, f32, .neg, ip.popV128())),
        227 => try ip.pushV128(funary(4, f32, .sqrt, ip.popV128())),
        236 => try ip.pushV128(funary(2, f64, .abs, ip.popV128())),
        237 => try ip.pushV128(funary(2, f64, .neg, ip.popV128())),
        239 => try ip.pushV128(funary(2, f64, .sqrt, ip.popV128())),

        // binary integer arithmetic
        110 => try ip.pushV128(ibin(ip, 16, i8, .add)),
        113 => try ip.pushV128(ibin(ip, 16, i8, .sub)),
        142 => try ip.pushV128(ibin(ip, 8, i16, .add)),
        145 => try ip.pushV128(ibin(ip, 8, i16, .sub)),
        149 => try ip.pushV128(ibin(ip, 8, i16, .mul)),
        174 => try ip.pushV128(ibin(ip, 4, i32, .add)),
        177 => try ip.pushV128(ibin(ip, 4, i32, .sub)),
        181 => try ip.pushV128(ibin(ip, 4, i32, .mul)),
        206 => try ip.pushV128(ibin(ip, 2, i64, .add)),
        209 => try ip.pushV128(ibin(ip, 2, i64, .sub)),
        213 => try ip.pushV128(ibin(ip, 2, i64, .mul)),

        // binary float arithmetic
        228 => try ip.pushV128(fbin(ip, 4, f32, .add)),
        229 => try ip.pushV128(fbin(ip, 4, f32, .sub)),
        230 => try ip.pushV128(fbin(ip, 4, f32, .mul)),
        231 => try ip.pushV128(fbin(ip, 4, f32, .div)),
        232 => try ip.pushV128(fbin(ip, 4, f32, .min)),
        233 => try ip.pushV128(fbin(ip, 4, f32, .max)),
        240 => try ip.pushV128(fbin(ip, 2, f64, .add)),
        241 => try ip.pushV128(fbin(ip, 2, f64, .sub)),
        242 => try ip.pushV128(fbin(ip, 2, f64, .mul)),
        243 => try ip.pushV128(fbin(ip, 2, f64, .div)),
        244 => try ip.pushV128(fbin(ip, 2, f64, .min)),
        245 => try ip.pushV128(fbin(ip, 2, f64, .max)),

        // shifts: pop the v128 first (top), then the i32 count below it.
        107 => try shiftOp(ip, 16, i8, u8, .shl),
        108 => try shiftOp(ip, 16, i8, u8, .shr_s),
        109 => try shiftOp(ip, 16, i8, u8, .shr_u),
        139 => try shiftOp(ip, 8, i16, u16, .shl),
        140 => try shiftOp(ip, 8, i16, u16, .shr_s),
        141 => try shiftOp(ip, 8, i16, u16, .shr_u),
        171 => try shiftOp(ip, 4, i32, u32, .shl),
        172 => try shiftOp(ip, 4, i32, u32, .shr_s),
        173 => try shiftOp(ip, 4, i32, u32, .shr_u),
        203 => try shiftOp(ip, 2, i64, u64, .shl),
        204 => try shiftOp(ip, 2, i64, u64, .shr_s),
        205 => try shiftOp(ip, 2, i64, u64, .shr_u),

        // integer abs / popcnt
        96 => try ip.pushV128(vabs(16, i8, ip.popV128())),
        128 => try ip.pushV128(vabs(8, i16, ip.popV128())),
        160 => try ip.pushV128(vabs(4, i32, ip.popV128())),
        192 => try ip.pushV128(vabs(2, i64, ip.popV128())),
        98 => try ip.pushV128(vpopcnt(ip.popV128())),

        // all_true / bitmask
        99 => try ip.pushI32(vallTrue(16, u8, ip.popV128())),
        131 => try ip.pushI32(vallTrue(8, u16, ip.popV128())),
        163 => try ip.pushI32(vallTrue(4, u32, ip.popV128())),
        195 => try ip.pushI32(vallTrue(2, u64, ip.popV128())),
        100 => try ip.pushI32(vbitmask(16, i8, ip.popV128())),
        132 => try ip.pushI32(vbitmask(8, i16, ip.popV128())),
        164 => try ip.pushI32(vbitmask(4, i32, ip.popV128())),
        196 => try ip.pushI32(vbitmask(2, i64, ip.popV128())),

        // min / max (signed and unsigned)
        118 => try ip.pushV128(vminmax(ip, 16, i8, false)),
        119 => try ip.pushV128(vminmax(ip, 16, u8, false)),
        120 => try ip.pushV128(vminmax(ip, 16, i8, true)),
        121 => try ip.pushV128(vminmax(ip, 16, u8, true)),
        150 => try ip.pushV128(vminmax(ip, 8, i16, false)),
        151 => try ip.pushV128(vminmax(ip, 8, u16, false)),
        152 => try ip.pushV128(vminmax(ip, 8, i16, true)),
        153 => try ip.pushV128(vminmax(ip, 8, u16, true)),
        182 => try ip.pushV128(vminmax(ip, 4, i32, false)),
        183 => try ip.pushV128(vminmax(ip, 4, u32, false)),
        184 => try ip.pushV128(vminmax(ip, 4, i32, true)),
        185 => try ip.pushV128(vminmax(ip, 4, u32, true)),

        // avgr_u
        123 => try ip.pushV128(vavgr(ip, 16, u8)),
        155 => try ip.pushV128(vavgr(ip, 8, u16)),

        // saturating add / sub
        111 => try ip.pushV128(vsat(ip, 16, i8, true)),
        112 => try ip.pushV128(vsat(ip, 16, u8, true)),
        114 => try ip.pushV128(vsat(ip, 16, i8, false)),
        115 => try ip.pushV128(vsat(ip, 16, u8, false)),
        143 => try ip.pushV128(vsat(ip, 8, i16, true)),
        144 => try ip.pushV128(vsat(ip, 8, u16, true)),
        146 => try ip.pushV128(vsat(ip, 8, i16, false)),
        147 => try ip.pushV128(vsat(ip, 8, u16, false)),

        // i64x2 comparisons (signed only)
        214 => try ip.pushV128(intCmp(ip, 2, i64, u64, 0)),
        215 => try ip.pushV128(intCmp(ip, 2, i64, u64, 1)),
        216 => try ip.pushV128(intCmp(ip, 2, i64, u64, 2)),
        217 => try ip.pushV128(intCmp(ip, 2, i64, u64, 4)),
        218 => try ip.pushV128(intCmp(ip, 2, i64, u64, 6)),
        219 => try ip.pushV128(intCmp(ip, 2, i64, u64, 8)),

        // float rounding
        103 => try ip.pushV128(vround(4, f32, .ceil, ip.popV128())),
        104 => try ip.pushV128(vround(4, f32, .floor, ip.popV128())),
        105 => try ip.pushV128(vround(4, f32, .trunc, ip.popV128())),
        106 => try ip.pushV128(vround(4, f32, .nearest, ip.popV128())),
        116 => try ip.pushV128(vround(2, f64, .ceil, ip.popV128())),
        117 => try ip.pushV128(vround(2, f64, .floor, ip.popV128())),
        122 => try ip.pushV128(vround(2, f64, .trunc, ip.popV128())),
        148 => try ip.pushV128(vround(2, f64, .nearest, ip.popV128())),

        // pmin / pmax
        234 => try ip.pushV128(vpminmax(ip, 4, f32, false)),
        235 => try ip.pushV128(vpminmax(ip, 4, f32, true)),
        246 => try ip.pushV128(vpminmax(ip, 2, f64, false)),
        247 => try ip.pushV128(vpminmax(ip, 2, f64, true)),

        // conversions
        248 => try ip.pushV128(truncSatF32x4(i32, ip.popV128())),
        249 => try ip.pushV128(truncSatF32x4(u32, ip.popV128())),
        250 => try ip.pushV128(convertI32x4(i32, ip.popV128())),
        251 => try ip.pushV128(convertI32x4(u32, ip.popV128())),
        252 => try ip.pushV128(truncSatF64x2Zero(i32, ip.popV128())),
        253 => try ip.pushV128(truncSatF64x2Zero(u32, ip.popV128())),
        254 => try ip.pushV128(convertLowI32x4(i32, ip.popV128())),
        255 => try ip.pushV128(convertLowI32x4(u32, ip.popV128())),
        94 => try ip.pushV128(demoteF64x2Zero(ip.popV128())),
        95 => try ip.pushV128(promoteLowF32x4(ip.popV128())),

        else => return error.UnsupportedImportCall, // not yet implemented
    }
}

fn readLane(body: []const u8, pc: *usize) u8 {
    const lane = body[pc.*];
    pc.* += 1;
    return lane;
}

// Lane access uses a fixed array view rather than `vec[i]` because a
// `@Vector` index must be comptime-known, while the lane is a runtime
// immediate.
fn laneI8(v: u128, lane: u8, signed: bool) i32 {
    if (signed) {
        const arr: [16]i8 = @bitCast(v);
        return arr[lane];
    }
    const arr: [16]u8 = @bitCast(v);
    return arr[lane];
}

fn laneI16(v: u128, lane: u8, signed: bool) i32 {
    if (signed) {
        const arr: [8]i16 = @bitCast(v);
        return arr[lane];
    }
    const arr: [8]u16 = @bitCast(v);
    return arr[lane];
}

fn replaceI8(body: []const u8, pc: *usize, x: i8, v: u128) u128 {
    const lane = readLane(body, pc);
    var arr: [16]i8 = @bitCast(v);
    arr[lane] = x;
    return @bitCast(arr);
}

fn replaceI16(body: []const u8, pc: *usize, x: i16, v: u128) u128 {
    const lane = readLane(body, pc);
    var arr: [8]i16 = @bitCast(v);
    arr[lane] = x;
    return @bitCast(arr);
}

fn shiftOp(ip: *Interp, comptime N: usize, comptime S: type, comptime U: type, comptime op: ShOp) TrapError!void {
    const count: u32 = @bitCast(ip.popI32());
    const v = ip.popV128();
    try ip.pushV128(ishift(N, S, U, op, count, v));
}

fn vabs(comptime N: usize, comptime T: type, a: u128) u128 {
    const x: @Vector(N, T) = @bitCast(a);
    const z: @Vector(N, T) = @splat(0);
    return @bitCast(@select(T, x < z, z -% x, x));
}

fn vpopcnt(a: u128) u128 {
    const x: @Vector(16, u8) = @bitCast(a);
    const counts: @Vector(16, u8) = @intCast(@popCount(x));
    return @bitCast(counts);
}

fn vallTrue(comptime N: usize, comptime T: type, a: u128) i32 {
    const x: @Vector(N, T) = @bitCast(a);
    const z: @Vector(N, T) = @splat(0);
    return @intFromBool(@reduce(.And, x != z));
}

fn vbitmask(comptime N: usize, comptime T: type, a: u128) i32 {
    const arr: [N]T = @bitCast(a);
    var m: u32 = 0;
    inline for (0..N) |i| {
        if (arr[i] < 0) m |= (@as(u32, 1) << @intCast(i));
    }
    return @bitCast(m);
}

fn vminmax(ip: *Interp, comptime N: usize, comptime T: type, comptime is_max: bool) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const x: @Vector(N, T) = @bitCast(a);
    const y: @Vector(N, T) = @bitCast(b);
    return @bitCast(if (is_max) @max(x, y) else @min(x, y));
}

fn vavgr(ip: *Interp, comptime N: usize, comptime T: type) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const xa: [N]T = @bitCast(a);
    const ya: [N]T = @bitCast(b);
    var r: [N]T = undefined;
    inline for (0..N) |i| {
        const s: u32 = @as(u32, xa[i]) + @as(u32, ya[i]) + 1;
        r[i] = @truncate(s >> 1);
    }
    return @bitCast(r);
}

fn vsat(ip: *Interp, comptime N: usize, comptime T: type, comptime is_add: bool) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const x: @Vector(N, T) = @bitCast(a);
    const y: @Vector(N, T) = @bitCast(b);
    return @bitCast(if (is_add) x +| y else x -| y);
}

fn vround(comptime N: usize, comptime T: type, comptime op: enum { ceil, floor, trunc, nearest }, a: u128) u128 {
    const x: @Vector(N, T) = @bitCast(a);
    switch (op) {
        .ceil => return @bitCast(@ceil(x)),
        .floor => return @bitCast(@floor(x)),
        .trunc => return @bitCast(@trunc(x)),
        .nearest => {
            var r: @Vector(N, T) = x;
            inline for (0..N) |i| r[i] = roundEven(T, x[i]);
            return @bitCast(r);
        },
    }
}

fn vpminmax(ip: *Interp, comptime N: usize, comptime T: type, comptime is_max: bool) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const x: @Vector(N, T) = @bitCast(a);
    const y: @Vector(N, T) = @bitCast(b);
    // pmin(a, b) = b < a ? b : a ; pmax(a, b) = a < b ? b : a (§5.4.8).
    const r = if (is_max) @select(T, x < y, y, x) else @select(T, y < x, y, x);
    return @bitCast(r);
}

fn truncSatF32x4(comptime Int: type, a: u128) u128 {
    const f: [4]f32 = @bitCast(a);
    var r: [4]Int = undefined;
    inline for (0..4) |i| r[i] = truncSat(Int, f32, f[i]);
    return @bitCast(r);
}

fn truncSatF64x2Zero(comptime Int: type, a: u128) u128 {
    const f: [2]f64 = @bitCast(a);
    var r: [4]Int = .{ 0, 0, 0, 0 };
    r[0] = truncSat(Int, f64, f[0]);
    r[1] = truncSat(Int, f64, f[1]);
    return @bitCast(r);
}

fn convertI32x4(comptime Int: type, a: u128) u128 {
    const iv: [4]Int = @bitCast(a);
    var r: [4]f32 = undefined;
    inline for (0..4) |i| r[i] = @floatFromInt(iv[i]);
    return @bitCast(r);
}

fn convertLowI32x4(comptime Int: type, a: u128) u128 {
    const iv: [4]Int = @bitCast(a);
    var r: [2]f64 = undefined;
    r[0] = @floatFromInt(iv[0]);
    r[1] = @floatFromInt(iv[1]);
    return @bitCast(r);
}

fn demoteF64x2Zero(a: u128) u128 {
    const d: [2]f64 = @bitCast(a);
    var r: [4]f32 = .{ 0, 0, 0, 0 };
    r[0] = @floatCast(d[0]);
    r[1] = @floatCast(d[1]);
    return @bitCast(r);
}

fn promoteLowF32x4(a: u128) u128 {
    const f: [4]f32 = @bitCast(a);
    var r: [2]f64 = undefined;
    r[0] = f[0];
    r[1] = f[1];
    return @bitCast(r);
}

// ── arithmetic ──────────────────────────────────────────────────────

fn compareI32(op: Op, a: i32, b: i32) bool {
    const ua: u32 = @bitCast(a);
    const ub: u32 = @bitCast(b);
    return switch (op) {
        .i32_eq => a == b,
        .i32_ne => a != b,
        .i32_lt_s => a < b,
        .i32_lt_u => ua < ub,
        .i32_gt_s => a > b,
        .i32_gt_u => ua > ub,
        .i32_le_s => a <= b,
        .i32_le_u => ua <= ub,
        .i32_ge_s => a >= b,
        .i32_ge_u => ua >= ub,
        else => unreachable,
    };
}

fn compareI64(op: Op, a: i64, b: i64) bool {
    const ua: u64 = @bitCast(a);
    const ub: u64 = @bitCast(b);
    return switch (op) {
        .i64_eq => a == b,
        .i64_ne => a != b,
        .i64_lt_s => a < b,
        .i64_lt_u => ua < ub,
        .i64_gt_s => a > b,
        .i64_gt_u => ua > ub,
        .i64_le_s => a <= b,
        .i64_le_u => ua <= ub,
        .i64_ge_s => a >= b,
        .i64_ge_u => ua >= ub,
        else => unreachable,
    };
}

fn arithI32(op: Op, a: i32, b: i32) TrapError!i32 {
    const ua: u32 = @bitCast(a);
    const ub: u32 = @bitCast(b);
    return switch (op) {
        .i32_add => a +% b,
        .i32_sub => a -% b,
        .i32_mul => a *% b,
        .i32_div_s => blk: {
            if (b == 0) return error.IntegerDivideByZero;
            if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
            break :blk @divTrunc(a, b);
        },
        .i32_div_u => blk: {
            if (b == 0) return error.IntegerDivideByZero;
            break :blk @bitCast(ua / ub);
        },
        .i32_rem_s => blk: {
            if (b == 0) return error.IntegerDivideByZero;
            if (b == -1) break :blk 0; // avoids INT_MIN % -1 overflow
            break :blk @rem(a, b);
        },
        .i32_rem_u => blk: {
            if (b == 0) return error.IntegerDivideByZero;
            break :blk @bitCast(ua % ub);
        },
        .i32_and => @bitCast(ua & ub),
        .i32_or => @bitCast(ua | ub),
        .i32_xor => @bitCast(ua ^ ub),
        .i32_shl => @bitCast(ua << @intCast(ub & 31)),
        .i32_shr_s => a >> @intCast(ub & 31),
        .i32_shr_u => @bitCast(ua >> @intCast(ub & 31)),
        .i32_rotl => @bitCast(std.math.rotl(u32, ua, ub & 31)),
        .i32_rotr => @bitCast(std.math.rotr(u32, ua, ub & 31)),
        else => unreachable,
    };
}

fn arithI64(op: Op, a: i64, b: i64) TrapError!i64 {
    const ua: u64 = @bitCast(a);
    const ub: u64 = @bitCast(b);
    return switch (op) {
        .i64_add => a +% b,
        .i64_sub => a -% b,
        .i64_mul => a *% b,
        .i64_div_s => blk: {
            if (b == 0) return error.IntegerDivideByZero;
            if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
            break :blk @divTrunc(a, b);
        },
        .i64_div_u => blk: {
            if (b == 0) return error.IntegerDivideByZero;
            break :blk @bitCast(ua / ub);
        },
        .i64_rem_s => blk: {
            if (b == 0) return error.IntegerDivideByZero;
            if (b == -1) break :blk 0;
            break :blk @rem(a, b);
        },
        .i64_rem_u => blk: {
            if (b == 0) return error.IntegerDivideByZero;
            break :blk @bitCast(ua % ub);
        },
        .i64_and => @bitCast(ua & ub),
        .i64_or => @bitCast(ua | ub),
        .i64_xor => @bitCast(ua ^ ub),
        .i64_shl => @bitCast(ua << @intCast(ub & 63)),
        .i64_shr_s => a >> @intCast(ub & 63),
        .i64_shr_u => @bitCast(ua >> @intCast(ub & 63)),
        .i64_rotl => @bitCast(std.math.rotl(u64, ua, ub & 63)),
        .i64_rotr => @bitCast(std.math.rotr(u64, ua, ub & 63)),
        else => unreachable,
    };
}
