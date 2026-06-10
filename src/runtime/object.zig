//! `JSObject` — Cynic's plain runtime object.
//!
//! later intentionally skips shapes / hidden classes — every
//! `JSObject` is a name → `Value` hashtable with an optional
//! prototype pointer. Performance is not the priority here;
//! correctness is. later or M5 will introduce shapes (the
//! handbook's [compiler-engineering.md] cites Self / V8 lineage
//! for the eventual design).
//!
//! later scope:
//! • Object literals (`{a: 1, b: 2}`).
//! • Property access (`obj.x`, `obj['x']`, `obj.x = v`).
//! • Prototype pointer — installed by built-in factories in
//! later (`Error.prototype` etc); user-visible
//! `Object.getPrototypeOf` / `__proto__` come later.
//! Out of scope: shapes, full property descriptors,
//! getters/setters, symbol keys, classes, `new`.

const std = @import("std");

const Value = @import("value.zig").Value;
const HeapKind = @import("function.zig").HeapKind;

test {
    // Pull the property-shape module's unit tests into the suite.
    // `shape.zig` is not yet wired into `JSObject` storage; this
    // keeps its tests running while it is developed standalone.
    _ = @import("shape.zig");
}

/// One instance-field initializer: a (name, function) pair that
/// the constructor invokes during instance creation to compute
/// `this.name = init_fn.call(this)`. Stored on the class's
/// prototype so the `init_instance_fields` op can find it via
/// the executing function's home object.
pub const FieldInit = struct {
    name: []const u8,
    /// `null` means `class C { x; }` — declared without an
    /// initializer; assigned `undefined`. Otherwise a JSFunction
    /// whose body evaluates the init expression with the
    /// instance bound as `this`.
    init_fn: ?*@import("function.zig").JSFunction,
    /// Private fields write into `private_properties`; public
    /// fields write into `properties`. Distinguished here rather
    /// than by name-prefix so the runtime is clean.
    is_private: bool = false,
    /// §15.7 — private methods can be plain methods or accessors.
    /// Plain methods land in `private_properties` (the function
    /// itself is the value). Accessor kinds land in
    /// `private_accessors[name].{getter, setter}` so a read /
    /// write through `this.#x` invokes the function instead of
    /// returning it.
    accessor_kind: AccessorKind = .none,
};

pub const AccessorKind = enum(u8) {
    none,
    getter,
    setter,
};

/// §15.2.1.16.3 ResolveExport — a `export { X as Y } from "src"`
/// re-export records an indirect entry that resolves to `X` on
/// the source module's namespace. Cynic stores these on the
/// importer's namespace under `namespace_redirects[Y]`; reads
/// walk the chain at access time with a visited-set so a
/// cyclic chain terminates instead of recursing forever.
///
/// `target_key` is borrowed from the chunk constant pool (a
/// `JSString.bytes` slice pinned for the realm's lifetime); the
/// target namespace is heap-owned by `target_ns`'s module
/// record, which itself outlives every namespace it could be
/// reached from (modules live for the realm).
pub const NamespaceRedirect = struct {
    target_ns: *JSObject,
    target_key: []const u8,
    /// §15.2.1.16 step 9 — only IndirectExportEntries (the
    /// `export { X } from "src"` flavour) are validated at
    /// instantiation. Star-merged redirects come from a
    /// different ExportEntries list and don't error if their
    /// chain resolves to ambiguous/circular/null (the spec
    /// surfaces that lazily, at namespace-read time).
    /// `false` for `module_reexport_star`-installed entries
    /// via `mergeStarKey`, `true` for `module_reexport_named`.
    from_indirect_export: bool = false,
};

/// §27.2.6 PromiseState — internal slot, never surfaced to JS.
/// `.none` is Cynic's sentinel for "not a Promise"; the value /
/// reactions / waiters slots are unread in that state.
pub const PromiseState = enum(u8) {
    none,
    pending,
    fulfilled,
    rejected,
};

/// Accessor pair (§10.1.8 [[Get]] / §10.1.9 [[Set]]). Either
/// half may be `null` (write-only / read-only).
pub const Accessor = struct {
    getter: ?*@import("function.zig").JSFunction = null,
    setter: ?*@import("function.zig").JSFunction = null,
};

/// §6.2.5 PropertyDescriptor flags. Default for ordinary
/// property creation is all-true (writable + enumerable +
/// configurable); deviations land in the parallel
/// `JSObject.property_flags` map. Most properties never need
/// an entry there — only built-in proto methods (which are
/// non-enumerable) and properties created via
/// `Object.defineProperty` with explicit flags.
pub const PropertyFlags = packed struct {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,

    pub const default: PropertyFlags = .{};
};

/// ES2026 explicit-resource-management §27.3 / §27.4 —
/// `[[DisposableState]]` slot on a DisposableStack /
/// AsyncDisposableStack instance.
///
/// The four variants encode BOTH the stack kind (sync vs async)
/// and the lifecycle state ("pending" vs "disposed"). The kind
/// discriminator is needed so `requireDisposableStack` rejects
/// an `AsyncDisposableStack` receiver (and vice versa) without
/// a prototype-identity check — a user `Object.setPrototypeOf`
/// must not flip the brand. The encoding keeps the brand in one
/// 8-bit enum so the existing `disposable_state` slot doubles as
/// the kind tag.
///
///   - `.sync_pending` / `.sync_disposed` — DisposableStack §27.3
///   - `.async_pending` / `.async_disposed` — AsyncDisposableStack §27.4
pub const DisposableState = enum(u8) {
    sync_pending,
    sync_disposed,
    async_pending,
    async_disposed,

    /// Whether this brand is the AsyncDisposableStack §27.4 family.
    pub fn isAsync(self: DisposableState) bool {
        return self == .async_pending or self == .async_disposed;
    }

    /// Whether the stack has been disposed (or moved-from). Once
    /// disposed, `.use()` / `.adopt()` / `.defer()` / `.move()`
    /// throw ReferenceError; `.dispose()` / `.disposeAsync()` no-op.
    pub fn isDisposed(self: DisposableState) bool {
        return self == .sync_disposed or self == .async_disposed;
    }

    /// The "pending → disposed" transition for the same kind.
    pub fn toDisposed(self: DisposableState) DisposableState {
        return switch (self) {
            .sync_pending, .sync_disposed => .sync_disposed,
            .async_pending, .async_disposed => .async_disposed,
        };
    }
};

/// ES2026 explicit-resource-management — the `[[Hint]]` field
/// on a `DisposableResource` record (§27.3.2.1 step 4 /
/// §27.4.2.1 step 4). DisposableStack only ever appends
/// `sync_dispose`; AsyncDisposableStack appends either.
pub const DisposableHint = enum(u8) { sync_dispose, async_dispose };

/// ES2026 explicit-resource-management `DisposableResource`
/// record (§9.5.3 AddDisposableResource step 4). One per
/// `using` binding / `.use()` / `.adopt()` / `.defer()` call.
/// Iterated in REVERSE inside DisposeResources (LIFO).
pub const DisposableResource = struct {
    resource: Value,
    hint: DisposableHint,
    dispose_method: Value,
};

/// ES2026 explicit-resource-management — per-disposal walk state
/// for an `AsyncDisposableStack` (§27.4.3.4 + §9.5.4 with
/// hint = async-dispose). One instance per outstanding
/// `.disposeAsync()` call; freed once the chain settles the
/// outer Promise.
///
/// The async DisposeResources walk is driven by a `.then` chain
/// across the snapshotted resource records — each step's onFulfilled
/// / onRejected reads `cursor`, invokes the disposer at
/// `resources[cursor-1]`, and decrements. The rejected handler
/// merges its `reason` into `pending_error` (wrapping via
/// SuppressedError per §9.5.4 step 2.b.iv-vi when one is already
/// in flight). The final reaction settles `outer` — fulfilled if
/// `has_pending_error` is false, rejected with `pending_error`
/// otherwise.
///
/// All three reachable values (`resources` records, `pending_error`,
/// `outer`) are marked by `Heap.markRoots`; without that the
/// disposal walk would dangle across a minor cycle that ran
/// between two of its microtask steps.
pub const AsyncDisposeWalk = struct {
    resources: std.ArrayListUnmanaged(DisposableResource) = .empty,
    cursor: u32 = 0,
    pending_error: Value = Value.undefined_,
    has_pending_error: bool = false,
    /// True when `pending_error` was seeded by an external caller
    /// (the `dispose_stack_async` opcode in mode 1) rather than by
    /// a disposer's throw. The terminal `finalizeSettle` clears
    /// pending_error before settling if THIS is still set —
    /// meaning no disposer contributed, so the outer Promise
    /// fulfils with undefined and the caller re-throws the
    /// original. A disposer throw clears the flag (its
    /// `pending_error` value carries the suppressed external on
    /// the [[Suppressed]] side of a fresh SuppressedError).
    external_seed_only: bool = false,
    outer: Value = Value.undefined_,

    pub fn deinit(self: *AsyncDisposeWalk, allocator: std.mem.Allocator) void {
        self.resources.deinit(allocator);
        allocator.destroy(self);
    }
};

