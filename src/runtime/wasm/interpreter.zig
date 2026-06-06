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
    CallStackExhausted,
    ValueStackOverflow,
    UnsupportedImportCall,
};

pub const Error = TrapError || validator.ValidateError || error{ NoSuchExport, OutOfMemory };

const STACK_CELLS = 1 << 16;
const MAX_FRAMES = 1 << 12;

/// A runtime global cell.
const Global = struct {
    value: u64,
    mutable: bool,
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

    pub fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        allocator.free(self.globals);
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

    return .{
        .module = module,
        .funcs = funcs,
        .globals = globals,
        .func_import_count = func_imports,
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

const Interp = struct {
    instance: *Instance,
    stack: []u64,
    sp: usize,
    frames: []Frame,
    nframes: usize,

    inline fn pushCell(self: *Interp, v: u64) TrapError!void {
        if (self.sp >= self.stack.len) return error.ValueStackOverflow;
        self.stack[self.sp] = v;
        self.sp += 1;
    }
    inline fn popCell(self: *Interp) u64 {
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
        try self.pushCell(@bitCast(v));
    }
    inline fn popI64(self: *Interp) i64 {
        return @bitCast(self.popCell());
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
/// encoded as raw cells. Returns the result cells, allocated from
/// `allocator`.
pub fn invoke(
    self: *Instance,
    allocator: std.mem.Allocator,
    func_index: u32,
    args: []const u64,
) Error![]u64 {
    const entry = self.definedFunc(func_index) orelse return error.UnsupportedImportCall;

    const stack = try allocator.alloc(u64, STACK_CELLS);
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

    // Results sit at the bottom of the stack after the final pop.
    const nres = ip.sp;
    const out = try allocator.alloc(u64, nres);
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
