//! WebAssembly validation (§3) fused with O(1) side-table emission.
//!
//! A single forward pass over each function body type-checks it against
//! the abstract value/control stacks of the spec's validation
//! algorithm (Appendix), and — as a side effect — emits the branch
//! side-table the in-place interpreter consults (see
//! docs/wasm-engine.md and code.zig).
//!
//! Side-table contract. One entry per reachable branch-consulting
//! instruction (`if` / `else` / `br` / `br_if`), in bytecode order, so
//! an entry's index equals the count of reachable branches before it.
//! The interpreter keeps a side-table pointer in lockstep: falling
//! through a not-taken `if` / `br_if` advances it by one; a taken
//! branch adds `delta_stp`, set here so the pointer lands on the entry
//! of the first reachable branch at or after the target. Forward
//! targets (`block` / `if` ends) are backpatched at `end` / `else`;
//! `loop` targets are backward and resolved immediately. Branches in
//! unreachable code are type-checked but emit no entry, keeping the
//! lockstep exact.

const std = @import("std");
const types = @import("types.zig");
const module_mod = @import("module.zig");
const reader_mod = @import("reader.zig");
const code_mod = @import("code.zig");
const opcodes = @import("opcodes.zig");

const ValType = types.ValType;
const Module = module_mod.Module;
const Reader = reader_mod.Reader;
const BranchEntry = code_mod.BranchEntry;
const CompiledFunc = code_mod.CompiledFunc;
const Op = opcodes.Op;

pub const ValidateError = error{
    Truncated,
    IntTooLarge,
    LebTooLong,
    BadUtf8,
    BadValType,
    BadRefType,
    BadBlockType,
    BadLane,
    BadAlign,
    BadConstExpr,
    DataCountMissing,
    UnknownDataSegment,
    UnknownMemory,
    SectionSizeMismatch,
    UnknownOpcode,
    TypeMismatch,
    StackUnderflow,
    UnknownLocal,
    UnknownGlobal,
    UnknownFunc,
    UnknownType,
    UnknownTable,
    UnknownLabel,
    ImmutableGlobal,
    UnexpectedElse,
    UnbalancedEnd,
    InvalidLocalCount,
    NoMemory,
    OutOfMemory,
};

/// `null` models the spec's "Unknown" (bottom) type that polymorphic
/// stack slots take in unreachable code.
const AbsVal = ?ValType;

/// A block signature: the params it consumes and the results it
/// produces (§5.3.2 blocktype). Slices live in the arena.
const BlockType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// A forward branch awaiting its target. Patched when the construct's
/// `end` (or, for `if`'s false edge, its `else`) is reached.
const Pending = struct {
    entry: u32, // index into the side-table
    ip: u32, // bytecode offset of the branch opcode
};

const Ctrl = struct {
    op: Op, // block / loop / if / else
    start_types: []const ValType,
    end_types: []const ValType,
    height: u32, // operand-stack height at entry
    unreachable_: bool = false,
    entered_reachable: bool, // was the construct itself reachable?
    start_ip: u32, // first body instruction (loop branch target)
    start_stp: u32, // side-table length at body start (loop target entry)
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    if_entry: ?u32 = null, // `if`'s own entry, patched at else/end
    if_ip: u32 = 0,

    fn labelTypes(self: *const Ctrl) []const ValType {
        return if (self.op == .loop) self.start_types else self.end_types;
    }
};

/// Validate every function in `module`, returning one `CompiledFunc`
/// each (positionally matching `module.code`). Allocations come from
/// `arena`, which the caller owns for the module's lifetime.
pub fn validateModule(arena: std.mem.Allocator, module: *const Module) ValidateError![]const CompiledFunc {
    // §3.4.4 — each global's initializer is a constant expression of the
    // global's declared type. A `global.get` may name any preceding
    // immutable global (imported or defined), so each initializer sees
    // only the globals declared before it.
    var glob_imports: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .global) glob_imports += 1;
    }
    const total_globals = glob_imports + @as(u32, @intCast(module.globals.len));
    for (module.globals, 0..) |g, i| {
        try validateConstExpr(module, g.init_expr, g.type.val, glob_imports + @as(u32, @intCast(i)));
    }

    // §3.4.5/§3.4.6 — active data and element segment offsets are
    // constant expressions of the target's address type, and their
    // memory / table indices must exist.
    try validateData(module, total_globals);
    try validateElements(module, total_globals);

    // §3.4.2 — a table's explicit element initializer is a constant
    // expression of the table's element type. Only imported globals
    // precede the table section, so defined globals are out of scope.
    for (module.tables) |t| {
        if (t.init_expr) |expr| {
            try validateConstExpr(module, expr, t.elem.toValType(), glob_imports);
        }
    }

    // §3.4.9 — the start function must exist and have type [] -> [].
    if (module.start) |s| {
        const ft = module.types[try funcTypeIndex(module, s)];
        if (ft.params.len != 0 or ft.results.len != 0) return error.TypeMismatch;
    }

    // §3.4.10 — every imported function names an existing type.
    for (module.imports) |imp| switch (imp.desc) {
        .func => |ti| if (ti >= module.types.len) return error.UnknownType,
        else => {},
    };

    const declared = try buildDeclaredSet(arena, module);

    const out = try arena.alloc(CompiledFunc, module.code.len);
    for (module.code, 0..) |body, i| {
        const type_index = module.funcs[i];
        if (type_index >= module.types.len) return error.UnknownType;
        out[i] = try validateFunc(arena, module, type_index, body.bytes, declared);
    }
    return out;
}

/// The type index of a function by its function-index-space index,
/// spanning imports and defined functions.
fn funcTypeIndex(module: *const Module, fidx: u32) ValidateError!u32 {
    var k: u32 = 0;
    for (module.imports) |imp| switch (imp.desc) {
        .func => |ti| {
            if (k == fidx) return ti;
            k += 1;
        },
        else => {},
    };
    const local = fidx - k;
    if (local >= module.funcs.len) return error.UnknownFunc;
    return module.funcs[local];
}

/// Walk a constant expression, marking every `ref.func` index it names
/// in `declared` (used to build §3.4.1.3's reference set).
fn markRefFuncsInExpr(r: *Reader, declared: []bool) ValidateError!void {
    while (true) {
        const b = try r.byte();
        switch (b) {
            0x0b => break,
            0x41 => _ = try r.sleb(i32),
            0x42 => _ = try r.sleb(i64),
            0x43 => _ = try r.bytesN(4),
            0x44 => _ = try r.bytesN(8),
            0x23 => _ = try r.uleb(u32),
            0xd0 => _ = try r.byte(),
            0xd2 => {
                const fi = try r.uleb(u32);
                if (fi < declared.len) declared[fi] = true;
            },
            0x6a, 0x6b, 0x6c, 0x7c, 0x7d, 0x7e => {},
            0xfd => {
                _ = try r.uleb(u32);
                _ = try r.bytesN(16);
            },
            else => {},
        }
    }
}

