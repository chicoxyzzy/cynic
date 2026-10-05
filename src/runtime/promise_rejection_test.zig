//! HostPromiseRejectionTracker events and internal PerformPromiseThen consumers.
//! https://tc39.es/ecma262/#sec-host-promise-rejection-tracker
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const Value = @import("value.zig").Value;
const heap = @import("heap.zig");
const JSObject = @import("object.zig").JSObject;
const lantern = @import("lantern/interpreter.zig");

const Recorder = struct {
    const Event = struct { identity: usize, operation: heap.PromiseRejectionOperation };
    events: [128]Event = undefined,
    count: usize = 0,
    failed: bool = false,
    roots: *heap.HandleScope,

    fn init(h: *heap.Heap) !Recorder {
        return .{ .roots = try h.openScope() };
    }

    fn install(self: *Recorder) void {
        self.roots.heap.promise_rejection_tracker = .{ .context = self, .callback = record };
    }

    fn deinit(self: *Recorder) void {
        self.roots.heap.promise_rejection_tracker = null;
        self.roots.close();
    }

    fn record(context: ?*anyopaque, promise: *JSObject, operation: heap.PromiseRejectionOperation) void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        if (self.count == self.events.len) {
            self.failed = true;
            return;
        }
        // Historical identities are integers, never dereferenced after GC.
        self.events[self.count] = .{ .identity = @intFromPtr(promise), .operation = operation };
        self.count += 1;
        const value = heap.taggedObject(promise);
        switch (operation) {
            .reject => self.roots.push(value) catch {
                self.failed = true;
            },
            .handle => {
                for (self.roots.handles.items, 0..) |root, index| {
                    if (root.bits == value.bits) {
                        _ = self.roots.handles.swapRemove(index);
                        return;
                    }
                }
            },
        }
    }

    fn expectOperations(self: *Recorder, expected: []const heap.PromiseRejectionOperation) !void {
        try std.testing.expect(!self.failed);
        try std.testing.expectEqual(expected.len, self.count);
        for (expected, self.events[0..self.count]) |operation, event|
            try std.testing.expectEqual(operation, event.operation);
    }

    fn expectUnhandled(self: *Recorder, count: usize) !void {
        try std.testing.expect(!self.failed);
        try std.testing.expectEqual(count, self.roots.handles.items.len);
    }
};

fn install(realm: *Realm) !void {
    realm.hardened = false;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    realm.heap.setGcThreshold(1);
}

fn evaluate(realm: *Realm, source: []const u8) !Value {
    return switch (try lantern.evaluateScript(realm.allocator, realm, source)) {
        .value => |value| value,
        else => error.UnexpectedJavaScriptCompletion,
    };
}

fn expectTrue(realm: *Realm, source: []const u8) !void {
    const value = try evaluate(realm, source);
    try std.testing.expect(value.isBool() and value.asBool());
}

fn drain(realm: *Realm) !void {
    try lantern.drainMicrotasks(realm.allocator, realm);
}

test "Promise rejection tracking: reject and first handle fire once and transfer to derived promise" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    var recorder = try Recorder.init(realm.heap);
    defer recorder.deinit();
    recorder.install();
    _ = try evaluate(&realm,
        \\let reject;
        \\const source = new Promise((resolve, r) => { reject = r; });
        \\reject(7); reject(8);
        \\const derived = source.then();
        \\source.catch(() => {});
    );
    try recorder.expectOperations(&.{ .reject, .handle });
    try std.testing.expectEqual(recorder.events[0].identity, recorder.events[1].identity);
    try recorder.expectUnhandled(0);
    try drain(&realm);
    try recorder.expectOperations(&.{ .reject, .handle, .reject });
    try std.testing.expect(recorder.events[0].identity != recorder.events[2].identity);
    try recorder.expectUnhandled(1);
    _ = try evaluate(&realm, "derived.catch(() => {}); derived.catch(() => {});");
    try recorder.expectOperations(&.{ .reject, .handle, .reject, .handle });
    try recorder.expectUnhandled(0);
}

test "Promise rejection tracking: pending handlers suppress rejection events" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    var recorder = try Recorder.init(realm.heap);
    defer recorder.deinit();
    recorder.install();
    _ = try evaluate(&realm,
        \\let reject, caught = 0;
        \\const source = new Promise((resolve, r) => { reject = r; });
        \\source.then(undefined, reason => { caught = reason; });
        \\reject(42); reject(43);
    );
    try drain(&realm);
    try expectTrue(&realm, "caught === 42;");
    try recorder.expectOperations(&.{});
    try recorder.expectUnhandled(0);
}

