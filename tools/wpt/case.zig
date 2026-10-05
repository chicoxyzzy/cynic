//! One WPT fixture in a fresh, mutable-intrinsic JS shell. The Python
//! supervisor owns discovery, wall-clock deadlines and result classification.
//! A single checkpoint after the last Script keeps the WPT shell harness's
//! loading Promise from completing before the fixture registers its tests.
//! See docs/wpt.md; ECMA-262 ScriptEvaluation and Jobs/HostEnqueuePromiseJob.
const std = @import("std");
const cynic = @import("cynic");
const Realm = cynic.runtime.Realm;
const Value = cynic.runtime.Value;

// Each executor is single-threaded and handles exactly one fixture. Streaming
// output preserves already-finished subtests if a later test crashes or hangs.
threadlocal var host_io: std.Io = undefined;
threadlocal var output_bytes: usize = 0;
threadlocal var output_failed: bool = false;
const output_limit = 16 * 1024 * 1024;

fn writeOutput(bytes: []const u8) error{OutOfMemory}!void {
    if (bytes.len > output_limit - output_bytes) {
        output_failed = true;
        return error.OutOfMemory;
    }
    output_bytes += bytes.len;
    std.Io.File.stdout().writeStreamingAll(host_io, bytes) catch {
        output_failed = true;
        return error.OutOfMemory;
    };
}

// Shell diagnostics only: no user-defined coercions or getters are invoked.
fn valueText(realm: *Realm, value: Value, scratch: *[128]u8) error{OutOfMemory}![]const u8 {
    if (value.isString()) {
        const string: *cynic.runtime.JSString = @ptrCast(@alignCast(value.asString()));
        return string.flatten(realm.heap.bytes_allocator);
    }
    if (value.isInt32()) return std.fmt.bufPrint(scratch, "{d}", .{value.asInt32()}) catch error.OutOfMemory;
    if (value.isDouble()) return std.fmt.bufPrint(scratch, "{d}", .{value.asDouble()}) catch error.OutOfMemory;
    if (value.isBool()) return if (value.asBool()) "true" else "false";
    if (value.isNull()) return "null";
    if (value.isUndefined()) return "undefined";
    return "[object]";
}

fn printNative(realm: *Realm, this_value: Value, args: []const Value) cynic.runtime.function.NativeError!Value {
    _ = this_value;
    for (args, 0..) |value, index| {
        if (index != 0) try writeOutput(" ");
        var scratch: [128]u8 = undefined;
        // Primitive formatting does not re-enter JS. Arguments remain rooted
        // by the caller throughout any rope flattening / byte allocation.
        try writeOutput(try valueText(realm, value, &scratch));
    }
    try writeOutput("\n");
    return Value.undefined_;
}

fn diagnostic(io: std.Io, path: []const u8, message: []const u8) !void {
    const stderr = std.Io.File.stderr();
    try stderr.writeStreamingAll(io, path);
    try stderr.writeStreamingAll(io, ": ");
    try stderr.writeStreamingAll(io, message);
    try stderr.writeStreamingAll(io, "\n");
}

fn reportThrown(io: std.Io, path: []const u8, realm: *Realm, value: Value) !void {
    if (realm.terminationReason() != null) {
        return diagnostic(io, path, realm.terminationMessage());
    }
    // Read the ordinary message slot without invoking user accessors while
    // diagnosing a failure. No JS re-entry / GC occurs before it is rendered.
    const message = blk: {
        if (cynic.runtime.heap.valueAsPlainObject(value)) |object| {
            const candidate = object.get("message");
            if (!candidate.isUndefined()) break :blk candidate;
        }
        break :blk value;
    };
    var scratch: [128]u8 = undefined;
    const rendered = valueText(realm, message, &scratch) catch {
        return diagnostic(io, path, "uncaught exception (message unavailable)");
    };
    try diagnostic(io, path, rendered[0..@min(rendered.len, 8192)]);
}

fn positive(comptime T: type, text: []const u8) !T {
    const value = try std.fmt.parseInt(T, text, 10);
    if (value == 0) return error.InvalidArgument;
    return value;
}

