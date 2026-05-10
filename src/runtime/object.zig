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
    /// `length` (§23.1.4) is still a real own property in
    /// `properties`; the indexed-write helpers keep
    /// `properties["length"]` in sync with `elements.items.len`.
    /// `Object.getOwnPropertyDescriptor(arr, "length")` returns a
    /// data descriptor as the spec demands.
    is_array_exotic: bool = false,
    elements: std.ArrayListUnmanaged(Value) = .empty,
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
        self.elements.deinit(allocator);
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
        // §10.4.2 Array exotic — integer-indexed writes land in
        // `elements`. The JSString anchor is unnecessary because
        // the value isn't keyed by the string at all.
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key_str.bytes)) |idx| {
                return self.setIndexed(allocator, idx, v);
            }
        }
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
        // §10.4.2 Array exotic — integer-indexed writes route to
        // `elements`. The descriptor flags are silently ignored
        // for now: indexed slots are always `{w,e,c} = true`
        // (full descriptor support per slot would require
        // promoting indexed-with-flags into a sparse dictionary
        // representation, which is later).
        const is_default =
            flags.writable and flags.enumerable and flags.configurable;
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
                if (self.elements.items.len < new_len) {
                    try self.ensureElementsLen(allocator, new_len);
                    try self.syncLengthProperty(allocator);
                }
                if (idx < self.elements.items.len) {
                    self.elements.items[idx] = Value.hole_;
                }
            }
        }
        try self.properties.put(allocator, key, v);
        // Skip the flags entry when the descriptor is the
        // all-true default — keeps the parallel map sparse.
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
        // §10.4.2 Array exotic — integer-indexed keys land in
        // the packed `elements` vector, unless the slot has been
        // demoted to the named-property bag (descriptor flags
        // override). The bypass `set` skips the writability gate
        // by design (internal installers).
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                if (self.properties.contains(key)) {
                    try self.properties.put(allocator, key, v);
                    return;
                }
                return self.setIndexed(allocator, idx, v);
            }
        }
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
        // §10.4.2 Array exotic — integer-indexed writes go to
        // the packed `elements` vector unless the slot has been
        // descriptor-flag-demoted to the named-property bag, in
        // which case the bag's `writable` gate applies.
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                if (self.properties.contains(key)) {
                    const flags = self.flagsFor(key);
                    if (!flags.writable) return false;
                    try self.properties.put(allocator, key, v);
                    return true;
                }
                try self.setIndexed(allocator, idx, v);
                return true;
            }
        }
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
        // §10.4.2 Array exotic — integer-indexed reads come from
        // `elements`. Holes (§10.4.2.1) fall through to the
        // prototype chain. `length` stays in `properties` and is
        // read by the regular path below.
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                if (idx < self.elements.items.len) {
                    const v = self.elements.items[idx];
                    if (!isElementHole(v)) return v;
                }
            }
        }
        if (self.properties.get(key)) |v| return v;
        if (self.prototype) |proto| return proto.get(key);
        return Value.undefined_;
    }

    /// Own-property check — does NOT walk the prototype chain.
    /// Returns true for both data and accessor own properties
    /// (§7.3.13 HasOwnProperty: any descriptor counts).
    pub fn hasOwn(self: *const JSObject, key: []const u8) bool {
        if (self.properties.contains(key) or self.accessors.contains(key)) return true;
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                return self.hasOwnIndexedSlot(idx);
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
        if (self.properties.contains(key)) return true;
        if (self.accessors.contains(key)) return true;
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                if (self.hasOwnIndexedSlot(idx)) return true;
            }
        }
        if (self.prototype) |proto| return proto.hasProperty(key);
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

    /// Indexed read — own only; does NOT walk the prototype
    /// chain. Returns `undefined` for out-of-range or hole.
    /// (§10.4.2.1 step 2 — a hole on an Array exotic delegates
    /// up the prototype chain via the caller.)
    pub fn getIndexed(self: *const JSObject, idx: u32) Value {
        if (idx >= self.elements.items.len) return Value.undefined_;
        const v = self.elements.items[idx];
        if (isElementHole(v)) return Value.undefined_;
        return v;
    }

    /// §10.4.2.1 — an Array exotic's indexed slot is an own
    /// property iff it's been written (the slot is not a hole).
    /// `[0,,2]` leaves slot 1 as a hole; `arr[1] = undefined`
    /// turns slot 1 into a real own property whose value is
    /// `undefined`. The two are distinguishable here via the
    /// `Value.hole_` sentinel re-used from the TDZ encoding.
    pub fn hasOwnIndexedSlot(self: *const JSObject, idx: u32) bool {
        if (idx >= self.elements.items.len) return false;
        return !isElementHole(self.elements.items[idx]);
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
    /// `idx`, growing `elements` (padding with `undefined`) and
    /// updating `length` so `length === idx + 1` whenever
    /// `idx >= length`.
    pub fn setIndexed(
        self: *JSObject,
        allocator: std.mem.Allocator,
        idx: u32,
        v: Value,
    ) !void {
        const new_len: usize = @as(usize, idx) + 1;
        try self.ensureElementsLen(allocator, new_len);
        self.elements.items[idx] = v;
        try self.syncLengthProperty(allocator);
    }

    /// Grow `elements` to `new_len`, filling any new slots with
    /// the hole sentinel (§10.4.2.1 — sparse holes are NOT own
    /// properties; reads fall through to the prototype chain).
    /// No-op if already big enough.
    fn ensureElementsLen(self: *JSObject, allocator: std.mem.Allocator, new_len: usize) !void {
        const old_len = self.elements.items.len;
        if (new_len <= old_len) return;
        try self.elements.resize(allocator, new_len);
        var i = old_len;
        while (i < new_len) : (i += 1) {
            self.elements.items[i] = Value.hole_;
        }
    }

    /// Write `length === elements.items.len` into `properties`.
    /// Called from every indexed mutator so the data property
    /// stays in sync with the vector's true size.
    pub fn syncLengthProperty(self: *JSObject, allocator: std.mem.Allocator) !void {
        const len_now: u64 = @intCast(self.elements.items.len);
        const len_v: Value = if (len_now <= std.math.maxInt(i32))
            Value.fromInt32(@intCast(len_now))
        else
            Value.fromDouble(@floatFromInt(len_now));
        try self.properties.put(allocator, "length", len_v);
    }

    /// Truncate the elements vector to `new_len`. Used by
    /// §10.4.2.4 ArraySetLength and the `length`-write fast path.
    /// Returns `false` on the first non-configurable element
    /// from the right (spec sets length to that index + 1 and
    /// throws TypeError in strict mode). Today every indexed
    /// slot is implicitly configurable; the return is wired for
    /// the future when `Object.defineProperty(arr, "0", {configurable: false})`
    /// promotes a slot into the named-property bag.
    pub fn truncateIndexed(self: *JSObject, allocator: std.mem.Allocator, new_len: u32) !bool {
        const cur: usize = self.elements.items.len;
        const want: usize = new_len;
        if (want >= cur) return true;
        try self.elements.resize(allocator, want);
        return true;
    }

    /// §10.4.2.4 ArraySetLength — set the array length to
    /// `new_len`, truncating `elements` if shrinking and
    /// growing-with-holes if expanding. Caller is responsible
    /// for the length-writability gate (§10.4.2.4 step 4); this
    /// helper is the storage-level effect.
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
        const cur_len = self.elements.items.len;
        if (new_len < cur_len) {
            try self.elements.resize(allocator, new_len);
        } else if (new_len > cur_len) {
            try self.ensureElementsLen(allocator, new_len);
        }
        try self.syncLengthProperty(allocator);
    }

    /// §10.4.2 — flip an already-allocated JSObject into an
    /// Array exotic. Called from the centralised `allocateArray`
    /// path and from any site that allocated a fresh JSObject
    /// and is about to chain it to `%Array.prototype%`. Sets the
    /// flag, installs `length: 0` with §23.1.4 flags, and is a
    /// no-op if already an array exotic.
    pub fn markAsArrayExotic(self: *JSObject, allocator: std.mem.Allocator) !void {
        if (self.is_array_exotic) return;
        self.is_array_exotic = true;
        try self.setWithFlags(allocator, "length", Value.fromInt32(0), .{
            .writable = true,
            .enumerable = false,
            .configurable = false,
        });
    }

    /// Drop the indexed slot at `idx` — sets it to the hole
    /// sentinel so a subsequent read falls through to the
    /// prototype chain (§13.5.1.2 [[Delete]] step 5: leaves
    /// length alone, just removes the own property).
    pub fn removeIndexed(self: *JSObject, idx: u32) bool {
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
    pub fn deleteOwn(self: *JSObject, key: []const u8) bool {
        if (self.is_array_exotic) {
            if (canonicalIntegerIndex(key)) |idx| {
                _ = self.removeIndexed(idx);
                if (self.properties.contains(key)) {
                    const flags = self.property_flags.get(key) orelse PropertyFlags.default;
                    if (!flags.configurable) return false;
                    _ = self.properties.swapRemove(key);
                    _ = self.property_flags.swapRemove(key);
                }
                return true;
            }
        }
        if (self.accessors.contains(key)) {
            _ = self.accessors.swapRemove(key);
            _ = self.property_flags.swapRemove(key);
            return true;
        }
        if (!self.properties.contains(key)) return true;
        _ = self.properties.swapRemove(key);
        _ = self.property_flags.swapRemove(key);
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
