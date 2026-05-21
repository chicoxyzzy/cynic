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
const string_mod = @import("string.zig");
const JSString = string_mod.JSString;
const utf16 = @import("utf16.zig");
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
///
/// On a freestanding target with no libc (the `wasm32-freestanding`
/// playground build) `std.c.timespec` is `void` — there is no
/// monotonic clock to read, so the GC pause-time diagnostic
/// degrades to a constant 0. Correctness of collection itself is
/// unaffected; only the `--gc-stats` timing field goes dark, and
/// that flag is harness-only.
fn monotonicNs() i128 {
    if (@import("builtin").os.tag == .freestanding) return 0;
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

/// Generational-GC age of a heap object. A `.young` object lives
/// in its kind's young list and is reclaimable by a cheap
/// `collectYoung` cycle; a `.mature` object survived at least one
/// collection and was relinked into the kind's mature list (the
/// object itself never moves — Cynic's collector is non-moving).
/// Two-bit enum so it packs into the existing flag-byte padding
/// next to each header's `marked` bit.
pub const Generation = enum(u2) { young, mature };

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

// The NaN-boxed pointer field is masked out as a `u64`; on a
// 32-bit target (wasm32) `@ptrFromInt` wants a `usize`, so each
// site `@intCast`s down. Real pointers fit `usize` on every
// target Cynic builds for; on 64-bit the cast is a no-op.

pub fn valueAsFunction(v: Value) ?*JSFunction {
    if (valueKind(v) != kind_function) return null;
    const p = v.bits & Value.pointer_mask;
    return @ptrFromInt(@as(usize, @intCast(p)));
}

pub fn valueAsPlainObject(v: Value) ?*JSObject {
    if (valueKind(v) != kind_object) return null;
    const p = (v.bits & Value.pointer_mask) & ~kind_mask;
    return @ptrFromInt(@as(usize, @intCast(p)));
}

pub fn valueAsSymbol(v: Value) ?*JSSymbol {
    if (valueKind(v) != kind_symbol) return null;
    const p = (v.bits & Value.pointer_mask) & ~kind_mask;
    return @ptrFromInt(@as(usize, @intCast(p)));
}

pub fn valueAsBigInt(v: Value) ?*JSBigInt {
    if (valueKind(v) != kind_bigint) return null;
    const p = (v.bits & Value.pointer_mask) & ~kind_mask;
    return @ptrFromInt(@as(usize, @intCast(p)));
}

/// Erase a heap value to an opaque pointer for diagnostic
/// printing — used by `verifyRememberedSet` to name the
/// young-target of an un-barriered edge. Returns `null` for a
/// non-heap value.
fn valueHeapPtr(v: Value) ?*const anyopaque {
    if (v.isString()) return v.asString();
    if (valueAsFunction(v)) |f| return f;
    if (valueAsPlainObject(v)) |o| return o;
    if (valueAsSymbol(v)) |s| return s;
    if (valueAsBigInt(v)) |b| return b;
    return null;
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
    /// Allocator backing large heap-owned payloads (JSString.bytes,
    /// ArrayBuffer slabs) that the mark-sweep collector will free
    /// during `sweep`. Defaults to `allocator`, but hosts running
    /// many disjoint workloads on top of an `ArenaAllocator` (the
    /// test262 harness, in particular) override it to a real
    /// page-returning allocator — `arena.free()` is a no-op, so
    /// without the split, freed string bytes stay resident inside
    /// the arena's pages and per-fixture peak RSS never shrinks.
    bytes_allocator: std.mem.Allocator,
    // Per-kind live-object lists. Each kind is split into a
    // `young` list (fresh allocations — reclaimable by the cheap
    // `collectYoung` cycle) and a `mature` list (objects that
    // survived at least one collection). `collectFull` sweeps
    // both; `collectYoung` sweeps only the young lists, relinking
    // survivors into the mature list (a pointer move — the object
    // never relocates, the collector is non-moving). Stage 1
    // wires the split but `collectFull` keeps the old behaviour.

    /// Young `JSString` instances. Allocate appends here.
    strings_young: std.ArrayListUnmanaged(*JSString) = .empty,
    /// Mature `JSString` instances — survived a young collection,
    /// or allocated straight here when pinned (chunk constants).
    strings_mature: std.ArrayListUnmanaged(*JSString) = .empty,
    /// Young `JSFunction` instances.
    functions_young: std.ArrayListUnmanaged(*JSFunction) = .empty,
    /// Mature `JSFunction` instances.
    functions_mature: std.ArrayListUnmanaged(*JSFunction) = .empty,
    /// Young plain `JSObject` instances (object literals,
    /// prototypes, built-in constructors' return values).
    objects_young: std.ArrayListUnmanaged(*JSObject) = .empty,
    /// Mature plain `JSObject` instances.
    objects_mature: std.ArrayListUnmanaged(*JSObject) = .empty,
    /// Young `Environment` records — one per active scope that
    /// holds named bindings.
    environments_young: std.ArrayListUnmanaged(*Environment) = .empty,
    /// Mature `Environment` records.
    environments_mature: std.ArrayListUnmanaged(*Environment) = .empty,
    /// Young `JSGenerator` instances. Each carries an owned
    /// register file plus borrowed pointers into env / chunk;
    /// `deinit` frees the register buffer.
    generators_young: std.ArrayListUnmanaged(*JSGenerator) = .empty,
    /// Mature `JSGenerator` instances.
    generators_mature: std.ArrayListUnmanaged(*JSGenerator) = .empty,
    /// Young `JSSymbol` instances. Identity is by pointer; two
    /// `Symbol("x")` calls produce distinct entries here.
    /// `Symbol.for("k")` interns into `symbol_registry`.
    symbols_young: std.ArrayListUnmanaged(*JSSymbol) = .empty,
    /// Mature `JSSymbol` instances.
    symbols_mature: std.ArrayListUnmanaged(*JSSymbol) = .empty,
    /// Young `JSBigInt` instances. Allocated by every
    /// `0n`-literal and arithmetic result; identity is
    /// by-value at the language level (the heap may dedupe
    /// later as an optimization).
    bigints_young: std.ArrayListUnmanaged(*JSBigInt) = .empty,
    /// Mature `JSBigInt` instances.
    bigints_mature: std.ArrayListUnmanaged(*JSBigInt) = .empty,
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

    /// Remembered set — every mature container that the write
    /// barrier has observed storing a pointer to a young object.
    /// `collectYoung` scans these as additional roots so a young
    /// object reachable only from old space survives. An entry is
    /// appended at most once (the container's `in_remembered_set`
    /// bit guards re-insertion); `collectYoung` clears the set and
    /// the bits after each young cycle. `collectFull` ignores and
    /// clears it — a full mark already traces every mature object.
    remembered: std.ArrayListUnmanaged(Container) = .empty,

    /// Allocations (across every kind) since the last `collect`
    /// call. Bumped by each `allocateX`; the interpreter dispatch
    /// loop checks it against `gc_threshold` between opcodes and
    /// runs `Realm.collectGarbage` when it crosses. Zero once GC
    /// finishes. Stop-the-world mark-sweep means we never run
    /// mid-opcode — pointers from native callbacks stay stable.
    allocs_since_gc: u32 = 0,
    /// Bytes charged since the last `collect`. A workload that
    /// allocates a small number of huge payloads (`String += big`,
    /// `new ArrayBuffer(MB)`, …) never trips the count-based
    /// threshold, so dead intermediates pile up between collects.
    /// Bytes-based trigger keeps GC firing on data volume too.
    bytes_since_gc: usize = 0,
    /// Allocation count that triggers a *major* (full) collection.
    /// Tunable; the default is sized so an empty allocating loop
    /// runs GC every few hundred ms at typical
    /// `JSObject`/`Environment` sizes. `std.math.maxInt(u32)`
    /// effectively disables the trigger (the unit-test paths that
    /// call `collect` directly do this when they want full control
    /// over when GC fires).
    gc_threshold: u32 = 16384,
    /// Allocation count that triggers a *minor* (young-only)
    /// collection. The two-tier dispatch: a minor cycle fires
    /// when `allocs_since_gc` crosses this; a major cycle when
    /// `minor_cycles_since_full` reaches `full_every_n_minor`
    /// (or the byte threshold trips). Sized at a quarter of the
    /// major threshold — most allocations die young, so the cheap
    /// young sweep absorbs the bulk of the churn and the
    /// expensive full trace stays rare. `setGcThreshold` keeps
    /// this coherent with `gc_threshold`.
    gc_young_threshold: u32 = 4096,
    /// Number of minor cycles between forced major (full) cycles.
    /// The dispatch fires a minor cycle on young-threshold
    /// pressure; every `full_every_n_minor`-th minor cycle is
    /// promoted to a major cycle so mature garbage (and any
    /// remembered-set residue) is reclaimed periodically. Bounded
    /// so even a `--gc-threshold=1` stress run, where every
    /// allocation collects, still exercises `collectYoung` heavily
    /// while running a `collectFull` often enough to keep RSS
    /// bounded and the remembered set drained.
    full_every_n_minor: u32 = 8,
    /// Minor cycles run since the last major cycle. Reset to zero
    /// by `collectFull`; bumped by `collectYoung`. Drives the
    /// "promote to full every Nth minor" rule in the dispatch.
    minor_cycles_since_full: u32 = 0,
    /// Byte counterpart to `gc_threshold` — collect when the
    /// charged payload since the last sweep crosses this. 16 MiB
    /// is loose enough to leave small workloads count-gated while
    /// catching the property-escapes / huge-string-concat pattern
    /// (each `result += chunk` charges N bytes; without this,
    /// 80 += operations on a multi-MB result accumulate hundreds
    /// of MB of dead intermediates before the count-based trigger
    /// fires).
    gc_byte_threshold: usize = 16 * 1024 * 1024,
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
    /// Cumulative bytes charged across this heap's lifetime (never
    /// reset on GC). Dual of `bytes_live`, which only sees what's
    /// alive right now. Catches workloads that allocate-and-discard
    /// at high rates — e.g. a loop of `result += chunk` looks small
    /// in `bytes_live` (one buffer at a time) but huge in
    /// `bytes_alloc_total` (every intermediate). Drives the harness
    /// `--mem-summary` / `--top-alloc` reports.
    bytes_alloc_total: u64 = 0,
    /// High-water mark of `bytes_live` reached during this heap's
    /// lifetime. Different from per-fixture RSS delta — that's a
    /// process-level peak (includes binary, libc, allocator slack);
    /// this is the engine's *charged* peak (the slice that GC could
    /// theoretically reclaim).
    bytes_live_peak: usize = 0,
    /// Total `collect()` cycles run on this heap. Independent of
    /// `gc_stats_cycle` (which only bumps when `gc_stats` is on).
    gc_cycles_total: u32 = 0,
    /// Accumulated GC pause time in nanoseconds across every
    /// `collect()` cycle. Average pause = `gc_time_ns_total /
    /// gc_cycles_total`.
    gc_time_ns_total: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator, .bytes_allocator = allocator };
    }

    /// Same as `init` but with a distinct allocator for large heap-
    /// owned byte payloads (`JSString.bytes`, ArrayBuffer slabs).
    /// See `bytes_allocator` for the motivation.
    pub fn initWithBytesAllocator(
        allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
    ) Heap {
        return .{ .allocator = allocator, .bytes_allocator = bytes_allocator };
    }

    /// Set the GC pressure threshold from a single harness knob
    /// (`--gc-threshold=<n>`). `n` becomes the *minor* threshold —
    /// a young collection fires every `n` allocations — and the
    /// *major* count threshold is set to `n * full_every_n_minor`
    /// so a full cycle still lands on the count path at the same
    /// total allocation cadence as before the two-tier split,
    /// while the minor-cycle counter promotes to full every
    /// `full_every_n_minor` minor cycles regardless. The upshot:
    /// `--gc-threshold=1` collects (minor) on every allocation and
    /// runs a full cycle every `full_every_n_minor`-th — the exact
    /// stress profile the generational collector needs exercised.
    pub fn setGcThreshold(self: *Heap, n: u32) void {
        self.gc_young_threshold = n;
        self.gc_threshold = n *| self.full_every_n_minor;
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
        self.bytes_since_gc +|= n;
        self.bytes_alloc_total +|= n;
        if (new_total > self.bytes_live_peak) self.bytes_live_peak = new_total;
    }

    /// Decrease the live byte counter. Idempotent w.r.t. the GC
    /// (any inaccuracy gets corrected on the next sweep).
    pub fn discharge(self: *Heap, n: usize) void {
        self.bytes_live = if (n >= self.bytes_live) 0 else self.bytes_live - n;
    }

    /// Free every tracked object and the bookkeeping arrays.
    /// Idempotent — safe to call on a partially-initialized heap.
    pub fn deinit(self: *Heap) void {
        for (self.strings_young.items) |s| s.deinit(self.allocator, self.bytes_allocator);
        for (self.strings_mature.items) |s| s.deinit(self.allocator, self.bytes_allocator);
        self.strings_young.deinit(self.allocator);
        self.strings_mature.deinit(self.allocator);
        for (self.functions_young.items) |f| f.deinit(self.allocator);
        for (self.functions_mature.items) |f| f.deinit(self.allocator);
        self.functions_young.deinit(self.allocator);
        self.functions_mature.deinit(self.allocator);
        for (self.objects_young.items) |o| o.deinit(self.allocator);
        for (self.objects_mature.items) |o| o.deinit(self.allocator);
        self.objects_young.deinit(self.allocator);
        self.objects_mature.deinit(self.allocator);
        for (self.environments_young.items) |e| e.deinit(self.allocator);
        for (self.environments_mature.items) |e| e.deinit(self.allocator);
        self.environments_young.deinit(self.allocator);
        self.environments_mature.deinit(self.allocator);
        for (self.generators_young.items) |g| g.deinit(self.allocator);
        for (self.generators_mature.items) |g| g.deinit(self.allocator);
        self.generators_young.deinit(self.allocator);
        self.generators_mature.deinit(self.allocator);
        for (self.symbols_young.items) |s| s.deinit(self.allocator);
        for (self.symbols_mature.items) |s| s.deinit(self.allocator);
        self.symbols_young.deinit(self.allocator);
        self.symbols_mature.deinit(self.allocator);
        self.symbol_registry.deinit(self.allocator);
        for (self.bigints_young.items) |b| b.deinit(self.allocator);
        for (self.bigints_mature.items) |b| b.deinit(self.allocator);
        self.bigints_young.deinit(self.allocator);
        self.bigints_mature.deinit(self.allocator);
        self.remembered.deinit(self.allocator);
        self.handle_scopes.deinit(self.allocator);
    }

    pub fn allocateBigInt(self: *Heap, value: i128) !*JSBigInt {
        const b = try JSBigInt.init(self.allocator, value);
        errdefer b.deinit(self.allocator);
        try self.bigints_young.append(self.allocator, b);
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
        try self.symbols_young.append(self.allocator, s);
        self.allocs_since_gc +|= 1;
        return s;
    }

    /// Look up an existing Symbol by its stored `prop_key`. Used
    /// by `Reflect.ownKeys` / Object key enumeration where Cynic
    /// stores symbol-keyed entries under their string key
    /// (`@@iterator`, `<sym:N>`) and needs the actual Symbol value
    /// back for the output array. Linear scan — symbol count is
    /// small (well-known + a handful of user-allocated). Returns
    /// `null` for keys with no registered Symbol.
    pub fn symbolForKey(self: *Heap, prop_key: []const u8) ?*JSSymbol {
        for (self.symbols_young.items) |s| {
            if (std.mem.eql(u8, s.prop_key, prop_key)) return s;
        }
        for (self.symbols_mature.items) |s| {
            if (std.mem.eql(u8, s.prop_key, prop_key)) return s;
        }
        return null;
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
        try self.symbols_young.append(self.allocator, s);
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
        try self.generators_young.append(self.allocator, g);
        self.allocs_since_gc +|= 1;
        return g;
    }

    pub fn allocateObject(self: *Heap) !*JSObject {
        const o = try JSObject.init(self.allocator);
        errdefer o.deinit(self.allocator);
        try self.objects_young.append(self.allocator, o);
        self.allocs_since_gc +|= 1;
        return o;
    }

    /// Allocate a new `Environment` chained to `parent`, with
    /// `slot_count` bindings initialised to the TDZ Hole.
    pub fn allocateEnvironment(self: *Heap, parent: ?*Environment, slot_count: u8) !*Environment {
        const env = try Environment.init(self.allocator, parent, slot_count);
        errdefer env.deinit(self.allocator);
        try self.environments_young.append(self.allocator, env);
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
        try self.functions_young.append(self.allocator, f);
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
        try self.functions_young.append(self.allocator, f);
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
            // Freshly heap-allocated flat string — known-flat.
            f.name = name_str.flatBytes();
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
        const s = try JSString.init(self.allocator, self.bytes_allocator, src);
        errdefer s.deinit(self.allocator, self.bytes_allocator);
        try self.strings_young.append(self.allocator, s);
        self.allocs_since_gc +|= 1;
        return s;
    }

    /// Allocate a string that is `a ++ b`, owned by the heap.
    /// Stage 1 (ConsString): produces a flat result — `JSString.
    /// concat` flattens both operands and allocates the joined
    /// buffer in one shot. No rope is built.
    pub fn concatStrings(self: *Heap, a: *JSString, b: *JSString) !*JSString {
        try self.charge(a.byte_len + b.byte_len + @sizeOf(JSString));
        const s = try JSString.concat(self.allocator, self.bytes_allocator, a, b);
        errdefer s.deinit(self.allocator, self.bytes_allocator);
        try self.strings_young.append(self.allocator, s);
        self.allocs_since_gc +|= 1;
        return s;
    }

    /// Allocate a `ConsString` (lazy rope) node for `a ++ b`.
    ///
    /// Stage 2 of the ConsString effort: this builds a real lazy
    /// `.cons` node so `a + b` is amortised O(1) instead of an
    /// O(n) byte copy — subject to three gates. When any gate
    /// rejects the rope, it falls through to the eager flat
    /// `concatStrings` path (identical observable result).
    ///
    /// - **Gate A — min length.** Below `min_cons_byte_len` total
    ///   bytes, a cons header (two pointers + JSString header,
    ///   ~32 B) costs more than the copy it saves and only deepens
    ///   the tree. Eager-flatten.
    /// - **Gate B — WTF-8 dirty surrogate seam (§6.1.4).** A
    ///   *valid* surrogate pair must be stored as the single 4-byte
    ///   form, never two adjacent 3-byte CESU-8 escapes. When the
    ///   rightmost flat leaf of `a` ends with a lone high surrogate
    ///   and the leftmost flat leaf of `b` starts with a lone low
    ///   surrogate, a plain leaf-concat would leave that seam dirty.
    ///   A cons node cannot represent the merge, so such a concat
    ///   eager-flattens (`concatStrings` → `concatBytes` merges the
    ///   seam). This keeps every cons tree trivially clean —
    ///   `flatten` is then a pure leaf-memcpy with no seam logic and
    ///   `byte_len = a.byte_len + b.byte_len` exactly.
    /// - **Gate C — depth cap.** A `result += chunk` loop builds a
    ///   left-leaning spine of depth = iteration count; unbounded
    ///   depth means `flatten` / `markString` recurse / iterate
    ///   without bound. When the new node would exceed
    ///   `max_rope_depth`, the deeper operand is flattened first so
    ///   the new node's depth resets. The loop stays amortised
    ///   O(1) per `+=` (a flatten only every `max_rope_depth`
    ///   steps) while no rope ever exceeds the cap.
    pub fn allocateConsString(self: *Heap, a: *JSString, b: *JSString) !*JSString {
        var left = a;
        var right = b;

        // Gate A — min-length threshold. `byte_len` is O(1).
        const total: usize = @as(usize, left.byte_len) + @as(usize, right.byte_len);
        if (total < string_mod.min_cons_byte_len) {
            return self.concatStrings(left, right);
        }

        // Gate B — WTF-8 dirty surrogate seam. Inspect the rightmost
        // flat leaf of `left` and the leftmost flat leaf of `right`;
        // every existing cons tree is already clean (this gate
        // guarantees it), so the seam is decided entirely by those
        // two leaves — an O(depth) spine walk, no materialisation.
        const left_tail = left.rightmostLeaf().flatBytes();
        const right_head = right.leftmostLeaf().flatBytes();
        if (utf16.wtf8ConcatSeamPairs(left_tail, right_head)) {
            return self.concatStrings(left, right);
        }

        // Gate C — depth cap. The new node's depth would be
        // `1 + max(left.depth, right.depth)`. If that exceeds the
        // cap, flatten the deeper operand first (then, in the rare
        // both-deep case, the other) so the resulting depth stays
        // bounded. In the dominant `result += chunk` loop only
        // `left` is deep, so this flattens once every
        // `max_rope_depth` iterations — still amortised O(1).
        if (1 + @max(left.depth, right.depth) > string_mod.max_rope_depth) {
            // `flatten` allocates a fresh `byte_len`-sized buffer; it
            // has no `Heap` in scope, so charge the byte trigger here
            // (the leaf buffers it concatenates were already charged
            // at their `allocateString`, but the materialised copy is
            // new live memory until the next sweep frees the leaves).
            if (left.depth >= right.depth) {
                if (!left.isFlat()) try self.charge(left.byte_len);
                _ = try left.flatten(self.bytes_allocator);
            } else {
                if (!right.isFlat()) try self.charge(right.byte_len);
                _ = try right.flatten(self.bytes_allocator);
            }
            if (1 + @max(left.depth, right.depth) > string_mod.max_rope_depth) {
                // Both operands were deep — flatten the other too.
                if (left.depth >= right.depth) {
                    if (!left.isFlat()) try self.charge(left.byte_len);
                    _ = try left.flatten(self.bytes_allocator);
                } else {
                    if (!right.isFlat()) try self.charge(right.byte_len);
                    _ = try right.flatten(self.bytes_allocator);
                }
            }
        }
        const new_depth: usize = 1 + @max(left.depth, right.depth);

        // All gates passed — build a real lazy cons node. The total
        // byte length is exact (Gate B ruled out a seam merge) and
        // both `length_cu` figures are O(1) stored values.
        if (total > string_mod.max_byte_len) return error.StringTooLong;
        try self.charge(@sizeOf(JSString));
        const s = try self.allocator.create(JSString);
        errdefer self.allocator.destroy(s);
        s.* = .{
            .length_cu = left.length_cu + right.length_cu,
            .byte_len = @intCast(total),
            .depth = @intCast(new_depth),
            .payload = .{ .cons = .{
                .left = left,
                .right = right,
                .heap = self,
            } },
        };
        try self.strings_young.append(self.allocator, s);
        self.allocs_since_gc +|= 1;
        return s;
    }

    /// Allocate a heap-owned string that is the concatenation of two
    /// raw WTF-8 byte slices, in a single allocation. Dual of
    /// `concatStrings` for callers (the `+` operator) whose operands
    /// were ToString-coerced into scratch slices rather than
    /// `JSString`s — saves the throwaway intermediate buffer +
    /// second copy that `allocateString(scratch)` would incur.
    pub fn allocateStringConcat2(self: *Heap, a: []const u8, b: []const u8) !*JSString {
        try self.charge(a.len + b.len + @sizeOf(JSString));
        const s = try JSString.concatBytes(self.allocator, self.bytes_allocator, a, b);
        errdefer s.deinit(self.allocator, self.bytes_allocator);
        try self.strings_young.append(self.allocator, s);
        self.allocs_since_gc +|= 1;
        return s;
    }

    /// Mark a `JSString` and, when it is a cons (rope) node, its
    /// `left` / `right` children. Idempotent — the `!marked` guard
    /// stops the recursion at an already-visited node. Strings form
    /// a DAG with no cycles (a cons child is allocated strictly
    /// before its parent), so the guard is enough; no cycle break
    /// is needed.
    ///
    /// Stage 1 of the ConsString effort builds no cons node, so the
    /// recursive arm here is exercised only by the hand-built-cons
    /// unit test below. It is in place so a later stage that does
    /// create ropes has a correct mark walk from day one.
    pub fn markString(self: *Heap, s: *JSString) void {
        if (s.marked) return;
        s.marked = true;
        switch (s.payload) {
            .flat => {},
            .cons => |c| {
                self.markString(c.left);
                self.markString(c.right);
            },
        }
    }

    /// Mark a single value if it carries a heap pointer. Idempotent.
    /// handles `String` and `Object` (where Object is
    /// currently always a `JSFunction`). later generalises Object
    /// once shapes / plain objects land.
    pub fn markValue(self: *Heap, v: Value) void {
        if (v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(v.asString()));
            self.markString(s);
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
                // Heap-allocated JSStrings backing computed property
                // keys (`fn[expr] = v`). The property map holds only
                // the `bytes` slice — without this the key dangles.
                for (f.key_anchors.items) |s| s.marked = true;
                if (f.prototype) |p| self.markValue(taggedObject(p));
                // §15.3 ArrowFunction lexical captures — `this` and
                // `new.target` are stamped at MakeFunction time and
                // may be the only roots holding their referents
                // alive. Without these the captured instance can be
                // swept while the arrow is still callable.
                self.markValue(f.captured_this);
                self.markValue(f.captured_new_target);
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
                // §15.2.1.16.3 ResolveExport chain — re-export
                // redirects pin their target namespace alive so a
                // module that's only reachable via another
                // module's `export { X as Y } from "src"` survives
                // GC for as long as the importer's namespace does.
                // `target_key` is a chunk-constant slice (pinned
                // at chunk-finalise time) — no anchor needed.
                var nrit = o.namespace_redirects.iterator();
                while (nrit.next()) |entry| {
                    self.markValue(taggedObject(entry.value_ptr.target_ns));
                }
                if (o.boxed_primitive) |bp| self.markValue(bp);
                // §22.1.3 `[[StringData]]` — the JSString a `String`
                // wrapper boxes; a typed slot, not a property.
                if (o.boxed_string) |bs| self.markString(bs);
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
                if (o.array_like_iter) |s| {
                    self.markValue(s.target);
                    self.markValue(s.for_in_source);
                }
                if (o.iter_helper) |s| {
                    self.markValue(s.source);
                    self.markValue(s.next_fn);
                    self.markValue(s.payload);
                    self.markValue(s.active);
                }
                if (o.capability_record) |c| {
                    self.markValue(c.resolve);
                    self.markValue(c.reject);
                }
                if (o.finally_callback) |f| self.markValue(taggedFunction(f));
                self.markValue(o.finally_value);
                if (o.finally_constructor) |f| self.markValue(taggedFunction(f));
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
                // §10.5 Proxy exotic — `[[ProxyTarget]]` /
                // `[[ProxyHandler]]` are typed slots, not properties;
                // a reachable Proxy must keep both alive.
                if (o.proxy_target) |pt| self.markValue(taggedObject(pt));
                if (o.proxy_handler) |ph| self.markValue(taggedObject(ph));
                if (o.proxy_target_fn) |ptf| self.markValue(taggedFunction(ptf));
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
            // A pinned chunk-constant string is permanently live;
            // mark it `.mature` so a young collection treats it as
            // an old object. The string may still physically sit in
            // `strings_young` (it was allocated there during
            // compile, before `pinChunk` ran) — `collectYoung`
            // relinks any such pinned straggler into
            // `strings_mature` when it sweeps.
            s.generation = .mature;
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
        // §27.6.3.4 — every buffered AsyncGeneratorRequest holds
        // both a completion value (the `.next(v)` / `.return(v)` /
        // `.throw(v)` arg) and the capability Promise we'll later
        // settle. Both must stay reachable for as long as the
        // request is queued.
        for (gen.queue.items) |req| {
            switch (req.completion) {
                .normal => |v| self.markValue(v),
                .return_value => |v| self.markValue(v),
                .throw_value => |v| self.markValue(v),
            }
            self.markValue(taggedObject(req.capability_promise));
        }
    }

    // ── Live-count accessors ────────────────────────────────────
    // The per-kind lists are split young / mature; these report
    // the combined live count so diagnostics and callers don't
    // care about the split.

    pub fn stringCount(self: *const Heap) usize {
        return self.strings_young.items.len + self.strings_mature.items.len;
    }
    pub fn functionCount(self: *const Heap) usize {
        return self.functions_young.items.len + self.functions_mature.items.len;
    }
    pub fn objectCount(self: *const Heap) usize {
        return self.objects_young.items.len + self.objects_mature.items.len;
    }
    pub fn environmentCount(self: *const Heap) usize {
        return self.environments_young.items.len + self.environments_mature.items.len;
    }
    pub fn generatorCount(self: *const Heap) usize {
        return self.generators_young.items.len + self.generators_mature.items.len;
    }
    pub fn symbolCount(self: *const Heap) usize {
        return self.symbols_young.items.len + self.symbols_mature.items.len;
    }
    pub fn bigintCount(self: *const Heap) usize {
        return self.bigints_young.items.len + self.bigints_mature.items.len;
    }

    /// Sweep one per-kind list (reverse walk so `swapRemove` stays
    /// O(1)). An unmarked entry is `deinit`'d and removed; a marked
    /// entry has its bit cleared and stays. `JSString` carries a
    /// `pinned` flag (chunk constants) — pinned entries are skipped
    /// untouched. `deinit_args` is forwarded to each freed entry's
    /// `deinit` (strings need the bytes allocator; everyone else
    /// just the struct allocator). `list` is `*ArrayListUnmanaged(*T)`;
    /// passed as `anytype` because Zig has no way to spell a list
    /// generic over the element type at a non-generic call site.
    fn sweepList(list: anytype, deinit_args: anytype) void {
        var i: usize = list.items.len;
        while (i > 0) {
            i -= 1;
            const entry = list.items[i];
            const EntryT = @typeInfo(@TypeOf(entry)).pointer.child;
            const has_pinned = @hasField(EntryT, "pinned");
            if (has_pinned and entry.pinned) {
                // Permanently live (chunk constants). Skip. A
                // pinned string never enters the remembered set
                // (strings aren't barriered containers), so no bit
                // to clear here.
            } else if (entry.marked) {
                entry.marked = false;
                // A full trace already visited this survivor, so
                // any remembered-set membership is now stale. Clear
                // the bit (the set itself is emptied by the caller)
                // so the next young cycle can re-record a genuine
                // old→young store into it.
                if (@hasField(EntryT, "in_remembered_set")) {
                    entry.in_remembered_set = false;
                }
            } else {
                _ = list.swapRemove(i);
                @call(.auto, EntryT.deinit, .{entry} ++ deinit_args);
            }
        }
    }

    /// Run a full mark-sweep cycle across BOTH generations. `roots`
    /// is every live value the caller wants to keep. Anything
    /// reachable only through values outside `roots` (and outside
    /// any open `HandleScope`) is freed. After this call every
    /// surviving object's `marked` bit is back to `false`.
    ///
    /// A full cycle also **tenures every survivor**: young
    /// survivors are relinked into the mature list and their
    /// generation bit flipped. This is mandatory for a correct
    /// generational invariant — after a full cycle there are no
    /// young objects at all, so no mature→young edge can exist,
    /// so the (now-cleared) remembered set is trivially complete.
    /// Without this, a full cycle could leave a mature object
    /// pointing at a surviving-but-still-young object while having
    /// cleared the remembered set, and the next `collectYoung`
    /// would free that young object out from under it.
    pub fn collectFull(self: *Heap, roots: []const Value) void {
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
        // Registered symbols stay alive forever (GlobalSymbolRegistry
        // is a strong reference). Mark them before the sweep.
        {
            var rit = self.symbol_registry.iterator();
            while (rit.next()) |e| e.value_ptr.*.marked = true;
        }

        // Snapshot pre-sweep counts for the diagnostic report.
        const pre_objs = self.objectCount();
        const pre_strs = self.stringCount();
        const pre_fns = self.functionCount();
        const pre_envs = self.environmentCount();
        const pre_gens = self.generatorCount();
        const pre_syms = self.symbolCount();
        const pre_bigs = self.bigintCount();

        // Sweep phase. The mature lists are swept in place; the
        // young lists are swept-AND-promoted — every young survivor
        // is relinked into its mature list. After this, the young
        // lists are empty, so the generational invariant "no
        // mature→young edge outside the remembered set" holds
        // trivially (there are no young objects to point at).
        const ba = .{ self.allocator, self.bytes_allocator };
        const sa = .{self.allocator};
        sweepList(&self.strings_mature, ba);
        sweepList(&self.functions_mature, sa);
        sweepList(&self.objects_mature, sa);
        sweepList(&self.environments_mature, sa);
        sweepList(&self.generators_mature, sa);
        sweepList(&self.symbols_mature, sa);
        sweepList(&self.bigints_mature, sa);
        promoteYoungList(*JSString, &self.strings_young, &self.strings_mature, self.allocator, ba);
        promoteYoungList(*JSFunction, &self.functions_young, &self.functions_mature, self.allocator, sa);
        promoteYoungList(*JSObject, &self.objects_young, &self.objects_mature, self.allocator, sa);
        promoteYoungList(*Environment, &self.environments_young, &self.environments_mature, self.allocator, sa);
        promoteYoungList(*JSGenerator, &self.generators_young, &self.generators_mature, self.allocator, sa);
        promoteYoungList(*JSSymbol, &self.symbols_young, &self.symbols_mature, self.allocator, sa);
        promoteYoungList(*JSBigInt, &self.bigints_young, &self.bigints_mature, self.allocator, sa);

        // The remembered set is empty after a full cycle — a full
        // mark visited every mature object, and every survivor is
        // now mature, so no old→young edge can exist. `sweepList` /
        // `promoteYoungList` cleared the `in_remembered_set` bit on
        // every survivor, so the set just needs emptying here.
        self.remembered.clearRetainingCapacity();

        // Reset the allocation pressure counters so the next
        // collect doesn't fire until fresh allocations cross
        // a threshold again. A full cycle also resets the
        // minor-cycle counter — the two-tier dispatch counts
        // minor cycles since the last full one.
        self.allocs_since_gc = 0;
        self.bytes_since_gc = 0;
        self.minor_cycles_since_full = 0;

        // Always-on cycle accounting (cheap; drives the harness
        // `--mem-summary` line).
        const elapsed_ns_total: i128 = monotonicNs() - t_start;
        self.gc_cycles_total +|= 1;
        if (elapsed_ns_total > 0) self.gc_time_ns_total +|= @intCast(elapsed_ns_total);

        // Per-cycle diagnostic report — flagged on by the
        // `--gc-stats` test262 harness option (or by hand for
        // ad-hoc debugging). Format: `[gc N] kind=pre→post ...`.
        // A kind whose `post` keeps climbing across cycles is
        // being kept alive by something that should let go.
        // `std.debug.print` reaches for the std threaded-IO stderr
        // path, which a `wasm32-freestanding` target cannot provide
        // (no `getrandom`, no libc). `gc_stats` is a harness-only
        // diagnostic — never set in the WASM playground build — so
        // compile the report out entirely on freestanding.
        if (self.gc_stats and @import("builtin").os.tag != .freestanding) {
            self.gc_stats_cycle += 1;
            const elapsed_us: i128 = @divTrunc(elapsed_ns_total, 1000);
            std.debug.print(
                "[gc {d}] full {d}\u{00B5}s live={d}KB peak={d}KB alloc_total={d}KB obj={d}\u{2192}{d} str={d}\u{2192}{d} fn={d}\u{2192}{d} env={d}\u{2192}{d} gen={d}\u{2192}{d} sym={d}\u{2192}{d} big={d}\u{2192}{d}\n",
                .{
                    self.gc_stats_cycle,
                    elapsed_us,
                    self.bytes_live / 1024,
                    self.bytes_live_peak / 1024,
                    self.bytes_alloc_total / 1024,
                    pre_objs,
                    self.objectCount(),
                    pre_strs,
                    self.stringCount(),
                    pre_fns,
                    self.functionCount(),
                    pre_envs,
                    self.environmentCount(),
                    pre_gens,
                    self.generatorCount(),
                    pre_syms,
                    self.symbolCount(),
                    pre_bigs,
                    self.bigintCount(),
                },
            );
        }
    }

    /// Run a minor (young-generation) mark-sweep cycle. Only the
    /// young lists are swept; the mature lists are left untouched.
    /// `roots` plus every open handle scope plus the realm roots
    /// (the caller marks those before calling) seed the trace.
    ///
    /// Three additional root sources peculiar to a minor cycle:
    ///
    ///  1. **The remembered set.** Every mature container the write
    ///     barrier observed storing a young pointer is marked
    ///     transitively — its property bag, elements, env slots and
    ///     internal slots become roots. Without this a young object
    ///     reachable only from old space would be swept.
    ///  2. **Mature typed internal slots.** Roughly 240 raw
    ///     `container.field = young` writes in `builtins/*.zig` and
    ///     the object model bypass the Stage-0 routed setters and so
    ///     never hit the write barrier (`prototype`, `home_object`,
    ///     `typed_view.viewed`, accessor halves, Map/Set entries,
    ///     bound-function state, …). Rather than barrier all 240
    ///     fragile sites, every minor cycle scans those typed slots
    ///     on every mature container directly — bounded by mature
    ///     object count × a fixed field set, far cheaper than the
    ///     mature property-bag walk a full cycle pays.
    ///  3. Marking from the realm roots (the caller's responsibility,
    ///     same set `collectFull` uses).
    ///
    /// Survivors in the young lists are **promoted** — relinked from
    /// the young list into the mature list of their kind and their
    /// `generation` bit flipped — and crucially the object's address
    /// never changes (Cynic's collector is non-moving; there are no
    /// JIT stack maps to fix up, which is the whole reason for the
    /// JSC-Riptide promotion-by-relink model).
    ///
    /// Because `markValue` recurses through mature objects too, the
    /// mark bit gets set on mature survivors as well; a minor sweep
    /// only clears bits on the young lists it sweeps, so this routine
    /// finishes with an explicit pass that clears the mark bit on
    /// every mature object — otherwise the next `collectFull` would
    /// see stale marks and leak.
    pub fn collectYoung(self: *Heap, roots: []const Value) void {
        const t_start = monotonicNs();

        // ── Mark phase ──────────────────────────────────────────
        for (roots) |r| self.markValue(r);
        for (self.handle_scopes.items) |scope| {
            for (scope.handles.items) |r| self.markValue(r);
        }
        {
            var rit = self.symbol_registry.iterator();
            while (rit.next()) |e| {
                const sym = e.value_ptr.*;
                if (sym.generation == .young) sym.marked = true;
            }
        }

        // Root source 1 — remembered set. Each recorded mature
        // container is a root edge into young: mark it (and via
        // `markValue`'s recursion, everything it reaches).
        for (self.remembered.items) |container| {
            switch (container) {
                .object => |o| self.markValue(taggedObject(o)),
                .function => |f| self.markValue(taggedFunction(f)),
                .environment => |e| self.markEnvironment(e),
                .generator => |g| self.markGenerator(g),
            }
        }

        // Root source 2 — typed internal slots on every mature
        // container. These raw-pointer fields bypass the barrier,
        // so they are scanned unconditionally on every minor cycle.
        for (self.objects_mature.items) |o| self.markObjectInternalSlots(o);
        for (self.functions_mature.items) |f| self.markFunctionInternalSlots(f);
        for (self.environments_mature.items) |e| {
            for (e.slots) |s| self.markValue(s);
        }
        for (self.generators_mature.items) |g| self.markGeneratorInternalSlots(g);

        // Snapshot pre-sweep young counts for the diagnostic line.
        const pre_objs = self.objects_young.items.len;
        const pre_strs = self.strings_young.items.len;
        const pre_fns = self.functions_young.items.len;
        const pre_envs = self.environments_young.items.len;
        const pre_gens = self.generators_young.items.len;
        const pre_syms = self.symbols_young.items.len;
        const pre_bigs = self.bigints_young.items.len;

        // ── Sweep + promote phase ───────────────────────────────
        // Young survivors are relinked into the mature list; young
        // garbage is freed. Mature lists are not touched.
        promoteYoungList(*JSString, &self.strings_young, &self.strings_mature, self.allocator, .{ self.allocator, self.bytes_allocator });
        promoteYoungList(*JSFunction, &self.functions_young, &self.functions_mature, self.allocator, .{self.allocator});
        promoteYoungList(*JSObject, &self.objects_young, &self.objects_mature, self.allocator, .{self.allocator});
        promoteYoungList(*Environment, &self.environments_young, &self.environments_mature, self.allocator, .{self.allocator});
        promoteYoungList(*JSGenerator, &self.generators_young, &self.generators_mature, self.allocator, .{self.allocator});
        promoteYoungList(*JSSymbol, &self.symbols_young, &self.symbols_mature, self.allocator, .{self.allocator});
        promoteYoungList(*JSBigInt, &self.bigints_young, &self.bigints_mature, self.allocator, .{self.allocator});

        // Clear the mark bit on every mature object. A minor sweep
        // only resets bits on the young lists it walks; the mark
        // phase above set bits on mature objects too (the trace
        // recurses through old space). Leaving them set would make
        // the next `collectFull` treat them as already-visited.
        for (self.objects_mature.items) |o| o.marked = false;
        for (self.functions_mature.items) |f| f.marked = false;
        for (self.environments_mature.items) |e| e.marked = false;
        for (self.generators_mature.items) |g| g.marked = false;
        for (self.strings_mature.items) |s| s.marked = false;
        for (self.symbols_mature.items) |s| s.marked = false;
        for (self.bigints_mature.items) |b| b.marked = false;

        // The remembered set is consumed by this cycle. Clear it and
        // every surviving container's `in_remembered_set` bit so the
        // next minor cycle starts from a clean slate; a still-live
        // old→young edge will be re-recorded by the barrier on its
        // next store (or, for a pre-existing edge, would be missed —
        // but the typed-slot scan covers internal slots and Stage-0
        // routing covers property writes, so a *new* store is what
        // re-arms it). Note: an edge created before this cycle and
        // not re-stored is still safe because the referent was
        // promoted to mature this cycle (it survived as a root), so
        // it no longer lives in young space.
        for (self.remembered.items) |container| container.setInRememberedSet(false);
        self.remembered.clearRetainingCapacity();

        // Reset allocation-pressure counters; count this minor
        // cycle toward the next forced major.
        self.allocs_since_gc = 0;
        self.bytes_since_gc = 0;
        self.minor_cycles_since_full +|= 1;

        const elapsed_ns_total: i128 = monotonicNs() - t_start;
        self.gc_cycles_total +|= 1;
        if (elapsed_ns_total > 0) self.gc_time_ns_total +|= @intCast(elapsed_ns_total);

        if (self.gc_stats and @import("builtin").os.tag != .freestanding) {
            self.gc_stats_cycle += 1;
            const elapsed_us: i128 = @divTrunc(elapsed_ns_total, 1000);
            std.debug.print(
                "[gc {d}] young {d}\u{00B5}s live={d}KB peak={d}KB alloc_total={d}KB obj={d}\u{2192}{d} str={d}\u{2192}{d} fn={d}\u{2192}{d} env={d}\u{2192}{d} gen={d}\u{2192}{d} sym={d}\u{2192}{d} big={d}\u{2192}{d}\n",
                .{
                    self.gc_stats_cycle,
                    elapsed_us,
                    self.bytes_live / 1024,
                    self.bytes_live_peak / 1024,
                    self.bytes_alloc_total / 1024,
                    pre_objs, self.objects_young.items.len,
                    pre_strs, self.strings_young.items.len,
                    pre_fns,  self.functions_young.items.len,
                    pre_envs, self.environments_young.items.len,
                    pre_gens, self.generators_young.items.len,
                    pre_syms, self.symbols_young.items.len,
                    pre_bigs, self.bigints_young.items.len,
                },
            );
        }
    }

    /// Sweep one young list, promoting marked survivors into the
    /// matching mature list. A reverse walk keeps `swapRemove` O(1).
    /// An unmarked entry is freed; a marked entry has its bit
    /// cleared, its `generation` flipped to `.mature`, and is moved
    /// to `mature_list` — the pointer never moves, only its list
    /// membership. A pinned string (chunk constant) is promoted
    /// without needing a mark (it is permanently live).
    fn promoteYoungList(
        comptime PtrT: type,
        young_list: *std.ArrayListUnmanaged(PtrT),
        mature_list: *std.ArrayListUnmanaged(PtrT),
        allocator: std.mem.Allocator,
        deinit_args: anytype,
    ) void {
        const EntryT = @typeInfo(PtrT).pointer.child;
        const has_pinned = @hasField(EntryT, "pinned");
        var i: usize = young_list.items.len;
        while (i > 0) {
            i -= 1;
            const entry = young_list.items[i];
            const live = (has_pinned and entry.pinned) or entry.marked;
            if (live) {
                entry.marked = false;
                entry.generation = .mature;
                if (@hasField(EntryT, "in_remembered_set")) {
                    entry.in_remembered_set = false;
                }
                _ = young_list.swapRemove(i);
                // Append to mature. On OOM the object would leak —
                // but the heap allocator already failed catastrophically
                // by this point; keep the object reachable rather than
                // free a survivor.
                mature_list.append(allocator, entry) catch {
                    young_list.append(allocator, entry) catch {};
                };
            } else {
                _ = young_list.swapRemove(i);
                @call(.auto, EntryT.deinit, .{entry} ++ deinit_args);
            }
        }
    }

    /// Mark the typed internal-slot pointers of a `JSObject` —
    /// everything `markValue` reaches for an object EXCEPT the
    /// property bag / element vector (those are covered by the
    /// Stage-0-routed write barrier + remembered set). Used by
    /// `collectYoung` to root young objects reachable only through
    /// a raw `mature_obj.field = young` write in a builtin.
    fn markObjectInternalSlots(self: *Heap, o: *JSObject) void {
        // §15.7 private instance fields — a typed internal map, not
        // the property bag, so the remembered set never covers it and
        // it must be scanned unconditionally here. The full `markValue`
        // object arm walks it; this abbreviated copy had dropped it,
        // so a mature instance's young `#field` value was swept out
        // from under it.
        var ppit = o.private_properties.iterator();
        while (ppit.next()) |entry| self.markValue(entry.value_ptr.*);
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
        var nrit = o.namespace_redirects.iterator();
        while (nrit.next()) |entry| {
            self.markValue(taggedObject(entry.value_ptr.target_ns));
        }
        if (o.boxed_primitive) |bp| self.markValue(bp);
        if (o.boxed_string) |bs| self.markString(bs);
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
        if (o.array_like_iter) |s| {
            self.markValue(s.target);
            self.markValue(s.for_in_source);
        }
        if (o.iter_helper) |s| {
            self.markValue(s.source);
            self.markValue(s.next_fn);
            self.markValue(s.payload);
            self.markValue(s.active);
        }
        if (o.capability_record) |c| {
            self.markValue(c.resolve);
            self.markValue(c.reject);
        }
        if (o.finally_callback) |f| self.markValue(taggedFunction(f));
        self.markValue(o.finally_value);
        if (o.finally_constructor) |f| self.markValue(taggedFunction(f));
        if (o.generator_ref) |gen| self.markGenerator(gen);
        if (o.is_weak_ref) self.markValue(o.weak_ref_target);
        if (o.finalization_cells) |fc| {
            self.markValue(fc.cleanup_callback);
            for (fc.cells.items) |cell| {
                if (cell.deleted) continue;
                self.markValue(cell.target);
                self.markValue(cell.held_value);
                if (cell.has_token) self.markValue(cell.unregister_token);
            }
        }
        for (o.key_anchors.items) |s| self.markString(s);
        for (o.promise_reactions.items) |r| {
            self.markValue(r.on_fulfilled);
            self.markValue(r.on_rejected);
            self.markValue(r.result_promise);
        }
        for (o.promise_waiters.items) |w| self.markGenerator(w);
        if (o.promise_state != .none) self.markValue(o.promise_value);
        if (o.regexp_source) |s| self.markString(s);
        if (o.regexp_flags) |s| self.markString(s);
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
        if (o.proxy_target) |pt| self.markValue(taggedObject(pt));
        if (o.proxy_handler) |ph| self.markValue(taggedObject(ph));
        if (o.proxy_target_fn) |ptf| self.markValue(taggedFunction(ptf));
        if (o.typed_view) |tv| self.markValue(taggedObject(tv.viewed));
        if (o.data_view) |dv| self.markValue(taggedObject(dv.viewed));
    }

    /// Mark the typed internal-slot pointers of a `JSFunction` —
    /// the `markValue` function arm minus the property bag.
    fn markFunctionInternalSlots(self: *Heap, f: *JSFunction) void {
        if (f.captured_env) |env| self.markEnvironment(env);
        for (f.key_anchors.items) |s| self.markString(s);
        var fait = f.accessors.iterator();
        while (fait.next()) |entry| {
            if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
            if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
        }
        var fpit = f.private_properties.iterator();
        while (fpit.next()) |entry| self.markValue(entry.value_ptr.*);
        var fpait = f.private_accessors.iterator();
        while (fpait.next()) |entry| {
            if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
            if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
        }
        if (f.prototype) |p| self.markValue(taggedObject(p));
        self.markValue(f.captured_this);
        self.markValue(f.captured_new_target);
        if (f.bound_target) |bt| self.markValue(taggedFunction(bt));
        self.markValue(f.bound_this);
        if (f.bound_args) |ba| {
            for (ba) |a| self.markValue(a);
        }
        if (f.name_string) |s| self.markString(s);
    }

    /// Mark the typed internal-slot pointers of a `JSGenerator`.
    fn markGeneratorInternalSlots(self: *Heap, g: *JSGenerator) void {
        for (g.registers) |s| self.markValue(s);
        self.markValue(g.accumulator);
        self.markValue(g.this_value);
        if (g.env) |e| self.markEnvironment(e);
        if (g.home_object) |ho| self.markValue(taggedObject(ho));
        for (g.queue.items) |req| {
            switch (req.completion) {
                .normal => |v| self.markValue(v),
                .return_value => |v| self.markValue(v),
                .throw_value => |v| self.markValue(v),
            }
            self.markValue(taggedObject(req.capability_promise));
        }
    }

    /// Debug-only remembered-set verifier. Before a minor cycle,
    /// walk every mature container and assert that any
    /// mature→young pointer edge living in a *property bag*,
    /// *element vector*, or *environment slot* — the edge classes
    /// the Stage-0 routed setters are responsible for barriering —
    /// is covered by the remembered set. A missing entry names the
    /// exact `(container, field, young-target)` triple.
    ///
    /// Typed internal slots (`prototype`, `viewed`, accessor
    /// halves, …) are deliberately NOT checked: `collectYoung`
    /// scans those directly on every mature container, so a raw
    /// write into one never needs a remembered-set entry. This
    /// verifier therefore only polices the routed-setter contract.
    ///
    /// Compiled to a no-op outside Debug / ReleaseSafe.
    pub fn verifyRememberedSet(self: *Heap) void {
        if (@import("builtin").mode != .Debug and
            @import("builtin").mode != .ReleaseSafe) return;

        for (self.objects_mature.items) |o| {
            // Property bag.
            var it = o.properties.iterator();
            while (it.next()) |entry| {
                if (isYoungHeapValue(entry.value_ptr.*) and !o.in_remembered_set) {
                    std.debug.print(
                        "verifyRememberedSet: un-barriered mature\u{2192}young edge: " ++
                            "JSObject {*} property \"{s}\" -> young {*}\n",
                        .{ o, entry.key_ptr.*, valueHeapPtr(entry.value_ptr.*) },
                    );
                    std.debug.assert(false);
                }
            }
            // Element vector.
            if (o.is_array_exotic) {
                if (o.is_sparse) {
                    var sit = o.sparse_elements.iterator();
                    while (sit.next()) |entry| {
                        if (isYoungHeapValue(entry.value_ptr.*) and !o.in_remembered_set) {
                            std.debug.print(
                                "verifyRememberedSet: un-barriered mature\u{2192}young edge: " ++
                                    "JSObject {*} sparse element [{d}] -> young {*}\n",
                                .{ o, entry.key_ptr.*, valueHeapPtr(entry.value_ptr.*) },
                            );
                            std.debug.assert(false);
                        }
                    }
                } else {
                    for (o.elements.items, 0..) |elem, idx| {
                        if (isYoungHeapValue(elem) and !o.in_remembered_set) {
                            std.debug.print(
                                "verifyRememberedSet: un-barriered mature\u{2192}young edge: " ++
                                    "JSObject {*} element [{d}] -> young {*}\n",
                                .{ o, idx, valueHeapPtr(elem) },
                            );
                            std.debug.assert(false);
                        }
                    }
                }
            }
        }
        for (self.functions_mature.items) |f| {
            var it = f.properties.iterator();
            while (it.next()) |entry| {
                if (isYoungHeapValue(entry.value_ptr.*) and !f.in_remembered_set) {
                    std.debug.print(
                        "verifyRememberedSet: un-barriered mature\u{2192}young edge: " ++
                            "JSFunction {*} property \"{s}\" -> young {*}\n",
                        .{ f, entry.key_ptr.*, valueHeapPtr(entry.value_ptr.*) },
                    );
                    std.debug.assert(false);
                }
            }
        }
        for (self.environments_mature.items) |e| {
            for (e.slots, 0..) |slot, idx| {
                if (isYoungHeapValue(slot) and !e.in_remembered_set) {
                    std.debug.print(
                        "verifyRememberedSet: un-barriered mature\u{2192}young edge: " ++
                            "Environment {*} slot [{d}] -> young {*}\n",
                        .{ e, idx, valueHeapPtr(slot) },
                    );
                    std.debug.assert(false);
                }
            }
        }
    }

    /// Deprecated spelling — `collect` is `collectFull`. Kept so
    /// the unit-test suite and any external caller compile while
    /// the rename propagates.
    pub fn collect(self: *Heap, roots: []const Value) void {
        self.collectFull(roots);
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

    // -----------------------------------------------------------------
    // Generational-GC store routing — the "merge firewall".
    //
    // Every interpreter store arm that assigns a value into a
    // heap-object field funnels through one of these four helpers.
    // Stage 0 (this commit) makes them pure pass-throughs over the
    // existing setters — zero behaviour change. Stage 2 prepends
    // the generational write barrier inside these same four bodies,
    // so the barrier lands in one place per store category rather
    // than in ~20 scattered opcode arms.
    //
    // The container types accepted are the four mutable heap kinds
    // that can hold a pointer to a younger object: `JSObject`,
    // `JSFunction`, `Environment`. Strings (`JSString`) are immutable
    // once built, so they need no store helper.
    // -----------------------------------------------------------------

    /// Tagged heap-container reference. The write barrier needs the
    /// container's generation bit and `in_remembered_set` flag; a
    /// young collection needs to re-find it as a root. This tagged
    /// union is that handle. Only the four mutable heap kinds that
    /// can hold a pointer to a younger object appear here — strings
    /// (immutable post-build) and the symbol / bigint primitives do
    /// not need a barriered store path.
    pub const Container = union(enum) {
        object: *JSObject,
        function: *JSFunction,
        environment: *Environment,
        generator: *JSGenerator,

        /// Generational age of the pointed-to container.
        pub fn generation(self: Container) Generation {
            return switch (self) {
                inline else => |p| p.generation,
            };
        }

        /// Whether the container is already in the remembered set.
        pub fn inRememberedSet(self: Container) bool {
            return switch (self) {
                inline else => |p| p.in_remembered_set,
            };
        }

        /// Set the container's remembered-set membership bit.
        pub fn setInRememberedSet(self: Container, v: bool) void {
            switch (self) {
                inline else => |p| p.in_remembered_set = v,
            }
        }
    };

    /// Store `v` into plain-object property `key` via §10.1.9
    /// `[[Set]]` bypass (`JSObject.set`). Stage 0: pass-through.
    pub fn storeProperty(
        self: *Heap,
        obj: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
    ) !void {
        self.writeBarrier(.{ .object = obj }, v);
        try obj.set(allocator, key, v);
    }

    /// Store `v` into plain-object property `key`, honouring
    /// §10.1.9 writability (`JSObject.setIfWritable`). Stage 0:
    /// pass-through; returns the setter's writable verdict.
    pub fn storePropertyIfWritable(
        self: *Heap,
        obj: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
    ) !bool {
        self.writeBarrier(.{ .object = obj }, v);
        return obj.setIfWritable(allocator, key, v);
    }

    /// Store `v` into plain-object property `key` with explicit
    /// descriptor flags (`JSObject.setWithFlags`). Stage 0:
    /// pass-through.
    pub fn storePropertyWithFlags(
        self: *Heap,
        obj: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
        flags: @import("object.zig").PropertyFlags,
    ) !void {
        self.writeBarrier(.{ .object = obj }, v);
        try obj.setWithFlags(allocator, key, v, flags);
    }

    /// Store `v` into a function-object property `key` via the
    /// §10.2 ordinary `[[Set]]` bypass (`JSFunction.set`).
    /// Stage 0: pass-through.
    pub fn storeFunctionProperty(
        self: *Heap,
        fn_obj: *JSFunction,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
    ) !void {
        self.writeBarrier(.{ .function = fn_obj }, v);
        try fn_obj.set(allocator, key, v);
    }

    /// Store `v` into plain-object property keyed by `key_str`,
    /// anchoring the heap-allocated key JSString on the receiver
    /// (`JSObject.setComputedOwned`). Stage 0: pass-through.
    pub fn storePropertyComputedOwned(
        self: *Heap,
        obj: *JSObject,
        allocator: std.mem.Allocator,
        key_str: *JSString,
        v: Value,
    ) !void {
        self.writeBarrier(.{ .object = obj }, v);
        try obj.setComputedOwned(allocator, key_str, v);
    }

    /// Store `v` into a function-object property `key`, honouring
    /// §10.2 writability (`JSFunction.setIfWritable`). Stage 0:
    /// pass-through.
    pub fn storeFunctionPropertyIfWritable(
        self: *Heap,
        fn_obj: *JSFunction,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
    ) !bool {
        self.writeBarrier(.{ .function = fn_obj }, v);
        return fn_obj.setIfWritable(allocator, key, v);
    }

    /// Store `v` into an Array-exotic element slot `idx`
    /// (`JSObject.setIndexed`). Stage 0: pass-through.
    pub fn storeElement(
        self: *Heap,
        obj: *JSObject,
        allocator: std.mem.Allocator,
        idx: u32,
        v: Value,
    ) !void {
        self.writeBarrier(.{ .object = obj }, v);
        try obj.setIndexed(allocator, idx, v);
    }

    /// Store `v` into declarative-environment slot `slot`.
    /// Stage 0: pass-through (the raw slot write the interpreter
    /// `sta_env` arm used to do inline).
    pub fn storeEnvSlot(
        self: *Heap,
        env: *Environment,
        slot: usize,
        v: Value,
    ) void {
        self.writeBarrier(.{ .environment = env }, v);
        env.slots[slot] = v;
    }

    /// Record an old→young store into a *typed internal slot* of
    /// a heap container — `prototype`, `home_object`, accessor
    /// halves, Map/Set entry values, promise reaction fields, and
    /// the other fields the interpreter writes directly rather
    /// than through a property-bag setter. The caller performs the
    /// actual field assignment; this helper only runs the barrier.
    /// Stage 0: no-op (`writeBarrier` is a stub).
    pub fn storeInternalSlot(self: *Heap, container: Container, v: Value) void {
        self.writeBarrier(container, v);
    }

    /// Generational write barrier. Records an old→young store:
    /// when `container` is a mature object and `v` carries a young
    /// heap pointer, the container joins the remembered set so a
    /// young collection still treats it as a root for `v`.
    ///
    /// Hot path (the common case — a young container, since most
    /// stores happen while an object is still being built): one
    /// load of the container's `generation` and a not-taken
    /// branch. Only an old→young store touches the remembered set,
    /// and the `in_remembered_set` bit collapses repeated stores
    /// into the same container to a single list entry.
    ///
    /// `error.OutOfMemory` from the append is swallowed: a missed
    /// remembered-set entry would be a correctness bug, but the
    /// safety net is that the next `collectYoung` would then
    /// promote nothing and a fall-back `collectFull` still traces
    /// everything. In practice the list append almost never OOMs
    /// (amortised growth, tiny entries); a real OOM here means the
    /// process is already failing.
    pub fn writeBarrier(self: *Heap, container: Container, v: Value) void {
        // Fast reject — young container can't create an old→young
        // edge (a young→young store is reclaimed wholesale by the
        // young sweep).
        if (container.generation() != .mature) return;
        // Only a young heap pointer needs remembering. Primitives
        // (number, bool, null, undefined) and already-mature
        // referents are fine.
        if (!isYoungHeapValue(v)) return;
        // Already recorded — the bit collapses repeats.
        if (container.inRememberedSet()) return;
        container.setInRememberedSet(true);
        self.remembered.append(self.allocator, container) catch {
            // See doc comment — undo the bit so a later
            // collectFull (which clears the set) re-syncs cleanly,
            // and so a retry can still record the container.
            container.setInRememberedSet(false);
        };
    }
};

