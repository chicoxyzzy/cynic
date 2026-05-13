//! Mark-sweep heap for Cynic's runtime.
//!
//! later ships the simplest correct thing: a list of GC-managed
//! objects, each carrying a `marked` bit. `collect(roots)` marks
//! reachable objects from the supplied root values and sweeps the
//! rest. Allocator: the host `std.mem.Allocator`. No bump-pointer
//! young space, no copying, no concurrency. The handbook's
//! [compiler-engineering.md] says start here; generational comes
//! after later.
//!
//! Roots fed to `collect` come from the caller. The interpreter
//! supplies its register file + accumulator + constant pool's
//! string entries; built-ins supply their `HandleScope`
//! contents. Cynic deliberately doesn't bake "find your own roots"
//! into `Heap` — explicit roots make the GC contract auditable.
//!
//! `HandleScope` is provided here too, for Zig-side runtime code
//! that allocates more than one heap object across a single
//! abstract operation (e.g. `String.prototype.concat` allocating
//! the result before its operands' last use). Mirrors V8's
//! `Local<T>` ergonomics, single-threaded.

const std = @import("std");

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const JSString = @import("string.zig").JSString;
const JSFunction = @import("function.zig").JSFunction;
const HeapKind = @import("function.zig").HeapKind;
const JSObject = @import("object.zig").JSObject;
const Environment = @import("environment.zig").Environment;
const Chunk = @import("../bytecode/chunk.zig").Chunk;
const JSGenerator = @import("generator.zig").JSGenerator;
const JSSymbol = @import("symbol.zig").JSSymbol;
const JSBigInt = @import("bigint.zig").JSBigInt;

/// Monotonic nanosecond timestamp via libc `clock_gettime`.
/// Used by `Heap.collect`'s diagnostic pause-time field; the
/// std `std.Io` clock would require threading the io handle
/// down here, which costs more than this small libc detour.
fn monotonicNs() i128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

/// Heap-managed pointers are at least 8-byte aligned (the
/// allocator's minimum for any struct containing a pointer
/// field), which leaves the bottom three bits free. We encode
/// the heap kind in the bottom two bits of the stored pointer:
///
/// 00 = Function (JSFunction)
/// 01 = Plain object (JSObject)
/// 10 = Symbol (JSSymbol)
/// 11 = BigInt (JSBigInt)
///
/// The tag-object value tag (`0xFFF9`) is shared across all
/// four; predicate selection uses the pointer-tag bits. Real
/// pointers are reconstructed by masking out the tag bits.
const kind_mask: u64 = 0x3;
const kind_function: u64 = 0x0;
const kind_object: u64 = 0x1;
const kind_symbol: u64 = 0x2;
const kind_bigint: u64 = 0x3;

pub fn taggedFunction(ptr: *JSFunction) Value {
    const p: u64 = @intFromPtr(ptr);
    std.debug.assert(p & 0x7 == 0); // 8-byte aligned
    return .{ .bits = (@as(u64, Value.tag_object) << 48) | p | kind_function };
}

pub fn taggedObject(ptr: *JSObject) Value {
    const p: u64 = @intFromPtr(ptr);
    std.debug.assert(p & 0x7 == 0);
    return .{ .bits = (@as(u64, Value.tag_object) << 48) | p | kind_object };
}

pub fn taggedSymbol(ptr: *JSSymbol) Value {
    const p: u64 = @intFromPtr(ptr);
    std.debug.assert(p & 0x7 == 0);
    return .{ .bits = (@as(u64, Value.tag_object) << 48) | p | kind_symbol };
}

pub fn taggedBigInt(ptr: *JSBigInt) Value {
    const p: u64 = @intFromPtr(ptr);
    std.debug.assert(p & 0x7 == 0);
    return .{ .bits = (@as(u64, Value.tag_object) << 48) | p | kind_bigint };
}

fn valueKind(v: Value) ?u64 {
    if (!v.isObject()) return null;
    return v.bits & kind_mask;
}

pub fn valueAsFunction(v: Value) ?*JSFunction {
    if (valueKind(v) != kind_function) return null;
    const p = v.bits & Value.pointer_mask;
    return @ptrFromInt(p);
}

pub fn valueAsPlainObject(v: Value) ?*JSObject {
    if (valueKind(v) != kind_object) return null;
    const p = (v.bits & Value.pointer_mask) & ~kind_mask;
    return @ptrFromInt(p);
}

pub fn valueAsSymbol(v: Value) ?*JSSymbol {
    if (valueKind(v) != kind_symbol) return null;
    const p = (v.bits & Value.pointer_mask) & ~kind_mask;
    return @ptrFromInt(p);
}

pub fn valueAsBigInt(v: Value) ?*JSBigInt {
    if (valueKind(v) != kind_bigint) return null;
    const p = (v.bits & Value.pointer_mask) & ~kind_mask;
    return @ptrFromInt(p);
}

/// Used by GC marking and printing — returns whether the value
/// is the function flavour without needing to coerce to a
/// concrete pointer type.
pub fn isFunction(v: Value) bool {
    return valueKind(v) == kind_function;
}

