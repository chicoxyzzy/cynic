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
const ShapeTree = @import("shape.zig").ShapeTree;
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

/// §26.2 FinalizationRegistry cleanup-job scheduler. The collector
/// discovers a dead registry target during the post-mark weak pass
/// and must enqueue a host job — `cleanupCallback(heldValue)` — to
/// run later via the normal microtask drain, NOT synchronously
/// inside GC. The `Heap` has no `Realm` in scope, so the realm
/// installs this callback (`Heap.setFinalizationEnqueue`) at init;
/// the collector invokes it with the opaque realm pointer. `ctx`
/// is the `*Realm`; `callback` the registry's `[[CleanupCallback]]`;
/// `held_value` the cell's `[[HeldValue]]`.
pub const FinalizationEnqueueFn = *const fn (
    ctx: *anyopaque,
    callback: Value,
    held_value: Value,
) void;

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
    /// §10.1 property-shape transition tree, shared by every object
    /// allocated on this heap (agent-scoped, like a V8 Isolate's
    /// Maps). The realm-agnostic `JSObject.set` reaches it through
    /// each object's `heap` back-pointer. Realm-lifetime arena —
    /// the GC does not trace into shapes.
    shapes: ShapeTree,
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
    /// `%Function.prototype%` — handed to the heap by realm init
    /// once it exists. `allocateFunctionNative` reads it to wire
    /// each native function's `[[Prototype]]` at creation time, so
    /// `.call` / `.apply` / `.bind` resolve on every native — even
    /// ones built lazily after init's one-time proto-wiring pass.
    /// `null` only during the early bootstrap before
    /// `%Function.prototype%` is allocated; those functions are
    /// caught by that init pass instead. Borrowed — the object is
    /// rooted via the realm's intrinsics and outlives the heap.
    function_prototype: ?*JSObject = null,
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

    /// Chunk-constant heap values — permanently-live non-string
    /// constants parked in a `Chunk`'s constant pool: the per-call-
    /// site tagged-template `strs` / `raw` arrays, and `BigInt`
    /// literal values (§12.9.5). Constant *strings* carry a `pinned`
    /// flag the sweep honours directly; objects and bigints don't, so
    /// `pinChunk` registers each here and every GC cycle marks them
    /// as roots — `markValue`'s recursion then keeps the whole
    /// template graph (the `raw` companion, segment strings, anchored
    /// index keys) reachable. Realm-lifetime; freed in `deinit`.
    const_roots: std.ArrayListUnmanaged(Value) = .empty,

    /// Native-constructor instance roots — a LIFO stack of the
    /// freshly-allocated instances currently "in flight" inside a
    /// native constructor call. The `new_call` opcode / `constructValue`
    /// push the instance here before invoking the native and pop it
    /// after; a GC triggered by the native re-entering JS (argument
    /// coercion, an executor callback) marks the stack so the instance
    /// can't be swept mid-construction. A plain `Value` stack rather
    /// than a `HandleScope` per construct — the backing capacity is
    /// retained across calls, so steady-state push/pop is allocation-
    /// free (a `HandleScope` per `new` cost two allocs each). Balanced
    /// push/pop keeps it bounded; freed in `deinit`.
    native_ctor_roots: std.ArrayListUnmanaged(Value) = .empty,

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
    gc_threshold: u32 = 32768,
    /// Allocation count that triggers a *minor* (young-only)
    /// collection. The two-tier dispatch: a minor cycle fires
    /// when `allocs_since_gc` crosses this; a major cycle when
    /// `minor_cycles_since_full` reaches `full_every_n_minor`
    /// (or the byte threshold trips). Sized at a quarter of the
    /// major threshold — most allocations die young, so the cheap
    /// young sweep absorbs the bulk of the churn and the
    /// expensive full trace stays rare. `setGcThreshold` keeps
    /// this coherent with `gc_threshold`.
    gc_young_threshold: u32 = 8192,
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
    /// Current mark color (V8 / JSC / SM trick). An object is "live
    /// this cycle" iff `obj.mark_color == heap.live_color`. The mark
    /// phase sets `obj.mark_color = live_color` on every reachable
    /// object; the sweep keeps `mark_color == live_color` and frees
    /// everything else. Flipped exactly once per cycle (in
    /// `beginMajorCycle` / `beginMinorCycle`), so survivors of the
    /// previous cycle automatically look "unmarked" until the trace
    /// re-marks them — replacing the per-cycle linear walk that
    /// used to clear `marked = false` on every mature object. Fresh
    /// allocations seed `mark_color` from `live_color` so they look
    /// "alive" until the next flip.
    live_color: u1 = 0,
    /// Set by `beginMajorCycle` / `beginMinorCycle`; cleared at the
    /// end of `collectFull` / `collectYoung`. Lets the realm-driven
    /// path (which calls the begin-cycle helpers before `markRoots`)
    /// skip a redundant arm-cycle inside collectFull / collectYoung,
    /// and lets a direct unit-test caller arm the cycle implicitly.
    cycle_started: bool = false,
    /// Accumulated GC pause time in nanoseconds across every
    /// `collect()` cycle. Average pause = `gc_time_ns_total /
    /// gc_cycles_total`.
    gc_time_ns_total: u64 = 0,

    /// Weak-aware marking mode. `collectFull` sets this `true` for
    /// the duration of its mark phase; `collectYoung` leaves it
    /// `false`. When `true`, `markValue` does NOT strong-mark the
    /// weak slots of a `WeakRef` / `WeakMap` / `WeakSet` /
    /// `FinalizationRegistry` — instead each reached weak holder is
    /// appended to one of the per-cycle lists below so the
    /// post-mark weak-handling pass (§26.1 / §24.3 / §24.4 / §26.2)
    /// can clear / prune / queue. A minor cycle keeps the old
    /// strong-marking behaviour: a young weak target survives the
    /// minor cycle, tenures, and is handled weakly at the next
    /// `collectFull`. GC timing is spec-unspecified (§26.1 — a
    /// WeakRef is only guaranteed to *eventually* clear), so
    /// "weak refs clear at major GC" is fully conformant.
    weak_aware_mark: bool = false,
    /// Per-`collectFull`-cycle worklist: every reached `WeakRef`
    /// object (`is_weak_ref`). Cleared at the start of each
    /// `collectFull`. Used by the post-mark pass to clear a
    /// `weak_ref_target` whose referent did not survive the trace.
    weak_refs_seen: std.ArrayListUnmanaged(*JSObject) = .empty,
    /// Per-`collectFull`-cycle worklist: every reached object that
    /// carries a `WeakMap` / `WeakSet` `[[MapData]]` / `[[SetData]]`
    /// with `is_weak == true`. Drives the ephemeron fixpoint and
    /// the post-mark entry-pruning pass.
    weak_collections_seen: std.ArrayListUnmanaged(*JSObject) = .empty,
    /// Per-`collectFull`-cycle worklist: every reached
    /// `FinalizationRegistry` object (`finalization_cells`).
    /// The post-mark pass walks each cell and, for a dead target,
    /// enqueues the cleanup job and tombstones the cell.
    finalization_registries_seen: std.ArrayListUnmanaged(*JSObject) = .empty,
    /// Deferred-mark worklists — values / environments whose
    /// traversal would otherwise blow the call stack. Three
    /// recursion chains that overflow at ~5-10k frames under GC
    /// pressure pay the worklist cost: (1) Promise reaction chain
    /// (`reaction.result_promise`), (2) closure-env chain
    /// (`env.slots[i]` is a function whose captured_env contains
    /// another function …), (3) proto chain
    /// (`obj.prototype` walking up a 10k-deep `Object.create` tower).
    /// Items pushed here are processed iteratively by
    /// `drainMarkWorklist` at cycle boundaries (before sweep),
    /// alternating between the two worklists until both are empty.
    /// V8 / JSC / SM ship fully iterative markers; this is a
    /// scoped subset covering the chains that actually hit
    /// today's stack limit.
    mark_worklist: std.ArrayListUnmanaged(Value) = .empty,
    /// Companion to `mark_worklist` for `*Environment` traversals.
    /// `markEnvironment` pushes `env.parent` here instead of
    /// recursing, breaking the markValue ↔ markEnvironment chain
    /// that 10k-deep closure scopes would otherwise blow the stack
    /// through.
    mark_env_worklist: std.ArrayListUnmanaged(*Environment) = .empty,
    /// §26.2 FinalizationRegistry cleanup-job scheduler context —
    /// the `*Realm`, type-erased (the heap can't import realm.zig
    /// without a cycle). `null` on a bare `Heap` (unit tests that
    /// drive `collectFull` directly), in which case the post-mark
    /// pass still tombstones dead cells but queues no job.
    finalization_ctx: ?*anyopaque = null,
    /// §26.2 cleanup-job scheduler — see `FinalizationEnqueueFn`.
    /// Installed by the realm at init via `setFinalizationEnqueue`.
    finalization_enqueue_fn: ?FinalizationEnqueueFn = null,

    /// Slab allocator for `JSObject` headers — free-list-backed,
    /// O(1) per `create`/`destroy` after warmup. Dramatically
    /// outperforms going through the general-purpose allocator on
    /// the `object_alloc` churn (every literal is a malloc + free
    /// pair the GP allocator services through a lock + size-class
    /// walk; the pool just pops a header pointer). The pool's
    /// arena reclaims everything in one `deinit`; per-object
    /// sub-field cleanup goes through `JSObject.deinitFields`
    /// before the header returns to the pool.
    object_pool: std.heap.MemoryPool(JSObject) = .empty,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{
            .allocator = allocator,
            .bytes_allocator = allocator,
            .shapes = ShapeTree.init(allocator) catch unreachable,
        };
    }

    /// Same as `init` but with a distinct allocator for large heap-
    /// owned byte payloads (`JSString.bytes`, ArrayBuffer slabs).
    /// See `bytes_allocator` for the motivation.
    pub fn initWithBytesAllocator(
        allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
    ) Heap {
        return .{
            .allocator = allocator,
            .bytes_allocator = bytes_allocator,
            .shapes = ShapeTree.init(allocator) catch unreachable,
        };
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
        self.shapes.deinit();
        for (self.strings_young.items) |s| s.deinit(self.allocator, self.bytes_allocator);
        for (self.strings_mature.items) |s| s.deinit(self.allocator, self.bytes_allocator);
        self.strings_young.deinit(self.allocator);
        self.strings_mature.deinit(self.allocator);
        for (self.functions_young.items) |f| f.deinit(self.allocator);
        for (self.functions_mature.items) |f| f.deinit(self.allocator);
        self.functions_young.deinit(self.allocator);
        self.functions_mature.deinit(self.allocator);
        // JSObject headers live in the slab pool — drop sub-fields
        // per-object, then let `object_pool.deinit` reclaim every
        // header in one shot.
        for (self.objects_young.items) |o| o.deinitFields(self.allocator);
        for (self.objects_mature.items) |o| o.deinitFields(self.allocator);
        self.objects_young.deinit(self.allocator);
        self.objects_mature.deinit(self.allocator);
        self.object_pool.deinit(self.allocator);
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
        self.const_roots.deinit(self.allocator);
        self.native_ctor_roots.deinit(self.allocator);
        self.handle_scopes.deinit(self.allocator);
        self.weak_refs_seen.deinit(self.allocator);
        self.weak_collections_seen.deinit(self.allocator);
        self.finalization_registries_seen.deinit(self.allocator);
        self.mark_worklist.deinit(self.allocator);
        self.mark_env_worklist.deinit(self.allocator);
    }

    pub fn allocateBigInt(self: *Heap, value: i128) !*JSBigInt {
        const b = try JSBigInt.init(self.allocator, value);
        errdefer b.deinit(self.allocator);
        b.mark_color = self.live_color;
        try self.bigints_young.append(self.allocator, b);
        self.allocs_since_gc +|= 1;
        return b;
    }

    /// Allocate a `JSBigInt` taking ownership of an arbitrary-
    /// precision `BigIntValue` (sign + heap-owned limb slice). The
    /// limb slice must have been allocated by `self.allocator`; the
    /// new `JSBigInt` owns it directly with no copy. On failure the
    /// limb slice is freed so the caller never leaks it.
    pub fn allocateBigIntValue(self: *Heap, v: @import("bigint.zig").BigIntValue) !*JSBigInt {
        const bigint_mod = @import("bigint.zig");
        // Normalize defensively — `initOwned` asserts the top limb
        // is non-zero, and a zero result must carry sign=false.
        const b = bigint_mod.JSBigInt.initOwned(self.allocator, v.sign, v.limbs) catch |err| {
            if (v.limbs.len != 0) self.allocator.free(v.limbs);
            return err;
        };
        errdefer b.deinit(self.allocator);
        b.mark_color = self.live_color;
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
        s.mark_color = self.live_color;
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
        s.mark_color = self.live_color;
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
        g.mark_color = self.live_color;
        try self.generators_young.append(self.allocator, g);
        self.allocs_since_gc +|= 1;
        return g;
    }

    pub fn allocateObject(self: *Heap) !*JSObject {
        // Pool the header (free-list-backed slab allocation —
        // O(1) after warmup; no libsystem_malloc round-trip per
        // literal). Sub-fields stay allocator-owned so test paths
        // that construct objects through `JSObject.init` still
        // free cleanly through the regular `deinit`.
        const o = try self.object_pool.create(self.allocator);
        o.* = .{ .kind = .object };
        errdefer {
            o.deinitFields(self.allocator);
            self.object_pool.destroy(o);
        }
        o.heap = self;
        o.mark_color = self.live_color;
        try self.objects_young.append(self.allocator, o);
        self.allocs_since_gc +|= 1;
        return o;
    }

    /// Allocate a new `Environment` chained to `parent`, with
    /// `slot_count` bindings initialised to the TDZ Hole.
    pub fn allocateEnvironment(self: *Heap, parent: ?*Environment, slot_count: u8) !*Environment {
        const env = try Environment.init(self.allocator, parent, slot_count);
        errdefer env.deinit(self.allocator);
        env.mark_color = self.live_color;
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
        f.mark_color = self.live_color;
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
        // §20.2.3 — a native function's `[[Prototype]]` is
        // %Function.prototype%. Wire it here so it holds for
        // functions allocated lazily after realm init (the init
        // pass that backfills `proto` runs only once); `null`
        // before the prototype exists, handled by that pass.
        if (self.function_prototype) |fp| f.proto = fp;
        try self.installFunctionLengthAndName(f, param_count, name);
        f.mark_color = self.live_color;
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
        s.mark_color = self.live_color;
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
        s.mark_color = self.live_color;
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
        s.mark_color = self.live_color;
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
        s.mark_color = self.live_color;
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
        // Iterative walk — the cons tree can be up to
        // `string_mod.max_rope_depth` deep (1024 as of the
        // `string_concat` speed-up), so a recursive `markString`
        // would risk a stack overflow on a deep `s = s + tiny`
        // loop. The worklist holds one right-child per descent
        // level; depth is bounded by the rope depth cap. On OOM
        // the marker falls back to direct recursion on the right
        // child (left continues iteratively) — a missed mark would
        // be worse than a deep stack frame.
        var cursor: *JSString = s;
        while (true) {
            if (cursor.mark_color == self.live_color) break;
            cursor.mark_color = self.live_color;
            switch (cursor.payload) {
                .flat => break,
                .cons => |c| {
                    // Defer the right child; descend left
                    // iteratively to keep the worklist bounded
                    // (left-deep is the common shape).
                    self.mark_worklist.append(
                        self.allocator,
                        Value.fromString(@ptrCast(c.right)),
                    ) catch {
                        // Fall back to recursion only on this
                        // right child — leaves the left iteration
                        // intact so a deep left spine stays safe.
                        self.markString(c.right);
                    };
                    cursor = c.left;
                },
            }
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
            sym.mark_color = self.live_color;
        } else if (valueAsBigInt(v)) |bi| {
            bi.mark_color = self.live_color;
        } else if (valueAsFunction(v)) |f| {
            if (f.mark_color != self.live_color) {
                f.mark_color = self.live_color;
                // Defer captured_env to break the closure-chain
                // recursion (each function's captured env contains
                // another function whose captured env …).
                // `drainMarkWorklist` walks `mark_env_worklist`
                // iteratively after markRoots returns.
                if (f.captured_env) |env| {
                    self.mark_env_worklist.append(self.allocator, env) catch {
                        self.markEnvironment(env);
                    };
                }
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
                for (f.key_anchors.items) |s| s.mark_color = self.live_color;
                if (f.prototype) |p| self.markValue(taggedObject(p));
                // §10.2.3 [[HomeObject]] — a method's home object
                // (and, for the typed-slot split Cynic uses, the
                // owning `home_function`) back `super` lookups.
                // They can be the only reference keeping the
                // prototype / constructor alive — without these marks
                // a method's home object is swept and a later call
                // copies the dangling pointer into the call frame.
                if (f.home_object) |ho| self.markValue(taggedObject(ho));
                if (f.home_function) |hf| self.markValue(taggedFunction(hf));
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
            if (o.mark_color != self.live_color) {
                o.mark_color = self.live_color;
                // Debug-only: every reachable shaped object's shadow
                // shape must agree with its `properties` dictionary.
                // Catches any direct property-bag mutation that
                // bypassed `shadowSet` / `demoteFromShape`, at the
                // next collection — regardless of which call site
                // introduced the divergence. Compiled out in
                // ReleaseFast.
                o.verifyShapeInvariant();
                var it = o.properties.iterator();
                while (it.next()) |entry| self.markValue(entry.value_ptr.*);
                if (o.privatePropertyIterator()) |pit_outer| {
                    var pit = pit_outer;
                    while (pit.next()) |entry| self.markValue(entry.value_ptr.*);
                }
                if (o.privateAccessorIterator()) |pait_outer| {
                    var pait = pait_outer;
                    while (pait.next()) |entry| {
                        if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
                        if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
                    }
                }
                if (o.accessorIterator()) |ait_outer| {
                    var ait = ait_outer;
                    while (ait.next()) |entry| {
                        if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
                        if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
                    }
                }
                // §15.2.1.16.3 ResolveExport chain — re-export
                // redirects pin their target namespace alive so a
                // module that's only reachable via another
                // module's `export { X as Y } from "src"` survives
                // GC for as long as the importer's namespace does.
                // `target_key` is a chunk-constant slice (pinned
                // at chunk-finalise time) — no anchor needed.
                if (o.namespaceRedirectIterator()) |nrit_outer| {
                    var nrit = nrit_outer;
                    while (nrit.next()) |entry| {
                        self.markValue(taggedObject(entry.value_ptr.target_ns));
                    }
                }
                if (o.boxed_primitive) |bp| self.markValue(bp);
                // §22.1.3 `[[StringData]]` — the JSString a `String`
                // wrapper boxes; a typed slot, not a property.
                if (o.boxed_string) |bs| self.markString(bs);
                if (o.getMapData()) |md| {
                    if (md.is_weak and self.weak_aware_mark) {
                        // §24.3 WeakMap — the [[WeakMapData]] keys
                        // and values are weak edges. Don't strong-
                        // mark them here; defer to the post-mark
                        // ephemeron fixpoint + pruning pass. Record
                        // the holder so that pass can find it.
                        self.weak_collections_seen.append(self.allocator, o) catch {};
                    } else {
                        // §24.1 Map (or a WeakMap during a minor
                        // cycle) — strong-mark every live entry.
                        for (md.entries.items) |entry| {
                            if (entry.deleted) continue;
                            self.markValue(entry.key);
                            self.markValue(entry.value);
                        }
                    }
                }
                if (o.getSetData()) |sd| {
                    if (sd.is_weak and self.weak_aware_mark) {
                        // §24.4 WeakSet — members are weak edges;
                        // defer to the post-mark pruning pass.
                        self.weak_collections_seen.append(self.allocator, o) catch {};
                    } else {
                        // §24.2 Set (or a WeakSet during a minor
                        // cycle) — strong-mark every live member.
                        for (sd.entries.items) |entry| {
                            if (entry.deleted) continue;
                            self.markValue(entry.value);
                        }
                    }
                }
                if (o.array_like_iter) |s| {
                    self.markValue(s.target);
                    self.markValue(s.for_in_source);
                }
                if (o.map_set_iter) |s| self.markValue(s.source);
                if (o.regexp_string_iter) |s| {
                    self.markValue(s.regexp);
                    self.markValue(s.string);
                }
                if (o.iter_record) |s| self.markValue(s.next);
                if (o.iter_helper) |s| {
                    self.markValue(s.source);
                    self.markValue(s.next_fn);
                    self.markValue(s.payload);
                    self.markValue(s.active);
                    for (s.concat_inputs.items) |ci| {
                        self.markValue(ci.iterable);
                        self.markValue(ci.method);
                    }
                    for (s.zip_inputs.items) |zi| {
                        self.markValue(zi.iter);
                        self.markValue(zi.next);
                        self.markValue(zi.key);
                        self.markValue(zi.pad);
                    }
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
                // §26.1 WeakRef — the `[[WeakRefTarget]]` is a weak
                // edge. During a weak-aware full cycle, do NOT
                // strong-mark it; record the WeakRef so the
                // post-mark pass can clear `weak_ref_target` when
                // the referent did not survive the trace. A minor
                // cycle keeps strong-marking (the young target
                // tenures and is handled weakly next `collectFull`).
                if (o.is_weak_ref) {
                    if (self.weak_aware_mark) {
                        self.weak_refs_seen.append(self.allocator, o) catch {};
                    } else {
                        self.markValue(o.getWeakRefTarget());
                    }
                }
                // §26.2 FinalizationRegistry — the cleanup callback
                // and every cell's `[[HeldValue]]` are strong edges
                // (they must survive to be passed to the callback);
                // the cell `[[WeakRefTarget]]` and `[[UnregisterToken]]`
                // are weak. During a weak-aware full cycle, strong-
                // mark callback + held values, defer the weak slots
                // to the post-mark pass (which queues a cleanup job
                // for any dead target). A minor cycle keeps the old
                // strong-marking of every slot.
                if (o.getFinalizationCells()) |fc| {
                    self.markValue(fc.cleanup_callback);
                    if (self.weak_aware_mark) {
                        self.finalization_registries_seen.append(self.allocator, o) catch {};
                        for (fc.cells.items) |cell| {
                            if (cell.deleted) continue;
                            self.markValue(cell.held_value);
                        }
                    } else {
                        for (fc.cells.items) |cell| {
                            if (cell.deleted) continue;
                            self.markValue(cell.target);
                            self.markValue(cell.held_value);
                            if (cell.has_token) self.markValue(cell.unregister_token);
                        }
                    }
                }
                // Heap-allocated JSStrings whose `.bytes` slice
                // backs a property key. The property hash maps
                // store `[]const u8`, not pointers; without this
                // anchor the JSString gets swept and the key
                // dangles. Computed `obj[expr] = v` writes go
                // through `setComputedOwned` which pushes here.
                for (o.key_anchors.items) |s| s.mark_color = self.live_color;
                // Pending Promise reactions / waiters — settlement
                // microtasks read these lists. A reaction's
                // `result_promise` is the chained sub-Promise that
                // a later `.then` is registered on; without marking
                // it here, mid-drain GC collects the chain.
                if (o.promiseReactionsConst()) |reactions| {
                    for (reactions.items) |r| {
                        self.markValue(r.on_fulfilled);
                        self.markValue(r.on_rejected);
                        // Defer the chained sub-Promise: a `.then` chain
                        // of length N walks N deep through reactions if
                        // we recurse, overflowing past ~5k frames under
                        // GC pressure. `drainMarkWorklist` (called at
                        // cycle boundaries) processes these iteratively
                        // — chain length stops mattering. On OOM (the
                        // append's only failure mode), fall back to the
                        // recursive mark so a missed mark can't become
                        // a missed sweep.
                        self.mark_worklist.append(self.allocator, r.result_promise) catch {
                            self.markValue(r.result_promise);
                        };
                    }
                }
                if (o.promiseWaitersConst()) |waiters| {
                    for (waiters.items) |w| self.markGenerator(w);
                }
                // §27.2 `[[PromiseResult]]` — the settled value on
                // a fulfilled / rejected Promise. Held in the typed
                // `promise_value` slot rather than a property bag,
                // so the regular property walk above misses it.
                if (o.promise_state != .none) self.markValue(o.promise_value);
                // §22.2.4 `[[OriginalSource]]` / `[[OriginalFlags]]`
                // for RegExp instances. Strings that the regular
                // property walk wouldn't reach.
                if (o.regexp_source) |s| s.mark_color = self.live_color;
                if (o.regexp_flags) |s| s.mark_color = self.live_color;
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
                // Defer the prototype walk to break the proto-chain
                // recursion (a 10k-deep `Object.create` tower forms
                // an N-deep prototype chain). `drainMarkWorklist`
                // walks the worklist iteratively after markRoots.
                if (o.prototype) |p| {
                    self.mark_worklist.append(self.allocator, taggedObject(p)) catch {
                        self.markValue(taggedObject(p));
                    };
                }
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
                if (o.getTypedView()) |tv| self.markValue(taggedObject(tv.viewed));
                if (o.getDataView()) |dv| self.markValue(taggedObject(dv.viewed));
            }
        }
        // Doubles, ints, bools, null, undefined, hole: no heap pointer.
    }

    /// Whether the referent of a weak slot (`WeakRef` target,
    /// `WeakMap`/`WeakSet` key/member, `FinalizationRegistry` cell
    /// target) survived the trace. §6.2.10 CanBeHeldWeakly limits a
    /// weak referent to an Object or a non-registered Symbol; only
    /// those heap kinds carry a `marked` bit that matters here. A
    /// primitive (number / bool / undefined / string) can never be
    /// the referent of a live weak slot — but if one is encountered
    /// it is trivially "live" (it isn't on the GC sweep list as a
    /// reclaimable weak target). Returns `true` for anything that
    /// is not a swept-away heap object/function/symbol.
    fn isWeakReferentLive(self: *const Heap, v: Value) bool {
        if (valueAsPlainObject(v)) |o| return o.mark_color == self.live_color;
        if (valueAsFunction(v)) |f| return f.mark_color == self.live_color;
        if (valueAsSymbol(v)) |s| {
            // §6.2.10 CanBeHeldWeakly — a non-registered symbol is
            // a valid weak referent and the regular colour check
            // applies. A registered (pinned) symbol's `mark_color`
            // is allowed to go stale across cycles — its registry
            // entry keeps it permanently alive — so the pinned
            // bit is the live-edge signal here.
            return s.pinned or s.mark_color == self.live_color;
        }
        // Strings, BigInts, and primitives: not valid weak
        // referents per §6.2.10, treated as trivially live.
        return true;
    }

    /// §24.3 WeakMap ephemeron fixpoint. For each reached WeakMap,
    /// for every entry whose KEY object survived the trace,
    /// transitively strong-mark the entry's VALUE. Marking a value
    /// can make another WeakMap's key live, so the whole set is
    /// re-scanned until a pass adds no new marks. (§24.4 WeakSet has
    /// no value column — it needs no fixpoint.) Called by
    /// `collectFull` after the main mark loop, before the sweep.
    fn weakMapEphemeronFixpoint(self: *Heap) void {
        var changed = true;
        while (changed) {
            changed = false;
            // Index-based walk: a `markValue` below can reach a new
            // WeakMap and append it to `weak_collections_seen`,
            // reallocating the backing buffer — so re-read `.items`
            // and `.len` each step rather than capturing the slice
            // once. A WeakMap appended mid-walk is still visited
            // (this pass continues past the old length); the outer
            // `changed` loop re-scans regardless.
            var i: usize = 0;
            while (i < self.weak_collections_seen.items.len) : (i += 1) {
                const holder = self.weak_collections_seen.items[i];
                const md = holder.getMapData() orelse continue;
                if (!md.is_weak) continue;
                for (md.entries.items) |entry| {
                    if (entry.deleted) continue;
                    if (!self.isWeakReferentLive(entry.key)) continue;
                    // Key is live — the value must be too. Mark it
                    // and note whether that introduced a new mark
                    // (a freshly-marked object flips a bit, which a
                    // later WeakMap key check can observe).
                    if (!self.isWeakReferentLive(entry.value)) {
                        self.markValue(entry.value);
                        changed = true;
                    }
                }
            }
        }
    }

    /// §26.1 / §24.3 / §24.4 / §26.2 — post-mark weak handling.
    /// Run by `collectFull` after the ephemeron fixpoint and before
    /// the sweep:
    ///
    ///  • §26.1 WeakRef — a `weak_ref_target` whose referent did
    ///    not survive the trace is reset to `undefined`, so a later
    ///    `.deref()` returns `undefined` per §26.1.4.1.
    ///  • §24.3 WeakMap / §24.4 WeakSet — every entry whose
    ///    key / member object did not survive is tombstoned
    ///    (`deleted = true`, matching `MapEntry`/`SetEntry`), so the
    ///    entry is gone from `has` / `get` / iteration. The dead
    ///    key/value pair is then unreachable and freed by the sweep.
    ///  • §26.2 FinalizationRegistry — every non-deleted cell whose
    ///    `target` did not survive has its `held_value` handed to
    ///    `enqueue_fn` (the cleanup-job scheduler) and the cell is
    ///    tombstoned. The job runs later via the normal microtask
    ///    drain — never synchronously inside GC.
    ///
    /// A `null` `finalization_enqueue_fn` (the unit-test path that
    /// calls `collectFull` on a bare `Heap`) skips FinalizationRegistry
    /// queuing but still tombstones dead cells.
    fn processWeakReferences(self: *Heap) void {
        // §26.1 WeakRef.
        for (self.weak_refs_seen.items) |wr| {
            if (!wr.is_weak_ref) continue;
            const slot = wr.weakRefTargetSlot() orelse continue;
            if (!self.isWeakReferentLive(slot.*)) {
                slot.* = Value.undefined_;
            }
        }
        // §24.3 WeakMap / §24.4 WeakSet — prune dead entries.
        for (self.weak_collections_seen.items) |holder| {
            if (holder.getMapData()) |md| {
                if (md.is_weak) {
                    for (md.entries.items) |*entry| {
                        if (entry.deleted) continue;
                        if (!self.isWeakReferentLive(entry.key)) {
                            entry.deleted = true;
                        }
                    }
                }
            }
            if (holder.getSetData()) |sd| {
                if (sd.is_weak) {
                    for (sd.entries.items) |*entry| {
                        if (entry.deleted) continue;
                        if (!self.isWeakReferentLive(entry.value)) {
                            entry.deleted = true;
                        }
                    }
                }
            }
        }
        // §26.2 FinalizationRegistry — queue cleanup for dead
        // targets, tombstone the cell.
        for (self.finalization_registries_seen.items) |reg| {
            const fc = reg.getFinalizationCells() orelse continue;
            for (fc.cells.items) |*cell| {
                if (cell.deleted) continue;
                if (!self.isWeakReferentLive(cell.target)) {
                    if (self.finalization_enqueue_fn) |f| {
                        if (self.finalization_ctx) |c| {
                            f(c, fc.cleanup_callback, cell.held_value);
                        }
                    }
                    cell.deleted = true;
                }
            }
        }
    }

    /// Install the §26.2 FinalizationRegistry cleanup-job scheduler.
    /// Called once by the realm at init — see `FinalizationEnqueueFn`.
    pub fn setFinalizationEnqueue(
        self: *Heap,
        ctx: *anyopaque,
        enqueue_fn: FinalizationEnqueueFn,
    ) void {
        self.finalization_ctx = ctx;
        self.finalization_enqueue_fn = enqueue_fn;
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
    pub fn pinChunk(self: *Heap, chunk: *const Chunk) !void {
        for (chunk.constants) |c| try self.pinValue(c);
        for (chunk.function_templates) |*ft| try self.pinChunk(&ft.chunk);
        for (chunk.class_templates) |*ct| {
            try self.pinChunk(&ct.constructor_chunk);
            for (ct.instance_methods) |*m| try self.pinChunk(&m.chunk);
            for (ct.static_methods) |*m| try self.pinChunk(&m.chunk);
            for (ct.instance_fields) |*fd| if (fd.init_chunk) |*ic| try self.pinChunk(ic);
            for (ct.static_fields) |*fd| if (fd.init_chunk) |*ic| try self.pinChunk(ic);
            for (ct.static_blocks) |*sb| try self.pinChunk(sb);
        }
    }

    /// Weak-clear every reachable chunk's `call_method` inline-cache
    /// cells whose cached callee isn't marked through other refs.
    /// Called from `collectFull` and `collectYoung` after the mark
    /// phase, before sweep. Without this, a swept-and-reused address
    /// could match a stale `cell.callee` pointer and the fast path
    /// would jump into the wrong (or freed) function.
    ///
    /// Walks every live function's chunk recursively (function
    /// templates, class constructor / methods / field initializers /
    /// static blocks). A chunk reached through multiple functions
    /// gets visited multiple times — the operation is idempotent
    /// (nulling an already-null cell is a no-op).
    fn weakClearCallICs(self: *Heap) void {
        const lc = self.live_color;
        for (self.functions_young.items) |f| {
            if (f.mark_color != lc) continue;
            if (f.chunk) |c| weakClearChunkICs(c, lc);
        }
        for (self.functions_mature.items) |f| {
            if (f.mark_color != lc) continue;
            if (f.chunk) |c| weakClearChunkICs(c, lc);
        }
    }

    /// Weak-clear stale heap pointers in both IC tables of a chunk:
    /// `inline_caches` (proto pointer for prototype-load cells)
    /// and `inline_call_caches` (callee pointer). Cells whose
    /// pointer isn't otherwise reachable get nulled, so a swept-
    /// and-reused address cannot reawaken a stale cell.
    fn weakClearChunkICs(chunk: *const Chunk, live_color: u1) void {
        for (chunk.inline_caches) |*cell| {
            if (cell.proto) |proto| {
                if (proto.mark_color != live_color) {
                    cell.shape = null;
                    cell.proto = null;
                    cell.proto_shape = null;
                }
            }
        }
        for (chunk.inline_call_caches) |*cell| {
            if (cell.callee) |callee| {
                if (callee.mark_color != live_color) cell.callee = null;
            }
        }
        for (chunk.function_templates) |*ft| weakClearChunkICs(&ft.chunk, live_color);
        for (chunk.class_templates) |*ct| {
            weakClearChunkICs(&ct.constructor_chunk, live_color);
            for (ct.instance_methods) |*m| weakClearChunkICs(&m.chunk, live_color);
            for (ct.static_methods) |*m| weakClearChunkICs(&m.chunk, live_color);
            for (ct.instance_fields) |*fd| if (fd.init_chunk) |*ic| weakClearChunkICs(ic, live_color);
            for (ct.static_fields) |*fd| if (fd.init_chunk) |*ic| weakClearChunkICs(ic, live_color);
            for (ct.static_blocks) |*sb| weakClearChunkICs(sb, live_color);
        }
    }

    /// Keep the heap-allocated payload of `v` permanently live.
    /// Strings carry a `pinned` flag the sweep honours directly.
    /// Objects (the per-call-site tagged-template `strs` / `raw`
    /// arrays) and `BigInt` literal values can't — pinning one slot
    /// of an object without pinning its whole transitive graph would
    /// dangle — so they are registered in `const_roots` and re-marked
    /// as roots every GC cycle, which keeps the graph alive through
    /// `markValue`'s recursion. Symbols don't appear in chunk
    /// constants (the compiler allocates them at runtime).
    /// Idempotent for strings.
    fn pinValue(self: *Heap, v: Value) !void {
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
            return;
        }
        // Objects (template arrays) and BigInt literals — re-marked
        // every cycle from `const_roots`.
        if (valueAsPlainObject(v) != null or valueAsBigInt(v) != null) {
            try self.const_roots.append(self.allocator, v);
        }
    }

    /// Mark `env` and recursively walk its parent chain + slots.
    /// Idempotent — a repeated mark short-circuits on the bit.
    pub fn markEnvironment(self: *Heap, env: *Environment) void {
        if (env.mark_color == self.live_color) return;
        env.mark_color = self.live_color;
        // Defer the parent walk to break the markEnvironment-
        // recurses-on-parent chain (a 10k-deep nested-let scope
        // builds an N-deep parent chain). Slot values stay
        // recursive — they're shallow per env; the chain that
        // overflows on closures goes via markValue → captured_env
        // → markEnvironment, which is broken by markValue's own
        // worklist push on the captured_env edge (see below).
        for (env.slots) |s| self.markValue(s);
        if (env.parent) |p| {
            self.mark_env_worklist.append(self.allocator, p) catch {
                // OOM fallback — accept the stack-depth risk
                // over leaving the env unmarked.
                self.markEnvironment(p);
            };
        }
    }

    /// Mark a suspended generator's saved frame state. Idempotent.
    /// Walks: register file (live local values), captured env,
    /// `this`, `[[HomeObject]]`, plus the accumulator. The chunk
    /// pointer is borrowed from the function template; not owned
    /// by the heap, so not marked here.
    pub fn markGenerator(self: *Heap, gen: *JSGenerator) void {
        if (gen.mark_color == self.live_color) return;
        gen.mark_color = self.live_color;
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
    fn sweepList(list: anytype, live_color: u1, deinit_args: anytype) void {
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
            } else if (entry.mark_color == live_color) {
                // Survivor — leave `mark_color` as-is; the next
                // cycle's `live_color` flip will age it back to
                // "unmarked". A full trace already visited this
                // object, so any remembered-set membership is now
                // stale. Clear the bit (the set itself is emptied
                // by the caller) so the next young cycle can re-
                // record a genuine old→young store into it.
                if (@hasField(EntryT, "in_remembered_set")) {
                    entry.in_remembered_set = false;
                }
            } else {
                _ = list.swapRemove(i);
                if (comptime EntryT == JSObject) {
                    // Slab pool path — see promoteYoungList for the
                    // matching logic; `deinit_args` is
                    // `.{allocator, &heap.object_pool}` here.
                    entry.deinitFields(deinit_args[0]);
                    deinit_args[1].destroy(entry);
                } else {
                    @call(.auto, EntryT.deinit, .{entry} ++ deinit_args);
                }
            }
        }
    }

    /// Arm a major (full) GC cycle. Flips `live_color`, clears
    /// every mature object's `mark_color` so a stale mark from a
    /// previous cycle can't spuriously match the new `live_color`
    /// (cross-cycle stale-mark hazard: u1 has period 2, so a
    /// mature object unreached across two minor cycles has its
    /// old colour back when the major cycle flips), sets
    /// `cycle_started` so `collectFull` skips its idempotent self-
    /// arm, sets `weak_aware_mark` + clears the per-cycle weak-
    /// holder worklists so `markValue` treats `WeakRef` /
    /// `WeakMap` / `WeakSet` / `FinalizationRegistry` slots as
    /// weak edges. MUST run before any `markValue` for the cycle.
    /// Two callers: `Realm.collectGarbage` (which calls it BEFORE
    /// `markRoots` so the flip precedes any mark), and `collectFull`
    /// itself for the unit-test path that doesn't go through a
    /// realm.
    ///
    /// The pre-mark clear walks every mature list once per *major*
    /// cycle. Minor cycles still skip the walk (`full_every_n_minor`
    /// is 8 by default, so the per-cycle savings of the colour-flip
    /// are preserved).
    pub fn beginMajorCycle(self: *Heap) void {
        self.live_color = ~self.live_color;
        const unmarked: u1 = ~self.live_color;
        for (self.strings_mature.items) |s| s.mark_color = unmarked;
        for (self.functions_mature.items) |f| f.mark_color = unmarked;
        for (self.objects_mature.items) |o| o.mark_color = unmarked;
        for (self.environments_mature.items) |e| e.mark_color = unmarked;
        for (self.generators_mature.items) |g| g.mark_color = unmarked;
        for (self.symbols_mature.items) |s| s.mark_color = unmarked;
        for (self.bigints_mature.items) |b| b.mark_color = unmarked;
        self.cycle_started = true;
        self.weak_aware_mark = true;
        self.weak_refs_seen.clearRetainingCapacity();
        self.weak_collections_seen.clearRetainingCapacity();
        self.finalization_registries_seen.clearRetainingCapacity();
    }

    /// Arm a minor (young-only) GC cycle. Flips `live_color`; does
    /// NOT arm weak-aware marking — a minor cycle strong-marks weak
    /// slots (a young weak target tenures and is processed weakly at
    /// the next major cycle; §26.1 GC timing is implementation-
    /// defined, so this is conformant). Same caller protocol as
    /// `beginMajorCycle` — realm calls before `markRoots`,
    /// `collectYoung` covers the test path.
    pub fn beginMinorCycle(self: *Heap) void {
        self.live_color = ~self.live_color;
        self.cycle_started = true;
    }

    /// Iteratively process every value pushed onto `mark_worklist`
    /// during the mark phase. Each pop's `markValue` may push more
    /// — the loop accommodates growth. The point is to avoid
    /// stack-depth recursion through long graphs (currently only
    /// the promise-reaction chain). Must be called before sweep
    /// so deferred-mark items are accounted for.
    pub fn drainMarkWorklist(self: *Heap) void {
        // Drain both worklists, alternating between them, until
        // both are empty. Either drain can refill the other:
        // `markValue` of a function pushes its captured_env onto
        // `mark_env_worklist`; `markEnvironment` of an env pushes
        // its slot values onto `mark_worklist` (and pushes
        // `env.parent` onto `mark_env_worklist`). An outer while
        // re-checks both after each inner drain.
        while (self.mark_worklist.items.len > 0 or self.mark_env_worklist.items.len > 0) {
            while (self.mark_worklist.items.len > 0) {
                const w = self.mark_worklist.items[self.mark_worklist.items.len - 1];
                self.mark_worklist.items.len -= 1;
                self.markValue(w);
            }
            while (self.mark_env_worklist.items.len > 0) {
                const env = self.mark_env_worklist.items[self.mark_env_worklist.items.len - 1];
                self.mark_env_worklist.items.len -= 1;
                self.markEnvironment(env);
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

        // Arm the cycle if the caller hasn't yet (the realm path
        // calls `beginMajorCycle` BEFORE `markRoots` so the flip +
        // weak-aware setup precedes its `markValue`s; a direct
        // unit-test caller reaches here cold and `cycle_started`
        // catches them).
        if (!self.cycle_started) self.beginMajorCycle();

        // Mark phase.
        for (roots) |r| self.markValue(r);
        for (self.handle_scopes.items) |scope| {
            for (scope.handles.items) |r| self.markValue(r);
        }
        // Chunk-constant heap values (tagged-template `strs` / `raw`
        // arrays, BigInt literals) — permanently live; `markValue`
        // recursion keeps their whole graph reachable.
        for (self.const_roots.items) |v| self.markValue(v);
        // Native-constructor instances currently in flight.
        for (self.native_ctor_roots.items) |v| self.markValue(v);
        // Registered symbols are pinned at `Symbol.for` time
        // (§20.4.2.2 GlobalSymbolRegistry has no spec'd eviction);
        // the sweep skips pinned entries and `isWeakReferentLive`
        // short-circuits on `pinned`, so the per-cycle re-mark
        // loop the heap used to do over `symbol_registry` is
        // gone.

        // Drain deferred-mark items pushed during the main mark
        // walk (currently `promise_reactions[i].result_promise`)
        // BEFORE the ephemeron fixpoint, so its `isWeakReferentLive`
        // probes see complete marks.
        self.drainMarkWorklist();

        // §24.3 WeakMap ephemeron fixpoint — a WeakMap entry's value
        // is reachable iff its key is. Run to a fixpoint: marking a
        // value can make another WeakMap's key live. WeakSet has no
        // value column, so it is unaffected.
        self.weakMapEphemeronFixpoint();
        // Fixpoint may have pushed more deferred items. Drain again
        // before the post-mark weak pass.
        self.drainMarkWorklist();
        // §26.1 / §24.3 / §24.4 / §26.2 — post-mark weak handling:
        // clear dead WeakRef targets, prune dead WeakMap/WeakSet
        // entries, queue FinalizationRegistry cleanup jobs. Must run
        // BEFORE the sweep — `isWeakReferentLive` reads the
        // `mark_color` the sweep is about to filter on. Marking is
        // done now, so turn weak-aware mode back off.
        self.weak_aware_mark = false;
        self.processWeakReferences();

        // Weak-clear the `call_method` IC. Cells caching a callee
        // whose mark-colour doesn't match `live_color` are stale —
        // the callee is about to be swept (or, on the first cycle
        // after a previous sweep, points at memory that may have
        // been reused). Nulling them forces the slow path + refill
        // on the next call site execution.
        self.weakClearCallICs();

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
        const lc = self.live_color;
        sweepList(&self.strings_mature, lc, ba);
        sweepList(&self.functions_mature, lc, sa);
        sweepList(&self.objects_mature, lc, .{ self.allocator, &self.object_pool });
        sweepList(&self.environments_mature, lc, sa);
        sweepList(&self.generators_mature, lc, sa);
        sweepList(&self.symbols_mature, lc, sa);
        sweepList(&self.bigints_mature, lc, sa);
        promoteYoungList(*JSString, &self.strings_young, &self.strings_mature, lc, self.allocator, ba);
        promoteYoungList(*JSFunction, &self.functions_young, &self.functions_mature, lc, self.allocator, sa);
        promoteYoungList(*JSObject, &self.objects_young, &self.objects_mature, lc, self.allocator, .{ self.allocator, &self.object_pool });
        promoteYoungList(*Environment, &self.environments_young, &self.environments_mature, lc, self.allocator, sa);
        promoteYoungList(*JSGenerator, &self.generators_young, &self.generators_mature, lc, self.allocator, sa);
        promoteYoungList(*JSSymbol, &self.symbols_young, &self.symbols_mature, lc, self.allocator, sa);
        promoteYoungList(*JSBigInt, &self.bigints_young, &self.bigints_mature, lc, self.allocator, sa);

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
        // Cycle complete — disarm so the next collect knows to flip.
        self.cycle_started = false;

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

        // Arm the cycle if the caller hasn't yet — same protocol
        // as `collectFull`. Realm path calls `beginMinorCycle`
        // before `markRoots`; the unit-test path comes here cold.
        if (!self.cycle_started) self.beginMinorCycle();

        // ── Mark phase ──────────────────────────────────────────
        for (roots) |r| self.markValue(r);
        for (self.handle_scopes.items) |scope| {
            for (scope.handles.items) |r| self.markValue(r);
        }
        // Chunk-constant heap values — permanently-live roots; the
        // template graph / BigInt literals (built young at compile
        // time) are promoted on the first minor cycle and stay
        // reachable thereafter.
        for (self.const_roots.items) |v| self.markValue(v);
        // Native-constructor instances currently in flight.
        for (self.native_ctor_roots.items) |v| self.markValue(v);
        // Registered symbols are pinned (§20.4.2.2); promoteYoungList
        // honours `entry.pinned` and tenures them straight into the
        // mature list without needing a per-cycle re-mark.

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

        // Weak-clear the `call_method` IC — see `collectFull` for
        // the rationale. Young collection nulls cells whose callee
        // is young AND unmarked (about to be swept); mature callees
        // pass through marked, so cells caching them survive.
        self.weakClearCallICs();

        // Snapshot pre-sweep young counts for the diagnostic line.
        const pre_objs = self.objects_young.items.len;
        const pre_strs = self.strings_young.items.len;
        const pre_fns = self.functions_young.items.len;
        const pre_envs = self.environments_young.items.len;
        const pre_gens = self.generators_young.items.len;
        const pre_syms = self.symbols_young.items.len;
        const pre_bigs = self.bigints_young.items.len;

        // Drain deferred-mark items (promise reaction chain) before
        // the young sweep — a deferred mark whose target is young
        // would otherwise be unmarked at sweep time and freed.
        self.drainMarkWorklist();

        // ── Sweep + promote phase ───────────────────────────────
        // Young survivors are relinked into the mature list; young
        // garbage is freed. Mature lists are not touched — the
        // mark-colour flip at the top of the next cycle ages every
        // mature `mark_color` back to "unmarked" without a linear
        // walk over the mature set. (Before the colour trick, this
        // loop body cleared `marked = false` on every mature object,
        // defeating part of the generational promise: a "cheap"
        // minor cycle still cost O(mature_set) per cycle.)
        const lc = self.live_color;
        promoteYoungList(*JSString, &self.strings_young, &self.strings_mature, lc, self.allocator, .{ self.allocator, self.bytes_allocator });
        promoteYoungList(*JSFunction, &self.functions_young, &self.functions_mature, lc, self.allocator, .{self.allocator});
        promoteYoungList(*JSObject, &self.objects_young, &self.objects_mature, lc, self.allocator, .{ self.allocator, &self.object_pool });
        promoteYoungList(*Environment, &self.environments_young, &self.environments_mature, lc, self.allocator, .{self.allocator});
        promoteYoungList(*JSGenerator, &self.generators_young, &self.generators_mature, lc, self.allocator, .{self.allocator});
        promoteYoungList(*JSSymbol, &self.symbols_young, &self.symbols_mature, lc, self.allocator, .{self.allocator});
        promoteYoungList(*JSBigInt, &self.bigints_young, &self.bigints_mature, lc, self.allocator, .{self.allocator});

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
        self.cycle_started = false;

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
        live_color: u1,
        allocator: std.mem.Allocator,
        deinit_args: anytype,
    ) void {
        const EntryT = @typeInfo(PtrT).pointer.child;
        const has_pinned = @hasField(EntryT, "pinned");
        var i: usize = young_list.items.len;
        while (i > 0) {
            i -= 1;
            const entry = young_list.items[i];
            const live = (has_pinned and entry.pinned) or entry.mark_color == live_color;
            if (live) {
                // Survivor — leave `mark_color` as the current
                // `live_color`; the next cycle's flip ages it to
                // "unmarked". Promote into mature.
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
                if (comptime EntryT == JSObject) {
                    // Slab pool path — drop sub-fields, then
                    // return the header to the free-list instead
                    // of dropping it through the GP allocator.
                    // `deinit_args` is `.{allocator, &heap.object_pool}`
                    // for JSObject specifically; the comptime
                    // branch keeps the generic call shape unchanged
                    // for every other heap type.
                    entry.deinitFields(deinit_args[0]);
                    deinit_args[1].destroy(entry);
                } else {
                    @call(.auto, EntryT.deinit, .{entry} ++ deinit_args);
                }
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
        if (o.privatePropertyIterator()) |ppit_outer| {
            var ppit = ppit_outer;
            while (ppit.next()) |entry| self.markValue(entry.value_ptr.*);
        }
        if (o.privateAccessorIterator()) |pait_outer| {
            var pait = pait_outer;
            while (pait.next()) |entry| {
                if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
                if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
            }
        }
        if (o.accessorIterator()) |ait_outer| {
            var ait = ait_outer;
            while (ait.next()) |entry| {
                if (entry.value_ptr.*.getter) |g| self.markValue(taggedFunction(g));
                if (entry.value_ptr.*.setter) |s| self.markValue(taggedFunction(s));
            }
        }
        if (o.namespaceRedirectIterator()) |nrit_outer| {
            var nrit = nrit_outer;
            while (nrit.next()) |entry| {
                self.markValue(taggedObject(entry.value_ptr.target_ns));
            }
        }
        if (o.boxed_primitive) |bp| self.markValue(bp);
        if (o.boxed_string) |bs| self.markString(bs);
        if (o.getMapData()) |md| {
            for (md.entries.items) |entry| {
                if (entry.deleted) continue;
                self.markValue(entry.key);
                self.markValue(entry.value);
            }
        }
        if (o.getSetData()) |sd| {
            for (sd.entries.items) |entry| {
                if (entry.deleted) continue;
                self.markValue(entry.value);
            }
        }
        if (o.array_like_iter) |s| {
            self.markValue(s.target);
            self.markValue(s.for_in_source);
        }
        if (o.map_set_iter) |s| self.markValue(s.source);
        if (o.regexp_string_iter) |s| {
            self.markValue(s.regexp);
            self.markValue(s.string);
        }
        if (o.iter_record) |s| self.markValue(s.next);
        if (o.iter_helper) |s| {
            self.markValue(s.source);
            self.markValue(s.next_fn);
            self.markValue(s.payload);
            self.markValue(s.active);
            for (s.concat_inputs.items) |ci| {
                self.markValue(ci.iterable);
                self.markValue(ci.method);
            }
            for (s.zip_inputs.items) |zi| {
                self.markValue(zi.iter);
                self.markValue(zi.next);
                self.markValue(zi.key);
                self.markValue(zi.pad);
            }
        }
        if (o.capability_record) |c| {
            self.markValue(c.resolve);
            self.markValue(c.reject);
        }
        if (o.finally_callback) |f| self.markValue(taggedFunction(f));
        self.markValue(o.finally_value);
        if (o.finally_constructor) |f| self.markValue(taggedFunction(f));
        if (o.generator_ref) |gen| self.markGenerator(gen);
        if (o.is_weak_ref) self.markValue(o.getWeakRefTarget());
        if (o.getFinalizationCells()) |fc| {
            self.markValue(fc.cleanup_callback);
            for (fc.cells.items) |cell| {
                if (cell.deleted) continue;
                self.markValue(cell.target);
                self.markValue(cell.held_value);
                if (cell.has_token) self.markValue(cell.unregister_token);
            }
        }
        for (o.key_anchors.items) |s| self.markString(s);
        if (o.promiseReactionsConst()) |reactions| {
            for (reactions.items) |r| {
                self.markValue(r.on_fulfilled);
                self.markValue(r.on_rejected);
                self.markValue(r.result_promise);
            }
        }
        if (o.promiseWaitersConst()) |waiters| {
            for (waiters.items) |w| self.markGenerator(w);
        }
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
        // Same proto-chain rationale as markValue's object arm.
        if (o.prototype) |p| {
            self.mark_worklist.append(self.allocator, taggedObject(p)) catch {
                self.markValue(taggedObject(p));
            };
        }
        if (o.proxy_target) |pt| self.markValue(taggedObject(pt));
        if (o.proxy_handler) |ph| self.markValue(taggedObject(ph));
        if (o.proxy_target_fn) |ptf| self.markValue(taggedFunction(ptf));
        if (o.getTypedView()) |tv| self.markValue(taggedObject(tv.viewed));
        if (o.getDataView()) |dv| self.markValue(taggedObject(dv.viewed));
    }

    /// Mark the typed internal-slot pointers of a `JSFunction` —
    /// the `markValue` function arm minus the property bag.
    fn markFunctionInternalSlots(self: *Heap, f: *JSFunction) void {
        // Same closure-chain rationale as markValue's function arm.
        if (f.captured_env) |env| {
            self.mark_env_worklist.append(self.allocator, env) catch {
                self.markEnvironment(env);
            };
        }
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
        // §10.2.3 [[HomeObject]] — see the `markValue` function arm.
        if (f.home_object) |ho| self.markValue(taggedObject(ho));
        if (f.home_function) |hf| self.markValue(taggedFunction(hf));
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

    /// Push a native-constructor instance onto the in-flight root
    /// stack — see `native_ctor_roots`. Pair every call with a
    /// `defer heap.popNativeRoot()`.
    pub fn pushNativeRoot(self: *Heap, v: Value) !void {
        try self.native_ctor_roots.append(self.allocator, v);
    }

    /// Pop the most recent native-constructor instance root.
    pub fn popNativeRoot(self: *Heap) void {
        _ = self.native_ctor_roots.pop();
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
        // Fast reject 1 — non-heap value can't create any
        // generational edge. The fixture-heavy
        // `o.x = i` (int32) case hits this in O(1) without
        // instancing the five `valueAs*` casts inside
        // `isYoungHeapValue`. Measured ~8 % of `prop_write`
        // sample time on the un-fast-pathed barrier; the cheap
        // tag-compare here collapses it to ~0 % for primitive
        // stores. Doubles, ints, bools, null, undefined, hole.
        if (!v.isHeapValue()) return;
        // Fast reject 2 — young container can't create an
        // old→young edge (a young→young store is reclaimed
        // wholesale by the young sweep).
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

test "Heap: write barrier fast-path bails on primitives regardless of container generation" {
    // The primitive check sits BEFORE the generation check in the
    // barrier (see `writeBarrier` doc-comment). This test pins the
    // ordering so a refactor that moves the heap-value reject back
    // below the generation reject would still pass the
    // "primitive store" test above but regress on the
    // young-container hot path the profiler flagged.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const young_container = try heap.allocateObject(); // .young by default
    const mature_container = try heap.allocateObject();
    mature_container.generation = .mature;

    // Every primitive: int32, double, bool, null, undefined, hole.
    const primitives = [_]Value{
        Value.fromInt32(0),
        Value.fromInt32(std.math.maxInt(i32)),
        Value.fromDouble(1.5),
        Value.fromDouble(std.math.nan(f64)),
        Value.true_,
        Value.false_,
        Value.null_,
        Value.undefined_,
        Value.hole_,
    };
    for (primitives) |p| {
        heap.writeBarrier(.{ .object = young_container }, p);
        heap.writeBarrier(.{ .object = mature_container }, p);
    }
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

    // Relinked into mature — same address (non-moving), generation
    // flipped. Survivor carries the current `live_color`; the next
    // cycle's flip ages it back to "unmarked" automatically (the
    // cross-cycle behavioural test above covers that aging).
    try testing.expectEqual(@as(usize, 0), heap.objects_young.items.len);
    try testing.expectEqual(@as(usize, 1), heap.objects_mature.items.len);
    try testing.expectEqual(Generation.mature, survivor.generation);
    try testing.expectEqual(addr_before, @intFromPtr(survivor));
    try testing.expectEqual(heap.live_color, survivor.mark_color);
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
    // it transitively. The cycle-end `live_color` flip ages every
    // mature `mark_color` automatically — so a follow-up
    // `collectFull` with empty roots can still free this object.
    // That's the behavioural check that used to be done indirectly
    // via `!mature.marked`.
    const mature = try heap.allocateObject();
    _ = heap.objects_young.pop();
    try heap.objects_mature.append(heap.allocator, mature);
    mature.generation = .mature;

    heap.collectYoung(&.{taggedObject(mature)});

    // A subsequent collectFull with empty roots must still be able
    // to free it — proof the mark colour is honored across cycles.
    heap.collectFull(&.{});
    try testing.expectEqual(@as(usize, 0), heap.objects_mature.items.len);
}

// ── Mark-colour flip tests ─────────────────────────────────────────
// The mark-bit scheme: every heap kind carries a `mark_color: u1`;
// an object is "live this cycle" iff `obj.mark_color ==
// heap.live_color`. Each cycle flips `live_color` once at the top,
// so survivors of the previous cycle automatically look "unmarked"
// without a per-object clear loop. The tests below characterise the
// flip protocol — they belong to the colour-flip refactor itself
// rather than to any single allocator helper.

test "Heap: live_color flips on each major cycle" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const c0 = heap.live_color;
    heap.collect(&.{});
    const c1 = heap.live_color;
    try testing.expect(c0 != c1);

    heap.collect(&.{});
    const c2 = heap.live_color;
    try testing.expect(c1 != c2);
    // u1 has period 2 — two flips return to the original colour.
    try testing.expectEqual(c0, c2);
}

test "Heap: live_color flips on each minor cycle" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const c0 = heap.live_color;
    heap.collectYoung(&.{});
    try testing.expect(c0 != heap.live_color);
}

test "Heap: a freshly-allocated object's mark_color matches live_color" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const o = try heap.allocateObject();
    try testing.expectEqual(heap.live_color, o.mark_color);

    // Holds across cycles — after a cycle, a fresh allocation
    // again carries the (newly flipped) live colour.
    heap.collect(&.{});
    const o2 = try heap.allocateObject();
    try testing.expectEqual(heap.live_color, o2.mark_color);
}

test "Heap: a survivor's mark_color matches live_color after the cycle" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const o = try heap.allocateObject();
    heap.collect(&.{taggedObject(o)});
    try testing.expectEqual(heap.live_color, o.mark_color);
}

test "Heap: cycle_started is false outside a cycle and after one finishes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    try testing.expect(!heap.cycle_started);
    heap.collect(&.{});
    try testing.expect(!heap.cycle_started);
    heap.collectYoung(&.{});
    try testing.expect(!heap.cycle_started);
}

test "Heap: beginMajorCycle arms the cycle and flips live_color exactly once" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const c0 = heap.live_color;
    heap.beginMajorCycle();
    try testing.expect(heap.cycle_started);
    try testing.expectEqual(@as(u1, ~c0), heap.live_color);

    // collectFull called after explicit arming must NOT re-flip.
    const c_armed = heap.live_color;
    heap.collectFull(&.{});
    // After the cycle, live_color is the post-flip value; the
    // cycle_started flag is back to false.
    try testing.expectEqual(c_armed, heap.live_color);
    try testing.expect(!heap.cycle_started);
}

test "Heap: beginMinorCycle arms the cycle and flips live_color exactly once" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const c0 = heap.live_color;
    heap.beginMinorCycle();
    try testing.expect(heap.cycle_started);
    try testing.expectEqual(@as(u1, ~c0), heap.live_color);

    // collectYoung called after explicit arming must NOT re-flip.
    const c_armed = heap.live_color;
    heap.collectYoung(&.{});
    try testing.expectEqual(c_armed, heap.live_color);
    try testing.expect(!heap.cycle_started);
}