/// True when `v` carries a pointer to a `.young` heap object.
/// Used by the write barrier to decide whether a store into a
/// mature container creates an old→young edge worth remembering.
/// Strings are immutable but still age (a young string stored
/// into a mature object must be remembered); symbols and bigints
/// likewise carry a generation bit.
pub fn isYoungHeapValue(v: Value) bool {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.generation == .young;
    }
    if (valueAsFunction(v)) |f| return f.generation == .young;
    if (valueAsPlainObject(v)) |o| return o.generation == .young;
    if (valueAsSymbol(v)) |sym| return sym.generation == .young;
    if (valueAsBigInt(v)) |bi| return bi.generation == .young;
    return false;
}

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
    try testing.expectEqual(@as(usize, 1), heap.stringCount());

    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.stringCount());
}

test "Heap: fresh allocations land in the young generation" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const s = try heap.allocateString("y");
    const o = try heap.allocateObject();
    try testing.expectEqual(Generation.young, s.generation);
    try testing.expectEqual(Generation.young, o.generation);
    try testing.expectEqual(@as(usize, 1), heap.strings_young.items.len);
    try testing.expectEqual(@as(usize, 0), heap.strings_mature.items.len);
    try testing.expectEqual(@as(usize, 1), heap.objects_young.items.len);
    try testing.expectEqual(@as(usize, 0), heap.objects_mature.items.len);
}