/// `[[MapData]]` storage (§24.1.4). Keeps insertion order so
/// `forEach` / `for-of` walks pairs in the order they were
/// added. later uses linear-scan lookup; revisit with a real
/// hashmap once we have shapes.
pub const MapData = struct {
    entries: std.ArrayListUnmanaged(MapEntry) = .empty,
    /// Whether this map data belongs to a WeakMap instance.
    /// `WeakMap.prototype.{set, get, has, delete}` reject
    /// receivers whose map_data isn't a WeakMap; symmetric
    /// rejection on the Map side. Also tells the major collector
    /// to treat entry keys / values as weak edges (§24.3): a
    /// WeakMap entry whose key becomes unreachable is tombstoned
    /// by `Heap.processWeakReferences` after an ephemeron fixpoint.
    is_weak: bool = false,

    pub fn deinit(self: *MapData, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const MapEntry = struct {
    key: Value,
    value: Value,
    /// Deleted entries stay in the array so an in-progress
    /// iteration's positional index doesn't shift. They're
    /// skipped on read / iterate.
    deleted: bool = false,
};

/// `[[SetData]]` storage (§24.2.4). Same shape as MapData
/// minus the value column.
pub const SetData = struct {
    entries: std.ArrayListUnmanaged(SetEntry) = .empty,
    /// Whether this set data belongs to a WeakSet instance.
    /// Set.prototype.{add, has, delete, clear, forEach, entries,
    /// values, keys, size, …} reject receivers whose set_data
    /// is a WeakSet's; symmetric rejection on the WeakSet side.
    /// Also tells the major collector to treat members as weak
    /// edges (§24.4): a WeakSet member that becomes unreachable
    /// is tombstoned by `Heap.processWeakReferences`.
    is_weak: bool = false,

    pub fn deinit(self: *SetData, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const SetEntry = struct {
    value: Value,
    deleted: bool = false,
};

/// Per-instance state for the synthetic iterator returned by
/// `openIterator`'s array-like fallback (§7.4.1 step 4) and by
/// the parallel `fromIterable` path in Map / Set / WeakMap
/// constructors. The iterator walks `target[0..length]` with
/// `idx` as the cursor. `done` flips on first out-of-range read.
/// Kept off the property bag so it isn't enumerable / inspectable
/// from JS (the spec's [[IteratedObject]] / [[NextIndex]] are
/// internal slots).
pub const ArrayLikeIterState = struct {
    pub const Kind = enum { values, keys, entries };

    target: Value,
    idx: u32 = 0,
    done: bool = false,
    /// §23.1.5.1 CreateArrayIterator kind — selects whether each
    /// yield is a `value`, an integer index, or a `[idx, value]`
    /// pair. Defaults to `.values`; non-Array consumers (String
    /// iterator, for-in snapshot) reuse the same state with this
    /// field unread.
    kind: Kind = .values,
    /// §14.7.5.6 EnumerateObjectProperties live-deletion check:
    /// for `for-in` only, the iterator skips any key from the
    /// snapshot that is no longer present on the original source
    /// object at yield time. Null for non-for-in iterators
    /// (e.g. `Array.from` arg, string iter).
    for_in_source: Value = Value.undefined_,

    pub fn deinit(self: *ArrayLikeIterState, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

/// Per-instance state for Map / Set iterator objects
/// (§24.1.5.1 CreateMapIterator, §24.2.5.1 CreateSetIterator).
/// Kept off the property bag so the iterator exposes only internal
/// slots — `MapIteratorPrototype` / `SetIteratorPrototype` carry
/// the visible `next` / `@@toStringTag`.
pub const MapSetIterState = struct {
    /// Iteration kind — `[[MapIterationKind]]` /
    /// `[[SetIterationKind]]`. Set iterators only use
    /// `.entries` / `.values`.
    pub const Kind = enum { entries, keys, values };
    /// Distinguishes a Map Iterator from a Set Iterator for the
    /// `next` brand check — the two have distinct internal-slot
    /// sets (`[[IteratedMap]]` vs `[[IteratedSet]]`).
    pub const Brand = enum { map, set };

    brand: Brand,
    /// `[[IteratedMap]]` / `[[IteratedSet]]`. Cleared to
    /// `undefined` on exhaustion so a later source mutation can't
    /// revive iteration.
    source: Value = Value.undefined_,
    /// `[[MapNextIndex]]` / `[[SetNextIndex]]` — the entry cursor.
    idx: u32 = 0,
    kind: Kind = .entries,

    pub fn deinit(self: *MapSetIterState, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

/// §22.2.9.1 CreateRegExpStringIterator internal slots — the
/// per-instance state of the iterator `String.prototype.matchAll`
/// / `RegExp.prototype[@@matchAll]` return. Kept off the property
/// bag so the iterator exposes only `next` / `@@iterator` /
/// `@@toStringTag` from `%RegExpStringIteratorPrototype%`.
pub const RegExpStringIterState = struct {
    /// `[[IteratingRegExp]]` — the matcher RegExp object.
    regexp: Value = Value.undefined_,
    /// `[[IteratedString]]` — the subject string.
    string: Value = Value.undefined_,
    /// `[[Global]]`.
    global: bool = false,
    /// `[[Unicode]]`.
    unicode: bool = false,
    /// `[[Done]]`.
    done: bool = false,

    pub fn deinit(self: *RegExpStringIterState, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

/// §7.4.1 Iterator Record — the `{[[NextMethod]], [[Done]]}` an
/// iteration step needs alongside the iterator object. `iter_step`
/// caches it on the *iterated object's* typed `iter_record` slot
/// (lazily, on the first step) so destructuring / for-of don't
/// re-fire the `get next` accessor and don't leave observable own
/// properties on a user-supplied iterator.
pub const IterRecord = struct {
    /// `[[NextMethod]]` — snapshotted once, on the first step.
    next: Value = Value.undefined_,
    /// Whether `[[NextMethod]]` has been snapshotted yet.
    next_cached: bool = false,
    /// `[[Done]]`.
    done: bool = false,

    pub fn deinit(self: *IterRecord, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

/// §27.2.1.5 PromiseCapability internal slots — populated by the
/// per-cap executor closure (§27.2.1.5.1 GetCapabilitiesExecutor)
/// and consulted by `newPromiseCapability` once the user
/// constructor returns. `called` guards the "executor called
/// twice" TypeError. Hidden from JS; the state JSObject is an
/// implementation-private vehicle that user code shouldn't reach.
pub const PromiseCapabilityRecord = struct {
    resolve: Value = Value.undefined_,
    reject: Value = Value.undefined_,
    called: bool = false,

    pub fn deinit(self: *PromiseCapabilityRecord, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

/// Per-instance state for the lazy `Iterator.prototype.*` helpers
/// (`from`, `map`, `filter`, `take`, `drop`, `flatMap`, `zip`).
/// §27.1.5 — every helper returns a new iterator whose `next`
/// pulls from `source` through `next_fn` and processes the value
/// through `payload`. The shape unifies the V8 / SM / JSC pattern
/// of "lazy generator-like wrapper".
///
/// Field usage per helper:
///   from    : source, next_fn
///   map     : source, next_fn, payload, count, done, running
///   filter  : source, next_fn, payload, count, done, running
///   take    : source, next_fn, count (remaining), done, running
///   drop    : source, next_fn, count (remaining-to-drop), done, running, started
///   flatMap : source, next_fn, payload, active, count, done, running
///   zip     : zip_inputs (per-input iter/next/active/key/pad),
///             count, done, running, started, keyed, mode
///
/// Hidden from JS — `Object.getOwnPropertyNames(iter)` no longer
/// returns spec-internal slot names like `[[Iterated]]` / `[[Done]]`.
/// §27.1.4.2 Iterator.concat — one validated input record,
/// `{[[Iterable]], [[OpenMethod]]}`. Held inside
/// `IteratorHelperState` so the concat iterator carries its inputs
/// as an internal slot rather than as observable own properties.
pub const ConcatInput = struct {
    iterable: Value = Value.undefined_,
    method: Value = Value.undefined_,
};

/// §27.5.4 / §27.5.5 Iterator.zip / Iterator.zipKeyed — one
/// per-input record. Held in `IteratorHelperState.zip_inputs` so
/// the zip iterator carries its inputs as an internal slot rather
/// than as observable own properties.
pub const ZipInput = struct {
    /// The opened sub-iterator.
    iter: Value = Value.undefined_,
    /// §7.4.2 GetIteratorDirect — the snapshotted `next` method.
    next: Value = Value.undefined_,
    /// Whether the sub-iterator is still open (in `openIters`).
    active: bool = true,
    /// zipKeyed only — the result key string for this input.
    key: Value = Value.undefined_,
    /// `longest` mode only — the precomputed padding value.
    pad: Value = Value.undefined_,
};

pub const IteratorHelperState = struct {
    /// Which iterator helper this state drives. §27.1.4.1
    /// `%IteratorHelperPrototype%.next` / `.return` are generic —
    /// one shared method dispatches to the per-kind step on this
    /// discriminator. `.map` for the `Iterator.from` wrapper too
    /// (it never reaches the helper prototype, so the value is
    /// unread there).
    pub const HelperKind = enum { map, filter, take, drop, flat_map, concat, zip };

    source: Value = Value.undefined_,
    next_fn: Value = Value.undefined_,
    payload: Value = Value.undefined_,
    active: Value = Value.undefined_,
    kind: HelperKind = .map,
    count: u32 = 0,
    idx: u32 = 0,
    done: bool = false,
    running: bool = false,
    started: bool = false,
    keyed: bool = false,
    mode: u8 = 0,
    /// §27.1.4.2 Iterator.concat — the validated input records.
    /// `.empty` for every other iterator helper.
    concat_inputs: std.ArrayListUnmanaged(ConcatInput) = .empty,
    /// §27.5.4 / §27.5.5 Iterator.zip / zipKeyed — the per-input
    /// records. `.empty` for every other iterator helper.
    zip_inputs: std.ArrayListUnmanaged(ZipInput) = .empty,

    pub fn deinit(self: *IteratorHelperState, allocator: std.mem.Allocator) void {
        self.concat_inputs.deinit(allocator);
        self.zip_inputs.deinit(allocator);
        allocator.destroy(self);
    }
};

/// §26.2.1.1 [[Cells]] storage for FinalizationRegistry.
/// `cleanup_callback` is the callable supplied at construction;
/// `cells` holds the live registrations. FinalizationRegistry is
/// genuinely weak: the major collector (`Heap.collectFull`) does
/// not strong-mark a cell's `target` / `unregister_token`; its
/// post-mark weak pass enqueues a `cleanupCallback(heldValue)`
/// host job and tombstones the cell for any target that did not
/// survive the trace. `cleanup_callback` and each cell's
/// `held_value` ARE strong-marked — they must survive to be used.
/// `register` appends; `unregister` (and cleanup) flips
/// `deleted = true` so an in-progress walk doesn't shift indices.
pub const FinalizationData = struct {
    cleanup_callback: Value = Value.undefined_,
    cells: std.ArrayListUnmanaged(FinalizationCell) = .empty,

    pub fn deinit(self: *FinalizationData, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
        allocator.destroy(self);
    }
};

/// §26.2.1.1 — one Cell record. `[[WeakRefTarget]]`,
/// `[[HeldValue]]`, `[[UnregisterToken]]` (per §26.2.1.1, the
/// last is `~empty~` when the call site omitted the token).
/// `has_token = false` corresponds to the `~empty~` sentinel.
pub const FinalizationCell = struct {
    target: Value,
    held_value: Value,
    unregister_token: Value = Value.undefined_,
    has_token: bool = false,
    /// Tombstoned by `unregister` and during cleanup; skipped on
    /// walk. Matches `MapEntry.deleted` shape so an iteration
    /// path concurrent with mutation doesn't reshuffle indices.
    deleted: bool = false,
};

/// Lazy side allocation for cold JSObject state. See the trailing
/// scaffolding-tests block in this file for the contract; the
/// short version is "things a plain `{a, b}` literal never reads
/// or writes." Subsequent commits migrate the cold fields here
/// one at a time. Anything the JIT will speculate on stays in the
/// hot JSObject prefix and MUST NOT move here — keep `shape`,
/// `slots`, `properties`, `elements`, `prototype` out of this
/// struct forever.
pub const JSObjectExtension = struct {
    /// §10.1.8 accessor descriptors — pairs of getter / setter
    /// functions installed via `Object.defineProperty` with a
    /// `{get, set}` descriptor. The vast majority of objects
    /// have zero accessors, so this map sits behind the extension
    /// pointer. The GC marker walks every accessor's getter /
    /// setter (which are heap pointers).
    accessors: std.StringArrayHashMapUnmanaged(Accessor) = .empty,
    /// §7.3.27 class private fields. Per-instance data slots
    /// installed by `init_private_field` from a class body's
    /// `#x = value` initializer. The map is keyed by the private
    /// name's mangled bytes (`#x` after lexing). Only class
    /// instances carry private state — plain object literals
    /// never.
    private_properties: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// §15.7 — names in `private_properties` whose [[Kind]] is
    /// "method" (§7.3.30 PrivateSet step 4). Set semantics, not a
    /// map: the function value itself lives in `private_properties`;
    /// this is the brand membership check. Writes to these names
    /// throw TypeError per spec.
    private_methods: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// §15.7 class private accessors — `get #x()` / `set #x(v)`
    /// pairs. Same shape as `accessors` above but keyed by the
    /// mangled private name and never visible via reflection.
    private_accessors: std.StringArrayHashMapUnmanaged(Accessor) = .empty,
    /// §15.2.1.16.3 ResolveExport chain — `export { X as Y } from
    /// "src"` re-exports. Populated only on a Module Namespace
    /// exotic; entries point back at the source namespace + the
    /// local key name. Plain objects never carry this.
    namespace_redirects: std.StringArrayHashMapUnmanaged(NamespaceRedirect) = .empty,
    /// §15.2.1.16.3 step 8 — keys whose `export *` chain resolves
    /// to two distinct (module, binding) pairs. Treated as absent
    /// by every reflection / lookup path. Module Namespace exotic
    /// only.
    ambiguous_namespace_keys: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// §24.1 — backing store for a Map instance (chained entry
    /// bucket with insertion-order iteration). Only `Map` /
    /// `WeakMap` instances populate this; plain objects never.
    /// `null` means "not a Map instance".
    map_data: ?*MapData = null,
    /// §24.2 — backing store for a Set instance. Only `Set` /
    /// `WeakSet` instances populate this. `null` means "not a Set
    /// instance".
    set_data: ?*SetData = null,
    /// WebAssembly host-object backings (`WebAssembly.{Module,Global,
    /// Table,Memory}`). Only those rare exotics populate them; the
    /// base `JSObject` no longer carries the four pointers (they were
    /// 32 bytes on every object — see `getWasmModule` etc.).
    wasm_module: ?*anyopaque = null,
    wasm_global: ?*anyopaque = null,
    wasm_table: ?*anyopaque = null,
    wasm_memory: ?*anyopaque = null,
    /// A `WebAssembly.Tag`'s backing record (its canonical `*TagType`)
    /// and a `WebAssembly.Exception`'s (tag identity + payload copy).
    /// Opaque, arena-owned.
    wasm_tag: ?*anyopaque = null,
    wasm_exception: ?*anyopaque = null,
    /// Cold per-kind state moved off the base `JSObject` (each cost
    /// 8-16 bytes on every object but is set by one rare kind):
    /// a Date's [[DateValue]], a boxed-primitive wrapper's payload,
    /// a Promise capability's record, a generator instance's engine
    /// state. The GC marks `boxed_primitive` / `capability_record` /
    /// `generator_ref` via the extension-marking block in `heap.zig`;
    /// `date_ms` holds no GC value.
    date_ms: ?f64 = null,
    boxed_primitive: ?Value = null,
    capability_record: ?*PromiseCapabilityRecord = null,
    generator_ref: ?*@import("generator.zig").JSGenerator = null,
    /// `Promise.prototype.finally` machinery — the captured callback,
    /// the threaded value, and the species constructor. Set only on
    /// the per-call finally bound-this objects (rare, cold). GC marks
    /// `finally_callback` / `finally_constructor` (functions) and
    /// `finally_value` (a Value) via the extension getters.
    finally_callback: ?*@import("function.zig").JSFunction = null,
    finally_value: Value = Value.undefined_,
    finally_constructor: ?*@import("function.zig").JSFunction = null,
    /// Class private-state machinery — instance-field / private-method
    /// initializer lists (borrowed slices owned by the class arena),
    /// the per-class-evaluation [[PrivateBrand]] prefix and its
    /// compile-time prefix. Set only on class prototype / instance
    /// objects (cold). GC marks the two init lists' `init_fn`s via
    /// the extension getters; the brand strings are realm-arena bytes.
    instance_field_inits: ?[]const FieldInit = null,
    private_method_inits: ?[]const FieldInit = null,
    private_brand: []const u8 = "",
    private_compile_prefix: []const u8 = "",
    // (`promise_waiters` + `promise_reactions` moved OUT of the
    // extension into `JSObject.promise_store` — a Promise touches
    // none of the extension's other cold fields, so they get a
    // dedicated lightweight node instead of the full extension.)
    /// §26.1.1 [[WeakRefTarget]] — the cell a `WeakRef` watches.
    /// Genuinely weak: the GC marker skips this slot on a full
    /// cycle and clears it post-mark for a dead referent. Defaults
    /// to `undefined` (no live target). Only WeakRef instances
    /// populate this; the read API still returns `undefined` for
    /// plain objects, just via the null-extension path.
    weak_ref_target: Value = Value.undefined_,
    /// §26.2.1 [[Cells]] — pending FinalizationRegistry cleanup
    /// entries. Only `new FinalizationRegistry(cb)` instances
    /// populate this. `null` everywhere else.
    finalization_cells: ?*FinalizationData = null,
    /// §25.1 ArrayBuffer raw byte storage. Only `new
    /// ArrayBuffer(n)` / `.transfer()` / `.slice()` instances
    /// populate this. Heap-allocated slice; freed in deinit.
    array_buffer: ?[]u8 = null,
    /// When true, `array_buffer` is a *borrowed* (externally-owned)
    /// view — `deinit` must not free it. Set for the ArrayBuffer that
    /// `WebAssembly.Memory.prototype.buffer` returns: its bytes live in
    /// the realm's wasm arena, not this realm's general allocator.
    array_buffer_external: bool = false,
    /// §25.2 SharedArrayBuffer backing store — a refcounted, non-GC
    /// block shared across agents. Present (and `array_buffer` null)
    /// on `SharedArrayBuffer` instances; `getArrayBuffer` returns the
    /// block's live slice. The object's `deinit` `release`s it (the
    /// block frees when its last cross-agent reference is gone).
    shared_block: ?*@import("shared_data_block.zig").SharedDataBlock = null,
    /// §25.1 [[ArrayBufferMaxByteLength]] — resizable buffer
    /// upper bound. `null` on fixed-length buffers.
    array_buffer_max_byte_length: ?usize = null,
    /// §23.2 [[ViewedArrayBuffer]] + element-kind metadata for
    /// TypedArray instances. Borrowed pointer to the underlying
    /// ArrayBuffer object's `array_buffer` slice.
    typed_view: ?TypedView = null,
    /// §25.3 DataView state — byte-offset / byte-length / endian
    /// hooks over the source ArrayBuffer.
    data_view: ?DataView = null,
    /// `[[StringData]]` (§22.1.3) — the string primitive a
    /// `String` wrapper boxes. Only `new String(v)` / `toObjectThis`
    /// boxing populates this; every plain object skips the
    /// extension alloc.
    boxed_string: ?*@import("string.zig").JSString = null,
    /// Opaque host-side pointer. Used by embedder code that
    /// needs to associate a `*Realm` (or similar) with a JS
    /// object — currently only the test262 harness, which
    /// stashes the child Realm pointer on the wrapper returned
    /// by `$262.createRealm()`. Not GC-traced; the harness keeps
    /// the child Realm rooted in `parent.child_realms` separately.
    host_data: ?*anyopaque = null,
    /// §3.8 — the realm a ShadowRealm INSTANCE was created in
    /// (`GetFunctionRealm(new_target)` at construct time). Cold:
    /// only ShadowRealm instances populate it, and they already
    /// allocate an extension for the child realm pointer in
    /// `host_data`, so co-locating here is free. Read via
    /// `JSObject.shadowRealmOwner` / set via
    /// `setShadowRealmOwner`. See the `is_shadow_realm` brand flag
    /// on the inline struct (kept inline — it packs into existing
    /// bool padding at zero footprint cost).
    shadow_realm_owner: ?*@import("realm.zig").Realm = null,
    /// ES2026 explicit-resource-management — `[[DisposableState]]`
    /// (§27.3.2 / §27.4.2). `null` means "not a DisposableStack /
    /// AsyncDisposableStack instance". The four enum variants
    /// encode BOTH the kind (sync vs async) and the lifecycle
    /// state — so `requireDisposableStack` rejects an
    /// AsyncDisposableStack receiver (and vice versa) on a
    /// single-value comparison, without a prototype-identity
    /// check that a user `Object.setPrototypeOf` could defeat.
    disposable_state: ?DisposableState = null,
    /// ES2026 explicit-resource-management — `[[DisposeCapability]]`
    /// (§9.5.3 AddDisposableResource). Disposable resource records
    /// appended in source order; iterated in REVERSE during
    /// `DisposeResources` so the most-recently-added resource is
    /// disposed first (LIFO, matches §9.5.4 DisposeResources step 2).
    /// Empty for non-stack objects.
    disposable_resources: std.ArrayListUnmanaged(DisposableResource) = .empty,
    /// ES2026 explicit-resource-management — `AsyncDisposableStack`
    /// disposal walk state (§27.4.3.4 + §9.5.4 with hint =
    /// async-dispose). Allocated when `.disposeAsync()` starts;
    /// retained until the chain settles the outer Promise. The
    /// snapshot keeps the resource records reachable from GC
    /// (the source `disposable_resources` is cleared at walk
    /// start so re-entry during disposal sees an empty source).
    /// `null` for sync DisposableStack / non-stack objects.
    async_dispose_walk: ?*AsyncDisposeWalk = null,
    /// Temporal proposal — the internal-slot record a plain
    /// Temporal value (`Temporal.Duration`, `Temporal.PlainTime`)
    /// carries. A tagged union over the plain Temporal types; the
    /// tag also serves as the §RequireInternalSlot brand check. No
    /// heap pointers inside, so the GC marker needs no mark edge —
    /// the side allocation is freed in `deinit` like `map_data`.
    /// `null` for every non-Temporal object.
    temporal_record: ?*@import("temporal.zig").TemporalRecord = null,

    pub fn deinit(self: *JSObjectExtension, allocator: std.mem.Allocator) void {
        self.accessors.deinit(allocator);
        self.private_properties.deinit(allocator);
        self.private_methods.deinit(allocator);
        self.private_accessors.deinit(allocator);
        self.namespace_redirects.deinit(allocator);
        self.ambiguous_namespace_keys.deinit(allocator);
        if (self.map_data) |m| m.deinit(allocator);
        if (self.set_data) |s| s.deinit(allocator);
        if (self.finalization_cells) |fc| fc.deinit(allocator);
        // §25.2 — a SharedArrayBuffer's bytes belong to the refcounted
        // shared block (not this realm's allocator); drop our reference
        // instead of freeing. A plain ArrayBuffer frees its own slice.
        if (self.shared_block) |blk| blk.release() else if (self.array_buffer) |ab| {
            if (!self.array_buffer_external) allocator.free(ab);
        }
        self.disposable_resources.deinit(allocator);
        if (self.async_dispose_walk) |w| w.deinit(allocator);
        if (self.temporal_record) |tr| {
            tr.deinit(allocator);
            allocator.destroy(tr);
        }
    }
};

/// Iterator yielded by `JSObject.iterOwnNamedKeys`. Mirrors the
/// `Entry` shape of `std.StringArrayHashMapUnmanaged(Value).Iterator`
/// — `entry.key_ptr.*` / `entry.value_ptr.*` work identically — so
/// existing call sites pick up shape-mode enumeration with no edit.
/// Two modes:
///   `.bag`   — dictionary-mode object, walks the bag iterator.
///   `.order` — shape-mode object (bag empty), walks
///              `own_key_order` and resolves each value through
///              the shape's slot.
pub const OwnNamedEntry = struct {
    key_ptr: *const []const u8,
    value_ptr: *const Value,
};

pub const OwnNamedIterator = struct {
    mode: union(enum) {
        bag: std.StringArrayHashMapUnmanaged(Value).Iterator,
        shape: ShapeWalker,
    },

    pub const ShapeWalker = struct {
        obj: *const JSObject,
        /// Walks the transition chain leaf → root, but yields in
        /// insertion order (root → leaf) by recursing first when
        /// the caller's `next` strategy demands ordering. Stored
        /// as the leaf shape; we walk from `obj.shape` upward and
        /// emit slot-by-slot using the visit cursor below.
        leaf: *const @import("shape.zig").Shape,
        /// Visit cursor — the slot index we last returned. Walks
        /// from `0` up to `leaf.property_count - 1`. For each, we
        /// look up the corresponding key/attrs by walking the
        /// chain. O(depth) per step ⇒ O(depth²) total, but the
        /// chain depth is bounded by the object's named-property
        /// count (typically small).
        next_slot: u32 = 0,
        /// Backing storage for the entry pointers returned from
        /// `next` — the walker owns the key slice and value
        /// snapshot it just yielded so callers can deref the
        /// entry pointers without worrying about lifetime.
        cur_key: []const u8 = "",
        cur_value: Value = Value.undefined_,
    };

    pub fn next(self: *OwnNamedIterator) ?OwnNamedEntry {
        switch (self.mode) {
            .bag => |*it| {
                if (it.next()) |e| return .{ .key_ptr = e.key_ptr, .value_ptr = e.value_ptr };
                return null;
            },
            .shape => |*walk| {
                const property_count = walk.leaf.property_count;
                while (walk.next_slot < property_count) {
                    const want_slot = walk.next_slot;
                    walk.next_slot += 1;
                    // Walk the chain to find the node that owns
                    // `want_slot`. Append-only shapes have stable
                    // slot indices: the node that added the key
                    // also has `slot == want_slot`.
                    var node: ?*const @import("shape.zig").Shape = walk.leaf;
                    var found: ?*const @import("shape.zig").Shape = null;
                    while (node) |n| : (node = n.parent) {
                        if (n.parent == null) break;
                        if (n.slot == want_slot and n.kind == .data) {
                            found = n;
                            break;
                        }
                    }
                    const entry = found orelse continue;
                    if (entry.slot >= walk.obj.slotCount()) continue;
                    walk.cur_key = entry.key;
                    walk.cur_value = walk.obj.slotAt(entry.slot);
                    return .{ .key_ptr = &walk.cur_key, .value_ptr = &walk.cur_value };
                }
                return null;
            },
        }
    }
};

/// Number of shape-mode property values stored inline in the
/// `JSObject` header before spilling to a heap buffer. Covers the
/// common small object (2-4 props: `{a, b}`, `{x, y, z}`, RGBA) so
/// it pays no per-object value-buffer allocation. Each slot is a
/// `Value` (8 bytes); 4 adds 32 bytes to the header, which the slab
/// pool absorbs and which is recouped the moment the object would
/// otherwise have `malloc`'d a slots buffer.
pub const inline_slot_cap: u32 = 4;

pub const JSObject = struct {
    /// Discriminator — must remain the first field. Mirrors the
    /// `kind` field on `JSFunction` so runtime dispatch on a
    /// `Value` carrying the `Object` tag can read the first
    /// byte to decide which heap type it points to.
    kind: HeapKind = .object,
    /// Property name → value map. Names are owned by the heap's
    /// strings list (interned through allocation, not deduplicated
    /// later). Lookups are O(1) on the hash.
    properties: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// Parallel map of non-default property flags (§6.2.5
    /// PropertyDescriptor). Lazy: only properties that diverge
    /// from `PropertyFlags.default` (all-true) have an entry.
    /// Built-in proto methods (`Array.prototype.push`, etc.)
    /// install with `enumerable: false`; user-level
    /// `Object.defineProperty` populates here too.
    property_flags: std.StringArrayHashMapUnmanaged(PropertyFlags) = .empty,
    /// §10.1 shape-based named-property storage — not yet the
    /// source of truth. `shape` describes this object's named-
    /// property layout (see `shape.zig`); `slots[shape.lookup(key)
    /// .slot]` holds each value. `get` / `set` are not yet routed
    /// here, so `shape == null` on every object and property
    /// access stays on `properties` / `property_flags` (the
    /// dictionary representation). Routing access over and
    /// retiring those two maps is the remaining work.
    shape: ?*@import("shape.zig").Shape = null,
    /// Shape-mode property values, split for allocation speed (V8
    /// "in-object properties" / JSC inline storage). The first
    /// `inline_slot_cap` values live INLINE in the header — the
    /// overwhelmingly common small object (`{a, b}`, a `Point`,
    /// RGBA) stores every value here and pays NO separate
    /// allocation, since the header itself comes from the slab
    /// pool. Only objects that grow past the inline capacity spill
    /// the remainder into `overflow_slots` (a heap buffer holding
    /// logical slots `[inline_slot_cap ..]`). `slot_count` is the
    /// total live count across both. Access ONLY through
    /// `slotAt` / `slotPtr` / `setSlot` / `slotCount` /
    /// `resizeSlots` / `clearSlots` — never the raw fields — so the
    /// inline/overflow split stays an implementation detail.
    /// Non-moving: inline slots live in the (pinned-address) header,
    /// so the engine's pointer-stability invariant is preserved.
    inline_slots: [inline_slot_cap]Value = undefined,
    slot_count: u32 = 0,
    overflow_slots: std.ArrayListUnmanaged(Value) = .empty,
    /// Back-pointer to the owning heap, stamped at allocation by
    /// `Heap.allocateObject`. Lets the realm-agnostic `get` / `set`
    /// API reach the agent-wide property-shape tree (`heap.shapes`)
    /// without threading a realm or heap argument through every
    /// call site. `null` only on an object built outside
    /// `allocateObject` (none today).
    heap: ?*@import("heap.zig").Heap = null,
    // (`private_properties`, `private_methods`, `private_accessors`
    // moved to `JSObjectExtension` — class private state is rare on
    // a typical instance. Access through `hasPrivateProperty` /
    // `getPrivateProperty` / `getOrPutPrivateProperty` /
    // `removePrivateProperty` / `privatePropertyIterator` and the
    // matching `*PrivateMethod` / `*PrivateAccessor` helpers below.)
    // (`accessors` field moved to `JSObjectExtension.accessors` —
    // access via the `hasAccessor` / `getAccessor` /
    // `getOrPutAccessor` / `removeAccessor` / `accessorIterator`
    // helpers near the bottom of this struct.)
    // Class private-state machinery (`instance_field_inits`,
    // `private_method_inits`, `private_brand`, `private_compile_prefix`)
    // moved to `JSObjectExtension` — set only on class prototype /
    // instance objects. Access via `getInstanceFieldInits` /
    // `getPrivateMethodInits` / `getPrivateBrand` /
    // `getPrivateCompilePrefix` and their `set*` counterparts.
    /// Prototype object for prototype-chain lookups. later
    /// resolves member access through `[[Get]]` (§10.1.8) which
    /// walks this chain when the own property is absent.
    prototype: ?*JSObject = null,
    /// Function-valued `[[Prototype]]` link (§10.2 — functions are
    /// objects and can sit in a prototype chain: `Object.create(f)`,
    /// `F.prototype = someFunction`). `JSFunction` is a distinct heap
    /// type, so it needs this parallel slot — exactly one of
    /// `prototype` / `prototype_fn` is non-null. The walk hops into
    /// the function's own properties and continues through its
    /// `proto` (`%Function.prototype%`) chain. Mirrors the
    /// `static_parent` pattern on `JSFunction`.
    prototype_fn: ?*@import("function.zig").JSFunction = null,
    /// Mark color. `obj.mark_color == heap.live_color` means "live
    /// this cycle". The mark phase sets it to `heap.live_color`; the
    /// sweep keeps survivors and frees mismatches. No explicit clear
    /// — the cycle-start `live_color` flip ages every entry to the
    /// "unmarked" colour automatically.
    mark_color: u1 = 0,
    /// Generational-GC age. Fresh allocations start `.young`; a
    /// young object surviving a `collectYoung` is promoted to
    /// `.mature` and relinked into the mature list (the object
    /// itself never moves — the collector is non-moving).
    generation: @import("heap.zig").Generation = .young,
    /// Set when this object is a known mature→young store source —
    /// it is in the heap's dirty-container list, scanned as a root
    /// by the next minor cycle. Guards the write-barrier hot path
    /// against double-insertion. Edge-class-agnostic: any store of a
    /// young heap value into any property / element / slot of this
    /// object (while it is mature) sets it.
    dirty: bool = false,
    /// `[[Extensible]]` (§10.1.2). `false` after
    /// `Object.preventExtensions` / `seal` / `freeze`. New
    /// property writes silently fail when `false`.
    extensible: bool = true,
    /// Boxed primitive — set on objects produced by
    /// `new Number(v)`, `new String(v)`, `new Boolean(v)`.
    // `boxed_primitive` (`[[NumberData]]`/`[[StringData]]`/
    // `[[BooleanData]]`) moved to `JSObjectExtension` — only boxed
    // wrappers carry it. Access via `getBoxedPrimitive` /
    // `setBoxedPrimitive`.
    // (`map_data`, `set_data` moved to `JSObjectExtension` — only
    // Map/Set/WeakMap/WeakSet instances populate them. Access via
    // `getMapData` / `setMapData` / `getSetData` / `setSetData`
    // helpers below.)
    /// Array-like iterator state — present on the synthetic
    /// iterator objects produced by the §7.4.1 fallback path
    /// (`openIterator`) and the `Map` / `Set` `fromIterable`
    /// helper. `null` for every other object. Hidden from JS;
    /// mirrors the spec's [[IteratedObject]] + [[NextIndex]]
    /// internal slots.
    array_like_iter: ?*ArrayLikeIterState = null,
    /// Map / Set iterator state — present on the objects returned
    /// by `Map.prototype.{entries,keys,values}` /
    /// `Set.prototype.{entries,values}` and the respective
    /// `@@iterator`. `null` for every other object.
    map_set_iter: ?*MapSetIterState = null,
    /// RegExp String Iterator state — present on the object
    /// returned by `String.prototype.matchAll` /
    /// `RegExp.prototype[@@matchAll]`. `null` for every other
    /// object.
    regexp_string_iter: ?*RegExpStringIterState = null,
    /// §7.4.1 Iterator Record — lazily attached by `iter_step` to
    /// whatever object is being iterated (a destructuring /
    /// for-of source). Caches `[[NextMethod]]` and `[[Done]]` off
    /// the property bag. `null` until first stepped.
    iter_record: ?*IterRecord = null,
    /// `Iterator.prototype.*` helper state — present on the
    /// lazy wrapper objects produced by `Iterator.from`, `.map`,
    /// `.filter`, `.take`, `.drop`, `.flatMap`, and `Iterator.zip`.
    /// Hidden from JS; mirrors §27.1.5's IteratorRecord internal
    /// state.
    iter_helper: ?*IteratorHelperState = null,
    // `capability_record` (§27.2.1.5 PromiseCapability state) moved to
    // `JSObjectExtension` — set only on the transient capability
    // bound-this. Access via `getCapabilityRecord` / `setCapabilityRecord`.
    // `WebAssembly.{Module,Global,Table,Memory,Tag,Exception}` host
    // backings moved to `JSObjectExtension` — only those rare exotics
    // carry them, so they no longer cost 32 bytes on every object. Access
    // via the `getWasm*` / `setWasm*` helpers below.
    // `Promise.prototype.finally` machinery (`finally_callback`,
    // `finally_value`, `finally_constructor`) moved to
    // `JSObjectExtension` — set only on the per-`.finally()` context
    // objects. Access via `getFinally*` / `setFinally*`.
    // `date_ms` (§21.4.1 `[[DateValue]]`) and `generator_ref` (the
    // backing `JSGenerator` for a `function*` result) moved to
    // `JSObjectExtension` — Date / generator instances only. Access
    // via `getDateMs`/`setDateMs` and `getGeneratorRef`/`setGeneratorRef`.
    // (`array_buffer`, `array_buffer_max_byte_length`, `typed_view`,
    // `data_view` moved to `JSObjectExtension` — only TypedArray /
    // ArrayBuffer / DataView instances populate them. Access via
    // `getArrayBuffer` / `setArrayBuffer` /
    // `getArrayBufferMaxByteLength` / `setArrayBufferMaxByteLength`
    // / `getTypedView` / `setTypedView` / `getDataView` /
    // `setDataView` helpers below. `has_array_buffer_data` (brand
    // bool) stays on JSObject — flat byte-aligned with the other
    // brand flags and used in every typed-array hot path.)
    /// `[[ArrayBufferData]]` brand presence (§25.1.5.x
    /// RequireInternalSlot). True iff the object was produced by
    /// the ArrayBuffer constructor (or `.transfer` / `.slice`).
    /// `getArrayBuffer() == null && has_array_buffer_data == true`
    /// is the detached state. Plain objects keep the default `false`
    /// so the prototype-method brand checks `TypeError` correctly.
    has_array_buffer_data: bool = false,
    /// §25.2 — true iff the byte data block belongs to a
    /// `SharedArrayBuffer` (vs a plain `ArrayBuffer`). Both carry
    /// `[[ArrayBufferData]]` (`has_array_buffer_data`), so this flag
    /// is the `IsSharedArrayBuffer(O)` discriminator: it drives the
    /// §25.1.5.x "If IsSharedArrayBuffer(O) throw TypeError" guards on
    /// `ArrayBuffer.prototype.*`, and the brand checks on
    /// `SharedArrayBuffer.prototype.*`. A shared buffer never detaches
    /// and is grow-only. Flat alongside the brand for the hot path.
    array_buffer_shared: bool = false,
    // (`boxed_string` moved to `JSObjectExtension` — only
    // `new String(v)` / String-wrapper boxing populates it.
    // Access via `getBoxedString` / `setBoxedString` helpers.)
    // (`host_data` moved to `JSObjectExtension` — only the test262
    // harness uses it. Access via `getHostData` / `setHostData`.)
    /// §27.2 Promise reaction + waiter lists, in a dedicated
    /// lazily-allocated node reached by this single inline pointer.
    /// Kept OUT of `JSObjectExtension`: a pending Promise in a
    /// `.then` chain populates only these two lists and would
    /// otherwise allocate the full ~500-byte extension just to hold
    /// them (the dominant per-Promise heap cost on long chains).
    /// `null` on every non-Promise and on a Promise that has never
    /// queued a reaction or waiter. Access via the `promiseWaiters*`
    /// / `promiseReactions*` helpers below — never the field.
    promise_store: ?*PromiseReactionStore = null,
    /// §27.2.6 `[[PromiseState]]`. `.none` means this object isn't
    /// a Promise; the runtime brand-checks for `!= .none` rather
    /// than walking the prototype chain. Hidden from JS — never
    /// surfaces in `Object.keys` / `in` / property reads.
    promise_state: PromiseState = .none,
    /// §27.2.6 `[[PromiseResult]]`. Read only when
    /// `promise_state` is fulfilled or rejected; pending Promises
    /// leave it at `undefined_`.
    promise_value: Value = Value.undefined_,
    /// §27.2.1.3 alreadyResolved closure flag — set true on the
    /// first invocation of either the resolve or reject function
    /// for this Promise. Subsequent invocations no-op, and the
    /// Promise constructor's executor-threw fallback (§27.2.3.1
    /// step 10) consults this flag to avoid double-settlement when
    /// the executor already called resolve(thenable) (which leaves
    /// the Promise pending until the thenable job runs).
    promise_already_resolved: bool = false,
    /// §22.2.4 `[[OriginalSource]]` — the source string a RegExp
    /// instance was constructed from (the part between the
    /// slashes in `/abc/i`). Hidden from JS; user-visible via
    /// the `RegExp.prototype.source` accessor.
    regexp_source: ?*@import("string.zig").JSString = null,
    /// §22.2.4 `[[OriginalFlags]]` — the flag string ("gim", "u",
    /// etc.) the instance carries. Hidden from JS; user-visible
    /// via the `RegExp.prototype.flags` accessor.
    regexp_flags: ?*@import("string.zig").JSString = null,
    /// §10.5 Proxy exotic — `[[ProxyTarget]]` / `[[ProxyHandler]]`
    /// internal slots when this object was constructed via
    /// `new Proxy(target, handler)`. `null` for plain objects.
    /// The interpreter's property opcodes detect this slot and
    /// route through the handler's traps (`get`, `set`, `has`,
    /// `deleteProperty`) before falling back to the target.
    proxy_target: ?*JSObject = null,
    proxy_handler: ?*JSObject = null,
    /// For `new Proxy(fn, handler)` where the target is a
    /// function — Cynic's JSFunction lives in a different tag
    /// from JSObject so the proxy slot above can't hold it. The
    /// call/new opcodes check this slot to make the proxy
    /// itself callable.
    proxy_target_fn: ?*@import("function.zig").JSFunction = null,
    /// §28.2.2.1 Proxy.revocable — a revoked proxy reports as
    /// revoked once `revoke()` clears its `[[ProxyTarget]]` /
    /// `[[ProxyHandler]]`. Every internal method on a revoked
    /// proxy throws TypeError per §10.5.x step 1.
    proxy_revoked: bool = false,
    /// Callable-exotic flag on a plain JSObject. Set in two places:
    /// (a) §10.5 ProxyCreate — when the original target was callable,
    /// `[[Call]]` is exposed on the proxy regardless of whether
    /// `proxy_target_fn` is currently set. After revocation the
    /// `proxy_target_fn` slot is null, but `typeof` and re-wraps
    /// still need to know the proxy is "callable".
    /// (b) §20.2.3 — %Function.prototype% is itself a built-in
    /// function object that returns undefined when called; the JS-
    /// observable shape is "an object whose typeof is function",
    /// which rides this same flag (since Cynic represents
    /// `Function.prototype` as a JSObject, not a JSFunction).
    proxy_callable: bool = false,
    /// §22.2.7 RegExp instance — the compiled Perlex (native engine)
    /// program for this RegExp's [[RegExpMatcher]]. The first call to
    /// `.exec`/`.test` parses the `source` + `flags` and caches the
    /// program here. Allocated against the realm allocator and freed in
    /// `deinitFields` (it holds no GC references, so the collector
    /// doesn't trace it). Perlex is the sole regex engine.
    regex_perlex: ?*@import("../perlex/perlex.zig").Program = null,
    // (`finalization_cells` + `weak_ref_target` moved to
    // `JSObjectExtension` — only `FinalizationRegistry` /
    // `WeakRef` instances populate them. Access via
    // `getFinalizationCells` / `setFinalizationCells` /
    // `getWeakRefTarget` / `setWeakRefTarget` below.)
    /// §26.1 WeakRef brand — `(deref.call(plainObj))` must throw
    /// a TypeError per §26.1.3.2 even when the slot is empty, so
    /// the brand is checked separately from the target slot.
    is_weak_ref: bool = false,
    /// §3.8 ShadowRealm brand — the prototype methods walk this
    /// flag (and the `host_data` slot which carries the child
    /// `*Realm` pointer) to identify a ShadowRealm receiver and
    /// reject mismatched `this` values per §3.8.3.1 step 2 /
    /// §3.8.3.2 step 2 (`RequireInternalSlot(O, [[ShadowRealm]])`
    /// throws TypeError on any non-ShadowRealm receiver — like
    /// `evaluate.call({}, "1")`).
    is_shadow_realm: bool = false,
    /// §10.4.2 Array exotic — packed indexed elements storage.
    /// Array instances set `is_array_exotic = true` and use
    /// `elements` as the source of truth for integer-indexed
    /// reads / writes (§7.1.21 canonical array-index range
    /// `[0, 2^32 - 2]`). Holes (sparse arrays) are represented as
    /// `Value.undefined_` slots; the spec-faithful "hole bit" is
    /// later (lookups via `hasOwnIndexed` currently treat any
    /// in-bounds slot as an own property — correct for dense
    /// arrays, off for sparse ones). String-keyed numeric writes
    /// like `arr["3"] = v` route into this vector via the
    /// canonical-integer-index dispatch in `set` / `get` / etc.,
    /// so user code never needs to think about it.
    ///
    /// `length` (§23.1.4) is a VIRTUAL own property: synthesized
    /// from `arrayLength()` (the indexed-storage size) plus the
    /// `array_length_writable` bit below at every consult point
    /// (`get` / `hasOwn` / `flagsFor` / key enumeration) — never
    /// materialized in `properties`. This kills the per-element
    /// `length` hashmap sync and the per-array bag allocation the
    /// materialized form paid on every array literal, and makes
    /// `a.length` reads O(1) with no hashing.
    /// `Object.getOwnPropertyDescriptor(arr, "length")` still
    /// returns the §23.1.4 data descriptor.
    is_array_exotic: bool = false,
    /// §10.4.2 `length`.[[Writable]] for an array exotic — cleared
    /// by `Object.defineProperty(arr, "length", {writable:false})`
    /// (and `Object.freeze`); §10.4.2.4 step 17.b gates length
    /// writes and §10.4.2.1 step 2 gates the implicit grow on
    /// index-past-end writes against it. [[Enumerable]] /
    /// [[Configurable]] are constant `false` per §23.1.4, so one
    /// bit carries the whole mutable descriptor state.
    array_length_writable: bool = true,
    /// §10.4.4 — Arguments exotic brand. `Object.prototype.toString`
    /// reads this to produce `"[object Arguments]"` per §22.1.3.6
    /// step 4 (the "Arguments" case keyed off the internal slot
    /// presence). Cynic's `lda_arguments` opcode sets this when it
    /// synthesises the strict-mode unmapped arguments object.
    is_arguments_exotic: bool = false,
    /// §25.5.4 `[[IsRawJSON]]` internal slot. Set on the frozen
    /// null-prototype objects produced by `JSON.rawJSON(text)`.
    /// `JSON.isRawJSON` brand-tests against it; `JSON.stringify`
    /// reads the `rawJSON` data property on a branded object and
    /// emits its bytes verbatim instead of re-serialising. The
    /// json-parse-with-source proposal (Stage 4 ES2025) covers this.
    is_raw_json: bool = false,
    /// §9.4.6 Module Namespace exotic object — set when this object
    /// is a Module Namespace produced by `import(spec)` / `import * as
    /// ns from "…"`. The flag flips on `[[Set]]` / `[[Delete]]` /
    /// `[[DefineOwnProperty]]` paths so user writes silently fail
    /// (always return `false`) per §9.4.6.4 / 9.4.6.7 / 9.4.6.8. The
    /// `extensible` slot is also flipped `false` and the `prototype`
    /// slot is cleared to `null` at finalisation; this flag is the
    /// brand that distinguishes "module namespace with `null`
    /// proto + non-extensible" from "user object frozen via
    /// `Object.preventExtensions(Object.create(null))`" which has
    /// different `[[Set]]` semantics (writes are silently dropped
    /// vs. always-`false`).
    is_module_namespace: bool = false,
    // (`namespace_redirects`, `ambiguous_namespace_keys` moved to
    // `JSObjectExtension` — only Module Namespace exotics populate
    // them. Access via the `namespaceRedirect*` /
    // `ambiguousNamespaceKey*` helpers below.)
    /// §20.5.1.1 [[ErrorData]] — set when this object is an Error
    /// (or NativeError) instance produced via `new <X>Error(...)`
    /// / `<X>Error(...)`. Object.prototype.toString uses this to
    /// emit `"[object Error]"`; AggregateError init also flips it.
    /// Plain `<X>Error.prototype` does NOT have this slot, which is
    /// what `built-ins/NativeErrors/<X>/prototype/not-error-object.js`
    /// asserts.
    has_error_data: bool = false,
    elements: std.ArrayListUnmanaged(Value) = .empty,
    /// §10.4.2 Array exotic — dictionary mode (V8-style). When a
    /// single indexed write would extend `elements` by more than
    /// `sparse_gap_threshold` slots (e.g. `arr[2**32 - 2] = v` on
    /// an empty array), demote to a `u32 → Value` map keyed by
    /// present indices. Absent keys are holes; `sparse_length`
    /// is the logical array length (mirrors `elements.items.len`
    /// in dense mode). Once sparse, stays sparse — no re-pack on
    /// shrink. Off by default; only Array exotics flip this.
    is_sparse: bool = false,
    sparse_elements: std.AutoHashMapUnmanaged(u32, Value) = .empty,
    sparse_length: u32 = 0,
    /// Heap-allocated JSStrings whose `bytes` slice backs a key
    /// in `properties` / `accessors` / `private_properties` /
    /// `property_flags`. The hash maps store `[]const u8` slices,
    /// not pointers — so without this anchor the JSString gets
    /// swept and the key slice dangles. Static-literal key strings
    /// (constants pool, builtin installation) don't need anchoring;
    /// only keys allocated for `obj[expr] = v` etc. via
    /// `setComputedOwned` land here.
    key_anchors: std.ArrayListUnmanaged(*@import("string.zig").JSString) = .empty,

    /// §10.1.11 OrdinaryOwnPropertyKeys — unified insertion-order
    /// list across `properties` and `accessors`, so an object that
    /// installs `a` as an accessor, then `b` as data, then
    /// redefines `a` reports `[a, b]` (not `[b, a]`). Each entry
    /// is a borrowed slice — the backing bytes are pinned by the
    /// matching `properties` / `accessors` entry (or by
    /// `key_anchors` when the key originated from
    /// `setComputedOwned`). Append-only on first insertion;
    /// removed when the key is deleted. Only mutated through the
    /// `recordKey` / `forgetKey` helpers below; the raw `put`
    /// callsites in object.zig / lantern.zig / builtins/object.zig
    /// route through them. Built-in proto installation that
    /// bypasses the helpers (e.g. realm wiring) doesn't land in
    /// this list; that's intentional — those keys are
    /// non-enumerable and don't surface through
    /// `Object.keys/values/entries` anyway, and the fallback in
    /// `ownPropertyKeysOrdered` covers them by walking
    /// `properties` + `accessors` directly when this list is
    /// empty.
    own_key_order: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Lazy side allocation for cold state — see `JSObjectExtension`
    /// above. `null` on every fresh JSObject; allocated on first
    /// `getOrCreateExtension` call. Owned by this JSObject; freed
    /// in `deinit`. Currently empty (scaffolding commit); fields
    /// migrate here one at a time in follow-up commits.
    extension: ?*JSObjectExtension = null,

    pub fn init(allocator: std.mem.Allocator) !*JSObject {
        const o = try allocator.create(JSObject);
        o.* = .{ .kind = .object };
        return o;
    }

    /// §10.1.11 OrdinaryOwnPropertyKeys — iterator over the
    /// object's own named-data properties in insertion order.
    /// Phase 3 of [docs/lazy-property-bag.md]: a shape-mode
    /// object's bag is empty, so the iterator walks
    /// `own_key_order` (populated by `recordKey`) and resolves
    /// each entry through the shape slot. Dictionary-mode
    /// objects walk the bag iterator directly — preserves
    /// deterministic insertion order for built-in installation
    /// paths that didn't `recordKey`.
    pub fn iterOwnNamedKeys(self: *const JSObject) OwnNamedIterator {
        if (self.shape) |sh| {
            return .{ .mode = .{ .shape = .{ .obj = self, .leaf = sh } } };
        }
        return .{ .mode = .{ .bag = self.properties.iterator() } };
    }

    /// §10.1.1 OrdinaryGetOwnProperty (data half) — return the
    /// own data property's value, or `null` if absent. Shape-
    /// first: `slots[shape.lookup(key).slot]` for a shape-mode
    /// data entry, otherwise `properties.get`. Accessors /
    /// proxy traps / proto chain are NOT consulted — callers
    /// that need the full §10.1.7 [[Get]] semantics route
    /// through `lda_property`'s helper stack (or
    /// `lookupAccessor` for the accessor half).
    pub fn lookupOwn(self: *const JSObject, key: []const u8) ?Value {
        // §23.1.4 — the array exotic's virtual `length`.
        if (self.isVirtualLengthKey(key)) return self.arrayLengthValue();
        if (self.shape) |sh| {
            if (sh.lookup(key)) |entry| {
                if (entry.kind == .data and entry.slot < self.slotCount()) {
                    return self.slotAt(entry.slot);
                }
            }
        }
        return self.properties.get(key);
    }

    /// §10.1.1 OrdinaryGetOwnProperty presence test (data half) —
    /// true iff the receiver holds an own DATA property at `key`.
    /// Shape-first: shape slot wins for shape-mode objects, bag
    /// fallback for dictionary mode. Does NOT consult accessors —
    /// pair with `hasAccessor(key)` for the full §7.3.13
    /// HasOwnProperty semantic, or call `hasOwn(key)` for the
    /// combined check. Replaces the direct `obj.properties.contains`
    /// callsites that were ambiguous about which representation
    /// is authoritative under [docs/lazy-property-bag.md].
    pub fn ownDataContains(self: *const JSObject, key: []const u8) bool {
        // §23.1.4 — the array exotic's virtual `length` is an own
        // data property.
        if (self.isVirtualLengthKey(key)) return true;
        if (self.shape) |sh| {
            if (sh.lookup(key)) |entry| {
                if (entry.kind == .data) return true;
            }
        }
        return self.properties.contains(key);
    }

    /// Number of own named DATA properties — shape's
    /// `property_count` when shape-mode, bag's `count()`
    /// otherwise. Doesn't include accessors.
    pub fn ownDataCount(self: *const JSObject) usize {
        if (self.shape) |sh| return sh.property_count;
        return self.properties.count();
    }

    /// Return the extension if already allocated, otherwise allocate
    /// a zero-init extension and stash it on this object. The
    /// caller mutates the returned pointer in place; subsequent
    /// calls return the same pointer.
    pub fn getOrCreateExtension(self: *JSObject, allocator: std.mem.Allocator) !*JSObjectExtension {
        if (self.extension) |ext| return ext;
        const ext = try allocator.create(JSObjectExtension);
        ext.* = .{};
        self.extension = ext;
        return ext;
    }

    // ── §10.1.8 accessor descriptors — extension-backed cold map ─
    //
    // Most objects have zero accessors; the map sits behind
    // `extension.accessors`. The helpers below give every reader
    // a cheap "is there an extension at all?" guard so plain
    // `{a, b}` literals pay nothing for the migration.

    // ── WebAssembly host backings — extension-backed cold pointers ─
    //
    // Only `WebAssembly.{Module,Global,Table,Memory}` exotics carry
    // these; a plain object/array has no extension and reads `null`
    // for free. Setters lazily allocate the extension. The records are
    // realm-arena-owned opaque pointers (no GC marking / cleanup).
    pub fn getWasmModule(self: *const JSObject) ?*anyopaque {
        return if (self.extension) |ext| ext.wasm_module else null;
    }
    pub fn getWasmGlobal(self: *const JSObject) ?*anyopaque {
        return if (self.extension) |ext| ext.wasm_global else null;
    }
    pub fn getWasmTable(self: *const JSObject) ?*anyopaque {
        return if (self.extension) |ext| ext.wasm_table else null;
    }
    pub fn getWasmMemory(self: *const JSObject) ?*anyopaque {
        return if (self.extension) |ext| ext.wasm_memory else null;
    }
    pub fn setWasmModule(self: *JSObject, allocator: std.mem.Allocator, v: ?*anyopaque) !void {
        (try self.getOrCreateExtension(allocator)).wasm_module = v;
    }
    pub fn setWasmGlobal(self: *JSObject, allocator: std.mem.Allocator, v: ?*anyopaque) !void {
        (try self.getOrCreateExtension(allocator)).wasm_global = v;
    }
    pub fn setWasmTable(self: *JSObject, allocator: std.mem.Allocator, v: ?*anyopaque) !void {
        (try self.getOrCreateExtension(allocator)).wasm_table = v;
    }
    pub fn setWasmMemory(self: *JSObject, allocator: std.mem.Allocator, v: ?*anyopaque) !void {
        (try self.getOrCreateExtension(allocator)).wasm_memory = v;
    }
    pub fn getWasmTag(self: *const JSObject) ?*anyopaque {
        return if (self.extension) |ext| ext.wasm_tag else null;
    }
    pub fn setWasmTag(self: *JSObject, allocator: std.mem.Allocator, v: ?*anyopaque) !void {
        (try self.getOrCreateExtension(allocator)).wasm_tag = v;
    }
    pub fn getWasmException(self: *const JSObject) ?*anyopaque {
        return if (self.extension) |ext| ext.wasm_exception else null;
    }
    pub fn setWasmException(self: *JSObject, allocator: std.mem.Allocator, v: ?*anyopaque) !void {
        (try self.getOrCreateExtension(allocator)).wasm_exception = v;
    }

    // ── Cold per-kind state — extension-backed (see migration note) ─
    pub fn getDateMs(self: *const JSObject) ?f64 {
        return if (self.extension) |ext| ext.date_ms else null;
    }
    pub fn setDateMs(self: *JSObject, allocator: std.mem.Allocator, v: ?f64) !void {
        (try self.getOrCreateExtension(allocator)).date_ms = v;
    }
    pub fn getBoxedPrimitive(self: *const JSObject) ?Value {
        return if (self.extension) |ext| ext.boxed_primitive else null;
    }
    pub fn setBoxedPrimitive(self: *JSObject, allocator: std.mem.Allocator, v: ?Value) !void {
        (try self.getOrCreateExtension(allocator)).boxed_primitive = v;
    }
    pub fn getCapabilityRecord(self: *const JSObject) ?*PromiseCapabilityRecord {
        return if (self.extension) |ext| ext.capability_record else null;
    }
    pub fn setCapabilityRecord(self: *JSObject, allocator: std.mem.Allocator, v: ?*PromiseCapabilityRecord) !void {
        (try self.getOrCreateExtension(allocator)).capability_record = v;
    }
    pub fn getGeneratorRef(self: *const JSObject) ?*@import("generator.zig").JSGenerator {
        return if (self.extension) |ext| ext.generator_ref else null;
    }
    pub fn setGeneratorRef(self: *JSObject, allocator: std.mem.Allocator, v: ?*@import("generator.zig").JSGenerator) !void {
        (try self.getOrCreateExtension(allocator)).generator_ref = v;
    }
    pub fn getFinallyCallback(self: *const JSObject) ?*@import("function.zig").JSFunction {
        return if (self.extension) |ext| ext.finally_callback else null;
    }
    pub fn setFinallyCallback(self: *JSObject, allocator: std.mem.Allocator, v: ?*@import("function.zig").JSFunction) !void {
        (try self.getOrCreateExtension(allocator)).finally_callback = v;
    }
    pub fn getFinallyValue(self: *const JSObject) Value {
        return if (self.extension) |ext| ext.finally_value else Value.undefined_;
    }
    pub fn setFinallyValue(self: *JSObject, allocator: std.mem.Allocator, v: Value) !void {
        (try self.getOrCreateExtension(allocator)).finally_value = v;
    }
    pub fn getFinallyConstructor(self: *const JSObject) ?*@import("function.zig").JSFunction {
        return if (self.extension) |ext| ext.finally_constructor else null;
    }
    pub fn setFinallyConstructor(self: *JSObject, allocator: std.mem.Allocator, v: ?*@import("function.zig").JSFunction) !void {
        (try self.getOrCreateExtension(allocator)).finally_constructor = v;
    }
    pub fn getInstanceFieldInits(self: *const JSObject) ?[]const FieldInit {
        return if (self.extension) |ext| ext.instance_field_inits else null;
    }
    pub fn setInstanceFieldInits(self: *JSObject, allocator: std.mem.Allocator, v: ?[]const FieldInit) !void {
        (try self.getOrCreateExtension(allocator)).instance_field_inits = v;
    }
    pub fn getPrivateMethodInits(self: *const JSObject) ?[]const FieldInit {
        return if (self.extension) |ext| ext.private_method_inits else null;
    }
    pub fn setPrivateMethodInits(self: *JSObject, allocator: std.mem.Allocator, v: ?[]const FieldInit) !void {
        (try self.getOrCreateExtension(allocator)).private_method_inits = v;
    }
    pub fn getPrivateBrand(self: *const JSObject) []const u8 {
        return if (self.extension) |ext| ext.private_brand else "";
    }
    pub fn setPrivateBrand(self: *JSObject, allocator: std.mem.Allocator, v: []const u8) !void {
        (try self.getOrCreateExtension(allocator)).private_brand = v;
    }
    pub fn getPrivateCompilePrefix(self: *const JSObject) []const u8 {
        return if (self.extension) |ext| ext.private_compile_prefix else "";
    }
    pub fn setPrivateCompilePrefix(self: *JSObject, allocator: std.mem.Allocator, v: []const u8) !void {
        (try self.getOrCreateExtension(allocator)).private_compile_prefix = v;
    }

    pub fn hasAccessor(self: *const JSObject, key: []const u8) bool {
        if (self.extension) |ext| return ext.accessors.contains(key);
        return false;
    }

    pub fn getAccessor(self: *const JSObject, key: []const u8) ?Accessor {
        if (self.extension) |ext| return ext.accessors.get(key);
        return null;
    }

    /// `Map.GetOrPutResult` thin wrapper — lazy-allocates the
    /// extension on the first put.
    pub fn getOrPutAccessor(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !std.StringArrayHashMapUnmanaged(Accessor).GetOrPutResult {
        const ext = try self.getOrCreateExtension(allocator);
        // A setter installed at this key invalidates any transition
        // write IC whose receiver inherits from `self`.
        if (self.heap) |h| h.bumpProtoStructEpoch();
        return ext.accessors.getOrPut(allocator, key);
    }

    /// Returns true if the key was present and removed.
    pub fn removeAccessor(self: *JSObject, key: []const u8) bool {
        if (self.extension) |ext| {
            const removed = ext.accessors.swapRemove(key);
            // Removing an accessor can re-expose an ancestor's setter.
            if (removed) {
                if (self.heap) |h| h.bumpProtoStructEpoch();
            }
            return removed;
        }
        return false;
    }

    /// Iterator over the accessor map, or `null` when the object
    /// has no extension (and therefore no accessors). Caller
    /// receives an owned iterator value — `while (it.next()) |e|`
    /// works the same as the underlying `Map.iterator()`.
    pub fn accessorIterator(self: *const JSObject) ?std.StringArrayHashMapUnmanaged(Accessor).Iterator {
        if (self.extension) |ext| return ext.accessors.iterator();
        return null;
    }

    /// Count of installed accessors. `0` when there is no extension.
    /// Cheaper than walking `accessorIterator` for size checks.
    pub fn accessorCount(self: *const JSObject) usize {
        if (self.extension) |ext| return ext.accessors.count();
        return 0;
    }

    // ── §7.3.27 class private slots — extension-backed cold maps ─
    //
    // Class instances with `#field` / `get #x()` etc. install state
    // here. Plain object literals never touch these maps. Three
    // parallel families (data / method-brand / accessor) mirror
    // the accessor pattern above.

    pub fn hasPrivateProperty(self: *const JSObject, key: []const u8) bool {
        if (self.extension) |ext| return ext.private_properties.contains(key);
        return false;
    }

    pub fn getPrivateProperty(self: *const JSObject, key: []const u8) ?Value {
        if (self.extension) |ext| return ext.private_properties.get(key);
        return null;
    }

    pub fn putPrivateProperty(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
    ) !void {
        const ext = try self.getOrCreateExtension(allocator);
        try ext.private_properties.put(allocator, key, v);
    }

    pub fn getOrPutPrivateProperty(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !std.StringArrayHashMapUnmanaged(Value).GetOrPutResult {
        const ext = try self.getOrCreateExtension(allocator);
        return ext.private_properties.getOrPut(allocator, key);
    }

    pub fn removePrivateProperty(self: *JSObject, key: []const u8) bool {
        if (self.extension) |ext| return ext.private_properties.swapRemove(key);
        return false;
    }

    pub fn privatePropertyIterator(self: *const JSObject) ?std.StringArrayHashMapUnmanaged(Value).Iterator {
        if (self.extension) |ext| return ext.private_properties.iterator();
        return null;
    }

    pub fn hasPrivateMethod(self: *const JSObject, key: []const u8) bool {
        if (self.extension) |ext| return ext.private_methods.contains(key);
        return false;
    }

    pub fn putPrivateMethod(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !void {
        const ext = try self.getOrCreateExtension(allocator);
        try ext.private_methods.put(allocator, key, {});
    }

    pub fn hasPrivateAccessor(self: *const JSObject, key: []const u8) bool {
        if (self.extension) |ext| return ext.private_accessors.contains(key);
        return false;
    }

    pub fn getPrivateAccessor(self: *const JSObject, key: []const u8) ?Accessor {
        if (self.extension) |ext| return ext.private_accessors.get(key);
        return null;
    }

    pub fn getOrPutPrivateAccessor(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !std.StringArrayHashMapUnmanaged(Accessor).GetOrPutResult {
        const ext = try self.getOrCreateExtension(allocator);
        return ext.private_accessors.getOrPut(allocator, key);
    }

    pub fn privateAccessorIterator(self: *const JSObject) ?std.StringArrayHashMapUnmanaged(Accessor).Iterator {
        if (self.extension) |ext| return ext.private_accessors.iterator();
        return null;
    }

    // ── §15.2.1.16.3 Module Namespace exotic state ──────────────
    //
    // Only objects with `is_module_namespace == true` ever populate
    // these maps. Everything else returns "absent" cheaply via the
    // null-extension fast path.

    pub fn hasNamespaceRedirect(self: *const JSObject, key: []const u8) bool {
        if (self.extension) |ext| return ext.namespace_redirects.contains(key);
        return false;
    }

    pub fn getNamespaceRedirect(self: *const JSObject, key: []const u8) ?NamespaceRedirect {
        if (self.extension) |ext| return ext.namespace_redirects.get(key);
        return null;
    }

    pub fn putNamespaceRedirect(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        r: NamespaceRedirect,
    ) !void {
        const ext = try self.getOrCreateExtension(allocator);
        try ext.namespace_redirects.put(allocator, key, r);
    }

    pub fn removeNamespaceRedirect(self: *JSObject, key: []const u8) bool {
        if (self.extension) |ext| return ext.namespace_redirects.swapRemove(key);
        return false;
    }

    pub fn namespaceRedirectIterator(self: *const JSObject) ?std.StringArrayHashMapUnmanaged(NamespaceRedirect).Iterator {
        if (self.extension) |ext| return ext.namespace_redirects.iterator();
        return null;
    }

    pub fn hasAmbiguousNamespaceKey(self: *const JSObject, key: []const u8) bool {
        if (self.extension) |ext| return ext.ambiguous_namespace_keys.contains(key);
        return false;
    }

    pub fn putAmbiguousNamespaceKey(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !void {
        const ext = try self.getOrCreateExtension(allocator);
        try ext.ambiguous_namespace_keys.put(allocator, key, {});
    }

    pub fn ambiguousNamespaceKeyIterator(self: *const JSObject) ?std.StringArrayHashMapUnmanaged(void).Iterator {
        if (self.extension) |ext| return ext.ambiguous_namespace_keys.iterator();
        return null;
    }

    // ── §24 Map / Set / WeakMap / WeakSet backing store ─────────
    //
    // Each instance type carries a single pointer field on the
    // extension. Non-collection objects return null from the
    // getter without ever materialising the extension.

    pub fn getMapData(self: *const JSObject) ?*MapData {
        if (self.extension) |ext| return ext.map_data;
        return null;
    }

    pub fn setMapData(self: *JSObject, allocator: std.mem.Allocator, data: ?*MapData) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.map_data = data;
    }

    pub fn getSetData(self: *const JSObject) ?*SetData {
        if (self.extension) |ext| return ext.set_data;
        return null;
    }

    pub fn setSetData(self: *JSObject, allocator: std.mem.Allocator, data: ?*SetData) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.set_data = data;
    }

    // ── §27.2 Promise reaction queue + §26 WeakRef / FinReg ────
    //
    // Promise instances and WeakRef / FinalizationRegistry
    // instances carry their backing state here. Plain objects
    // pay the null-extension fast path.

    /// Lazily allocate (and cache) this Promise's reaction/waiter
    /// node. See `promise_store`. Distinct from `getOrCreateExtension`
    /// — a Promise pays only this ~small node, not the full extension.
    fn getOrCreatePromiseStore(self: *JSObject, allocator: std.mem.Allocator) !*PromiseReactionStore {
        if (self.promise_store) |s| return s;
        // Heap-stamped objects draw the node from the slab pool (an
        // O(1) free-list pop after warmup); the rare heap-less object
        // (unit-test construction) falls back to the raw allocator —
        // `deinitFields` mirrors the split on the destroy side.
        const s = if (self.heap) |h|
            try h.promise_store_pool.create(h.allocator)
        else
            try allocator.create(PromiseReactionStore);
        s.* = .{};
        self.promise_store = s;
        return s;
    }

    pub fn promiseWaitersPtr(self: *JSObject, allocator: std.mem.Allocator) !*std.ArrayListUnmanaged(*@import("generator.zig").JSGenerator) {
        const s = try self.getOrCreatePromiseStore(allocator);
        return &s.waiters;
    }

    pub fn promiseWaitersConst(self: *const JSObject) ?*const std.ArrayListUnmanaged(*@import("generator.zig").JSGenerator) {
        if (self.promise_store) |s| return &s.waiters;
        return null;
    }

    pub fn promiseReactionsPtr(self: *JSObject, allocator: std.mem.Allocator) !*std.ArrayListUnmanaged(PromiseReaction) {
        const s = try self.getOrCreatePromiseStore(allocator);
        return &s.reactions;
    }

    pub fn promiseReactionsConst(self: *const JSObject) ?*const std.ArrayListUnmanaged(PromiseReaction) {
        if (self.promise_store) |s| return &s.reactions;
        return null;
    }

    /// Returns `Value.undefined_` when no extension yet (read API
    /// preserves the original semantics — every plain object behaves
    /// like an empty WeakRef target slot, matching the old behaviour
    /// where the field defaulted to undefined).
    pub fn getWeakRefTarget(self: *const JSObject) Value {
        if (self.extension) |ext| return ext.weak_ref_target;
        return Value.undefined_;
    }

    pub fn setWeakRefTarget(self: *JSObject, allocator: std.mem.Allocator, v: Value) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.weak_ref_target = v;
    }

    /// Pointer-mutate the slot in place. Only safe when the
    /// extension is known to exist (GC post-mark clear, never on
    /// a plain object).
    pub fn weakRefTargetSlot(self: *JSObject) ?*Value {
        if (self.extension) |ext| return &ext.weak_ref_target;
        return null;
    }

    pub fn getFinalizationCells(self: *const JSObject) ?*FinalizationData {
        if (self.extension) |ext| return ext.finalization_cells;
        return null;
    }

    pub fn setFinalizationCells(self: *JSObject, allocator: std.mem.Allocator, fc: ?*FinalizationData) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.finalization_cells = fc;
    }

    // ── ES2026 explicit-resource-management — DisposableStack ──
    //
    // §27.3 DisposableStack / §27.4 AsyncDisposableStack. The
    // `[[DisposableState]]` slot brands an instance ("pending" /
    // "disposed"); `[[DisposeCapability]]` is a LIFO list of
    // disposable resource records. Both live on the extension —
    // plain objects pay the null-extension fast path.

    pub fn getDisposableState(self: *const JSObject) ?DisposableState {
        if (self.extension) |ext| return ext.disposable_state;
        return null;
    }

    pub fn setDisposableState(self: *JSObject, allocator: std.mem.Allocator, state: ?DisposableState) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.disposable_state = state;
    }

    pub fn disposableResourcesPtr(self: *JSObject, allocator: std.mem.Allocator) !*std.ArrayListUnmanaged(DisposableResource) {
        const ext = try self.getOrCreateExtension(allocator);
        return &ext.disposable_resources;
    }

    pub fn disposableResourcesConst(self: *const JSObject) ?*const std.ArrayListUnmanaged(DisposableResource) {
        if (self.extension) |ext| return &ext.disposable_resources;
        return null;
    }

    // ── Temporal — plain value internal-slot record ────────────
    //
    // A `Temporal.Duration` / `Temporal.PlainTime` instance points
    // at a heap-allocated `TemporalRecord` through the extension.
    // The brand (the tagged-union variant) is checked by every
    // prototype method's RequireInternalSlot. Plain objects pay the
    // null-extension fast path.

    pub fn getTemporalRecord(self: *const JSObject) ?*@import("temporal.zig").TemporalRecord {
        if (self.extension) |ext| return ext.temporal_record;
        return null;
    }

    pub fn setTemporalRecord(self: *JSObject, allocator: std.mem.Allocator, rec: *@import("temporal.zig").TemporalRecord) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.temporal_record = rec;
    }

    // ── §25 / §23 ArrayBuffer + TypedArray + DataView state ────
    //
    // The four heaviest cold fields by absolute byte count — the
    // TypedView struct alone is ~56 bytes. Only TypedArray /
    // ArrayBuffer / DataView instances populate them; every plain
    // object skips the allocation.

    pub fn getArrayBuffer(self: *const JSObject) ?[]u8 {
        if (self.extension) |ext| {
            // §25.2 — a SharedArrayBuffer's bytes are the shared
            // block's live slice (`bytes[0..byte_length]`), computed
            // fresh so a `grow` (which bumps `byte_length` in place) is
            // visible to every agent's view without re-caching.
            if (ext.shared_block) |blk| return blk.live();
            return ext.array_buffer;
        }
        return null;
    }

    /// §25.1.6 IsSharedArrayBuffer(O) — true iff `O` carries a byte
    /// data block that belongs to a `SharedArrayBuffer`.
    pub fn isSharedArrayBuffer(self: *const JSObject) bool {
        return self.has_array_buffer_data and self.array_buffer_shared;
    }

    pub fn getSharedBlock(self: *const JSObject) ?*@import("shared_data_block.zig").SharedDataBlock {
        if (self.extension) |ext| return ext.shared_block;
        return null;
    }

    pub fn setSharedBlock(self: *JSObject, allocator: std.mem.Allocator, blk: ?*@import("shared_data_block.zig").SharedDataBlock) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.shared_block = blk;
    }

    pub fn setArrayBuffer(self: *JSObject, allocator: std.mem.Allocator, bytes: ?[]u8) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.array_buffer = bytes;
    }

    /// Set `array_buffer` to a *borrowed* slice the object must not free
    /// (e.g. WebAssembly linear memory backing `Memory.prototype.buffer`).
    pub fn setExternalArrayBuffer(self: *JSObject, allocator: std.mem.Allocator, bytes: []u8) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.array_buffer = bytes;
        ext.array_buffer_external = true;
    }

    /// In-place mutate of the slice; safe only when the extension
    /// already exists (the array_buffer setter ran).
    pub fn arrayBufferSlot(self: *JSObject) ?*?[]u8 {
        if (self.extension) |ext| return &ext.array_buffer;
        return null;
    }

    pub fn getArrayBufferMaxByteLength(self: *const JSObject) ?usize {
        if (self.extension) |ext| return ext.array_buffer_max_byte_length;
        return null;
    }

    pub fn setArrayBufferMaxByteLength(self: *JSObject, allocator: std.mem.Allocator, n: ?usize) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.array_buffer_max_byte_length = n;
    }

    pub fn getTypedView(self: *const JSObject) ?TypedView {
        if (self.extension) |ext| return ext.typed_view;
        return null;
    }

    pub fn getTypedViewPtr(self: *JSObject) ?*TypedView {
        if (self.extension) |ext| if (ext.typed_view) |*tv| return tv;
        return null;
    }

    pub fn setTypedView(self: *JSObject, allocator: std.mem.Allocator, view: ?TypedView) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.typed_view = view;
    }

    pub fn getDataView(self: *const JSObject) ?DataView {
        if (self.extension) |ext| return ext.data_view;
        return null;
    }

    pub fn getDataViewPtr(self: *JSObject) ?*DataView {
        if (self.extension) |ext| if (ext.data_view) |*dv| return dv;
        return null;
    }

    pub fn setDataView(self: *JSObject, allocator: std.mem.Allocator, dv: ?DataView) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.data_view = dv;
    }

    // ── §22.1 String wrapper + embedder host pointer ──────────
    //
    // Both are cold on a plain JSObject and live behind the
    // extension. The brand check `getBoxedString() != null` keeps
    // the same semantics as the old direct-field read; non-String
    // wrappers stay on the null-extension fast path.

    pub fn getBoxedString(self: *const JSObject) ?*@import("string.zig").JSString {
        if (self.extension) |ext| return ext.boxed_string;
        return null;
    }

    pub fn setBoxedString(self: *JSObject, allocator: std.mem.Allocator, s: ?*@import("string.zig").JSString) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.boxed_string = s;
    }

    pub fn getHostData(self: *const JSObject) ?*anyopaque {
        if (self.extension) |ext| return ext.host_data;
        return null;
    }

    pub fn setHostData(self: *JSObject, allocator: std.mem.Allocator, p: ?*anyopaque) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.host_data = p;
    }

    /// §3.8 ShadowRealm instance [[Realm]] — see the
    /// `JSObjectExtension.shadow_realm_owner` doc. Cold; only
    /// ShadowRealm instances populate it.
    pub fn shadowRealmOwner(self: *const JSObject) ?*@import("realm.zig").Realm {
        if (self.extension) |ext| return ext.shadow_realm_owner;
        return null;
    }

    pub fn setShadowRealmOwner(self: *JSObject, allocator: std.mem.Allocator, r: ?*@import("realm.zig").Realm) !void {
        const ext = try self.getOrCreateExtension(allocator);
        ext.shadow_realm_owner = r;
    }

    // ── Shape-mode slot storage (inline + overflow) ─────────────────
    //
    // The first `inline_slot_cap` logical slots live in `inline_slots`
    // (in the header); the rest in `overflow_slots`. These accessors
    // hide the split — callers index a single logical [0 .. slot_count)
    // space. Bounds are the caller's responsibility (same contract the
    // old `slots.items[i]` had).

    /// Total live slot count (inline + overflow).
    pub inline fn slotCount(self: *const JSObject) usize {
        return self.slot_count;
    }

    /// Read logical slot `i`.
    pub inline fn slotAt(self: *const JSObject, i: usize) Value {
        return if (i < inline_slot_cap)
            self.inline_slots[i]
        else
            self.overflow_slots.items[i - inline_slot_cap];
    }

    /// Pointer to logical slot `i` (for in-place update).
    pub inline fn slotPtr(self: *JSObject, i: usize) *Value {
        return if (i < inline_slot_cap)
            &self.inline_slots[i]
        else
            &self.overflow_slots.items[i - inline_slot_cap];
    }

    /// Write logical slot `i`.
    pub inline fn setSlot(self: *JSObject, i: usize, v: Value) void {
        if (i < inline_slot_cap) {
            self.inline_slots[i] = v;
        } else {
            self.overflow_slots.items[i - inline_slot_cap] = v;
        }
    }

    /// Grow / shrink the live slot space to exactly `n`. Overflow is
    /// allocated only when `n > inline_slot_cap`. Matches
    /// `ArrayList.resize` semantics: new slots are uninitialised
    /// (the caller writes them); shrinking just lowers the count.
    pub fn resizeSlots(self: *JSObject, allocator: std.mem.Allocator, n: usize) !void {
        if (n > inline_slot_cap) {
            try self.overflow_slots.resize(allocator, n - inline_slot_cap);
        } else if (self.overflow_slots.items.len != 0) {
            // Shrinking back into the inline range — drop the
            // overflow buffer's live entries (keep capacity).
            self.overflow_slots.clearRetainingCapacity();
        }
        self.slot_count = @intCast(n);
    }

    /// Reset to zero live slots, retaining overflow capacity (the
    /// demote path's `slots.clearRetainingCapacity()` analogue).
    pub fn clearSlots(self: *JSObject) void {
        self.slot_count = 0;
        self.overflow_slots.clearRetainingCapacity();
    }

    /// Drop every sub-allocation owned by this object — does NOT
    /// release the `JSObject` struct itself. The full `deinit`
    /// path calls this and then `allocator.destroy(self)`; the
    /// `Heap` pool path calls this and then `pool.destroy(self)`
    /// so the JSObject memory goes onto the slab free-list instead
    /// of back through libsystem_malloc.
    pub fn deinitFields(self: *JSObject, allocator: std.mem.Allocator) void {
        self.properties.deinit(allocator);
        self.property_flags.deinit(allocator);
        // `private_properties`, `private_methods`, `private_accessors`,
        // `accessors`, `namespace_redirects`, `ambiguous_namespace_keys`,
        // `map_data`, `set_data` all live in the extension — freed
        // when it is.
        if (self.array_like_iter) |s| s.deinit(allocator);
        if (self.map_set_iter) |s| s.deinit(allocator);
        if (self.regexp_string_iter) |s| s.deinit(allocator);
        if (self.iter_record) |s| s.deinit(allocator);
        if (self.iter_helper) |s| s.deinit(allocator);
        if (self.getCapabilityRecord()) |s| s.deinit(allocator);
        if (self.regex_perlex) |p| {
            p.deinit();
            allocator.destroy(p);
        }
        // `finalization_cells`, `weak_ref_target`, `array_buffer`,
        // `typed_view`, `data_view`, `array_buffer_max_byte_length`
        // all live in the extension — freed when it is.
        // Promise reaction/waiter lists live in their own node.
        if (self.promise_store) |s| {
            s.deinit(allocator);
            if (self.heap) |h| h.promise_store_pool.destroy(s) else allocator.destroy(s);
        }
        self.key_anchors.deinit(allocator);
        self.own_key_order.deinit(allocator);
        self.elements.deinit(allocator);
        self.sparse_elements.deinit(allocator);
        // `shape` itself is realm-lifetime arena memory (ShapeTree),
        // not freed per-object; only the overflow slot vector is
        // owned here (inline slots live in the header).
        self.overflow_slots.deinit(allocator);
        if (self.extension) |ext| {
            ext.deinit(allocator);
            allocator.destroy(ext);
        }
        // instance_field_inits / private_method_inits are
        // borrowed slices owned by class.zig (allocated against
        // the realm allocator and tracked by the realm); freeing
        // them happens at realm.deinit().
    }

    pub fn deinit(self: *JSObject, allocator: std.mem.Allocator) void {
        self.deinitFields(allocator);
        allocator.destroy(self);
    }

    /// §10.1.11 OrdinaryOwnPropertyKeys — record `key` as a member
    /// of the unified insertion-order list, if it isn't already
    /// tracked. No-op for internal `__cynic_*` slots, integer-index
    /// keys (those have their own ordering rule in
    /// `ownPropertyKeysOrdered`), and re-insertions of an existing
    /// key (chronological order is anchored at first insertion).
    /// Returns `true` when `key` was newly appended to the order
    /// list, `false` when it was skipped (internal slot, integer
    /// index, or already present). Callers that anchor the key's
    /// backing JSString (`setComputedOwned`) use this to anchor
    /// exactly once — on first insertion.
    pub fn recordKey(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !bool {
        if (std.mem.startsWith(u8, key, "__cynic_")) return false;
        if (canonicalIntegerIndex(key) != null) return false;
        for (self.own_key_order.items) |existing| {
            if (std.mem.eql(u8, existing, key)) return false;
        }
        try self.own_key_order.append(allocator, key);
        return true;
    }

    /// §10.1.11 OrdinaryOwnPropertyKeys — drop `key` from the
    /// unified insertion-order list. Called from the delete /
    /// swapRemove paths in builtins/object.zig / lantern.zig
    /// when both the data and accessor map entries for `key` go
    /// away. Cheap linear scan — the list is bounded by the
    /// object's own-key count.
    pub fn forgetKey(self: *JSObject, key: []const u8) void {
        var i: usize = 0;
        while (i < self.own_key_order.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.own_key_order.items[i], key)) {
                _ = self.own_key_order.orderedRemove(i);
                return;
            }
        }
    }

    /// Property-bag store with the generational write barrier folded
    /// in. A named-data write that lands in the dictionary bag (not a
    /// shape slot) still creates an owner→value edge the GC must see:
    /// a mature object gaining a young referent here must join the
    /// remembered set, or the minor sweep reclaims the still-reachable
    /// value (`verifyRememberedSet` bag-edge assert). Mirrors the
    /// barrier `shadowSet` applies on the shape-slot path and
    /// `setIndexed` on the element vector — the bag is the third
    /// storage chokepoint, and native callers reach it through
    /// `set` / `setIfWritable` / `setWithFlags`, never the barriered
    /// interpreter store opcode.
    fn bagPut(self: *JSObject, allocator: std.mem.Allocator, key: []const u8, v: Value) std.mem.Allocator.Error!void {
        try self.properties.put(allocator, key, v);
        if (self.heap) |h| h.writeBarrier(.{ .object = self }, v);
    }

    /// Like `set`, but anchors `key_str` (whose `bytes` is the
    /// property key) onto this object so the GC keeps it alive
    /// for as long as the object is reachable. Use when the key
    /// is a heap-allocated JSString rather than a static literal
    /// or chunk-constant slice (the latter never get swept).
    pub fn setComputedOwned(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key_str: *@import("string.zig").JSString,
        v: Value,
    ) !void {
        // §10.4.2 Array exotic — integer-indexed writes land in
        // `elements`. The JSString anchor is unnecessary because
        // the value isn't keyed by the string at all.
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key_str.flatBytes())) |idx| {
                return self.setIndexed(allocator, idx, v);
            }
        }
        const key = key_str.flatBytes();
        const absorbed = try self.shadowSet(allocator, key, v, PropertyFlags.default);
        const newly_ordered = try self.recordKey(allocator, key);
        if (absorbed) {
            // Shape-mode: only `own_key_order` borrows the slice (the
            // shape's transition arena dupes the key for value lookup,
            // and there is no `properties` entry). Anchor the JSString
            // when newly recorded so a sweep can't free it out from
            // under the order slice (gc-threshold=1 reorders
            // Object.keys/values otherwise).
            if (newly_ordered) try self.key_anchors.append(allocator, key_str);
            return;
        }
        // Dictionary-mode: the `properties` bag ALSO borrows the key
        // slice. Anchor the JSString on a first insertion into either
        // `own_key_order` OR the bag. Integer-index keys on a non-array
        // object (`o[0] = v`) skip `own_key_order` (recordKey returns
        // false for them) but still land in the bag — so the bag
        // insertion must anchor them too, else gc-threshold=1 sweeps
        // the index key and a later indexed read misses (e.g.
        // Array.prototype.forEach on an array-like saw zero-length
        // iteration once the `o[i]=…` keys dangled). Repeated writes to
        // an existing key (found_existing) skip the anchor so
        // `key_anchors` can't grow unboundedly.
        const gop = try self.properties.getOrPut(allocator, key);
        gop.value_ptr.* = v;
        // Generational write barrier — see `bagPut` (this site can't
        // use the helper: it needs `getOrPut`'s `found_existing` for
        // the key-anchor bookkeeping below).
        if (self.heap) |h| h.writeBarrier(.{ .object = self }, v);
        if (newly_ordered or !gop.found_existing) try self.key_anchors.append(allocator, key_str);
    }

    /// Read the (possibly defaulted) descriptor flags for
    /// `key`. Returns `PropertyFlags.default` (all-true) when no
    /// override is recorded. Phase 3 of
    /// [docs/lazy-property-bag.md]: shape-mode entries encode
    /// their attrs on the transition node, so we consult the
    /// shape first and only fall back to `property_flags` for
    /// dictionary-mode keys.
    pub fn flagsFor(self: *const JSObject, key: []const u8) PropertyFlags {
        // §23.1.4 — the array exotic's virtual `length` descriptor:
        // only [[Writable]] is mutable (the bit); [[Enumerable]] and
        // [[Configurable]] are constant false.
        if (self.isVirtualLengthKey(key)) {
            return .{
                .writable = self.array_length_writable,
                .enumerable = false,
                .configurable = false,
            };
        }
        if (self.shape) |sh| {
            if (sh.lookup(key)) |entry| {
                if (entry.kind == .data) return entry.attrs;
            }
        }
        if (self.property_flags.get(key)) |f| return f;
        // §9.4.6.5 Module Namespace exotic — every exported binding
        // descriptor is `{writable: true, enumerable: true,
        // configurable: false}` regardless of when the binding was
        // installed, so a self-import that reads
        // `Object.getOwnPropertyDescriptor(ns, "X")` during the body
        // (before the module's evaluation completes, when
        // `getModuleNamespace`'s flag-lowering pass runs) still
        // reports the spec descriptor. The `@@toStringTag` slot has
        // an explicit entry in `property_flags` so it stays
        // `{w:false, e:false, c:false}`.
        if (self.is_module_namespace and
            !std.mem.startsWith(u8, key, "@@") and
            !std.mem.startsWith(u8, key, "<sym:"))
        {
            if (self.properties.contains(key) or self.hasNamespaceRedirect(key)) {
                return .{
                    .writable = true,
                    .enumerable = true,
                    .configurable = false,
                };
            }
        }
        return PropertyFlags.default;
    }

    /// Set the value AND descriptor flags for `key`. Used by
    /// `installNativeMethodOnProto` for non-enumerable
    /// installations and by `Object.defineProperty`.
    pub fn setWithFlags(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
        flags: PropertyFlags,
    ) !void {
        return self.setWithFlagsImpl(allocator, key, v, flags, true);
    }

    /// `setWithFlags` without the `heap.proto_struct_epoch` bump.
    /// Valid ONLY when `self` is a brand-new object not yet reachable
    /// as any other object's prototype: a non-default-flagged own
    /// install on such an object (e.g. an array exotic's §23.1.4
    /// `length` at construction) cannot sit in any live transition
    /// write IC's snapshotted prototype chain, so the conservative
    /// epoch bump `setWithFlags` does for §10.1.9 prototype-chain
    /// safety would be a pure false positive that deopts unrelated hot
    /// constructor loops. See `markAsArrayExotic`.
    fn setWithFlagsNoEpochBump(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
        flags: PropertyFlags,
    ) !void {
        return self.setWithFlagsImpl(allocator, key, v, flags, false);
    }

    fn setWithFlagsImpl(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
        flags: PropertyFlags,
        comptime bump_epoch: bool,
    ) !void {
        // DISABLED-BISECT
        // §10.4.2 Array exotic — integer-indexed writes route to
        // `elements`. The descriptor flags are silently ignored
        // for now: indexed slots are always `{w,e,c} = true`
        // (full descriptor support per slot would require
        // promoting indexed-with-flags into a sparse dictionary
        // representation, which is later).
        const is_default =
            flags.writable and flags.enumerable and flags.configurable;
        // A non-default flagged install (defineProperty / freeze / a
        // non-enumerable builtin) can place a non-writable data property
        // — or, on the accessor path, a setter — into some receiver's
        // prototype chain, which a transition write IC must not write
        // past (§10.1.9). This is the funnel the cell's proto_shape /
        // proto_rev miss for a dictionary-mode or non-immediate proto.
        // Plain value writes go through `shadowSet`, not here, so the
        // constructor hot loop is unaffected. Callers installing onto a
        // freshly-created, never-yet-a-prototype object opt out via
        // `setWithFlagsNoEpochBump` — the bump would be a false positive.
        if (bump_epoch and !is_default) {
            if (self.heap) |h| h.bumpProtoStructEpoch();
        }
        // §23.1.4 / §10.4.2.1 — the array exotic's virtual `length`.
        // A flagged install (defineProperty machinery, freeze) lands
        // here: the value routes to the indexed storage and the only
        // mutable descriptor field, [[Writable]], lands in the bit.
        // ([[Enumerable]] / [[Configurable]] are constant false; the
        // defineProperty builtin validates illegal descriptors before
        // calling down.)
        if (self.isVirtualLengthKey(key)) {
            if (valueToArrayLength(v)) |n| try self.setArrayLength(allocator, n);
            self.array_length_writable = flags.writable;
            return;
        }
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                if (is_default) {
                    return self.setIndexed(allocator, idx, v);
                }
                // Non-default flags (e.g. `enumerable: false`,
                // `writable: false`) on an indexed slot — promote
                // the slot into the named-property bag so the
                // descriptor flags survive. The corresponding
                // elements slot stays as a hole; reads check the
                // property bag first via the `set` / `get` paths.
                // §10.4.2.1 step 4 — length auto-extends when
                // the index is at or past the current length,
                // even when the indexed slot is bag-promoted.
                const new_len: usize = @as(usize, idx) + 1;
                if (self.arrayLength() < new_len) {
                    try self.ensureElementsLen(allocator, new_len);
                }
                self.holeIndexed(idx);
            }
        }
        // Try the shape-first path. On success the slot is the
        // source of truth and the bag write is skipped — the
        // headline Phase 3 perf win (see
        // [docs/lazy-property-bag.md]).
        const absorbed = try self.shadowSet(allocator, key, v, flags);
        _ = try self.recordKey(allocator, key);
        if (absorbed) {
            // Shape encodes the attrs on the transition node —
            // no `property_flags` entry needed. Clear any stale
            // entry left behind by a prior dict-mode redefine.
            _ = self.property_flags.swapRemove(key);
            return;
        }
        // Dictionary-mode: bag is the source of truth.
        try self.bagPut(allocator, key, v);
        if (is_default) {
            _ = self.property_flags.swapRemove(key);
        } else {
            try self.property_flags.put(allocator, key, flags);
        }
    }

    /// Generational write barrier at the *lowest* property-storage
    /// funnel. Every named / indexed / flagged write into a JSObject's
    /// bag, slots, or elements routes through `set` / `setWithFlags` /
    /// `setIfWritable` / `setComputedOwned` / `setIndexed`, so calling
    /// this at the top of each one makes "a young value stored into a
    /// mature object marks it dirty" complete by construction — it no
    /// longer depends on every call site reaching for `Heap.store*`
    /// (hundreds of raw `obj.set(...)` calls in builtins bypassed
    /// those). Cheap: `writeBarrier` fast-rejects a non-heap value and
    /// a young container before touching the dirty list, which is the
    /// overwhelmingly common construction case. Mirrors V8 / JSC's
    /// store barrier living in the object write path, not the caller.
    inline fn storeBarrier(self: *JSObject, v: Value) void {
        if (self.heap) |h| h.writeBarrier(.{ .object = self }, v);
    }

    /// `[[Set]]` (§10.1.9) — assign a property by name. The
    /// `key` slice must remain valid for the object's lifetime
    /// (typically a `JSString` byte buffer or a literal in the
    /// chunk's source).
    ///
    /// Bypass form: doesn't honor writable=false. Used by
    /// internal installers (`installNativeMethodOnProto`,
    /// constructor wiring, etc.) where the caller already knows
    /// the descriptor flags it wants. User-driven writes go
    /// through `setIfWritable` (which respects flags).
    /// Coerce an already-numeric Value to an array length, or `null`
    /// when it isn't one (negative, fractional, out of u32 range, or
    /// not a number). The JS-visible length writes do the full
    /// §10.4.2.4 ToUint32 + RangeError dance in the interpreter
    /// BEFORE reaching the storage funnels here; this covers the
    /// native builders that pass a known-good integer.
    fn valueToArrayLength(v: Value) ?u32 {
        if (v.isInt32()) {
            const i = v.asInt32();
            return if (i >= 0) @intCast(i) else null;
        }
        if (v.isDouble()) {
            const d = v.asDouble();
            if (d >= 0 and d <= 4294967295.0 and d == @trunc(d))
                return @intFromFloat(d);
        }
        return null;
    }

    pub fn set(self: *JSObject, allocator: std.mem.Allocator, key: []const u8, v: Value) !void {
        // DISABLED-BISECT
        // §10.4.2 Array exotic — integer-indexed keys land in
        // the packed `elements` vector, unless the slot has been
        // demoted to the named-property bag (descriptor flags
        // override). The bypass `set` skips the writability gate
        // by design (internal installers).
        if (self.is_array_exotic) {
            // The virtual `length` slot — route to the indexed
            // storage (§10.4.2.4's storage effect). This bypass API
            // skips the writability gate by design, like every other
            // key through it.
            if (self.isVirtualLengthKey(key)) {
                if (valueToArrayLength(v)) |n| return self.setArrayLength(allocator, n);
                return; // non-length-shaped value: nothing to store
            }
            if (canonicalIntegerIndex(key)) |idx| {
                if (self.properties.contains(key)) {
                    try self.bagPut(allocator, key, v);
                    // Already-tracked key — no-op for recordKey.
                    return;
                }
                return self.setIndexed(allocator, idx, v);
            }
        }
        // §10.4.5 Integer-Indexed Exotic [[Set]] — TypedArray
        // numeric-index write goes straight to the backing buffer
        // (live length on length-tracking views over a resizable
        // ArrayBuffer). NOTE: this internal `set` bypasses
        // ToNumber/ToBigInt coercion — Array.prototype.fill /
        // copyWithin etc. pass an already-numeric value, and
        // the call sites that need user coercion route through
        // the interpreter's sta_property bytecode instead. Drop
        // out-of-bounds writes silently per spec.
        if (self.getTypedView()) |tv| {
            // §10.4.5.5 [[Set]] for Integer-Indexed Exotic Objects —
            // the intercept gate is CanonicalNumericIndexString, NOT
            // Zig `parseInt` (which accepts a leading `+` / `-` that
            // CanonicalNumericIndexString rejects). Without the
            // round-trip check, keys like "+1" / "01" land in the
            // OOB-drop branch and never make it to the property bag,
            // making `Reflect.set(ta, "+1", v)` a silent no-op.
            const ta_mod = @import("builtins/typed_array.zig");
            if (ta_mod.canonicalNumericIndex(key)) |num| {
                if (ta_mod.isValidIntegerIndexPub(tv, num)) {
                    const buf = tv.viewed.getArrayBuffer().?;
                    const elem_size = tv.kind.elementSize();
                    const idx: usize = @intFromFloat(num);
                    const intrinsics_mod = @import("intrinsics.zig");
                    // Route through the name-aware dispatcher so
                    // Uint8ClampedArray uses ToUint8Clamp (§7.1.11),
                    // not modular ToUint8 (§7.1.6) — both share
                    // `kind = .uint8` in Cynic.
                    intrinsics_mod.writeTypedElementForView(buf, tv, tv.byte_offset + idx * elem_size, v);
                }
                // CanonicalNumericIndex keys (whether valid or OOB)
                // never land in the ordinary property bag — that's
                // the typed-array exotic's whole point.
                return;
            }
        }
        // Try the shape-first path. On absorption the slot is the
        // source of truth and the bag write is skipped.
        const absorbed = try self.shadowSet(allocator, key, v, PropertyFlags.default);
        _ = try self.recordKey(allocator, key);
        if (absorbed) return;
        try self.bagPut(allocator, key, v);
    }

    /// Demote a shaped object back to dictionary mode. Phase 3 of
    /// [docs/lazy-property-bag.md]: shape-mode objects no longer
    /// mirror their slot values into the bag, so demoting must
    /// back-fill `properties` (and `property_flags` for any
    /// non-default attrs) from the shape chain before dropping
    /// the shape. Idempotent for objects without a shape.
    ///
    /// Public so the paths that mutate `properties` directly —
    /// `delete`, `defineProperty`, accessor installs — can pin
    /// the bag as the source of truth before they touch it.
    pub fn demoteFromShape(self: *JSObject, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        const shape = self.shape orelse return;
        // Leaving shape mode (delete, flag-diverging redefine, accessor
        // install) can alter what a transition write IC inheriting from
        // `self` may write past — broad funnel covering shaped-object
        // delete/redefine. Not reached by plain shaped writes.
        if (self.heap) |h| h.bumpProtoStructEpoch();
        // Walk leaf → root; the chain order is "last property
        // added is the leaf." Back-fill the bag with each entry,
        // including its descriptor attrs when they diverge from
        // the all-true default.
        var node: ?*const @import("shape.zig").Shape = shape;
        while (node) |n| : (node = n.parent) {
            if (n.parent == null) break; // root carries no key
            if (n.kind != .data) continue;
            if (n.slot >= self.slotCount()) continue;
            const v = self.slotAt(n.slot);
            try self.properties.put(allocator, n.key, v);
            const is_default = n.attrs.writable and n.attrs.enumerable and n.attrs.configurable;
            if (!is_default) {
                try self.property_flags.put(allocator, n.key, n.attrs);
            }
        }
        self.shape = null;
        self.clearSlots();
    }

    /// Debug-only consistency check: under Phase 3 of
    /// [docs/lazy-property-bag.md] a shape-mode object's bag
    /// is empty — the shape owns the data. Verify that every
    /// shape-claimed data slot points to a valid index in
    /// `slots` and (when the bag also carries the key) that
    /// the bag agrees with the slot. The empty-bag case is
    /// the new normal; a divergence flags a code path that
    /// mutated one representation without rebuilding the other.
    pub fn verifyShapeInvariant(self: *const JSObject) void {
        if (!std.debug.runtime_safety) return;
        const shape = self.shape orelse return;
        var node: ?*const @import("shape.zig").Shape = shape;
        while (node) |n| : (node = n.parent) {
            if (n.parent == null) break;
            if (n.kind != .data) continue;
            if (n.slot >= self.slotCount()) {
                std.debug.panic(
                    "shape invariant: slot {} out of range (slots.len={}) for key '{s}'",
                    .{ n.slot, self.slotCount(), n.key },
                );
            }
            // Bag may legitimately not have the key (pure shape-
            // mode object). Only check parity when the bag DOES
            // carry it (a stragger from a partial demote, or a
            // raw `properties.put` callsite we missed migrating).
            if (self.properties.get(n.key)) |props_val| {
                const slot_val = self.slotAt(n.slot);
                if (slot_val.bits != props_val.bits) {
                    std.debug.panic(
                        "shape invariant: key '{s}' diverges — slot=0x{x} properties=0x{x}",
                        .{ n.key, slot_val.bits, props_val.bits },
                    );
                }
            }
        }
    }

    /// Try to absorb a named-data write into the shape chain.
    /// Returns `true` iff the shape took the write — caller MUST
    /// skip the `properties.put` mirror; the slot is now the
    /// source of truth. Returns `false` for objects in
    /// dictionary mode (exotic, accessor-bearing, or already
    /// post-demote) — caller must perform the bag write. Demote
    /// paths fall through to `false` after back-filling the bag.
    ///
    /// Phase 3 of [docs/lazy-property-bag.md] — the bag is no
    /// longer a mirror; either the shape or the bag holds the
    /// data, never both. Shape-eligible writes skip the bag
    /// entirely (the headline `class_instantiate` perf win).
    pub fn shadowSet(
        self: *JSObject,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
        flags: PropertyFlags,
    ) std.mem.Allocator.Error!bool {
        const heap = self.heap orelse return false;
        // Exotics and engine-internal slots stay dictionary-mode.
        if (self.is_array_exotic or self.getTypedView() != null or
            self.is_module_namespace or self.proxy_target != null or
            std.mem.startsWith(u8, key, "__cynic_"))
        {
            try self.demoteFromShape(allocator);
            return false;
        }
        // Key already in the shape: a same-descriptor value update
        // keeps the shape; any other redefinition demotes.
        if (self.shape) |s| {
            if (s.lookup(key)) |e| {
                if (e.kind == .data and
                    e.attrs.writable == flags.writable and
                    e.attrs.enumerable == flags.enumerable and
                    e.attrs.configurable == flags.configurable)
                {
                    self.setSlot(e.slot, v);
                    // Generational write barrier — a mature object
                    // gaining a young referent in a shape slot must
                    // join the remembered set, or the minor sweep
                    // collects the still-reachable young value
                    // (`verifyRememberedSet` slot-edge assert).
                    heap.writeBarrier(.{ .object = self }, v);
                    return true;
                }
                try self.demoteFromShape(allocator);
                return false;
            }
        }
        // A key new to the shape. Begin shaping only from a clean
        // object — no bag entries, no accessors, no `own_key_order`
        // residue from a prior demote.
        if (self.shape == null and
            (self.properties.count() != 0 or
                self.own_key_order.items.len != 0 or
                self.accessorCount() != 0))
        {
            return false;
        }
        const from = self.shape orelse heap.shapes.root;
        const child = heap.shapes.transition(from, key, flags, .data) catch |err| {
            try self.demoteFromShape(allocator);
            return err;
        };
        self.resizeSlots(allocator, child.property_count) catch |err| {
            try self.demoteFromShape(allocator);
            return err;
        };
        self.setSlot(child.slot, v);
        // Generational write barrier for the freshly transitioned
        // slot — same hazard as the same-descriptor update above.
        heap.writeBarrier(.{ .object = self }, v);
        self.shape = child;
        return true;
    }

    /// `[[Set]]` honoring §10.1.9 writability. Returns:
    /// • `true` — write succeeded (or no prior entry existed).
    /// • `false` — own property exists with `writable: false`;
    /// value is unchanged. Strict-mode callers should
    /// surface this as a TypeError.
    /// Doesn't walk the prototype chain — that's the caller's
    /// responsibility (the spec [[Set]] climbs proto looking for
    /// accessors, then OrdinaryDefineOwnProperty back on the
    /// receiver). The interpreter's sta_property handler already
    /// checks the prototype chain for accessor setters before
    /// reaching here.
    pub fn setIfWritable(self: *JSObject, allocator: std.mem.Allocator, key: []const u8, v: Value) !bool {
        // DISABLED-BISECT
        // §10.4.2 Array exotic — integer-indexed writes go to
        // the packed `elements` vector unless the slot has been
        // descriptor-flag-demoted to the named-property bag, in
        // which case the bag's `writable` gate applies.
        if (self.is_array_exotic) {
            // The virtual `length` slot — §10.4.2.4 step 17.b gates
            // on the writability bit, then the storage effect.
            if (self.isVirtualLengthKey(key)) {
                if (!self.array_length_writable) return false;
                if (valueToArrayLength(v)) |n| try self.setArrayLength(allocator, n);
                return true;
            }
            if (canonicalIntegerIndex(key)) |idx| {
                if (self.properties.contains(key)) {
                    const flags = self.flagsFor(key);
                    if (!flags.writable) return false;
                    try self.bagPut(allocator, key, v);
                    return true;
                }
                try self.setIndexed(allocator, idx, v);
                return true;
            }
        }
        // §10.1.9 writability gate — shape-first via `flagsFor`
        // + `ownDataContains` (slot in either representation).
        if (self.ownDataContains(key)) {
            const flags = self.flagsFor(key);
            if (!flags.writable) return false;
        }
        const cur_flags = self.flagsFor(key);
        const absorbed = try self.shadowSet(allocator, key, v, cur_flags);
        _ = try self.recordKey(allocator, key);
        if (absorbed) return true;
        try self.bagPut(allocator, key, v);
        return true;
    }

    /// `[[Get]]` (§10.1.8) — own-property lookup that walks the
    /// prototype chain. Returns `undefined` when absent.
    ///
    /// Spec-incomplete on purpose: a *general* §10.1.8 [[Get]]
    /// can call accessor getters, which re-enters the engine
    /// and requires a `*Realm`. Most callers (the interpreter
    /// hot path's IC-served `lda_property`, the spread / iter
    /// machinery in `lantern/interpreter.zig`, the builtin
    /// methods in `runtime/builtins/*`) want a data-shaped
    /// shortcut and route accessor lookups through their own
    /// realm-aware paths. So this method handles data slots
    /// and **synthetic accessors only**.
    ///
    /// Synthetic accessors are the Phase 3 SES demotion
    /// (`intrinsics.installSyntheticAccessorPair`) — every
    /// frozen prototype's data slot becomes an accessor pair
    /// whose getter just returns a captured Value, no JS
    /// re-entry. Treating them as data slots here is
    /// observably equivalent and lets the engine's many
    /// `obj.get("next")` / `obj.get("constructor")` shortcuts
    /// keep working after SES hardening — without this, every
    /// shortcut path that touches a frozen-prototype method
    /// silently returns `undefined`, which is how the
    /// `iterator.next is not callable` cluster surfaced at
    /// `docs/handbook/ses-test262-policy.md` Phase 1.
    ///
    /// User-installed getters (e.g. `Object.defineProperty(o,
    /// "x", {get: …})`) are still NOT fired here. Callers
    /// that need full §10.1.8 semantics must use
    /// `intrinsics.getPropertyChain` (realm-aware) or
    /// `lda_property` (interpreter-hot).
    /// Whether `key` is the virtual `length` of an array exotic.
    pub inline fn isVirtualLengthKey(self: *const JSObject, key: []const u8) bool {
        return self.is_array_exotic and key.len == 6 and std.mem.eql(u8, key, "length");
    }

    /// §23.1.4 — the array exotic's `length` as a Value, computed
    /// from the indexed storage (the virtual slot's current value).
    pub fn arrayLengthValue(self: *const JSObject) Value {
        const n: u32 = self.arrayLength();
        return if (n <= std.math.maxInt(i32))
            Value.fromInt32(@intCast(n))
        else
            Value.fromDouble(@floatFromInt(n));
    }

    pub fn get(self: *const JSObject, key: []const u8) Value {
        // §10.4.2 Array exotic — integer-indexed reads come from
        // the indexed storage (packed `elements` or `sparse_elements`).
        // Holes (§10.4.2.1) fall through to the prototype chain.
        // `length` is the virtual §23.1.4 slot, synthesized here.
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                if (self.tryGetIndexedOwn(idx)) |v| return v;
            } else if (self.isVirtualLengthKey(key)) {
                return self.arrayLengthValue();
            }
        }
        // §10.1 own named-property read. Shape-first when present:
        // `slots[entry.slot]` is the source of truth for shape-stable
        // objects. The bag is consulted only as the fallback (object
        // not shape-managed, or the key isn't covered by the shape
        // — possible during an in-flight transition or on a demoted
        // object). This contract lets `sta_property` skip the bag
        // mirror on IC hits without leaving slow-path readers stale.
        if (self.shape) |sh| {
            if (sh.lookup(key)) |entry| {
                if (entry.kind == .data and entry.slot < self.slotCount()) {
                    return self.slotAt(entry.slot);
                }
            }
        }
        if (self.properties.get(key)) |v| return v;
        // Synthetic-accessor fast path — see the method-level
        // doc above for why this lives in the data-shaped
        // shortcut rather than as a realm-aware general
        // accessor walk.
        if (self.getAccessor(key)) |acc| {
            if (acc.getter) |getter| {
                if (getter.synth_accessor) |sa| return sa.value;
            }
            // Non-synthetic accessor or write-only — caller must
            // route through a realm-aware path; surface `undefined`
            // (matches the legacy pre-SES behaviour for any
            // unreachable accessor).
            return Value.undefined_;
        }
        if (self.prototype) |proto| return proto.get(key);
        if (self.prototype_fn) |pf| return pf.get(key);
        return Value.undefined_;
    }

    /// Own-data lookup, NOT walking the prototype chain. Shape-first:
    /// when the receiver carries a shape that claims `key` as an
    /// own-data entry, returns `slots[entry.slot]` — the bag is a
    /// best-effort mirror and may be stale for shape-mode objects
    /// whose IC-served writes skipped the mirror. Bag fallback is
    /// used for dictionary-mode objects (no shape) and for
    /// shape-claimed accessor entries (data lookup misses, bag
    /// stays the source of truth for descriptor metadata).
    ///
    /// Returns `null` when the key is absent from both shape and
    /// bag. Callers that need accessor dispatch must consult
    /// `getAccessor` separately — this helper is for the data
    /// lookup that closes out an `OrdinaryGet` chain walk.
    pub fn ownDataLookup(self: *const JSObject, key: []const u8) ?Value {
        // §23.1.4 — an array exotic's `length` is an own data
        // property, but virtual (computed, never stored).
        if (self.isVirtualLengthKey(key)) return self.arrayLengthValue();
        if (self.shape) |sh| {
            if (sh.lookup(key)) |entry| {
                if (entry.kind == .data and entry.slot < self.slotCount()) {
                    return self.slotAt(entry.slot);
                }
            }
        }
        return self.properties.get(key);
    }

    /// Own-property check — does NOT walk the prototype chain.
    /// Returns true for both data and accessor own properties
    /// (§7.3.13 HasOwnProperty: any descriptor counts).
    pub fn hasOwn(self: *const JSObject, key: []const u8) bool {
        // §15.2.1.16.3 ambiguous star-export resolution — the
        // namespace's exported-names list excludes ambiguous
        // entries (§15.2.1.18 step 3.c.ii); reflect that in
        // [[HasProperty]] / [[GetOwnProperty]] so `'X' in ns` is
        // `false` and `Object.keys(ns)` omits the key.
        if (self.is_module_namespace and self.hasAmbiguousNamespaceKey(key)) return false;
        // Shape-first own-property check — `slots[entry.slot]` is
        // the authority for shape-stable objects (see the matching
        // ordering in `get` above). Same rationale: future
        // bag-mirror skip in `sta_property` must not leave hasOwn
        // returning false on a freshly-written shaped slot.
        if (self.shape) |sh| {
            if (sh.lookup(key)) |_| return true;
        }
        if (self.properties.contains(key) or self.hasAccessor(key)) return true;
        // §15.2.1.16.3 ResolveExport — re-export redirects make
        // the binding "own" on the Module Namespace exotic even
        // though the value lives elsewhere. `'X' in ns` /
        // `Object.keys(ns)` / `Reflect.has(ns, 'X')` must
        // include them.
        if (self.is_module_namespace and self.hasNamespaceRedirect(key)) return true;
        if (self.is_array_exotic) {
            // §23.1.4 — the virtual `length` is an own property.
            if (self.isVirtualLengthKey(key)) return true;
            if (canonicalIntegerIndex(key)) |idx| {
                return self.hasOwnIndexedSlot(idx);
            }
        }
        // §10.4.5.2 Integer-Indexed Exotic [[HasProperty]] — when
        // the key is a CanonicalNumericIndexString, an own-property
        // check on a TypedArray resolves through IsValidIntegerIndex
        // against the live buffer witness. A fixed-length view over
        // a resizable buffer that's been shrunk past its window
        // reports `hasOwn(i) === false` (and `i in ta === false`)
        // for every numeric index — the §10.4.5.2 lookup explicitly
        // does NOT walk the prototype chain on the numeric form.
        if (self.getTypedView()) |tv| {
            const ta_mod = @import("builtins/typed_array.zig");
            if (ta_mod.canonicalNumericIndex(key)) |num| {
                return ta_mod.isValidIntegerIndexPub(tv, num);
            }
        }
        return false;
    }

    /// §7.3.12 HasProperty — walks the prototype chain. True iff
    /// `key` resolves to a data or accessor own property anywhere
    /// on the chain. Used by §6.2.5.5 ToPropertyDescriptor (which
    /// distinguishes "field not present" from "field is undefined")
    /// and other specs that observe inherited fields.
    pub fn hasProperty(self: *const JSObject, key: []const u8) bool {
        // §15.2.1.16.3 / §15.2.1.18 — ambiguous star-export keys
        // are omitted from the namespace.
        if (self.is_module_namespace and self.hasAmbiguousNamespaceKey(key)) return false;
        if (self.ownDataContains(key)) return true;
        if (self.hasAccessor(key)) return true;
        // §15.2.1.16.3 ResolveExport — re-export redirects appear
        // as own properties on a Module Namespace exotic.
        if (self.is_module_namespace and self.hasNamespaceRedirect(key)) return true;
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                if (self.hasOwnIndexedSlot(idx)) return true;
            }
        }
        // §10.4.5.2 Integer-Indexed Exotic [[HasProperty]] — if the
        // key is a CanonicalNumericIndexString, the lookup ends at
        // the typed-array view (no proto-chain fallthrough for the
        // numeric form). Out-of-bounds / detached / non-integer /
        // negative / -0 all resolve to `false` *without* walking
        // the prototype chain.
        if (self.getTypedView()) |tv| {
            const ta_mod = @import("builtins/typed_array.zig");
            if (ta_mod.canonicalNumericIndex(key)) |num| {
                if (std.math.isNan(num) or std.math.isInf(num)) return false;
                if (@trunc(num) != num) return false;
                if (num == 0.0 and std.math.signbit(num)) return false;
                if (num < 0) return false;
                const idx_u: usize = @intFromFloat(num);
                const buf = tv.viewed.getArrayBuffer() orelse return false;
                // §10.4.5.16 IsValidIntegerIndex — for a length-
                // tracking view, the live length is recomputed from
                // the current buffer size; for a fixed-length view
                // the snapshot, gated on IsTypedArrayOutOfBounds
                // (the view may be entirely OOB after a resizable-
                // buffer shrink).
                const elem_size = tv.kind.elementSize();
                const live_len: usize = if (tv.length_tracking) blk: {
                    if (tv.byte_offset > buf.len) break :blk 0;
                    break :blk (buf.len - tv.byte_offset) / elem_size;
                } else blk: {
                    if (tv.byte_offset + tv.length * elem_size > buf.len) break :blk 0;
                    break :blk tv.length;
                };
                if (idx_u >= live_len) return false;
                if (tv.byte_offset + (idx_u + 1) * elem_size > buf.len) return false;
                return true;
            }
        }
        if (self.prototype) |proto| return proto.hasProperty(key);
        if (self.prototype_fn) |pf| return pf.hasProperty(key);
        return false;
    }

    // ── §7.1.21 / §10.4.2 — Array exotic indexed storage ───────────────

    /// §7.1.21 CanonicalNumericIndexString restricted to
    /// array-index range. Returns the parsed `u32` for keys whose
    /// canonical numeric form is in `[0, 2^32 - 2]` (the array-
    /// index range; `2^32 - 1` is reserved as the impossible-
    /// length sentinel and is NOT an array index). `null`
    /// otherwise — including for `"-0"`, `"01"`, leading-zero
    /// forms, anything non-decimal, and `"4294967295"`.
    pub fn canonicalIntegerIndex(s: []const u8) ?u32 {
        if (s.len == 0) return null;
        if (s.len > 10) return null;
        if (s[0] == '0' and s.len > 1) return null;
        var n: u64 = 0;
        for (s) |c| {
            if (c < '0' or c > '9') return null;
            n = n * 10 + (c - '0');
            if (n > 0xFFFFFFFE) return null;
        }
        return @intCast(n);
    }

    /// Promotion gap — when an indexed write or length-grow
    /// would extend `elements` by more than this many slots in
    /// a single step (i.e. would pad more than this many holes),
    /// the array demotes to `sparse_elements`. Incremental dense
    /// growth (`arr.push` in a loop) stays packed because each
    /// step grows by 1. Picked to comfortably exceed any normal
    /// pre-allocate-and-fill pattern while keeping the worst-case
    /// dense allocation bounded to ~512 KB.
    const sparse_gap_threshold: usize = 1 << 16;

    /// §27.2 — true iff this object is a Promise instance.
    /// Checked via the internal `[[PromiseState]]` slot, NOT via
    /// any user-visible property; a user can't forge a Promise
    /// just by setting properties on a plain object.
    pub inline fn isPromise(self: *const JSObject) bool {
        return self.promise_state != .none;
    }

    /// Settle the promise's `[[PromiseState]]` / `[[PromiseResult]]`
    /// pair atomically. Callers that need to chain reactions should
    /// invoke this AFTER the reactions list has been drained or
    /// snapshotted; the state flip is what makes subsequent
    /// `.then` reactions resolve eagerly instead of registering
    /// for later.
    pub inline fn settlePromise(self: *JSObject, state: PromiseState, value: Value) void {
        self.promise_state = state;
        self.promise_value = value;
    }

    /// Logical array length. Dense → `elements.items.len`;
    /// sparse → `sparse_length`. Callers should prefer this
    /// helper over poking the underlying storage directly.
    pub fn arrayLength(self: *const JSObject) u32 {
        if (self.is_sparse) return self.sparse_length;
        return @intCast(self.elements.items.len);
    }

    /// Own indexed slot read that distinguishes hole from
    /// present-value. Returns `null` for out-of-range or hole,
    /// the value otherwise. `getIndexed` is the §10.4.2.1 step 2
    /// view (hole → undefined); this one preserves the
    /// distinction for callers like `defineProperty`'s
    /// compatible-redefine guard.
    pub fn tryGetIndexedOwn(self: *const JSObject, idx: u32) ?Value {
        if (self.is_sparse) {
            if (self.sparse_elements.get(idx)) |v| {
                if (isElementHole(v)) return null;
                return v;
            }
            return null;
        }
        if (idx >= self.elements.items.len) return null;
        const v = self.elements.items[idx];
        if (isElementHole(v)) return null;
        return v;
    }

    /// Indexed read — own only; does NOT walk the prototype
    /// chain. Returns `undefined` for out-of-range or hole.
    /// (§10.4.2.1 step 2 — a hole on an Array exotic delegates
    /// up the prototype chain via the caller.)
    pub fn getIndexed(self: *const JSObject, idx: u32) Value {
        return self.tryGetIndexedOwn(idx) orelse Value.undefined_;
    }

    /// §10.4.2.1 — an Array exotic's indexed slot is an own
    /// property iff it's been written (the slot is not a hole).
    /// `[0,,2]` leaves slot 1 as a hole; `arr[1] = undefined`
    /// turns slot 1 into a real own property whose value is
    /// `undefined`. The two are distinguishable here via the
    /// `Value.hole_` sentinel re-used from the TDZ encoding.
    pub fn hasOwnIndexedSlot(self: *const JSObject, idx: u32) bool {
        return self.tryGetIndexedOwn(idx) != null;
    }

    /// True iff the slot value is the engine's reserved hole
    /// marker. Element holes share the `Value.hole_` encoding
    /// with TDZ holes — both are unobservable to user code, but
    /// the read paths that surface them differ (TDZ → throw
    /// `ReferenceError`; element hole → fall through to
    /// prototype chain).
    pub fn isElementHole(v: Value) bool {
        return v.bits == Value.hole_.bits;
    }

    /// §10.4.2.1 [[DefineOwnProperty]] step 4 — write `v` at
    /// `idx`, growing the indexed storage (padding with holes)
    /// and updating `length` so `length === idx + 1` whenever
    /// `idx >= length`. May promote dense → sparse.
    pub fn setIndexed(
        self: *JSObject,
        allocator: std.mem.Allocator,
        idx: u32,
        v: Value,
    ) !void {
        const new_len: usize = @as(usize, idx) + 1;
        try self.ensureElementsLen(allocator, new_len);
        if (self.is_sparse) {
            try self.sparse_elements.put(allocator, idx, v);
        } else {
            self.elements.items[idx] = v;
        }
        // Generational write barrier — a mature array gaining a young
        // element referent must join the remembered set, or the minor
        // sweep reclaims the still-reachable young value
        // (`verifyRememberedSet` element-edge assert). Native array
        // builders reach here through `JSObject.set`, not the
        // `heap.storeElement` wrapper, and may hold the result array
        // across a re-entrant build loop where it matures mid-build —
        // so the barrier has to live at this storage chokepoint, not
        // only in the wrapper. Idempotent + O(1)-rejected for the
        // young-array / primitive-element common case.
        if (self.heap) |h| h.writeBarrier(.{ .object = self }, v);
    }

    /// Mirror of `setIndexed` for the hole sentinel — used by
    /// the descriptor-flag-demoted path (the slot's value lives
    /// in the named-property bag; the indexed slot exists only
    /// to count as a hole for `[[Get]]` / `[[HasProperty]]`).
    /// Does NOT sync length; caller is responsible.
    pub fn holeIndexed(self: *JSObject, idx: u32) void {
        if (self.is_sparse) {
            _ = self.sparse_elements.remove(idx);
        } else if (idx < self.elements.items.len) {
            self.elements.items[idx] = Value.hole_;
        }
    }

    /// Append `v` at the next dense index on a dense Array exotic — the
    /// sequential array-literal init case `[a, b, c]`, whose elements
    /// land at 0, 1, 2 in order. Pushes straight onto `elements` and
    /// fires the generational write barrier (a mature array can gain a
    /// young element referent — same `verifyRememberedSet` element-edge
    /// obligation as `setIndexed`). Returns `false` so the caller falls
    /// back to the general indexed path when the array is sparse or
    /// `idx` is not the next slot (a hole-creating or overwriting
    /// write). Does NOT touch `length`; the caller syncs it. §10.4.2.1.
    pub fn appendDenseSequential(
        self: *JSObject,
        allocator: std.mem.Allocator,
        idx: u32,
        v: Value,
    ) !bool {
        if (self.is_sparse) return false;
        if (idx != self.elements.items.len) return false;
        try self.elements.append(allocator, v);
        if (self.heap) |h| h.writeBarrier(.{ .object = self }, v);
        return true;
    }

    /// Grow indexed storage to `new_len`, filling any new slots
    /// with the hole sentinel (§10.4.2.1 — sparse holes are NOT
    /// own properties; reads fall through to the prototype
    /// chain). Promotes dense → sparse when the growth gap
    /// exceeds `sparse_gap_threshold`. No-op if already big enough.
    pub fn ensureElementsLen(self: *JSObject, allocator: std.mem.Allocator, new_len: usize) !void {
        if (self.is_sparse) {
            if (new_len > self.sparse_length) {
                if (new_len > std.math.maxInt(u32)) return error.OutOfMemory;
                self.sparse_length = @intCast(new_len);
            }
            return;
        }
        const old_len = self.elements.items.len;
        if (new_len <= old_len) return;
        if (new_len - old_len > sparse_gap_threshold) {
            try self.promoteToSparse(allocator, new_len);
            return;
        }
        try self.elements.resize(allocator, new_len);
        var i = old_len;
        while (i < new_len) : (i += 1) {
            self.elements.items[i] = Value.hole_;
        }
    }

    /// Migrate `elements` into `sparse_elements`. Existing non-
    /// hole slots become map entries; holes become absent keys.
    /// `sparse_length` is set to `new_len`. Caller has already
    /// validated `new_len <= 2^32`.
    fn promoteToSparse(self: *JSObject, allocator: std.mem.Allocator, new_len: usize) !void {
        std.debug.assert(!self.is_sparse);
        std.debug.assert(new_len <= std.math.maxInt(u32));
        var i: u32 = 0;
        while (i < self.elements.items.len) : (i += 1) {
            const v = self.elements.items[i];
            if (isElementHole(v)) continue;
            try self.sparse_elements.put(allocator, i, v);
        }
        self.elements.clearAndFree(allocator);
        self.sparse_length = @intCast(new_len);
        self.is_sparse = true;
    }

    /// Write `length === arrayLength()` into `properties`.
    /// Called from every indexed mutator so the data property
    /// stays in sync with the storage's logical length.
    // (`syncLengthProperty` is gone — `length` is the virtual
    // §23.1.4 slot computed by `arrayLengthValue`; the indexed
    // storage IS the length, so there is nothing to keep in sync.)

    /// Truncate indexed storage to `new_len`. Used by
    /// §10.4.2.4 ArraySetLength and the `length`-write fast path.
    /// Returns `false` on the first non-configurable element
    /// from the right (spec sets length to that index + 1 and
    /// throws TypeError in strict mode). Today every indexed
    /// slot is implicitly configurable; the return is wired for
    /// the future when `Object.defineProperty(arr, "0", {configurable: false})`
    /// promotes a slot into the named-property bag.
    pub fn truncateIndexed(self: *JSObject, allocator: std.mem.Allocator, new_len: u32) !bool {
        if (self.is_sparse) {
            // Collect keys to remove (can't mutate while iterating).
            var to_remove: std.ArrayListUnmanaged(u32) = .empty;
            defer to_remove.deinit(allocator);
            var it = self.sparse_elements.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* >= new_len) {
                    try to_remove.append(allocator, entry.key_ptr.*);
                }
            }
            for (to_remove.items) |k| _ = self.sparse_elements.remove(k);
            if (new_len < self.sparse_length) self.sparse_length = new_len;
            return true;
        }
        const cur: usize = self.elements.items.len;
        const want: usize = new_len;
        if (want >= cur) return true;
        try self.elements.resize(allocator, want);
        return true;
    }

    /// §10.4.2.4 ArraySetLength — set the array length to
    /// `new_len`, truncating storage if shrinking and growing-
    /// with-holes if expanding. Caller is responsible for the
    /// length-writability gate (§10.4.2.4 step 4); this helper
    /// is the storage-level effect.
    pub fn setArrayLength(self: *JSObject, allocator: std.mem.Allocator, new_len: u32) !void {
        if (!self.is_array_exotic) {
            // Plain object — length is just a data property.
            const v: Value = if (new_len <= std.math.maxInt(i32))
                Value.fromInt32(@intCast(new_len))
            else
                Value.fromDouble(@floatFromInt(new_len));
            try self.properties.put(allocator, "length", v);
            return;
        }
        const cur_len = self.arrayLength();
        if (new_len < cur_len) {
            _ = try self.truncateIndexed(allocator, new_len);
        } else if (new_len > cur_len) {
            try self.ensureElementsLen(allocator, new_len);
        }
    }

    /// §10.4.2 — flip an already-allocated JSObject into an
    /// Array exotic. Called from the centralised `allocateArray`
    /// path and from any site that allocated a fresh JSObject
    /// and is about to chain it to `%Array.prototype%`. Sets the
    /// flag, installs `length: 0` with §23.1.4 flags, and is a
    /// no-op if already an array exotic.
    pub fn markAsArrayExotic(self: *JSObject, allocator: std.mem.Allocator) !void {
        _ = allocator;
        if (self.is_array_exotic) return;
        self.is_array_exotic = true;
        // `length` (§23.1.4) is the VIRTUAL slot — synthesized from the
        // indexed storage by `arrayLengthValue` / `flagsFor` / the key
        // walks — so there is nothing to install: no bag entry, no
        // hashmap traffic, no per-array allocation. The writability
        // bit `array_length_writable` defaults true per §23.1.4.
    }

    /// Drop the indexed slot at `idx` — sets it to the hole
    /// sentinel so a subsequent read falls through to the
    /// prototype chain (§13.5.1.2 [[Delete]] step 5: leaves
    /// length alone, just removes the own property).
    pub fn removeIndexed(self: *JSObject, idx: u32) bool {
        if (self.is_sparse) {
            _ = self.sparse_elements.remove(idx);
            return true;
        }
        if (idx >= self.elements.items.len) return true; // already absent
        self.elements.items[idx] = Value.hole_;
        return true;
    }

    /// §10.1.10 [[Delete]] — drop an own property by key. For
    /// Array-exotic integer-indexed keys, holes the `elements`
    /// slot AND (if the slot was descriptor-flag-demoted to the
    /// named-property bag) removes the bag entry too. Returns
    /// whether the property is absent after the call (true on
    /// success / missing-already, false if a non-configurable
    /// own slot blocked the delete).
    pub fn deleteOwn(self: *JSObject, allocator: std.mem.Allocator, key: []const u8) !bool {
        // Deleting a named property can re-expose an ancestor's setter
        // at this key — invalidate transition write ICs. Integer-index
        // deletes (Array.pop / shift / splice hot path) can't affect a
        // named-key transition IC, so they skip the bump.
        if (canonicalIntegerIndex(key) == null) {
            if (self.heap) |h| h.bumpProtoStructEpoch();
        }
        if (self.is_array_exotic) {
            // §23.1.4 — `length` is non-configurable; the virtual
            // slot can never be deleted.
            if (self.isVirtualLengthKey(key)) return false;
            if (canonicalIntegerIndex(key)) |idx| {
                _ = self.removeIndexed(idx);
                if (self.ownDataContains(key)) {
                    const flags = self.flagsFor(key);
                    if (!flags.configurable) return false;
                    // Shape can't encode a removal — back-fill the
                    // bag from shape (so the swapRemove below has
                    // an entry to drop) and clear the shape. Same
                    // discipline as `del_named_property` in the
                    // interpreter. Native callers
                    // (Array.prototype.pop / splice / shift /
                    // reverse / copyWithin / unshift) reach here
                    // for array-like generic-object receivers.
                    try self.demoteFromShape(allocator);
                    _ = self.properties.swapRemove(key);
                    _ = self.property_flags.swapRemove(key);
                }
                return true;
            }
        }
        if (self.hasAccessor(key)) {
            try self.demoteFromShape(allocator);
            _ = self.removeAccessor(key);
            _ = self.property_flags.swapRemove(key);
            if (!self.properties.contains(key)) self.forgetKey(key);
            return true;
        }
        if (!self.ownDataContains(key)) return true;
        try self.demoteFromShape(allocator);
        _ = self.properties.swapRemove(key);
        _ = self.property_flags.swapRemove(key);
        if (!self.hasAccessor(key)) self.forgetKey(key);
        return true;
    }
};