fn execute(init: std.process.Init) !u8 {
    const allocator = std.heap.c_allocator;
    const io = init.io;
    host_io = io;
    var source_arena: std.heap.ArenaAllocator = .init(allocator);
    defer source_arena.deinit();
    const sources = source_arena.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    var fuel: u64 = 50_000_000;
    var memory_limit: usize = 256 * 1024 * 1024;
    var gc_threshold: u32 = 32768;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const first = args.next() orelse return error.MissingScripts;
    // This isolated query runs no JS and cannot silently replace a fixture.
    // Report the compiler's actual mode, never a caller-supplied expectation.
    if (std.mem.eql(u8, first, "--build-info")) {
        if (args.next() != null) return error.InvalidArgument;
        try writeOutput("{\"schema_version\":1,\"build_mode\":\"" ++ @tagName(@import("builtin").mode) ++ "\"}\n");
        return 0;
    }
    var argument_next: ?[]const u8 = first;
    while (argument_next) |argument| : (argument_next = args.next()) {
        if (std.mem.startsWith(u8, argument, "--fuel=")) {
            fuel = try positive(u64, argument["--fuel=".len..]);
        } else if (std.mem.startsWith(u8, argument, "--memory-limit=")) {
            memory_limit = try positive(usize, argument["--memory-limit=".len..]);
        } else if (std.mem.startsWith(u8, argument, "--gc-threshold=")) {
            gc_threshold = try positive(u32, argument["--gc-threshold=".len..]);
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.InvalidArgument;
        } else {
            try paths.append(sources, argument);
        }
    }
    if (paths.items.len == 0) return error.MissingScripts;

    var realm = Realm.init(allocator);
    defer realm.deinit(); // chunks borrow source bytes until realm teardown
    realm.hardened = false;
    realm.allow_eval = true;
    realm.allow_wasm_compile = true;
    // Both JS tiers and Spasm stay off for this first reference baseline.
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    realm.setFuel(fuel);
    realm.setMemoryLimit(memory_limit);
    realm.heap.setGcThreshold(gc_threshold);
    try realm.installBuiltins();
    const printer = try realm.heap.allocateFunctionNative(&realm, printNative, 1, "print");
    const printer_value = cynic.runtime.heap.taggedFunction(printer);
    try realm.globals.put(realm.allocator, "print", printer_value);
    if (realm.globals.get("console")) |console_value| {
        if (cynic.runtime.heap.valueAsPlainObject(console_value)) |console| {
            try console.set(realm.allocator, "log", printer_value);
        }
    }

    // Detached reactions can reject after WPT has printed a successful
    // completion. Keep only currently unhandled promises rooted until the
    // final checkpoint; the cap bounds additional host bookkeeping.
    var rejections = try cynic.runtime.PendingPromiseRejections.init(realm.heap, allocator, 65536);
    defer rejections.deinit();
    try rejections.install();

    var source_bytes: usize = 0;
    for (paths.items) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, sources, .limited(8 * 1024 * 1024)) catch |err| {
            try diagnostic(io, path, @errorName(err));
            return 1;
        };
        source_bytes += source.len;
        if (source_bytes > 64 * 1024 * 1024) return error.SourceLimitExceeded;
        const outcome = cynic.runtime.evaluateScript(realm.allocator, &realm, source) catch |err| {
            try diagnostic(io, path, @errorName(err));
            return 1;
        };
        if (outcome == .thrown) {
            try reportThrown(io, path, &realm, outcome.thrown);
            return 1;
        }
        if (output_failed) return error.OutputLimitOrWriteFailed;
        if (rejections.failure) |failure| {
            try diagnostic(io, "Promise rejection tracking", @tagName(failure));
            return 1;
        }
    }

    cynic.runtime.lantern.drainMicrotasks(realm.allocator, &realm) catch |err| {
        try diagnostic(io, "microtask checkpoint", @errorName(err));
        return 1;
    };
    if (realm.terminationReason() != null) {
        try diagnostic(io, "microtask checkpoint", realm.terminationMessage());
        return 1;
    }
    if (output_failed) return error.OutputLimitOrWriteFailed;
    if (rejections.failure) |failure| {
        try diagnostic(io, "Promise rejection tracking", @tagName(failure));
        return 1;
    }
    if (rejections.values().len != 0) {
        for (rejections.values()[0..@min(rejections.values().len, 8)]) |value| {
            const promise = cynic.runtime.heap.valueAsPlainObject(value).?;
            try reportThrown(io, "unhandled Promise rejection", &realm, promise.promise_value);
        }
        return 1;
    }
    return 0;
}

pub fn main(init: std.process.Init) void {
    const status = execute(init) catch |err| {
        diagnostic(init.io, "cynic-wpt-case", @errorName(err)) catch {};
        std.process.exit(1);
    };
    // execute() has already released the realm and all source storage.
    if (status != 0) std.process.exit(status);
}