test "Heap: collectFull sweeps both generations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // A young string (garbage) plus a mature one (hand-promoted)
    // — collectFull with empty roots must free BOTH.
    _ = try heap.allocateString("young-garbage");
    const mature = try heap.allocateString("mature-garbage");
    _ = heap.strings_young.pop();
    try heap.strings_mature.append(heap.allocator, mature);
    mature.generation = .mature;

    try testing.expectEqual(@as(usize, 2), heap.stringCount());
    heap.collectFull(&.{});
    try testing.expectEqual(@as(usize, 0), heap.stringCount());
}

test "Heap: collectFull keeps a rooted mature object" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const s = try heap.allocateString("kept");
    _ = heap.strings_young.pop();
    try heap.strings_mature.append(heap.allocator, s);
    s.generation = .mature;

    heap.collectFull(&.{Value.fromString(s)});
    try testing.expectEqual(@as(usize, 1), heap.stringCount());
    try testing.expectEqual(@as(usize, 1), heap.strings_mature.items.len);
}

test "Heap: write barrier records an old→young store" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // A mature container and a young referent — the canonical
    // old→young store the remembered set exists to track.
    const container = try heap.allocateObject();
    container.generation = .mature;
    const young = try heap.allocateObject();
    try testing.expectEqual(Generation.young, young.generation);

    try testing.expectEqual(@as(usize, 0), heap.remembered.items.len);
    heap.writeBarrier(.{ .object = container }, taggedObject(young));
    try testing.expectEqual(@as(usize, 1), heap.remembered.items.len);
    try testing.expect(container.in_remembered_set);

    // A second store into the same container collapses — the bit
    // guards against a duplicate entry.
    const young2 = try heap.allocateObject();
    heap.writeBarrier(.{ .object = container }, taggedObject(young2));
    try testing.expectEqual(@as(usize, 1), heap.remembered.items.len);
}

