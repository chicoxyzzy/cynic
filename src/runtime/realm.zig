//! `Realm` — the unit of isolation for a running Cynic program.
//!
//! Per ECMA-262 §9.3 a Realm "consists of a set of intrinsic
//! objects, an ECMAScript global environment, all of the
//! ECMAScript code that is loaded within the scope of that global
//! environment, and other associated state and resources." For
//! Cynic, later represents that with: a heap, intrinsics (later fills
//! these in), and a global object stub.
//!
//! Multiple realms are also the foundation for the SES /
//! Compartments direction (see [docs/handbook/prior-art.md]). later
//! ships a single realm; the API is shaped so adding more later is
//! a structural addition, not a refactor.

const std = @import("std");

const Heap = @import("heap.zig").Heap;
const Value = @import("value.zig").Value;
const JSString = @import("string.zig").JSString;
const JSFunction = @import("function.zig").JSFunction;
const NativeFn = @import("function.zig").NativeFn;
const heap_mod = @import("heap.zig");
const intrinsics_mod = @import("intrinsics.zig");
const Intrinsics = intrinsics_mod.Intrinsics;
const features = @import("features.zig");
pub const FeatureSet = features.FeatureSet;

/// One pending microtask. Drained in FIFO order from
/// `realm.microtask_queue` either at top-level entry boundaries
/// or from inside an `await` opcode.
///
/// Three flavours:
/// • `.callback`: invoke a JS function with one argument
/// (`queueMicrotask` callbacks, the later settled-Promise
/// fast path).
/// • `.async_resume`: resume a suspended `async function`
/// generator with a settled value.
/// • `.promise_reaction`: user-level `.then(onF, onR)`
/// reaction. Runs the handler matching
/// `was_rejected` against `arg`; whatever it returns
/// resolves `reaction_result`. A null handler propagates
/// the settlement unchanged. A Promise-returning handler
/// chains.
/// Per-size register-file pool. Each JS-function call allocates a
/// `[]Value` sized `max(register_count, argc)` for the callee's
/// register file; without pooling, that's a libc malloc + free per
/// call. The pool keeps freed buffers in a per-size bin so a hot
/// method loop pops the same buffer back out every iteration.
///
/// Size key is `register_count` (u32 to cover both u8 and the
/// `argc` path). Bin entries are owned `[]Value` slices freed
/// individually at `realm.deinit`.
pub const FramePool = struct {
    bins: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]Value)) = .empty,

    /// Pop a register file of exactly `n` from the pool, or
    /// allocate a fresh one on miss. Caller is responsible for
    /// memset'ing to `undefined` before use — buffer contents
    /// are stale from the previous frame.
    pub fn acquire(self: *FramePool, allocator: std.mem.Allocator, n: usize) ![]Value {
        if (self.bins.getPtr(@intCast(n))) |list| {
            if (list.items.len > 0) return list.pop().?;
        }
        return try allocator.alloc(Value, n);
    }

    /// Return a register file to its size's bin. On allocation
    /// failure (the bins map can't grow), fall back to freeing
    /// the slice directly — pool growth is best-effort.
    pub fn release(self: *FramePool, allocator: std.mem.Allocator, regs: []Value) void {
        const gop = self.bins.getOrPut(allocator, @intCast(regs.len)) catch {
            allocator.free(regs);
            return;
        };
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(allocator, regs) catch {
            allocator.free(regs);
        };
    }

    pub fn deinit(self: *FramePool, allocator: std.mem.Allocator) void {
        var it = self.bins.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |buf| allocator.free(buf);
            e.value_ptr.deinit(allocator);
        }
        self.bins.deinit(allocator);
    }
};

pub const Microtask = struct {
    kind: enum {
        callback,
        async_resume,
        promise_reaction,
        thenable_job,
        /// §27.6.3.6 AsyncGeneratorYield-as-Await. The body
        /// yielded `value`; per spec the syntactic `yield` is
        /// `Await(value); AsyncGeneratorYield(value)`, so the
        /// settlement of the capability defers a microtask.
        /// This kind both settles `agy_cap_promise` with
        /// `{arg, agy_done}` AND continues the drain.
        async_gen_yield,
        /// §27.6.3.7 step 8.b — when a yield suspended by an
        /// outer `iter.return(v)` is resumed, the body runs
        /// `Let awaited be Await(resumptionValue.[[Value]])`
        /// before propagating the return-completion. We model
        /// this as a microtask that awaits the supplied value
        /// (`arg`), then routes it back into the body as a
        /// return-completion via `resumeAsyncGenBody`. The
        /// thenable case follows the await machinery
        /// (PromiseResolve → suspend on resolved Promise).
        async_gen_return_after_await,
        /// §13.3.10 / §16.2.1.10 EvaluateImportCall — a
        /// dynamic `import(specifier)` whose load + evaluation
        /// is deferred to a job so the importing module's
        /// synchronous DFS (§16.2.1.5 InnerModuleEvaluation)
        /// finishes first. `callback` holds the specifier
        /// JSString, `module_import_base` the importer's base
        /// URL, `reaction_result` the pending import() Promise
        /// the job settles with the resolved namespace (or a
        /// load error).
        module_import,
    } = .callback,
    callback: Value = Value.undefined_,
    arg: Value = Value.undefined_,
    async_gen: ?*@import("generator.zig").JSGenerator = null,
    async_throws: bool = false,
    /// For `.async_gen_yield` — the AsyncGeneratorRequest's
    /// capability Promise to settle.
    agy_cap_promise: ?*@import("object.zig").JSObject = null,
    /// For `.async_gen_yield` — the `done` flag for the
    /// iterator result. Yield → false; return-after-queue → true.
    agy_done: bool = false,
    /// For `.async_gen_yield` — true when the capability should
    /// reject (used by the legacy yield-of-rejected-Promise quirk).
    agy_reject: bool = false,
    /// For `.promise_reaction` — the handler for the settled
    /// state (`Value.undefined_` if absent → propagate).
    /// For `.thenable_job` — the `then` callable to invoke.
    reaction_handler: Value = Value.undefined_,
    /// For `.promise_reaction` — the Promise to settle with
    /// the handler's outcome.
    /// For `.thenable_job` — the outer Promise to settle.
    reaction_result: Value = Value.undefined_,
    /// For `.promise_reaction` — true when the source Promise
    /// settled rejected (drives propagation in the no-handler
    /// case).
    reaction_was_rejected: bool = false,
    /// For `.module_import` — the importing module's base URL
    /// (or `null` at the entry point). Points into chunk-pinned
    /// or realm-lifetime storage, so it needs no GC marking.
    module_import_base: ?[]const u8 = null,
    /// For `.module_import` — §16.2.1.4 ImportAttributes `type`
    /// value when the `import()` call carried a
    /// `{ with: { type: "..." } }` literal in its second arg.
    /// `null` for a plain `import(spec)`. Borrowed from the
    /// importing chunk's constants (lifetime ties to the realm),
    /// so no marking needed.
    module_import_attribute_type: ?[]const u8 = null,
};

/// §16.2.1.8.x — Cynic's three module shapes. `javascript` is the
/// default ParseModule path; `json` and `text` are the synthetic
/// Synthetic Module Records the proposals
/// [json-modules](https://tc39.es/proposal-json-modules/) and
/// [import-text](https://tc39.es/ecma262/#sec-create-text-module)
/// gate behind a `with { type: "..." }` import attribute. A
/// synthetic record skips parse / compile / body-run entirely —
/// the loader returns a fully-populated namespace with a single
/// `default` export.
pub const ModuleType = enum {
    javascript,
    json,
    text,
};

/// Host-supplied module loader. Given a specifier (string from
/// the import declaration, e.g. `"./foo.js"`), the importing
/// module's base URL (or `null` at the entry point), and the
/// decoded `type` import attribute (or `null` when the import has
/// no `with { type: "..." }` clause), returns the resolved
/// canonical URL plus the source bytes and the module shape. Both
/// slices must be valid for the realm's lifetime — typical
/// loaders allocate them off the realm's allocator.
///
/// §16.2.1.4 ImportAttributes: an unknown `type` value (anything
/// other than the host-recognised set — `json` and `text` for
/// Cynic) is a host-defined error. Loaders return
/// `error.ModuleLoadError` for unrecognised type values; the
/// caller translates that into a TypeError at the import site.
pub const ModuleLoadResult = struct {
    /// Canonical URL — used as the cache key. Two specifiers
    /// resolving to the same source must produce identical
    /// `url` strings.
    url: []const u8,
    source: []const u8,
    /// §16.2.1.8.x — selects ParseModule vs the JSON / text
    /// synthetic-module pipeline. `javascript` is the default;
    /// `json` / `text` mean the loader's `source` bytes are fed
    /// directly into the synthetic-record builder (JSON.parse for
    /// `json`, identity for `text`). The loader picks this from
    /// the `attribute_type` arg, the file extension, or both.
    module_type: ModuleType = .javascript,
};
pub const ModuleLoaderError = error{
    OutOfMemory,
    ModuleNotFound,
    ModuleLoadError,
};
pub const ModuleLoader = *const fn (
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
    attribute_type: ?[]const u8,
) ModuleLoaderError!ModuleLoadResult;

