//! Opt-in instance tier. Refusal precedes execution; runtime errors never retry.
const std = @import("std");
const frontend = @import("backend_prototype.zig");
const interpreter = @import("interpreter.zig");
const code_alloc = @import("../jit/code_alloc.zig");
const stack_guard = @import("../../stack_guard.zig");
const native = frontend.native;

pub const Stats = struct {
    entries: u64 = 0,
    compiles: u64 = 0,
    refusals: u64 = 0,
    last_refusal: ?anyerror = null,
};

pub const Cache = struct {
    const Slot = union(enum) { untried, refused, compiled: frontend.Compiled };
    allocator: std.mem.Allocator,
    owner: code_alloc.CodeAllocator,
    slots: []Slot,

    pub fn init(allocator: std.mem.Allocator, count: usize, reserve: usize, ledger: ?code_alloc.MemoryLedger) !*Cache {
        const self = try allocator.create(Cache);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .owner = try code_alloc.CodeAllocator.initMetered(allocator, reserve, ledger), .slots = undefined };
        errdefer self.owner.deinit();
        self.slots = try allocator.alloc(Slot, count);
        @memset(self.slots, .untried);
        return self;
    }

    pub fn deinit(self: *Cache) void {
        for (self.slots) |*slot| if (slot.* == .compiled) slot.compiled.deinit();
        self.owner.deinit();
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    fn codeFor(self: *Cache, instance: *interpreter.Instance, local: usize) ?*const frontend.Compiled {
        const slot = &self.slots[local];
        if (slot.* == .untried) self.compileSlot(instance, local);
        return if (slot.* == .compiled) &slot.compiled else null;
    }

    // Keep compiler workspace off recursive invocation frames even when
    // the cached lookup is inlined into the runtime dispatcher.
    noinline fn compileSlot(self: *Cache, instance: *interpreter.Instance, local: usize) void {
        const slot = &self.slots[local];
        slot.* = .refused;
        const index = std.math.add(u32, instance.func_import_count, std.math.cast(u32, local) orelse {
            refuse(instance, error.FunctionIndex);
            return;
        }) catch {
            refuse(instance, error.FunctionIndex);
            return;
        };
        var graph = frontend.lowerInstance(self.allocator, instance, index) catch |err| {
            refuse(instance, err);
            return;
        };
        defer graph.deinit();
        const compiled = frontend.compile(self.allocator, &self.owner, &graph, .{ .execution_policy = .controlled }) catch |err| {
            refuse(instance, err);
            return;
        };
        slot.* = .{ .compiled = compiled };
        if (instance.shared_backend_diagnostics) instance.shared_backend_stats.compiles +%= 1;
    }
};

pub fn refuse(instance: *interpreter.Instance, err: anyerror) void {
    if (!instance.shared_backend_diagnostics) return;
    instance.shared_backend_stats.refusals +%= 1;
    instance.shared_backend_stats.last_refusal = err;
}

pub const Outcome = union(enum) { returned: []u128, tail_call };

pub fn run(allocator: std.mem.Allocator, instance: *interpreter.Instance, func: *const @import("code.zig").CompiledFunc, args: []const u128, execution_control: ?interpreter.ExecutionControl, reserve: usize) interpreter.Error!?Outcome {
    if (comptime !native.supported) return null;
    if (stack_guard.nearLimit()) return error.CallStackExhausted;
    if (instance.shared_backend_cache_failed) return null;
    const local = (@intFromPtr(func) - @intFromPtr(instance.funcs.ptr)) / @sizeOf(@import("code.zig").CompiledFunc);
    if (local >= instance.funcs.len) return error.SharedBackendFailure;
    const signature = instance.module.types[func.type_index];
    if (args.len != signature.params.len) return null;
    if (instance.shared_backend_cache == null) {
        instance.shared_backend_cache = Cache.init(instance.shared_backend_allocator orelse instance.gpa, instance.funcs.len, reserve, instance.spasm_memory_ledger) catch |err| {
            instance.shared_backend_cache_failed = true;
            refuse(instance, err);
            return null;
        };
    }
    const code = instance.shared_backend_cache.?.codeFor(instance, local) orelse return null;
    var arguments: [frontend.ir.max_arguments]u64 = undefined;
    var results: [frontend.ir.max_arguments]u64 = undefined;
    const words = frontend.abi.pack(signature.params, args, &arguments) catch return error.SharedBackendFailure;
    // Allocate the public result before entry, so OOM cannot replay side effects.
    const out = try allocator.alloc(u128, signature.results.len);
    errdefer allocator.free(out);
    var result = frontend.runControlledInInstance(code, instance.invocation_allocator orelse allocator, instance, words, execution_control, if (instance.shared_backend_diagnostics) &instance.shared_backend_stats.entries else null, results[0..code.code.result_types.len]) catch |err| {
        inline for (@typeInfo(interpreter.Error).error_set.error_names.?) |name| {
            if (err == @field(interpreter.Error, name)) return @field(interpreter.Error, name);
        }
        return error.SharedBackendFailure;
    };
    defer result.deinit();
    switch (result) {
        .returned => frontend.abi.unpack(signature.results, results[0..code.code.result_types.len], out) catch return error.SharedBackendFailure,
        .trapped => |trap| return trap.reason.toError(),
        .exited => |exit| {
            frontend.stageTailCall(code, instance, exit.id, exit.values) catch |err| {
                inline for (@typeInfo(interpreter.Error).error_set.error_names.?) |name| {
                    if (err == @field(interpreter.Error, name)) return @field(interpreter.Error, name);
                }
                return error.SharedBackendFailure;
            };
            allocator.free(out);
            return .tail_call;
        },
    }
    return .{ .returned = out };
}