test "Heap: write barrier ignores a young container" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Young → young store: the young sweep handles both, so the
    // barrier must NOT remember anything.
    const container = try heap.allocateObject(); // young
    const young = try heap.allocateObject();
    heap.writeBarrier(.{ .object = container }, taggedObject(young));
    try testing.expectEqual(@as(usize, 0), heap.remembered.items.len);
    try testing.expect(!container.in_remembered_set);
}

test "Heap: write barrier ignores a mature→mature store" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Both sides mature — no old→young edge, nothing to remember.
    const container = try heap.allocateObject();
    container.generation = .mature;
    const referent = try heap.allocateObject();
    referent.generation = .mature;
    heap.writeBarrier(.{ .object = container }, taggedObject(referent));
    try testing.expectEqual(@as(usize, 0), heap.remembered.items.len);
}

test "Heap: write barrier ignores a primitive store" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Storing a non-heap value into a mature container carries no
    // edge — barrier must be a no-op.
    const container = try heap.allocateObject();
    container.generation = .mature;
    heap.writeBarrier(.{ .object = container }, Value.fromInt32(42));
    heap.writeBarrier(.{ .object = container }, Value.undefined_);
    try testing.expectEqual(@as(usize, 0), heap.remembered.items.len);
}

test "Heap: collectFull clears the remembered set and the bits" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const container = try heap.allocateObject();
    container.generation = .mature;
    _ = heap.objects_young.pop();
    try heap.objects_mature.append(heap.allocator, container);
    const young = try heap.allocateObject();
    heap.writeBarrier(.{ .object = container }, taggedObject(young));
    try testing.expectEqual(@as(usize, 1), heap.remembered.items.len);

    // Root the mature container so it survives the full sweep.
    heap.collectFull(&.{taggedObject(container)});
    try testing.expectEqual(@as(usize, 0), heap.remembered.items.len);
    try testing.expect(!container.in_remembered_set);

    // The bit really cleared — a fresh barrier can re-record it.
    const young2 = try heap.allocateObject();
    heap.writeBarrier(.{ .object = container }, taggedObject(young2));
    try testing.expectEqual(@as(usize, 1), heap.remembered.items.len);
}

