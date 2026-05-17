//! `ModuleRecord` — Cynic's runtime module instance.
//!
//! Per ECMA-262 §16.2.1.5 ModuleRecord, each unique module
//! source has one MR. Cynic's later shape:
//! • `source_url` — resolved (canonical) URL; doubles as
//! the cache key on `realm.modules`.
//! • `exports` — JSObject namespace populated as the
//! module body runs. Per-named-export property; default
//! under `"default"`.
//! • `state` — uninstantiated → evaluating → evaluated.
//! Cycles are broken by returning the partial `exports`
//! when a module that's still `evaluating` is re-entered.
//!
//! later does eager linking + evaluation: `module_load`
//! opcode parses, compiles, runs the module synchronously and
//! caches the result. Top-level await + true two-phase
//! linking (§16.2.1.5.2 Link, §16.2.1.5.4 Evaluate) are
//! later.

const std = @import("std");

const Value = @import("value.zig").Value;
const JSObject = @import("object.zig").JSObject;
const Chunk = @import("../bytecode/chunk.zig").Chunk;
const Realm = @import("realm.zig").Realm;
const heap_mod = @import("heap.zig");
const PropertyFlags = @import("object.zig").PropertyFlags;
const function_mod = @import("function.zig");
const NativeError = function_mod.NativeError;

pub const ModuleState = enum(u8) {
    /// Module hasn't started evaluating — entry just allocated.
    uninstantiated,
    /// Module body is currently running; cycles route here and
    /// receive the in-progress exports namespace.
    evaluating,
    /// §16.2.1.5.1 Async Module Records — the body started and
    /// is currently suspended on a top-level `await`. The
    /// `evaluation_promise` slot carries the AsyncFunctionStart
    /// result Promise; consumers (static-import drains, dynamic
    /// `import()`) chain settlement off of it.
    evaluating_async,
    /// Module body returned successfully; `exports` is final.
    evaluated,
    /// Module body threw — `exports` is whatever was populated
    /// before the throw. Subsequent imports also throw.
    errored,
};

pub const ModuleRecord = struct {
    /// Resolved URL — canonical key into `realm.modules`. Owned
    /// by the realm allocator.
    source_url: []const u8,
    /// Namespace object containing the module's exports.
    /// Populated as `export` declarations run; finalized at
    /// module-body Return. Borrowed pointer — the heap owns
    /// the JSObject.
    exports: *JSObject,
    /// The compiled module chunk. Lives for the realm's
    /// lifetime — heap-allocated `JSFunction`s declared inside
    /// the module hold non-owning pointers into this chunk's
    /// `function_templates`. Cleaning up early would
    /// invalidate those pointers, so we keep the chunk pinned
    /// until `realm.deinit`.
    chunk: ?Chunk = null,
    state: ModuleState = .uninstantiated,
    /// If `state ==.errored`, the thrown value is stashed
    /// here so subsequent imports can re-throw it.
    error_value: Value = Value.undefined_,
    /// §16.2.1.5.1 [[TopLevelCapability]] / [[AsyncEvaluation]] —
    /// the result Promise of an async module body (the one
    /// `startAsyncCall` returned). Pending while the body is
    /// suspended on a top-level `await`, fulfilled with
    /// undefined when the body returns normally, rejected with
    /// the thrown value otherwise. Set together with
    /// `state = .evaluating_async`; cleared back to
    /// `Value.undefined_` when the module finalises to
    /// `.evaluated` / `.errored`. Consumers:
    /// • `loadModule` static-import path drains microtasks
    ///   against this Promise so the importer's body sees
    ///   final exports.
    /// • `dynamic_import` opcode reads this so the
    ///   import()-Promise settles in lockstep with the
    ///   module's evaluation Promise.
    evaluation_promise: Value = Value.undefined_,
    /// `true` once `getModuleNamespace` has installed the §9.4.6
    /// Module Namespace exotic brand on `exports` — clears the
    /// prototype chain, flips `extensible = false`, sets
    /// `@@toStringTag = "Module"`, and lowers the descriptor flags
    /// on every exported binding to `{w:true, e:true, c:false}`.
    /// Idempotent: callers safely re-enter for cycles.
    namespace_finalized: bool = false,
    /// §16.2.1.5 InnerModuleEvaluation [[PendingAsyncDependencies]]
    /// — async dependency modules that suspended at a top-level
    /// `await` during their `module_load` and whose evaluation
    /// Promise is still pending. Populated by `loadModule` when
    /// an async dep's body returns a pending result Promise; drained
    /// by the `module_link_complete` opcode in the importer's body
    /// (which awaits microtasks to settle each promise, then
    /// propagates any rejection as a thrown exception so the
    /// importer's body sees the abrupt completion). Cleared once
    /// drained. Cynic's lightweight stand-in for the full
    /// PendingAsyncDependencies count + GatherAvailableAncestors
    /// machinery — sufficient because the compiler hoists every
    /// import to a contiguous block before the body proper, so a
    /// single drain at the end of that block matches spec ordering.
    pending_async_deps: std.ArrayListUnmanaged(*ModuleRecord) = .empty,
    /// Mark-sweep bit, written by `Heap.markValue`.
    marked: bool = false,

    pub fn init(allocator: std.mem.Allocator, source_url: []const u8, exports: *JSObject) !*ModuleRecord {
        const m = try allocator.create(ModuleRecord);
        m.* = .{ .source_url = source_url, .exports = exports };
        return m;
    }

    pub fn deinit(self: *ModuleRecord, allocator: std.mem.Allocator) void {
        if (self.chunk) |*c| c.deinit(allocator);
        self.pending_async_deps.deinit(allocator);
        allocator.destroy(self);
    }
};

