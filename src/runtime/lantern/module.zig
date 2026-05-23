//! Module-load entry + helpers — extracted from `interpreter.zig`
//! to keep the dispatch-loop file focused.
//!
//! Hosts the §16.2.1.5 module load pipeline:
//!
//!   - LoadModuleOutcome (the typed result Value+threw flag)
//!   - loadModule (public entry; tracks recursion depth so the
//!     outermost call drains the deferred-IndirectExport
//!     validation queue once everything below it has settled)
//!   - drainPendingIndirectValidation (queue drain)
//!   - loadModuleInner (single-module load: cache → fetch →
//!     parse → compile → link → evaluate)
//!   - mergeStarKey (§15.2.1.16.3 redirect-with-ambiguity-check
//!     used by `export * from`)
//!
//! Callbacks back into interpreter.zig: `runFrames` to evaluate the
//! module body, `unwindThrow` to surface link-time SyntaxErrors,
//! plus the error makers.

const std = @import("std");

const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSFunction = @import("../function.zig").JSFunction;
const object_mod = @import("../object.zig");
const JSObject = object_mod.JSObject;
const Environment = @import("../environment.zig").Environment;
const heap_mod = @import("../heap.zig");
const intrinsics_mod = @import("../intrinsics.zig");
const Realm = @import("../realm.zig").Realm;
const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const parser_mod = @import("../../parser/parser.zig");
const compiler_mod = @import("../../bytecode/compiler.zig");
const module_mod = @import("../module.zig");
const Code = @import("../../diagnostic.zig").Code;

// Circular back to interpreter.zig for the dispatch entry, error
// makers, and the per-fixture unwind helper used at link errors.
const lantern = @import("interpreter.zig");
const CallFrame = lantern.CallFrame;
const RunError = lantern.RunError;
const RunResult = lantern.RunResult;
const runFrames = lantern.runFrames;
const unwindThrow = lantern.unwindThrow;
const makeTypeError = lantern.makeTypeError;
const makeSyntaxError = lantern.makeSyntaxError;
const run = lantern.run;


/// §16.2.1.5 module load. Resolves `specifier` via the host
/// loader, fetches+caches+evaluates the target module, and
/// returns its exports namespace as a Value. Cycles return
/// the partial in-progress namespace (matches V8 / SM
/// behaviour). later — top-level await is not yet a
/// suspension point; `await` inside a module body still uses
/// the synchronous unwrap from later. Errored modules
/// re-throw on subsequent loads.
/// §16.2.1.5 load outcome — pair a Value with a flag telling the
/// caller whether it's the module namespace (`threw = false`) or
/// an exception (`threw = true`). Without the flag, TypeError
/// objects (e.g. "module not found") would tunnel through the
/// `valueAsPlainObject != null` check and be misclassified as
/// successful namespaces — fixtures under
/// `language/expressions/dynamic-import/catch/*` rely on the
/// rejected-Promise path firing for missing-file and errored-
/// module specifiers.
pub const LoadModuleOutcome = struct {
    value: Value,
    threw: bool,
    /// The loaded module record when the load reached the
    /// "ran the body" phase. Lets callers (notably the
    /// `dynamic_import` opcode) inspect `state` /
    /// `evaluation_promise` to decide whether to wait on a
    /// suspended top-level `await` before settling the
    /// import-Promise. `null` when load failed before the
    /// body ran (loader error, parse error, compile error)
    /// or when the request was satisfied by the
    /// `realm.modules` cache.
    mr: ?*module_mod.ModuleRecord = null,
};