/// Build §3.4.1.3's function reference set: the functions a body's
/// `ref.func` may name — those referenced by exports, global
/// initializers, and element segments. The start function index does
/// *not* contribute (a start that is otherwise unreferenced may not be
/// the target of a `ref.func`).
fn buildDeclaredSet(arena: std.mem.Allocator, module: *const Module) ValidateError![]bool {
    const declared = try arena.alloc(bool, totalFuncs(module));
    @memset(declared, false);
    for (module.exports) |ex| {
        if (ex.desc == .func and ex.desc.func < declared.len) declared[ex.desc.func] = true;
    }
    for (module.globals) |gl| {
        var r = Reader.init(gl.init_expr);
        try markRefFuncsInExpr(&r, declared);
    }
    if (module.elements_count != 0) {
        var r = Reader.init(module.elements_raw);
        var i: u32 = 0;
        while (i < module.elements_count) : (i += 1) {
            const flag = try r.uleb(u32);
            const kind = flag & 3;
            const use_exprs = flag >= 4;
            const is_active = (kind == 0 or kind == 2);
            if (kind == 2) _ = try r.uleb(u32); // table index
            if (is_active) try markRefFuncsInExpr(&r, declared); // offset (no ref.func)
            if (kind != 0) _ = try r.byte(); // elemkind / reftype
            const n = try r.uleb(u32);
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                if (use_exprs) {
                    try markRefFuncsInExpr(&r, declared);
                } else {
                    const fi = try r.uleb(u32);
                    if (fi < declared.len) declared[fi] = true;
                }
            }
        }
    }
    return declared;
}

/// Total functions in the index space (imports + defined).
fn totalFuncs(module: *const Module) u32 {
    var imported: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .func) imported += 1;
    }
    return imported + @as(u32, @intCast(module.funcs.len));
}

/// Type of a global referenceable from a constant expression (§3.3.7):
/// `global.get gi` may name any immutable global preceding `limit` in
/// the index space (imports followed by earlier-declared definitions).
fn constGlobalType(module: *const Module, gi: u32, limit: u32) ValidateError!ValType {
    if (gi >= limit) return error.UnknownGlobal;
    var k: u32 = 0;
    for (module.imports) |imp| switch (imp.desc) {
        .global => |gt| {
            if (k == gi) {
                if (gt.mut == .mutable) return error.BadConstExpr;
                return gt.val;
            }
            k += 1;
        },
        else => {},
    };
    // A defined global preceding `limit`.
    const di = gi - k;
    if (di >= module.globals.len) return error.UnknownGlobal;
    const g = module.globals[di];
    if (g.type.mut == .mutable) return error.BadConstExpr;
    return g.type.val;
}

/// §3.3.7 — type-check a constant expression and require it to yield
/// exactly `expected`. Admits the typed `*.const` forms, `ref.null` /
/// `ref.func`, `global.get` of an imported immutable global, and the
/// extended-const `i32`/`i64` `add` / `sub` / `mul`.
fn validateConstExpr(module: *const Module, expr: []const u8, expected: ValType, global_limit: u32) ValidateError!void {
    var r = Reader.init(expr);
    return validateConstExprR(module, &r, expected, global_limit);
}

/// As `validateConstExpr`, but consuming the expression from an existing
/// reader (for data / element segment offsets parsed in-stream).
fn validateConstExprR(module: *const Module, r: *Reader, expected: ValType, global_limit: u32) ValidateError!void {
    var stack: [16]ValType = undefined;
    var sp: usize = 0;
    const push = struct {
        fn f(s: *[16]ValType, n: *usize, t: ValType) ValidateError!void {
            if (n.* >= s.len) return error.BadConstExpr;
            s.*[n.*] = t;
            n.* += 1;
        }
    }.f;
    const pop = struct {
        fn f(s: *[16]ValType, n: *usize, t: ValType) ValidateError!void {
            if (n.* == 0) return error.TypeMismatch;
            n.* -= 1;
            if (s.*[n.*] != t) return error.TypeMismatch;
        }
    }.f;
    while (true) {
        const op = try r.byte();
        switch (op) {
            0x0b => break, // end
            0x41 => {
                _ = try r.sleb(i32);
                try push(&stack, &sp, .i32);
            },
            0x42 => {
                _ = try r.sleb(i64);
                try push(&stack, &sp, .i64);
            },
            0x43 => {
                _ = try r.bytesN(4);
                try push(&stack, &sp, .f32);
            },
            0x44 => {
                _ = try r.bytesN(8);
                try push(&stack, &sp, .f64);
            },
            0x23 => { // global.get
                const gi = try r.uleb(u32);
                try push(&stack, &sp, try constGlobalType(module, gi, global_limit));
            },
            0xd0 => { // ref.null
                const rt = types.RefType.fromByte(try r.byte()) orelse return error.BadRefType;
                try push(&stack, &sp, rt.toValType());
            },
            0xd2 => { // ref.func
                const fi = try r.uleb(u32);
                if (fi >= totalFuncs(module)) return error.UnknownFunc;
                try push(&stack, &sp, .funcref);
            },
            0x6a, 0x6b, 0x6c => { // i32.add / sub / mul
                try pop(&stack, &sp, .i32);
                try pop(&stack, &sp, .i32);
                try push(&stack, &sp, .i32);
            },
            0x7c, 0x7d, 0x7e => { // i64.add / sub / mul
                try pop(&stack, &sp, .i64);
                try pop(&stack, &sp, .i64);
                try push(&stack, &sp, .i64);
            },
            0xfd => { // v128.const (only constant 0xFD form)
                const sub = try r.uleb(u32);
                if (sub != 12) return error.BadConstExpr;
                _ = try r.bytesN(16);
                try push(&stack, &sp, .v128);
            },
            else => return error.BadConstExpr, // not a constant instruction
        }
    }
    if (sp != 1 or stack[0] != expected) return error.TypeMismatch;
}

/// Number of memories in the index space (imports + defined).
fn numMemories(module: *const Module) u32 {
    var n: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .mem) n += 1;
    }
    return n + @as(u32, @intCast(module.mems.len));
}

/// Address type (i32, or i64 for a memory64) of memory 0.
fn memAddrType(module: *const Module) ValType {
    for (module.imports) |imp| {
        if (imp.desc == .mem) return if (imp.desc.mem.limits.is_64) .i64 else .i32;
    }
    if (module.mems.len > 0) return if (module.mems[0].limits.is_64) .i64 else .i32;
    return .i32;
}

