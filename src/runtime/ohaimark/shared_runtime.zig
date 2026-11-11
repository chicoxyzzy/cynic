//! Opt-in shared codegen on ordinary Lantern frames. Compilation refusal is
//! pre-entry only; neither a guard exit nor a runtime failure restarts a call.
const std = @import("std");
const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const Heap = @import("../heap.zig").Heap;
const Realm = @import("../realm.zig").Realm;
const lantern = @import("../lantern/interpreter.zig");
const frontend = @import("shared_backend.zig");
const driver = @import("driver.zig");
const stack_guard = @import("../../stack_guard.zig");
const QuotaAllocator = @import("../quota_allocator.zig").QuotaAllocator;

pub const Stats = struct {
    entries: u64 = 0,
    compiles: u64 = 0,
    refusals: u64 = 0,
    guard_exits: u64 = 0,
    safe_points: u64 = 0,
    completions: u64 = 0,
    last_refusal: ?anyerror = null,

    pub fn merge(self: *Stats, other: Stats) void {
        inline for (.{ "entries", "compiles", "refusals", "guard_exits", "safe_points", "completions" }) |field| @field(self, field) +|= @field(other, field);
        if (other.last_refusal) |reason| self.last_refusal = reason;
    }
};

pub const Cache = struct {
    quota: QuotaAllocator,
    owner: frontend.CodeAllocator,
    program: frontend.Program,

    // Compiler workspace must not enlarge every cached invocation's host frame.
    noinline fn init(heap: *Heap, chunk: *const Chunk) !*Cache {
        try heap.charge(@sizeOf(Cache));
        errdefer heap.discharge(@sizeOf(Cache));
        const self = try heap.allocator.create(Cache);
        errdefer heap.allocator.destroy(self);
        self.quota = .{ .backing = heap.allocator, .heap = heap };
        const allocator = self.quota.allocator();
        if (chunk.code.len > 16 * 1024) return error.PrototypeLimit;
        const reserve = try std.math.ceilPowerOfTwo(usize, @max(64 * 1024, chunk.code.len * 256));
        self.owner = try frontend.CodeAllocator.initMetered(allocator, reserve, .{ .ctx = heap, .charge_fn = chargeCode, .discharge_fn = dischargeCode });
        errdefer self.owner.deinit();
        self.program = try frontend.Program.buildWithOptions(allocator, &self.owner, chunk, .{ .execution_policy = .controlled });
        return self;
    }

    pub fn deinit(self: *Cache) void {
        const heap = self.quota.heap;
        self.program.deinit();
        self.owner.deinit();
        heap.allocator.destroy(self);
        heap.discharge(@sizeOf(Cache));
    }

    fn chargeCode(raw: *anyopaque, bytes: usize) bool {
        const heap: *Heap = @ptrCast(@alignCast(raw));
        heap.charge(bytes) catch return false;
        return true;
    }

    fn dischargeCode(raw: *anyopaque, bytes: usize) void {
        const heap: *Heap = @ptrCast(@alignCast(raw));
        heap.discharge(bytes);
    }
};

pub fn tryEnter(allocator: std.mem.Allocator, realm: *Realm, frames: *std.ArrayListUnmanaged(lantern.CallFrame)) lantern.RunError!driver.EnterOutcome {
    if (comptime !frontend.supported) return .not_entered;
    if (stack_guard.nearLimit()) return .not_entered;
    const frame = &frames.items[frames.items.len - 1];
    const state = frame.chunk.jit_state orelse return .not_entered;
    if (state.shared_backend_refused or state.shared_backend_guard_exits >= driver.guard_exit_limit) return .not_entered;
    if (state.shared_backend == null) {
        if (state.warmth < (realm.ohaimark_threshold_override orelse driver.tierUpThreshold(frame.chunk.code.len))) return .not_entered;
        state.shared_backend = Cache.init(realm.heap, frame.chunk) catch |err| {
            state.shared_backend_refused = true;
            realm.heap.ohaimark_stats.shared_backend.refusals +|= 1;
            realm.heap.ohaimark_stats.shared_backend.last_refusal = err;
            return .not_entered;
        };
        realm.heap.ohaimark_stats.shared_backend.compiles +|= 1;
    }
    if (realm.terminationReason() != null) return .safe_point;
    const cache = state.shared_backend.?;
    const stats = &realm.heap.ohaimark_stats.shared_backend;
    const outcome = cache.program.runFrame(cache.quota.allocator(), realm, frame, &stats.entries) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CallStackExhausted => return .not_entered, // checked before native entry
        else => return error.InvalidOpcode,
    };
    return switch (outcome) {
        .safe_point => blk: {
            stats.safe_points +|= 1;
            break :blk .safe_point;
        },
        .resumed => blk: {
            state.shared_backend_guard_exits +|= 1;
            stats.guard_exits +|= 1;
            break :blk .resumed;
        },
        .returned => |value| blk: {
            stats.completions +|= 1;
            frame.releaseRegisters(realm, allocator);
            _ = frames.pop();
            break :blk .{ .completed = value };
        },
    };
}

test "shared JS backend runtime: failed compilation releases every quota charge" {
    if (!frontend.supported) return error.SkipZigTest;
    var builder = @import("../../bytecode/chunk.zig").Builder.init(std.testing.allocator);
    defer builder.deinit();
    const span = @import("../../source.zig").Span{ .start = 0, .end = 1 };
    try builder.emitLoadSmi(span, 42);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(std.testing.allocator);
    const Check = struct {
        fn run(allocator: std.mem.Allocator, source: *const Chunk) !void {
            var heap = Heap.init(std.testing.allocator);
            defer heap.deinit();
            // Heap bootstrap is outside the compiler transaction under test.
            heap.allocator = allocator;
            defer heap.allocator = std.testing.allocator;
            defer std.testing.expectEqual(@as(usize, 0), heap.bytes_live) catch @panic("leaked quota charge");
            const cache = try Cache.init(&heap, source);
            cache.deinit();
        }
    };
    var baseline = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try Check.run(baseline.allocator(), &chunk);
    try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        Check.run(failing.allocator(), &chunk) catch |err| if (err != error.OutOfMemory) return err;
        try std.testing.expect(failing.has_induced_failure);
        // Code-slot free-list reclamation is best-effort; unmapping the
        // owned region must still release its full charge and all metadata.
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