/// §15.2.1.16.3 / §16.2.3.7 — install a redirect for `key` on
/// the importer's namespace pointing at `src_ns[src_key]`,
/// with §15.2.1.18 step 3.c ambiguity detection.
///
/// Resolves the source's redirect chain (and the importer's
/// existing redirect chain, if any) to their terminal `(ns,
/// key)` pairs before comparing. The terminal is the
/// originating module + binding name; two `export *` paths can
/// pull in the same name through different routes but still
/// resolve to the same final binding (§15.2.1.16.3 step
/// 8.d.ii.2 vs 8.d.ii.3 — "same module + same binding name"
/// is not ambiguous). When the terminals differ, drop the
/// redirect and record the key in `ambiguous_namespace_keys` so
/// `hasOwn` / `hasProperty` return false (§9.4.6.2 /
/// §15.2.1.18 step 3.c.ii).
///
/// For ambiguity-detection purposes we also peek at the
/// terminal's value when the terminal is a property entry (not a
/// redirect) — two namespace bindings that point at the same
/// JSObject are spec-equivalent (`export * as foo from same`)
/// and shouldn't fight even though they came from different
/// importer-side intermediate modules. This is the resolution
/// step the spec captures by walking IndirectExportEntries with
/// the `~all~` import-name path: both routes land on the same
/// Module Namespace exotic, so the bindings match.
pub fn mergeStarKey(
    allocator: std.mem.Allocator,
    dst_ns: *JSObject,
    key: []const u8,
    src_ns: *JSObject,
    src_key: []const u8,
) !void {
    if (dst_ns.properties.contains(key)) return;
    if (dst_ns.hasAccessor(key)) return;
    if (dst_ns.ambiguous_namespace_keys.contains(key)) return;

    const new_resolved = module_mod.resolveRedirectChain(src_ns, src_key) catch return;

    if (dst_ns.namespace_redirects.get(key)) |existing| {
        const old_resolved = module_mod.resolveRedirectChain(existing.target_ns, existing.target_key) catch {
            try dst_ns.namespace_redirects.put(allocator, key, .{
                .target_ns = src_ns,
                .target_key = src_key,
            });
            return;
        };
        if (old_resolved.ns == new_resolved.ns and std.mem.eql(u8, old_resolved.key, new_resolved.key)) {
            return;
        }
        // §15.2.1.16.3 step 8.d.ii fallback — Cynic compiles
        // `export * as foo from src` to a value-copy of `src`'s
        // namespace on the importer's property bag. Two routes
        // that both end up holding the *same heap-object* in the
        // terminal slot trace back to the same originating
        // (module, namespace) binding under the spec's
        // IndirectExportEntry walk, so they aren't ambiguous.
        // Primitives are excluded — two modules can each declare
        // `export var both` and both hold `undefined`, but the
        // bindings are still distinct and should mark the key
        // ambiguous per §15.2.1.18 step 3.c.ii.
        const old_val = old_resolved.ns.get(old_resolved.key);
        const new_val = new_resolved.ns.get(new_resolved.key);
        if (heap_mod.valueAsPlainObject(old_val)) |old_obj| {
            if (heap_mod.valueAsPlainObject(new_val)) |new_obj| {
                if (old_obj == new_obj) return;
            }
        }
        if (heap_mod.valueAsFunction(old_val)) |old_fn| {
            if (heap_mod.valueAsFunction(new_val)) |new_fn| {
                if (old_fn == new_fn) return;
            }
        }
        _ = dst_ns.namespace_redirects.swapRemove(key);
        try dst_ns.ambiguous_namespace_keys.put(allocator, key, {});
        return;
    }
    try dst_ns.namespace_redirects.put(allocator, key, .{
        .target_ns = src_ns,
        .target_key = src_key,
    });
}

pub fn loadModule(
    allocator: std.mem.Allocator,
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
) RunError!LoadModuleOutcome {
    // §15.2.1.16 step 9 — IndirectExport validation must wait
    // until the whole link tree has finished evaluating, so each
    // dep gets its IndirectExports resolved against the parent's
    // final star-export shape (not the partial mid-cycle one).
    // Track recursion depth so the topmost call drains the
    // queued validations once everything below it has settled.
    realm.module_load_depth += 1;
    defer realm.module_load_depth -= 1;
    const outcome = try loadModuleInner(allocator, realm, specifier, base_url);
    // Drain the deferred-validation queue ONCE the topmost
    // `loadModule` is about to return — depth-1 here means we
    // were the outermost (decremented in `defer` above). If
    // validation discovers an ambiguous/circular/null
    // IndirectExport on the module we're handing back, rewrite
    // the outcome as a thrown SyntaxError so the caller (static
    // `module_load` opcode or `dynamic_import`) surfaces the
    // failure at the import site, not at first access.
    if (realm.module_load_depth == 1) {
        return drainPendingIndirectValidation(realm, outcome);
    }
    return outcome;
}