/// §3.4.6 — validate active data segment offsets (constant expressions
/// of the memory's address type) and their memory indices.
fn validateData(module: *const Module, global_limit: u32) ValidateError!void {
    if (module.data_count_in_section == 0) return;
    var r = Reader.init(module.data_raw);
    var i: u32 = 0;
    while (i < module.data_count_in_section) : (i += 1) {
        const flag = try r.uleb(u32);
        const is_active = (flag != 1);
        var memidx: u32 = 0;
        if (flag == 2) memidx = try r.uleb(u32);
        if (is_active) {
            if (memidx >= numMemories(module)) return error.UnknownMemory;
            try validateConstExprR(module, &r, memAddrType(module), global_limit);
        }
        const n = try r.uleb(u32);
        _ = try r.bytesN(n);
    }
    // The segments must consume the whole section payload (§5.5.14): a
    // declared size larger than the structural content is malformed.
    if (r.pos != module.data_raw.len) return error.SectionSizeMismatch;
}

/// §3.4.5 — validate active element segment offsets and the function
/// indices a segment references.
fn validateElements(module: *const Module, global_limit: u32) ValidateError!void {
    if (module.elements_count == 0) return;
    var r = Reader.init(module.elements_raw);
    var i: u32 = 0;
    while (i < module.elements_count) : (i += 1) {
        const flag = try r.uleb(u32);
        const kind = flag & 3; // 0/2 active, 1 passive, 3 declarative
        const use_exprs = flag >= 4;
        const is_active = (kind == 0 or kind == 2);

        var table_idx: u32 = 0;
        if (kind == 2) table_idx = try r.uleb(u32);
        if (is_active) {
            const addr = try tableAddr(module, table_idx);
            try validateConstExprR(module, &r, addr, global_limit);
        }
        // For an expression-form segment the byte after the offset is the
        // element reference type; for an index-form segment it is the
        // elemkind (always funcref).
        var elem_type: ValType = .funcref;
        if (kind != 0) {
            const b = try r.byte();
            if (use_exprs) {
                const rt = types.RefType.fromByte(b) orelse return error.BadRefType;
                elem_type = rt.toValType();
            }
        }

        const n = try r.uleb(u32);
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            if (use_exprs) {
                try validateConstExprR(module, &r, elem_type, global_limit);
            } else {
                const fi = try r.uleb(u32);
                if (fi >= totalFuncs(module)) return error.UnknownFunc;
            }
        }
    }
    if (r.pos != module.elements_raw.len) return error.SectionSizeMismatch;
}

const Validator = struct {
    arena: std.mem.Allocator,
    module: *const Module,
    local_types: []const ValType,
    results: []const ValType,
    has_memory: bool,
    mem_addr: ValType, // i32, or i64 for a 64-bit memory
    declared_funcs: []const bool, // §3.4.1.3 ref.func reference set
    r: Reader, // over the body's expression bytes
    vals: std.ArrayListUnmanaged(AbsVal) = .empty,
    ctrls: std.ArrayListUnmanaged(Ctrl) = .empty,
    side_table: std.ArrayListUnmanaged(BranchEntry) = .empty,
    max_stack: u32 = 0,

    fn reachable(self: *Validator) bool {
        const c = &self.ctrls.items[self.ctrls.items.len - 1];
        return c.entered_reachable and !c.unreachable_;
    }

    fn pushVal(self: *Validator, t: AbsVal) !void {
        try self.vals.append(self.arena, t);
        self.max_stack = @max(self.max_stack, @as(u32, @intCast(self.vals.items.len)));
    }

    fn popVal(self: *Validator) !AbsVal {
        const c = &self.ctrls.items[self.ctrls.items.len - 1];
        if (self.vals.items.len == c.height) {
            if (c.unreachable_) return null; // polymorphic: yields Unknown
            return error.StackUnderflow;
        }
        return self.vals.pop().?;
    }

    fn popExpect(self: *Validator, expect: ValType) !void {
        const actual = try self.popVal();
        if (actual) |a| {
            if (a != expect) return error.TypeMismatch;
        }
    }

    fn popVals(self: *Validator, ts: []const ValType) !void {
        var i: usize = ts.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(ts[i]);
        }
    }

    fn pushVals(self: *Validator, ts: []const ValType) !void {
        for (ts) |t| try self.pushVal(t);
    }

    fn pushCtrl(self: *Validator, op: Op, in: []const ValType, out: []const ValType, start_ip: u32) !void {
        const parent_reachable = self.reachable();
        const c: Ctrl = .{
            .op = op,
            .start_types = in,
            .end_types = out,
            .height = @intCast(self.vals.items.len),
            .entered_reachable = parent_reachable,
            .start_ip = start_ip,
            .start_stp = @intCast(self.side_table.items.len),
        };
        try self.ctrls.append(self.arena, c);
        try self.pushVals(in);
    }

    fn popCtrl(self: *Validator) !Ctrl {
        if (self.ctrls.items.len == 0) return error.UnbalancedEnd;
        const c = self.ctrls.items[self.ctrls.items.len - 1];
        try self.popVals(c.end_types);
        if (self.vals.items.len != c.height) return error.TypeMismatch;
        _ = self.ctrls.pop();
        return c;
    }

    fn setUnreachable(self: *Validator) void {
        const c = &self.ctrls.items[self.ctrls.items.len - 1];
        self.vals.shrinkRetainingCapacity(c.height);
        c.unreachable_ = true;
    }

    /// Resolve the `n`-th enclosing label (0 = innermost).
    fn label(self: *Validator, n: u32) !*Ctrl {
        if (n >= self.ctrls.items.len) return error.UnknownLabel;
        return &self.ctrls.items[self.ctrls.items.len - 1 - n];
    }

    /// Emit a side-table entry for a reachable branch to `target`,
    /// returning its index (or null when the branch is in dead code).
    fn emitBranch(self: *Validator, branch_ip: u32, target: *Ctrl) !?u32 {
        const arity: u32 = @intCast(target.labelTypes().len);
        // popcnt: operands above the target label's height, minus the
        // carried arity. In reachable code the height is concrete.
        const height: u32 = @intCast(self.vals.items.len);
        const popcnt = height - target.height - arity;
        if (!self.reachable()) return null;
        const idx: u32 = @intCast(self.side_table.items.len);
        try self.side_table.append(self.arena, .{
            .delta_ip = 0,
            .delta_stp = 0,
            .val_count = arity,
            .pop_count = popcnt,
        });
        if (target.op == .loop) {
            // Backward target: resolve now.
            const e = &self.side_table.items[idx];
            e.delta_ip = @as(i32, @intCast(target.start_ip)) - @as(i32, @intCast(branch_ip));
            e.delta_stp = @as(i32, @intCast(target.start_stp)) - @as(i32, @intCast(idx));
        } else {
            // Forward target: patch at the construct's `end`.
            try target.pending.append(self.arena, .{ .entry = idx, .ip = branch_ip });
        }
        return idx;
    }

    /// Patch every forward branch that targeted a just-closed
    /// construct, given the position past its `end`.
    fn patchPending(self: *Validator, c: *Ctrl, after_end_ip: u32) void {
        const end_stp: u32 = @intCast(self.side_table.items.len);
        for (c.pending.items) |p| {
            const e = &self.side_table.items[p.entry];
            e.delta_ip = @as(i32, @intCast(after_end_ip)) - @as(i32, @intCast(p.ip));
            e.delta_stp = @as(i32, @intCast(end_stp)) - @as(i32, @intCast(p.entry));
        }
    }
};