pub fn isPlainObject(v: Value) bool {
    return valueKind(v) == kind_object;
}

pub fn isSymbol(v: Value) bool {
    return valueKind(v) == kind_symbol;
}

pub fn isBigInt(v: Value) bool {
    return valueKind(v) == kind_bigint;
}

/// §6.1.7 — JS-level "Object" (plain object or function exotic).
/// Distinct from `Value.isObject`, which is a heap-tag predicate
/// that also covers Symbol and BigInt (those share the
/// tagged-pointer encoding but are primitives at the JS layer,
/// per §6.1.5 and §6.1.6.2). Spec checks like §7.1.1 ToPrimitive
/// "If Type(result) is Object" want this helper, not `isObject`.
pub fn isJSObject(v: Value) bool {
    const k = valueKind(v) orelse return false;
    return k == kind_object or k == kind_function;
}

pub const Heap = struct {
    allocator: std.mem.Allocator,
    /// Every live `JSString` allocated through this heap. Sweep
    /// walks this list; allocate appends.
    strings: std.ArrayListUnmanaged(*JSString) = .empty,
    /// Live `JSFunction` instances.
    functions: std.ArrayListUnmanaged(*JSFunction) = .empty,
    /// Live plain `JSObject` instances (object literals,
    /// prototypes, built-in constructors' return values).
    objects: std.ArrayListUnmanaged(*JSObject) = .empty,
    /// Live `Environment` records — one per active scope that
    /// holds named bindings. The chain through `parent`
    /// pointers keeps captured environments alive as long as
    /// any function still references them.
    environments: std.ArrayListUnmanaged(*Environment) = .empty,
    /// Live `JSGenerator` instances. Each carries an owned
    /// register file plus borrowed pointers into env / chunk;
    /// `deinit` frees the register buffer.
    generators: std.ArrayListUnmanaged(*JSGenerator) = .empty,
    /// Live `JSSymbol` instances. Identity is by pointer; two
    /// `Symbol("x")` calls produce distinct entries here.
    /// `Symbol.for("k")` interns into `symbol_registry`.
    symbols: std.ArrayListUnmanaged(*JSSymbol) = .empty,
    /// Live `JSBigInt` instances. Allocated by every
    /// `0n`-literal and arithmetic result; identity is
    /// by-value at the language level (the heap may dedupe
    /// later as an optimization).
    bigints: std.ArrayListUnmanaged(*JSBigInt) = .empty,
    /// `Symbol.for` registry (§20.4.2.2 GlobalSymbolRegistry).
    /// Maps the registry key (always a string) → JSSymbol pointer
    /// so successive `Symbol.for(k)` calls return the same symbol.
    symbol_registry: std.StringArrayHashMapUnmanaged(*JSSymbol) = .empty,
    /// Monotonic counter feeding `<sym:N>` property keys for
    /// user-created Symbols. Distinct from `symbols.items.len`
    /// because Symbols can be GC'd; using the count would
    /// recycle keys and create false collisions across realm
    /// lifetime.
    next_symbol_id: u64 = 0,
    /// Open handle scopes, in nesting order. The top of the stack
    /// is the innermost scope. Roots from every open scope are
    /// scanned during a collect.
    handle_scopes: std.ArrayListUnmanaged(*HandleScope) = .empty,

    /// Allocations (across every kind) since the last `collect`
    /// call. Bumped by each `allocateX`; the interpreter dispatch
    /// loop checks it against `gc_threshold` between opcodes and
    /// runs `Realm.collectGarbage` when it crosses. Zero once GC
    /// finishes. Stop-the-world mark-sweep means we never run
    /// mid-opcode — pointers from native callbacks stay stable.
    allocs_since_gc: u32 = 0,
    /// Allocation count that triggers a collection. Tunable; the
    /// default is sized so an empty allocating loop runs GC every
    /// few hundred ms at typical `JSObject`/`Environment` sizes.
    /// `std.math.maxInt(u32)` effectively disables the trigger
    /// (the unit-test paths that call `collect` directly do this
    /// when they want full control over when GC fires).
    gc_threshold: u32 = 16384,
    /// Sum of bytes charged across `allocateX` callers. Coarse
    /// — counts the dominant payload (string bytes, ArrayBuffer
    /// bytes, register files); approximate for the small headers.
    /// Drives the hard ceiling check below.
    bytes_live: usize = 0,
    /// Hard ceiling on `bytes_live`. When `charge(n)` would push
    /// it over, the heap forces a GC; if still over, returns
    /// `error.OutOfMemory`. Mirrors V8's `--max-old-space-size`,
    /// QuickJS's `JS_SetMemoryLimit`, Hermes's
    /// `gcConfig.maxHeapSize`. Default `maxInt(usize)` =
    /// unbounded; sandboxed hosts (test runners, browser tabs,
    /// isolated workers) set a per-realm cap so a runaway
    /// `new ArrayBuffer(2 ** 31)` can't exhaust system memory.
    max_bytes: usize = std.math.maxInt(usize),
    /// When non-zero, every `collect` cycle prints a one-line
    /// stderr report of live counts per heap kind (before sweep,
    /// after sweep). Diagnostic for finding leaks: a kind whose
    /// post-sweep count climbs across cycles is being kept alive
    /// by something. Counts as the cycle number for cross-
    /// referencing.
    gc_stats_cycle: u32 = 0,
    gc_stats: bool = false,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator };
    }

    /// Charge `n` bytes against the heap ceiling. Returns
    /// `error.OutOfMemory` when the new total would exceed
    /// `max_bytes`. Cheap to call (one add + one compare); the
    /// caller is responsible for the actual allocation after this
    /// returns. Sweep is the right place to undo the charge —
    /// `mark_sweep_collect` resets `bytes_live` to the post-sweep
    /// sum before continuing.
    pub fn charge(self: *Heap, n: usize) error{OutOfMemory}!void {
        const new_total = self.bytes_live +| n;
        if (new_total > self.max_bytes) return error.OutOfMemory;
        self.bytes_live = new_total;
    }

    /// Decrease the live byte counter. Idempotent w.r.t. the GC
    /// (any inaccuracy gets corrected on the next sweep).
    pub fn discharge(self: *Heap, n: usize) void {
        self.bytes_live = if (n >= self.bytes_live) 0 else self.bytes_live - n;
    }

    /// Free every tracked object and the bookkeeping arrays.
    /// Idempotent — safe to call on a partially-initialized heap.
    pub fn deinit(self: *Heap) void {
        for (self.strings.items) |s| s.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        for (self.functions.items) |f| f.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        for (self.objects.items) |o| o.deinit(self.allocator);
        self.objects.deinit(self.allocator);
        for (self.environments.items) |e| e.deinit(self.allocator);
        self.environments.deinit(self.allocator);
        for (self.generators.items) |g| g.deinit(self.allocator);
        self.generators.deinit(self.allocator);
        for (self.symbols.items) |s| s.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.symbol_registry.deinit(self.allocator);
        for (self.bigints.items) |b| b.deinit(self.allocator);
        self.bigints.deinit(self.allocator);
        self.handle_scopes.deinit(self.allocator);
    }

    pub fn allocateBigInt(self: *Heap, value: i128) !*JSBigInt {
        const b = try JSBigInt.init(self.allocator, value);
        errdefer b.deinit(self.allocator);
        try self.bigints.append(self.allocator, b);
        self.allocs_since_gc +|= 1;
        return b;
    }

    /// Allocate a Symbol whose property-key string is generated
    /// from the heap's monotonic counter. Used for user-level
    /// `Symbol(desc)` and `Symbol.for(k)` — every call yields a
    /// unique key so distinct symbols never collide as
    /// computed-property keys.
    pub fn allocateSymbol(self: *Heap, description: ?[]const u8) !*JSSymbol {
        var key_buf: [32]u8 = undefined;
        const id = self.next_symbol_id;
        self.next_symbol_id += 1;
        const slice = std.fmt.bufPrint(&key_buf, "<sym:{d}>", .{id}) catch unreachable;
        const owned = try self.allocator.dupe(u8, slice);
        const s = try JSSymbol.init(self.allocator, description, owned);
        errdefer s.deinit(self.allocator);
        try self.symbols.append(self.allocator, s);
        self.allocs_since_gc +|= 1;
        return s;
    }

    /// Allocate a Symbol with an explicit, caller-chosen
    /// property-key string. Used by well-known symbols
    /// (`Symbol.iterator` etc.) where the conventional
    /// `@@iterator` key keeps existing intrinsics installations
    /// working.
    pub fn allocateWellKnownSymbol(self: *Heap, description: ?[]const u8, prop_key: []const u8) !*JSSymbol {
        const owned = try self.allocator.dupe(u8, prop_key);
        const s = try JSSymbol.init(self.allocator, description, owned);
        errdefer s.deinit(self.allocator);
        try self.symbols.append(self.allocator, s);
        self.allocs_since_gc +|= 1;
        return s;
    }

    pub fn allocateGenerator(
        self: *Heap,
        chunk: *const Chunk,
        register_count: u8,
        captured_env: ?*Environment,
        this_value: Value,
    ) !*JSGenerator {
        const g = try JSGenerator.init(self.allocator, chunk, register_count, captured_env, this_value);
        errdefer g.deinit(self.allocator);
        try self.generators.append(self.allocator, g);
        self.allocs_since_gc +|= 1;
        return g;
    }

    pub fn allocateObject(self: *Heap) !*JSObject {
        const o = try JSObject.init(self.allocator);
        errdefer o.deinit(self.allocator);
        try self.objects.append(self.allocator, o);
        self.allocs_since_gc +|= 1;
        return o;
    }

    /// Allocate a new `Environment` chained to `parent`, with
    /// `slot_count` bindings initialised to the TDZ Hole.
    pub fn allocateEnvironment(self: *Heap, parent: ?*Environment, slot_count: u8) !*Environment {
        const env = try Environment.init(self.allocator, parent, slot_count);
        errdefer env.deinit(self.allocator);
        try self.environments.append(self.allocator, env);
        self.allocs_since_gc +|= 1;
        return env;
    }

    /// Allocate a `JSFunction` whose chunk is `chunk`. Ownership
    /// of the function pointer is transferred to the heap; never
    /// call `JSFunction.deinit` on a heap-allocated instance
    /// (it's freed during sweep / heap.deinit).
    ///
    /// Non-arrow functions also get a fresh `.prototype` object
    /// auto-allocated, with its `.constructor` slot wired back to
    /// the function (§10.2.4 / §20.2.4.1) so `(new F).constructor === F`.
    /// Arrow functions don't get a `.prototype` slot.
    pub fn allocateFunction(
        self: *Heap,
        chunk: *const Chunk,
        param_count: u8,
        name: ?[]const u8,
        is_arrow: bool,
        captured_env: ?*Environment,
    ) !*JSFunction {
        const f = try JSFunction.init(self.allocator, chunk, param_count, name, is_arrow, captured_env);
        errdefer f.deinit(self.allocator);
        // §10.2.4 / §10.2.9 — install `length` and `name` as own
        // properties with the spec-mandated descriptor flags
        // ({w:false, e:false, c:true}). Storing them in the
        // generic property bag (rather than as dedicated-slot
        // fallbacks) means `delete fn.length` works through the
        // ordinary path and `Object.getOwnPropertyDescriptor`
        // sees the right flags.
        try self.installFunctionLengthAndName(f, param_count, name);
        try self.functions.append(self.allocator, f);
        self.allocs_since_gc +|= 1;
        if (!is_arrow) {
            const proto = try self.allocateObject();
            f.prototype = proto;
            // §20.2.4.1 — `prototype.constructor` is
            // non-enumerable. for-in over an instance must
            // not surface this as a key.
            try proto.setWithFlags(self.allocator, "constructor", taggedFunction(f), .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            });
        }
        return f;
    }

    /// Allocate a native (host-implemented) function. Differs
    /// from `allocateFunction` only in that the resulting
    /// `JSFunction` carries a `native_callback` instead of a
    /// chunk; the Call opcode dispatches to it directly.
    pub fn allocateFunctionNative(
        self: *Heap,
        callback: @import("function.zig").NativeFn,
        param_count: u8,
        name: []const u8,
    ) !*JSFunction {
        const f = try JSFunction.initNative(self.allocator, callback, param_count, name);
        errdefer f.deinit(self.allocator);
        try self.installFunctionLengthAndName(f, param_count, name);
        try self.functions.append(self.allocator, f);
        self.allocs_since_gc +|= 1;
        return f;
    }

    /// Install `length` and (when present) `name` as own
    /// properties on a freshly-allocated function with §17 spec
    /// flags. Allocates a heap-tracked JSString to back `name`
    /// so the property's `value` is a real string.
    fn installFunctionLengthAndName(
        self: *Heap,
        f: *JSFunction,
        param_count: u8,
        name: ?[]const u8,
    ) !void {
        const flags: @import("object.zig").PropertyFlags = .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        };
        // length always installs.
        try f.properties.put(self.allocator, "length", Value.fromInt32(param_count));
        try f.property_flags.put(self.allocator, "length", flags);
        // §10.2.9 SetFunctionName — every function gets a `name`
        // own property; anonymous functions get `""` rather than
        // omitting the property. Tests probe the descriptor (via
        // `Object.getOwnPropertyDescriptor(fn, "name")`) which
        // requires it to actually exist.
        const display_name = name orelse "";
        const name_str = try self.allocateString(display_name);
        if (display_name.len > 0) {
            f.name_string = name_str;
            f.name = name_str.bytes;
        }
        try f.properties.put(self.allocator, "name", Value.fromString(name_str));
        try f.property_flags.put(self.allocator, "name", flags);
    }

    /// Allocate a `JSString` whose contents are a copy of `src`.
    /// The pointer is owned by the heap; do NOT call `deinit` on
    /// it directly — it is freed during a sweep that doesn't see
    /// it marked, or when the heap itself is deinit'd.
    pub fn allocateString(self: *Heap, src: []const u8) !*JSString {
        try self.charge(src.len + @sizeOf(JSString));
        const s = try JSString.init(self.allocator, src);
        errdefer s.deinit(self.allocator);
        try self.strings.append(self.allocator, s);
        self.allocs_since_gc +|= 1;
        return s;
    }

    /// Allocate a string that is `a ++ b`, owned by the heap.
    pub fn concatStrings(self: *Heap, a: *const JSString, b: *const JSString) !*JSString {
        try self.charge(a.bytes.len + b.bytes.len + @sizeOf(JSString));
        const s = try JSString.concat(self.allocator, a, b);
        errdefer s.deinit(self.allocator);
        try self.strings.append(self.allocator, s);
        return s;
    }

    /// Mark a single value if it carries a heap pointer. Idempotent.
    /// handles `String` and `Object` (where Object is
    /// currently always a `JSFunction`). later generalises Object
    /// once shapes / plain objects land.
    pub fn markValue(self: *Heap, v: Value) void {
        if (v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(v.asString()));
            s.marked = true;
        } else if (valueAsSymbol(v)) |sym| {
            sym.marked = true;
        } else if (valueAsBigInt(v)) |bi| {
            bi.marked = true;
        } else if (valueAsFunction(v)) |f| {
            if (!f.marked) {
                f.marked = true;
                if (f.captured_env) |env| self.markEnvironment(env);
                var it = f.properties.iterator();
                while (it.next()) |entry| self.markValue(entry.value_ptr.*);
                // §10.1.8 accessor descriptors on the function
                // object itself (e.g. `Object.defineProperty(fn,
                // 'prototype', {get: …})`). The accessor functions
                // are roots — without this walk a getter installed
                // on a NewTarget gets swept while the registry of
                // pending constructions still holds the function.
                var fait = f.accessors.iterator();
                while (fait.next()) |entry| {
                    if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
                    if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
                }
                // §15.7 static private slots on the class
                // constructor — `static #x = …` data slots and
                // `static get/set #y` accessor halves.
                var fpit = f.private_properties.iterator();
                while (fpit.next()) |entry| self.markValue(entry.value_ptr.*);
                var fpait = f.private_accessors.iterator();
                while (fpait.next()) |entry| {
                    if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
                    if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
                }
                if (f.prototype) |p| self.markValue(taggedObject(p));
                // §10.4.1 BoundFunction state — keep target +
                // bound this + bound args alive.
                if (f.bound_target) |bt| self.markValue(taggedFunction(bt));
                self.markValue(f.bound_this);
                if (f.bound_args) |ba| {
                    for (ba) |a| self.markValue(a);
                }
                // The function's chunk holds heap-allocated string
                // constants. Those JSStrings were pinned at
                // chunk-finalize time (see `pinChunk`), so we
                // don't need to walk them here — sweep skips
                // pinned items entirely.
            }
        } else if (valueAsPlainObject(v)) |o| {
            if (!o.marked) {
                o.marked = true;
                var it = o.properties.iterator();
                while (it.next()) |entry| self.markValue(entry.value_ptr.*);
                var pit = o.private_properties.iterator();
                while (pit.next()) |entry| self.markValue(entry.value_ptr.*);
                var pait = o.private_accessors.iterator();
                while (pait.next()) |entry| {
                    if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
                    if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
                }
                var ait = o.accessors.iterator();
                while (ait.next()) |entry| {
                    if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
                    if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
                }
                if (o.boxed_primitive) |bp| self.markValue(bp);
                if (o.map_data) |md| {
                    for (md.entries.items) |entry| {
                        if (entry.deleted) continue;
                        self.markValue(entry.key);
                        self.markValue(entry.value);
                    }
                }
                if (o.set_data) |sd| {
                    for (sd.entries.items) |entry| {
                        if (entry.deleted) continue;
                        self.markValue(entry.value);
                    }
                }
                if (o.generator_ref) |gen| self.markGenerator(gen);
                // §10.4.2 Array exotic — packed indexed elements
                // are part of the JSObject's own state; mark each
                // slot to keep referenced values alive.
                if (o.is_array_exotic) {
                    if (o.is_sparse) {
                        var sit = o.sparse_elements.iterator();
                        while (sit.next()) |entry| self.markValue(entry.value_ptr.*);
                    } else {
                        for (o.elements.items) |elem| self.markValue(elem);
                    }
                }
                // §26.1 WeakRef — strong-ref impl: keep target alive
                // for the lifetime of the WeakRef. Once Cynic grows
                // true GC-weak references this becomes conditional
                // (only marked while inside a job that has observed
                // `.deref()`, per §9.10 AddToKeptObjects).
                if (o.is_weak_ref) self.markValue(o.weak_ref_target);
                // §26.2 FinalizationRegistry — strong-mark the
                // cleanup callback plus every live cell's target /
                // heldValue / unregister token. Cynic's FR is a
                // strong-ref impl (see object.zig FinalizationData
                // doc); without these marks the cleanup closure
                // and the still-registered targets would be swept
                // out from under a reachable registry.
                if (o.finalization_cells) |fc| {
                    self.markValue(fc.cleanup_callback);
                    for (fc.cells.items) |cell| {
                        if (cell.deleted) continue;
                        self.markValue(cell.target);
                        self.markValue(cell.held_value);
                        if (cell.has_token) self.markValue(cell.unregister_token);
                    }
                }
                // Heap-allocated JSStrings whose `.bytes` slice
                // backs a property key. The property hash maps
                // store `[]const u8`, not pointers; without this
                // anchor the JSString gets swept and the key
                // dangles. Computed `obj[expr] = v` writes go
                // through `setComputedOwned` which pushes here.
                for (o.key_anchors.items) |s| s.marked = true;
                // Pending Promise reactions / waiters — settlement
                // microtasks read these lists. A reaction's
                // `result_promise` is the chained sub-Promise that
                // a later `.then` is registered on; without marking
                // it here, mid-drain GC collects the chain.
                for (o.promise_reactions.items) |r| {
                    self.markValue(r.on_fulfilled);
                    self.markValue(r.on_rejected);
                    self.markValue(r.result_promise);
                }
                for (o.promise_waiters.items) |w| self.markGenerator(w);
                // §27.2 `[[PromiseResult]]` — the settled value on
                // a fulfilled / rejected Promise. Held in the typed
                // `promise_value` slot rather than a property bag,
                // so the regular property walk above misses it.
                if (o.promise_state != .none) self.markValue(o.promise_value);
                // §22.2.4 `[[OriginalSource]]` / `[[OriginalFlags]]`
                // for RegExp instances. Strings that the regular
                // property walk wouldn't reach.
                if (o.regexp_source) |s| s.marked = true;
                if (o.regexp_flags) |s| s.marked = true;
                if (o.instance_field_inits) |inits| {
                    for (inits) |fi| {
                        if (fi.init_fn) |fnp| self.markValue(taggedFunction(fnp));
                    }
                }
                if (o.private_method_inits) |inits| {
                    for (inits) |fi| {
                        if (fi.init_fn) |fnp| self.markValue(taggedFunction(fnp));
                    }
                }
                if (o.prototype) |p| self.markValue(taggedObject(p));
                // §23.2 / §25.3 — TypedArray and DataView views
                // borrow bytes from a sibling ArrayBuffer object via
                // `viewed`. The ArrayBuffer is held only through this
                // Zig field, not through a JS-visible property, so
                // without marking it here the buffer gets swept while
                // the view is still reachable and indexed reads see
                // freed bytes.
                if (o.typed_view) |tv| self.markValue(taggedObject(tv.viewed));
                if (o.data_view) |dv| self.markValue(taggedObject(dv.viewed));
            }
        }
        // Doubles, ints, bools, null, undefined, hole: no heap pointer.
    }

    /// Walk a `Chunk`'s constant pool and pin every JSString it
    /// references — including those in nested function / class
    /// templates. Called once at chunk-finalize time
    /// (`compileScriptAsChunk`, `compileModuleAsChunk`) and
    /// never again: chunks are realm-lifetime, so their constant
    /// pool can't outlive the realm. Pinned strings are skipped
    /// during sweep, which lets us drop the per-GC-cycle walk
    /// of `script_chunks` and `JSFunction.chunk` (the heap's
    /// hottest mark-phase work, since chunk trees recurse into
    /// every method / static-block / field initializer).
    pub fn pinChunk(self: *Heap, chunk: *const Chunk) void {
        for (chunk.constants) |c| self.pinValue(c);
        for (chunk.function_templates) |*ft| self.pinChunk(&ft.chunk);
        for (chunk.class_templates) |*ct| {
            self.pinChunk(&ct.constructor_chunk);
            for (ct.instance_methods) |*m| self.pinChunk(&m.chunk);
            for (ct.static_methods) |*m| self.pinChunk(&m.chunk);
            for (ct.instance_fields) |*fd| if (fd.init_chunk) |*ic| self.pinChunk(ic);
            for (ct.static_fields) |*fd| if (fd.init_chunk) |*ic| self.pinChunk(ic);
            for (ct.static_blocks) |*sb| self.pinChunk(sb);
        }
    }

    /// Pin the heap-allocated payload of `v` if it's a string.
    /// Other primitive kinds carry no heap pointer; symbols /
    /// bigints don't appear in chunk constants (the compiler
    /// allocates symbols at runtime). Idempotent.
    fn pinValue(self: *Heap, v: Value) void {
        _ = self;
        if (v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(v.asString()));
            s.pinned = true;
        }
    }

    /// Mark `env` and recursively walk its parent chain + slots.
    /// Idempotent — a repeated mark short-circuits on the bit.
    pub fn markEnvironment(self: *Heap, env: *Environment) void {
        if (env.marked) return;
        env.marked = true;
        for (env.slots) |s| self.markValue(s);
        if (env.parent) |p| self.markEnvironment(p);
    }

    /// Mark a suspended generator's saved frame state. Idempotent.
    /// Walks: register file (live local values), captured env,
    /// `this`, `[[HomeObject]]`, plus the accumulator. The chunk
    /// pointer is borrowed from the function template; not owned
    /// by the heap, so not marked here.
    pub fn markGenerator(self: *Heap, gen: *JSGenerator) void {
        if (gen.marked) return;
        gen.marked = true;
        for (gen.registers) |s| self.markValue(s);
        self.markValue(gen.accumulator);
        self.markValue(gen.this_value);
        if (gen.env) |e| self.markEnvironment(e);
        if (gen.home_object) |ho| self.markValue(taggedObject(ho));
    }

    /// Run a full mark-sweep cycle. `roots` is every live value the
    /// caller wants to keep. Anything reachable only through values
    /// outside `roots` (and outside any open `HandleScope`) is
    /// freed. After this call every surviving object's `marked` bit
    /// is back to `false`, ready for the next cycle.
    pub fn collect(self: *Heap, roots: []const Value) void {
        // Wall-clock start for the diagnostic pause-time field.
        // Production engines (V8 `--trace-gc`, JSC GC logs, SM
        // `MOZ_GCTIMER`) all surface per-cycle pause distribution
        // — the long-tail cycles are where investigation starts.
        const t_start = monotonicNs();

        // Mark phase.
        for (roots) |r| self.markValue(r);
        for (self.handle_scopes.items) |scope| {
            for (scope.handles.items) |r| self.markValue(r);
        }

        // Snapshot pre-sweep counts for the diagnostic report.
        const pre_objs = self.objects.items.len;
        const pre_strs = self.strings.items.len;
        const pre_fns = self.functions.items.len;
        const pre_envs = self.environments.items.len;
        const pre_gens = self.generators.items.len;
        const pre_syms = self.symbols.items.len;
        const pre_bigs = self.bigints.items.len;

        // Sweep phase. Walk in reverse so swap-removal stays cheap.
        {
            var i: usize = self.strings.items.len;
            while (i > 0) {
                i -= 1;
                const s = self.strings.items[i];
                if (s.pinned) {
                    // Permanently live (chunk constants). Skip;
                    // never gets marked or cleared either way.
                } else if (s.marked) {
                    s.marked = false;
                } else {
                    _ = self.strings.swapRemove(i);
                    s.deinit(self.allocator);
                }
            }
        }
        {
            var i: usize = self.functions.items.len;
            while (i > 0) {
                i -= 1;
                const f = self.functions.items[i];
                if (f.marked) {
                    f.marked = false;
                } else {
                    _ = self.functions.swapRemove(i);
                    f.deinit(self.allocator);
                }
            }
        }
        {
            var i: usize = self.objects.items.len;
            while (i > 0) {
                i -= 1;
                const obj = self.objects.items[i];
                if (obj.marked) {
                    obj.marked = false;
                } else {
                    _ = self.objects.swapRemove(i);
                    obj.deinit(self.allocator);
                }
            }
        }
        {
            var i: usize = self.environments.items.len;
            while (i > 0) {
                i -= 1;
                const env = self.environments.items[i];
                if (env.marked) {
                    env.marked = false;
                } else {
                    _ = self.environments.swapRemove(i);
                    env.deinit(self.allocator);
                }
            }
        }
        {
            var i: usize = self.generators.items.len;
            while (i > 0) {
                i -= 1;
                const gen = self.generators.items[i];
                if (gen.marked) {
                    gen.marked = false;
                } else {
                    _ = self.generators.swapRemove(i);
                    gen.deinit(self.allocator);
                }
            }
        }
        {
            // Registered symbols stay alive forever (GlobalSymbolRegistry
            // is a strong reference). Mark them before the sweep.
            var rit = self.symbol_registry.iterator();
            while (rit.next()) |e| e.value_ptr.*.marked = true;

            var i: usize = self.symbols.items.len;
            while (i > 0) {
                i -= 1;
                const sym = self.symbols.items[i];
                if (sym.marked) {
                    sym.marked = false;
                } else {
                    _ = self.symbols.swapRemove(i);
                    sym.deinit(self.allocator);
                }
            }
        }
        {
            var i: usize = self.bigints.items.len;
            while (i > 0) {
                i -= 1;
                const bi = self.bigints.items[i];
                if (bi.marked) {
                    bi.marked = false;
                } else {
                    _ = self.bigints.swapRemove(i);
                    bi.deinit(self.allocator);
                }
            }
        }
        // Reset the allocation pressure counter so the next
        // collect doesn't fire until fresh allocations cross
        // the threshold again.
        self.allocs_since_gc = 0;

        // Per-cycle diagnostic report — flagged on by the
        // `--gc-stats` test262 harness option (or by hand for
        // ad-hoc debugging). Format: `[gc N] kind=pre→post ...`.
        // A kind whose `post` keeps climbing across cycles is
        // being kept alive by something that should let go.
        if (self.gc_stats) {
            self.gc_stats_cycle += 1;
            const elapsed_ns: i128 = monotonicNs() - t_start;
            const elapsed_us: i128 = @divTrunc(elapsed_ns, 1000);
            std.debug.print(
                "[gc {d}] {d}\u{00B5}s obj={d}\u{2192}{d} str={d}\u{2192}{d} fn={d}\u{2192}{d} env={d}\u{2192}{d} gen={d}\u{2192}{d} sym={d}\u{2192}{d} big={d}\u{2192}{d}\n",
                .{
                    self.gc_stats_cycle,
                    elapsed_us,
                    pre_objs, self.objects.items.len,
                    pre_strs, self.strings.items.len,
                    pre_fns,  self.functions.items.len,
                    pre_envs, self.environments.items.len,
                    pre_gens, self.generators.items.len,
                    pre_syms, self.symbols.items.len,
                    pre_bigs, self.bigints.items.len,
                },
            );
        }
    }

    /// Open a new handle scope. The returned scope is owned by the
    /// caller; pair with `close` (typically `defer scope.close()`).
    /// While open, every value pushed via `scope.push` is a GC root.
    pub fn openScope(self: *Heap) !*HandleScope {
        const scope = try self.allocator.create(HandleScope);
        scope.* = .{ .heap = self };
        try self.handle_scopes.append(self.allocator, scope);
        return scope;
    }
};