/// TypedArray view kind. Element-byte-size derives from the
/// variant.
pub const TypedKind = enum(u8) {
    int8,
    uint8,
    int16,
    uint16,
    int32,
    uint32,
    float16,
    float32,
    float64,
    biguint64,
    bigint64,

    pub fn elementSize(k: TypedKind) u8 {
        return switch (k) {
            .int8, .uint8 => 1,
            .int16, .uint16, .float16 => 2,
            .int32, .uint32, .float32 => 4,
            .float64, .biguint64, .bigint64 => 8,
        };
    }

    /// True for the two BigInt-typed-array element kinds. Used
    /// by `fill` / `set` / etc. to branch between ToNumber
    /// (regular typed arrays) and ToBigInt (BigInt variants).
    pub fn isBigInt(k: TypedKind) bool {
        return k == .biguint64 or k == .bigint64;
    }
};

pub const TypedView = struct {
    kind: TypedKind,
    /// Source ArrayBuffer object — the byte buffer is at
    /// `viewed.getArrayBuffer()`. Borrowed pointer.
    viewed: *JSObject,
    byte_offset: usize,
    /// Number of *elements* in the view (not bytes). Snapshot
    /// taken at construction time for fixed-length views;
    /// ignored when `length_tracking` is true (the live length
    /// is computed against the backing buffer).
    length: usize,
    /// §23.2 [[TypedArrayName]] — the string name returned by
    /// `%TypedArray%.prototype[@@toStringTag]`. Stored as a
    /// static string slice so Uint8Array vs Uint8ClampedArray
    /// (which share `kind = .uint8`) can be told apart.
    name: []const u8 = "",
    /// §10.4.5 [[ArrayLength]] = auto — set when the TypedArray
    /// was constructed without an explicit `length` argument over
    /// a resizable ArrayBuffer. The length floats with the buffer.
    length_tracking: bool = false,
};