/// §9.1.1.4 GlobalEnvironmentRecord — TWO inner records:
///
///   • **ObjectEnvironmentRecord** (`target` / `fallback`) — backed
///     by the globalThis object. Hosts `print`, `console`, the
///     intrinsic constructors, and every top-level `var` /
///     `function` declaration (which stamp non-configurable
///     properties via `installScriptVarBinding` per §9.1.1.4.18 /
///     .19). A bare `globalThis.x = 1` also lands here (regular
///     `put` path).
///
///   • **DeclarativeEnvironmentRecord** (`decl_env` / `decl_kinds`)
///     — pure dictionary, INVISIBLE on globalThis. Top-level `let`
///     / `const` / `class` (and strict-mode block-`function`
///     declarations) stamp here per §9.1.1.4.17 step b. `let foo`
///     does NOT make `'foo' in globalThis` true.
///
/// Per §9.1.1.4 GetBindingValue / SetMutableBinding the
/// declarative record is consulted FIRST; if the name isn't
/// declared lexically, the object record handles it. The runtime
/// `lda_global` / `sta_global` / `contains` helpers below
/// implement that order.
///
/// Before `intrinsics.install` allocates the globalThis JSObject
/// the host pre-installs a handful of bindings (`print`, `console`,
/// the typed Error constructors) on a `fallback` hashmap. Once the
/// globalThis object exists, `bindToObject` migrates the fallback
/// into `gt.properties` and pins the pointer; every subsequent
/// object-env operation routes through the object's own property
/// bag. The `decl_env` is independent of bootstrap and unaffected
/// by `bindToObject`.
pub const GlobalBindings = struct {
    /// Live target for the object env-record: when set, every
    /// object-env operation reads / writes the JSObject's
    /// `properties` map. Late-installed host bindings (e.g.
    /// test262's `$DONE` / `$262`) reach both bare-identifier
    /// lookups and `globalThis.X` because they're really one
    /// property bag.
    target: ?*@import("object.zig").JSObject = null,
    /// Fallback storage for the object env-record — only used
    /// during bootstrap before `bindToObject` runs. Migrated
    /// wholesale into `target`'s `properties` map when the
    /// globalThis object is allocated.
    fallback: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// §9.1.1.4 DeclarativeRecord — lexical bindings (`let` /
    /// `const` / `class` / strict-mode block-`function`). Holds
    /// values plus the §13.3.1 TDZ Hole until each binding's
    /// initialiser fires. NOT mirrored on the global object.
    decl_env: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// Per-name const flag for the declarative env. `true` means
    /// the binding is immutable — `sta_global` raises §13.15.2
    /// TypeError on write. Keyed by the same string slices as
    /// `decl_env`; lifetimes are tied to the script chunk.
    decl_consts: std.StringArrayHashMapUnmanaged(bool) = .empty,
    /// §9.1.1.4 [[VarNames]] — the set of names that have been
    /// declared as top-level `var` or `function` in any script
    /// run against this realm. Distinct from the object env's
    /// property bag (which also holds host-installed bindings
    /// like `Array` / `print`). §16.1.7 step 5.a
    /// HasVarDeclaration consults this set, NOT the property
    /// bag — otherwise `let Array;` would falsely collide with
    /// the host `Array` constructor. Entries are added by
    /// `installScriptVarBinding` / `installScriptFunctionBinding`.
    var_names: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// The realm's heap, wired at `Realm.init` time. Used by the
    /// object-env-record store paths (`put`,
    /// `installScriptVarBinding`, `installScriptFunctionBinding`) to
    /// run the generational write barrier — those write the global
    /// object's `properties` bag directly, bypassing the routed
    /// `heap.storeProperty`. Optional only because a default-
    /// constructed `GlobalBindings` exists briefly before `init`
    /// wires it; every store path that matters runs after.
    heap: ?*Heap = null,

    fn map(self: *GlobalBindings) *std.StringArrayHashMapUnmanaged(Value) {
        if (self.target) |t| return &t.properties;
        return &self.fallback;
    }
    fn mapConst(self: *const GlobalBindings) *const std.StringArrayHashMapUnmanaged(Value) {
        if (self.target) |t| return &t.properties;
        return &self.fallback;
    }

    /// §9.1.1.4 GetBindingValue — declarative record FIRST, then
    /// object record. Used by `lda_global` / `lda_global_or_undef`
    /// and by host code that just wants "whatever binding name
    /// resolves to". The object-record path goes through
    /// `JSObject.lookupOwn` so shape-mode keys (Phase 3 of
    /// [docs/lazy-property-bag.md]) resolve via their slot rather
    /// than the empty bag.
    pub fn get(self: *const GlobalBindings, key: []const u8) ?Value {
        if (self.decl_env.get(key)) |v| return v;
        if (self.target) |t| return t.lookupOwn(key);
        return self.fallback.get(key);
    }
    /// Object env-record put (host-style). Hits the global
    /// object's property bag — does NOT touch the declarative
    /// record. Used by intrinsics installers, `sta_global` for
    /// names that aren't lex-declared, and bare `globalThis.x =
    /// 1` style writes.
    ///
    /// §17 — host-installed bindings on the global object
    /// default to `{ writable: true, enumerable: false,
    /// configurable: true }`. Existing entries keep whatever flags
    /// the installer set (handles the §19.1 frozen
    /// `NaN`/`Infinity`/`undefined` case once those flags are
    /// stamped).
    pub fn put(self: *GlobalBindings, allocator: std.mem.Allocator, key: []const u8, value: Value) !void {
        if (self.target) |t| {
            const had_key = t.ownDataContains(key);
            // Generational write barrier — `setWithFlags` bypasses
            // the routed `heap.storeProperty` path.
            if (self.heap) |h| h.writeBarrier(.{ .object = t }, value);
            // Host-installed bindings default to `{writable: true,
            // enumerable: false, configurable: true}`; existing
            // bindings keep their previously-installed flags so a
            // frozen `NaN` / `Infinity` / `undefined` slot survives
            // re-binding attempts. Routing through `setWithFlags`
            // keeps shape and bag coherent under Phase 3 of
            // [docs/lazy-property-bag.md].
            const flags: @import("object.zig").PropertyFlags = if (had_key)
                t.flagsFor(key)
            else
                .{ .writable = true, .enumerable = false, .configurable = true };
            try t.setWithFlags(allocator, key, value, flags);
            return;
        }
        try self.fallback.put(allocator, key, value);
    }
    /// §9.1.1.4 HasBinding — true if EITHER record has the name.
    pub fn contains(self: *const GlobalBindings, key: []const u8) bool {
        if (self.decl_env.contains(key)) return true;
        if (self.target) |t| return t.ownDataContains(key);
        return self.fallback.contains(key);
    }
    pub fn iterator(self: *const GlobalBindings) std.StringArrayHashMapUnmanaged(Value).Iterator {
        return self.mapConst().iterator();
    }
    pub fn count(self: *const GlobalBindings) usize {
        return self.mapConst().count();
    }
    pub fn getOrPut(
        self: *GlobalBindings,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !std.StringArrayHashMapUnmanaged(Value).GetOrPutResult {
        return self.map().getOrPut(allocator, key);
    }

    /// §9.1.1.4 HasLexicalDeclaration — does the declarative
    /// record hold this name? Drives §16.1.7 step 5.b / 6.a
    /// collision detection.
    pub fn hasLexicalDeclaration(self: *const GlobalBindings, key: []const u8) bool {
        return self.decl_env.contains(key);
    }

    /// §9.1.1.4.4 HasVarDeclaration — consults the realm's
    /// `[[VarNames]]` set. Host-installed properties (e.g.
    /// `Array`, `Object`) are NOT in `[[VarNames]]`, so
    /// `let Array;` doesn't collide here (it's gated by
    /// HasRestrictedGlobalProperty instead, which checks for
    /// non-configurable bindings).
    pub fn hasVarDeclaration(self: *const GlobalBindings, key: []const u8) bool {
        return self.var_names.contains(key);
    }

    /// §9.1.1.4.5 HasRestrictedGlobalProperty — true if the
    /// global object has the named property AND it's non-
    /// configurable. Drives §16.1.7 step 5.c — a script-mode
    /// `let` / `const` / `class` cannot shadow a non-configurable
    /// global property.
    pub fn hasRestrictedGlobalProperty(self: *const GlobalBindings, key: []const u8) bool {
        const t = self.target orelse return false;
        if (!t.ownDataContains(key)) return false;
        // `flagsFor` is shape-aware (Phase 3 of
        // [docs/lazy-property-bag.md]); attrs from a
        // `Object.defineProperty(globalThis, key, {configurable:false})`
        // call land in the shape transition node for shape-mode
        // globals, not the bag.
        return !t.flagsFor(key).configurable;
    }

    /// §9.1.1.4.15 CanDeclareGlobalVar — true if `name` can be
    /// added as a top-level `var` binding.
    ///   • Property already exists on the global object → OK.
    ///   • Otherwise → the global object must be extensible.
    ///
    /// `hardened` opts out of the extensibility check. A hardened
    /// realm freezes globalThis (`extensible = false`) at init,
    /// but the host still needs to install top-level `var` /
    /// `function` decls — the SES freeze is meant to block user
    /// JS from poisoning globalThis via assignment, not to break
    /// host program-level bindings.
    pub fn canDeclareGlobalVar(self: *const GlobalBindings, key: []const u8, hardened: bool) bool {
        if (self.mapConst().contains(key)) return true;
        const t = self.target orelse return true;
        if (hardened) return true;
        return t.extensible;
    }

    /// §9.1.1.4.16 CanDeclareGlobalFunction — stricter than
    /// `CanDeclareGlobalVar`. If no property exists yet, the
    /// global object must be extensible. If one exists, it must
    /// be configurable, or it must be a writable + enumerable
    /// data property (accessor descriptors fail outright).
    ///
    /// `hardened` — see `canDeclareGlobalVar`. Bypasses the
    /// extensibility check on the "no existing property" branch
    /// only; the existing-binding check stays in force so
    /// `function Array() {}` at top level still rejects (Array is
    /// frozen by the SES pass: non-writable + non-configurable).
    pub fn canDeclareGlobalFunction(self: *const GlobalBindings, key: []const u8, hardened: bool) bool {
        const t = self.target orelse return true;
        const has_data = t.ownDataContains(key);
        const has_accessor = t.hasAccessor(key);
        if (!has_data and !has_accessor) {
            if (hardened) return true;
            return t.extensible;
        }
        // `flagsFor` is shape-aware (Phase 3 of
        // [docs/lazy-property-bag.md]) so a defineProperty-
        // installed descriptor stored on the shape transition
        // node is honoured for the configurable / writable
        // gates below.
        const flags = t.flagsFor(key);
        if (has_accessor) {
            return flags.configurable;
        }
        if (flags.configurable) return true;
        return flags.writable and flags.enumerable;
    }

    /// §9.1.1.4 GetBindingValue path through the declarative env
    /// only — used by `lda_global` to surface the TDZ Hole for a
    /// lex binding that hasn't been initialised yet.
    pub fn getDecl(self: *const GlobalBindings, key: []const u8) ?Value {
        return self.decl_env.get(key);
    }

    /// True iff the named declarative binding is `const`-declared.
    /// Drives §13.15.2 / §13.3.1 immutability checks at
    /// `sta_global` time.
    pub fn isLexConst(self: *const GlobalBindings, key: []const u8) bool {
        return self.decl_consts.get(key) orelse false;
    }

    /// §9.1.1.4 SetMutableBinding for the declarative record —
    /// overwrite the slot. Caller has already verified the binding
    /// exists; the const check is done at the bytecode site.
    pub fn putDecl(self: *GlobalBindings, allocator: std.mem.Allocator, key: []const u8, value: Value) !void {
        try self.decl_env.put(allocator, key, value);
    }

    /// §16.1.7 GlobalDeclarationInstantiation step 18 — top-level
    /// `var` / `function` declarations route through §9.1.1.4.18
    /// CreateGlobalVarBinding / §9.1.1.4.19 CreateGlobalFunctionBinding.
    /// Both create the property on the global object with
    /// `{[[Writable]]:true, [[Enumerable]]:true, [[Configurable]]:D}`
    /// where `D` is the "deletable" flag. For source-text scripts
    /// `D` is false — Cynic doesn't ship `eval` so script-source
    /// is the only path that can reach this. Distinguishes top-
    /// level `var x` (non-configurable, enumerable) from a direct
    /// `globalThis.x = 1` (the regular `put` path — configurable,
    /// non-enumerable to match host built-in shape).
    ///
    /// Idempotent for an existing key: §9.1.1.4.18 step 2 / step 6
    /// say "if hasProperty is true … return NormalCompletion" —
    /// the property descriptor (e.g. one previously stamped by
    /// `Object.defineProperty`) is preserved.
    pub fn installScriptVarBinding(
        self: *GlobalBindings,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: Value,
    ) !void {
        try self.var_names.put(allocator, key, {});
        if (self.target) |t| {
            if (!t.ownDataContains(key)) {
                if (self.heap) |h| h.writeBarrier(.{ .object = t }, value);
                // Idempotent for an existing key — only install when
                // missing so a pre-existing descriptor is preserved.
                try t.setWithFlags(allocator, key, value, .{
                    .writable = true,
                    .enumerable = true,
                    .configurable = false,
                });
            }
            return;
        }
        // Pre-`bindToObject` bootstrap path. No flags map exists
        // yet; `bindToObject` copies entries straight onto
        // `gt.properties`. The script-var hoist only runs from
        // user code, which is always after bootstrap, so this
        // branch is defensive — fall back to the fallback map
        // and let the migrating copy do the right thing.
        _ = try self.fallback.getOrPut(allocator, key);
    }
    /// §9.1.1.4.19 CreateGlobalFunctionBinding — top-level
    /// `function` declarations. Unlike var bindings (idempotent
    /// on existing keys) function decls OVERWRITE the data slot
    /// AND restamp the flags to `{writable:true, enumerable:true,
    /// configurable:false}` when CanDeclareGlobalFunction has
    /// already approved. The caller (compiler) is responsible for
    /// running that approval check; here we just install. Any
    /// existing accessor descriptor is replaced with a data
    /// descriptor.
    pub fn installScriptFunctionBinding(
        self: *GlobalBindings,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: Value,
    ) !void {
        try self.var_names.put(allocator, key, {});
        if (self.target) |t| {
            _ = t.removeAccessor(key);
            // Generational write barrier — `setWithFlags` bypasses
            // the routed `heap.storeProperty` path.
            if (self.heap) |h| h.writeBarrier(.{ .object = t }, value);
            try t.setWithFlags(allocator, key, value, .{
                .writable = true,
                .enumerable = true,
                .configurable = false,
            });
            return;
        }
        try self.fallback.put(allocator, key, value);
    }

    /// §16.1.7 GlobalDeclarationInstantiation step 17 — `let` /
    /// `const` / `class` at script top level get a declarative
    /// binding initialised to the TDZ Hole (§13.3.1). The
    /// initializer's `sta_global` overwrites with the actual
    /// value; `lda_global` raises ReferenceError via the existing
    /// `throw_if_hole` shape until then.
    ///
    /// Caller is responsible for the §16.1.7 step 5.a-d collision
    /// checks (HasVarDeclaration / HasLexicalDeclaration /
    /// HasRestrictedGlobalProperty); on reaching this method the
    /// name is guaranteed to be installable. Idempotent for the
    /// same `(name, is_const)` pair — re-running a chunk's hoist
    /// pass (impossible today, defensive) just leaves the slot at
    /// Hole.
    pub fn installScriptLexBinding(
        self: *GlobalBindings,
        allocator: std.mem.Allocator,
        key: []const u8,
        is_const: bool,
    ) !void {
        const gop = try self.decl_env.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = Value.hole_;
        }
        try self.decl_consts.put(allocator, key, is_const);
    }

    pub fn deinit(self: *GlobalBindings, allocator: std.mem.Allocator) void {
        // The `target`'s properties map is owned by the JSObject
        // (and freed by the heap sweep). We only ever own the
        // fallback — which after `bindToObject` is empty, but
        // still holds its backing array allocation — plus the
        // independent declarative env-record maps.
        self.fallback.deinit(allocator);
        self.decl_env.deinit(allocator);
        self.decl_consts.deinit(allocator);
        self.var_names.deinit(allocator);
    }

    /// Promote the JSObject to the live target. Any bindings the
    /// host already pushed into `fallback` (`print`, `console`,
    /// `Error`, …) are copied onto `gt.properties` so identifier
    /// lookups don't regress. `gt`'s own `properties` map is
    /// reused — `setWithFlags` on `gt` for the same key from
    /// inside `intrinsics.install` will overwrite the copy with
    /// the spec-mandated descriptor flags.
    pub fn bindToObject(self: *GlobalBindings, allocator: std.mem.Allocator, gt: *@import("object.zig").JSObject) !void {
        if (self.target != null) return;
        var it = self.fallback.iterator();
        while (it.next()) |e| {
            // Route through `setWithFlags` so the gt's shape / bag
            // representation stays coherent with the rest of
            // intrinsics installation. Default flags here — the
            // fallback map carries pre-bootstrap host pushes that
            // don't track descriptor metadata.
            try gt.setWithFlags(allocator, e.key_ptr.*, e.value_ptr.*, .{});
        }
        self.fallback.deinit(allocator);
        self.fallback = .empty;
        self.target = gt;
    }
};