test "Heap: collectYoung sweeps young garbage, leaves mature untouched" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // One mature object (hand-promoted) and one young garbage.
    const mature = try heap.allocateObject();
    _ = heap.objects_young.pop();
    try heap.objects_mature.append(heap.allocator, mature);
    mature.generation = .mature;
    _ = try heap.allocateObject(); // young garbage, unrooted

    try testing.expectEqual(@as(usize, 1), heap.objects_young.items.len);
    try testing.expectEqual(@as(usize, 1), heap.objects_mature.items.len);

    heap.collectYoung(&.{});

    // Young garbage freed; mature object untouched (not even
    // visited for sweeping).
    try testing.expectEqual(@as(usize, 0), heap.objects_young.items.len);
    try testing.expectEqual(@as(usize, 1), heap.objects_mature.items.len);
}

test "Heap: collectYoung promotes a young survivor by relink" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const survivor = try heap.allocateObject();
    const addr_before = @intFromPtr(survivor);
    try testing.expectEqual(Generation.young, survivor.generation);
    try testing.expectEqual(@as(usize, 1), heap.objects_young.items.len);

    heap.collectYoung(&.{taggedObject(survivor)});

    // Relinked into mature — same address (non-moving), bit flipped.
    try testing.expectEqual(@as(usize, 0), heap.objects_young.items.len);
    try testing.expectEqual(@as(usize, 1), heap.objects_mature.items.len);
    try testing.expectEqual(Generation.mature, survivor.generation);
    try testing.expectEqual(addr_before, @intFromPtr(survivor));
    try testing.expect(!survivor.marked);
}