/// `[[DataView]]` (§25.3.1) — a view over an ArrayBuffer
/// addressed in BYTES, with per-call endianness selection.
/// Distinct from `TypedView` because DataView reads/writes
/// support all element kinds at any byte offset (not aligned)
/// and explicit endian-ness instead of native.
pub const DataView = struct {
    /// Source ArrayBuffer.
    viewed: *JSObject,
    byte_offset: usize,
    /// Snapshot taken at construction. Ignored when
    /// `length_tracking` is true; live byte length is then
    /// computed against the backing buffer.
    byte_length: usize,
    /// §25.3.1 [[ByteLength]] = auto — set when the DataView was
    /// constructed without an explicit `byteLength` argument
    /// over a resizable ArrayBuffer.
    length_tracking: bool = false,
};

/// One user-level `.then` reaction queued on a pending
/// Promise. Recorded by `promiseThen` and fired (as a
/// `promise_reaction` microtask) when the source Promise
/// settles. The handler corresponding to the settled state
/// runs against the settled value; whatever it returns
/// resolves `result_promise` (a Promise return chains
/// settlement). A handler that throws rejects `result_promise`
/// with the thrown value. A null handler propagates the
/// settlement unchanged.
pub const PromiseReaction = struct {
    /// `onFulfilled` callback, or `Value.undefined_` if absent.
    on_fulfilled: Value,
    /// `onRejected` callback, or `Value.undefined_` if absent.
    on_rejected: Value,
    /// The Promise that `then` returned to user code; settled
    /// based on the handler's outcome.
    result_promise: Value,
};