test "Heap: markValue is idempotent within a cycle" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const o = try heap.allocateObject();
    heap.beginMajorCycle();
    heap.markValue(taggedObject(o));
    const after_first = o.mark_color;
    heap.markValue(taggedObject(o));
    try testing.expectEqual(after_first, o.mark_color);
    try testing.expectEqual(heap.live_color, o.mark_color);
    // Clean up — finish the cycle so heap.deinit doesn't trip on
    // a dangling cycle_started flag.
    heap.collectFull(&.{taggedObject(o)});
}

test "Heap: a mature object unreachable after a cycle is swept by the next cycle" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Tenure the object via a full cycle that holds it as a root.
    const o = try heap.allocateObject();
    heap.collect(&.{taggedObject(o)});
    try testing.expectEqual(Generation.mature, o.generation);
    try testing.expectEqual(@as(usize, 1), heap.objects_mature.items.len);

    // Next cycle with empty roots: the colour flip ages
    // `o.mark_color` to the "unmarked" value automatically, no
    // per-object clear pass required.
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.objects_mature.items.len);
}

// ── Symbol-registry pin tests ───────────────────────────────────────
// `Symbol.for("k")` interns into `Heap.symbol_registry`; the entries
// are permanently alive (the spec gives no way to evict them). The
// per-cycle re-mark loop the GC used to do is replaced by a `pinned`
// bit on `JSSymbol` — the sweep skips pinned entries (same mechanism
// chunk-constant strings use). The tests below pin the invariants:
// the symbol survives across cycles, an un-pinned symbol does NOT,
// and `WeakRef(symbol)` keeps observing the pinned referent (the
// non-obvious corner — the `mark_color` of a pinned symbol can go
// stale, so `isWeakReferentLive` needs the `pinned` short-circuit).

