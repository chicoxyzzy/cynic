//! Bounded host storage for pending HostPromiseRejectionTracker notifications.
const std = @import("std");
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const JSObject = @import("object.zig").JSObject;
const Value = @import("value.zig").Value;

/// Optional host policy, separate from the engine's allocation-free callback.
/// Keep this value at a stable address from install() until deinit(). Install
/// before executing JS: HostPromiseRejectionTracker does not replay history.
/// Poll failure after host checkpoints; OOM/capacity failures are sticky and
/// must not be turned into catchable JS exceptions or silently ignored.
pub const PendingPromiseRejections = struct {
    pub const Failure = enum { out_of_memory, capacity_exceeded };
    roots: *heap_mod.HandleScope,
    allocator: std.mem.Allocator,
    indices: std.AutoHashMapUnmanaged(*JSObject, usize) = .empty,
    limit: usize,
    failure: ?Failure = null,
    installed: bool = false,

    pub fn init(heap: *Heap, allocator: std.mem.Allocator, limit: usize) !PendingPromiseRejections {
        return .{ .roots = try heap.openScope(), .allocator = allocator, .limit = limit };
    }

    pub fn install(self: *PendingPromiseRejections) !void {
        if (self.roots.heap.promise_rejection_tracker != null)
            return error.PromiseRejectionTrackerAlreadyInstalled;
        self.roots.heap.promise_rejection_tracker = .{ .context = self, .callback = notify };
        self.installed = true;
    }

    pub fn deinit(self: *PendingPromiseRejections) void {
        if (self.installed) {
            if (self.roots.heap.promise_rejection_tracker) |tracker| {
                if (tracker.context == @as(?*anyopaque, self) and tracker.callback == notify)
                    self.roots.heap.promise_rejection_tracker = null;
            }
        }
        self.indices.deinit(self.allocator);
        self.roots.close();
    }

    pub fn values(self: *const PendingPromiseRejections) []const Value {
        return self.roots.handles.items;
    }

    fn notify(context: ?*anyopaque, promise: *JSObject, operation: heap_mod.PromiseRejectionOperation) void {
        const self: *PendingPromiseRejections = @ptrCast(@alignCast(context.?));
        switch (operation) {
            .reject => {
                if (self.failure != null or self.indices.contains(promise)) return;
                if (self.indices.count() >= self.limit) {
                    self.failure = .capacity_exceeded;
                    return;
                }
                // These allocator calls never allocate an engine object, run
                // JS or trigger collection. A failed root push rolls back the
                // pointer key before this callback returns to the engine.
                const entry = self.indices.getOrPut(self.allocator, promise) catch {
                    self.failure = .out_of_memory;
                    return;
                };
                self.roots.push(heap_mod.taggedObject(promise)) catch {
                    _ = self.indices.remove(promise);
                    self.failure = .out_of_memory;
                    return;
                };
                entry.value_ptr.* = self.roots.handles.items.len - 1;
            },
            .handle => {
                // Release roots even after a sticky allocation/limit failure.
                const removed = self.indices.fetchRemove(promise) orelse return;
                _ = self.roots.handles.swapRemove(removed.value);
                if (removed.value < self.roots.handles.items.len) {
                    const moved = heap_mod.valueAsPlainObject(self.roots.handles.items[removed.value]).?;
                    self.indices.getPtr(moved).?.* = removed.value;
                }
            },
        }
    }
};

fn pendingPromise(heap: *Heap) !*JSObject {
    const promise = try heap.allocateObject();
    promise.brand.promise_state = .pending;
    return promise;
}

test "pending Promise rejections: roots, swap removal and released reasons" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var pending = try PendingPromiseRejections.init(&heap, std.testing.allocator, 3);
    defer pending.deinit();
    try pending.install();
    const a = try pendingPromise(&heap);
    const b = try pendingPromise(&heap);
    const c = try pendingPromise(&heap);
    const reason = try heap.allocateObject();
    heap.settlePromise(a, .rejected, heap_mod.taggedObject(reason));
    heap.settlePromise(b, .rejected, Value.undefined_);
    heap.settlePromise(c, .rejected, Value.undefined_);
    try std.testing.expectEqual(3, pending.values().len);
    heap.collect(&.{});
    try std.testing.expectEqual(4, heap.objectCount());
    heap.markPromiseHandled(b); // c moves into b's root slot.
    heap.markPromiseHandled(c);
    heap.collect(&.{});
    try std.testing.expectEqual(2, heap.objectCount());
    heap.markPromiseHandled(a);
    try std.testing.expectEqual(0, pending.values().len);
    heap.collect(&.{});
    try std.testing.expectEqual(0, heap.objectCount());
    try std.testing.expect(pending.failure == null);
}

test "pending Promise rejections: capacity failure is sticky and handling still releases roots" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var pending = try PendingPromiseRejections.init(&heap, std.testing.allocator, 1);
    defer pending.deinit();
    try pending.install();
    const a = try pendingPromise(&heap);
    const b = try pendingPromise(&heap);
    heap.settlePromise(a, .rejected, Value.undefined_);
    heap.settlePromise(b, .rejected, Value.undefined_);
    try std.testing.expectEqual(PendingPromiseRejections.Failure.capacity_exceeded, pending.failure.?);
    heap.markPromiseHandled(a);
    heap.markPromiseHandled(b);
    try std.testing.expectEqual(0, pending.values().len);
    try std.testing.expect(pending.failure != null);
}

test "pending Promise rejections: map and root allocation failures fail closed" {
    inline for (.{ false, true }) |fail_root| {
        var heap_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var host_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var heap = Heap.init(heap_allocator.allocator());
        defer heap.deinit();
        var pending = try PendingPromiseRejections.init(&heap, host_allocator.allocator(), 3);
        defer pending.deinit();
        try pending.install();
        const promise = try pendingPromise(&heap);
        if (fail_root) heap_allocator.fail_index = heap_allocator.alloc_index else host_allocator.fail_index = host_allocator.alloc_index;
        heap.settlePromise(promise, .rejected, Value.undefined_);
        try std.testing.expectEqual(PendingPromiseRejections.Failure.out_of_memory, pending.failure.?);
        try std.testing.expectEqual(0, pending.values().len);
        try std.testing.expectEqual(0, pending.indices.count());
        heap.markPromiseHandled(promise);
        try std.testing.expect(pending.failure != null);
    }
}

test "pending Promise rejections: installation preserves an existing host callback" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var first = try PendingPromiseRejections.init(&heap, std.testing.allocator, 3);
    defer first.deinit();
    try first.install();
    var second = try PendingPromiseRejections.init(&heap, std.testing.allocator, 3);
    try std.testing.expectError(error.PromiseRejectionTrackerAlreadyInstalled, second.install());
    second.deinit();
    const promise = try pendingPromise(&heap);
    heap.settlePromise(promise, .rejected, Value.undefined_);
    try std.testing.expectEqual(1, first.values().len);
}