/// §27.2 per-Promise reaction + waiter lists. Split out of the
/// shared `JSObjectExtension` into this small dedicated node
/// (reached by `JSObject.promise_store`): a Promise touches none of
/// the extension's other ~24 cold fields, so piggybacking these two
/// lists on the full extension cost ~500 bytes per pending Promise
/// in a `.then` chain. Lazily allocated on the first reaction /
/// waiter append; owned by the JSObject and freed in `deinitFields`.
pub const PromiseReactionStore = struct {
    /// §27.2.1.8 reaction records queued on a *pending* Promise; run
    /// in FIFO order when it settles.
    reactions: std.ArrayListUnmanaged(PromiseReaction) = .empty,
    /// Generators (async-function suspensions) awaiting this Promise
    /// via `Await` (§27.7) — resumed when it settles.
    waiters: std.ArrayListUnmanaged(*@import("generator.zig").JSGenerator) = .empty,

    pub fn deinit(self: *PromiseReactionStore, allocator: std.mem.Allocator) void {
        self.reactions.deinit(allocator);
        self.waiters.deinit(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "JSObject: set/get round-trip" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try o.set(testing.allocator, "x", Value.fromInt32(42));
    try testing.expectEqual(@as(i32, 42), o.get("x").asInt32());
}

test "JSObject: inline/overflow slot boundary round-trips" {
    // The first `inline_slot_cap` property values live in the
    // header's `inline_slots`; the rest spill to the heap-backed
    // `overflow_slots`. Set enough properties to straddle the
    // boundary and confirm every value reads back through both
    // `slotAt` and the spec-facing `get`, including the slots on
    // either side of the inline/overflow seam.
    const heap_mod = @import("heap.zig");
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    const o = try heap.allocateObject();
    const n: usize = inline_slot_cap + 3;
    var keys: [inline_slot_cap + 3][1]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        keys[i] = .{@as(u8, 'a') + @as(u8, @intCast(i))};
        try o.set(testing.allocator, &keys[i], Value.fromInt32(@intCast(i * 10)));
    }

    try testing.expectEqual(n, o.slotCount());
    // Every logical slot reads back its value via the low-level
    // accessor (the seam is at index `inline_slot_cap`).
    i = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(@as(i32, @intCast(i * 10)), o.slotAt(i).asInt32());
    }
    // And via the spec-facing key lookup.
    i = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(@as(i32, @intCast(i * 10)), o.get(&keys[i]).asInt32());
    }

    // Mutating an overflow slot through `setSlot` is visible to
    // the next read — the write must not silently target the
    // inline array.
    o.setSlot(inline_slot_cap + 1, Value.fromInt32(777));
    try testing.expectEqual(@as(i32, 777), o.slotAt(inline_slot_cap + 1).asInt32());
}