pub const Realm = struct {
    allocator: std.mem.Allocator,
    /// `*Heap` so multiple Realms can share one heap — required
    /// by §9.3.1 InitializeHostDefinedRealm and the cross-realm
    /// fixtures (one agent, one heap, multiple realms with their
    /// own intrinsics + globals). When `owns_heap` is true the
    /// Realm tears down the heap on `deinit`; child realms set
    /// it false and the parent does the cleanup.
    heap: *Heap,
    /// True when this Realm allocated its own Heap (`Realm.init`).
    /// False for child realms created via `Realm.initChild` that
    /// borrow the parent's heap.
    owns_heap: bool = true,
    /// Child Realms allocated via `$262.createRealm()` or future
    /// `new ShadowRealm()`. Owned by the parent; deinit walks
    /// the list and tears each down before tearing itself down.
    child_realms: std.ArrayListUnmanaged(*Realm) = .empty,
    /// Host-installed global bindings — `print`, `console`,
    /// `globalThis`, etc. Looked up by `lda_global` when an
    /// identifier reference doesn't resolve in any user scope.
    /// Slices borrow from the source / built-ins; lifetime is
    /// the realm.
    globals: GlobalBindings = .{},
    /// Buffered output from `print` / `console.log`. The host
    /// reads it after a script finishes (CLI flushes to stdout;
    /// the test262 runner discards it). Avoids threading
    /// `std.Io` into the runtime, which would touch every
    /// allocation site.
    output: std.ArrayListUnmanaged(u8) = .empty,
    /// Pointers to the built-in constructor / prototype objects
    /// (`%TypeError.prototype%`, `%Object.prototype%`, etc.).
    /// Populated by `installBuiltins`; consulted by the runtime
    /// exception path to allocate real `TypeError` / `RangeError`
    /// instances for `assert.throws`.
    intrinsics: Intrinsics = .{},
    /// Arena for class-build-time data (FieldInit slices, the
    /// per-class private-name prefix strings) that live for the
    /// lifetime of the realm. Avoids per-allocation tracking.
    class_arena: ?std.heap.ArenaAllocator = null,
    /// Monotonic counter for per-ClassTail-evaluation private
    /// brand prefixes (§15.7.14 step 31). Each `buildClass` call
    /// reserves a fresh value and formats `"B{n}#"` into the
    /// `class_arena`. Two evaluations of the same source-text
    /// ClassTail (e.g. inside a `makeC()` factory) produce
    /// distinct brand identities so cross-instance private reads
    /// raise the spec-mandated TypeError.
    class_brand_counter: u32 = 0,
    /// Monotonic invalidation counter for the prototype-load path
    /// of the property IC. Bumped on every operation that swaps a
    /// receiver's `[[Prototype]]` link — `Object.setPrototypeOf`,
    /// `Reflect.setPrototypeOf`, and the `__proto__` object-literal
    /// shorthand. The IC's prototype-load cells snapshot this value
    /// at fill time and miss on any subsequent bump, forcing a
    /// fresh chain walk. Mutations to a prototype's own properties
    /// (data reassign, delete, data→accessor) don't bump — those
    /// surface through the cached `proto_shape` field. Conservative:
    /// bumps invalidate every proto-load cell in the realm, but the
    /// counter is bumped only on the rare proto-link write path so
    /// the broad invalidation is fine in practice.
    proto_revision_counter: u64 = 1,
    /// Per-size register-file pool for call frames. Every
    /// JS-function call allocates a `[]Value` sized
    /// `max(chunk.register_count, argc)` for the callee's register
    /// file; freeing it on frame pop returns malloc/free pressure
    /// on every call. Method-call and constructor-instantiation
    /// hot loops (the `method_call` / `class_instantiate` cross-
    /// engine benches surfaced this) repeatedly allocate the same
    /// size, so a per-size free list captures the pattern: pop on
    /// `acquire`, push on `release`. Bin entries are owned slices
    /// drained at `realm.deinit`. Distinct sizes (different
    /// chunks, or `argc` ≥ `register_count` paths) get their own
    /// bin; the map grows bounded by the number of unique
    /// register_counts the realm has seen.
    frame_pool: FramePool = .{},
    /// One-shot exception slot for native callbacks. A native
    /// that wants to throw a specific JS value sets this and
    /// returns `error.NativeThrew`; the dispatcher reads it,
    /// clears it, and surfaces the value as the runtime
    /// exception. Lets `Object.create(null)` etc. throw with the
    /// exact constructor / message the spec mandates rather than
    /// the generic "native error".
    pending_exception: ?Value = null,
    /// NewTarget for the next native constructor call when the
    /// callee's `defers_proto_lookup` flag is set. The construct
    /// path skips OrdinaryCreateFromConstructor and stashes the
    /// resolved newTarget here so the native can perform its
    /// spec-mandated argument validation BEFORE the proto lookup
    /// (which may throw via a custom `prototype` getter — see
    /// §25.1.4.1 / §25.3.2.1: ToIndex / RangeError on byteLength
    /// vs maxByteLength precedes OCFC). The native consumes this
    /// slot via `consumePendingNativeNewTarget` and is responsible
    /// for calling `getPrototypeFromConstructor` itself before
    /// allocating its instance.
    pending_native_new_target: Value = Value.undefined_,
    /// Sticky flag set when [[DefineOwnProperty]] rejected a typed-
    /// array index (per §10.4.5.3 — returns false, not throws).
    /// Object.defineProperty translates the reject to TypeError;
    /// Reflect.defineProperty translates it to `false`. The flag
    /// lets the two callers split the same throw site.
    define_own_property_rejected: bool = false,
    /// §27.5.1.3 GeneratorPrototype.return — set while a generator
    /// is being driven through its pending `try { … } finally`
    /// blocks with a return-completion. The `throw_` opcode and
    /// any other `unwindThrow` caller running inside that
    /// generator's frame stack must skip past user `catch`
    /// clauses and stop only at `is_finally` handlers. `null`
    /// outside the return-completion unwind cycle; the value
    /// stored is the return-completion value to surface once
    /// every relevant finally has run.
    gen_return_completion: ?Value = null,
    /// FIFO microtask queue (§9.4 HostEnqueueMicrotask). Drained
    /// at the end of every external entry — `cynic eval`,
    /// `cynic run`, each test262 invocation — and from any
    /// `await` opcode site. Each entry is a function to call
    /// with one argument.
    microtask_queue: std.ArrayListUnmanaged(Microtask) = .empty,
    /// §9.10 [[KeptAlive]] — the per-agent "keep alive across the
    /// current job" list. `WeakRef.prototype.deref` (§26.1.4.1
    /// step 2a) and the `WeakRef` constructor (§26.1.1.1 step 4)
    /// both call AddToKeptObjects (§9.10.4.1) which appends here.
    /// `markRoots` strong-marks every entry so the GC can't
    /// collect a target while it's still in this list.
    /// `drainMicrotasks` calls `ClearKeptObjects` (§9.10.4.2) at
    /// each job boundary, releasing the targets. Without this,
    /// `ref.deref()` is observably broken — a second `deref()` in
    /// the same synchronous block can see a swept target on a
    /// spec-compliant engine, but every other shipping engine
    /// pins the target until the job ends.
    kept_alive: std.ArrayListUnmanaged(Value) = .empty,
    /// Host-installed module loader. `null` means imports throw
    /// at runtime. The CLI's `cynic run --module …` path and
    /// the test262 harness install one that reads from disk.
    module_loader: ?ModuleLoader = null,
    /// Module record cache — keyed by the resolved URL the
    /// loader returns. Cycle detection consults this map: a
    /// module re-encountered while still `evaluating` returns
    /// its in-progress namespace.
    modules: std.StringArrayHashMapUnmanaged(*@import("module.zig").ModuleRecord) = .empty,
    /// Module currently being evaluated, if any. The
    /// `module_export` opcode reads this to find the exports
    /// namespace it should publish into. Set by `loadModule`
    /// before run(), restored after.
    current_module: ?*@import("module.zig").ModuleRecord = null,
    /// §15.2.1.16 step 9 — IndirectExportEntries are validated
    /// once per module, after the whole link/evaluate tree has
    /// settled. Cynic's eager link+evaluate inlines body runs
    /// inside `loadModule`, so a dep's IndirectExports can't be
    /// validated when *its* body returns — the dep's chain might
    /// resolve through a star-export the parent installs *after*
    /// the dep finishes (e.g. `b` re-exports `a.foo` and `a` has
    /// `export * from b, export * from c` — `b.foo` resolves
    /// via `a.foo → c.foo`, but `a` hasn't installed its star
    /// redirects when `b` returns). `loadModule` queues each
    /// successfully-evaluated module here; the topmost
    /// (depth=0) call drains the queue and runs validation
    /// against the now-final namespace shape.
    pending_indirect_export_validation: std.ArrayListUnmanaged(*@import("module.zig").ModuleRecord) = .empty,
    /// Nesting depth of `loadModule` calls. Drives the queued
    /// validation drain above: depth>0 means we're inside a
    /// recursive `module_load`; only the depth=0 return is
    /// safe to validate (every dep's body has finalised by
    /// then, and every parent's star-exports have been
    /// installed).
    module_load_depth: u32 = 0,
    /// `$DONE(err)` host-hook state for the test262 harness.
    /// Async-flagged tests call `$DONE()` to signal success or
    /// `$DONE(err)` for failure; the runner checks these slots
    /// after draining microtasks. Reset between tests by
    /// `Realm.init`.
    async_done_called: bool = false,
    async_done_error: Value = Value.undefined_,
    /// Bytecode chunks produced by `evaluateScript` calls. The
    /// realm owns these so that JS functions declared in one
    /// script (which hold pointers into their parent chunk's
    /// `function_templates` array) survive past the script
    /// itself and can be called from a later script. Stored as
    /// pointers — the array may grow, but each chunk's address
    /// is stable across appends, which matters because the
    /// `JSFunction` objects on the heap hold direct pointers
    /// into chunk-template arrays. Memory reclaim is at realm
    /// tear-down — fine for the cynic CLI and the test262
    /// harness; a longer-running host (REPL, edge worker) can
    /// be revisited with a per-script arena later if it
    /// matters.
    script_chunks: std.ArrayListUnmanaged(*@import("../bytecode/chunk.zig").Chunk) = .empty,
    /// Cooperative interpreter step budget. Decremented once per
    /// opcode in `runFrames`; on reaching zero the dispatch loop
    /// raises a synthetic `RangeError("step budget exhausted")`
    /// and unwinds. Default is `maxInt(u64)` — hosts that need
    /// bounded execution (test runners, sandboxed shells, slow-
    /// script watchers) set a lower value before each run.
    step_budget: u64 = std.math.maxInt(u64),
    /// Externally-flippable interrupt flag. Any thread (including
    /// a SIGALRM-style watchdog or a host UI thread) can call
    /// `requestInterrupt`. The interpreter dispatch loop polls
    /// this between opcodes and throws an uncatchable
    /// `RangeError("execution interrupted")` when set, mirroring
    /// V8's `Isolate::TerminateExecution` and JSC's
    /// `Watchdog::fire`.
    interrupt: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Optional host-supplied interrupt flag, polled alongside
    /// `interrupt`. Unlike `interrupt` (a per-realm field), this
    /// points at storage the host keeps alive longer than the realm
    /// — so a watchdog thread can flip it without racing the realm's
    /// teardown. The test262 harness aims it at a stable per-worker
    /// flag; null for ordinary embeddings.
    host_interrupt: ?*std.atomic.Value(bool) = null,
    /// Stack of every live `runFrames` call's frame list. Each
    /// entry is the `*ArrayListUnmanaged(CallFrame)` that a
    /// `runFrames` invocation is currently dispatching against;
    /// pushed on entry, popped on return. The GC walks every
    /// stack here so a nested `runFrames` (a native callback
    /// re-entering JS, `gen.next()` from outside the interpreter,
    /// `callJSFunction` from inside an opcode) doesn't lose the
    /// outer frames' registers as roots. Without this, an
    /// allocation inside a child `runFrames` collects values that
    /// the parent's for-of's `r_iter` register still points at.
    frame_stacks: std.ArrayListUnmanaged(*std.ArrayListUnmanaged(@import("lantern/interpreter.zig").CallFrame)) = .empty,
    /// Pre-Stage-4 / experimental TC39 proposals enabled for this
    /// realm. See `runtime/features.zig`. Default is empty —
    /// embedders and the `cynic` CLI opt in via `--enable=<name>`
    /// or `--enable-experimental`; the test262 harness sets this
    /// to `features.all()` so proposal fixtures actually exercise
    /// the surface they're testing. Read by gated installers (e.g.
    /// `Iterator.zip`, `Map.prototype.getOrInsert`) before they
    /// register their methods on the prototype, so a disabled
    /// feature is invisible at the property-lookup level rather
    /// than just throwing at call time.
    feature_flags: FeatureSet = FeatureSet.initEmpty(),
    /// Heap-allocated bool cells tracking `[[ThisBindingStatus]]`
    /// for derived-class constructors that have outlived their
    /// frame's call site. Allocated on entry to a derived-ctor
    /// frame, shared with any arrows that frame creates, and
    /// flipped by `super(...)` from those arrows — including when
    /// the arrow runs in a fresh `runFrames` re-entry (e.g.
    /// iterator `return()` during for-of close). The slice is
    /// freed on realm tear-down rather than per-ctor — small
    /// volume, simpler than threading lifetime through every
    /// `super_call` site. Each entry is a single `*bool`.
    derived_ctor_cells: std.ArrayListUnmanaged(*bool) = .empty,
    /// SES posture toggle. When `true` (the default) the freeze
    /// pass at the end of `installBuiltins` walks the intrinsic
    /// graph + globalThis and stamps every reachable object /
    /// function `[[Extensible]] = false`, every own data
    /// descriptor `{writable: false, configurable: false}`, and
    /// every accessor descriptor `{configurable: false}`. User-
    /// installed `Array.prototype.X = …` etc. then throws.
    /// `--unhardened` flips this to `false` — the freeze is a
    /// no-op and Cynic behaves like legacy ECMAScript (mutable
    /// primordials).
    ///
    /// Also consulted by `GlobalBindings.canDeclareGlobalVar` /
    /// `canDeclareGlobalFunction`: a hardened realm freezes
    /// globalThis (`extensible = false`), which would normally
    /// reject every new top-level `var` / `function` declaration
    /// via §9.1.1.4.15. The host bypasses the extensibility check
    /// when `hardened` is true so user scripts can still declare
    /// top-level bindings — the freeze is intended to lock the
    /// intrinsics, not break the host's ability to install
    /// program-level globals.
    ///
    /// See [docs/ses-alignment.md](../../docs/ses-alignment.md).
    hardened: bool = true,
    /// Phase 3 SES override-mistake fix — `freezePrimordials`
    /// installs a `SyntheticAccessor` pair (getter + setter
    /// JSFunctions sharing one capture cell) for every data
    /// property on every reachable prototype. The capture cells
    /// live as long as the realm; this list tracks them for the
    /// teardown free. The realm owns the cells; the
    /// `JSFunction.synth_accessor` slot is a borrow.
    synth_accessor_cells: std.ArrayListUnmanaged(*@import("function.zig").SyntheticAccessor) = .empty,

    pub fn init(allocator: std.mem.Allocator) Realm {
        const heap_ptr = allocator.create(Heap) catch unreachable;
        heap_ptr.* = Heap.init(allocator);
        var r: Realm = .{
            .allocator = allocator,
            .heap = heap_ptr,
            .owns_heap = true,
        };
        r.globals.heap = heap_ptr;
        return r;
    }

    /// §26.2 FinalizationRegistry cleanup-job scheduler. The major
    /// collector (`Heap.collectFull`) calls this for every cell
    /// whose target did not survive the trace; it enqueues a host
    /// job that invokes `cleanupCallback(heldValue)` on the next
    /// microtask drain. Installed onto the heap via
    /// `Heap.setFinalizationEnqueue` so the heap — which can't
    /// import `realm.zig` — can reach it. `ctx` is the `*Realm`.
    /// An OOM from the queue append is swallowed: §26.2's
    /// introductory note explicitly permits an implementation to
    /// skip a cleanup callback, so a dropped job is conformant.
    fn finalizationEnqueueJob(ctx: *anyopaque, callback: Value, held_value: Value) void {
        const realm: *Realm = @ptrCast(@alignCast(ctx));
        realm.enqueueMicrotask(callback, held_value) catch {};
    }

    /// Variant of `init` that backs heap-side byte payloads
    /// (`JSString.bytes`, ArrayBuffer slabs) with a separate
    /// allocator from the realm's struct allocator. Used by the
    /// test262 harness so per-fixture peaks return to the OS
    /// between fixtures — see `Heap.initWithBytesAllocator`.
    pub fn initWithBytesAllocator(
        allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
    ) Realm {
        const heap_ptr = allocator.create(Heap) catch unreachable;
        heap_ptr.* = Heap.initWithBytesAllocator(allocator, bytes_allocator);
        var r: Realm = .{
            .allocator = allocator,
            .heap = heap_ptr,
            .owns_heap = true,
        };
        r.globals.heap = heap_ptr;
        return r;
    }

    /// Create a child Realm that shares `parent`'s heap. Used by
    /// `$262.createRealm()` (test262 harness) and by future
    /// ShadowRealm support — both need a fresh set of intrinsics
    /// and globals but a single agent-wide heap so values can
    /// cross realm boundaries without GC roots being split.
    pub fn initChild(parent: *Realm) Realm {
        var r: Realm = .{
            .allocator = parent.allocator,
            .heap = parent.heap,
            .owns_heap = false,
            .host_interrupt = parent.host_interrupt,
            // Children inherit the SES posture of their parent —
            // a hardened parent must not accidentally hand a
            // mutable-primordials surface to `$262.createRealm()`
            // and vice versa.
            .hardened = parent.hardened,
        };
        r.globals.heap = parent.heap;
        return r;
    }

    /// §6.1.5.1 — well-known symbols (`Symbol.iterator`,
    /// `Symbol.hasInstance`, …) are shared across all realms in
    /// the same agent. After `installBuiltins` on a child realm
    /// builds fresh per-realm intrinsics, this rewires the
    /// child's `Symbol` constructor properties to point at the
    /// parent's symbol objects so identity comparisons
    /// (`a.Symbol.iterator === b.Symbol.iterator`) succeed per
    /// spec.
    pub fn shareWellKnownSymbolsWith(self: *Realm, parent: *const Realm) !void {
        const parent_sym = heap_mod.valueAsFunction(parent.globals.get("Symbol") orelse return) orelse return;
        const child_sym = heap_mod.valueAsFunction(self.globals.get("Symbol") orelse return) orelse return;
        const names = [_][]const u8{
            "iterator",    "asyncIterator", "hasInstance",
            "toPrimitive", "toStringTag",   "isConcatSpreadable",
            "species",     "match",         "replace",
            "search",      "split",         "matchAll",
            "unscopables",
        };
        for (names) |name| {
            const v = parent_sym.get(name);
            if (v.isUndefined()) continue;
            // setWithFlags overwrites both the data slot and the
            // descriptor (well-known symbols are frozen:
            // `{ w:false, e:false, c:false }`).
            try child_sym.setWithFlags(self.allocator, name, v, .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            });
        }
    }

    pub fn deinit(self: *Realm) void {
        self.frame_pool.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.microtask_queue.deinit(self.allocator);
        self.kept_alive.deinit(self.allocator);
        self.pending_indirect_export_validation.deinit(self.allocator);
        // ModuleRecords are owned by the realm; the heap
        // doesn't sweep them.
        var mit = self.modules.iterator();
        while (mit.next()) |entry| entry.value_ptr.*.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        for (self.script_chunks.items) |ch| {
            ch.deinit(self.allocator);
            self.allocator.destroy(ch);
        }
        self.script_chunks.deinit(self.allocator);
        self.frame_stacks.deinit(self.allocator);
        // Free the derived-ctor `super_called` cells handed out
        // across this realm's lifetime. JSFunctions holding cell
        // pointers are about to be torn down with the heap.
        for (self.derived_ctor_cells.items) |cell| {
            self.allocator.destroy(cell);
        }
        self.derived_ctor_cells.deinit(self.allocator);
        // Phase 3 — free the SES override-mistake-fix capture cells.
        // The getter/setter JSFunctions referencing them are torn
        // down with the heap below; freeing the cells here is
        // safe-ordered (the heap sweep doesn't dereference
        // `synth_accessor` after this point).
        for (self.synth_accessor_cells.items) |cell| {
            self.allocator.destroy(cell);
        }
        self.synth_accessor_cells.deinit(self.allocator);
        // Tear down child realms (created via $262.createRealm)
        // BEFORE the heap, so their globals/intrinsics maps free
        // through allocator paths that don't depend on heap state.
        // They borrow our heap (owns_heap=false), so each just
        // releases its own maps.
        for (self.child_realms.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.child_realms.deinit(self.allocator);
        // Only the Realm that allocated the heap frees it; child
        // realms borrow and exit cleanly.
        if (self.owns_heap) {
            self.heap.deinit();
            self.allocator.destroy(self.heap);
        }
        if (self.class_arena) |*a| a.deinit();
    }

    /// Request the interpreter unwind on its next dispatch tick.
    /// Safe to call from any thread; the dispatch-loop poll uses
    /// acquire-release ordering.
    pub fn requestInterrupt(self: *Realm) void {
        self.interrupt.store(true, .release);
    }

    /// Reset the interrupt flag. Called automatically after the
    /// dispatch loop throws the synthetic RangeError, but exposed
    /// so a host can cancel a pending request before it fires.
    pub fn clearInterrupt(self: *Realm) void {
        self.interrupt.store(false, .release);
    }

    pub fn enqueueMicrotask(self: *Realm, callback: Value, arg: Value) !void {
        try self.microtask_queue.append(self.allocator, .{ .kind = .callback, .callback = callback, .arg = arg });
    }

    /// §9.10.4.1 AddToKeptObjects — pin `value` alive for the
    /// duration of the current job. Called from
    /// `WeakRef.prototype.deref` (§26.1.4.1 step 2a) and the
    /// `WeakRef` constructor (§26.1.1.1 step 4). The pinning is
    /// released by `clearKeptObjects` at the next job boundary.
    pub fn addToKeptObjects(self: *Realm, value: Value) !void {
        try self.kept_alive.append(self.allocator, value);
    }

    /// §9.10.4.2 ClearKeptObjects — clear the per-agent
    /// "keep alive across the current job" list. Per the spec
    /// note, "ECMAScript implementations are expected to call
    /// ClearKeptObjects when a synchronous sequence of ECMAScript
    /// execution completes." `drainMicrotasks` calls this at the
    /// start of each drain (after the top-level synchronous block
    /// ended) and again after every drained microtask (each
    /// microtask is its own job per §9.5.5).
    pub fn clearKeptObjects(self: *Realm) void {
        self.kept_alive.clearRetainingCapacity();
    }

    /// Schedule a suspended async-function generator to resume
    /// with `value`. `throws = true` makes the resumption throw
    /// `value` from inside the gen (rejected awaits).
    pub fn enqueueAsyncResume(
        self: *Realm,
        gen: *@import("generator.zig").JSGenerator,
        value: Value,
        throws: bool,
    ) !void {
        try self.microtask_queue.append(self.allocator, .{
            .kind = .async_resume,
            .arg = value,
            .async_gen = gen,
            .async_throws = throws,
        });
    }

    /// §27.6.3.7 step 8.b — schedule the Awaited return-completion
    /// at the suspended yield site. `value` is the value passed
    /// to `outerGen.return(value)` — it must be Awaited before
    /// being propagated as the return completion, so the cap of
    /// the outer `.return()` settles one tick later than a bare
    /// `.next()` would. (For Promise / thenable values the await
    /// machinery in `asyncGenDispatch` registers a reaction and
    /// only enqueues this kind once the await settles.)
    pub fn enqueueAsyncGenReturnAfterAwait(
        self: *Realm,
        gen: *@import("generator.zig").JSGenerator,
        value: Value,
        throws: bool,
    ) !void {
        try self.microtask_queue.append(self.allocator, .{
            .kind = .async_gen_return_after_await,
            .arg = value,
            .async_gen = gen,
            .async_throws = throws,
        });
    }

    /// §27.6.3.6 AsyncGeneratorYield (the syntactic `yield X` in
    /// an async generator is `Await(X); AsyncGeneratorYield(X)`).
    /// Defers settlement of `cap_promise` with `{value, done}`
    /// (or rejection with `value` when `reject = true`) until
    /// the microtask drain — observably, that means the user's
    /// `.then(cb)` registered AFTER `iter.next()` returns sees a
    /// pending promise and queues its reaction in the same tick.
    /// After settlement, continues the drain so any buffered
    /// follow-on requests get processed.
    pub fn enqueueAsyncGenYield(
        self: *Realm,
        gen: *@import("generator.zig").JSGenerator,
        cap_promise: *@import("object.zig").JSObject,
        value: Value,
        done: bool,
        reject: bool,
    ) !void {
        try self.microtask_queue.append(self.allocator, .{
            .kind = .async_gen_yield,
            .arg = value,
            .async_gen = gen,
            .agy_cap_promise = cap_promise,
            .agy_done = done,
            .agy_reject = reject,
        });
    }

    /// Schedule a `.then` reaction. `handler` is the callback
    /// for the settled state (or `Value.undefined_` if the
    /// reaction has no handler for this state — propagate).
    /// `value` is the settled value of the source Promise.
    /// `result` is the Promise the reaction returns; settled
    /// based on the handler's outcome (or the propagated state
    /// when handler is undefined).
    pub fn enqueuePromiseReaction(
        self: *Realm,
        handler: Value,
        value: Value,
        result: Value,
        was_rejected: bool,
    ) !void {
        try self.microtask_queue.append(self.allocator, .{
            .kind = .promise_reaction,
            .arg = value,
            .reaction_handler = handler,
            .reaction_result = result,
            .reaction_was_rejected = was_rejected,
        });
    }

    /// §27.2.1.3 PromiseResolveThenableJob — schedule a job that
    /// invokes `then.call(thenable, resolveFn, rejectFn)` where
    /// resolveFn/rejectFn settle `outer_promise`. Used both by
    /// `Promise.prototype.then` reactions returning a thenable
    /// and by `Promise Resolve Functions` (§27.2.1.3.2).
    pub fn enqueueThenableJob(
        self: *Realm,
        outer_promise: Value,
        thenable: Value,
        then_fn: Value,
    ) !void {
        try self.microtask_queue.append(self.allocator, .{
            .kind = .thenable_job,
            .arg = thenable,
            .reaction_handler = then_fn,
            .reaction_result = outer_promise,
        });
    }

    /// §13.3.10 / §16.2.1.10 EvaluateImportCall — schedule a
    /// deferred dynamic-import job. The actual `loadModule`
    /// (parse + link + InnerModuleEvaluation) runs when the
    /// microtask drains, NOT inline at the `import()` call site,
    /// so a module already part of the importer's static graph
    /// is evaluated by the synchronous DFS first and the dynamic
    /// import merely observes it (it "can't preempt DFS order").
    /// `specifier` is the already-coerced specifier JSString;
    /// `result_promise` is the pending Promise `import()`
    /// returned; `base_url` is the importer's base URL.
    pub fn enqueueModuleImport(
        self: *Realm,
        specifier: Value,
        result_promise: Value,
        base_url: ?[]const u8,
        attribute_type: ?[]const u8,
    ) !void {
        try self.microtask_queue.append(self.allocator, .{
            .kind = .module_import,
            .callback = specifier,
            .reaction_result = result_promise,
            .module_import_base = base_url,
            .module_import_attribute_type = attribute_type,
        });
    }

    /// Lazily-initialised allocator for class build-time data
    /// (FieldInit slices, etc.). Lives until `realm.deinit`.
    pub fn classAllocator(self: *Realm) std.mem.Allocator {
        if (self.class_arena == null) {
            self.class_arena = std.heap.ArenaAllocator.init(self.allocator);
        }
        return self.class_arena.?.allocator();
    }

    /// Run a stop-the-world mark-sweep cycle. Roots:
    ///   • `realm.globals` (every binding)
    ///   • `realm.intrinsics` (every prototype / constructor pointer)
    ///   • `realm.pending_exception`, `async_done_error`
    ///   • `realm.microtask_queue` (callbacks + args + async-gen handles)
    ///   • `realm.modules` + `realm.current_module` (module export bags)
    ///   • `realm.script_chunks` (each chunk's constants pool)
    ///   • Every active `runFrames` invocation's frame stack —
    ///     pushed onto `realm.frame_stacks` on entry, popped on
    ///     return. Walks every frame's accumulator, registers,
    ///     `this`, captured env, home object, owning generator,
    ///     plus the chunk. Critical for nested re-entry: a
    ///     native callback that calls back into JS (e.g. `gen.next()`
    ///     fired by a `for-of` loop, `Promise.then` handlers,
    ///     iterator-protocol step calls) opens a child `runFrames`;
    ///     the outer frames' registers must stay rooted across the
    ///     child's allocations.
    ///   • Open handle scopes (covered by `heap.collect`).
    ///
    /// Called from the interpreter dispatch loop when
    /// `heap.allocs_since_gc` crosses `heap.gc_threshold`. The
    /// counter resets to zero at the end of `heap.collect`.
    pub fn collectGarbage(self: *Realm) void {
        // §26.1 / §24.3 / §24.4 / §26.2 — arm the major cycle
        // BEFORE `markRoots`. `markRoots` calls `markValue` on every
        // realm root (including any WeakRef / WeakMap / WeakSet /
        // FinalizationRegistry held by a global), so both the
        // `live_color` flip and the `weak_aware_mark` flag must
        // already be in place. `collectFull` sees `cycle_started`
        // and skips its own arm-cycle.
        self.heap.beginMajorCycle();
        self.markRoots();
        // Hand off to `heap.collectFull` for the handle-scope walk
        // and the actual sweep. The empty roots slice is fine —
        // every root above is already marked.
        self.heap.collectFull(&.{});
    }

    /// Run a minor (young-generation) collection. Marks exactly the
    /// same realm roots as `collectGarbage`, then hands off to
    /// `heap.collectYoung`, which additionally walks the remembered
    /// set and every mature container's typed internal slots,
    /// sweeps only the young lists, and promotes young survivors
    /// into the mature generation by relink (non-moving).
    pub fn collectGarbageYoung(self: *Realm) void {
        // Debug-only barrier audit — under Debug / ReleaseSafe this
        // asserts every routed-setter mature→young edge is in the
        // remembered set before the minor cycle consumes it.
        self.heap.verifyRememberedSet();
        // Arm the minor cycle BEFORE `markRoots` so the `live_color`
        // flip precedes any `markValue` call. `collectYoung` sees
        // `cycle_started` and skips its own arm-cycle.
        self.heap.beginMinorCycle();
        self.markRoots();
        self.heap.collectYoung(&.{});
    }

    /// Mark every realm-level root reachable for a GC cycle. Shared
    /// by the major (`collectGarbage`) and minor
    /// (`collectGarbageYoung`) collectors — the root set is
    /// identical; only the sweep differs.
    fn markRoots(self: *Realm) void {
        // Globals — both the object env-record (live target /
        // fallback) and the declarative env-record. Lex bindings
        // (`let x = someObject;`) are GC roots just like var.
        //
        // The target object itself is the root: marking it picks
        // up `slots[]` (shape-mode values under Phase 3 of
        // [docs/lazy-property-bag.md]), `properties` (dict-mode
        // values), accessors, and the prototype chain via
        // `markObject`. The fallback map is host-bootstrap state
        // before `bindToObject` runs.
        if (self.globals.target) |gt| {
            self.heap.markValue(heap_mod.taggedObject(gt));
        } else {
            var fit = self.globals.fallback.iterator();
            while (fit.next()) |e| self.heap.markValue(e.value_ptr.*);
        }
        var dit = self.globals.decl_env.iterator();
        while (dit.next()) |e| self.heap.markValue(e.value_ptr.*);

        // Intrinsics — the struct is a flat list of optional
        // `*JSObject` / `*JSFunction` pointers; iterate fields
        // with comptime reflection so adding a new intrinsic
        // doesn't silently break GC roots.
        inline for (@typeInfo(Intrinsics).@"struct".fields) |field| {
            const v = @field(self.intrinsics, field.name);
            const T = @TypeOf(v);
            if (T == ?*@import("object.zig").JSObject) {
                if (v) |o| self.heap.markValue(heap_mod.taggedObject(o));
            } else if (T == ?*JSFunction) {
                if (v) |fp| self.heap.markValue(heap_mod.taggedFunction(fp));
            }
        }

        // Per-realm singleton values.
        if (self.pending_exception) |ex| self.heap.markValue(ex);
        self.heap.markValue(self.async_done_error);

        // Microtask queue.
        for (self.microtask_queue.items) |mt| {
            self.heap.markValue(mt.callback);
            self.heap.markValue(mt.arg);
            if (mt.async_gen) |g| self.heap.markGenerator(g);
            if (mt.agy_cap_promise) |cap| self.heap.markValue(heap_mod.taggedObject(cap));
            self.heap.markValue(mt.reaction_handler);
            self.heap.markValue(mt.reaction_result);
        }

        // §9.10 [[KeptAlive]] — `WeakRef` constructor / `deref`
        // pin targets here for the duration of the current job.
        // Strong-mark every entry so the major collector treats
        // them as live; `drainMicrotasks` releases them at the
        // next job boundary via `clearKeptObjects`.
        for (self.kept_alive.items) |v| self.heap.markValue(v);

        // Modules — each `ModuleRecord.exports` is a plain
        // `*JSObject` on the GC heap whose property bag holds
        // every named export. `error_value` carries the thrown
        // exception for `.errored` modules so re-imports
        // re-throw the same identity. `evaluation_promise`
        // pins the async-module result Promise that the body's
        // suspended frame settles when it returns. `import_meta`
        // pins the §16.2.1.7 [[ImportMeta]] object so
        // user-installed properties survive across GC cycles.
        if (self.current_module) |m| self.heap.markValue(heap_mod.taggedObject(m.exports));
        var mit = self.modules.iterator();
        while (mit.next()) |e| {
            const m = e.value_ptr.*;
            self.heap.markValue(heap_mod.taggedObject(m.exports));
            self.heap.markValue(m.error_value);
            self.heap.markValue(m.evaluation_promise);
            if (m.import_meta) |im| self.heap.markValue(heap_mod.taggedObject(im));
        }

        // Chunk constants — pinned at chunk-finalize time
        // (`Heap.pinChunk`); sweep skips pinned strings, so
        // there's nothing to mark per cycle. Saves the
        // recursive `markChunk` walk over every nested function
        // / class template's constant pool.

        // Active call frames — every nested `runFrames` invocation's
        // stack is pushed onto `frame_stacks`. Walking all of them
        // means an outer for-of's `r_iter` register stays alive
        // while a generator body's nested dispatch loop allocates
        // (and triggers GC) underneath.
        for (self.frame_stacks.items) |stack| {
            for (stack.items) |f| {
                self.heap.markValue(f.accumulator);
                self.heap.markValue(f.this_value);
                for (f.registers) |r| self.heap.markValue(r);
                if (f.env) |env| self.heap.markEnvironment(env);
                if (f.home_object) |ho| self.heap.markValue(heap_mod.taggedObject(ho));
                if (f.generator) |gen| self.heap.markGenerator(gen);
                // f.chunk's constants were pinned at finalize.
            }
        }
    }

    /// Install the host's built-in bindings — `print`, `console`,
    /// the typed Error constructors, plus core prototypes.
    /// Call after `init` if the realm should run user scripts.
    pub fn installBuiltins(self: *Realm) !void {
        // §26.2 — wire the FinalizationRegistry cleanup-job
        // scheduler onto the heap. `self` is stable here (the realm
        // has reached its final address by the time `installBuiltins`
        // runs), so the collector's type-erased `*Realm` context is
        // valid for the realm's lifetime. A child realm sharing the
        // parent's heap (`initChild`) re-points this at itself — the
        // last installer wins, which is fine: a cleanup job is host-
        // queued and any realm sharing the heap can drain it.
        self.heap.setFinalizationEnqueue(self, finalizationEnqueueJob);

        const print_fn = try self.heap.allocateFunctionNative(printNative, 1, "print");
        try self.globals.put(self.allocator, "print", heap_mod.taggedFunction(print_fn));

        // Minimal `console` object with a `log` method bound to
        // the same printer. Lets test scripts that conventionally
        // call `console.log(x)` work without us having to teach
        // every test the host's name for a logger.
        const console_obj = try self.heap.allocateObject();
        try console_obj.set(self.allocator, "log", heap_mod.taggedFunction(print_fn));
        try self.globals.put(self.allocator, "console", heap_mod.taggedObject(console_obj));

        // typed Error constructors + prototype chain.
        try intrinsics_mod.install(self);
    }

    /// Install the engine's **debug / test-only host hooks** on
    /// `globalThis`. Each of these is documented as "real host
    /// never exposes this"; they exist for inline unit tests, the
    /// test262 harness, and `cynic run --debug-globals`-style
    /// invocations that want a deterministic trigger for behaviour
    /// the spec leaves unspecified.
    ///
    /// **Do not call this from a production embedding.** Each hook
    /// is a real attack surface for an untrusted script:
    ///   - `__collectGarbage` → DoS via forced GC, timing leverage
    ///   - `__clearKeptObjects` → §9.10 [[KeptAlive]] confusion,
    ///     WeakRef target observation
    ///   - `__drainMicrotasks` → forced job boundaries, TOCTOU on
    ///     async ordering
    ///
    /// `installBuiltins` deliberately does NOT install these — a
    /// fresh Cynic realm is debug-clean by default. The test262
    /// harness, the inline test helpers, and the playground all
    /// opt in explicitly.
    pub fn installTestGlobals(self: *Realm) !void {
        // Forces a full (major) mark-sweep cycle. Not in the spec;
        // `$262.gc()` is the test262 equivalent and the canonical
        // way to ask for a deterministic GC trigger from
        // `built-ins/WeakRef` / `built-ins/FinalizationRegistry`
        // fixtures and inline tests with the same shape.
        const gc_fn = try self.heap.allocateFunctionNative(collectGarbageNative, 0, "__collectGarbage");
        try self.globals.put(self.allocator, "__collectGarbage", heap_mod.taggedFunction(gc_fn));

        // Companion to `__collectGarbage`: synchronously runs
        // §9.10.4.2 ClearKeptObjects. Job boundaries (microtask
        // drain / top-level entry boundaries) normally fire this;
        // inline tests that don't cross one need a synchronous
        // drop of the per-job kept-alive list so a follow-up
        // `__collectGarbage()` can actually weak-clear a WeakRef
        // target the constructor / `deref()` pinned.
        const ck_fn = try self.heap.allocateFunctionNative(clearKeptObjectsNative, 0, "__clearKeptObjects");
        try self.globals.put(self.allocator, "__clearKeptObjects", heap_mod.taggedFunction(ck_fn));

        // Forces a microtask-queue drain. Real ECMAScript hosts
        // drain automatically at "completion of a job" — Cynic's
        // CLI does the same around `cynic eval` / `cynic run`,
        // but inline tests asserting microtask ordering need
        // direct access. Lives on `globalThis.__drainMicrotasks`.
        const drain_fn = try self.heap.allocateFunctionNative(@import("builtins/promise.zig").microtaskDrainNative, 0, "__drainMicrotasks");
        try self.globals.put(self.allocator, "__drainMicrotasks", heap_mod.taggedFunction(drain_fn));
    }
};

