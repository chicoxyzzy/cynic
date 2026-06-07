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
    OutOfBoundsTableAccess,
    UndefinedElement,
    UninitializedElement,
    IndirectCallTypeMismatch,
    CallStackExhausted,
    ValueStackOverflow,
    UnsupportedImportCall,
    /// A JS-backed host import threw; the exception is pending on the
    /// realm and is re-raised at the wasm->JS boundary.
    HostThrew,
};

/// The null reference sentinel. A funcref always carries a non-null
/// instance pointer in its high bits, and host extern values are small,
/// so all-ones never collides with a real reference.
pub const REF_NULL: u128 = std.math.maxInt(u128);

/// A `funcref` cell encodes the function's *defining* instance in the
/// high 64 bits and its function-space index in the low 32. This makes
/// a funcref callable across module boundaries: a table shared between
/// instances may hold functions defined in either, and `call_indirect`
/// runs each in the instance it was defined in. (The low 32 bits remain
/// the bare function index, which the conformance harness compares.)
pub inline fn makeFuncRef(instance: *Instance, idx: u32) u128 {
    return (@as(u128, @intFromPtr(instance)) << 64) | idx;
}
pub inline fn funcRefInstance(ref: u128) *Instance {
    return @ptrFromInt(@as(usize, @truncate(ref >> 64)));
}
pub inline fn funcRefIndex(ref: u128) u32 {
    return @truncate(ref);
}

/// A table: a growable vector of references. (Holds opaque cells today;
/// once the JS API lands, externref cells carry JS values and Metla
/// scans them — see docs/wasm-engine.md.)
pub const Table = struct {
    elems: []u128,
    max: ?u64,
    is_64: bool = false,
};

/// A parsed element segment (for `table.init`). Active and declarative
/// segments arrive already dropped.
const ElemSegment = struct {
    values: []const u128,
    dropped: bool,
};

/// A parsed data segment (for `memory.init`). Active segments arrive
/// already dropped.
const DataSegment = struct {
    bytes: []const u8,
    dropped: bool,
};

pub const Error = TrapError || validator.ValidateError || error{ NoSuchExport, OutOfMemory };

const STACK_CELLS = 1 << 16;
const MAX_FRAMES = 1 << 12;
/// Implementation cap on table size (§4.5.4 allows growth to fail).
const MAX_TABLE_ELEMS = 1 << 24;

/// WebAssembly linear-memory page size (§2.5.2): 64 KiB.
pub const PAGE_SIZE = 1 << 16;

/// A runtime global cell. 128-bit to hold a `v128` (scalars use the
/// low bits).
const Global = struct {
    value: u128,
    mutable: bool,
};

/// A host (native) function backing a wasm import — `spectest.print` and
/// friends. Receives the marshalled argument cells (low bits hold
/// scalars) and fills `results`.
pub const HostFn = *const fn (ctx: ?*anyopaque, args: []const u128, results: []u128) TrapError!void;

/// A resolved function-import target: a wasm function living in some
/// (possibly other) instance, or a host callable. The function index
/// space of an importing module is `imported_funcs ++ funcs`.
pub const FuncRef = union(enum) {
    wasm: struct { instance: *Instance, func: *const CompiledFunc },
    host: struct { fn_ptr: HostFn, ctx: ?*anyopaque = null, params: u32, results: u32 },
};

/// Resolved imports handed to `instantiate` for cross-module linking.
/// Today only function imports are wired (the dominant linking case);
/// table/memory/global imports arrive alongside the host `spectest`
/// module.
pub const Imports = struct {
    funcs: []const FuncRef = &.{},
    /// Imported global values, in global-import declaration order. Each
    /// occupies the front of the importing module's global index space.
    globals: []const u128 = &.{},
    /// Source for the imported linear memory (snapshotted at instantiate).
    memory: ?*const Memory = null,
    /// Imported tables, in table-import order — the provider's own
    /// `*Table` (shared), so writes are mutually visible.
    tables: []const *Table = &.{},
};

/// Linear memory: a byte-addressable, page-granular buffer. (The
/// ArrayBuffer aliasing the JS API exposes arrives with that step;
/// here it is a plain owned buffer.)
pub const Memory = struct {
    data: []u8,
    max_pages: ?u64,
    is_64: bool = false,

    fn pages(self: *const Memory) u64 {
        return self.data.len / PAGE_SIZE;
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
    /// Resolved function imports (cross-module linking). Empty for a
    /// self-contained module. Index `i` is function-space index `i`.
    imported_funcs: []const FuncRef = &.{},
    /// The module's single linear memory (multi-memory is post-1.0).
    memory: ?Memory,
    /// The table index space: imported tables (shared pointers into the
    /// providing instance) followed by pointers into `owned_tables`.
    /// Tables are pointers so an imported table is genuinely shared —
    /// a write through one instance is visible through the other.
    tables: []*Table,
    /// Backing storage for this module's own (defined) tables, pointed
    /// into by the tail of `tables`.
    owned_tables: []Table,
    /// Passive/active element segments, in declaration order.
    elem_segments: []ElemSegment,
    /// Passive/active data segments, in declaration order.
    data_segments: []DataSegment,
    /// Owns `globals`, `memory.data`, and the table backing; used to
    /// grow and free them.
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Instance) void {
        self.gpa.free(self.globals);
        if (self.memory) |m| self.gpa.free(m.data);
        for (self.owned_tables) |t| self.gpa.free(t.elems);
        self.gpa.free(self.owned_tables);
        self.gpa.free(self.tables);
    }

    /// Read a global's raw cell by its index in the global index space
    /// (used by the conformance harness's `get` action). Returns null
    /// for an imported global, which is not yet wired.
    pub fn readGlobalByIndex(self: *const Instance, global_index: u32) ?u128 {
        // Imported globals occupy the front of the index space.
        if (global_index >= self.globals.len) return null;
        return self.globals[global_index].value;
    }

    /// Resolve a function-index-space entry to a defined function, or
    /// null if it names an import.
    fn definedFunc(self: *const Instance, func_index: u32) ?*const CompiledFunc {
        if (func_index < self.func_import_count) return null;
        const local = func_index - self.func_import_count;
        return &self.funcs[local];
    }

    /// Resolve a function-index-space entry to its call target, spanning
    /// imports (cross-module linking) and defined functions. Null on an
    /// out-of-range index (an import the harness could not link, or a
    /// bad index).
    fn resolveFunc(self: *Instance, func_index: u32) ?FuncRef {
        if (func_index < self.imported_funcs.len)
            return self.imported_funcs[func_index];
        const local = func_index - @as(u32, @intCast(self.imported_funcs.len));
        if (local >= self.funcs.len) return null;
        return .{ .wasm = .{ .instance = self, .func = &self.funcs[local] } };
    }

    /// Resolve a function-index-space entry to a callable `FuncRef`, for
    /// the JS API (importing one instance's exported function into
    /// another module).
    pub fn funcRefAt(self: *Instance, idx: u32) ?FuncRef {
        return self.resolveFunc(idx);
    }

    /// A pointer to the instance's live linear memory, for the JS API's
    /// `Memory` object (its `buffer` aliases these bytes).
    pub fn memoryPtr(self: *Instance) ?*Memory {
        if (self.memory) |*m| return m;
        return null;
    }

    /// The function type (params / results) of a function-index-space
    /// entry, spanning imports and defined functions. For the JS API's
    /// argument / result marshalling.
    pub fn funcType(self: *const Instance, func_index: u32) ?types.FuncType {
        var k: u32 = 0;
        for (self.module.imports) |imp| switch (imp.desc) {
            .func => |ti| {
                if (k == func_index) return self.module.types[ti];
                k += 1;
            },
            else => {},
        };
        const local = func_index - k;
        if (local >= self.module.funcs.len) return null;
        return self.module.types[self.module.funcs[local]];
    }

    /// The live (shared) table at `idx`, for the JS API's `Table` object
    /// — get / set / grow operate on the same elements wasm sees.
    pub fn tableRef(self: *Instance, idx: u32) ?*Table {
        if (idx >= self.tables.len) return null;
        return self.tables[idx];
    }

    /// A table's element reference type by index (imports first).
    pub fn tableElemType(self: *const Instance, idx: u32) ?types.RefType {
        var k: u32 = 0;
        for (self.module.imports) |imp| switch (imp.desc) {
            .table => |tt| {
                if (k == idx) return tt.elem;
                k += 1;
            },
            else => {},
        };
        const local = idx - k;
        if (local >= self.module.tables.len) return null;
        return self.module.tables[local].elem;
    }

    /// A pointer to a global's live operand cell (imports occupy the
    /// front of the index space), for the JS API's `Global.prototype.
    /// value` accessor — reads and writes are visible to wasm.
    pub fn globalCellPtr(self: *Instance, idx: u32) ?*u128 {
        if (idx >= self.globals.len) return null;
        return &self.globals[idx].value;
    }

    /// A global's declared type (value type + mutability) by index,
    /// spanning imports and defined globals.
    pub fn globalTypeAt(self: *const Instance, idx: u32) ?types.GlobalType {
        var k: u32 = 0;
        for (self.module.imports) |imp| switch (imp.desc) {
            .global => |gt| {
                if (k == idx) return gt;
                k += 1;
            },
            else => {},
        };
        const local = idx - k;
        if (local >= self.module.globals.len) return null;
        return self.module.globals[local].type;
    }

    /// Resolve an exported function by name to a callable `FuncRef`,
    /// for cross-module linking (the importing instance stores this as
    /// one of its `imported_funcs`). Null if there is no such function
    /// export.
    pub fn exportedFuncRef(self: *Instance, name: []const u8) ?FuncRef {
        for (self.module.exports) |ex| {
            switch (ex.desc) {
                .func => |idx| if (std.mem.eql(u8, ex.name, name)) return self.resolveFunc(idx),
                else => {},
            }
        }
        return null;
    }

    /// Read an exported global's current value by name, for a later
    /// module importing it (cross-module linking).
    pub fn exportedGlobalValue(self: *const Instance, name: []const u8) ?u128 {
        for (self.module.exports) |ex| {
            switch (ex.desc) {
                .global => |idx| if (std.mem.eql(u8, ex.name, name)) {
                    if (idx < self.globals.len) return self.globals[idx].value;
                },
                else => {},
            }
        }
        return null;
    }

    /// The exported linear memory named `name`, for a later module
    /// importing it (snapshotted by the importer).
    pub fn exportedMemory(self: *Instance, name: []const u8) ?*const Memory {
        for (self.module.exports) |ex| {
            switch (ex.desc) {
                .mem => if (std.mem.eql(u8, ex.name, name)) {
                    if (self.memory) |*m| return m;
                },
                else => {},
            }
        }
        return null;
    }

    /// The exported table named `name`, for a later module importing it.
    pub fn exportedTable(self: *Instance, name: []const u8) ?*Table {
        for (self.module.exports) |ex| {
            switch (ex.desc) {
                .table => |idx| if (std.mem.eql(u8, ex.name, name)) {
                    if (idx < self.tables.len) return self.tables[idx];
                },
                else => {},
            }
        }
        return null;
    }
};