fn validateFunc(
    arena: std.mem.Allocator,
    module: *const Module,
    type_index: u32,
    body_bytes: []const u8,
    declared: []const bool,
) ValidateError!CompiledFunc {
    const ft = module.types[type_index];

    // Parse the locals header (§5.5.13): vec((count, valtype)).
    var br = Reader.init(body_bytes);
    const group_count = try br.uleb(u32);
    var locals: std.ArrayListUnmanaged(ValType) = .empty;
    try locals.appendSlice(arena, ft.params);
    var g: u32 = 0;
    while (g < group_count) : (g += 1) {
        const n = try br.uleb(u32);
        const vt = ValType.fromByte(try br.byte()) orelse return error.BadValType;
        // Guard against a pathological local count blowing up memory.
        if (n > 1_000_000) return error.InvalidLocalCount;
        var k: u32 = 0;
        while (k < n) : (k += 1) try locals.append(arena, vt);
    }
    const local_types = try locals.toOwnedSlice(arena);
    const expr = body_bytes[br.pos..];

    var has_memory = false;
    var mem_addr: ValType = .i32;
    if (module.mems.len > 0) {
        has_memory = true;
        if (module.mems[0].limits.is_64) mem_addr = .i64;
    }
    for (module.imports) |imp| {
        if (imp.desc == .mem) {
            has_memory = true;
            if (imp.desc.mem.limits.is_64) mem_addr = .i64;
        }
    }

    var v: Validator = .{
        .arena = arena,
        .module = module,
        .local_types = local_types,
        .results = ft.results,
        .has_memory = has_memory,
        .mem_addr = mem_addr,
        .declared_funcs = declared,
        .r = Reader.init(expr),
    };

    // The implicit function-level block: its results are the function
    // results, and its `end` is the body's terminating `end`.
    try v.ctrls.append(arena, .{
        .op = .block,
        .start_types = &.{},
        .end_types = ft.results,
        .height = 0,
        .entered_reachable = true,
        .start_ip = 0,
        .start_stp = 0,
    });

    try validateExpr(&v);

    return .{
        .type_index = type_index,
        .local_types = local_types,
        .body = expr,
        .side_table = try v.side_table.toOwnedSlice(arena),
        .max_stack = v.max_stack,
    };
}

fn readBlockType(v: *Validator) !BlockType {
    // §5.3.2 — an s33: negative encodes empty (0x40) or a single
    // valtype; non-negative is a type index.
    const peek = try v.r.peek();
    if (peek == 0x40) {
        _ = try v.r.byte();
        return .{ .params = &.{}, .results = &.{} };
    }
    if (ValType.fromByte(peek)) |vt| {
        _ = try v.r.byte();
        const one = try v.arena.alloc(ValType, 1);
        one[0] = vt;
        return .{ .params = &.{}, .results = one };
    }
    const idx = try v.r.sleb(i33);
    if (idx < 0 or @as(u64, @intCast(idx)) >= v.module.types.len) return error.BadBlockType;
    const ft = v.module.types[@intCast(idx)];
    return .{ .params = ft.params, .results = ft.results };
}

/// Map an index in the function index space to its type signature,
/// accounting for imported functions preceding the defined ones.
fn funcType(module: *const Module, func_index: u32) !types.FuncType {
    var imported: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .func) {
            if (func_index == imported) {
                if (imp.desc.func >= module.types.len) return error.UnknownType;
                return module.types[imp.desc.func];
            }
            imported += 1;
        }
    }
    const local_index = func_index - imported;
    if (local_index >= module.funcs.len) return error.UnknownFunc;
    const ti = module.funcs[local_index];
    if (ti >= module.types.len) return error.UnknownType;
    return module.types[ti];
}