/// `print(...args)` — appends each argument's string form to
/// the realm's output buffer, separated by single spaces and
/// terminated by a newline. Returns `undefined`. The host (CLI
/// or test runner) is responsible for flushing the buffer.
fn printNative(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = this_value;
    for (args, 0..) |v, i| {
        if (i > 0) realm.output.append(realm.allocator, ' ') catch return error.OutOfMemory;
        appendValueText(realm, v) catch return error.OutOfMemory;
    }
    realm.output.append(realm.allocator, '\n') catch return error.OutOfMemory;
    return Value.undefined_;
}

/// `globalThis.__collectGarbage()` — host hook backing the
/// deterministic-GC test trigger. Runs a full (major) mark-sweep
/// cycle so genuinely-weak WeakRef / WeakMap / WeakSet /
/// FinalizationRegistry behaviour is observable from a unit test.
/// Not a spec built-in.
/// `globalThis.__clearKeptObjects()` — host hook backing the
/// deterministic-job-boundary test trigger. Drops every entry
/// from §9.10 [[KeptAlive]] so a follow-up `__collectGarbage()`
/// can observe a WeakRef target as unreachable (the constructor /
/// `deref()` pin the target across the current job; the spec
/// clears the list at the next job boundary, but inline unit
/// tests don't cross one). Not a spec built-in.
fn clearKeptObjectsNative(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = this_value;
    _ = args;
    realm.clearKeptObjects();
    return Value.undefined_;
}