/// A V8-`Local<T>`-style scope. Push values that must survive
/// allocations across a single abstract operation; close the scope
/// at the operation's end.
pub const HandleScope = struct {
    heap: *Heap,
    handles: std.ArrayListUnmanaged(Value) = .empty,

    pub fn close(self: *HandleScope) void {
        // Pop ourselves off the heap's open-scope stack. The most
        // recent open scope is at the top; in non-pathological code
        // that is exactly us. Tolerate out-of-order close defensively
        // by linear-scanning if the top doesn't match — bugs in
        // builtins shouldn't crash the interpreter.
        const scopes = &self.heap.handle_scopes;
        const top = scopes.items.len;
        if (top > 0 and scopes.items[top - 1] == self) {
            _ = scopes.pop();
        } else {
            var i: usize = top;
            while (i > 0) {
                i -= 1;
                if (scopes.items[i] == self) {
                    _ = scopes.swapRemove(i);
                    break;
                }
            }
        }
        self.handles.deinit(self.heap.allocator);
        self.heap.allocator.destroy(self);
    }

    pub fn push(self: *HandleScope, v: Value) !void {
        try self.handles.append(self.heap.allocator, v);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Heap: allocate then collect with empty roots frees the string" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    _ = try heap.allocateString("transient");
    try testing.expectEqual(@as(usize, 1), heap.strings.items.len);

    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.strings.items.len);
}

