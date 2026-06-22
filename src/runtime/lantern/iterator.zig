//! Iterator opening + for-in walker — extracted from `interpreter.zig`
//! to keep the dispatch-loop file focused.
//!
//! Hosts the `IterError` set, the §7.4.2 GetIterator family
//! (`openIterator`, `openIteratorAllowArrayLike`,
//! `openIteratorOpts`, `openAsyncIterator`), the §14.7.5.6
//! EnumerateObjectProperties walker (`openForInIterator`), and
//! the `arrayLikeIterNext` native callback used by the array-
//! like fallback iterator's `next` slot.
//!
//! Each public entry calls back into interpreter.zig for
//! `callJSFunction` (the dispatch-loop entry the iterator's
//! `@@iterator` method invocation routes through).

const std = @import("std");

const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSFunction = @import("../function.zig").JSFunction;
const object_mod = @import("../object.zig");
const JSObject = object_mod.JSObject;
const heap_mod = @import("../heap.zig");
const intrinsics_mod = @import("../intrinsics.zig");
const Realm = @import("../realm.zig").Realm;

// Circular back to interpreter.zig for the dispatch entry point the
// iterator setup routes user `@@iterator` method calls through.
const lantern = @import("interpreter.zig");
const callJSFunction = lantern.callJSFunction;
const RunError = lantern.RunError;
const helpers = @import("helpers.zig");
const canonicalIntegerIndexInterp = helpers.canonicalIntegerIndexInterp;

pub const IterError = error{
    OutOfMemory,
    NotIterable,
    InvalidOpcode,
    /// Iterator-setup observed user code (an accessor getter, a
    /// `next` method call, etc.) that threw. The thrown value
    /// lives in `realm.pending_exception`; the caller must
    /// propagate it instead of synthesising "value is not
    /// iterable" TypeError. §27.1.4.3 GetIterator step 1.a
    /// (`GetMethod` throws) and step 1.b.i (sync fallback
    /// throws) both surface here.
    Propagated,
};

/// §7.4.1 GetIterator. Produce an iterator object for an
/// iterable. Tries the `@@iterator` method first; falls back to
/// an array-like length+index walk so existing arrays / strings
/// still iterate without forcing every host to install a real
/// `@@iterator` on `Array.prototype` / `String.prototype`. The
/// fallback is observably correct (returns `{value, done}` from
/// `.next()`) for the test262 surface that just calls `for-of`
/// over arrays.
/// §27.1.4.3 GetIterator(obj, async) — async variant. Prefers
/// `@@asyncIterator`; if absent, falls back to the sync
/// `@@iterator` (or the array-like-length walk). The for-await
/// step path awaits each `.next()` result, so a sync iterator
/// produces a resolved promise per step automatically via the
/// `await_` opcode.
pub fn openAsyncIterator(
    _: std.mem.Allocator,
    realm: *Realm,
    iterable: Value,
) IterError!Value {
    if (heap_mod.valueAsPlainObject(iterable)) |obj| {
        // §27.1.4.3 step 1.a — GetMethod(obj, @@asyncIterator).
        // Use `getPropertyChain` (accessor-aware); a thrown getter
        // propagates as `Propagated` so the caller hands the
        // user's exception value back instead of synthesising
        // "not async iterable".
        const iter_fn_v = intrinsics_mod.getPropertyChain(realm, obj, "@@asyncIterator") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Propagated,
        };
        // §27.1.4.3 step 1.b — method is undefined → fall through
        // to the sync iterator. A callable (function) goes through
        // the async branch.
        if (!iter_fn_v.isUndefined() and !iter_fn_v.isNull()) {
            const iter_fn = heap_mod.valueAsFunction(iter_fn_v) orelse return error.NotIterable;
            const result = callJSFunction(realm.allocator, realm, iter_fn, iterable, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidOpcode,
            };
            switch (result) {
                .value, .yielded => |v| {
                    // §7.4.2 GetIteratorDirect step 3 — the
                    // returned value must be an Object.
                    if (heap_mod.valueAsPlainObject(v) == null) return error.NotIterable;
                    return v;
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.Propagated;
                },
            }
        }
    }
    // §27.1.4.3 step 1.b — fall back to sync `@@iterator`,
    // then wrap with §27.6.1.1 CreateAsyncFromSyncIterator so
    // each `.next()` / `.return()` / `.throw()` returns a fresh
    // Promise per §27.6.1.{2,3,4}.
    const sync_iter = try openIterator(realm.allocator, realm, iterable);
    const afsi = @import("../builtins/async_iterator.zig");
    return afsi.createAsyncFromSyncIterator(realm, sync_iter) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub fn openIterator(
    allocator: std.mem.Allocator,
    realm: *Realm,
    iterable: Value,
) IterError!Value {
    return openIteratorOpts(allocator, realm, iterable, .{});
}