fn collectGarbageNative(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = this_value;
    _ = args;
    realm.collectGarbage();
    return Value.undefined_;
}

fn appendValueText(realm: *Realm, v: Value) !void {
    var buf: [64]u8 = undefined;
    if (v.isInt32()) {
        const m = try std.fmt.bufPrint(&buf, "{d}", .{v.asInt32()});
        try realm.output.appendSlice(realm.allocator, m);
    } else if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) {
            try realm.output.appendSlice(realm.allocator, "NaN");
        } else if (std.math.isInf(d)) {
            try realm.output.appendSlice(realm.allocator, if (d > 0) "Infinity" else "-Infinity");
        } else {
            const m = try std.fmt.bufPrint(&buf, "{d}", .{d});
            try realm.output.appendSlice(realm.allocator, m);
        }
    } else if (v.isBool()) {
        try realm.output.appendSlice(realm.allocator, if (v.asBool()) "true" else "false");
    } else if (v.isNull()) {
        try realm.output.appendSlice(realm.allocator, "null");
    } else if (v.isUndefined()) {
        try realm.output.appendSlice(realm.allocator, "undefined");
    } else if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        try realm.output.appendSlice(realm.allocator, s.flatBytes());
    } else if (heap_mod.valueAsBigInt(v)) |bi| {
        const m = try @import("bigint.zig").toStringAlloc(realm.allocator, bi, 10);
        defer realm.allocator.free(m);
        try realm.output.appendSlice(realm.allocator, m);
    } else if (heap_mod.isFunction(v)) {
        try realm.output.appendSlice(realm.allocator, "[function]");
    } else if (heap_mod.isPlainObject(v)) {
        try realm.output.appendSlice(realm.allocator, "[object Object]");
    } else {
        try realm.output.appendSlice(realm.allocator, "[unknown]");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Realm: init / deinit round-trip" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    // Heap is reachable through the realm and usable for allocation.
    const s = try realm.heap.allocateString("hello");
    try testing.expectEqualStrings("hello", s.flatBytes());
}

test "Realm: deinit frees heap-allocated strings" {
    // Leak detection comes from `testing.allocator`. If `deinit`
    // forgets the heap's string list, this test fails on shutdown.
    var realm = Realm.init(testing.allocator);
    _ = try realm.heap.allocateString("leakable");
    realm.deinit();
}