test "JSObject: get prefers the shape slot when present" {
    // The IC fast path serves shape-backed reads in the
    // interpreter, but the JSObject.get fallback (called by
    // every builtin reaching for `obj.get(...)`) must also
    // honour the shape slot — otherwise skipping the
    // property-bag mirror in `sta_property` would leave the
    // slow path returning stale values. Pin the contract.
    const heap_mod = @import("heap.zig");
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    const o = try heap.allocateObject();
    try o.set(testing.allocator, "x", Value.fromInt32(42));
    try o.set(testing.allocator, "y", Value.fromInt32(99));

    // Shape was built — `set` routes through `shadowSet`.
    try testing.expect(o.shape != null);
    try testing.expectEqual(@as(usize, 2), o.slotCount());

    // Stamp a different value directly into the slot, leaving
    // the property bag stale. A shape-first `get` must see the
    // slot value; a bag-first `get` would return the stale bag
    // value. Bag-mirror skip in `sta_property` (future commit)
    // relies on this ordering.
    o.setSlot(0, Value.fromInt32(7));
    try testing.expectEqual(@as(i32, 7), o.get("x").asInt32());
}

test "JSObject: hasOwn prefers the shape when present" {
    // Same contract as `get` above: the shape is authoritative
    // for own-property liveness on a shape-stable object, so
    // skipping the bag mirror in `sta_property` doesn't strand
    // a `hasOwn`-shaped check.
    const heap_mod = @import("heap.zig");
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    const o = try heap.allocateObject();
    try o.set(testing.allocator, "x", Value.fromInt32(42));
    try testing.expect(o.shape != null);

    // Strip the bag entry behind the shape's back; hasOwn must
    // still report own.
    _ = o.properties.swapRemove("x");
    try testing.expect(o.hasOwn("x"));
}