/// Open an iterator with an array-like fallback enabled — used
/// only by callers that legitimately want it (String iterator
/// impl, internal for-in snapshot wrapping). Per §7.4.2, the
/// for-of / array-destructuring / spread paths must reject
/// non-iterable array-likes; those callers use `openIterator`.
pub fn openIteratorAllowArrayLike(
    allocator: std.mem.Allocator,
    realm: *Realm,
    iterable: Value,
) IterError!Value {
    return openIteratorOpts(allocator, realm, iterable, .{ .allow_array_like = true });
}

pub const OpenIterOpts = struct {
    /// When true, fall through to a synth array-like iterator if
    /// the iterable has no `@@iterator` but does have `.length`.
    /// Non-spec for `for-of` / destructuring / spread; spec-correct
    /// for String's own `@@iterator` and for internal snapshots
    /// where the caller built the array themselves.
    allow_array_like: bool = false,
};

pub fn openIteratorOpts(
    _: std.mem.Allocator,
    realm: *Realm,
    iterable: Value,
    opts: OpenIterOpts,
) IterError!Value {
    // 1. If iterable carries `@@iterator`, invoke it with the
    // iterable as `this`. The well-known-symbol key is
    // represented by the literal string `"@@iterator"` until
    // Symbol becomes a Value-tag primitive.
    //
    // §7.4.2 GetIterator implicitly ToObject's the receiver
    // (via §7.3.11 GetMethod → §7.3.3 GetV); a primitive String
    // therefore consults `String.prototype[@@iterator]`. We
    // mirror that by routing primitive strings through the
    // shared String prototype lookup instead of always falling
    // through to the array-like fallback.
    if (iterable.isString()) {
        if (realm.intrinsics.string_prototype) |sp| {
            const iter_fn_v = intrinsics_mod.getPropertyChain(realm, sp, "@@iterator") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Propagated,
            };
            if (!iter_fn_v.isUndefined() and !iter_fn_v.isNull()) {
                const iter_fn = heap_mod.valueAsFunction(iter_fn_v) orelse return error.NotIterable;
                const result = callJSFunction(realm.allocator, realm, iter_fn, iterable, &.{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidOpcode,
                };
                switch (result) {
                    .value, .yielded => |v| {
                        if (heap_mod.valueAsPlainObject(v) == null) return error.NotIterable;
                        return v;
                    },
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.Propagated;
                    },
                }
            }
        }
    }
    // §7.4.2 GetIterator on primitive Boolean / Number / BigInt /
    // Symbol — the spec ToObject's the receiver, so a user-
    // installed `Boolean.prototype[Symbol.iterator]` is reachable
    // (test262 `language/expressions/yield/star-in-rltn-expr.js`).
    // Mirror the String branch above: route the lookup through
    // the wrapper prototype and call with the primitive as `this`.
    if (iterable.isBool() or iterable.isInt32() or iterable.isDouble() or
        heap_mod.isBigInt(iterable) or heap_mod.isSymbol(iterable))
    {
        if (intrinsics_mod.lookupPrimitivePrototype(realm, iterable)) |wp| {
            const iter_fn_v = intrinsics_mod.getPropertyChain(realm, wp, "@@iterator") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Propagated,
            };
            if (!iter_fn_v.isUndefined() and !iter_fn_v.isNull()) {
                const iter_fn = heap_mod.valueAsFunction(iter_fn_v) orelse return error.NotIterable;
                const result = callJSFunction(realm.allocator, realm, iter_fn, iterable, &.{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidOpcode,
                };
                switch (result) {
                    .value, .yielded => |v| {
                        if (heap_mod.valueAsPlainObject(v) == null) return error.NotIterable;
                        return v;
                    },
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.Propagated;
                    },
                }
            }
        }
    }
    if (heap_mod.valueAsPlainObject(iterable)) |obj| {
        // §7.4.2 GetIterator — accessor-aware so a `get
        // [Symbol.iterator]() { throw … }` style fixture
        // propagates the user exception instead of being
        // squashed to "not iterable".
        const iter_fn_v = intrinsics_mod.getPropertyChain(realm, obj, "@@iterator") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Propagated,
        };
        if (!iter_fn_v.isUndefined() and !iter_fn_v.isNull()) {
            const iter_fn = heap_mod.valueAsFunction(iter_fn_v) orelse return error.NotIterable;
            const result = callJSFunction(realm.allocator, realm, iter_fn, iterable, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidOpcode,
            };
            switch (result) {
                .value, .yielded => |v| {
                    if (heap_mod.valueAsPlainObject(v) == null) return error.NotIterable;
                    return v;
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.Propagated;
                },
            }
        }
    }

    // §7.4.2 step 8 — `if method is undefined, throw a TypeError`.
    // The array-like fallback below is non-spec; gated on opts.
    if (!opts.allow_array_like) return error.NotIterable;

    // 2. Array-like fallback. Builds a plain object with a
    // `next` method that walks `iterable[i]` for `i` in
    // `0..length`. The cursor + target live on the typed
    // `array_like_iter` slot (hidden from JS), mirroring the
    // spec's [[IteratedObject]] + [[NextIndex]] internal slots.
    const has_length = if (heap_mod.valueAsPlainObject(iterable)) |o|
        o.hasOwn("length") or (o.prototype != null and !o.get("length").isUndefined())
    else
        iterable.isString();
    if (!has_length) return error.NotIterable;

    const iter = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(iter, realm.intrinsics.object_prototype);
    const state = realm.allocator.create(object_mod.ArrayLikeIterState) catch return error.OutOfMemory;
    state.* = .{ .target = iterable };
    iter.array_like_iter = state;
    iter.markNonPristine();
    iter.noteInternalSlotWrite(); // card-mark: array_like_iter holds young target/source
    const next_fn = realm.heap.allocateFunctionNative(realm, arrayLikeIterNext, 0, "next") catch return error.OutOfMemory;
    next_fn.proto = realm.intrinsics.function_prototype;
    iter.set(realm.allocator, "next", heap_mod.taggedFunction(next_fn)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(iter);
}

