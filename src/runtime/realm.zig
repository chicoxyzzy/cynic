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
pub const Microtask = struct {
    kind: enum { callback, async_resume, promise_reaction } = .callback,
    callback: Value = Value.undefined_,
    arg: Value = Value.undefined_,
    async_gen: ?*@import("generator.zig").JSGenerator = null,
    async_throws: bool = false,
    /// For `.promise_reaction` — the handler for the settled
    /// state (`Value.undefined_` if absent → propagate).
    reaction_handler: Value = Value.undefined_,
    /// For `.promise_reaction` — the Promise to settle with
    /// the handler's outcome.
    reaction_result: Value = Value.undefined_,
    /// For `.promise_reaction` — true when the source Promise
    /// settled rejected (drives propagation in the no-handler
    /// case).
    reaction_was_rejected: bool = false,
};

/// Host-supplied module loader. Given a specifier (string from
/// the import declaration, e.g. `"./foo.js"`) and the importing
/// module's base URL (or `null` at the entry point), returns
/// the resolved canonical URL plus the source bytes. Both
/// slices must be valid for the realm's lifetime — typical
/// loaders allocate them off the realm's allocator.
pub const ModuleLoadResult = struct {
    /// Canonical URL — used as the cache key. Two specifiers
    /// resolving to the same source must produce identical
    /// `url` strings.
    url: []const u8,
    source: []const u8,
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
) ModuleLoaderError!ModuleLoadResult;

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
    globals: std.StringArrayHashMapUnmanaged(Value) = .empty,
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
    /// One-shot exception slot for native callbacks. A native
    /// that wants to throw a specific JS value sets this and
    /// returns `error.NativeThrew`; the dispatcher reads it,
    /// clears it, and surfaces the value as the runtime
    /// exception. Lets `Object.create(null)` etc. throw with the
    /// exact constructor / message the spec mandates rather than
    /// the generic "native error".
    pending_exception: ?Value = null,
    /// Sticky flag set when [[DefineOwnProperty]] rejected a typed-
    /// array index (per §10.4.5.3 — returns false, not throws).
    /// Object.defineProperty translates the reject to TypeError;
    /// Reflect.defineProperty translates it to `false`. The flag
    /// lets the two callers split the same throw site.
    define_own_property_rejected: bool = false,
    /// FIFO microtask queue (§9.4 HostEnqueueMicrotask). Drained
    /// at the end of every external entry — `cynic eval`,
    /// `cynic run`, each test262 invocation — and from any
    /// `await` opcode site. Each entry is a function to call
    /// with one argument.
    microtask_queue: std.ArrayListUnmanaged(Microtask) = .empty,
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
    frame_stacks: std.ArrayListUnmanaged(*std.ArrayListUnmanaged(@import("interpreter.zig").CallFrame)) = .empty,

    pub fn init(allocator: std.mem.Allocator) Realm {
        const heap_ptr = allocator.create(Heap) catch unreachable;
        heap_ptr.* = Heap.init(allocator);
        return .{
            .allocator = allocator,
            .heap = heap_ptr,
            .owns_heap = true,
        };
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
        return .{
            .allocator = allocator,
            .heap = heap_ptr,
            .owns_heap = true,
        };
    }

    /// Create a child Realm that shares `parent`'s heap. Used by
    /// `$262.createRealm()` (test262 harness) and by future
    /// ShadowRealm support — both need a fresh set of intrinsics
    /// and globals but a single agent-wide heap so values can
    /// cross realm boundaries without GC roots being split.
    pub fn initChild(parent: *Realm) Realm {
        return .{
            .allocator = parent.allocator,
            .heap = parent.heap,
            .owns_heap = false,
        };
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
            "iterator",       "asyncIterator", "hasInstance",
            "toPrimitive",    "toStringTag",   "isConcatSpreadable",
            "species",        "match",         "replace",
            "search",         "split",         "matchAll",
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
        self.globals.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.microtask_queue.deinit(self.allocator);
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
        // Globals.
        var git = self.globals.iterator();
        while (git.next()) |e| self.heap.markValue(e.value_ptr.*);

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
            self.heap.markValue(mt.reaction_handler);
            self.heap.markValue(mt.reaction_result);
        }

        // Modules — each `ModuleRecord.exports` is a plain
        // `*JSObject` on the GC heap whose property bag holds
        // every named export.
        if (self.current_module) |m| self.heap.markValue(heap_mod.taggedObject(m.exports));
        var mit = self.modules.iterator();
        while (mit.next()) |e| self.heap.markValue(heap_mod.taggedObject(e.value_ptr.*.exports));

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

        // Hand off to `heap.collect` for the handle-scope walk
        // and the actual sweep. The empty roots slice is fine —
        // every root above is already marked.
        self.heap.collect(&.{});
    }

    /// Install the host's built-in bindings — `print`, `console`,
    /// the typed Error constructors, plus core prototypes.
    /// Call after `init` if the realm should run user scripts.
    pub fn installBuiltins(self: *Realm) !void {
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
        try realm.output.appendSlice(realm.allocator, s.bytes);
    } else if (heap_mod.valueAsBigInt(v)) |bi| {
        const m = try std.fmt.bufPrint(&buf, "{d}", .{bi.value});
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
    try testing.expectEqualStrings("hello", s.bytes);
}

test "Realm: deinit frees heap-allocated strings" {
    // Leak detection comes from `testing.allocator`. If `deinit`
    // forgets the heap's string list, this test fails on shutdown.
    var realm = Realm.init(testing.allocator);
    _ = try realm.heap.allocateString("leakable");
    realm.deinit();
}