test "JSObject: deleteOwn demotes the shape for shape-stable receivers" {
    // Regression for the 17-fixture `built-ins/Array` cluster
    // (`Array.prototype.{pop, splice, shift, reverse, copyWithin,
    // unshift}` on array-like plain-object receivers go through
    // `deleteOwn` to drop entries). Without demote, the shape
    // keeps claiming the slot is live; shape-first `get`
    // (4133c7f) then returns the stale value instead of
    // falling through to the prototype.
    const heap_mod = @import("heap.zig");
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    const o = try heap.allocateObject();
    try o.set(testing.allocator, "x", Value.fromInt32(42));
    try testing.expect(o.shape != null);

    try testing.expect(try o.deleteOwn(testing.allocator, "x"));
    // Shape demoted — JSObject.get's shape-first branch must
    // see no shape, fall through to the (now-emptied) bag,
    // return undefined.
    try testing.expect(o.shape == null);
    try testing.expect(!o.hasOwn("x"));
    try testing.expect(o.get("x").isUndefined());
}

test "JSObject: accessor install via deleteOwn-then-install demotes the shape" {
    // Regression for the iterator-proto install pattern
    // (`installIteratorPrototypeConstructorAccessor` /
    // `…ToStringTagAccessor`). The bug: install accessor pair
    // → swap-remove the leftover data slot left by an earlier
    // `installConstructor`. If the proto carried a shape with
    // "constructor" at some slot, the swap-remove without
    // demote left shape-first reads returning the stale data
    // value instead of routing through the accessor.
    const heap_mod = @import("heap.zig");
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    const proto = try heap.allocateObject();
    try proto.set(testing.allocator, "constructor", Value.fromInt32(123));
    try testing.expect(proto.shape != null);

    // Simulate the cleanup path: install accessor (demote +
    // getOrPutAccessor in the actual code), then strip the
    // leftover data slot via deleteOwn.
    try testing.expect(try proto.deleteOwn(testing.allocator, "constructor"));
    try testing.expect(proto.shape == null);
    try testing.expect(!proto.hasOwn("constructor"));
}