fn validateExpr(v: *Validator) ValidateError!void {
    while (true) {
        const op_ip: u32 = @intCast(v.r.pos);
        const op: Op = @enumFromInt(try v.r.byte());
        switch (op) {
            .nop => {},
            .@"unreachable" => v.setUnreachable(),

            .block, .loop => {
                const bt = try readBlockType(v);
                try v.popVals(bt.params);
                const body_ip: u32 = @intCast(v.r.pos);
                try v.pushCtrl(op, bt.params, bt.results, body_ip);
            },
            .@"if" => {
                const bt = try readBlockType(v);
                try v.popExpect(.i32); // condition
                try v.popVals(bt.params);
                const reachable_here = v.reachable();
                const body_ip: u32 = @intCast(v.r.pos);
                try v.pushCtrl(.@"if", bt.params, bt.results, body_ip);
                // The `if`'s false edge is a forward branch (to else or
                // end) carrying nothing: the params are already on the
                // stack as the block's operands.
                if (reachable_here) {
                    const idx: u32 = @intCast(v.side_table.items.len);
                    try v.side_table.append(v.arena, .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 });
                    const c = &v.ctrls.items[v.ctrls.items.len - 1];
                    c.if_entry = idx;
                    c.if_ip = op_ip;
                }
            },
            .@"else" => {
                var c = v.ctrls.items[v.ctrls.items.len - 1];
                if (c.op != .@"if") return error.UnexpectedElse;
                // Close the then-arm: it must have produced end_types.
                try v.popVals(c.end_types);
                if (v.vals.items.len != c.height) return error.TypeMismatch;
                // `else` is an unconditional forward branch to `end`,
                // carrying the block results.
                var else_entry: ?u32 = null;
                if (c.entered_reachable) {
                    else_entry = @intCast(v.side_table.items.len);
                    try v.side_table.append(v.arena, .{
                        .delta_ip = 0,
                        .delta_stp = 0,
                        .val_count = @intCast(c.end_types.len),
                        .pop_count = 0,
                    });
                    try c.pending.append(v.arena, .{ .entry = else_entry.?, .ip = op_ip });
                    // Resolve the `if`'s false edge to the else body.
                    if (c.if_entry) |ie| {
                        const else_body_ip: u32 = @intCast(v.r.pos);
                        const e = &v.side_table.items[ie];
                        e.delta_ip = @as(i32, @intCast(else_body_ip)) - @as(i32, @intCast(c.if_ip));
                        e.delta_stp = @as(i32, @intCast(else_entry.? + 1)) - @as(i32, @intCast(ie));
                    }
                }
                // Re-open as the else-arm: same label types, reachable
                // afresh, params back on the stack.
                c.op = .@"else";
                c.unreachable_ = false;
                c.if_entry = null;
                v.ctrls.items[v.ctrls.items.len - 1] = c;
                v.vals.shrinkRetainingCapacity(c.height);
                try v.pushVals(c.start_types);
            },
            .end => {
                var c = try v.popCtrl();
                const after_end_ip: u32 = @intCast(v.r.pos);
                // An `if` with no `else`: the empty else must map params
                // to results, so they must match.
                if (c.op == .@"if") {
                    if (!sameTypes(c.start_types, c.end_types)) return error.TypeMismatch;
                    // Resolve the `if`'s false edge straight to `end`.
                    if (c.if_entry) |ie| {
                        const e = &v.side_table.items[ie];
                        e.delta_ip = @as(i32, @intCast(after_end_ip)) - @as(i32, @intCast(c.if_ip));
                        e.delta_stp = @as(i32, @intCast(v.side_table.items.len)) - @as(i32, @intCast(ie));
                    }
                }
                v.patchPending(&c, after_end_ip);
                try v.pushVals(c.end_types);
                if (v.ctrls.items.len == 0) return; // function `end`
            },

            .br => {
                const n = try v.r.uleb(u32);
                const target = try v.label(n);
                _ = try v.emitBranch(op_ip, target);
                try v.popVals(target.labelTypes());
                v.setUnreachable();
            },
            .br_if => {
                const n = try v.r.uleb(u32);
                const target = try v.label(n);
                try v.popExpect(.i32); // condition
                _ = try v.emitBranch(op_ip, target);
                try v.popVals(target.labelTypes());
                try v.pushVals(target.labelTypes());
            },
            .br_table => {
                const count = try v.r.uleb(u32);
                const labels = try v.arena.alloc(u32, count);
                for (labels) |*l| l.* = try v.r.uleb(u32);
                const default_label = try v.r.uleb(u32);
                try v.popExpect(.i32); // index
                // One side-table entry per case, then the default — in
                // bytecode order, so the interpreter can index by case.
                for (labels) |l| {
                    _ = try v.emitBranch(op_ip, try v.label(l));
                }
                const def = try v.label(default_label);
                _ = try v.emitBranch(op_ip, def);
                // Every target must share the default's label arity.
                const def_arity = def.labelTypes().len;
                for (labels) |l| {
                    if ((try v.label(l)).labelTypes().len != def_arity) return error.TypeMismatch;
                }
                try v.popVals(def.labelTypes());
                v.setUnreachable();
            },
            .@"return" => {
                try v.popVals(v.results);
                v.setUnreachable();
            },
            .call => {
                const fidx = try v.r.uleb(u32);
                const ft = try funcType(v.module, fidx);
                try v.popVals(ft.params);
                try v.pushVals(ft.results);
            },
            .call_indirect => {
                const type_idx = try v.r.uleb(u32);
                const table_idx = try v.r.uleb(u32);
                // The table must exist and be funcref-typed; the element
                // index is that table's address type (i64 for a table64).
                const addr = try tableAddr(v.module, table_idx);
                if (try tableElemType(v.module, table_idx) != .funcref) return error.TypeMismatch;
                if (type_idx >= v.module.types.len) return error.UnknownType;
                const ft = v.module.types[type_idx];
                try v.popExpect(addr); // element index
                try v.popVals(ft.params);
                try v.pushVals(ft.results);
            },
            // Tail-call proposal: like `call` / `call_indirect`, but the
            // callee's results become this function's results, so they must
            // match — and control does not fall through (stack-polymorphic).
            .return_call => {
                const fidx = try v.r.uleb(u32);
                const ft = try funcType(v.module, fidx);
                try v.popVals(ft.params);
                if (!std.mem.eql(ValType, ft.results, v.results)) return error.TypeMismatch;
                v.setUnreachable();
            },
            .return_call_indirect => {
                const type_idx = try v.r.uleb(u32);
                const table_idx = try v.r.uleb(u32);
                const addr = try tableAddr(v.module, table_idx);
                if (try tableElemType(v.module, table_idx) != .funcref) return error.TypeMismatch;
                if (type_idx >= v.module.types.len) return error.UnknownType;
                const ft = v.module.types[type_idx];
                try v.popExpect(addr); // element index
                try v.popVals(ft.params);
                if (!std.mem.eql(ValType, ft.results, v.results)) return error.TypeMismatch;
                v.setUnreachable();
            },

            .select_t => {
                const n = try v.r.uleb(u32);
                if (n != 1) return error.TypeMismatch; // exactly one result type
                const t = ValType.fromByte(try v.r.byte()) orelse return error.BadValType;
                try v.popExpect(.i32);
                try v.popExpect(t);
                try v.popExpect(t);
                try v.pushVal(t);
            },

            .ref_null => {
                const rt = types.RefType.fromByte(try v.r.byte()) orelse return error.BadRefType;
                try v.pushVal(rt.toValType());
            },
            .ref_is_null => {
                try popRef(v);
                try v.pushVal(.i32);
            },
            .ref_func => {
                // §3.4.1.3 — the function must exist and be in the
                // module's reference set (declared outside a body).
                const fi = try v.r.uleb(u32);
                if (fi >= v.declared_funcs.len or !v.declared_funcs[fi]) return error.UnknownFunc;
                try v.pushVal(.funcref);
            },

            .table_get => {
                const idx = try v.r.uleb(u32);
                try v.popExpect(try tableAddr(v.module, idx));
                try v.pushVal(try tableElemType(v.module, idx));
            },
            .table_set => {
                const idx = try v.r.uleb(u32);
                try v.popExpect(try tableElemType(v.module, idx));
                try v.popExpect(try tableAddr(v.module, idx));
            },

            .drop => {
                _ = try v.popVal();
            },
            .select => {
                try v.popExpect(.i32);
                const a = try v.popVal();
                const b = try v.popVal();
                // Untyped select: operands must be a matching number
                // type (refs require the typed form, added later).
                const t = a orelse b;
                if (a != null and b != null and a.? != b.?) return error.TypeMismatch;
                if (t) |tt| {
                    if (!tt.isNum() and !tt.isVec()) return error.TypeMismatch;
                }
                try v.pushVal(t);
            },

            .local_get => {
                const x = try v.r.uleb(u32);
                if (x >= v.local_types.len) return error.UnknownLocal;
                try v.pushVal(v.local_types[x]);
            },
            .local_set => {
                const x = try v.r.uleb(u32);
                if (x >= v.local_types.len) return error.UnknownLocal;
                try v.popExpect(v.local_types[x]);
            },
            .local_tee => {
                const x = try v.r.uleb(u32);
                if (x >= v.local_types.len) return error.UnknownLocal;
                try v.popExpect(v.local_types[x]);
                try v.pushVal(v.local_types[x]);
            },
            .global_get => {
                const x = try v.r.uleb(u32);
                const gt = try globalType(v.module, x);
                try v.pushVal(gt.val);
            },
            .global_set => {
                const x = try v.r.uleb(u32);
                const gt = try globalType(v.module, x);
                if (gt.mut != .mutable) return error.ImmutableGlobal;
                try v.popExpect(gt.val);
            },

            .i32_const => {
                _ = try v.r.sleb(i32);
                try v.pushVal(.i32);
            },
            .i64_const => {
                _ = try v.r.sleb(i64);
                try v.pushVal(.i64);
            },

            .i32_eqz => try unop(v, .i32, .i32),
            .i64_eqz => try unop(v, .i64, .i32),

            .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => try binop(v, .i32, .i32),
            .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => try binop(v, .i64, .i32),

            .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => try binop(v, .i32, .i32),
            .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => try binop(v, .i64, .i64),

            // Integer unary (count bits) and sign extension.
            .i32_clz, .i32_ctz, .i32_popcnt, .i32_extend8_s, .i32_extend16_s => try unop(v, .i32, .i32),
            .i64_clz, .i64_ctz, .i64_popcnt, .i64_extend8_s, .i64_extend16_s, .i64_extend32_s => try unop(v, .i64, .i64),

            // Float constants.
            .f32_const => {
                _ = try v.r.bytesN(4);
                try v.pushVal(.f32);
            },
            .f64_const => {
                _ = try v.r.bytesN(8);
                try v.pushVal(.f64);
            },

            // Float comparisons → i32.
            .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => try binop(v, .f32, .i32),
            .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => try binop(v, .f64, .i32),

            // Float unary / binary arithmetic.
            .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => try unop(v, .f32, .f32),
            .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => try binop(v, .f32, .f32),
            .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => try unop(v, .f64, .f64),
            .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => try binop(v, .f64, .f64),

            // Conversions (§5.4.4) — each pops one value, pushes one.
            .i32_wrap_i64 => try unop(v, .i64, .i32),
            .i32_trunc_f32_s, .i32_trunc_f32_u => try unop(v, .f32, .i32),
            .i32_trunc_f64_s, .i32_trunc_f64_u => try unop(v, .f64, .i32),
            .i64_extend_i32_s, .i64_extend_i32_u => try unop(v, .i32, .i64),
            .i64_trunc_f32_s, .i64_trunc_f32_u => try unop(v, .f32, .i64),
            .i64_trunc_f64_s, .i64_trunc_f64_u => try unop(v, .f64, .i64),
            .f32_convert_i32_s, .f32_convert_i32_u => try unop(v, .i32, .f32),
            .f32_convert_i64_s, .f32_convert_i64_u => try unop(v, .i64, .f32),
            .f32_demote_f64 => try unop(v, .f64, .f32),
            .f64_convert_i32_s, .f64_convert_i32_u => try unop(v, .i32, .f64),
            .f64_convert_i64_s, .f64_convert_i64_u => try unop(v, .i64, .f64),
            .f64_promote_f32 => try unop(v, .f32, .f64),
            .i32_reinterpret_f32 => try unop(v, .f32, .i32),
            .i64_reinterpret_f64 => try unop(v, .f64, .i64),
            .f32_reinterpret_i32 => try unop(v, .i32, .f32),
            .f64_reinterpret_i64 => try unop(v, .i64, .f64),

            // Memory loads: pop the i32 address, push the result.
            .i32_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u => try load(v, .i32, op),
            .i64_load, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u => try load(v, .i64, op),
            .f32_load => try load(v, .f32, op),
            .f64_load => try load(v, .f64, op),
            // Memory stores: pop the value, then the i32 address.
            .i32_store, .i32_store8, .i32_store16 => try store(v, .i32, op),
            .i64_store, .i64_store8, .i64_store16, .i64_store32 => try store(v, .i64, op),
            .f32_store => try store(v, .f32, op),
            .f64_store => try store(v, .f64, op),

            .memory_size => {
                try requireMemory(v);
                _ = try v.r.byte(); // reserved memory index
                try v.pushVal(v.mem_addr);
            },
            .memory_grow => {
                try requireMemory(v);
                _ = try v.r.byte();
                try v.popExpect(v.mem_addr);
                try v.pushVal(v.mem_addr);
            },

            .prefix_fc => {
                const sub = try v.r.uleb(u32);
                switch (sub) {
                    10 => { // memory.copy
                        try requireMemory(v);
                        _ = try v.r.byte(); // dst memidx
                        _ = try v.r.byte(); // src memidx
                        try v.popExpect(v.mem_addr); // n
                        try v.popExpect(v.mem_addr); // src
                        try v.popExpect(v.mem_addr); // dst
                    },
                    11 => { // memory.fill
                        try requireMemory(v);
                        _ = try v.r.byte(); // memidx
                        try v.popExpect(v.mem_addr); // n
                        try v.popExpect(.i32); // value byte
                        try v.popExpect(v.mem_addr); // dst
                    },
                    8 => { // memory.init
                        try requireMemory(v);
                        try checkDataSeg(v, try v.r.uleb(u32)); // data segment index
                        _ = try v.r.byte(); // reserved memidx
                        try v.popExpect(.i32); // n
                        try v.popExpect(.i32); // src
                        try v.popExpect(v.mem_addr); // dst
                    },
                    9 => try checkDataSeg(v, try v.r.uleb(u32)), // data.drop

                    // Bulk table operations (reference-types).
                    12 => { // table.init
                        _ = try v.r.uleb(u32); // element segment index
                        const tidx = try v.r.uleb(u32);
                        try v.popExpect(.i32); // n
                        try v.popExpect(.i32); // src
                        try v.popExpect(try tableAddr(v.module, tidx)); // dst
                    },
                    13 => _ = try v.r.uleb(u32), // elem.drop
                    14 => { // table.copy
                        const dst_t = try v.r.uleb(u32);
                        const src_t = try v.r.uleb(u32);
                        try v.popExpect(try tableAddr(v.module, dst_t)); // n
                        try v.popExpect(try tableAddr(v.module, src_t)); // src
                        try v.popExpect(try tableAddr(v.module, dst_t)); // dst
                    },
                    15 => { // table.grow
                        const tidx = try v.r.uleb(u32);
                        try v.popExpect(try tableAddr(v.module, tidx)); // delta
                        try v.popExpect(try tableElemType(v.module, tidx)); // init
                        try v.pushVal(try tableAddr(v.module, tidx));
                    },
                    16 => { // table.size
                        const tidx = try v.r.uleb(u32);
                        try v.pushVal(try tableAddr(v.module, tidx));
                    },
                    17 => { // table.fill
                        const tidx = try v.r.uleb(u32);
                        try v.popExpect(try tableAddr(v.module, tidx)); // n
                        try v.popExpect(try tableElemType(v.module, tidx)); // value
                        try v.popExpect(try tableAddr(v.module, tidx)); // dst
                    },

                    // Saturating float→int truncations (non-trapping).
                    0 => try unop(v, .f32, .i32), // i32.trunc_sat_f32_s
                    1 => try unop(v, .f32, .i32), // i32.trunc_sat_f32_u
                    2 => try unop(v, .f64, .i32), // i32.trunc_sat_f64_s
                    3 => try unop(v, .f64, .i32), // i32.trunc_sat_f64_u
                    4 => try unop(v, .f32, .i64), // i64.trunc_sat_f32_s
                    5 => try unop(v, .f32, .i64), // i64.trunc_sat_f32_u
                    6 => try unop(v, .f64, .i64), // i64.trunc_sat_f64_s
                    7 => try unop(v, .f64, .i64), // i64.trunc_sat_f64_u
                    else => return error.UnknownOpcode,
                }
            },

            .prefix_fd => try validateSimd(v),

            _ => return error.UnknownOpcode,
        }
    }
}