test "Promise rejection tracking: adoption handles its source in the thenable job" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    var recorder = try Recorder.init(realm.heap);
    defer recorder.deinit();
    recorder.install();
    _ = try evaluate(&realm,
        \\let reject, caught = 0;
        \\const source = new Promise((resolve, r) => { reject = r; });
        \\new Promise(resolve => resolve(source)).catch(reason => { caught = reason; });
        \\reject(42);
    );
    try recorder.expectOperations(&.{.reject});
    try drain(&realm);
    try expectTrue(&realm, "caught === 42;");
    try recorder.expectOperations(&.{ .reject, .handle });
    try recorder.expectUnhandled(0);
}

test "Promise rejection tracking: species and capability errors leave source unhandled" {
    inline for (.{
        "Object.defineProperty(source, 'constructor', {get() { throw 42; }});",
        "function Bad() { throw 42; } Bad[Symbol.species] = Bad; source.constructor = Bad;",
    }) |poison| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        try install(&realm);
        var recorder = try Recorder.init(realm.heap);
        defer recorder.deinit();
        recorder.install();
        try expectTrue(
            &realm,
            "const source = Promise.reject(7);" ++ poison ++
                "let caught = false; try { source.then(undefined, () => {}); } catch (e) { caught = e === 42; } caught;",
        );
        try recorder.expectOperations(&.{.reject});
        try recorder.expectUnhandled(1);
    }
}

test "Promise rejection tracking: failed Await PromiseResolve does not handle its input" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    var recorder = try Recorder.init(realm.heap);
    defer recorder.deinit();
    recorder.install();
    _ = try evaluate(&realm,
        \\const source = Promise.reject(7);
        \\Object.defineProperty(source, 'constructor', {get() { throw 42; }});
        \\let caught = 0;
        \\(async function() { try { await source; } catch (e) { caught = e; } })();
    );
    try drain(&realm);
    try expectTrue(&realm, "caught === 42;");
    try recorder.expectOperations(&.{.reject});
    try recorder.expectUnhandled(1);
}

test "Promise rejection tracking: await and async return consume pending and rejected promises" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    var recorder = try Recorder.init(realm.heap);
    defer recorder.deinit();
    recorder.install();
    _ = try evaluate(&realm,
        \\let caught = 0, reject;
        \\const pending = new Promise((resolve, r) => { reject = r; });
        \\(async function() { try { await pending; } catch (e) { if (e === 1) caught++; } })();
        \\(async function() { try { await Promise.reject(2); } catch (e) { if (e === 2) caught++; } })();
        \\(async function() { await 0; return Promise.reject(3); })().catch(e => { if (e === 3) caught++; });
        \\(async function() { throw 4; })().catch(e => { if (e === 4) caught++; });
        \\reject(1);
    );
    try drain(&realm);
    try expectTrue(&realm, "caught === 4;");
    try recorder.expectUnhandled(0);
}

test "Promise rejection tracking: async generator and async-from-sync iterator consumers" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    var recorder = try Recorder.init(realm.heap);
    defer recorder.deinit();
    recorder.install();
    _ = try evaluate(&realm,
        \\let caught = 0, reject;
        \\const pending = new Promise((resolve, r) => { reject = r; });
        \\async function* yielded() { yield Promise.reject(1); }
        \\yielded().next().catch(e => { if (e === 1) caught++; });
        \\async function* returned() { yield 0; }
        \\returned().return(Promise.reject(2)).catch(e => { if (e === 2) caught++; });
        \\returned().return(pending).catch(e => { if (e === 3) caught++; });
        \\(async function() {
        \\  try { for await (const value of [Promise.reject(4)]) {} }
        \\  catch (e) { if (e === 4) caught++; }
        \\})();
        \\reject(3);
    );
    try drain(&realm);
    try expectTrue(&realm, "caught === 4;");
    try recorder.expectUnhandled(0);
}

test "Promise rejection tracking: Array.fromAsync consumes rejection on each await path" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    var recorder = try Recorder.init(realm.heap);
    defer recorder.deinit();
    recorder.install();
    _ = try evaluate(&realm,
        \\let caught = 0, reject;
        \\const pending = new Promise((resolve, r) => { reject = r; });
        \\Array.fromAsync([Promise.reject(1)]).catch(e => { if (e === 1) caught++; });
        \\Array.fromAsync({0: pending, length: 1}).catch(e => { if (e === 2) caught++; });
        \\Array.fromAsync([0], () => Promise.reject(3)).catch(e => { if (e === 3) caught++; });
        \\reject(2);
    );
    try drain(&realm);
    try expectTrue(&realm, "caught === 3;");
    try recorder.expectUnhandled(0);
}