/// Validate every function and lay out runtime state into `self` (which
/// must outlive the call at a stable address — funcrefs the module
/// creates capture `self`). `arena` owns the validated `CompiledFunc`s
/// for the instance's lifetime; `allocator` owns the mutable state.
pub fn instantiate(
    self: *Instance,
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    module: *const Module,
    imports: Imports,
) Error!void {
    const funcs = try validator.validateModule(arena, module);

    var func_imports: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .func) func_imports += 1;
    }

    // The global index space is imported globals followed by defined
    // ones; a defined initializer may `global.get` any earlier global.
    var glob_imports: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .global) glob_imports += 1;
    }
    const globals = try allocator.alloc(Global, glob_imports + module.globals.len);
    errdefer allocator.free(globals);
    {
        var k: usize = 0;
        for (module.imports) |imp| switch (imp.desc) {
            .global => |gt| {
                globals[k] = .{
                    .value = if (k < imports.globals.len) imports.globals[k] else 0,
                    .mutable = gt.mut == .mutable,
                };
                k += 1;
            },
            else => {},
        };
    }
    for (module.globals, 0..) |g, i| {
        const idx = glob_imports + i;
        globals[idx] = .{
            .value = evalConstExpr(g.init_expr, globals[0..idx]),
            .mutable = g.type.mut == .mutable,
        };
    }

    // The single linear memory (multi-memory is post-1.0): an imported
    // memory occupies memory index 0 and is snapshotted from the
    // provider; otherwise a defined memory is zero-filled to its minimum.
    var memory: ?Memory = null;
    var has_mem_import = false;
    for (module.imports) |imp| {
        if (imp.desc == .mem) {
            has_mem_import = true;
            break;
        }
    }
    if (has_mem_import) {
        if (imports.memory) |src| {
            memory = .{ .data = try allocator.dupe(u8, src.data), .max_pages = src.max_pages, .is_64 = src.is_64 };
        }
    } else if (module.mems.len > 0) {
        const lim = module.mems[0].limits;
        const bytes = try allocator.alloc(u8, @as(usize, @intCast(lim.min)) * PAGE_SIZE);
        @memset(bytes, 0);
        memory = .{ .data = bytes, .max_pages = lim.max, .is_64 = lim.is_64 };
    }

    // Defined tables, each sized to its minimum and null-filled.
    const owned_tables = try allocator.alloc(Table, module.tables.len);
    errdefer allocator.free(owned_tables);
    for (module.tables, 0..) |t, i| {
        const elems = try allocator.alloc(u128, @intCast(t.limits.min));
        @memset(elems, REF_NULL);
        owned_tables[i] = .{ .elems = elems, .max = t.limits.max, .is_64 = t.limits.is_64 };
    }

    // The table index space: imported tables (shared — the provider's
    // own `*Table`, so writes are mutually visible) precede pointers
    // into this module's `owned_tables`.
    var table_imports: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .table) table_imports += 1;
    }
    const tables = try allocator.alloc(*Table, table_imports + module.tables.len);
    errdefer allocator.free(tables);
    {
        var ti: usize = 0;
        var k: usize = 0;
        for (module.imports) |imp| {
            if (imp.desc != .table) continue;
            tables[ti] = imports.tables[k];
            ti += 1;
            k += 1;
        }
        for (owned_tables) |*t| {
            tables[ti] = t;
            ti += 1;
        }
    }

    self.* = .{
        .module = module,
        .funcs = funcs,
        .globals = globals,
        .func_import_count = func_imports,
        .imported_funcs = imports.funcs,
        .memory = memory,
        .tables = tables,
        .owned_tables = owned_tables,
        .elem_segments = &.{},
        .data_segments = &.{},
        .gpa = allocator,
    };

    // With `self` now stable, apply element + data segments. Element
    // funcrefs capture `self` as their defining instance.
    self.elem_segments = try parseElements(self, arena, module, globals);
    self.data_segments = try parseData(arena, module, if (self.memory) |*m| m else null, globals);
}

/// Parse the data section, applying active segments into linear memory
/// and returning the (passive-keeping) segments for `memory.init`.
fn parseData(arena: std.mem.Allocator, module: *const Module, memory: ?*Memory, globals: []const Global) Error![]DataSegment {
    const count = module.data_count_in_section;
    const segs = try arena.alloc(DataSegment, count);
    var r = reader_mod.Reader.init(module.data_raw);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flag = try r.uleb(u32);
        const is_active = (flag != 1); // flags 0 and 2 are active
        if (flag == 2) _ = try r.uleb(u32); // explicit memory index
        var offset: u64 = 0;
        if (is_active) offset = try readOffsetExpr(&r, globals);
        const n = try r.uleb(u32);
        const bytes = try r.bytesN(n);

        if (is_active) {
            const mem = memory orelse return error.OutOfBoundsMemoryAccess;
            const off: usize = @intCast(offset);
            if (off + n > mem.data.len) return error.OutOfBoundsMemoryAccess;
            @memcpy(mem.data[off..][0..n], bytes);
            segs[i] = .{ .bytes = &.{}, .dropped = true };
        } else {
            segs[i] = .{ .bytes = bytes, .dropped = false };
        }
    }
    return segs;
}