/// Validate a `0xFD` SIMD instruction (the sub-opcode subset Sarcasm
/// implements). Lane immediates and the v128 literal are consumed here.
fn validateSimd(v: *Validator) !void {
    const sub = try v.r.uleb(u32);
    switch (sub) {
        0 => { // v128.load
            try requireMemory(v);
            try skipMemarg(v, simdMemAlign(sub));
            try v.popExpect(v.mem_addr);
            try v.pushVal(.v128);
        },
        11 => { // v128.store
            try requireMemory(v);
            try skipMemarg(v, simdMemAlign(sub));
            try v.popExpect(.v128);
            try v.popExpect(v.mem_addr);
        },
        12 => { // v128.const
            _ = try v.r.bytesN(16);
            try v.pushVal(.v128);
        },
        // splats: pop a scalar, push v128.
        15, 16, 17 => try unop(v, .i32, .v128),
        18 => try unop(v, .i64, .v128),
        19 => try unop(v, .f32, .v128),
        20 => try unop(v, .f64, .v128),
        // extract_lane (1-byte lane immediate, range-checked): pop v128, push scalar.
        21, 22 => {
            try checkLane(v, 16);
            try v.popExpect(.v128);
            try v.pushVal(.i32);
        },
        24, 25 => {
            try checkLane(v, 8);
            try v.popExpect(.v128);
            try v.pushVal(.i32);
        },
        27 => {
            try checkLane(v, 4);
            try v.popExpect(.v128);
            try v.pushVal(.i32);
        },
        29 => {
            try checkLane(v, 2);
            try v.popExpect(.v128);
            try v.pushVal(.i64);
        },
        31 => {
            try checkLane(v, 4);
            try v.popExpect(.v128);
            try v.pushVal(.f32);
        },
        33 => {
            try checkLane(v, 2);
            try v.popExpect(.v128);
            try v.pushVal(.f64);
        },
        // replace_lane (1-byte lane): pop scalar, pop v128, push v128.
        23 => {
            try checkLane(v, 16);
            try v.popExpect(.i32);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },
        26 => {
            try checkLane(v, 8);
            try v.popExpect(.i32);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },
        28 => {
            try checkLane(v, 4);
            try v.popExpect(.i32);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },
        30 => {
            try checkLane(v, 2);
            try v.popExpect(.i64);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },
        32 => {
            try checkLane(v, 4);
            try v.popExpect(.f32);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },
        34 => {
            try checkLane(v, 2);
            try v.popExpect(.f64);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },
        // lane-wise comparisons (35..76): v128, v128 -> v128.
        35...76 => try binop(v, .v128, .v128),
        77 => try unop(v, .v128, .v128), // v128.not
        78, 79, 80, 81 => try binop(v, .v128, .v128), // and/andnot/or/xor
        82 => { // v128.bitselect
            try v.popExpect(.v128);
            try v.popExpect(.v128);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },
        83 => try unop(v, .v128, .i32), // v128.any_true
        // unary v128 arithmetic (neg / abs / sqrt).
        97, 129, 161, 193, 224, 225, 227, 236, 237, 239 => try unop(v, .v128, .v128),
        // binary integer arithmetic (add / sub / mul).
        110, 113, 142, 145, 149, 174, 177, 181, 206, 209, 213 => try binop(v, .v128, .v128),
        // binary float arithmetic (add / sub / mul / div / min / max).
        228...233, 240...245 => try binop(v, .v128, .v128),
        // shifts: pop i32 count, pop v128, push v128.
        107, 108, 109, 139, 140, 141, 171, 172, 173, 203, 204, 205 => {
            try v.popExpect(.i32);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },

        // integer abs / popcnt, float rounding, conversions: v128 -> v128.
        96, 98, 128, 160, 192, 103, 104, 105, 106, 116, 117, 122, 148, 94, 95, 248, 249, 250, 251, 252, 253, 254, 255 => try unop(v, .v128, .v128),
        // all_true / bitmask: v128 -> i32.
        99, 100, 131, 132, 163, 164, 195, 196 => try unop(v, .v128, .i32),
        // integer min/max/avgr/sat, i64x2 compares, float pmin/pmax: v128, v128 -> v128.
        111, 112, 114, 115, 118, 119, 120, 121, 123, 143, 144, 146, 147, 150, 151, 152, 153, 155, 182, 183, 184, 185, 214, 215, 216, 217, 218, 219, 234, 235, 246, 247 => try binop(v, .v128, .v128),

        // i8x16.shuffle: 16-byte lane immediate, each lane < 32.
        13 => {
            const lanes = try v.r.bytesN(16);
            for (lanes) |l| {
                if (l >= 32) return error.BadLane;
            }
            try v.popExpect(.v128);
            try v.popExpect(.v128);
            try v.pushVal(.v128);
        },
        // swizzle, narrow, extmul, dot, q15mulr: v128, v128 -> v128.
        14, 101, 102, 133, 134, 156, 157, 158, 159, 188, 189, 190, 191, 220, 221, 222, 223, 186, 130 => try binop(v, .v128, .v128),
        // extend / extadd_pairwise: v128 -> v128.
        135, 136, 137, 138, 167, 168, 169, 170, 199, 200, 201, 202, 124, 125, 126, 127 => try unop(v, .v128, .v128),
        // load_splat / load_extend / load_zero: pop address (+ memarg), push v128.
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 92, 93 => {
            try requireMemory(v);
            try skipMemarg(v, simdMemAlign(sub));
            try v.popExpect(v.mem_addr);
            try v.pushVal(.v128);
        },
        // load_lane: memarg + range-checked lane; pop v128, pop addr, push v128.
        84, 85, 86, 87 => {
            try requireMemory(v);
            try skipMemarg(v, simdMemAlign(sub));
            try checkLane(v, laneCount(sub));
            try v.popExpect(.v128);
            try v.popExpect(v.mem_addr);
            try v.pushVal(.v128);
        },
        // store_lane: memarg + range-checked lane; pop v128, pop addr.
        88, 89, 90, 91 => {
            try requireMemory(v);
            try skipMemarg(v, simdMemAlign(sub));
            try checkLane(v, laneCount(sub));
            try v.popExpect(.v128);
            try v.popExpect(v.mem_addr);
        },

        else => return error.UnknownOpcode,
    }
}

