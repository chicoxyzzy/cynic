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
const shared_data_block = @import("shared_data_block.zig");
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
/// Bins are direct-indexed by `register_count` (the array is grown
/// lazily on first release of each size). That replaces the earlier
/// `AutoHashMap(u32, …)` keyed on the count, whose `Wyhash(u32)` on
/// every acquire + release showed up at ~6 % of `method_call.js`
/// samples — a hot method loop hashed the same tiny integer twice
/// per call. Direct indexing collapses that to one bounds check +
/// one load. Empty bins are 16-byte `ArrayListUnmanaged` headers, so
/// the memory overhead is bounded by the largest function's register
/// count (~tens of KB even at pathological extremes).
///
/// Bin entries are owned `[]Value` slices freed individually at
/// `realm.deinit`.
pub const FramePool = struct {
    bins: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]Value)) = .empty,
    /// Single-slot fast cache in front of the binned free-list. A
    /// tight call loop runs one frame at a time, so it releases and
    /// then immediately re-acquires the same-arity register file every
    /// iteration; the fast slot turns that into a length-compare + a
    /// pointer move, skipping the `bins` index and the inner
    /// ArrayList pop/append. A size mismatch or a nested call falls
    /// through to `bins` unchanged. The cached buffer is free (never a
    /// GC root) exactly like a binned one; the caller memsets it
    /// before reuse. The slot only changes WHICH free buffer of size
    /// `n` is handed back, never whether one is — semantically inert.
    fast: ?[]Value = null,

    /// Pop a register file of exactly `n` from the pool, or
    /// allocate a fresh one on miss. Caller is responsible for
    /// memset'ing to `undefined` before use — buffer contents
    /// are stale from the previous frame.
    pub fn acquire(self: *FramePool, allocator: std.mem.Allocator, n: usize) ![]Value {
        if (self.fast) |buf| {
            if (buf.len == n) {
                self.fast = null;
                return buf;
            }
        }
        if (n < self.bins.items.len) {
            const bin = &self.bins.items[n];
            if (bin.items.len > 0) return bin.pop().?;
        }
        return try allocator.alloc(Value, n);
    }

    /// Return a register file to the fast slot when it's free,
    /// otherwise to its size's bin. On allocation failure (the bins
    /// vector can't grow, or its inner list can't append), fall back
    /// to freeing the slice directly — pool growth is best-effort.
    pub fn release(self: *FramePool, allocator: std.mem.Allocator, regs: []Value) void {
        if (self.fast == null) {
            self.fast = regs;
            return;
        }
        const n = regs.len;
        if (n >= self.bins.items.len) {
            const new_len = n + 1;
            self.bins.ensureTotalCapacity(allocator, new_len) catch {
                allocator.free(regs);
                return;
            };
            while (self.bins.items.len < new_len) {
                self.bins.appendAssumeCapacity(.empty);
            }
        }
        self.bins.items[n].append(allocator, regs) catch {
            allocator.free(regs);
        };
    }

    pub fn deinit(self: *FramePool, allocator: std.mem.Allocator) void {
        if (self.fast) |buf| allocator.free(buf);
        for (self.bins.items) |*bin| {
            for (bin.items) |buf| allocator.free(buf);
            bin.deinit(allocator);
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
    /// Stable views of `decl_env.values()` / `decl_consts.values()`
    /// for compiled code's slot ops (docs/jit.md §4.4) — machine
    /// code loads a slice pointer instead of walking ArrayHashMap
    /// internals. Refreshed in `createLexBinding`, the only growth
    /// site; in-place slot writes never move the backing array.
    decl_slots: []Value = &.{},
    decl_const_flags: []bool = &.{},
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
    /// Bump-on-add counter for the declarative env. The `lda_global`
    /// IC records this at fill time so the fast path can confirm
    /// no new `let` / `const` / `class` has been declared at script
    /// scope under a name that would now shadow the cached
    /// object-env hit. Only `installScriptLexBinding` bumps it (and
    /// only on a fresh `!found_existing` add) — reassigning a
    /// pre-existing decl via `putDecl` doesn't change which env a
    /// lookup resolves through, so an already-filled cell stays
    /// authoritative. `decl_env`-resolved names never fill a cell
    /// (the fast path serves the object-env slot), so a cell hit
    /// implies an object-env hit at fill time.
    decl_revision: u64 = 0,

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

    /// Top-level `var` / `function` declarations route through
    /// §9.1.1.4.18 CreateGlobalVarBinding / §9.1.1.4.19
    /// CreateGlobalFunctionBinding. Both create the property on the
    /// global object with `{[[Writable]]:true, [[Enumerable]]:true,
    /// [[Configurable]]:D}` where `D` is the "deletable" flag.
    ///
    /// `deletable` (D) is the spec's per-call argument:
    ///   - **false** for §16.1.7 GlobalDeclarationInstantiation
    ///     (source-text scripts, `ShadowRealm.prototype.evaluate`) —
    ///     a top-level script `var x` is non-configurable.
    ///   - **true** for §19.2.1.3 EvalDeclarationInstantiation steps
    ///     15.c.i / 16.a.i (a non-strict indirect `eval` whose
    ///     declarations bind on the global env) — the property is
    ///     deletable, so `delete x` succeeds afterward.
    /// Either way this differs from a direct `globalThis.x = 1` (the
    /// regular `put` path — configurable, non-enumerable to match host
    /// built-in shape).
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
        deletable: bool,
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
                    .configurable = deletable,
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
    /// configurable:D}` when CanDeclareGlobalFunction has already
    /// approved. The caller (compiler) is responsible for running
    /// that approval check; here we just install. Any existing
    /// accessor descriptor is replaced with a data descriptor.
    ///
    /// `deletable` (D) is false for §16.1.7 script-source function
    /// declarations (non-configurable) and true for a non-strict
    /// indirect `eval`'s §19.2.1.3 step 15.c.i declarations
    /// (configurable / deletable).
    pub fn installScriptFunctionBinding(
        self: *GlobalBindings,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: Value,
        deletable: bool,
    ) !void {
        try self.var_names.put(allocator, key, {});
        if (self.target) |t| {
            // §9.1.1.4.18 CreateGlobalFunctionBinding step 6 — when an
            // existing own DATA property is non-configurable, the
            // install is a value-only define: its writable /
            // enumerable / configurable attributes are preserved, not
            // re-stamped (an indirect eval's function decl over a
            // pre-defined `{configurable: false}` global must leave
            // the descriptor intact).
            if (t.hasOwn(key) and t.getAccessor(key) == null and !t.flagsFor(key).configurable) {
                if (self.heap) |h| h.writeBarrier(.{ .object = t }, value);
                const fl = t.flagsFor(key);
                try t.setWithFlags(allocator, key, value, fl);
                return;
            }
            _ = t.removeAccessor(key);
            // Generational write barrier — `setWithFlags` bypasses
            // the routed `heap.storeProperty` path.
            if (self.heap) |h| h.writeBarrier(.{ .object = t }, value);
            try t.setWithFlags(allocator, key, value, .{
                .writable = true,
                .enumerable = true,
                .configurable = deletable,
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
            // Invalidate every `lda_global` IC cell in the realm
            // — a newly-declared lex binding outranks the cached
            // object-env slot for the same name.
            self.decl_revision +%= 1;
        }
        try self.decl_consts.put(allocator, key, is_const);
        self.decl_slots = self.decl_env.values();
        self.decl_const_flags = self.decl_consts.values();
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

/// §25.4.1.4 one pending `Atomics.waitAsync` whose Promise is still
/// unsettled. `resolve` is the capability's resolve function (called
/// with `"timed-out"` or `"ok"` when the wait settles); `deadline_ms` is
/// an absolute monotonic timestamp in milliseconds (`+inf` for an
/// untimed wait, which only a cross-agent notify can settle). `node` is
/// this waiter's entry on `block`'s process-global wait list, where a
/// cross-agent `notify` finds it; the waiting agent reads `node.woken`
/// to decide "ok" vs "timed-out" and frees the node on settle.
pub const AsyncWaitRecord = struct {
    resolve: Value,
    deadline_ms: f64,
    node: *shared_data_block.Waiter,
    block: *shared_data_block.SharedDataBlock,
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
    /// For a child realm: the realm whose `child_realms` holds it.
    /// The teardown finalizer removes the child from this list before
    /// freeing it, so the eventual parent `deinit` doesn't double-free.
    /// `null` for a top-level realm (not in any `child_realms`).
    created_by: ?*Realm = null,
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
    /// Bump-allocated register-file stack for non-generator,
    /// non-async JS callees. Frames push their register file on
    /// call and pop on return — LIFO discipline matches the
    /// `frames` ArrayList's call-stack shape, so a stack handles
    /// the common case without per-call malloc / free. Generator
    /// and async frames keep going through `frame_pool` because
    /// their register file must outlive the suspending call.
    ///
    /// The buffer is pre-allocated at `Realm.init` to a fixed
    /// capacity so its underlying memory never moves — slices
    /// into it stay valid for the lifetime of the frame. A
    /// request that would push past the end returns null; the
    /// caller falls back to `frame_pool` (still correct, just
    /// slower). 32 K slots covers the 1024-frame
    /// `max_call_frames` ceiling × ~32 typical register-counts
    /// with headroom; degenerate workloads with wider frames spill
    /// to the pool transparently.
    value_stack: []Value = &.{},
    value_stack_top: usize = 0,
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
    /// §10.2.5 — the realm of the native function currently
    /// executing, as recorded by the call dispatcher just before
    /// it invokes a `native_callback`. Multiple realms share the
    /// same native body (e.g. every realm's
    /// `ShadowRealm.prototype.evaluate` points at the same Zig
    /// function), so a native can't otherwise tell which realm's
    /// copy of itself was called. The §3.8 ShadowRealm methods
    /// read this as their "caller realm" — for
    /// `YetAnotherShadowRealm.prototype.evaluate.call(otherInstance,
    /// …)` the boundary errors / WrappedFunctions must be tagged
    /// with YetAnotherRealm (the function's realm), not the
    /// instance's owner realm. `null` outside a native call. The
    /// dispatcher saves / restores it around every native
    /// invocation, so nested native calls don't clobber an outer
    /// frame's value.
    active_native_fn_realm: ?*Realm = null,
    /// The native function currently executing, recorded by the call
    /// dispatcher around every native invocation (saved / restored for
    /// nesting, like `active_native_fn_realm`). A native that needs
    /// per-callee state — e.g. a WebAssembly exported function reaching
    /// its `(instance, func_index)` — reads it here, since the native
    /// signature does not pass the callee.
    active_native_fn: ?*@import("function.zig").JSFunction = null,
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
    /// §25.5.2 scratch buffers reused across `JSON.stringify` calls.
    /// A tight `JSON.stringify(obj)` hot loop would otherwise pay
    /// (allocate, grow to ~hundreds of bytes, free) for `buf`,
    /// `state.stack`, and `state.indent` on every iteration. The
    /// pool retains the highest-water capacity reached on prior
    /// calls; only the first non-trivial call pays the realloc
    /// chain. Lifetime: top-level `jsonStringify` checks
    /// `json_scratch_in_use`, takes the pool, resets length to 0
    /// (capacity retained), runs, releases. Re-entry via `toJSON`
    /// or a replacer that calls `JSON.stringify(otherObj)` finds
    /// the flag set and falls back to fresh per-call allocations
    /// — correctness preserved at the cost of one realloc chain
    /// for the rare nested case.
    json_scratch_buf: std.ArrayListUnmanaged(u8) = .empty,
    json_scratch_stack: std.ArrayListUnmanaged(*@import("object.zig").JSObject) = .empty,
    json_scratch_indent: std.ArrayListUnmanaged(u8) = .empty,
    json_scratch_in_use: bool = false,
    /// §25.4.1.4 pending async waiters — one per `Atomics.waitAsync`
    /// whose value matched and whose timeout is non-zero, so its
    /// Promise is still unsettled. Each record carries the capability's
    /// resolve function and an absolute monotonic deadline (ms). The
    /// spec fires the timeout "in parallel"; with no real event loop the
    /// host drives it — polling these deadlines while draining
    /// microtasks and resolving an expired waiter with `"timed-out"`.
    /// (Cross-agent `notify` resolution is separate.) `markRoots` keeps
    /// each resolve function live.
    pending_async_waits: std.ArrayListUnmanaged(AsyncWaitRecord) = .empty,
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
    /// Source buffers retained for `--allow=eval` runtime code
    /// construction. Two producers:
    ///   • §19.2.1 eval(string) — a copy of the eval source (the
    ///     user's argument may be a transient heap JSString that GC
    ///     can reclaim, but the compiled chunk lives in `script_chunks`
    ///     and its function templates borrow slices of the source for
    ///     `Function.prototype.toString`).
    ///   • §20.2.1.1.1 CreateDynamicFunction — the synthesized
    ///     `(function anonymous(P){B})` wrapper.
    /// Both must outlive the chunks that borrow them, so they're owned
    /// here and freed at realm teardown alongside `script_chunks`.
    /// Only populated under `--allow=eval`.
    eval_sources: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Cooperative interpreter step budget. Decremented once per
    /// opcode in `runFrames`; on reaching zero the dispatch loop
    /// raises a synthetic `RangeError("step budget exhausted")`
    /// and unwinds. Default is `maxInt(u64)` — hosts that need
    /// bounded execution (test runners, sandboxed shells, slow-
    /// script watchers) set a lower value before each run.
    step_budget: u64 = std.math.maxInt(u64),
    /// Externally-flippable interrupt flag. Any thread (including
    /// a SIGALRM-style watchdog or a host UI thread) can call
    /// `requestInterrupt`. The interpreter dispatch loop polls this
    /// between opcodes (the loop back-edge safe point) and throws
    /// `RangeError("execution interrupted")` when set.
    ///
    /// NOTE: unlike V8's `Isolate::TerminateExecution` / JSC's
    /// `Watchdog::fire`, this exception is currently **catchable** —
    /// the thrown `RangeError` is an ordinary value that a user
    /// `try`/`catch` (or `assert.throws`) can swallow, after which
    /// execution resumes. A true watchdog abort needs uncatchable
    /// termination (a "terminating" mode that `unwindThrow` honours
    /// by skipping every handler, à la the existing
    /// `gen_return_completion` step-past-catch path); that isn't
    /// implemented yet, so a wedged fixture inside a `try` block
    /// can't be force-unwound.
    interrupt: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Optional host-supplied interrupt flag. Unlike `interrupt` (a
    /// per-realm field), this points at storage the host keeps alive
    /// longer than the realm — so a watchdog thread can flip it
    /// without racing the realm's teardown. The test262 harness aims
    /// it at a stable per-worker abort flag; null for ordinary
    /// embeddings.
    ///
    /// NOTE: this flag is currently **not polled** anywhere in the
    /// engine — only `interrupt` is checked at the safe points. Wiring
    /// it in (the safe points should poll `interrupt OR (host_interrupt
    /// and *host_interrupt)`) is a prerequisite for the test262
    /// watchdog to abort a wedged worker, but is insufficient on its
    /// own without the uncatchable-termination work noted on
    /// `interrupt` above. Until both land, the harness relies on
    /// `--exclude`ing the handful of fixtures that wedge under
    /// `--gc-threshold=1` (see the gc-stress CI job).
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
    feature_flags: FeatureSet = FeatureSet.empty,
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
    /// `--allow=eval` posture toggle. When `false` (the default)
    /// Cynic refuses runtime code construction: `eval` and the
    /// `Function` / `Generator…Function` / `Async…Function`
    /// string-source constructors throw EvalError by policy
    /// (§19.2.1.2 HostEnsureCanCompileStrings; SES-aligned — see
    /// AGENTS.md "eval and runtime code construction"). Setting it
    /// `true` opens the gate so the eval engine runs the source in
    /// the realm (§19.2.1 PerformEval, §20.2.1.1.1
    /// CreateDynamicFunction); the frozen primordials still confine
    /// it unless `hardened` is also off. Distinct from `hardened`:
    /// a build can be unhardened yet eval-off, or hardened yet
    /// eval-on — they're orthogonal capabilities. See
    /// docs/ses-alignment.md.
    allow_eval: bool = false,
    /// §25.4.3.14 AgentCanSuspend — whether the surrounding agent may
    /// block on `Atomics.wait`. `true` by default: Cynic targets edge
    /// / Worker / server hosts whose main agent can suspend, so a
    /// blocking wait is allowed. A host that runs Cynic in a context
    /// that must never block (an HTML-main-thread-style agent, or a
    /// runtime that forbids synchronous suspension) sets this `false`,
    /// and `Atomics.wait` then throws TypeError per step 9 instead of
    /// parking. `Atomics.waitAsync` is unaffected — it is designed to
    /// run on a non-blocking agent. The test262 harness flips this off
    /// for `flags: [CanBlockIsFalse]` fixtures.
    agent_can_block: bool = true,
    /// `--allow=wasm` posture toggle. When `false` (the default) the
    /// WebAssembly code-construction surface (`compile` / `instantiate`
    /// / `new Module` / `new Instance`) throws by policy
    /// (HostEnsureCanCompileWasmBytes; SES-aligned, orthogonal to
    /// `allow_eval`). `WebAssembly.validate` is ungated — it only
    /// inspects bytes. Set `true` to open the gate.
    allow_wasm: bool = false,
    /// `--jit` posture toggle (docs/jit.md §10). When `true` the
    /// engine tiers hot chunks up to Bistromath-compiled code; when
    /// `false` (the default while the tier lands) everything stays
    /// on Lantern and the chunk warmth counters merely accumulate.
    /// Targets without codegen support (docs/jit.md §8) ignore it.
    jit_enabled: bool = false,
    /// Tier-up threshold override for the differential gate
    /// (docs/jit.md §10 step 2): `1` force-compiles every eligible
    /// chunk on its first call so a test262 sweep exercises
    /// Bistromath everywhere. `null` uses the size-scaled default
    /// (docs/jit.md §4.7).
    jit_threshold_override: ?u32 = null,
    /// Lazily-created arena owning every realm-resident WebAssembly
    /// artifact (decoded modules, instances, their store state). Freed
    /// wholesale at realm teardown, so wasm objects need no per-object
    /// cleanup. The realm-owned store of docs/wasm-engine.md §7.
    wasm_arena: ?std.heap.ArenaAllocator = null,
    /// The most recently decoded `WebAssembly.Module` in this realm — a
    /// non-owning pointer into `wasm_arena`, so it needs no teardown. The
    /// playground's `cynic_wasm_inspect` reads it to disassemble (to WAT)
    /// the module a snippet built; ordinary eval ignores it. Typed opaque
    /// to keep the module layout out of the realm's interface.
    last_wasm_module: ?*const anyopaque = null,
    /// `WebAssembly.Global.prototype`, cached at install so an instance's
    /// global exports can be wrapped as `Global` objects.
    wasm_global_prototype: ?*@import("object.zig").JSObject = null,
    /// `WebAssembly.Table.prototype`, cached at install so table exports
    /// can be wrapped as `Table` objects.
    wasm_table_prototype: ?*@import("object.zig").JSObject = null,
    /// `WebAssembly.Memory.prototype`, cached at install so memory
    /// exports can be wrapped as `Memory` objects.
    wasm_memory_prototype: ?*@import("object.zig").JSObject = null,
    /// `WebAssembly.Tag.prototype` / `Exception.prototype`, cached at
    /// install so exported tags + uncaught exceptions can be wrapped.
    wasm_tag_prototype: ?*@import("object.zig").JSObject = null,
    wasm_exception_prototype: ?*@import("object.zig").JSObject = null,
    /// Sentinel tag identity for a foreign JS value caught by a wasm
    /// `try_table` — its address is unique to this realm, so no wasm
    /// `catch $tag` ever matches it and only `catch_all` / `catch_all_ref`
    /// catch a plain JS throw.
    wasm_foreign_exn_tag: @import("wasm/wasm.zig").TagType = .{ .params = &.{} },
    /// `WebAssembly.Module.prototype` / `Instance.prototype`, cached at
    /// install so `WebAssembly.compile` / `instantiate` can build those
    /// objects without `new`.
    wasm_module_prototype: ?*@import("object.zig").JSObject = null,
    wasm_instance_prototype: ?*@import("object.zig").JSObject = null,
    /// `WebAssembly.{CompileError,LinkError,RuntimeError}.prototype`,
    /// cached at install so the engine can throw the right error class.
    wasm_compile_error_prototype: ?*@import("object.zig").JSObject = null,
    wasm_link_error_prototype: ?*@import("object.zig").JSObject = null,
    wasm_runtime_error_prototype: ?*@import("object.zig").JSObject = null,
    /// `externref` GC rooting, reclaimed precisely (docs/wasm-engine.md §5):
    ///
    /// - **Transient** — `externref` values live on the wasm value stack /
    ///   in locals *during* a call (where a host import could trigger GC),
    ///   keyed by NaN-boxed bits (deduped; the non-moving collector makes
    ///   the bits a stable identity). Cleared when the outermost wasm call
    ///   returns to JS (`wasm_call_depth` hits 0) — by then the stack is
    ///   empty and any escapee is rooted by its JS caller.
    /// - **Persistent** — `externref` cells inside tables / globals are
    ///   marked precisely by walking the registered containers, so an
    ///   overwritten or dropped slot is reclaimed.
    wasm_extern_roots: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    /// Nesting of JS→wasm entries (the export trampoline). The transient
    /// set is cleared when this returns to 0.
    wasm_call_depth: u32 = 0,
    /// Registered `externref` tables / global cells, walked each GC so
    /// their live JS values survive. The lists grow with the number of
    /// such containers (bounded), not the number of values.
    wasm_extern_tables: std.ArrayListUnmanaged(*const @import("wasm/wasm.zig").Table) = .empty,
    wasm_extern_global_cells: std.ArrayListUnmanaged(*const u128) = .empty,
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
        r.value_stack = allocator.alloc(Value, value_stack_capacity) catch unreachable;
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
        r.value_stack = allocator.alloc(Value, value_stack_capacity) catch unreachable;
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
            // The eval posture is an agent-wide capability — a child
            // realm inherits the parent's `--allow=eval` setting so a
            // cross-realm `new other.Function(src)` is gated the same
            // way as a same-realm one.
            .allow_eval = parent.allow_eval,
            // Children inherit the host module loader so a child
            // realm can resolve module specifiers — required by
            // `ShadowRealm.prototype.importValue`, which loads a
            // module in the child realm. Without this the child's
            // loader is null and every import fails
            // `error.ModuleNotFound`.
            .module_loader = parent.module_loader,
            // Children inherit the parent's enabled feature set so a
            // flag-gated builtin is present in the child too — without
            // this, nested `new ShadowRealm()` inside `.evaluate()`
            // would skip the ShadowRealm install on the grandchild.
            .feature_flags = parent.feature_flags,
        };
        r.globals.heap = parent.heap;
        r.value_stack = parent.allocator.alloc(Value, value_stack_capacity) catch unreachable;
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
            "unscopables", "dispose",       "asyncDispose",
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

    /// Pre-allocated capacity for `value_stack`, in slots. 32 K ×
    /// `@sizeOf(Value)` ≈ 256-512 KB per realm. Covers the
    /// 1024-frame `max_call_frames` ceiling with headroom for
    /// wider-than-typical register counts; a per-frame request
    /// past the end returns null and the caller falls back to
    /// `frame_pool` transparently.
    pub const value_stack_capacity: usize = 32 * 1024;

    /// Allocate `n` value slots from the bump-allocated value
    /// stack. Returns null when the request would push past the
    /// pre-allocated buffer — caller falls back to `frame_pool`.
    /// LIFO: the returned slice is contiguous at the top of the
    /// stack; `freeStackRegisters` must be called on slices in
    /// reverse order of acquisition.
    pub fn allocStackRegisters(self: *Realm, n: usize) ?[]Value {
        const start = self.value_stack_top;
        const new_top = start + n;
        if (new_top > self.value_stack.len) return null;
        self.value_stack_top = new_top;
        return self.value_stack[start..new_top];
    }

    /// Return `n` slots to the stack. LIFO contract: the caller
    /// must pass the most-recently-acquired slice. Debug builds
    /// could assert `regs.ptr + regs.len == &value_stack[top]`;
    /// release builds just trust the discipline.
    pub fn freeStackRegisters(self: *Realm, regs: []Value) void {
        std.debug.assert(regs.len <= self.value_stack_top);
        self.value_stack_top -= regs.len;
    }

    pub fn deinit(self: *Realm) void {
        // Drop out of the shared heap's realm set first, so a
        // collection during the rest of teardown never marks (or a
        // later sibling GC never touches) this dying realm.
        self.deregisterFromHeap();
        self.frame_pool.deinit(self.allocator);
        if (self.value_stack.len > 0) self.allocator.free(self.value_stack);
        self.globals.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.microtask_queue.deinit(self.allocator);
        self.json_scratch_buf.deinit(self.allocator);
        self.json_scratch_stack.deinit(self.allocator);
        self.json_scratch_indent.deinit(self.allocator);
        self.clearPendingAsyncWaits();
        self.pending_async_waits.deinit(self.allocator);
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
        // Free the retained `--allow=eval` source buffers (a chunk's
        // function templates borrow slices for
        // `Function.prototype.toString`; the chunks were torn down
        // just above). See `eval_sources`.
        for (self.eval_sources.items) |buf| self.allocator.free(buf);
        self.eval_sources.deinit(self.allocator);
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
        if (self.wasm_arena) |*a| a.deinit();
        self.wasm_extern_roots.deinit(self.allocator);
        self.wasm_extern_tables.deinit(self.allocator);
        self.wasm_extern_global_cells.deinit(self.allocator);
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

    /// Copy `source` into a realm-owned buffer and return the copy.
    /// Used by the `--allow=eval` paths so a chunk compiled from
    /// transient source text (a user eval string, a synthesized
    /// `Function` wrapper) can safely borrow slices for the lifetime
    /// of the realm. Freed at teardown — see `eval_sources`.
    pub fn retainEvalSource(self: *Realm, source: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, source);
        self.eval_sources.append(self.allocator, copy) catch |err| {
            self.allocator.free(copy);
            return err;
        };
        return copy;
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
        // The import job runs later off the queue, after the
        // enqueuing opcode's locals (including any freshly-coerced
        // `with { type: ... }` attribute slice) have gone out of
        // scope. Borrowing the caller's slice would dangle, so the
        // queue owns its own copy; `runModuleImportJob` frees it.
        const owned_attr: ?[]const u8 = if (attribute_type) |t|
            try self.allocator.dupe(u8, t)
        else
            null;
        try self.microtask_queue.append(self.allocator, .{
            .kind = .module_import,
            .callback = specifier,
            .reaction_result = result_promise,
            .module_import_base = base_url,
            .module_import_attribute_type = owned_attr,
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

    /// Lazily-initialised allocator owning every realm-resident
    /// WebAssembly artifact (decoded modules, instances, store state).
    /// Lives until `realm.deinit`. See docs/wasm-engine.md §7.
    pub fn wasmAllocator(self: *Realm) std.mem.Allocator {
        if (self.wasm_arena == null) {
            self.wasm_arena = std.heap.ArenaAllocator.init(self.allocator);
        }
        return self.wasm_arena.?.allocator();
    }

    /// Pin a JS value as a *transient* wasm `externref` GC root (deduped),
    /// kept until the outermost wasm call returns. Primitives (non-heap
    /// values) are skipped — the collector never touches them.
    pub fn pinExternRefTransient(self: *Realm, v: Value) !void {
        if (!v.isHeapValue()) return;
        try self.wasm_extern_roots.put(self.allocator, v.bits, {});
    }

    /// Enter / leave a JS→wasm call (the export trampoline). On the
    /// outermost return the stack is empty, so transient externref pins
    /// are dropped — only container-held values stay rooted.
    pub fn enterWasmCall(self: *Realm) void {
        self.wasm_call_depth += 1;
    }
    pub fn leaveWasmCall(self: *Realm) void {
        self.wasm_call_depth -= 1;
        if (self.wasm_call_depth == 0) self.wasm_extern_roots.clearRetainingCapacity();
    }

    /// Register an externref table / global cell so its live JS values are
    /// marked each GC (precise: an overwritten or dropped slot is freed).
    pub fn registerExternTable(self: *Realm, t: *const @import("wasm/wasm.zig").Table) !void {
        try self.wasm_extern_tables.append(self.allocator, t);
    }
    pub fn registerExternGlobalCell(self: *Realm, cell: *const u128) !void {
        try self.wasm_extern_global_cells.append(self.allocator, cell);
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
    /// Detach + free every pending async waiter's heap node from its
    /// block (so none dangles on a still-shared block), then empty the
    /// list. Leaves the Promises unsettled — for realm teardown or an
    /// agent-realm reset where the realm is going away / being scrubbed.
    pub fn clearPendingAsyncWaits(self: *Realm) void {
        for (self.pending_async_waits.items) |w| _ = w.block.settleAndFreeAsyncWaiter(w.node);
        self.pending_async_waits.clearRetainingCapacity();
    }

    pub fn collectGarbage(self: *Realm) void {
        // §26.1 / §24.3 / §24.4 / §26.2 — arm the major cycle
        // BEFORE `markRoots`. `markRoots` calls `markValue` on every
        // realm root (including any WeakRef / WeakMap / WeakSet /
        // FinalizationRegistry held by a global), so both the
        // `live_color` flip and the `weak_aware_mark` flag must
        // already be in place. `collectFull` sees `cycle_started`
        // and skips its own arm-cycle.
        self.heap.beginMajorCycle();
        self.markAllSharingRealmRoots();
        // Arm the conservative native-stack rooting backstop when a
        // native builtin is on the stack — the full collector tenures
        // (and so can free) the young generation just like the minor
        // one, so a young heap pointer held only in a native local
        // across a JS re-entry needs the same backstop. Critically, at
        // `--gc-threshold=1` EVERY cycle is a full cycle, so without
        // this the backstop never runs under gc-stress. See
        // `Heap.scan_native_stack` and `Realm.collectGarbageYoung`.
        self.heap.scan_native_stack = self.active_native_fn != null;
        // Hand off to `heap.collectFull` for the handle-scope walk
        // and the actual sweep. The empty roots slice is fine —
        // every root above is already marked.
        self.heap.collectFull(&.{});
        self.drainRealmTeardown();
    }

    /// Mark roots from EVERY realm sharing this heap, not just
    /// `self`. With `Realm.initChild` (`$262.createRealm` /
    /// `ShadowRealm`) several realms share one heap and one set of
    /// object pools; the sweep frees every unmarked object, so
    /// marking only the running realm's roots would reclaim a
    /// sibling realm's live objects — a cross-realm use-after-free.
    /// Mirrors V8's global GC, which marks every live Context's
    /// roots. Falls back to `self` if the heap's realm set is empty
    /// (a realm collecting before it registered at `installBuiltins`).
    fn markAllSharingRealmRoots(self: *Realm) void {
        if (self.heap.realms.items.len == 0) {
            self.markRoots();
            return;
        }
        for (self.heap.realms.items) |r| r.markRoots();
    }

    /// Register `self` in the shared heap's realm set so the
    /// collector marks its roots. Idempotent. Call once `self` is at
    /// its final address (`installBuiltins`).
    pub fn registerWithHeap(self: *Realm) !void {
        for (self.heap.realms.items) |r| if (r == self) return;
        try self.heap.realms.append(self.allocator, self);
    }

    /// Remove `self` from the shared heap's realm set — its roots
    /// stop being marked, so its now-unreachable objects are
    /// reclaimed by the next collection. Used at `deinit` and by the
    /// ShadowRealm finalizer (per-realm teardown).
    pub fn deregisterFromHeap(self: *Realm) void {
        const items = self.heap.realms.items;
        for (items, 0..) |r, i| {
            if (r == self) {
                _ = self.heap.realms.swapRemove(i);
                return;
            }
        }
    }

    /// Run a minor (young-generation) collection. Marks exactly the
    /// same realm roots as `collectGarbage`, then hands off to
    /// `heap.collectYoung`, which additionally walks the dirty-
    /// container list and every mature container's typed internal
    /// slots, sweeps only the young lists, and promotes-or-ages young
    /// survivors into the mature generation by relink (non-moving).
    pub fn collectGarbageYoung(self: *Realm) void {
        // Debug-only barrier audit — under Debug / ReleaseSafe this
        // asserts every barriered (bag / element / slot / env-parent)
        // mature→young edge has its container in the dirty list before
        // the minor cycle scans it. The strongest guard that aging's
        // dirty-list retention + promotion-time remembering stays
        // complete (a swept young referent would otherwise surface as
        // a 0xaa-poison crash inside the cycle).
        self.heap.verifyRememberedSet();
        // Arm the minor cycle BEFORE `markRoots` so the `live_color`
        // flip precedes any `markValue` call. `collectYoung` sees
        // `cycle_started` and skips its own arm-cycle.
        self.heap.beginMinorCycle();
        self.markAllSharingRealmRoots();
        // Arm the conservative native-stack rooting backstop only when a
        // native builtin is executing — the sole window an unrooted young
        // heap pointer can sit in a native local across a re-entry. Pure-JS
        // young pointers are already rooted via the frame stack, so this
        // keeps the backstop's scan + young-set build off the hot alloc
        // loop. See `Heap.scan_native_stack`.
        self.heap.scan_native_stack = self.active_native_fn != null;
        self.heap.collectYoung(&.{});
        self.drainRealmTeardown();
    }

    /// Tear down the child realms whose `ShadowRealm` wrapper objects
    /// were found dead during the sweep just completed (queued on
    /// `heap.pending_realm_teardown` by `queueShadowRealmTeardown`).
    /// Runs post-sweep so freeing a `Realm` — which re-enters the
    /// allocator and frees its globals / intrinsics maps — never
    /// happens mid-walk. The child's own heap objects survived this
    /// cycle (the child was still registered when roots were marked);
    /// once `child.deinit` deregisters it, the next GC reclaims them.
    fn drainRealmTeardown(self: *Realm) void {
        const pending = &self.heap.pending_realm_teardown;
        while (pending.items.len > 0) {
            const child = pending.pop().?;
            // Unlink from the owner's `child_realms` so the eventual
            // parent `deinit` doesn't double-free this child.
            if (child.created_by) |owner| {
                for (owner.child_realms.items, 0..) |c, i| {
                    if (c == child) {
                        _ = owner.child_realms.swapRemove(i);
                        break;
                    }
                }
            }
            // `deinit` also deregisters the child from `heap.realms`.
            child.deinit();
            self.allocator.destroy(child);
        }
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
        inline for (@typeInfo(Intrinsics).@"struct".field_names) |field_name| {
            const v = @field(self.intrinsics, field_name);
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

        // §25.4.1.4 pending async waiters — keep each unsettled
        // capability's resolve function alive until it fires or is
        // dropped at realm reset.
        for (self.pending_async_waits.items) |w| self.heap.markValue(w.resolve);

        // §9.10 [[KeptAlive]] — `WeakRef` constructor / `deref`
        // pin targets here for the duration of the current job.
        // Strong-mark every entry so the major collector treats
        // them as live; `drainMicrotasks` releases them at the
        // next job boundary via `clearKeptObjects`.
        for (self.kept_alive.items) |v| self.heap.markValue(v);

        // Wasm externref roots — transient values in-flight on the wasm
        // stack, plus the live cells of every registered externref table
        // / global. (REF_NULL all-ones is skipped; a non-heap externref
        // marks as a no-op.)
        for (self.wasm_extern_roots.keys()) |bits| self.heap.markValue(Value{ .bits = bits });
        const ref_null = std.math.maxInt(u128);
        for (self.wasm_extern_tables.items) |t| {
            for (t.elems) |cell| {
                if (cell != ref_null) self.heap.markValue(Value{ .bits = @truncate(cell) });
            }
        }
        for (self.wasm_extern_global_cells.items) |c| {
            if (c.* != ref_null) self.heap.markValue(Value{ .bits = @truncate(c.*) });
        }

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

        // Register with the shared heap's realm set so the collector
        // marks this realm's roots (see `Heap.realms`). `self` is at
        // its final address here. Idempotent: skip if already present
        // (installBuiltins is normally called once per realm).
        try self.registerWithHeap();

        const print_fn = try self.heap.allocateFunctionNative(self, printNative, 1, "print");
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
        const gc_fn = try self.heap.allocateFunctionNative(self, collectGarbageNative, 0, "__collectGarbage");
        try self.globals.put(self.allocator, "__collectGarbage", heap_mod.taggedFunction(gc_fn));

        // Companion to `__collectGarbage`: synchronously runs
        // §9.10.4.2 ClearKeptObjects. Job boundaries (microtask
        // drain / top-level entry boundaries) normally fire this;
        // inline tests that don't cross one need a synchronous
        // drop of the per-job kept-alive list so a follow-up
        // `__collectGarbage()` can actually weak-clear a WeakRef
        // target the constructor / `deref()` pinned.
        const ck_fn = try self.heap.allocateFunctionNative(self, clearKeptObjectsNative, 0, "__clearKeptObjects");
        try self.globals.put(self.allocator, "__clearKeptObjects", heap_mod.taggedFunction(ck_fn));

        // Forces a microtask-queue drain. Real ECMAScript hosts
        // drain automatically at "completion of a job" — Cynic's
        // CLI does the same around `cynic eval` / `cynic run`,
        // but inline tests asserting microtask ordering need
        // direct access. Lives on `globalThis.__drainMicrotasks`.
        const drain_fn = try self.heap.allocateFunctionNative(self, @import("builtins/promise.zig").microtaskDrainNative, 0, "__drainMicrotasks");
        try self.globals.put(self.allocator, "__drainMicrotasks", heap_mod.taggedFunction(drain_fn));

        // `fuzzilli(op, arg)` — Fuzzilli's host hook. Exposed only
        // through the test-globals path; the production `cynic`
        // CLI never installs it. Native lives in `builtins/fuzzilli.zig`;
        // the REPRL loop that drives it sits in `tools/fuzz/fuzz_reprl.zig`.
        const fuzzilli_fn = try self.heap.allocateFunctionNative(self, @import("builtins/fuzzilli.zig").fuzzilliNative, 2, "fuzzilli");
        try self.globals.put(self.allocator, "fuzzilli", heap_mod.taggedFunction(fuzzilli_fn));

        // Re-stamp the freeze contract over the just-installed
        // debug globals when the realm is hardened. `globals.put`
        // adds new keys with `{writable: true, configurable: true}`
        // — the defaults for §17 host-installed bindings — which
        // would leave `globalThis` non-frozen by spec
        // (`Object.isFrozen(globalThis)` would return false because
        // the three new entries are configurable). Inline tests
        // that probe `Object.isFrozen(globalThis)` against the
        // hardened default would then see a false negative driven
        // by the test harness itself, not the engine policy. The
        // freeze pass during `installBuiltins` ran before these
        // installs, so we either need to re-walk globalThis or
        // stamp the three new keys directly. Stamp the three keys —
        // cheaper than re-walking the full intrinsic graph.
        if (self.hardened) {
            if (self.globals.target) |gt| {
                const debug_keys = [_][]const u8{
                    "__collectGarbage",
                    "__clearKeptObjects",
                    "__drainMicrotasks",
                    "fuzzilli",
                };
                inline for (debug_keys) |k| {
                    try gt.property_flags.put(self.allocator, k, .{
                        .writable = false,
                        .enumerable = false,
                        .configurable = false,
                    });
                }
                // The global object is shape-resident, where attrs
                // live in the shape entries and shadow the
                // `property_flags` stamp above (kept for the
                // dictionary fallback) — re-lock every own data key
                // in-shape; already-frozen keys no-op through the
                // redefinition cache.
                _ = try gt.freezeOwnDataInShape();
            }
        }
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

// FramePool — sized free-list of `[]Value` register files. The pool
// fires on every JS-function call (acquire) and return (release), so
// these tests pin the wire-level contract the interpreter relies on:
//   * acquire(n) on a cold bin allocates a length-n slice;
//   * release(s) followed by acquire(s.len) returns the same buffer
//     (the LIFO that makes a hot method loop reuse one slice);
//   * different sizes live in different bins;
//   * deinit frees every buffer the pool is still holding.

test "FramePool: acquire on cold pool allocates a length-n slice" {
    var pool: FramePool = .{};
    defer pool.deinit(testing.allocator);

    const regs = try pool.acquire(testing.allocator, 4);
    defer testing.allocator.free(regs);

    try testing.expectEqual(@as(usize, 4), regs.len);
}

test "FramePool: release then acquire reuses the same buffer (LIFO)" {
    var pool: FramePool = .{};
    defer pool.deinit(testing.allocator);

    const first = try pool.acquire(testing.allocator, 6);
    const first_ptr = first.ptr;
    pool.release(testing.allocator, first);

    const reused = try pool.acquire(testing.allocator, 6);
    defer testing.allocator.free(reused);
    try testing.expectEqual(first_ptr, reused.ptr);
    try testing.expectEqual(@as(usize, 6), reused.len);
}

test "FramePool: different sizes do not cross-pollinate bins" {
    var pool: FramePool = .{};
    defer pool.deinit(testing.allocator);

    const a = try pool.acquire(testing.allocator, 3);
    pool.release(testing.allocator, a);

    // A request for a different size must not return the 3-slot buffer.
    const b = try pool.acquire(testing.allocator, 5);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 5), b.len);
    try testing.expect(b.ptr != a.ptr);

    // The 3-slot buffer is still pooled — re-acquiring at 3 returns it.
    const a2 = try pool.acquire(testing.allocator, 3);
    defer testing.allocator.free(a2);
    try testing.expectEqual(a.ptr, a2.ptr);
}

test "FramePool: fast slot serves the first release; the bin is LIFO behind it" {
    var pool: FramePool = .{};
    defer pool.deinit(testing.allocator);

    const a = try pool.acquire(testing.allocator, 8);
    const b = try pool.acquire(testing.allocator, 8);
    const c = try pool.acquire(testing.allocator, 8);
    // Distinct allocations even though same size.
    try testing.expect(a.ptr != b.ptr and b.ptr != c.ptr);

    // First release lands in the single-slot fast cache; the rest go
    // to the size-8 bin (LIFO).
    pool.release(testing.allocator, a); // → fast slot
    pool.release(testing.allocator, b); // → bin
    pool.release(testing.allocator, c); // → bin

    // Fast slot is handed back first (a), then the bin pops LIFO
    // (c before b). Reuse is what matters; the exact order is an
    // internal detail and every buffer comes back.
    const got1 = try pool.acquire(testing.allocator, 8);
    const got2 = try pool.acquire(testing.allocator, 8);
    const got3 = try pool.acquire(testing.allocator, 8);
    defer testing.allocator.free(got1);
    defer testing.allocator.free(got2);
    defer testing.allocator.free(got3);
    try testing.expectEqual(a.ptr, got1.ptr); // fast slot
    try testing.expectEqual(c.ptr, got2.ptr); // bin, LIFO
    try testing.expectEqual(b.ptr, got3.ptr);
}

test "FramePool: deinit frees buffers still parked in any bin" {
    // Leak detection runs through `testing.allocator`. If `deinit`
    // misses any bin's parked slices, this test fails on shutdown.
    var pool: FramePool = .{};
    const sizes = [_]usize{ 1, 4, 4, 7, 32, 32, 64 };
    for (sizes) |n| {
        const buf = try pool.acquire(testing.allocator, n);
        pool.release(testing.allocator, buf);
    }
    pool.deinit(testing.allocator);
}

test "FramePool: zero-length acquire round-trips" {
    var pool: FramePool = .{};
    defer pool.deinit(testing.allocator);

    const empty = try pool.acquire(testing.allocator, 0);
    try testing.expectEqual(@as(usize, 0), empty.len);
    pool.release(testing.allocator, empty);
}

test "GlobalBindings.decl_revision: bumps once per fresh installScriptLexBinding" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const allocator = testing.allocator;

    const r0 = realm.globals.decl_revision;
    try realm.globals.installScriptLexBinding(allocator, "x", false);
    try testing.expect(realm.globals.decl_revision == r0 + 1);

    // Re-installing the same name is idempotent — no bump.
    try realm.globals.installScriptLexBinding(allocator, "x", false);
    try testing.expect(realm.globals.decl_revision == r0 + 1);

    // A second fresh name bumps again.
    try realm.globals.installScriptLexBinding(allocator, "y", true);
    try testing.expect(realm.globals.decl_revision == r0 + 2);

    // `putDecl` updates an existing entry's VALUE — no shadow-
    // resolution change, no bump.
    try realm.globals.putDecl(allocator, "x", Value.fromInt32(42));
    try testing.expect(realm.globals.decl_revision == r0 + 2);
}

// value_stack — bump-allocated register-file storage for
// non-generator, non-async JS callees. Frames are pushed and
// popped in LIFO order, so a stack handles them without
// per-call malloc / free. Tests pin the wire-level contract
// the interpreter relies on:
//   * allocStackRegisters(n) on a cold stack returns a length-n
//     slice carved from the pre-allocated buffer;
//   * freeStackRegisters(s) restores `value_stack_top` so the
//     next acquire reuses the same memory (LIFO);
//   * a request larger than the remaining capacity returns null —
//     caller falls back to FramePool;
//   * deinit frees the pre-allocated buffer without leaking.

test "value_stack: allocStackRegisters returns a length-n slice" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const regs = realm.allocStackRegisters(4) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(usize, 4), regs.len);
    try testing.expectEqual(@as(usize, 4), realm.value_stack_top);
    realm.freeStackRegisters(regs);
    try testing.expectEqual(@as(usize, 0), realm.value_stack_top);
}

test "value_stack: LIFO acquire/release reuses the same buffer" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const a = realm.allocStackRegisters(6) orelse return error.UnexpectedNull;
    realm.freeStackRegisters(a);
    const b = realm.allocStackRegisters(6) orelse return error.UnexpectedNull;
    try testing.expectEqual(a.ptr, b.ptr);
    realm.freeStackRegisters(b);
}

test "value_stack: nested LIFO acquires" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const a = realm.allocStackRegisters(3) orelse return error.UnexpectedNull;
    const b = realm.allocStackRegisters(5) orelse return error.UnexpectedNull;
    try testing.expect(b.ptr == a.ptr + a.len);
    try testing.expectEqual(@as(usize, 8), realm.value_stack_top);
    realm.freeStackRegisters(b);
    try testing.expectEqual(@as(usize, 3), realm.value_stack_top);
    realm.freeStackRegisters(a);
    try testing.expectEqual(@as(usize, 0), realm.value_stack_top);
}

test "value_stack: overflow returns null without disturbing the stack" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const before = realm.value_stack_top;
    const oversize = realm.value_stack.len + 1;
    try testing.expect(realm.allocStackRegisters(oversize) == null);
    try testing.expectEqual(before, realm.value_stack_top);
}

test "value_stack: deinit doesn't leak even with outstanding acquires" {
    // The pre-allocated buffer is freed wholesale on deinit
    // regardless of `value_stack_top`. (In practice the
    // interpreter always pops before realm teardown, but the
    // contract holds either way.) Leak detection comes from
    // testing.allocator.
    var realm = Realm.init(testing.allocator);
    _ = realm.allocStackRegisters(16) orelse return error.UnexpectedNull;
    _ = realm.allocStackRegisters(8) orelse return error.UnexpectedNull;
    realm.deinit();
}
