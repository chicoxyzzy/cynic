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

/// `[[MapData]]` storage (§24.1.4). Keeps insertion order so
/// `forEach` / `for-of` walks pairs in the order they were
/// added. later uses linear-scan lookup; revisit with a real
/// hashmap once we have shapes.
pub const MapData = struct {
    entries: std.ArrayListUnmanaged(MapEntry) = .empty,
    /// Whether this map data belongs to a WeakMap instance.
    /// `WeakMap.prototype.{set, get, has, delete}` reject
    /// receivers whose map_data isn't a WeakMap; symmetric
    /// rejection on the Map side.
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

/// §26.2.1.1 [[Cells]] storage for FinalizationRegistry.
/// `cleanup_callback` is the callable supplied at construction;
/// `cells` holds the live registrations. Cynic's FinalizationRegistry
/// is a strong-ref impl (mirrors WeakMap/WeakSet at `runtime/builtins/
/// collections.zig:7-9` — observable behaviour matches; actual
/// finalisation requires real weak refs). `register` appends; `unregister`
/// flips `deleted = true` so an in-progress walk doesn't shift indices.
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
    /// Per-instance private slots — keyed by the class-identity-
    /// prefixed name produced by the compiler (`P<uid>#name`),
    /// so two unrelated classes both declaring `#x` get distinct
    /// storage. §7.3.27 PrivateElementFind brand-checks via this
    /// map: a lookup miss is a TypeError.
    private_properties: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// Accessor descriptors — getter / setter pairs. Checked
    /// before `properties` on read and write. Walks the prototype
    /// chain like data properties.
    accessors: std.StringArrayHashMapUnmanaged(Accessor) = .empty,
    /// Class instance-field initializers — only meaningful on a
    /// class prototype object. The constructor's
    /// `init_instance_fields` op walks this list, calling each
    /// `init_fn` with `this = current instance` and assigning
    /// the result to `this.name`. `null` on non-prototype
    /// objects.
    instance_field_inits: ?[]const FieldInit = null,
    /// Class private-method registrations — only meaningful on a
    /// class prototype. Each (prefixed_name, fn) pair is
    /// installed on every instance's private_properties at
    /// constructor time, so brand checks succeed and the methods
    /// are callable through `this.#name()`.
    private_method_inits: ?[]const FieldInit = null,
    /// Prototype object for prototype-chain lookups. later
    /// resolves member access through `[[Get]]` (§10.1.8) which
    /// walks this chain when the own property is absent.
    prototype: ?*JSObject = null,
    /// Mark-sweep bit, written by `Heap.markValue` and cleared
    /// after each sweep.
    marked: bool = false,
    /// `[[Extensible]]` (§10.1.2). `false` after
    /// `Object.preventExtensions` / `seal` / `freeze`. New
    /// property writes silently fail when `false`.
    extensible: bool = true,
    /// Boxed primitive — set on objects produced by
    /// `new Number(v)`, `new String(v)`, `new Boolean(v)`.
    /// `[[NumberData]]` / `[[StringData]]` / `[[BooleanData]]`
    /// internal slots collapsed into one tagged Value. ToNumber
    /// / ToString / ToBoolean coercions check this first to
    /// return the underlying primitive.
    boxed_primitive: ?Value = null,
    /// `[[MapData]]` (§24.1.1.1) — only set on `new Map(...)`
    /// instances. Keeps insertion order; lookups use
    /// SameValueZero. later uses linear-scan storage; a hashmap
    /// is a later optimization.
    map_data: ?*MapData = null,
    /// `[[SetData]]` (§24.2.1.1) — same shape as map_data but
    /// values-only.
    set_data: ?*SetData = null,
    /// `[[DateValue]]` (§21.4.1) — milliseconds since Unix
    /// epoch. NaN means an invalid date. Only set on `new Date()`
    /// instances.
    date_ms: ?f64 = null,
    /// Pointer to the underlying `JSGenerator` for objects
    /// returned from a `function*` invocation. The generator's
    /// `next` / `return` / `throw` methods (installed on the
    /// generator-prototype) read this slot to find the saved
    /// frame state to resume.
    generator_ref: ?*@import("generator.zig").JSGenerator = null,
    /// `[[ArrayBufferData]]` (§25.1.1.1) — raw byte buffer.
    /// Owned by the realm allocator; freed at object deinit.
    /// Set on `new ArrayBuffer(N)` instances.
    array_buffer: ?[]u8 = null,
    /// `[[ViewedArrayBuffer]]` + view metadata (§23.2.1).
    /// Set on TypedArray instances. The view borrows bytes
    /// from `viewed.array_buffer` (a separate JSObject).
    typed_view: ?TypedView = null,
    /// `[[ViewedArrayBuffer]]` + offset + length for DataView
    /// instances (§25.3). Borrows bytes from
    /// `data_view.viewed.array_buffer`.
    data_view: ?DataView = null,
    /// `[[StringData]]` (§22.1.3) — the string primitive a
    /// `String` wrapper boxes. Set by `toObjectThis` when
    /// boxing a string primitive for a method call, and by
    /// `new String("…")`. Lets `String.prototype.*` methods
    /// unbox a wrapper receiver in O(1) instead of
    /// reconstructing the bytes from indexed slots.
    boxed_string: ?*@import("string.zig").JSString = null,
    /// Internal async-await waiters for a pending Promise.
    /// Each entry is a `*JSGenerator` representing a suspended
    /// `async function` frame that is awaiting this Promise.
    /// On settlement, each waiter is enqueued as an
    /// `async_resume` microtask. Distinct from user-level
    /// `then` handlers (which use a separate property-bag list)
    /// because waiters bypass the JS-callable layer.
    promise_waiters: std.ArrayListUnmanaged(*@import("generator.zig").JSGenerator) = .empty,
    /// User-level `.then(onFulfilled, onRejected)` reactions
    /// registered on a pending Promise. On settlement, each
    /// reaction is enqueued as a `promise_reaction` microtask
    /// that runs the appropriate handler and settles the
    /// reaction's `result_promise`.
    promise_reactions: std.ArrayListUnmanaged(PromiseReaction) = .empty,
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
    /// §10.5 ProxyCreate — when the original target was callable,
    /// `[[Call]]` is exposed on the proxy regardless of whether
    /// `proxy_target_fn` is currently set. After revocation the
    /// `proxy_target_fn` slot is null, but `typeof` and re-wraps
    /// still need to know the proxy is "callable".
    proxy_callable: bool = false,
    /// §22.2.7 RegExp instance — opaque pointer to the compiled
    /// libregexp bytecode (vendored QuickJS-NG engine). The first
    /// call to `.exec`/`.test` parses the `source` + `flags` and
    /// caches the bytecode here. The runtime owns the allocation.
    regex_bytecode: ?[]u8 = null,
    /// `[[Cells]]` (§26.2.1) — only set on `new FinalizationRegistry(cb)`
    /// instances. Carries the cleanup callback plus the list of
    /// registered cells. Allocated on construction; deinit releases
    /// the storage. The cleanup callback and per-cell values are
    /// strong-rooted via `Heap.markValue` (see `markValue` and
    /// the `finalization_cells` walk there).
    finalization_cells: ?*FinalizationData = null,
    /// §26.1 WeakRef — `[[WeakRefTarget]]` internal slot. Set on
    /// `new WeakRef(target)` instances. `is_weak_ref` is the brand
    /// (`deref.call(plainObj)` must throw a TypeError per §26.1.3.2
    /// even when no target was supplied). `weak_ref_target` holds
    /// the live target Value (Object or non-registered Symbol per
    /// §6.2.10 CanBeHeldWeakly). Cynic's WeakRef is a strong-ref
    /// impl — observable behaviour matches the spec, GC weakness
    /// is later (mirrors WeakMap / WeakSet, see collections.zig).
    is_weak_ref: bool = false,
    weak_ref_target: Value = Value.undefined_,
    /// Heap-allocated JSStrings whose `bytes` slice backs a key
    /// in `properties` / `accessors` / `private_properties` /
    /// `property_flags`. The hash maps store `[]const u8` slices,
    /// not pointers — so without this anchor the JSString gets
    /// swept and the key slice dangles. Static-literal key strings
    /// (constants pool, builtin installation) don't need anchoring;
    /// only keys allocated for `obj[expr] = v` etc. via
    /// `setComputedOwned` land here.
    key_anchors: std.ArrayListUnmanaged(*@import("string.zig").JSString) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*JSObject {
        const o = try allocator.create(JSObject);
        o.* = .{ .kind = .object };
        return o;
    }

    pub fn deinit(self: *JSObject, allocator: std.mem.Allocator) void {
        self.properties.deinit(allocator);
        self.property_flags.deinit(allocator);
        self.private_properties.deinit(allocator);
        self.accessors.deinit(allocator);
        if (self.map_data) |m| m.deinit(allocator);
        if (self.set_data) |s| s.deinit(allocator);
        if (self.finalization_cells) |fc| fc.deinit(allocator);
        if (self.array_buffer) |ab| allocator.free(ab);
        self.promise_waiters.deinit(allocator);
        self.promise_reactions.deinit(allocator);
        self.key_anchors.deinit(allocator);
        // instance_field_inits / private_method_inits are
        // borrowed slices owned by class.zig (allocated against
        // the realm allocator and tracked by the realm); freeing
        // them happens at realm.deinit().
        allocator.destroy(self);
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
        try self.properties.put(allocator, key_str.bytes, v);
        try self.key_anchors.append(allocator, key_str);
    }

    /// Read the (possibly defaulted) descriptor flags for
    /// `key`. Returns `PropertyFlags.default` (all-true) when no
    /// override is recorded.
    pub fn flagsFor(self: *const JSObject, key: []const u8) PropertyFlags {
        return self.property_flags.get(key) orelse PropertyFlags.default;
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
        try self.properties.put(allocator, key, v);
        // Skip the flags entry when the descriptor is the
        // all-true default — keeps the parallel map sparse.
        const is_default =
            flags.writable and flags.enumerable and flags.configurable;
        if (is_default) {
            _ = self.property_flags.swapRemove(key);
        } else {
            try self.property_flags.put(allocator, key, flags);
        }
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
    pub fn set(self: *JSObject, allocator: std.mem.Allocator, key: []const u8, v: Value) !void {
        try self.properties.put(allocator, key, v);
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
        if (self.properties.contains(key)) {
            const flags = self.flagsFor(key);
            if (!flags.writable) return false;
        }
        try self.properties.put(allocator, key, v);
        return true;
    }

    /// `[[Get]]` (§10.1.8) — own-property lookup that walks the
    /// prototype chain. Returns `undefined` when absent.
    pub fn get(self: *const JSObject, key: []const u8) Value {
        if (self.properties.get(key)) |v| return v;
        if (self.prototype) |proto| return proto.get(key);
        return Value.undefined_;
    }

    /// Own-property check — does NOT walk the prototype chain.
    /// Returns true for both data and accessor own properties
    /// (§7.3.13 HasOwnProperty: any descriptor counts).
    pub fn hasOwn(self: *const JSObject, key: []const u8) bool {
        return self.properties.contains(key) or self.accessors.contains(key);
    }

    /// §7.3.12 HasProperty — walks the prototype chain. True iff
    /// `key` resolves to a data or accessor own property anywhere
    /// on the chain. Used by §6.2.5.5 ToPropertyDescriptor (which
    /// distinguishes "field not present" from "field is undefined")
    /// and other specs that observe inherited fields.
    pub fn hasProperty(self: *const JSObject, key: []const u8) bool {
        if (self.properties.contains(key)) return true;
        if (self.accessors.contains(key)) return true;
        if (self.prototype) |proto| return proto.hasProperty(key);
        return false;
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
    float32,
    float64,
    biguint64,
    bigint64,

    pub fn elementSize(k: TypedKind) u8 {
        return switch (k) {
            .int8, .uint8 => 1,
            .int16, .uint16 => 2,
            .int32, .uint32, .float32 => 4,
            .float64, .biguint64, .bigint64 => 8,
        };
    }
};

pub const TypedView = struct {
    kind: TypedKind,
    /// Source ArrayBuffer object — the byte buffer is at
    /// `viewed.array_buffer`. Borrowed pointer.
    viewed: *JSObject,
    byte_offset: usize,
    /// Number of *elements* in the view (not bytes).
    length: usize,
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
    byte_length: usize,
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