test "Heap: collect keeps an object reachable through roots" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const s = try heap.allocateString("kept");
    const v = Value.fromString(s);

    heap.collect(&.{v});
    try testing.expectEqual(@as(usize, 1), heap.strings.items.len);
    try testing.expectEqualStrings("kept", s.bytes);
}

test "Heap: collect resets mark bit between cycles" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const s = try heap.allocateString("kept");
    const v = Value.fromString(s);

    heap.collect(&.{v});
    try testing.expect(!s.marked); // cleared after sweep

    // A second cycle with no roots must free it (mark bit must
    // really be cleared, not stuck on).
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.strings.items.len);
}

test "Heap: handle scope keeps an object alive without explicit roots" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const s = try heap.allocateString("scoped");
    const v = Value.fromString(s);

    const scope = try heap.openScope();
    try scope.push(v);

    // Collection with NO explicit roots — the scope must save it.
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 1), heap.strings.items.len);

    scope.close();

    // Now the scope is gone — collect frees the string.
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.strings.items.len);
}

test "Heap: nested handle scopes both contribute roots" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.allocateString("outer");
    const b = try heap.allocateString("inner");

    const outer = try heap.openScope();
    try outer.push(Value.fromString(a));
    const inner = try heap.openScope();
    try inner.push(Value.fromString(b));

    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 2), heap.strings.items.len);

    inner.close();
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 1), heap.strings.items.len);

    outer.close();
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.strings.items.len);
}