test "Heap: a pinned registered symbol survives multiple cycles with no roots" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const sym = try heap.allocateSymbol("k");
    sym.is_registered = true;
    sym.pinned = true;
    try heap.symbol_registry.put(heap.allocator, "k", sym);

    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 1), heap.symbolCount());
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 1), heap.symbolCount());
    heap.collectYoung(&.{});
    try testing.expectEqual(@as(usize, 1), heap.symbolCount());
}

test "Heap: an unpinned non-registered symbol is freed without roots" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    _ = try heap.allocateSymbol("x");
    heap.collect(&.{});
    try testing.expectEqual(@as(usize, 0), heap.symbolCount());
}

test "Heap: WeakRef to a pinned symbol observes the live referent after GC" {
    // The corner the `pinned` short-circuit on `isWeakReferentLive`
    // exists for. Without it, a registered symbol with no other
    // mark-phase reference would have a stale `mark_color`,
    // `isWeakReferentLive` would read false, and processWeakReferences
    // would clear the WeakRef's target slot — even though the symbol
    // is permanently alive via the registry.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Symbol.for("k") analogue — registered + pinned.
    const sym = try heap.allocateSymbol("k");
    sym.is_registered = true;
    sym.pinned = true;
    try heap.symbol_registry.put(heap.allocator, "k", sym);
    const sym_v = taggedSymbol(sym);

    // Build a WeakRef object pointing at the symbol. Keep the
    // WeakRef itself rooted; the cycle's weak-aware pass reaches it
    // and decides whether to clear its target slot.
    const wr = try heap.allocateObject();
    wr.is_weak_ref = true;
    try wr.setWeakRefTarget(testing.allocator, sym_v);

    heap.collect(&.{taggedObject(wr)});

    // Target slot must still point at the same symbol.
    const after = valueAsSymbol(wr.getWeakRefTarget()) orelse {
        return error.TestExpectedNonNullTarget;
    };
    try testing.expectEqual(sym, after);
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

test "Heap: collect honors the mark colour across cycles" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const s = try heap.allocateString("kept");
    const v = Value.fromString(s);

    heap.collect(&.{v});
    // Cycle 1 survivor — `mark_color == live_color` right now.
    try testing.expectEqual(heap.live_color, s.mark_color);

    // A second cycle with no roots must free it. The cycle-start
    // `live_color` flip ages `s.mark_color` to the "unmarked"
    // value automatically — no per-mature clear pass needed.
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