test "Heap: collectYoung keeps a young object reachable from the remembered set" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // A mature container holding a young value in its property bag —
    // the canonical old→young edge the remembered set exists to
    // bridge during a minor cycle.
    const container = try heap.allocateObject();
    _ = heap.objects_young.pop();
    try heap.objects_mature.append(heap.allocator, container);
    container.generation = .mature;

    const young = try heap.allocateObject();
    try heap.storeProperty(container, heap.allocator, "k", taggedObject(young));
    try testing.expectEqual(@as(usize, 1), heap.remembered.items.len);

    // The young object is NOT in `roots`; only the remembered-set
    // entry keeps it alive.
    heap.collectYoung(&.{});

    // Survivor promoted; remembered set drained.
    try testing.expectEqual(@as(usize, 0), heap.objects_young.items.len);
    try testing.expectEqual(@as(usize, 2), heap.objects_mature.items.len);
    try testing.expectEqual(Generation.mature, young.generation);
    try testing.expectEqual(@as(usize, 0), heap.remembered.items.len);
    try testing.expect(!container.in_remembered_set);
}

test "Heap: collectYoung keeps a young object reachable from a mature typed slot" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // A mature object whose `prototype` typed internal slot points
    // at a young object via a RAW write (no barrier, no remembered-
    // set entry). The minor cycle's mature-typed-slot scan must
    // still find and promote it — this is the gap that sank the
    // previous Stage-3 attempt.
    const container = try heap.allocateObject();
    _ = heap.objects_young.pop();
    try heap.objects_mature.append(heap.allocator, container);
    container.generation = .mature;

    const young_proto = try heap.allocateObject();
    container.prototype = young_proto; // raw write, no barrier
    try testing.expectEqual(@as(usize, 0), heap.remembered.items.len);

    heap.collectYoung(&.{});

    // The typed-slot scan rooted it: promoted, not swept.
    try testing.expectEqual(@as(usize, 0), heap.objects_young.items.len);
    try testing.expectEqual(@as(usize, 2), heap.objects_mature.items.len);
    try testing.expectEqual(Generation.mature, young_proto.generation);
}