fn requireMemory(v: *Validator) !void {
    if (!v.has_memory) return error.NoMemory;
}

/// Read a SIMD lane-index immediate and require it to be in range.
fn checkLane(v: *Validator, lane_count: u8) !void {
    if (try v.r.byte() >= lane_count) return error.BadLane;
}

/// §3.4.8 — `memory.init` / `data.drop` reference a data segment by
/// index. A data count section must be present and the index in range.
fn checkDataSeg(v: *Validator, idx: u32) !void {
    const count = v.module.data_count orelse return error.DataCountMissing;
    if (idx >= count) return error.UnknownDataSegment;
}

/// Lane count for a load_lane / store_lane sub-opcode (by access width).
fn laneCount(sub: u32) u8 {
    return switch (sub) {
        84, 88 => 16, // 8-bit
        85, 89 => 8, // 16-bit
        86, 90 => 4, // 32-bit
        87, 91 => 2, // 64-bit
        else => 16,
    };
}

fn load(v: *Validator, result: ValType, op: Op) !void {
    try requireMemory(v);
    try skipMemarg(v, memAlign(op));
    try v.popExpect(v.mem_addr); // address
    try v.pushVal(result);
}

fn store(v: *Validator, value: ValType, op: Op) !void {
    try requireMemory(v);
    try skipMemarg(v, memAlign(op));
    try v.popExpect(value); // value
    try v.popExpect(v.mem_addr); // address
}