/// §14.7.5.6 EnumerateObjectProperties. Walks the object's
/// own + inherited enumerable string-keyed properties
/// (deduplicated, prototype-chain-ordered) and produces an
/// iterator over the snapshot. `null` / `undefined` yield an
/// empty iterator.
///
/// Now (later) consults each property's
/// `PropertyFlags.enumerable` — built-in proto methods install
/// with `enumerable: false`, so user-level for-in correctly
/// skips `Array.prototype.push`, `Object.prototype.toString`,
/// etc. Cynic-internal sentinel properties (those whose name
/// starts with `__cynic_`) are also skipped.
pub fn openForInIterator(
    allocator: std.mem.Allocator,
    realm: *Realm,
    obj_v: Value,
) RunError!Value {
    const arr = try buildForInSnapshot(allocator, realm, obj_v);
    return wrapForInSnapshot(realm, arr, obj_v);
}

/// Build the §14.7.5.6 key-snapshot array for `obj_v` WITHOUT wrapping
/// it in an iterator. `openForInIterator` is `wrapForInSnapshot` over
/// this; the `for_in_open` enumeration cache caches the returned
/// `*JSObject` so a re-entry over a stable object serves a fresh
/// iterator without re-walking the keys.
///
/// The cache only fills from this with a fill-eligible receiver (plain
/// shape-mode object, frozen one-level proto, no integer elements), but
/// the walk itself is the general §14.7.5.6 one — the array is correct
/// for any receiver; the gate is purely a soundness-of-reuse filter.
pub fn buildForInSnapshot(
    _: std.mem.Allocator,
    realm: *Realm,
    obj_v: Value,
) RunError!*JSObject {
    const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(arr, realm.intrinsics.array_prototype);
    arr.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(realm.allocator);

    var len: i32 = 0;
    // §10.1.11 — for-in over a Function receiver (e.g. a class
    // constructor with static fields) walks its own properties
    // first, then climbs `proto`. Mirror the JSObject branch
    // below for the function representation.
    if (heap_mod.valueAsFunction(obj_v)) |fn_obj| {
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            // §14.7.5.9 EnumerateObjectProperties — String keys only; skip
            // the flattened Symbol keys (`@@<name>` / `<sym:N>`).
            if (std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:")) continue;
            if (!fn_obj.flagsForOwn(key).enumerable) continue;
            const gop = seen.getOrPut(realm.allocator, key) catch return error.OutOfMemory;
            if (gop.found_existing) continue;
            const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
            realm.heap.storeElement(arr, realm.allocator, @intCast(len), Value.fromString(key_owned)) catch return error.OutOfMemory;
            len += 1;
        }
        // §14.7.5.6 EnumerateObjectProperties step 5 — climb the
        // [[Prototype]] chain after the function's own properties.
        // Stock `%Function.prototype%` methods are all non-
        // enumerable, but a user `Object.defineProperty(
        // Function.prototype, "x", {enumerable: true})` adds an
        // enumerable inherited key that for-in must surface
        // (test262 built-ins/Object/defineProperty/15.2.3.6-4-419.js,
        // /15.2.3.6-4-595.js — same shape on bound functions). The
        // function's [[Prototype]] is the bound-function proto for
        // a bound function, else `%Function.prototype%`.
        var current_proto: ?*JSObject = fn_obj.proto;
        while (current_proto) |cur| {
            var pit = cur.iterOwnNamedKeys();
            while (pit.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                if (std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:")) continue;
                const gop = seen.getOrPut(realm.allocator, key) catch return error.OutOfMemory;
                if (gop.found_existing) continue;
                if (!cur.flagsFor(key).enumerable) continue;
                const k_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
                realm.heap.storeElement(arr, realm.allocator, @intCast(len), Value.fromString(k_owned)) catch return error.OutOfMemory;
                len += 1;
            }
            // §14.7.5.6 also surfaces accessor properties; mark them
            // seen so a same-named ancestor data property doesn't
            // re-emit (shadowing rule).
            if (cur.accessorIterator()) |ait_outer| {
                var ait = ait_outer;
                while (ait.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                    if (std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:")) continue;
                    const gop = seen.getOrPut(realm.allocator, key) catch return error.OutOfMemory;
                    if (gop.found_existing) continue;
                    if (!cur.flagsFor(key).enumerable) continue;
                    const k_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
                    realm.heap.storeElement(arr, realm.allocator, @intCast(len), Value.fromString(k_owned)) catch return error.OutOfMemory;
                    len += 1;
                }
            }
            current_proto = cur.prototype;
        }
    } else if (heap_mod.valueAsPlainObject(obj_v)) |start_obj| {
        var current: ?*JSObject = start_obj;
        while (current) |cur| {
            // §14.7.5.6 EnumerateObjectProperties — for a Proxy
            // exotic, call `[[OwnPropertyKeys]]` (which dispatches
            // the `ownKeys` trap or falls through to the target)
            // and filter by `[[GetOwnProperty]].[[Enumerable]]`
            // (which dispatches the `getOwnPropertyDescriptor`
            // trap). We materialise both via the helpers in
            // builtins/object.zig.
            if (cur.proxy_target != null or cur.proxy_target_fn != null or cur.proxy_revoked) {
                const obj_mod = @import("../builtins/object.zig");
                const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
                defer key_scope.close();
                if (obj_mod.proxyOwnKeysOrNull(realm, cur, key_scope)) |maybe_keys| {
                    if (maybe_keys) |keys| {
                        defer realm.allocator.free(keys);
                        for (keys) |k| {
                            // Skip Symbol keys — for-in is string-keyed only.
                            if (std.mem.startsWith(u8, k, "@@") or std.mem.startsWith(u8, k, "<sym:")) continue;
                            if (seen.contains(k)) continue;
                            // Probe enumerability via Object.getOwnPropertyDescriptor.
                            const key_str = realm.heap.allocateString(k) catch return error.OutOfMemory;
                            const probe_args = [_]Value{ heap_mod.taggedObject(cur), Value.fromString(key_str) };
                            const desc_v = obj_mod.objectGetOwnPropertyDescriptor(realm, Value.undefined_, &probe_args) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                error.NativeThrew => {
                                    realm.pending_exception = null;
                                    continue;
                                },
                            };
                            const enum_ok = blk: {
                                if (desc_v.isUndefined()) break :blk false;
                                if (heap_mod.valueAsPlainObject(desc_v)) |desc_obj| {
                                    const arith_mod = @import("arith.zig");
                                    break :blk arith_mod.toBoolean(desc_obj.get("enumerable"));
                                }
                                break :blk false;
                            };
                            const gop = seen.getOrPut(realm.allocator, k) catch return error.OutOfMemory;
                            if (gop.found_existing) continue;
                            if (!enum_ok) continue;
                            const k_owned = realm.heap.allocateString(k) catch return error.OutOfMemory;
                            realm.heap.storeElement(arr, realm.allocator, @intCast(len), Value.fromString(k_owned)) catch return error.OutOfMemory;
                            len += 1;
                        }
                    }
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NativeThrew => {
                        realm.pending_exception = null;
                    },
                }
                // Walk to the prototype (§14.7.5.6 step 6) — the
                // proxy's `getPrototypeOf` trap would intervene but
                // for now we just read `cur.prototype`.
                current = cur.prototype;
                continue;
            }
            // §10.1.11 — within each level, integer-indexed
            // keys come first in ascending numeric order, then
            // string keys in insertion order. Symbol keys
            // would sort last.
            const KeyEntry = struct { idx: u32, key: []const u8 };
            var int_keys: std.ArrayListUnmanaged(KeyEntry) = .empty;
            defer int_keys.deinit(realm.allocator);
            var str_keys: std.ArrayListUnmanaged([]const u8) = .empty;
            defer str_keys.deinit(realm.allocator);

            // §10.4.2 Array exotic — packed elements are own
            // integer-indexed properties for §14.7.5.6
            // EnumerateObjectProperties / `for-in` / `Object.keys`.
            // Holes (slot == hole sentinel) are either absent
            // (sparse) or descriptor-flag-demoted to the named-
            // property bag; the property-bag walker below picks
            // up the latter, so we skip them here either way.
            if (cur.is_array_exotic) {
                if (cur.is_sparse) {
                    var sit = cur.sparse_elements.iterator();
                    while (sit.next()) |entry| {
                        if (@import("../object.zig").JSObject.isElementHole(entry.value_ptr.*)) continue;
                        const idx = entry.key_ptr.*;
                        var ibuf: [16]u8 = undefined;
                        const ks = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch continue;
                        const key_owned_str = realm.heap.allocateString(ks) catch return error.OutOfMemory;
                        int_keys.append(realm.allocator, .{ .idx = idx, .key = key_owned_str.flatBytes() }) catch return error.OutOfMemory;
                    }
                } else {
                    var ei: u32 = 0;
                    while (ei < cur.elements.items.len) : (ei += 1) {
                        if (@import("../object.zig").JSObject.isElementHole(cur.elements.items[ei])) continue;
                        var ibuf: [16]u8 = undefined;
                        const ks = std.fmt.bufPrint(&ibuf, "{d}", .{ei}) catch continue;
                        const key_owned_str = realm.heap.allocateString(ks) catch return error.OutOfMemory;
                        int_keys.append(realm.allocator, .{ .idx = ei, .key = key_owned_str.flatBytes() }) catch return error.OutOfMemory;
                    }
                }
            }

            // §10.4.5.x IntegerIndexedExoticObject — for-in over a
            // TypedArray enumerates its in-bounds indices `[0,
            // [[ArrayLength]])` as own enumerable string keys.
            // Length comes from the LIVE buffer-witness count so a
            // length-tracking view (or a fixed-length view shrunk
            // OOB) reports the current state, not its snapshot.
            if (cur.getTypedView()) |tv| {
                const buf_opt = tv.viewed.getArrayBuffer();
                const live_len: u32 = blk: {
                    const buf = buf_opt orelse break :blk 0;
                    const elem_size = tv.kind.elementSize();
                    if (tv.length_tracking) {
                        if (tv.byte_offset > buf.len) break :blk 0;
                        break :blk @intCast((buf.len - tv.byte_offset) / elem_size);
                    }
                    if (tv.byte_offset + tv.length * elem_size > buf.len) break :blk 0;
                    break :blk @intCast(tv.length);
                };
                var ti: u32 = 0;
                while (ti < live_len) : (ti += 1) {
                    var ibuf: [16]u8 = undefined;
                    const ks = std.fmt.bufPrint(&ibuf, "{d}", .{ti}) catch continue;
                    const key_owned_str = realm.heap.allocateString(ks) catch return error.OutOfMemory;
                    int_keys.append(realm.allocator, .{ .idx = ti, .key = key_owned_str.flatBytes() }) catch return error.OutOfMemory;
                }
            }

            // §14.7.5.6 EnumerateObjectProperties — at each level
            // we shadow non-enumerable own keys against the
            // prototype chain. So we collect all own keys (to
            // populate `seen`) but only emit the enumerable ones.
            // `shadow_only` carries own-but-non-enumerable names so
            // they get added to `seen` after emission without ever
            // being yielded themselves.
            //
            // §10.1.11 OrdinaryOwnPropertyKeys orders String keys
            // in *unified* property-creation order (data + accessor
            // slots merged into one chronological list). Walk
            // `own_key_order` first so a key whose descriptor flipped
            // data ↔ accessor keeps its original slot — without this,
            // iterating `properties` then `accessors` separately
            // surfaced `b` (data) before `a` (accessor) even though
            // `a` was created first (test262
            // language/statements/for-in/order-after-define-property).
            var shadow_only: std.ArrayListUnmanaged([]const u8) = .empty;
            defer shadow_only.deinit(realm.allocator);
            var emitted_str: std.StringHashMapUnmanaged(void) = .empty;
            defer emitted_str.deinit(realm.allocator);
            var key_iter = cur.ownKeyOrderIterator();
            while (key_iter.next()) |key| {
                if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                // §14.7.5.9 — String keys only; skip flattened Symbols.
                if (std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:")) continue;
                // Liveness: skip if neither map carries the key
                // anymore (a delete path could leave a phantom entry).
                if (!cur.ownDataContains(key) and !cur.hasAccessor(key)) continue;
                if (!cur.flagsFor(key).enumerable) {
                    shadow_only.append(realm.allocator, key) catch return error.OutOfMemory;
                    continue;
                }
                if (canonicalIntegerIndexInterp(key)) |i| {
                    int_keys.append(realm.allocator, .{ .idx = i, .key = key }) catch return error.OutOfMemory;
                } else {
                    str_keys.append(realm.allocator, key) catch return error.OutOfMemory;
                }
                emitted_str.put(realm.allocator, key, {}) catch return error.OutOfMemory;
            }
            // Defensive sweep — any properties / accessors entries
            // not recorded in `own_key_order` (e.g. built-in
            // installers that bypass `recordKey`). Map iteration is
            // insertion-ordered for determinism.
            var it = cur.iterOwnNamedKeys();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                // §14.7.5.9 — String keys only; skip flattened Symbols.
                if (std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:")) continue;
                if (emitted_str.contains(key)) continue;
                if (!cur.flagsFor(key).enumerable) {
                    shadow_only.append(realm.allocator, key) catch return error.OutOfMemory;
                    continue;
                }
                if (canonicalIntegerIndexInterp(key)) |i| {
                    int_keys.append(realm.allocator, .{ .idx = i, .key = key }) catch return error.OutOfMemory;
                } else {
                    str_keys.append(realm.allocator, key) catch return error.OutOfMemory;
                }
            }
            if (cur.accessorIterator()) |ait_outer| {
                var ait = ait_outer;
                while (ait.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                    // §14.7.5.9 — String keys only; skip flattened Symbols.
                    if (std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:")) continue;
                    if (emitted_str.contains(key)) continue;
                    if (cur.ownDataContains(key)) continue;
                    if (!cur.flagsFor(key).enumerable) {
                        shadow_only.append(realm.allocator, key) catch return error.OutOfMemory;
                        continue;
                    }
                    if (canonicalIntegerIndexInterp(key)) |i| {
                        int_keys.append(realm.allocator, .{ .idx = i, .key = key }) catch return error.OutOfMemory;
                    } else {
                        str_keys.append(realm.allocator, key) catch return error.OutOfMemory;
                    }
                }
            }
            std.mem.sort(KeyEntry, int_keys.items, {}, struct {
                fn lessThan(_: void, a: KeyEntry, b: KeyEntry) bool {
                    return a.idx < b.idx;
                }
            }.lessThan);

            for (int_keys.items) |e| {
                if (seen.contains(e.key)) continue;
                seen.put(realm.allocator, e.key, {}) catch return error.OutOfMemory;
                const key_owned = realm.heap.allocateString(e.key) catch return error.OutOfMemory;
                realm.heap.storeElement(arr, realm.allocator, @intCast(len), Value.fromString(key_owned)) catch return error.OutOfMemory;
                len += 1;
            }
            for (str_keys.items) |key| {
                if (seen.contains(key)) continue;
                seen.put(realm.allocator, key, {}) catch return error.OutOfMemory;
                const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
                realm.heap.storeElement(arr, realm.allocator, @intCast(len), Value.fromString(key_owned)) catch return error.OutOfMemory;
                len += 1;
            }
            // §14.7.5.6 — own-but-non-enumerable names shadow
            // prototype-side enumerable names of the same key.
            // Add them to `seen` so the upper levels skip them.
            for (shadow_only.items) |key| {
                _ = seen.getOrPut(realm.allocator, key) catch return error.OutOfMemory;
            }
            current = cur.prototype;
        }
    }
    arr.set(realm.allocator, "length", Value.fromInt32(len)) catch return error.OutOfMemory;

    return arr;
}

/// Wrap an already-built §14.7.5.6 key-snapshot array in a fresh
/// for-in iterator. Used by both the cold build (`openForInIterator`)
/// and the `for_in_open` enumeration-cache hit. `source_v` is the
/// original for-in target, stashed on the iterator state so
/// `arrayLikeIterNext` can run §14.7.5.6's live-deletion check
/// ("a property deleted before it is visited is not visited"). The
/// array itself is never mutated, so a cached array is safe to wrap
/// repeatedly.
pub fn wrapForInSnapshot(
    realm: *Realm,
    arr: *JSObject,
    source_v: Value,
) RunError!Value {
    // Build a direct array-like iterator over the snapshot
    // rather than going through %Array.prototype%[@@iterator],
    // because we need to stash the original source on the
    // iterator state for §14.7.5.6's live-deletion check.
    const iter = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(iter, realm.intrinsics.object_prototype);
    const state = realm.allocator.create(@import("../object.zig").ArrayLikeIterState) catch return error.OutOfMemory;
    state.* = .{ .target = heap_mod.taggedObject(arr), .idx = 0, .done = false, .for_in_source = source_v };
    iter.array_like_iter = state;
    iter.markNonPristine();
    iter.noteInternalSlotWrite(); // card-mark: array_like_iter holds young target/source
    const next_fn = realm.heap.allocateFunctionNative(realm, arrayLikeIterNext, 0, "next") catch return error.OutOfMemory;
    next_fn.proto = realm.intrinsics.function_prototype;
    iter.set(realm.allocator, "next", heap_mod.taggedFunction(next_fn)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(iter);
}

/// `next()` for the synthesised array-like iterator. Reads
/// `[[IteratedObject]][idx]`, increments `idx`, returns
/// `{value, done}`. Done when `idx >= length`. Iterator state
/// lives on the typed `array_like_iter` slot (hidden from JS).
///
/// Strings get per-codepoint walking per §22.1.5.1
/// `String.prototype[@@iterator]` — `idx` is the byte offset
/// into the WTF-8 backing storage, advanced by the length of
/// the leading-byte's encoded sequence. The yielded value is
/// a fresh string containing exactly the codepoint's bytes
/// (1 byte for ASCII, 4 bytes for an astral codepoint, 3 bytes
/// for a lone surrogate stored as WTF-8). Done when `idx >=
/// bytes.len`.
fn arrayLikeIterNext(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    _ = args;
    const iter_obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const state = iter_obj.array_like_iter orelse return error.NativeThrew;
    const target = state.target;
    const idx: u32 = state.idx;

    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(result, realm.intrinsics.object_prototype);

    if (target.isString()) {
        const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(target.asString()));
        const start: usize = idx;
        if (start >= s.flatBytes().len) {
            result.set(realm.allocator, "value", Value.undefined_) catch return error.OutOfMemory;
            result.set(realm.allocator, "done", Value.true_) catch return error.OutOfMemory;
            state.done = true;
            return heap_mod.taggedObject(result);
        }
        const b0 = s.flatBytes()[start];
        // Decode the leading-byte width — UTF-8 (and WTF-8) sequence
        // lengths are 1/2/3/4 by the high bits of b0. We accept
        // anything well-formed AND lone-surrogate 3-byte sequences
        // (0xED 0xA0..0xBF 0x80..0xBF). Malformed bytes fall back
        // to single-byte advance so we don't loop forever.
        var width: usize = 1;
        if (b0 < 0x80) {
            width = 1;
        } else if (b0 & 0xE0 == 0xC0) {
            width = 2;
        } else if (b0 & 0xF0 == 0xE0) {
            width = 3;
        } else if (b0 & 0xF8 == 0xF0) {
            width = 4;
        }
        if (start + width > s.flatBytes().len) width = 1;
        const sub = realm.heap.allocateString(s.flatBytes()[start .. start + width]) catch return error.OutOfMemory;
        result.set(realm.allocator, "value", Value.fromString(sub)) catch return error.OutOfMemory;
        result.set(realm.allocator, "done", Value.false_) catch return error.OutOfMemory;
        state.idx = idx + @as(u32, @intCast(width));
        return heap_mod.taggedObject(result);
    }

    // Length: from `target.length` if it's an object.
    var length: i32 = 0;
    if (heap_mod.valueAsPlainObject(target)) |obj| {
        const len_v = obj.get("length");
        if (len_v.isInt32()) length = len_v.asInt32() else if (len_v.isDouble()) length = @intFromFloat(len_v.asDouble());
    }

    // §14.7.5.6 — for-in: advance past keys that have been
    // deleted on the source object since the snapshot was
    // taken. Other consumers (Array.from, etc.) leave
    // for_in_source undefined and skip this branch.
    const has_source = !state.for_in_source.isUndefined();
    var cursor: u32 = idx;
    while (true) {
        if (@as(i64, cursor) >= length) {
            result.set(realm.allocator, "value", Value.undefined_) catch return error.OutOfMemory;
            result.set(realm.allocator, "done", Value.true_) catch return error.OutOfMemory;
            state.done = true;
            state.idx = cursor;
            return heap_mod.taggedObject(result);
        }
        var elem: Value = Value.undefined_;
        if (heap_mod.valueAsPlainObject(target)) |obj| {
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{cursor}) catch unreachable;
            elem = obj.get(islice);
        }
        if (has_source) {
            // Live-check the key on the original source object.
            // The snapshot stores keys as JSString values.
            if (elem.isString()) {
                const key_str: *@import("../string.zig").JSString = @ptrCast(@alignCast(elem.asString()));
                if (heap_mod.valueAsPlainObject(state.for_in_source)) |src| {
                    // Proxy [[HasProperty]] would dispatch the `has`
                    // trap with side effects; the live-deletion check
                    // is an optimisation that doesn't survive trap
                    // observability. Trust the snapshot for proxies —
                    // user code can't safely delete-during-for-in on
                    // a proxy anyway (the trap controls visibility).
                    const is_proxy = src.proxy_target != null or src.proxy_target_fn != null or src.proxy_revoked;
                    if (!is_proxy and !src.hasProperty(key_str.flatBytes())) {
                        cursor += 1;
                        continue;
                    }
                } else if (heap_mod.valueAsFunction(state.for_in_source)) |src_fn| {
                    // §14.7.5.6 — the live-deletion check probes
                    // HasProperty on the source, which walks the
                    // prototype chain. A key inherited from
                    // `%Function.prototype%` (or its parent
                    // `%Object.prototype%`) is still HasProperty:true
                    // and must not be filtered out (test262
                    // built-ins/Object/defineProperty/15.2.3.6-4-419.js,
                    // /15.2.3.6-4-595.js — for-in over a function
                    // surfacing a user-installed enumerable inherited
                    // `prop`).
                    var fn_has = src_fn.ownDataContains(key_str.flatBytes()) or src_fn.accessors.contains(key_str.flatBytes());
                    if (!fn_has) {
                        var ancestor: ?*JSObject = src_fn.proto;
                        while (ancestor) |a| {
                            if (a.ownDataContains(key_str.flatBytes()) or a.hasAccessor(key_str.flatBytes())) {
                                fn_has = true;
                                break;
                            }
                            ancestor = a.prototype;
                        }
                    }
                    if (!fn_has) {
                        cursor += 1;
                        continue;
                    }
                }
            }
        }
        result.set(realm.allocator, "value", elem) catch return error.OutOfMemory;
        result.set(realm.allocator, "done", Value.false_) catch return error.OutOfMemory;
        state.idx = cursor + 1;
        return heap_mod.taggedObject(result);
    }
}