fn drainPendingIndirectValidation(
    realm: *Realm,
    outcome: LoadModuleOutcome,
) RunError!LoadModuleOutcome {
    // Walk the queued modules and validate each. If any throws,
    // mark the offending module errored and — if it's the one we
    // were about to return — rewrite the outcome. Other modules
    // hitting validation errors still get marked errored; they'll
    // surface their SyntaxError the next time they're imported.
    var rewritten = outcome;
    var i: usize = 0;
    while (i < realm.pending_indirect_export_validation.items.len) : (i += 1) {
        const mr = realm.pending_indirect_export_validation.items[i];
        if (mr.state != .evaluated) continue;
        module_mod.validateIndirectExports(mr) catch {
            mr.state = .errored;
            const ex = makeSyntaxError(realm, "indirect export does not resolve") catch return error.OutOfMemory;
            mr.error_value = ex;
            if (outcome.mr == mr and !outcome.threw) {
                rewritten = .{ .value = ex, .threw = true, .mr = mr };
            }
        };
    }
    realm.pending_indirect_export_validation.clearRetainingCapacity();
    return rewritten;
}

fn loadModuleInner(
    allocator: std.mem.Allocator,
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
) RunError!LoadModuleOutcome {
    const ModuleRecord = module_mod.ModuleRecord;
    const loader = realm.module_loader orelse {
        const ex = try makeTypeError(realm, "no module loader installed");
        return .{ .value = ex, .threw = true };
    };

    const result = loader(realm, specifier, base_url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ModuleNotFound => return .{ .value = try makeTypeError(realm, "module not found"), .threw = true },
        error.ModuleLoadError => return .{ .value = try makeTypeError(realm, "module load failed"), .threw = true },
    };

    // Cache lookup.
    if (realm.modules.get(result.url)) |mr| {
        switch (mr.state) {
            .uninstantiated, .evaluated => {
                const ns = module_mod.getModuleNamespace(realm, mr) catch return error.OutOfMemory;
                return .{ .value = heap_mod.taggedObject(ns), .threw = false, .mr = mr };
            },
            .evaluating, .evaluating_async => {
                // §16.2.1.5.4 cycle — the in-progress namespace
                // exists; brand it as the Module Namespace exotic
                // (proto:null, is_module_namespace=true) but leave
                // it extensible so the outer evaluation can keep
                // publishing exports. `.evaluating_async` is the
                // async-body-suspended variant — the body's
                // pending result Promise is held on
                // `evaluation_promise`, but a cycling importer
                // still gets the partial namespace synchronously
                // (matches §16.2.1.5 InnerModuleEvaluation step
                // 4 cycle handling).
                const ns = module_mod.getModuleNamespace(realm, mr) catch return error.OutOfMemory;
                return .{ .value = heap_mod.taggedObject(ns), .threw = false, .mr = mr };
            },
            .errored => return .{ .value = mr.error_value, .threw = true, .mr = mr },
        }
    }

    // Allocate the record + namespace BEFORE running the body
    // so cycles can find the in-progress namespace. The §9.4.6
    // Module Namespace exotic brand (proto:null, is_module_namespace=true)
    // is applied immediately; the `extensible = false` flip waits
    // until the body returns so module_export can still publish.
    const ns = realm.heap.allocateObject() catch return error.OutOfMemory;
    ns.prototype = null;
    ns.is_module_namespace = true;
    const mr = ModuleRecord.init(realm.allocator, result.url, ns) catch return error.OutOfMemory;
    mr.state = .evaluating;
    realm.modules.put(realm.allocator, result.url, mr) catch return error.OutOfMemory;

    // Parse + compile.
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const parse_arena = arena_state.allocator();

    // §16.2.1.7 ParseModule — parse errors surface as
    // SyntaxError. Likewise §16.2.1.5 InnerModuleEvaluation +
    // §16.2.1.5.2 InitializeEnvironment: any compile-time
    // resolution failure (unresolved import binding, ambiguous
    // indirect re-export, circular ResolveExport) is a
    // SyntaxError exception thrown during instantiation. The
    // dynamic-import path (§13.3.10) routes that exception
    // through IfAbruptRejectPromise to the import() Promise
    // capability's [[Reject]], so user code sees an error
    // whose `.name` is "SyntaxError".
    //
    // Parser surface: parseModule may either throw
    // `error.ParseError` *or* return a partial Program with
    // error-severity diagnostics on the side. Both shapes are
    // SyntaxError per spec — collect diagnostics and treat any
    // `severity == .err` entry as a parse failure.
    var diags: @import("../../diagnostic.zig").Diagnostics = .empty;
    const program = parser_mod.parseModule(parse_arena, result.source, &diags) catch {
        mr.state = .errored;
        const ex = makeSyntaxError(realm, "module parse error") catch return error.OutOfMemory;
        mr.error_value = ex;
        return .{ .value = ex, .threw = true };
    };
    for (diags.items) |d| {
        if (d.severity == .err) {
            mr.state = .errored;
            const ex = makeSyntaxError(realm, "module parse error") catch return error.OutOfMemory;
            mr.error_value = ex;
            return .{ .value = ex, .threw = true };
        }
    }

    mr.chunk = compiler_mod.compileModuleAsChunk(realm.allocator, realm, &program, result.source, null, result.url) catch {
        mr.state = .errored;
        const ex = makeSyntaxError(realm, "module compile error") catch return error.OutOfMemory;
        mr.error_value = ex;
        return .{ .value = ex, .threw = true };
    };
    // (chunk constants pinned inside `compileModuleAsChunk`)

    // Run the module body. JSFunctions declared inside this
    // chunk hold non-owning pointers into mr.chunk; the chunk
    // stays pinned for the realm's lifetime.
    //
    // §16.2.1.5 InnerModuleEvaluation step 14 — while a dep
    // evaluates, the executing-module reference is the dep.
    // Restore the caller's `current_module` on return so the
    // importer's subsequent `module_export` ops (for bindings
    // declared after the import hoist) land on the importer's
    // namespace, not silently no-op.
    const saved_module = realm.current_module;
    realm.current_module = mr;
    defer realm.current_module = saved_module;

    const outcome = run(allocator, realm, &mr.chunk.?) catch |err| {
        mr.state = .errored;
        return err;
    };
    switch (outcome) {
        .value, .yielded => |v| {
            // §16.2.1.5.1 [[IsAsync]] — when the module body
            // has top-level await, `run` routes through
            // `startAsyncCall` which returns a pending result
            // Promise. Per §16.2.1.5 InnerModuleEvaluation, an
            // async module's static-import dependents wait for
            // its `[[TopLevelCapability]]` to settle before
            // their bodies run.
            //
            // Cynic doesn't model the full
            // [[PendingAsyncDependencies]] count +
            // GatherAvailableAncestors machinery. Instead, we
            // record the dep's evaluation Promise on the
            // importer's `pending_async_deps` and rely on the
            // compiler-emitted `module_link_complete` opcode
            // (fired after the importer's hoisted import block,
            // before its body proper) to drain microtasks until
            // every recorded dep settles. That preserves the
            // sibling-doesn't-block invariant — sync siblings
            // get to run while an async dep is mid-await — at
            // the cost of being slightly coarser than spec
            // (rejection propagation lacks the per-parent
            // [[CycleRoot]] dance, and we drain the whole
            // microtask queue rather than just dep-settlement
            // jobs). Sufficient for the §16.2.1.5 fixtures.
            if (mr.chunk.?.is_async_module) {
                if (heap_mod.valueAsPlainObject(v)) |p_obj| {
                    if (p_obj.isPromise()) {
                        mr.evaluation_promise = v;
                        mr.state = .evaluating_async;
                        // If the importer is itself a module,
                        // hand it the pending Promise so its
                        // module_link_complete drains until we
                        // settle (or surfaces our rejection).
                        if (saved_module) |parent| {
                            parent.pending_async_deps.append(realm.allocator, mr) catch return error.OutOfMemory;
                        }
                        const final_ns = module_mod.getModuleNamespace(realm, mr) catch return error.OutOfMemory;
                        return .{ .value = heap_mod.taggedObject(final_ns), .threw = false, .mr = mr };
                    }
                }
            }
            mr.state = .evaluated;
            // §15.2.1.16 step 9 — queue this module's
            // IndirectExports for validation. We can't validate
            // here because a dep's re-export chain may resolve
            // through a star-export the *parent* installs after
            // we return. The topmost `loadModule` drains the
            // queue against final namespace shapes.
            realm.pending_indirect_export_validation.append(realm.allocator, mr) catch return error.OutOfMemory;
            const final_ns = module_mod.getModuleNamespace(realm, mr) catch return error.OutOfMemory;
            return .{ .value = heap_mod.taggedObject(final_ns), .threw = false, .mr = mr };
        },
        .thrown => |ex| {
            mr.state = .errored;
            mr.error_value = ex;
            return .{ .value = ex, .threw = true, .mr = mr };
        },
    }
}