test "Heap: collectYoung clears stale mark bits on mature objects" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // A mature object reachable from a root: the minor cycle marks
    // it transitively but must clear its mark bit afterward, or the
    // next collectFull would treat it as already-visited and leak.
    const mature = try heap.allocateObject();
    _ = heap.objects_young.pop();
    try heap.objects_mature.append(heap.allocator, mature);
    mature.generation = .mature;

    heap.collectYoung(&.{taggedObject(mature)});
    try testing.expect(!mature.marked);

    // A subsequent collectFull with empty roots must still be able
    // to free it — proof the mark bit was genuinely cleared.
    heap.collectFull(&.{});
    try testing.expectEqual(@as(usize, 0), heap.objects_mature.items.len);
}

test "Heap: setGcThreshold derives a coherent minor/major pair" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    heap.setGcThreshold(1);
    try testing.expectEqual(@as(u32, 1), heap.gc_young_threshold);
    try testing.expectEqual(@as(u32, 8), heap.gc_threshold);

    heap.setGcThreshold(1000);
    try testing.expectEqual(@as(u32, 1000), heap.gc_young_threshold);
    try testing.expectEqual(@as(u32, 8000), heap.gc_threshold);
}

test "Heap: collect keeps an object reachable through roots" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const s = try heap.allocateString("kept");
    const v = Value.fromString(s);

    heap.collect(&.{v});
    try testing.expectEqual(@as(usize, 1), heap.stringCount());
    try testing.expectEqualStrings("kept", s.flatBytes());
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
    try testing.expectEqual(@as(usize, 0), heap.stringCount());
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
    try testing.expectEqual(@as(usize, 1), heap.stringCount());

    scope.close();

    // Now the scope is gone — collect frees the string.
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.stringCount());
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
    try testing.expectEqual(@as(usize, 2), heap.stringCount());

    inner.close();
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 1), heap.stringCount());

    outer.close();
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.stringCount());
}