/// Parse the element section, applying active segments into the
/// instance's tables and returning the (passive-keeping) segments for
/// `table.init`. A `ref.func` element captures `self` as the funcref's
/// defining instance, so the function stays callable after the funcref
/// is copied into another module's table.
fn parseElements(self: *Instance, arena: std.mem.Allocator, module: *const Module, globals: []const Global) Error![]ElemSegment {
    const count = module.elements_count;
    const segs = try arena.alloc(ElemSegment, count);
    var r = reader_mod.Reader.init(module.elements_raw);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flag = try r.uleb(u32);
        const kind = flag & 3; // 0/2 active, 1 passive, 3 declarative
        const use_exprs = flag >= 4;
        const is_active = (kind == 0 or kind == 2);

        var table_idx: u32 = 0;
        if (kind == 2) table_idx = try r.uleb(u32);
        var offset: u64 = 0;
        if (is_active) offset = try readOffsetExpr(&r, globals);
        if (kind != 0) _ = try r.byte(); // elemkind / reftype

        const n = try r.uleb(u32);
        const values = try arena.alloc(u128, n);
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            values[j] = if (use_exprs)
                try readElemRefExpr(self, &r, globals)
            else
                makeFuncRef(self, try r.uleb(u32));
        }

        if (is_active) {
            if (table_idx >= self.tables.len) return error.UnsupportedImportCall;
            const table = self.tables[table_idx];
            const off: usize = @intCast(offset);
            if (off + n > table.elems.len) return error.OutOfBoundsTableAccess;
            @memcpy(table.elems[off..][0..n], values);
            segs[i] = .{ .values = &.{}, .dropped = true };
        } else if (kind == 3) {
            segs[i] = .{ .values = &.{}, .dropped = true };
        } else {
            segs[i] = .{ .values = values, .dropped = false };
        }
    }
    return segs;
}

/// Evaluate a single element reference expression — `ref.func` (encoding
/// `self`), `ref.null`, or `global.get` — consuming up to `end`.
fn readElemRefExpr(self: *Instance, r: *reader_mod.Reader, globals: []const Global) Error!u128 {
    const op: Op = @enumFromInt(try r.byte());
    var val: u128 = REF_NULL;
    switch (op) {
        .ref_func => val = makeFuncRef(self, try r.uleb(u32)),
        .ref_null => _ = try r.byte(), // reftype
        .global_get => {
            const gi = try r.uleb(u32);
            val = if (gi < globals.len) globals[gi].value else REF_NULL;
        },
        else => {},
    }
    _ = try r.byte(); // end
    return val;
}

/// Evaluate a constant expression (§3.3.7), consuming it from `r` up to
/// the terminating `end`. A small stack machine covering the constant
/// instruction set: the typed `*.const` forms, `ref.null` / `ref.func`,
/// `global.get` of an already-initialized (imported or earlier) global,
/// and the extended-const proposal's `i32`/`i64` `add` / `sub` / `mul`.
/// Returns the result as a raw cell (scalars in the low bits).
fn evalConstReader(r: *reader_mod.Reader, globals: []const Global) Error!u128 {
    var stack: [16]u128 = undefined;
    var sp: usize = 0;
    while (true) {
        const b = try r.byte();
        switch (b) {
            0x0b => break, // end
            0x41 => { // i32.const
                stack[sp] = @as(u32, @bitCast(try r.sleb(i32)));
                sp += 1;
            },
            0x42 => { // i64.const
                stack[sp] = @as(u64, @bitCast(try r.sleb(i64)));
                sp += 1;
            },
            0x43 => { // f32.const (4-byte little-endian pattern)
                const bytes = try r.bytesN(4);
                stack[sp] = std.mem.readInt(u32, bytes[0..4], .little);
                sp += 1;
            },
            0x44 => { // f64.const
                const bytes = try r.bytesN(8);
                stack[sp] = std.mem.readInt(u64, bytes[0..8], .little);
                sp += 1;
            },
            0x23 => { // global.get
                const gi = try r.uleb(u32);
                stack[sp] = if (gi < globals.len) globals[gi].value else 0;
                sp += 1;
            },
            0xd0 => { // ref.null
                _ = try r.byte(); // reftype
                stack[sp] = REF_NULL;
                sp += 1;
            },
            0xd2 => { // ref.func
                stack[sp] = try r.uleb(u32);
                sp += 1;
            },
            0x6a, 0x6b, 0x6c => { // i32.add / sub / mul
                sp -= 1;
                const y: u32 = @truncate(stack[sp]);
                const x: u32 = @truncate(stack[sp - 1]);
                stack[sp - 1] = switch (b) {
                    0x6a => x +% y,
                    0x6b => x -% y,
                    else => x *% y,
                };
            },
            0x7c, 0x7d, 0x7e => { // i64.add / sub / mul
                sp -= 1;
                const y: u64 = @truncate(stack[sp]);
                const x: u64 = @truncate(stack[sp - 1]);
                stack[sp - 1] = switch (b) {
                    0x7c => x +% y,
                    0x7d => x -% y,
                    else => x *% y,
                };
            },
            0xfd => { // v128.const (only constant 0xFD form)
                const sub = try r.uleb(u32);
                if (sub == 12) {
                    const bytes = try r.bytesN(16);
                    stack[sp] = std.mem.readInt(u128, bytes[0..16], .little);
                    sp += 1;
                }
            },
            else => {},
        }
        if (sp >= stack.len) return error.ValueStackOverflow;
    }
    return if (sp > 0) stack[sp - 1] else 0;
}

/// An active segment's offset is a constant expression yielding an
/// address (its low bits).
fn readOffsetExpr(r: *reader_mod.Reader, globals: []const Global) Error!u64 {
    return @truncate(try evalConstReader(r, globals));
}

/// Evaluate a global's constant initializer (§3.3.7) over the globals
/// initialized so far (imports + earlier defined globals).
fn evalConstExpr(expr: []const u8, globals: []const Global) u128 {
    var r = reader_mod.Reader.init(expr);
    return evalConstReader(&r, globals) catch 0;
}