test "Heap: concatStrings tracks the result" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.allocateString("foo");
    const b = try heap.allocateString("bar");
    const ab = try heap.concatStrings(a, b);

    try testing.expectEqualStrings("foobar", ab.bytes);
    try testing.expectEqual(@as(usize, 3), heap.strings.items.len);

    // With only `ab` rooted, `a` and `b` are freed.
    heap.collect(&.{Value.fromString(ab)});
    try testing.expectEqual(@as(usize, 1), heap.strings.items.len);
}

test "tagging: real JSObject from heap is recognised as plain object" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const obj = try heap.allocateObject();
    const v = taggedObject(obj);
    try testing.expect(v.isObject());
    try testing.expect(isPlainObject(v));
    try testing.expect(!isFunction(v));
    try testing.expect(valueAsPlainObject(v) == obj);
}

test "tagging: object and function have distinct kind bits" {
    const Bytes = struct { x: u64 align(8) };
    var fn_storage: Bytes = .{ .x = 0xDEAD };
    var obj_storage: Bytes = .{ .x = 0xBEEF };
    const fn_ptr: *JSFunction = @ptrCast(@alignCast(&fn_storage));
    const obj_ptr: *JSObject = @ptrCast(@alignCast(&obj_storage));
    const fv = taggedFunction(fn_ptr);
    const ov = taggedObject(obj_ptr);
    try std.testing.expect(isFunction(fv));
    try std.testing.expect(!isPlainObject(fv));
    try std.testing.expect(!isFunction(ov));
    try std.testing.expect(isPlainObject(ov));
}
