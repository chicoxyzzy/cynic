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
    heap: Heap,
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
    /// and unwinds. Default is `maxInt(u64)` so non-test hosts
    /// don't trip it. The test262 harness sets a per-test value
    /// before each run so an infinite-loop fixture can't wedge
    /// the entire sweep.
    step_budget: u64 = std.math.maxInt(u64),

    pub fn init(allocator: std.mem.Allocator) Realm {
        return .{
            .allocator = allocator,
            .heap = Heap.init(allocator),
        };
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
        self.heap.deinit();
        if (self.class_arena) |*a| a.deinit();
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
    ///   • Active `frames` — each frame's accumulator, registers,
    ///     `this`, captured env, home object, owning generator,
    ///     plus the chunk it's currently executing.
    ///   • Open handle scopes (covered by `heap.collect`).
    ///
    /// Called from the interpreter dispatch loop when
    /// `heap.allocs_since_gc` crosses `heap.gc_threshold`. The
    /// counter resets to zero at the end of `heap.collect`.
    pub fn collectGarbage(
        self: *Realm,
        frames: []const @import("interpreter.zig").CallFrame,
    ) void {
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

        // Top-level chunks — plus, transitively via `markChunk`,
        // every nested function / class template they hold.
        for (self.script_chunks.items) |chunk| self.heap.markChunk(chunk);

        // Active call frames.
        for (frames) |f| {
            self.heap.markValue(f.accumulator);
            self.heap.markValue(f.this_value);
            for (f.registers) |r| self.heap.markValue(r);
            if (f.env) |env| self.heap.markEnvironment(env);
            if (f.home_object) |ho| self.heap.markValue(heap_mod.taggedObject(ho));
            if (f.generator) |gen| self.heap.markGenerator(gen);
            self.heap.markChunk(f.chunk);
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