test "Promise rejection tracking: borrowed then across realms uses the shared heap tracker" {
    var parent = Realm.init(std.testing.allocator);
    defer parent.deinit();
    try install(&parent);
    var child = Realm.initChild(&parent);
    defer child.deinit();
    try install(&child);
    var recorder = try Recorder.init(parent.heap);
    defer recorder.deinit();
    recorder.install();
    const source = try evaluate(&parent, "Promise.reject(42);");
    try child.globals.put(child.allocator, "source", source);
    _ = try evaluate(&child, "Promise.prototype.then.call(source, undefined, () => {});");
    try recorder.expectOperations(&.{ .reject, .handle });
    try recorder.expectUnhandled(0);
    try drain(&parent);
    try drain(&child);
}

test "Promise rejection tracking: host roots preserve the reason and release handled promises" {
    var h = heap.Heap.init(std.testing.allocator);
    defer h.deinit();
    var recorder = try Recorder.init(&h);
    defer recorder.deinit();
    recorder.install();
    const reason = try h.allocateObject();
    try reason.set(std.testing.allocator, "answer", Value.fromInt32(42));
    const promise = try h.allocateObject();
    h.settlePromise(promise, .rejected, heap.taggedObject(reason));
    h.collect(&.{});
    try std.testing.expectEqual(@as(usize, 2), h.objectCount());
    const retained = heap.valueAsPlainObject(recorder.roots.handles.items[0]).?;
    try std.testing.expectEqual(Value.fromInt32(42).bits, heap.valueAsPlainObject(retained.promise_value).?.get("answer").bits);
    h.markPromiseHandled(retained);
    try recorder.expectUnhandled(0);
    h.collect(&.{});
    try std.testing.expectEqual(@as(usize, 0), h.objectCount());
}

test "Promise rejection tracking: altered constructors defer handling until PromiseResolve adoption" {
    inline for (.{
        "(async function() { try { await source; } catch (e) { caught = e; } })();",
        "(async function*() {})().return(source).catch(e => { caught = e; });",
        "Array.fromAsync({0: source, length: 1}).catch(e => { caught = e; });",
        "(async function() { try { for await (const value of [source]) {} } catch (e) { caught = e; } })();",
    }) |consume| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        try install(&realm);
        var recorder = try Recorder.init(realm.heap);
        defer recorder.deinit();
        recorder.install();
        _ = try evaluate(
            &realm,
            "let reject, caught = 0; const source = new Promise((resolve, r) => { reject = r; });" ++
                "source.constructor = undefined;" ++ consume ++ "reject(42);",
        );
        try recorder.expectOperations(&.{.reject});
        try drain(&realm);
        try expectTrue(&realm, "caught === 42;");
        try recorder.expectOperations(&.{ .reject, .handle });
        try recorder.expectUnhandled(0);
    }
}

fn rejectionModuleLoader(
    _: *Realm,
    specifier: []const u8,
    _: ?[]const u8,
    _: ?[]const u8,
) @import("realm.zig").ModuleLoaderError!@import("realm.zig").ModuleLoadResult {
    if (std.mem.eql(u8, specifier, "./direct.js"))
        return .{ .url = "./direct.js", .source = "await 0; throw 42;" };
    if (std.mem.eql(u8, specifier, "./parent.js"))
        return .{ .url = "./parent.js", .source = "import './dependency.js'; export const value = 0;" };
    if (std.mem.eql(u8, specifier, "./dependency.js"))
        return .{ .url = "./dependency.js", .source = "await 0; throw 43;" };
    return error.ModuleNotFound;
}

test "Promise rejection tracking: dynamic import and static dependencies consume module promises" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm);
    realm.module_loader = rejectionModuleLoader;
    var recorder = try Recorder.init(realm.heap);
    defer recorder.deinit();
    recorder.install();
    _ = try evaluate(&realm,
        \\let caught = 0;
        \\import('./direct.js').catch(e => { if (e === 42) caught++; });
        \\import('./parent.js').catch(e => { if (e === 43) caught++; });
    );
    try drain(&realm);
    try expectTrue(&realm, "caught === 2;");
    try recorder.expectUnhandled(0);
}