test "JSObject: missing property is undefined" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try testing.expect(o.get("missing").isUndefined());
}

test "JSObject: get walks prototype chain" {
    const proto = try JSObject.init(testing.allocator);
    defer proto.deinit(testing.allocator);
    try proto.set(testing.allocator, "shared", Value.fromInt32(7));

    const obj = try JSObject.init(testing.allocator);
    defer obj.deinit(testing.allocator);
    obj.prototype = proto;
    try testing.expectEqual(@as(i32, 7), obj.get("shared").asInt32());

    // Own property shadows prototype.
    try obj.set(testing.allocator, "shared", Value.fromInt32(99));
    try testing.expectEqual(@as(i32, 99), obj.get("shared").asInt32());
}

test "JSObject: hasOwn does not walk prototype chain" {
    const proto = try JSObject.init(testing.allocator);
    defer proto.deinit(testing.allocator);
    try proto.set(testing.allocator, "p", Value.true_);

    const obj = try JSObject.init(testing.allocator);
    defer obj.deinit(testing.allocator);
    obj.prototype = proto;
    try testing.expect(!obj.hasOwn("p"));
    try testing.expect(obj.get("p").asBool());
}

// ── Sparse-array representation (§10.4.2) ──────────────────────────

test "JSObject: setIndexed past threshold promotes to sparse" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try o.markAsArrayExotic(testing.allocator);

    try o.setIndexed(testing.allocator, 4_294_967_294, Value.fromInt32(100));
    try testing.expect(o.is_sparse);
    try testing.expectEqual(@as(usize, 0), o.elements.items.len);
    try testing.expectEqual(@as(u32, 4_294_967_295), o.arrayLength());
    try testing.expectEqual(@as(i32, 100), o.getIndexed(4_294_967_294).asInt32());
    try testing.expect(o.hasOwnIndexedSlot(4_294_967_294));
    try testing.expect(!o.hasOwnIndexedSlot(0));
    try testing.expect(o.getIndexed(0).isUndefined());
}

test "JSObject: dense growth stays packed below threshold" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try o.markAsArrayExotic(testing.allocator);

    try o.setIndexed(testing.allocator, 4, Value.fromInt32(7));
    try testing.expect(!o.is_sparse);
    try testing.expectEqual(@as(u32, 5), o.arrayLength());
    try testing.expect(!o.hasOwnIndexedSlot(0));
    try testing.expectEqual(@as(i32, 7), o.getIndexed(4).asInt32());
}

test "JSObject: setArrayLength truncates sparse entries" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try o.markAsArrayExotic(testing.allocator);

    try o.setIndexed(testing.allocator, 0, Value.fromInt32(10));
    try o.setIndexed(testing.allocator, 1, Value.fromInt32(11));
    try o.setIndexed(testing.allocator, 4_294_967_294, Value.fromInt32(12));
    try testing.expect(o.is_sparse);

    try o.setArrayLength(testing.allocator, 2);
    try testing.expectEqual(@as(u32, 2), o.arrayLength());
    try testing.expectEqual(@as(i32, 10), o.getIndexed(0).asInt32());
    try testing.expectEqual(@as(i32, 11), o.getIndexed(1).asInt32());
    try testing.expect(!o.hasOwnIndexedSlot(4_294_967_294));
    try testing.expect(o.getIndexed(4_294_967_294).isUndefined());
}

test "JSObject: setArrayLength grow on sparse just bumps length" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try o.markAsArrayExotic(testing.allocator);

    try o.setIndexed(testing.allocator, 4_294_967_294, Value.fromInt32(1));
    try testing.expect(o.is_sparse);

    try o.setArrayLength(testing.allocator, 4_294_967_295);
    try testing.expectEqual(@as(u32, 4_294_967_295), o.arrayLength());
}

test "JSObject: removeIndexed on sparse drops the slot" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try o.markAsArrayExotic(testing.allocator);

    try o.setIndexed(testing.allocator, 4_294_967_294, Value.fromInt32(42));
    try testing.expect(o.hasOwnIndexedSlot(4_294_967_294));
    _ = o.removeIndexed(4_294_967_294);
    try testing.expect(!o.hasOwnIndexedSlot(4_294_967_294));
    try testing.expectEqual(@as(u32, 4_294_967_295), o.arrayLength());
}

test "JSObject: defineProperty-style flagged write past threshold goes sparse" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try o.markAsArrayExotic(testing.allocator);

    try o.setWithFlags(testing.allocator, "4294967294", Value.fromInt32(100), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
    try testing.expect(o.is_sparse);
    try testing.expectEqual(@as(usize, 0), o.elements.items.len);
    try testing.expectEqual(@as(u32, 4_294_967_295), o.arrayLength());
    try testing.expectEqual(@as(i32, 100), o.get("4294967294").asInt32());
}

// ── JSObjectExtension — lazy cold-field side allocation ────────────
//
// Plain `{a, b}` literals carry the full JSObject header (~kilobyte
// of struct, most of it ArrayHashMap / ArrayList scaffolding for
// fields a typical object never touches: accessors, private slots,
// namespace state, Map/Set data, TypedArray view, Promise reactions,
// WeakRef target, FinalizationRegistry cells). Moving the cold
// fields behind a single `extension: ?*JSObjectExtension` pointer
// lazy-allocates that scaffolding on first cold-field use; the
// common case pays for one null pointer instead of a thousand bytes
// of dead state.
//
// Initial commit lands the scaffolding only — the extension struct
// is empty and no fields move yet. Subsequent commits migrate one
// cold field at a time, each gated on `zig build test`, a runtime
// sweep, and `/gc-stress` on the touched bucket. Anything the JIT
// will speculate on (`shape`, `slots`, `properties`, `elements`,
// `prototype`) stays in the hot JSObject prefix — never moves
// here.

test "JSObjectExtension: footprint probe (size measurement, not an invariant)" {
    // Surfaces the JSObject header size on every test run so a
    // future migration can be checked against the recorded
    // baseline. The header carries `inline_slot_cap` Values
    // inline (the first N property slots live in the header so a
    // small object never mallocs a separate value buffer — see
    // `inline_slots`); the extension-pointer pattern keeps the
    // cold fields off the hot header. Field-by-field moves into
    // the extension should drop this number; raising
    // `inline_slot_cap` raises it by 8 bytes per added slot.
    std.debug.print("[footprint] @sizeOf(JSObject)          = {d} bytes\n", .{@sizeOf(JSObject)});
    std.debug.print("[footprint] @sizeOf(JSObjectExtension) = {d} bytes\n", .{@sizeOf(JSObjectExtension)});
}

test "JSObjectExtension: extension is null on a fresh object" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try testing.expect(o.extension == null);
}

test "JSObjectExtension: getOrCreateExtension lazy-allocates on first call" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    try testing.expect(o.extension == null);
    _ = try o.getOrCreateExtension(testing.allocator);
    try testing.expect(o.extension != null);
}

test "JSObjectExtension: getOrCreateExtension returns the same extension on second call" {
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);
    const first = try o.getOrCreateExtension(testing.allocator);
    const second = try o.getOrCreateExtension(testing.allocator);
    try testing.expectEqual(first, second);
}

test "JSObjectExtension: deinit cleans up the extension if present" {
    // Doubles as a leak check — `testing.allocator` panics on the
    // following test entry if the extension's allocation isn't
    // freed by `deinit`.
    const o = try JSObject.init(testing.allocator);
    _ = try o.getOrCreateExtension(testing.allocator);
    o.deinit(testing.allocator);
}

test "JSObjectExtension: deinit is a no-op when extension is null" {
    // Parity test — confirms the deinit path doesn't crash on
    // objects that never reached for the extension.
    const o = try JSObject.init(testing.allocator);
    o.deinit(testing.allocator);
}

test "JSObjectExtension: boxed_string read/write through helpers" {
    // §22.1.3 [[StringData]] — moved from a JSObject field to the
    // extension. The brand check `getBoxedString() != null` keeps
    // its old semantics on a plain object (returns null without
    // materialising the extension).
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);

    try testing.expectEqual(@as(?*@import("string.zig").JSString, null), o.getBoxedString());
    try testing.expect(o.extension == null);

    // Setting to null still materialises the extension (matches
    // the explicit `Heap.setBoxedString(o, null)` semantics).
    try o.setBoxedString(testing.allocator, null);
    try testing.expect(o.extension != null);
    try testing.expectEqual(@as(?*@import("string.zig").JSString, null), o.getBoxedString());
}

test "JSObjectExtension: host_data read/write through helpers" {
    // Test262 harness — `$262.createRealm()` wrapper carries the
    // child `Realm` here. Plain objects must read back `null`
    // without paying the extension allocation.
    const o = try JSObject.init(testing.allocator);
    defer o.deinit(testing.allocator);

    try testing.expectEqual(@as(?*anyopaque, null), o.getHostData());
    try testing.expect(o.extension == null);

    // Stash a dummy pointer and read it back.
    var marker: u32 = 0xDEADBEEF;
    try o.setHostData(testing.allocator, @ptrCast(&marker));
    try testing.expect(o.extension != null);
    const got = o.getHostData() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&marker)), got);
}