const Frame = struct {
    func: *const CompiledFunc,
    /// The instance this frame executes in. Differs from the caller's
    /// for a cross-module (imported) call; the interpreter rebinds
    /// `Interp.instance` to it each time the active frame changes, so
    /// every memory / table / global access targets the right module.
    instance: *Instance,
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
    fn pushFrame(self: *Interp, instance: *Instance, func: *const CompiledFunc, param_count: u32) TrapError!void {
        if (self.nframes >= self.frames.len) return error.CallStackExhausted;
        const locals_base = self.sp - param_count;
        // Zero-init declared (non-parameter) locals.
        const total_locals: u32 = @intCast(func.local_types.len);
        var i = param_count;
        while (i < total_locals) : (i += 1) try self.pushCell(0);
        // Reserve operand headroom check.
        if (locals_base + total_locals + func.max_stack > self.stack.len)
            return error.ValueStackOverflow;
        const rc: u32 = @intCast(instance.module.types[func.type_index].results.len);
        self.frames[self.nframes] = .{
            .func = func,
            .instance = instance,
            .ip = 0,
            .stp = 0,
            .locals_base = locals_base,
            .result_count = rc,
        };
        self.nframes += 1;
    }

    /// Execute a host (imported native) function inline: pop its
    /// arguments, run it, push its results. No wasm frame is created.
    fn callHost(self: *Interp, h: anytype) TrapError!void {
        var argbuf: [16]u128 = undefined;
        var resbuf: [16]u128 = undefined;
        if (h.params > argbuf.len or h.results > resbuf.len)
            return error.UnsupportedImportCall;
        self.sp -= h.params;
        @memcpy(argbuf[0..h.params], self.stack[self.sp..][0..h.params]);
        try h.fn_ptr(h.ctx, argbuf[0..h.params], resbuf[0..h.results]);
        var i: u32 = 0;
        while (i < h.results) : (i += 1) try self.pushCell(resbuf[i]);
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
    const entry_ref = self.resolveFunc(func_index) orelse return error.UnsupportedImportCall;
    const entry = switch (entry_ref) {
        .wasm => |w| w.func,
        .host => return error.UnsupportedImportCall,
    };

    const stack = try allocator.alloc(Cell, STACK_CELLS);
    defer allocator.free(stack);
    const frames = try allocator.alloc(Frame, MAX_FRAMES);
    defer allocator.free(frames);

    var ip: Interp = .{ .instance = self, .stack = stack, .sp = 0, .frames = frames, .nframes = 0 };

    // Seed the entry function's parameters as its first locals.
    const param_count: u32 = @intCast(self.module.types[entry.type_index].params.len);
    if (args.len != param_count) return error.UnsupportedImportCall;
    for (args) |a| try ip.pushCell(a);
    try ip.pushFrame(self, entry, param_count);

    try run(&ip);

    // Results sit at the bottom of the stack after the final pop, one
    // 128-bit cell each (scalars in the low bits).
    const nres = ip.sp;
    const out = try allocator.alloc(u128, nres);
    @memcpy(out, ip.stack[0..nres]);
    return out;
}

/// Run the module's start function (§5.5.11), if any. Called once after
/// instantiation; a trap here means instantiation failed.
pub fn runStart(self: *Instance, allocator: std.mem.Allocator) Error!void {
    const idx = self.module.start orelse return;
    _ = try invoke(self, allocator, idx, &.{});
}

/// Read the opcode at `pc` and advance past it. `pc >= body.len` is the
/// function-level `end`: a `br` to the outermost block targets
/// `after_end == body.len` (see the validator's `patchPending`), and the
/// final `end` lands `pc` there too, so this synthesizes `.end` rather
/// than reading out of bounds. The `.end` arm distinguishes the
/// function end (`pc >= body.len`) from an interior block end.
inline fn nextOp(body: []const u8, pc: *usize) Op {
    if (pc.* >= body.len) return .end;
    const op: Op = @enumFromInt(body[pc.*]);
    pc.* += 1;
    return op;
}

fn run(ip: *Interp) Error!void {
    var f: *Frame = &ip.frames[ip.nframes - 1];
    // Threaded dispatch: every arm ends in `continue :dispatch
    // nextOp(...)`, so the compiler emits a separate indirect branch per
    // opcode site (the computed-goto equivalent) and the predictor learns
    // per-opcode-pair patterns instead of funnelling through one shared
    // dispatch. The frame-local cache (body / side_table / locals_base /
    // pc / stp and the active instance) is reloaded only at frame-swap
    // points (call / return / function end).
    ip.instance = f.instance;
    var body = f.func.body;
    var side_table = f.func.side_table;
    var locals_base = f.locals_base;
    var pc = f.ip;
    var stp = f.stp;

    dispatch: switch (nextOp(body, &pc)) {
        .nop => continue :dispatch nextOp(body, &pc),
        .end => {
            // The function-level end (and a `br` to the outermost block,
            // which lands at body.len) returns; an interior block end is
            // a no-op.
            if (pc >= body.len) {
                if (ip.popFrame()) return;
                f = &ip.frames[ip.nframes - 1];
                ip.instance = f.instance;
                body = f.func.body;
                side_table = f.func.side_table;
                locals_base = f.locals_base;
                pc = f.ip;
                stp = f.stp;
            }
            continue :dispatch nextOp(body, &pc);
        },
        .@"unreachable" => return error.Unreachable,

        .block, .loop => {
            pc = skipBlockType(body, pc);
            continue :dispatch nextOp(body, &pc);
        },
        .@"if" => {
            const op_ip = pc - 1;
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
            continue :dispatch nextOp(body, &pc);
        },
        .@"else" => {
            const op_ip = pc - 1;
            const e = side_table[stp];
            moveValues(ip, e);
            pc = @intCast(@as(i64, @intCast(op_ip)) + e.delta_ip);
            stp = @intCast(@as(i64, @intCast(stp)) + e.delta_stp);
            continue :dispatch nextOp(body, &pc);
        },
        .br => {
            const op_ip = pc - 1;
            const e = side_table[stp];
            moveValues(ip, e);
            pc = @intCast(@as(i64, @intCast(op_ip)) + e.delta_ip);
            stp = @intCast(@as(i64, @intCast(stp)) + e.delta_stp);
            continue :dispatch nextOp(body, &pc);
        },
        .br_if => {
            const op_ip = pc - 1;
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
            continue :dispatch nextOp(body, &pc);
        },
        .br_table => {
            const op_ip = pc - 1;
            const count = readU32(body, &pc);
            var i: u32 = 0;
            while (i < count) : (i += 1) _ = readU32(body, &pc); // case labels
            _ = readU32(body, &pc); // default label
            const index: u32 = @bitCast(ip.popI32());
            const sel = if (index < count) index else count;
            const entry_index = stp + sel;
            const e = side_table[entry_index];
            moveValues(ip, e);
            pc = @intCast(@as(i64, @intCast(op_ip)) + e.delta_ip);
            stp = @intCast(@as(i64, @intCast(entry_index)) + e.delta_stp);
            continue :dispatch nextOp(body, &pc);
        },
        .@"return" => {
            if (ip.popFrame()) return;
            f = &ip.frames[ip.nframes - 1];
            ip.instance = f.instance;
            body = f.func.body;
            side_table = f.func.side_table;
            locals_base = f.locals_base;
            pc = f.ip;
            stp = f.stp;
            continue :dispatch nextOp(body, &pc);
        },
        .call => {
            const fidx = readU32(body, &pc);
            const ref = ip.instance.resolveFunc(fidx) orelse return error.UnsupportedImportCall;
            switch (ref) {
                .host => |h| try ip.callHost(h), // no frame change
                .wasm => |w| {
                    const pcount: u32 = @intCast(w.instance.module.types[w.func.type_index].params.len);
                    f.ip = pc;
                    f.stp = stp;
                    try ip.pushFrame(w.instance, w.func, pcount);
                    f = &ip.frames[ip.nframes - 1];
                    ip.instance = f.instance;
                    body = f.func.body;
                    side_table = f.func.side_table;
                    locals_base = f.locals_base;
                    pc = f.ip;
                    stp = f.stp;
                },
            }
            continue :dispatch nextOp(body, &pc);
        },
        .call_indirect => {
            const type_idx = readU32(body, &pc);
            const table_idx = readU32(body, &pc);
            const elem_index: u64 = @truncate(ip.popCell());
            if (table_idx >= ip.instance.tables.len) return error.UnsupportedImportCall;
            const table = ip.instance.tables[table_idx];
            if (elem_index >= table.elems.len) return error.UndefinedElement;
            const ref = table.elems[elem_index];
            if (ref == REF_NULL) return error.UninitializedElement;
            // The funcref's defining instance is encoded in its high bits;
            // a bare index (high bits zero, e.g. from a funcref global)
            // defaults to the current instance.
            const fidx = funcRefIndex(ref);
            const def_inst = if (ref >> 64 == 0) ip.instance else funcRefInstance(ref);
            const target = def_inst.resolveFunc(fidx) orelse return error.UnsupportedImportCall;
            const expected = ip.instance.module.types[type_idx];
            switch (target) {
                .host => |h| {
                    if (expected.params.len != h.params or expected.results.len != h.results)
                        return error.IndirectCallTypeMismatch;
                    try ip.callHost(h);
                },
                .wasm => |w| {
                    const actual = w.instance.module.types[w.func.type_index];
                    if (!funcTypesEqual(expected, actual)) return error.IndirectCallTypeMismatch;
                    f.ip = pc;
                    f.stp = stp;
                    try ip.pushFrame(w.instance, w.func, @intCast(actual.params.len));
                    f = &ip.frames[ip.nframes - 1];
                    ip.instance = f.instance;
                    body = f.func.body;
                    side_table = f.func.side_table;
                    locals_base = f.locals_base;
                    pc = f.ip;
                    stp = f.stp;
                },
            }
            continue :dispatch nextOp(body, &pc);
        },

        .ref_null => {
            pc += 1; // reftype byte
            try ip.pushV128(REF_NULL);
            continue :dispatch nextOp(body, &pc);
        },
        .ref_is_null => {
            try ip.pushI32(@intFromBool(ip.popV128() == REF_NULL));
            continue :dispatch nextOp(body, &pc);
        },
        .ref_func => {
            try ip.pushV128(makeFuncRef(ip.instance, readU32(body, &pc)));
            continue :dispatch nextOp(body, &pc);
        },

        .select_t => {
            const n = readU32(body, &pc);
            pc += n; // skip the result-type vector
            const cond = ip.popI32();
            const b = ip.popCell();
            const a = ip.popCell();
            try ip.pushCell(if (cond != 0) a else b);
            continue :dispatch nextOp(body, &pc);
        },

        .table_get => {
            const tidx = readU32(body, &pc);
            const index: u64 = @truncate(ip.popCell());
            if (tidx >= ip.instance.tables.len) return error.UnsupportedImportCall;
            const table = ip.instance.tables[tidx];
            if (index >= table.elems.len) return error.OutOfBoundsTableAccess;
            try ip.pushV128(table.elems[@intCast(index)]);
            continue :dispatch nextOp(body, &pc);
        },
        .table_set => {
            const tidx = readU32(body, &pc);
            const val = ip.popV128();
            const index: u64 = @truncate(ip.popCell());
            if (tidx >= ip.instance.tables.len) return error.UnsupportedImportCall;
            const table = ip.instance.tables[tidx];
            if (index >= table.elems.len) return error.OutOfBoundsTableAccess;
            table.elems[@intCast(index)] = val;
            continue :dispatch nextOp(body, &pc);
        },

        .drop => {
            _ = ip.popCell();
            continue :dispatch nextOp(body, &pc);
        },
        .select => {
            const c = ip.popI32();
            const b = ip.popCell();
            const a = ip.popCell();
            try ip.pushCell(if (c != 0) a else b);
            continue :dispatch nextOp(body, &pc);
        },

        .local_get => {
            const x = readU32(body, &pc);
            try ip.pushCell(ip.stack[locals_base + x]);
            continue :dispatch nextOp(body, &pc);
        },
        .local_set => {
            const x = readU32(body, &pc);
            ip.stack[locals_base + x] = ip.popCell();
            continue :dispatch nextOp(body, &pc);
        },
        .local_tee => {
            const x = readU32(body, &pc);
            ip.stack[locals_base + x] = ip.stack[ip.sp - 1];
            continue :dispatch nextOp(body, &pc);
        },
        .global_get => {
            const x = readU32(body, &pc);
            try ip.pushCell(ip.instance.globals[x].value);
            continue :dispatch nextOp(body, &pc);
        },
        .global_set => {
            const x = readU32(body, &pc);
            ip.instance.globals[x].value = ip.popCell();
            continue :dispatch nextOp(body, &pc);
        },

        .i32_const => {
            try ip.pushI32(readI32(body, &pc));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_const => {
            try ip.pushI64(readI64(body, &pc));
            continue :dispatch nextOp(body, &pc);
        },

        .i32_eqz => {
            try ip.pushI32(@intFromBool(ip.popI32() == 0));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_eqz => {
            try ip.pushI32(@intFromBool(ip.popI64() == 0));
            continue :dispatch nextOp(body, &pc);
        },

        .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => |op| {
            const b = ip.popI32();
            const a = ip.popI32();
            try ip.pushI32(@intFromBool(compareI32(op, a, b)));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => |op| {
            const b = ip.popI64();
            const a = ip.popI64();
            try ip.pushI32(@intFromBool(compareI64(op, a, b)));
            continue :dispatch nextOp(body, &pc);
        },

        .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => |op| {
            const b = ip.popI32();
            const a = ip.popI32();
            try ip.pushI32(try arithI32(op, a, b));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => |op| {
            const b = ip.popI64();
            const a = ip.popI64();
            try ip.pushI64(try arithI64(op, a, b));
            continue :dispatch nextOp(body, &pc);
        },

        .i32_clz => {
            try ip.pushI32(@intCast(@clz(@as(u32, @bitCast(ip.popI32())))));
            continue :dispatch nextOp(body, &pc);
        },
        .i32_ctz => {
            try ip.pushI32(@intCast(@ctz(@as(u32, @bitCast(ip.popI32())))));
            continue :dispatch nextOp(body, &pc);
        },
        .i32_popcnt => {
            try ip.pushI32(@intCast(@popCount(@as(u32, @bitCast(ip.popI32())))));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_clz => {
            try ip.pushI64(@intCast(@clz(@as(u64, @bitCast(ip.popI64())))));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_ctz => {
            try ip.pushI64(@intCast(@ctz(@as(u64, @bitCast(ip.popI64())))));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_popcnt => {
            try ip.pushI64(@intCast(@popCount(@as(u64, @bitCast(ip.popI64())))));
            continue :dispatch nextOp(body, &pc);
        },
        .i32_extend8_s => {
            try ip.pushI32(@as(i8, @truncate(ip.popI32())));
            continue :dispatch nextOp(body, &pc);
        },
        .i32_extend16_s => {
            try ip.pushI32(@as(i16, @truncate(ip.popI32())));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_extend8_s => {
            try ip.pushI64(@as(i8, @truncate(ip.popI64())));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_extend16_s => {
            try ip.pushI64(@as(i16, @truncate(ip.popI64())));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_extend32_s => {
            try ip.pushI64(@as(i32, @truncate(ip.popI64())));
            continue :dispatch nextOp(body, &pc);
        },

        .f32_const => {
            try ip.pushF32(readF32(body, &pc));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_const => {
            try ip.pushF64(readF64(body, &pc));
            continue :dispatch nextOp(body, &pc);
        },

        .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => |op| {
            try ip.pushF32(floatUnop(f32, op, ip.popF32()));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => |op| {
            try ip.pushF64(floatUnop(f64, op, ip.popF64()));
            continue :dispatch nextOp(body, &pc);
        },
        .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => |op| {
            const b = ip.popF32();
            const a = ip.popF32();
            try ip.pushF32(floatBinop(f32, op, a, b));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => |op| {
            const b = ip.popF64();
            const a = ip.popF64();
            try ip.pushF64(floatBinop(f64, op, a, b));
            continue :dispatch nextOp(body, &pc);
        },
        .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => |op| {
            const b = ip.popF32();
            const a = ip.popF32();
            try ip.pushI32(@intFromBool(floatCmp(f32, op, a, b)));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => |op| {
            const b = ip.popF64();
            const a = ip.popF64();
            try ip.pushI32(@intFromBool(floatCmp(f64, op, a, b)));
            continue :dispatch nextOp(body, &pc);
        },

        .i32_wrap_i64 => {
            try ip.pushI32(@truncate(ip.popI64()));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_extend_i32_s => {
            try ip.pushI64(ip.popI32());
            continue :dispatch nextOp(body, &pc);
        },
        .i64_extend_i32_u => {
            try ip.pushI64(@bitCast(@as(u64, @as(u32, @bitCast(ip.popI32())))));
            continue :dispatch nextOp(body, &pc);
        },

        .i32_trunc_f32_s => {
            try ip.pushI32(try truncTrap(i32, f32, ip.popF32(), -2147483648.0, true, 2147483648.0));
            continue :dispatch nextOp(body, &pc);
        },
        .i32_trunc_f32_u => {
            try ip.pushI32(@bitCast(try truncTrap(u32, f32, ip.popF32(), -1.0, false, 4294967296.0)));
            continue :dispatch nextOp(body, &pc);
        },
        .i32_trunc_f64_s => {
            try ip.pushI32(try truncTrap(i32, f64, ip.popF64(), -2147483649.0, false, 2147483648.0));
            continue :dispatch nextOp(body, &pc);
        },
        .i32_trunc_f64_u => {
            try ip.pushI32(@bitCast(try truncTrap(u32, f64, ip.popF64(), -1.0, false, 4294967296.0)));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_trunc_f32_s => {
            try ip.pushI64(try truncTrap(i64, f32, ip.popF32(), -9223372036854775808.0, true, 9223372036854775808.0));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_trunc_f32_u => {
            try ip.pushI64(@bitCast(try truncTrap(u64, f32, ip.popF32(), -1.0, false, 18446744073709551616.0)));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_trunc_f64_s => {
            try ip.pushI64(try truncTrap(i64, f64, ip.popF64(), -9223372036854775808.0, true, 9223372036854775808.0));
            continue :dispatch nextOp(body, &pc);
        },
        .i64_trunc_f64_u => {
            try ip.pushI64(@bitCast(try truncTrap(u64, f64, ip.popF64(), -1.0, false, 18446744073709551616.0)));
            continue :dispatch nextOp(body, &pc);
        },

        .f32_convert_i32_s => {
            try ip.pushF32(@floatFromInt(ip.popI32()));
            continue :dispatch nextOp(body, &pc);
        },
        .f32_convert_i32_u => {
            try ip.pushF32(@floatFromInt(@as(u32, @bitCast(ip.popI32()))));
            continue :dispatch nextOp(body, &pc);
        },
        .f32_convert_i64_s => {
            try ip.pushF32(@floatFromInt(ip.popI64()));
            continue :dispatch nextOp(body, &pc);
        },
        .f32_convert_i64_u => {
            try ip.pushF32(@floatFromInt(@as(u64, @bitCast(ip.popI64()))));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_convert_i32_s => {
            try ip.pushF64(@floatFromInt(ip.popI32()));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_convert_i32_u => {
            try ip.pushF64(@floatFromInt(@as(u32, @bitCast(ip.popI32()))));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_convert_i64_s => {
            try ip.pushF64(@floatFromInt(ip.popI64()));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_convert_i64_u => {
            try ip.pushF64(@floatFromInt(@as(u64, @bitCast(ip.popI64()))));
            continue :dispatch nextOp(body, &pc);
        },
        .f32_demote_f64 => {
            try ip.pushF32(@floatCast(ip.popF64()));
            continue :dispatch nextOp(body, &pc);
        },
        .f64_promote_f32 => {
            try ip.pushF64(@floatCast(ip.popF32()));
            continue :dispatch nextOp(body, &pc);
        },

        // Reinterpret is a bit-identity on the untyped cell.
        .i32_reinterpret_f32, .i64_reinterpret_f64, .f32_reinterpret_i32, .f64_reinterpret_i64 => continue :dispatch nextOp(body, &pc),

        .i32_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u, .i64_load, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u, .f32_load, .f64_load => |op| {
            const ea = memEa(ip, body, &pc);
            try execLoad(ip, op, ea);
            continue :dispatch nextOp(body, &pc);
        },
        .i32_store, .i32_store8, .i32_store16, .i64_store, .i64_store8, .i64_store16, .i64_store32, .f32_store, .f64_store => |op| {
            try execStore(ip, op, body, &pc);
            continue :dispatch nextOp(body, &pc);
        },
        .memory_size => {
            pc += 1; // reserved memory index
            const mem = ip.instance.memory.?;
            if (mem.is_64) try ip.pushI64(@bitCast(mem.pages())) else try ip.pushI32(@intCast(mem.pages()));
            continue :dispatch nextOp(body, &pc);
        },
        .memory_grow => {
            pc += 1; // reserved memory index
            try memGrow(ip);
            continue :dispatch nextOp(body, &pc);
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
                8 => { // memory.init
                    const data_idx = readU32(body, &pc);
                    pc += 1; // reserved memidx
                    try memInit(ip, data_idx);
                },
                9 => { // data.drop
                    const data_idx = readU32(body, &pc);
                    if (data_idx < ip.instance.data_segments.len) {
                        ip.instance.data_segments[data_idx].dropped = true;
                        ip.instance.data_segments[data_idx].bytes = &.{};
                    }
                },
                12 => { // table.init
                    const elem_idx = readU32(body, &pc);
                    const tidx = readU32(body, &pc);
                    try tableInit(ip, elem_idx, tidx);
                },
                13 => { // elem.drop
                    const elem_idx = readU32(body, &pc);
                    if (elem_idx < ip.instance.elem_segments.len) {
                        ip.instance.elem_segments[elem_idx].dropped = true;
                        ip.instance.elem_segments[elem_idx].values = &.{};
                    }
                },
                14 => { // table.copy
                    const dst_t = readU32(body, &pc);
                    const src_t = readU32(body, &pc);
                    try tableCopy(ip, dst_t, src_t);
                },
                15 => { // table.grow
                    const tidx = readU32(body, &pc);
                    try tableGrow(ip, tidx);
                },
                16 => { // table.size
                    const tidx = readU32(body, &pc);
                    if (tidx >= ip.instance.tables.len) return error.UnsupportedImportCall;
                    const table = ip.instance.tables[tidx];
                    if (table.is_64) try ip.pushI64(@intCast(table.elems.len)) else try ip.pushI32(@intCast(table.elems.len));
                },
                17 => { // table.fill
                    const tidx = readU32(body, &pc);
                    try tableFill(ip, tidx);
                },
                // Saturating float->int truncations.
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
            continue :dispatch nextOp(body, &pc);
        },
        .prefix_fd => {
            const sub = readU32(body, &pc);
            try execSimd(ip, sub, body, &pc);
            continue :dispatch nextOp(body, &pc);
        },

        else => return error.UnsupportedImportCall, // unreachable: validation rejects
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
    const is_64 = if (ip.instance.memory) |m| m.is_64 else false;
    const offset: u64 = if (is_64) readU64(body, pc) else readU32(body, pc);
    // The i32 address zero-extends in its cell, so reading the low 64
    // bits gives the correct unsigned address for both 32- and 64-bit
    // memories. Saturate on overflow so an oversized effective address
    // fails the bounds check rather than wrapping.
    const addr: u64 = @truncate(ip.popCell());
    return std.math.add(u64, addr, offset) catch std.math.maxInt(u64);
}

/// Overflow-safe `[start, start+n)` ⊆ `[0, len)`. memory64/table64
/// operands can be near 2^64, so `start + n` must not be computed
/// directly.
inline fn rangeInBounds(len: usize, start: u64, n: u64) bool {
    if (start > len) return false;
    return n <= @as(u64, len) - start;
}

inline fn checkBounds(len: usize, ea: u64, n: u64) TrapError!void {
    if (!rangeInBounds(len, ea, n)) return error.OutOfBoundsMemoryAccess;
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

/// memory.grow: pushes the previous page count, or -1, with the result
/// width matching the memory's address type (§4.4.7).
fn memGrow(ip: *Interp) TrapError!void {
    const delta: u64 = @truncate(ip.popCell());
    const mem = &ip.instance.memory.?;
    const result = growMem(ip, mem, delta);
    if (mem.is_64) {
        try ip.pushI64(if (result) |r| @bitCast(r) else -1);
    } else {
        try ip.pushI32(if (result) |r| @intCast(r) else -1);
    }
}

fn growMem(ip: *Interp, mem: *Memory, delta: u64) ?u64 {
    const old = mem.pages();
    const new_pages: u64 = old + delta;
    if (new_pages > 65536) return null; // hard cap (4 GiB) bounds allocation
    if (mem.max_pages) |mx| {
        if (new_pages > mx) return null;
    }
    const old_len = mem.data.len;
    const grown = ip.instance.gpa.realloc(mem.data, @as(usize, @intCast(new_pages)) * PAGE_SIZE) catch return null;
    @memset(grown[old_len..], 0);
    mem.data = grown;
    return old;
}

fn memCopy(ip: *Interp) TrapError!void {
    const n: u64 = @truncate(ip.popCell());
    const src: u64 = @truncate(ip.popCell());
    const dst: u64 = @truncate(ip.popCell());
    const data = ip.instance.memory.?.data;
    try checkBounds(data.len, src, n);
    try checkBounds(data.len, dst, n);
    if (n == 0) return;
    const d: usize = @intCast(dst);
    const s: usize = @intCast(src);
    const cnt: usize = @intCast(n);
    if (dst <= src) {
        var i: usize = 0;
        while (i < cnt) : (i += 1) data[d + i] = data[s + i];
    } else {
        var i: usize = cnt;
        while (i > 0) {
            i -= 1;
            data[d + i] = data[s + i];
        }
    }
}

fn memFill(ip: *Interp) TrapError!void {
    const n: u64 = @truncate(ip.popCell());
    const val: u32 = @bitCast(ip.popI32());
    const dst: u64 = @truncate(ip.popCell());
    const data = ip.instance.memory.?.data;
    try checkBounds(data.len, dst, n);
    if (n == 0) return;
    @memset(data[@intCast(dst)..][0..@intCast(n)], @truncate(val));
}

fn memInit(ip: *Interp, data_idx: u32) TrapError!void {
    const n: u32 = @bitCast(ip.popI32());
    const src: u32 = @bitCast(ip.popI32());
    const dst: u64 = @truncate(ip.popCell());
    if (data_idx >= ip.instance.data_segments.len) return error.OutOfBoundsMemoryAccess;
    const seg = ip.instance.data_segments[data_idx].bytes;
    const mem = ip.instance.memory orelse return error.OutOfBoundsMemoryAccess;
    if (!rangeInBounds(seg.len, src, n) or !rangeInBounds(mem.data.len, dst, n)) return error.OutOfBoundsMemoryAccess;
    const base: usize = @intCast(dst);
    var k: u32 = 0;
    while (k < n) : (k += 1) mem.data[base + k] = seg[src + k];
}

// ── tables ──────────────────────────────────────────────────────────

fn funcTypesEqual(a: types.FuncType, b: types.FuncType) bool {
    if (a.params.len != b.params.len or a.results.len != b.results.len) return false;
    for (a.params, b.params) |x, y| if (x != y) return false;
    for (a.results, b.results) |x, y| if (x != y) return false;
    return true;
}

fn tableInit(ip: *Interp, elem_idx: u32, tidx: u32) TrapError!void {
    const n: u32 = @bitCast(ip.popI32());
    const src: u32 = @bitCast(ip.popI32());
    const dst: u64 = @truncate(ip.popCell());
    if (tidx >= ip.instance.tables.len or elem_idx >= ip.instance.elem_segments.len) return error.UnsupportedImportCall;
    const table = ip.instance.tables[tidx];
    const vals = ip.instance.elem_segments[elem_idx].values;
    if (!rangeInBounds(vals.len, src, n) or !rangeInBounds(table.elems.len, dst, n)) return error.OutOfBoundsTableAccess;
    const base: usize = @intCast(dst);
    var k: u32 = 0;
    while (k < n) : (k += 1) table.elems[base + k] = vals[src + k];
}

fn tableCopy(ip: *Interp, dst_t: u32, src_t: u32) TrapError!void {
    const n: u64 = @truncate(ip.popCell());
    const src: u64 = @truncate(ip.popCell());
    const dst: u64 = @truncate(ip.popCell());
    if (dst_t >= ip.instance.tables.len or src_t >= ip.instance.tables.len) return error.UnsupportedImportCall;
    const dtable = ip.instance.tables[dst_t];
    const stable = ip.instance.tables[src_t];
    if (!rangeInBounds(stable.elems.len, src, n) or !rangeInBounds(dtable.elems.len, dst, n)) return error.OutOfBoundsTableAccess;
    if (n == 0) return;
    const d: usize = @intCast(dst);
    const s: usize = @intCast(src);
    const cnt: usize = @intCast(n);
    if (dst <= src) {
        var k: usize = 0;
        while (k < cnt) : (k += 1) dtable.elems[d + k] = stable.elems[s + k];
    } else {
        var k: usize = cnt;
        while (k > 0) {
            k -= 1;
            dtable.elems[d + k] = stable.elems[s + k];
        }
    }
}

fn tableGrow(ip: *Interp, tidx: u32) TrapError!void {
    const n: u64 = @truncate(ip.popCell());
    const init_val = ip.popV128();
    if (tidx >= ip.instance.tables.len) return error.UnsupportedImportCall;
    const table = ip.instance.tables[tidx];
    const result = growTable(ip, table, n, init_val);
    if (table.is_64) {
        try ip.pushI64(if (result) |r| @intCast(r) else -1);
    } else {
        try ip.pushI32(if (result) |r| @intCast(r) else -1);
    }
}

fn growTable(ip: *Interp, table: *Table, n: u64, init_val: u128) ?u64 {
    const old: u64 = table.elems.len;
    const new_len: u64 = old + n;
    // §4.5.4 permits growth to fail for any implementation limit; cap
    // well below the point where a huge request would lazily "succeed"
    // and fault on first touch.
    if (new_len > MAX_TABLE_ELEMS) return null;
    if (table.max) |mx| {
        if (new_len > mx) return null;
    }
    const grown = ip.instance.gpa.realloc(table.elems, @intCast(new_len)) catch return null;
    for (grown[@intCast(old)..]) |*e| e.* = init_val;
    table.elems = grown;
    return old;
}

fn tableFill(ip: *Interp, tidx: u32) TrapError!void {
    const n: u64 = @truncate(ip.popCell());
    const val = ip.popV128();
    const dst: u64 = @truncate(ip.popCell());
    if (tidx >= ip.instance.tables.len) return error.UnsupportedImportCall;
    const table = ip.instance.tables[tidx];
    if (!rangeInBounds(table.elems.len, dst, n)) return error.OutOfBoundsTableAccess;
    const base: usize = @intCast(dst);
    var k: usize = 0;
    while (k < n) : (k += 1) table.elems[base + k] = val;
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

fn readU64(body: []const u8, pc: *usize) u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const b = body[pc.*];
        pc.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
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
    // Sign-extend only when there is room: at the final byte of a
    // 5-byte i32 LEB the value already fills 32 bits (shift == 28).
    if (shift < 25 and (b & 0x40) != 0) result |= @as(i32, -1) << (shift + 7);
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
    if (shift < 57 and (b & 0x40) != 0) result |= @as(i64, -1) << @as(u6, @intCast(shift + 7));
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

        // shuffle / swizzle
        13 => {
            var lanes: [16]u8 = undefined;
            @memcpy(&lanes, body[pc.*..][0..16]);
            pc.* += 16;
            const b = ip.popV128();
            const a = ip.popV128();
            const aa: [16]u8 = @bitCast(a);
            const bb: [16]u8 = @bitCast(b);
            var r: [16]u8 = undefined;
            inline for (0..16) |i| {
                const idx = lanes[i];
                r[i] = if (idx < 16) aa[idx] else bb[idx - 16];
            }
            try ip.pushV128(@bitCast(r));
        },
        14 => {
            const s = ip.popV128();
            const a = ip.popV128();
            const aa: [16]u8 = @bitCast(a);
            const ss: [16]u8 = @bitCast(s);
            var r: [16]u8 = undefined;
            inline for (0..16) |i| {
                const idx = ss[i];
                r[i] = if (idx < 16) aa[idx] else 0;
            }
            try ip.pushV128(@bitCast(r));
        },

        // narrow (saturating)
        101 => try ip.pushV128(vnarrow(ip, 8, i16, i8)),
        102 => try ip.pushV128(vnarrow(ip, 8, i16, u8)),
        133 => try ip.pushV128(vnarrow(ip, 4, i32, i16)),
        134 => try ip.pushV128(vnarrow(ip, 4, i32, u16)),

        // extend (low/high, signed/unsigned)
        135 => try ip.pushV128(vextend(16, i8, i16, false, ip.popV128())),
        136 => try ip.pushV128(vextend(16, i8, i16, true, ip.popV128())),
        137 => try ip.pushV128(vextend(16, u8, u16, false, ip.popV128())),
        138 => try ip.pushV128(vextend(16, u8, u16, true, ip.popV128())),
        167 => try ip.pushV128(vextend(8, i16, i32, false, ip.popV128())),
        168 => try ip.pushV128(vextend(8, i16, i32, true, ip.popV128())),
        169 => try ip.pushV128(vextend(8, u16, u32, false, ip.popV128())),
        170 => try ip.pushV128(vextend(8, u16, u32, true, ip.popV128())),
        199 => try ip.pushV128(vextend(4, i32, i64, false, ip.popV128())),
        200 => try ip.pushV128(vextend(4, i32, i64, true, ip.popV128())),
        201 => try ip.pushV128(vextend(4, u32, u64, false, ip.popV128())),
        202 => try ip.pushV128(vextend(4, u32, u64, true, ip.popV128())),

        // extmul (low/high, signed/unsigned)
        156 => try ip.pushV128(vextmul(ip, 16, i8, i16, false)),
        157 => try ip.pushV128(vextmul(ip, 16, i8, i16, true)),
        158 => try ip.pushV128(vextmul(ip, 16, u8, u16, false)),
        159 => try ip.pushV128(vextmul(ip, 16, u8, u16, true)),
        188 => try ip.pushV128(vextmul(ip, 8, i16, i32, false)),
        189 => try ip.pushV128(vextmul(ip, 8, i16, i32, true)),
        190 => try ip.pushV128(vextmul(ip, 8, u16, u32, false)),
        191 => try ip.pushV128(vextmul(ip, 8, u16, u32, true)),
        220 => try ip.pushV128(vextmul(ip, 4, i32, i64, false)),
        221 => try ip.pushV128(vextmul(ip, 4, i32, i64, true)),
        222 => try ip.pushV128(vextmul(ip, 4, u32, u64, false)),
        223 => try ip.pushV128(vextmul(ip, 4, u32, u64, true)),

        // extadd_pairwise
        124 => try ip.pushV128(vextadd(16, i8, i16, ip.popV128())),
        125 => try ip.pushV128(vextadd(16, u8, u16, ip.popV128())),
        126 => try ip.pushV128(vextadd(8, i16, i32, ip.popV128())),
        127 => try ip.pushV128(vextadd(8, u16, u32, ip.popV128())),

        // i32x4.dot_i16x8_s
        186 => {
            const b = ip.popV128();
            const a = ip.popV128();
            const aa: [8]i16 = @bitCast(a);
            const bb: [8]i16 = @bitCast(b);
            var r: [4]i32 = undefined;
            inline for (0..4) |j| {
                r[j] = @as(i32, aa[2 * j]) * @as(i32, bb[2 * j]) + @as(i32, aa[2 * j + 1]) * @as(i32, bb[2 * j + 1]);
            }
            try ip.pushV128(@bitCast(r));
        },
        // i16x8.q15mulr_sat_s
        130 => {
            const b = ip.popV128();
            const a = ip.popV128();
            const aa: [8]i16 = @bitCast(a);
            const bb: [8]i16 = @bitCast(b);
            var r: [8]i16 = undefined;
            inline for (0..8) |i| {
                const prod: i32 = (@as(i32, aa[i]) * @as(i32, bb[i]) + 0x4000) >> 15;
                r[i] = if (prod > 32767) 32767 else if (prod < -32768) -32768 else @intCast(prod);
            }
            try ip.pushV128(@bitCast(r));
        },

        // load_splat / load_extend / load_zero
        7 => try ip.pushV128(try loadSplat(ip, body, pc, 16, u8)),
        8 => try ip.pushV128(try loadSplat(ip, body, pc, 8, u16)),
        9 => try ip.pushV128(try loadSplat(ip, body, pc, 4, u32)),
        10 => try ip.pushV128(try loadSplat(ip, body, pc, 2, u64)),
        1 => try ip.pushV128(try loadExtend(ip, body, pc, 8, i8, i16)),
        2 => try ip.pushV128(try loadExtend(ip, body, pc, 8, u8, u16)),
        3 => try ip.pushV128(try loadExtend(ip, body, pc, 4, i16, i32)),
        4 => try ip.pushV128(try loadExtend(ip, body, pc, 4, u16, u32)),
        5 => try ip.pushV128(try loadExtend(ip, body, pc, 2, i32, i64)),
        6 => try ip.pushV128(try loadExtend(ip, body, pc, 2, u32, u64)),
        92 => try ip.pushV128(try loadZero(ip, body, pc, 4)),
        93 => try ip.pushV128(try loadZero(ip, body, pc, 8)),

        // load_lane / store_lane
        84 => try ip.pushV128(try loadLane(ip, body, pc, 16, u8)),
        85 => try ip.pushV128(try loadLane(ip, body, pc, 8, u16)),
        86 => try ip.pushV128(try loadLane(ip, body, pc, 4, u32)),
        87 => try ip.pushV128(try loadLane(ip, body, pc, 2, u64)),
        88 => try storeLane(ip, body, pc, 16, u8),
        89 => try storeLane(ip, body, pc, 8, u16),
        90 => try storeLane(ip, body, pc, 4, u32),
        91 => try storeLane(ip, body, pc, 2, u64),

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

fn satNarrow(comptime Src: type, comptime Dst: type, x: Src) Dst {
    const lo = std.math.minInt(Dst);
    const hi = std.math.maxInt(Dst);
    if (x < lo) return lo;
    if (x > hi) return hi;
    return @intCast(x);
}

fn vnarrow(ip: *Interp, comptime SrcN: usize, comptime Src: type, comptime Dst: type) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const aa: [SrcN]Src = @bitCast(a);
    const bb: [SrcN]Src = @bitCast(b);
    var r: [SrcN * 2]Dst = undefined;
    inline for (0..SrcN) |i| {
        r[i] = satNarrow(Src, Dst, aa[i]);
        r[i + SrcN] = satNarrow(Src, Dst, bb[i]);
    }
    return @bitCast(r);
}

fn vextend(comptime SrcN: usize, comptime Src: type, comptime Dst: type, comptime high: bool, a: u128) u128 {
    const arr: [SrcN]Src = @bitCast(a);
    const DstN = SrcN / 2;
    const off = if (high) DstN else 0;
    var r: [DstN]Dst = undefined;
    inline for (0..DstN) |i| r[i] = arr[off + i];
    return @bitCast(r);
}

fn vextmul(ip: *Interp, comptime SrcN: usize, comptime Src: type, comptime Dst: type, comptime high: bool) u128 {
    const b = ip.popV128();
    const a = ip.popV128();
    const aa: [SrcN]Src = @bitCast(a);
    const bb: [SrcN]Src = @bitCast(b);
    const DstN = SrcN / 2;
    const off = if (high) DstN else 0;
    var r: [DstN]Dst = undefined;
    inline for (0..DstN) |i| r[i] = @as(Dst, aa[off + i]) *% @as(Dst, bb[off + i]);
    return @bitCast(r);
}

fn vextadd(comptime SrcN: usize, comptime Src: type, comptime Dst: type, a: u128) u128 {
    const arr: [SrcN]Src = @bitCast(a);
    const DstN = SrcN / 2;
    var r: [DstN]Dst = undefined;
    inline for (0..DstN) |i| r[i] = @as(Dst, arr[2 * i]) +% @as(Dst, arr[2 * i + 1]);
    return @bitCast(r);
}

fn loadSplat(ip: *Interp, body: []const u8, pc: *usize, comptime N: usize, comptime T: type) TrapError!u128 {
    const ea = memEa(ip, body, pc);
    const data = ip.instance.memory.?.data;
    const nbytes = @sizeOf(T);
    try checkBounds(data.len, ea, nbytes);
    const x = std.mem.readInt(T, data[@intCast(ea)..][0..nbytes], .little);
    return vsplat(N, T, x);
}

fn loadExtend(ip: *Interp, body: []const u8, pc: *usize, comptime DstN: usize, comptime Src: type, comptime Dst: type) TrapError!u128 {
    const ea = memEa(ip, body, pc);
    const data = ip.instance.memory.?.data;
    try checkBounds(data.len, ea, 8); // always reads 8 source bytes
    const src_bytes = @sizeOf(Src);
    const base: usize = @intCast(ea);
    var r: [DstN]Dst = undefined;
    inline for (0..DstN) |i| {
        r[i] = std.mem.readInt(Src, data[base + i * src_bytes ..][0..src_bytes], .little);
    }
    return @bitCast(r);
}

fn loadZero(ip: *Interp, body: []const u8, pc: *usize, comptime nbytes: usize) TrapError!u128 {
    const ea = memEa(ip, body, pc);
    const data = ip.instance.memory.?.data;
    try checkBounds(data.len, ea, nbytes);
    const base: usize = @intCast(ea);
    if (nbytes == 4) return std.mem.readInt(u32, data[base..][0..4], .little);
    return std.mem.readInt(u64, data[base..][0..8], .little);
}

fn loadLane(ip: *Interp, body: []const u8, pc: *usize, comptime N: usize, comptime T: type) TrapError!u128 {
    const vector = ip.popV128();
    const ea = memEa(ip, body, pc);
    const lane = readLane(body, pc);
    const data = ip.instance.memory.?.data;
    const nbytes = @sizeOf(T);
    try checkBounds(data.len, ea, nbytes);
    var arr: [N]T = @bitCast(vector);
    arr[lane] = std.mem.readInt(T, data[@intCast(ea)..][0..nbytes], .little);
    return @bitCast(arr);
}

fn storeLane(ip: *Interp, body: []const u8, pc: *usize, comptime N: usize, comptime T: type) TrapError!void {
    const vector = ip.popV128();
    const ea = memEa(ip, body, pc);
    const lane = readLane(body, pc);
    const data = ip.instance.memory.?.data;
    const nbytes = @sizeOf(T);
    try checkBounds(data.len, ea, nbytes);
    const arr: [N]T = @bitCast(vector);
    std.mem.writeInt(T, data[@intCast(ea)..][0..nbytes], arr[lane], .little);
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