fn skipMemarg(v: *Validator, max_align: u8) !void {
    // §3.3.6 — the alignment (log2 of bytes) may not exceed the access's
    // natural alignment.
    const a = try v.r.uleb(u32);
    if (a > max_align) return error.BadAlign;
    // The offset is a 64-bit immediate for a memory64 access.
    if (v.mem_addr == .i64) {
        _ = try v.r.uleb(u64);
    } else {
        _ = try v.r.uleb(u32);
    }
}

/// Natural alignment (log2 of the access width in bytes) of a scalar
/// load/store opcode.
fn memAlign(op: Op) u8 {
    return switch (op) {
        .i32_load8_s, .i32_load8_u, .i64_load8_s, .i64_load8_u, .i32_store8, .i64_store8 => 0,
        .i32_load16_s, .i32_load16_u, .i64_load16_s, .i64_load16_u, .i32_store16, .i64_store16 => 1,
        .i32_load, .f32_load, .i32_store, .f32_store, .i64_load32_s, .i64_load32_u, .i64_store32 => 2,
        .i64_load, .f64_load, .i64_store, .f64_store => 3,
        else => 0,
    };
}

/// Natural alignment (log2 bytes) of a SIMD memory sub-opcode.
fn simdMemAlign(sub: u32) u8 {
    return switch (sub) {
        0, 11 => 4, // v128.load / v128.store (16 bytes)
        1, 2, 3, 4, 5, 6 => 3, // load8x8 / load16x4 / load32x2 (8 bytes)
        7 => 0, // v128.load8_splat
        8 => 1, // v128.load16_splat
        9 => 2, // v128.load32_splat
        10 => 3, // v128.load64_splat
        92 => 2, // v128.load32_zero
        93 => 3, // v128.load64_zero
        84, 88 => 0, // load8_lane / store8_lane
        85, 89 => 1, // 16-bit lane
        86, 90 => 2, // 32-bit lane
        87, 91 => 3, // 64-bit lane
        else => 4,
    };
}

fn unop(v: *Validator, in: ValType, out: ValType) !void {
    try v.popExpect(in);
    try v.pushVal(out);
}

fn binop(v: *Validator, in: ValType, out: ValType) !void {
    try v.popExpect(in);
    try v.popExpect(in);
    try v.pushVal(out);
}

fn popRef(v: *Validator) !void {
    const actual = try v.popVal();
    if (actual) |a| {
        if (!a.isRef()) return error.TypeMismatch;
    }
}

/// The element (reference) type of a table in the table index space.
fn tableElemType(module: *const Module, table_index: u32) !ValType {
    var imported: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .table) {
            if (table_index == imported) return imp.desc.table.elem.toValType();
            imported += 1;
        }
    }
    const local_index = table_index - imported;
    if (local_index >= module.tables.len) return error.UnknownTable;
    return module.tables[local_index].elem.toValType();
}

/// The index type of a table — i64 for a 64-bit table, else i32.
fn tableAddr(module: *const Module, table_index: u32) !ValType {
    var imported: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .table) {
            if (table_index == imported) return if (imp.desc.table.limits.is_64) .i64 else .i32;
            imported += 1;
        }
    }
    const local_index = table_index - imported;
    if (local_index >= module.tables.len) return error.UnknownTable;
    return if (module.tables[local_index].limits.is_64) .i64 else .i32;
}

fn globalType(module: *const Module, global_index: u32) !types.GlobalType {
    var imported: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .global) {
            if (global_index == imported) return imp.desc.global;
            imported += 1;
        }
    }
    const local_index = global_index - imported;
    if (local_index >= module.globals.len) return error.UnknownGlobal;
    return module.globals[local_index].type;
}

fn sameTypes(a: []const ValType, b: []const ValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