/// §9.4.6.13 GetModuleNamespace — return the Module Namespace
/// exotic object for `mr`, finalising it on first call. Spec
/// shape:
///   • `[[Prototype]]` = null  (§9.4.6.1)
///   • `[[Extensible]]` = false (§9.4.6.2 — set after init)
///   • `@@toStringTag` = "Module" {w:false, e:false, c:false}
///     (§9.4.6.16 / §28.3.5)
///   • Each exported binding: `{w:true, e:true, c:false}`
///     (§9.4.6.5 — exported bindings are live data descriptors)
///
/// Repeat calls are idempotent: the brand is installed once;
/// subsequent calls just return the cached namespace. Cycles
/// during evaluation receive the partial namespace from
/// `mr.exports` — the `is_module_namespace` brand is still set,
/// but `extensible` remains `true` until the cycle's outer module
/// finishes evaluating (matches §16.2.1.5.4 step on InnerModuleEvaluation).
pub fn getModuleNamespace(realm: *Realm, mr: *ModuleRecord) !*JSObject {
    const ns = mr.exports;

    // Brand-on-allocation so the property-write opcodes route
    // through the namespace-aware path even while the body is
    // evaluating (a cycle that re-enters this MR sees a partial
    // namespace, but it's a namespace — `Symbol.toStringTag` and
    // proto:null are visible before finalisation).
    ns.is_module_namespace = true;
    ns.prototype = null;

    // §28.3.5 — `Symbol.toStringTag` on a Module Namespace exotic is
    // fixed at `"Module"` with all-false flags. The spec doesn't gate
    // it on namespace finalisation: every observer of the namespace
    // (including a cycling importer that sees the partial namespace
    // before the source-module body has returned) gets to read it.
    // Used to live in the finalise block, but that left
    // `ns[Symbol.toStringTag]` and `hasOwnProperty(ns,
    // Symbol.toStringTag)` undefined / false for the cycle case.
    // Idempotent — the `hasOwn` guard keeps repeated calls cheap.
    if (!ns.hasOwn("@@toStringTag")) {
        const tag = try realm.heap.allocateString("Module");
        try ns.setWithFlags(realm.allocator, "@@toStringTag", Value.fromString(tag), .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        });
    }

    if (mr.namespace_finalized) return ns;

    // Only finalise after the module body has returned. While the
    // body is still running (state == .evaluating from a cycle),
    // we leave the namespace mutable so `module_export` opcodes
    // can keep publishing bindings.
    switch (mr.state) {
        .evaluated, .errored => {},
        else => return ns,
    }

    // §9.4.6.5 — exported bindings: {w:true, e:true, c:false}.
    // Iterate `properties` and lower each entry's flags.
    var it = ns.properties.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        // Skip the @@toStringTag installed above — it has different
        // flags.
        if (std.mem.eql(u8, key, "@@toStringTag")) continue;
        try ns.property_flags.put(realm.allocator, key, .{
            .writable = true,
            .enumerable = true,
            .configurable = false,
        });
    }

    ns.extensible = false;
    mr.namespace_finalized = true;
    return ns;
}

/// §9.4.6.7 Module Namespace [[Get]] (P, Receiver), data-property
/// path (steps 8-13). After the exotic dispatch resolves a string
/// key to a bound export, the spec routes the read through
/// `GetBindingValue(N, true)` — and the `true` strict flag makes
/// §8.1.1.1.6 throw a ReferenceError when the source-module
/// binding is still uninitialised.
///
/// Cynic represents uninitialised exported bindings as the Hole
/// sentinel pre-seeded into the namespace's property bag at module
/// instantiation (see `compiler.seedTdzExportHoles` /
/// §15.2.1.16.4 step 12). This helper translates that sentinel
/// into the spec ReferenceError; all other values pass through.
///
/// Callers: `lda_property` / `lda_computed` for `ns.x` / `ns[k]`,
/// `Object.getOwnPropertyDescriptor` (which materialises the
/// descriptor's `[[Value]]`), `Object.prototype.hasOwnProperty`,
/// `Object.prototype.propertyIsEnumerable`, `Object.keys` /
/// `Object.values` / `Object.entries`, and the for-in iterator
/// — every spec path that reaches §9.4.6.4 [[GetOwnProperty]]
/// (which materialises `[[Value]]` via [[Get]]).
///
/// Skipped for non-string keys: §9.4.6.7 step 2 routes Symbol keys
/// (and Cynic's flattened `@@toStringTag` key) through OrdinaryGet
/// without the GetBindingValue dispatch.
pub fn namespaceGetThrowingOnHole(
    realm: *Realm,
    ns: *JSObject,
    key: []const u8,
) NativeError!Value {
    const v = ns.get(key);
    if (v.isHole()) {
        // Match V8 / JSC's wording so user code matching the
        // message via `e.message.includes(name)` continues to
        // work; the binding name is the most useful diagnostic
        // we can surface here.
        const ex = @import("builtins/error.zig").newReferenceError(realm, key) catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    return v;
}