test "Heap: concatStrings tracks the result" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.allocateString("foo");
    const b = try heap.allocateString("bar");
    const ab = try heap.concatStrings(a, b);

    try testing.expectEqualStrings("foobar", ab.flatBytes());
    try testing.expectEqual(@as(usize, 3), heap.stringCount());

    // With only `ab` rooted, `a` and `b` are freed.
    heap.collect(&.{Value.fromString(ab)});
    try testing.expectEqual(@as(usize, 1), heap.stringCount());
}

test "Heap: markString recurses through a hand-built cons node" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Two flat children, plus a cons parent. Stage 1 production
    // code never builds a cons — this exercises the mark recursion.
    const left = try heap.allocateString("Hello, ");
    const right = try heap.allocateString("world!");
    const cons = try heap.allocator.create(JSString);
    cons.* = .{
        .length_cu = left.length_cu + right.length_cu,
        .byte_len = left.byte_len + right.byte_len,
        .depth = 1,
        .payload = .{ .cons = .{
            .left = left,
            .right = right,
            .heap = &heap,
        } },
    };
    try heap.strings_young.append(heap.allocator, cons);

    // Root only the cons node. Marking it must mark both children
    // so the sweep keeps all three alive.
    heap.collect(&.{Value.fromString(cons)});
    try testing.expectEqual(@as(usize, 3), heap.stringCount());

    // Drop the root; everything is collected.
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.stringCount());
}

test "Heap: allocateConsString eager-flattens below the min-length gate" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Total 4 bytes — well below `min_cons_byte_len` (16). Gate A
    // says eager-flatten: a cons header would cost more than the copy.
    const a = try heap.allocateString("ab");
    const b = try heap.allocateString("cd");
    const ab = try heap.allocateConsString(a, b);

    try testing.expect(ab.isFlat());
    try testing.expectEqualStrings("abcd", ab.flatBytes());
}

test "Heap: allocateConsString builds a lazy cons above the min-length gate" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Total 20 bytes ≥ `min_cons_byte_len` (16) — Gate A passes,
    // seam is clean, depth 1 ≤ cap. A real cons node is built.
    const a = try heap.allocateString("0123456789");
    const b = try heap.allocateString("abcdefghij");
    const ab = try heap.allocateConsString(a, b);

    try testing.expect(!ab.isFlat());
    try testing.expectEqual(@as(u16, 1), ab.depth);
    try testing.expectEqual(@as(u32, 20), ab.byte_len);
    try testing.expectEqual(@as(u32, 20), ab.length_cu);
    // Flatten on demand reproduces the joined bytes.
    try testing.expectEqualStrings("0123456789abcdefghij", try ab.flatten(heap.bytes_allocator));
}

test "Heap: allocateConsString eager-flattens a dirty WTF-8 seam" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // `a` ends with a lone high surrogate, `b` starts with a lone
    // low surrogate — the seam pairs (§6.1.4). Gate B forbids a cons
    // here even though both operands are long enough; the result
    // must be a flat node with the 4-byte form at the seam.
    const a_bytes = [_]u8{ 'p', 'a', 'd', '-', 'p', 'a', 'd', '-', 'p', 'a', 'd', '-', 'p', 'a', 'd', 0xED, 0xA0, 0x80 };
    const b_bytes = [_]u8{ 0xED, 0xB0, 0x80, 'p', 'a', 'd', '-', 'p', 'a', 'd', '-', 'p', 'a', 'd', '-', 'p', 'a', 'd' };
    const a = try heap.allocateString(&a_bytes);
    const b = try heap.allocateString(&b_bytes);
    const ab = try heap.allocateConsString(a, b);

    try testing.expect(ab.isFlat());
    // 18 + 18 bytes, minus 2 for the merged seam = 34.
    try testing.expectEqual(@as(u32, 34), ab.byte_len);
}

test "Heap: allocateConsString caps rope depth, eager-flattening one operand" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Build a left-leaning spine one cons at a time, mimicking a
    // `result += chunk` loop. The depth must never exceed
    // `max_rope_depth`: once it would, `allocateConsString` flattens
    // the left operand first and the new node's depth resets low.
    const chunk = "0123456789abcdef"; // 16 bytes — passes Gate A.
    var spine = try heap.allocateString(chunk);
    var iter: usize = 0;
    while (iter < string_mod.max_rope_depth * 3) : (iter += 1) {
        const next = try heap.allocateString(chunk);
        spine = try heap.allocateConsString(spine, next);
        try testing.expect(spine.depth <= string_mod.max_rope_depth);
    }

    // The accumulated string is still correct after the cap kicked in.
    const flat = try spine.flatten(heap.bytes_allocator);
    try testing.expectEqual(@as(usize, chunk.len * (string_mod.max_rope_depth * 3 + 1)), flat.len);
}

test "Heap: GC marks a real lazy cons tree built by allocateConsString" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.allocateString("0123456789");
    const b = try heap.allocateString("abcdefghij");
    const ab = try heap.allocateConsString(a, b);
    try testing.expect(!ab.isFlat());

    // Rooting only the cons keeps both children alive.
    heap.collect(&.{Value.fromString(ab)});
    try testing.expectEqual(@as(usize, 3), heap.stringCount());

    // Drop the root — everything collected.
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.stringCount());
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
