//! Wasm frontend for the shared backend. Bounded developer entry points
//! coexist with host-controlled execution used by the opt-in instance tier.
const std = @import("std");
const decoder = @import("decoder.zig");
const validator = @import("validator.zig");
const wasm_types = @import("types.zig");
const CompiledFunc = @import("code.zig").CompiledFunc;
const Reader = @import("reader.zig").Reader;
const Op = @import("opcodes.zig").Op;
const Module = @import("module.zig").Module;
const interpreter = @import("interpreter.zig");
const Instance = interpreter.Instance;
const metadata = @import("spasm_metadata.zig");
const simd = @import("spasm_simd.zig");
pub const abi = @import("backend_abi.zig");
pub const ir = @import("../jit/backend/ir.zig");
pub const native = @import("../jit/backend/native.zig");
pub const CodeAllocator = @import("../jit/code_alloc.zig").CodeAllocator;

pub const OwnedGraph = struct {
    arena: std.heap.ArenaAllocator,
    graph: ir.Graph,
    global_indices: []const u32,
    tail_calls: []const RuntimeTarget,

    pub fn deinit(self: *OwnedGraph) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Wasm owns instance bindings; the shared compiler sees only numbered views.
pub const Compiled = struct {
    code: native.Compiled,
    global_indices: []const u32,
    tail_calls: []const RuntimeTarget,

    pub fn deinit(self: *Compiled) void {
        self.code.allocator.free(self.global_indices);
        self.code.allocator.free(self.tail_calls);
        self.code.deinit();
        self.* = undefined;
    }
};

pub fn compile(allocator: std.mem.Allocator, owner: *CodeAllocator, graph: *const OwnedGraph, options: native.Options) !Compiled {
    const globals = try allocator.dupe(u32, graph.global_indices);
    errdefer allocator.free(globals);
    const tails = try allocator.dupe(RuntimeTarget, graph.tail_calls);
    errdefer allocator.free(tails);
    return .{ .code = try native.compileWithOptions(allocator, owner, graph.graph, options), .global_indices = globals, .tail_calls = tails };
}

/// Developer-only module entry point, not a Wasm execution tier. The temporary
/// decoder/validator workspace is capped independently of the emitted graph.
pub fn lowerModule(allocator: std.mem.Allocator, bytes: []const u8, function_index: u32) !OwnedGraph {
    if (bytes.len > 64 * 1024) return error.PrototypeLimit;
    const workspace = try allocator.alloc(u8, 8 * 1024 * 1024);
    defer allocator.free(workspace);
    var fixed = std.heap.FixedBufferAllocator.init(workspace);
    const module = try decoder.decode(fixed.allocator(), bytes);
    var memory_types: [ir.max_memories]wasm_types.MemType = undefined;
    const memories = try collectMemories(&module, &memory_types);
    const local = try localFunctionIndex(&module, function_index);
    const functions = try validator.validateModule(fixed.allocator(), &module);
    const function = &functions[local];
    return lower(allocator, function, module.types[function.type_index], memories, &module);
}

/// Compile an already validated function without capturing instance pointers.
pub fn lowerInstance(allocator: std.mem.Allocator, instance: *const Instance, function_index: u32) !OwnedGraph {
    var memory_types: [ir.max_memories]wasm_types.MemType = undefined;
    const memories = try collectMemories(instance.module, &memory_types);
    const local = try localFunctionIndex(instance.module, function_index);
    const function = &instance.funcs[local];
    return lower(allocator, function, instance.module.types[function.type_index], memories, instance.module);
}

/// Developer-only invocation. Direct calls use the existing Wasm tiers under a
/// separate bounded callee budget, not production tier selection or Realm fuel.
pub fn runInInstance(compiled: *const Compiled, instance: *Instance, args: []const u64, budget: u32) !native.Outcome {
    if (ir.wordCount(compiled.code.result_types) != 1) return error.ResultCount;
    var result: [1]u64 = .{0};
    const completion = try runResultsInInstance(compiled, instance, args, budget, &result);
    return native.Outcome.fromCompletion(completion, result[0]);
}

pub fn runResultsInInstance(compiled: *const Compiled, instance: *Instance, args: []const u64, budget: u32, results: []u64) !native.Completion {
    const code = &compiled.code;
    if (code.memory_count > ir.max_memories) return error.MemoryCount;
    var local_views: [4]native.MemoryView = undefined;
    const views = if (code.memory_count <= local_views.len) local_views[0..code.memory_count] else try code.allocator.alloc(native.MemoryView, code.memory_count);
    defer if (code.memory_count > local_views.len) code.allocator.free(views);
    try refreshMemories(instance, views, compiled.global_indices);
    var remaining = budget;
    var context: CallContext = .{ .instance = instance, .allocator = code.allocator, .remaining = &remaining, .global_indices = compiled.global_indices };
    var completion = try code.runInto(args, views, budget, if (code.call_sites.len == 0) null else .{ .context = &context, .call = CallContext.invoke }, results);
    if (completion != .exited) return completion;
    stageTailCall(compiled, instance, completion.exited.id, completion.exited.values) catch |err| {
        completion.deinit();
        return err;
    };
    completion.deinit();
    defer instance.native_tail_call = null;
    const request = &instance.native_tail_call.?;
    const signature = try callSignature(request.instance.module, request.func_index);
    const target = request.instance.funcRefAt(request.func_index) orelse return error.FunctionIndex;
    const inherited = instance.execution_control orelse request.instance.execution_control orelse switch (target) {
        .wasm => |callee| callee.instance.execution_control,
        .host => null,
    };
    var control: CalleeControl = .{ .remaining = &remaining, .inherited = inherited };
    const out = try interpreter.finishNativeTailCall(code.allocator, instance, .{ .ctx = &control, .poll_fn = CalleeControl.poll, .armed_fn = CalleeControl.armed });
    defer code.allocator.free(out);
    _ = try abi.pack(signature.results, out, results);
    return .returned;
}

pub fn runControlledInInstance(compiled: *const Compiled, allocator: std.mem.Allocator, instance: *Instance, args: []const u64, execution_control: ?interpreter.ExecutionControl, entries: ?*u64, results: []u64) !native.Completion {
    const code = &compiled.code;
    if (code.memory_count > ir.max_memories) return error.MemoryCount;
    var local_views: [4]native.MemoryView = undefined;
    const views = if (code.memory_count <= local_views.len) local_views[0..code.memory_count] else try allocator.alloc(native.MemoryView, code.memory_count);
    defer if (code.memory_count > local_views.len) allocator.free(views);
    try refreshMemories(instance, views, compiled.global_indices);
    var context: CallContext = .{ .instance = instance, .allocator = allocator, .execution_control = execution_control, .global_indices = compiled.global_indices };
    var host_control = execution_control;
    const native_control: ?native.ExecutionControl = if (host_control) |*host| blk: {
        const armed = host.isArmed();
        if (!armed and host.wake_flag == null) break :blk null;
        break :blk .{ .context = host, .poll_fn = pollExecution, .wake_flag = if (armed) null else host.wake_flag };
    } else null;
    return code.runControlledInto(allocator, args, views, .{
        .runtime = if (code.call_sites.len == 0) null else .{ .context = &context, .call = CallContext.invoke },
        .control = native_control,
        .entry_counter = entries,
    }, results);
}

fn pollExecution(raw: ?*anyopaque) !void {
    const control: *const interpreter.ExecutionControl = @ptrCast(@alignCast(raw.?));
    return switch (control.poll()) {
        .proceed => {},
        .step_budget_exhausted => error.StepBudgetExhausted,
        .cooperative_interrupted => error.ExecutionInterrupted,
        .terminated => error.ExecutionTerminated,
    };
}

fn refreshMemories(instance: *const Instance, views: []native.MemoryView, globals: []const u32) !void {
    if (instance.memories.len > views.len or views.len - instance.memories.len != globals.len) return error.MemoryCount;
    for (instance.memories, 0..) |memory, i| {
        if (memory.is_shared) return error.UnsupportedSharedMemory;
        views[i] = native.MemoryView.fromSlice(memory.data);
    }
    for (globals, views[instance.memories.len..]) |index, *view| {
        if (index >= instance.globals.len) return error.InvalidGlobal;
        view.* = native.MemoryView.fromSlice(std.mem.asBytes(&instance.globals[index].value));
    }
}

// Frontend-owned namespaces preserve all u32 function/memory indices without
// teaching the shared call ABI about Wasm operations or embedding pointers.
const RuntimeTarget = packed struct(u64) {
    index: u32,
    kind: enum(u32) { function, memory_grow, memory_copy, memory_fill, memory_init, data_drop, table_get, table_set, table_grow, table_size, table_fill, pin_references, ref_func, ref_as_non_null, call_indirect, call_ref, table_copy, table_init, elem_drop, _ } = .function,
};

fn checkCallSignature(request: native.CallRequest, params: []const ir.Type, results: []const ir.Type) !void {
    if (request.arguments.len != ir.wordCount(params) or request.results.len != ir.wordCount(results) or
        !std.mem.eql(ir.Type, request.parameter_types, params) or
        !std.mem.eql(ir.Type, request.result_types, results)) return error.CallSignatureMismatch;
}

const CallContext = struct {
    instance: *Instance,
    allocator: std.mem.Allocator,
    remaining: ?*u32 = null,
    execution_control: ?interpreter.ExecutionControl = null,
    global_indices: []const u32,

    fn invoke(raw: ?*anyopaque, request: native.CallRequest) !void {
        const self: *CallContext = @ptrCast(@alignCast(raw.?));
        if (request.captures.len % 2 != 0) return error.CallSignatureMismatch;
        if (self.instance.externref_rooter) |rooter| {
            var i: usize = 0;
            while (i < request.captures.len) : (i += 2)
                try rooter.pin(@as(u128, request.captures[i]) | (@as(u128, request.captures[i + 1]) << 64));
        }
        const target_id: RuntimeTarget = @bitCast(request.target);
        switch (target_id.kind) {
            .function, .call_indirect, .call_ref => {},
            .ref_func => {
                try checkCallSignature(request, &.{}, &.{ .i64, .i64 });
                if (self.instance.funcRefAt(target_id.index) == null) return error.FunctionIndex;
                const reference = interpreter.makeFuncRef(self.instance, target_id.index);
                request.results[0] = @truncate(reference);
                request.results[1] = @truncate(reference >> 64);
                return;
            },
            .ref_as_non_null => {
                try checkCallSignature(request, &.{ .i64, .i64 }, &.{});
                if (request.arguments[0] == std.math.maxInt(u64) and request.arguments[1] == std.math.maxInt(u64)) return error.NullReference;
                return;
            },
            .elem_drop => {
                try checkCallSignature(request, &.{}, &.{});
                if (target_id.index >= self.instance.elem_segments.len) return error.InvalidElementSegment;
                interpreter.dropElement(self.instance, target_id.index);
                return;
            },
            .pin_references => {
                try checkCallSignature(request, &.{}, &.{});
                return;
            },
            .table_get, .table_set, .table_grow, .table_size, .table_fill, .table_copy, .table_init => {
                if (target_id.index >= self.instance.tables.len) return error.OutOfBoundsTableAccess;
                const table = self.instance.tables[target_id.index];
                const addr: ir.Type = if (table.is_64) .i64 else .i32;
                switch (target_id.kind) {
                    .table_get => {
                        try checkCallSignature(request, &.{addr}, &.{ .i64, .i64 });
                        const index = request.arguments[0];
                        if (index >= table.elems.len) return error.OutOfBoundsTableAccess;
                        const value = table.elems[@intCast(index)];
                        request.results[0] = @truncate(value);
                        request.results[1] = @truncate(value >> 64);
                    },
                    .table_set => {
                        try checkCallSignature(request, &.{ addr, .i64, .i64 }, &.{});
                        const index = request.arguments[0];
                        if (index >= table.elems.len) return error.OutOfBoundsTableAccess;
                        table.elems[@intCast(index)] = @as(u128, request.arguments[1]) | (@as(u128, request.arguments[2]) << 64);
                    },
                    .table_size => {
                        try checkCallSignature(request, &.{}, &.{addr});
                        request.results[0] = table.elems.len;
                    },
                    .table_grow => {
                        try checkCallSignature(request, &.{ .i64, .i64, addr }, &.{addr});
                        const value = @as(u128, request.arguments[0]) | (@as(u128, request.arguments[1]) << 64);
                        const previous = interpreter.growTable(self.instance.gpa, table, request.arguments[2], value);
                        request.results[0] = ir.normalize(addr, previous orelse std.math.maxInt(u64));
                    },
                    .table_fill => {
                        try checkCallSignature(request, &.{ addr, .i64, .i64, addr }, &.{});
                        const value = @as(u128, request.arguments[1]) | (@as(u128, request.arguments[2]) << 64);
                        try interpreter.fillTable(table, request.arguments[0], value, request.arguments[3]);
                    },
                    .table_copy => {
                        if (request.arguments.len != 4) return error.CallSignatureMismatch;
                        const source_index = request.arguments[3];
                        if (source_index >= self.instance.tables.len) return error.OutOfBoundsTableAccess;
                        const source = self.instance.tables[@intCast(source_index)];
                        const src_addr: ir.Type = if (source.is_64) .i64 else .i32;
                        const count: ir.Type = if (table.is_64 and source.is_64) .i64 else .i32;
                        try checkCallSignature(request, &.{ addr, src_addr, count, .i32 }, &.{});
                        try interpreter.copyTable(table, source, request.arguments[0], request.arguments[1], request.arguments[2]);
                    },
                    .table_init => {
                        try checkCallSignature(request, &.{ addr, .i32, .i32, .i32 }, &.{});
                        const segment = request.arguments[3];
                        if (segment >= self.instance.elem_segments.len) return error.InvalidElementSegment;
                        try interpreter.initTable(table, self.instance.elem_segments[@intCast(segment)].values, request.arguments[0], @truncate(request.arguments[1]), @truncate(request.arguments[2]));
                    },
                    else => return error.CallSignatureMismatch,
                }
                return;
            },
            .memory_grow => {
                if (target_id.index >= self.instance.memories.len) return error.InvalidMemory;
                const memory = self.instance.memories[target_id.index];
                const ty: ir.Type = if (memory.is_64) .i64 else .i32;
                try checkCallSignature(request, &.{ty}, &.{ty});
                const previous = interpreter.growMemory(self.instance.gpa, memory, ir.normalize(ty, request.arguments[0]));
                request.results[0] = ir.normalize(ty, previous orelse std.math.maxInt(u64));
                // Several import indices can name the same backing store.
                try refreshMemories(self.instance, request.memories, self.global_indices);
                return;
            },
            .data_drop => {
                try checkCallSignature(request, &.{}, &.{});
                if (target_id.index >= self.instance.data_segments.len) return error.InvalidDataSegment;
                interpreter.dropData(self.instance, target_id.index);
                return;
            },
            .memory_copy, .memory_fill, .memory_init => {
                if (target_id.index >= self.instance.memories.len) return error.InvalidMemory;
                const memory = self.instance.memories[target_id.index];
                const addr: ir.Type = if (memory.is_64) .i64 else .i32;
                switch (target_id.kind) {
                    .memory_copy => {
                        if (request.arguments.len != 4) return error.CallSignatureMismatch;
                        const source_index = request.arguments[3];
                        if (source_index >= self.instance.memories.len) return error.InvalidMemory;
                        const source = self.instance.memories[@intCast(source_index)];
                        const src_addr: ir.Type = if (source.is_64) .i64 else .i32;
                        const count: ir.Type = if (memory.is_64 and source.is_64) .i64 else .i32;
                        try checkCallSignature(request, &.{ addr, src_addr, count, .i32 }, &.{});
                        try interpreter.copyMemory(memory, source, request.arguments[0], request.arguments[1], request.arguments[2]);
                    },
                    .memory_fill => {
                        try checkCallSignature(request, &.{ addr, .i32, addr }, &.{});
                        try interpreter.fillMemory(memory, request.arguments[0], @truncate(request.arguments[1]), request.arguments[2]);
                    },
                    .memory_init => {
                        try checkCallSignature(request, &.{ addr, .i32, .i32, .i32 }, &.{});
                        const segment = request.arguments[3];
                        if (segment >= self.instance.data_segments.len) return error.InvalidDataSegment;
                        try interpreter.initMemory(memory, self.instance.data_segments[@intCast(segment)].bytes, request.arguments[0], @truncate(request.arguments[1]), @truncate(request.arguments[2]));
                    },
                    else => return error.CallSignatureMismatch,
                }
                return;
            },
            else => return error.CallSignatureMismatch,
        }
        const resolved = try resolveCall(self.instance, target_id, request.arguments, request.parameter_types);
        const call_instance = resolved.instance;
        const call_index = resolved.index;
        const signature = resolved.signature;
        var result_types: [ir.max_arguments]ir.Type = undefined;
        const expected_results = try abi.writeTypes(signature.results, &result_types);
        if (request.results.len != ir.wordCount(expected_results) or !std.mem.eql(ir.Type, request.result_types, expected_results)) return error.CallSignatureMismatch;
        const target = call_instance.funcRefAt(call_index) orelse return error.FunctionIndex;
        const inherited = self.execution_control orelse self.instance.execution_control orelse switch (target) {
            .wasm => |callee| callee.instance.execution_control,
            .host => null,
        };
        var control: CalleeControl = .{ .remaining = self.remaining, .inherited = inherited };
        var args: [ir.max_arguments]u128 = undefined;
        try abi.unpack(signature.params, resolved.arguments, args[0..signature.params.len]);
        const result = interpreter.invokeWithControl(call_instance, self.allocator, call_index, args[0..signature.params.len], if (self.remaining != null) .{ .ctx = &control, .poll_fn = CalleeControl.poll, .armed_fn = CalleeControl.armed } else inherited) catch |err| {
            if (err == error.UncaughtException) self.instance.pending_exn = call_instance.pending_exn;
            return err;
        };
        defer self.allocator.free(result);
        try refreshMemories(self.instance, request.memories, self.global_indices);
        if (result.len != signature.results.len) return error.CallSignatureMismatch;
        _ = try abi.pack(signature.results, result, request.results);
    }
};

const ResolvedCall = struct {
    instance: *Instance,
    index: u32,
    signature: wasm_types.FuncType,
    arguments: []const u64,
};

fn resolveCall(instance: *Instance, target: RuntimeTarget, arguments: []const u64, parameter_types: ?[]const ir.Type) !ResolvedCall {
    const dynamic = target.kind == .call_indirect or target.kind == .call_ref;
    if (!dynamic and target.kind != .function) return error.CallSignatureMismatch;
    const expected = if (dynamic) try typeSignature(instance.module, target.index) else try callSignature(instance.module, target.index);
    const count = try abi.wordCount(expected.params);
    const total = count + @as(usize, if (dynamic) 2 else 0);
    if (total > ir.max_arguments or arguments.len != total) return error.CallSignatureMismatch;
    var types: [ir.max_arguments]ir.Type = undefined;
    const type_count = (try abi.writeTypes(expected.params, &types)).len;
    var callee = instance;
    var index = target.index;
    if (dynamic) {
        const extra = arguments[count..];
        const reference = if (target.kind == .call_indirect) ref: {
            if (extra[0] >= instance.tables.len) return error.UnsupportedImportCall;
            const table = instance.tables[@intCast(extra[0])];
            types[type_count] = .i32;
            types[type_count + 1] = if (table.is_64) .i64 else .i32;
            if (extra[1] >= table.elems.len) return error.UndefinedElement;
            const value = table.elems[@intCast(extra[1])];
            if (value == interpreter.REF_NULL) return error.UninitializedElement;
            break :ref value;
        } else ref: {
            types[type_count] = .i64;
            types[type_count + 1] = .i64;
            const value = @as(u128, extra[0]) | (@as(u128, extra[1]) << 64);
            if (value == interpreter.REF_NULL) return error.NullReference;
            break :ref value;
        };
        callee = if (reference >> 64 == 0) instance else interpreter.funcRefInstance(reference);
        index = interpreter.funcRefIndex(reference);
        const resolved = callee.funcRefAt(index) orelse return error.UnsupportedImportCall;
        const actual = switch (resolved) {
            .wasm => |w| w.instance.module.types[w.func.type_index],
            .host => callee.funcType(index) orelse return error.UnsupportedImportCall,
        };
        const compatible = if (target.kind == .call_ref)
            interpreter.funcCallLayoutsMatch(expected, actual)
        else
            interpreter.funcTypesEqual(expected, actual);
        if (!compatible) return error.IndirectCallTypeMismatch;
    }
    if (parameter_types) |actual| if (!std.mem.eql(ir.Type, actual, types[0 .. type_count + @as(usize, if (dynamic) 2 else 0)])) return error.CallSignatureMismatch;
    return .{ .instance = callee, .index = index, .signature = expected, .arguments = arguments[0..count] };
}

/// The generated frame is gone. Copy outgoing values before another tier can
/// allocate or re-enter JS. Pin only outgoing external references here.
// Keep the outgoing payload off ordinary recursive invocation frames.
pub noinline fn stageTailCall(compiled: *const Compiled, instance: *Instance, id: u32, values: []const u64) !void {
    if (id >= compiled.tail_calls.len) return error.InvalidNativeResult;
    const call = try resolveCall(instance, compiled.tail_calls[id], values, null);
    var request: interpreter.NativeTailCall = .{
        .instance = call.instance,
        .func_index = call.index,
        .args = @splat(0),
        .num_args = call.signature.params.len,
        .num_results = call.signature.results.len,
    };
    try abi.unpack(call.signature.params, call.arguments, request.args[0..request.num_args]);
    if (instance.externref_rooter) |rooter| for (call.signature.params, request.args[0..request.num_args]) |ty, value| {
        if (ty.heapOf() == wasm_types.heap_abs_extern) try rooter.pin(value);
    };
    instance.native_tail_call = request;
}

const CalleeControl = struct {
    remaining: ?*u32,
    inherited: ?interpreter.ExecutionControl,

    fn armed(_: *anyopaque) bool {
        return true;
    }
    fn poll(raw: *anyopaque) interpreter.ExecutionPoll {
        const self: *CalleeControl = @ptrCast(@alignCast(raw));
        if (self.inherited) |control| {
            const result = control.poll();
            if (result != .proceed) return result;
        }
        const remaining = self.remaining orelse return .proceed;
        if (remaining.* == 0) return .step_budget_exhausted;
        remaining.* -= 1;
        return .proceed;
    }
};

fn localFunctionIndex(module: *const Module, index: u32) !u32 {
    var imports: u32 = 0;
    for (module.imports) |entry| if (entry.desc == .func) {
        imports += 1;
    };
    if (index < imports) return error.UnsupportedImportedEntry;
    const local = index - imports;
    if (local >= module.funcs.len) return error.FunctionIndex;
    return local;
}

fn callSignature(module: *const Module, index: u32) !wasm_types.FuncType {
    var current: u32 = 0;
    const type_index = imported: {
        for (module.imports) |entry| if (entry.desc == .func) {
            if (current == index) break :imported entry.desc.func;
            current += 1;
        };
        const local = try localFunctionIndex(module, index);
        break :imported module.funcs[local];
    };
    return typeSignature(module, type_index);
}

fn typeSignature(module: *const Module, type_index: u32) !wasm_types.FuncType {
    if (type_index >= module.types.len) return error.FunctionIndex;
    const signature = module.types[type_index];
    _ = try abi.wordCount(signature.params);
    _ = try abi.wordCount(signature.results);
    return signature;
}

fn collectMemories(module: *const Module, out: *[ir.max_memories]wasm_types.MemType) ![]const wasm_types.MemType {
    var count: usize = 0;
    for (module.imports) |entry| {
        if (entry.desc == .func or entry.desc == .global or entry.desc == .table) continue;
        if (entry.desc != .mem) return error.UnsupportedImports;
        if (count == out.len) return error.PrototypeLimit;
        out[count] = entry.desc.mem;
        count += 1;
    }
    if (module.mems.len > out.len - count) return error.PrototypeLimit;
    @memcpy(out[count..][0..module.mems.len], module.mems);
    count += module.mems.len;
    for (out[0..count]) |memory| if (memory.limits.shared) return error.UnsupportedSharedMemory;
    return out[0..count];
}

pub fn evaluate(allocator: std.mem.Allocator, bytes: []const u8, function_index: u32, args: []const u64, budget: u32) !u64 {
    var graph = try lowerModule(allocator, bytes, function_index);
    defer graph.deinit();
    if (args.len != ir.wordCount(graph.graph.argument_types)) return error.ArgumentCount;
    if (comptime !native.supported) return error.UnsupportedTarget;
    var owner = try CodeAllocator.init(allocator, 256 * 1024);
    defer owner.deinit();
    var compiled = try native.compile(allocator, &owner, graph.graph);
    defer compiled.deinit();
    return compiled.run(args, budget);
}

const valueType = abi.valueType;

const missing = std.math.maxInt(u32);
const Instruction = struct {
    op: Op,
    offset: u32,
    immediate: u64 = 0,
    immediate_hi: u64 = 0,
    simd_opcode: u32 = 0,
    target: u32 = missing,
    pop_count: u32 = 0,
    val_count: u32 = 0,
    table_default: bool = false,
    memory_index: u32 = 0,
    secondary_index: u32 = 0,
};
const Range = struct { start: usize, end: usize };
const Control = struct { entered_reachable: bool, reachable: bool };

fn readBlockType(reader: *Reader, module: *const Module) !void {
    const first = try reader.peek();
    if (first == 0x40) {
        _ = try reader.byte();
    } else if (wasm_types.ValType.fromByte(first) != null or first == 0x63 or first == 0x64) {
        _ = try valueType(try wasm_types.readValType(reader));
    } else {
        const index = try reader.sleb(i33);
        if (index < 0 or index >= module.types.len) return error.InvalidControlFlow;
        const signature = module.types[@intCast(index)];
        if (signature.params.len > ir.max_arguments or signature.results.len > ir.max_arguments) return error.PrototypeLimit;
        for (signature.params) |ty| _ = try valueType(ty);
        for (signature.results) |ty| _ = try valueType(ty);
    }
}

fn readBranch(inst: *Instruction, function: *const CompiledFunc, side_index: *usize) !void {
    if (side_index.* >= function.side_table.len) return error.InvalidControlFlow;
    const branch = function.side_table[side_index.*];
    side_index.* += 1;
    const target = @as(i64, inst.offset) + branch.delta_ip;
    // A branch to the implicit function label targets the synthetic return.
    if (target < 0 or target > function.body.len) return error.InvalidControlFlow;
    inst.target = @intCast(target);
    inst.pop_count = branch.pop_count;
    inst.val_count = branch.val_count;
}

fn readMemoryArgument(inst: *Instruction, reader: *Reader, memories: []const wasm_types.MemType) !void {
    const alignment = try reader.uleb(u32);
    if (alignment & 0x40 != 0) inst.memory_index = try reader.uleb(u32);
    if (inst.memory_index >= memories.len) return error.InvalidMemory;
    inst.immediate = if (memories[inst.memory_index].limits.is_64) try reader.uleb(u64) else try reader.uleb(u32);
}

fn endsBlock(op: Op) bool {
    return switch (op) {
        .return_call, .return_call_indirect, .return_call_ref => true,
        .br, .br_if, .br_table, .br_on_null, .br_on_non_null, .@"if", .@"else", .select, .select_t, .@"return", .@"unreachable" => true,
        else => false,
    };
}

fn lower(allocator: std.mem.Allocator, function: *const CompiledFunc, signature: wasm_types.FuncType, memories: []const wasm_types.MemType, module: *const Module) !OwnedGraph {
    if (signature.results.len > ir.max_arguments) return error.UnsupportedSignature;
    if (function.body.len > 16 * 1024 or function.local_types.len > ir.max_arguments or
        function.max_stack > ir.max_arguments) return error.PrototypeLimit;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var global_indices: std.ArrayList(u32) = .empty;
    var tail_calls: std.ArrayList(RuntimeTarget) = .empty;
    const result_types = try abi.loweredTypes(a, signature.results);
    const argument_types = try abi.loweredTypes(a, signature.params);
    const local_types = function.local_types;
    _ = try abi.wordCount(local_types);

    var instructions: std.ArrayList(Instruction) = .empty;
    const offsets = try a.alloc(u32, function.body.len + 1);
    @memset(offsets, missing);
    // Mirror validator reachability: dead branches have no side-table entry.
    // Leaving an inner control restores its parent's reachability state.
    var controls: std.ArrayList(Control) = .empty;
    try controls.append(a, .{ .entered_reachable = true, .reachable = true });
    var reader = Reader.init(function.body);
    var side_index: usize = 0;
    while (!reader.atEnd()) {
        const offset = reader.pos;
        offsets[offset] = @intCast(instructions.items.len);
        var inst: Instruction = .{ .op = @fromBackingInt(@intCast(try reader.byte())), .offset = @intCast(offset) };
        switch (inst.op) {
            .nop, .drop, .select, .ref_is_null, .ref_as_non_null => {},
            .ref_func => inst.immediate = try reader.uleb(u32),
            .ref_null => inst.immediate = @backingInt(wasm_types.ValType.refType(true, try wasm_types.readHeapType(&reader))),
            .select_t => {
                if (try reader.uleb(u32) != 1) return error.UnsupportedType;
                _ = try valueType(try wasm_types.readValType(&reader));
            },
            .block, .loop, .@"if" => {
                try readBlockType(&reader, module);
                const parent = controls.items[controls.items.len - 1].reachable;
                if (inst.op == .@"if" and parent) try readBranch(&inst, function, &side_index);
                try controls.append(a, .{ .entered_reachable = parent, .reachable = parent });
            },
            .@"else" => {
                const control = &controls.items[controls.items.len - 1];
                // The validator emits this entry even after a terminated then arm.
                if (control.entered_reachable) try readBranch(&inst, function, &side_index);
                control.reachable = control.entered_reachable;
            },
            .end => {
                _ = controls.pop() orelse return error.InvalidControlFlow;
                if (controls.items.len == 0 and !reader.atEnd()) return error.InvalidControlFlow;
            },
            .br, .br_if, .br_on_null, .br_on_non_null => {
                _ = try reader.uleb(u32);
                const control = &controls.items[controls.items.len - 1];
                if (control.reachable) try readBranch(&inst, function, &side_index);
                if (inst.op == .br) control.reachable = false;
            },
            .br_table => {
                const count = try reader.uleb(u32);
                if (count >= ir.max_blocks) return error.PrototypeLimit;
                const control = &controls.items[controls.items.len - 1];
                // Expand into bounded conditional edges; each failed comparison
                // keeps the selector for the next case. No Wasm node enters the IR.
                for (0..@as(usize, count) + 1) |case| {
                    _ = try reader.uleb(u32);
                    inst.immediate = case;
                    inst.table_default = case == count;
                    if (control.reachable) try readBranch(&inst, function, &side_index);
                    if (case != count) try instructions.append(a, inst);
                }
                control.reachable = false;
            },
            .@"return", .@"unreachable" => controls.items[controls.items.len - 1].reachable = false,
            .local_get, .local_set, .local_tee => inst.immediate = try reader.uleb(u32),
            .global_get, .global_set => {
                const index = try reader.uleb(u32);
                _ = try valueType(metadata.globalValType(module, index) orelse return error.InvalidGlobal);
                const binding = std.mem.indexOfScalar(u32, global_indices.items, index) orelse blk: {
                    if (global_indices.items.len >= ir.max_memories - memories.len) return error.PrototypeLimit;
                    try global_indices.append(a, index);
                    break :blk global_indices.items.len - 1;
                };
                inst.immediate = index;
                inst.secondary_index = @intCast(memories.len + binding);
            },
            .memory_size, .memory_grow => {
                inst.memory_index = try reader.uleb(u32);
                if (inst.memory_index >= memories.len) return error.InvalidMemory;
            },
            .table_get, .table_set => {
                inst.memory_index = try reader.uleb(u32);
                _ = metadata.tableType(module, inst.memory_index) orelse return error.InvalidTable;
            },
            .call, .return_call => {
                inst.immediate = try reader.uleb(u32);
                _ = try callSignature(module, @intCast(inst.immediate));
                if (inst.op == .return_call) controls.items[controls.items.len - 1].reachable = false;
            },
            .call_ref, .call_indirect, .return_call_ref, .return_call_indirect => {
                inst.immediate = try reader.uleb(u32);
                _ = try typeSignature(module, @intCast(inst.immediate));
                if (inst.op == .call_indirect or inst.op == .return_call_indirect) {
                    inst.memory_index = try reader.uleb(u32);
                    _ = metadata.tableType(module, inst.memory_index) orelse return error.InvalidTable;
                }
                if (inst.op == .return_call_ref or inst.op == .return_call_indirect) controls.items[controls.items.len - 1].reachable = false;
            },
            .i32_const => inst.immediate = @as(u32, @bitCast(try reader.sleb(i32))),
            .i64_const => inst.immediate = @bitCast(try reader.sleb(i64)),
            .f32_const => inst.immediate = try reader.u32le(),
            .f64_const => inst.immediate = std.mem.readInt(u64, (try reader.bytesN(8))[0..8], .little),
            .prefix_fd => {
                inst.simd_opcode = try reader.uleb(u32);
                if (inst.simd_opcode == 12) {
                    inst.immediate = std.mem.readInt(u64, (try reader.bytesN(8))[0..8], .little);
                    inst.immediate_hi = std.mem.readInt(u64, (try reader.bytesN(8))[0..8], .little);
                } else if (memoryOperation(inst) != null) {
                    try readMemoryArgument(&inst, &reader, memories);
                } else if (vectorOperation(inst.simd_opcode) == null) return error.UnsupportedOpcode;
            },
            .prefix_fc => {
                inst.immediate = try reader.uleb(u32);
                switch (inst.immediate) {
                    0...7 => {},
                    8, 9 => {
                        inst.secondary_index = try reader.uleb(u32);
                        if (inst.secondary_index >= module.data_count_in_section) return error.InvalidDataSegment;
                        if (inst.immediate == 8) {
                            inst.memory_index = try reader.uleb(u32);
                            if (inst.memory_index >= memories.len) return error.InvalidMemory;
                        }
                    },
                    10, 11 => {
                        inst.memory_index = try reader.uleb(u32);
                        if (inst.memory_index >= memories.len) return error.InvalidMemory;
                        if (inst.immediate == 10) {
                            inst.secondary_index = try reader.uleb(u32);
                            if (inst.secondary_index >= memories.len) return error.InvalidMemory;
                        }
                    },
                    15...17 => {
                        inst.memory_index = try reader.uleb(u32);
                        _ = metadata.tableType(module, inst.memory_index) orelse return error.InvalidTable;
                    },
                    12, 13 => {
                        inst.secondary_index = try reader.uleb(u32);
                        if (inst.secondary_index >= module.elements_count) return error.InvalidElementSegment;
                        if (inst.immediate == 12) {
                            inst.memory_index = try reader.uleb(u32);
                            _ = metadata.tableType(module, inst.memory_index) orelse return error.InvalidTable;
                        }
                    },
                    14 => {
                        inst.memory_index = try reader.uleb(u32);
                        inst.secondary_index = try reader.uleb(u32);
                        _ = metadata.tableType(module, inst.memory_index) orelse return error.InvalidTable;
                        _ = metadata.tableType(module, inst.secondary_index) orelse return error.InvalidTable;
                    },
                    else => return error.UnsupportedOpcode,
                }
            },
            else => if (memoryOperation(inst) != null) {
                try readMemoryArgument(&inst, &reader, memories);
            } else if (scalarOperation(inst) == null) return error.UnsupportedOpcode,
        }
        try instructions.append(a, inst);
    }
    if (controls.items.len != 0 or side_index != function.side_table.len) return error.InvalidControlFlow;
    if (instructions.items.len == 0) return error.InvalidControlFlow;
    offsets[function.body.len] = @intCast(instructions.items.len);
    try instructions.append(a, .{ .op = .@"return", .offset = @intCast(function.body.len) });

    // Split only at branch destinations and terminators, then lower reachable
    // blocks in queue order. Every edge carries locals plus the operand stack.
    const leaders = try a.alloc(bool, instructions.items.len);
    @memset(leaders, false);
    leaders[0] = true;
    for (instructions.items, 0..) |*inst, i| {
        if (inst.target != missing) {
            inst.target = offsets[inst.target];
            if (inst.target == missing) return error.InvalidControlFlow;
            leaders[inst.target] = true;
        }
        if (endsBlock(inst.op) and i + 1 < leaders.len)
            leaders[i + 1] = true;
    }
    var ranges: std.ArrayList(Range) = .empty;
    const instruction_blocks = try a.alloc(u32, instructions.items.len);
    for (leaders, 0..) |leader, i| {
        if (leader) {
            if (ranges.items.len == ir.max_blocks) return error.PrototypeLimit;
            if (ranges.items.len != 0) ranges.items[ranges.items.len - 1].end = i;
            try ranges.append(a, .{ .start = i, .end = instructions.items.len });
        }
        instruction_blocks[i] = @intCast(ranges.items.len - 1);
    }
    for (instructions.items) |*inst| if (inst.target != missing) {
        inst.target = instruction_blocks[inst.target];
    };
    var builder: Builder = .{ .a = a };
    builder.mapping = try a.alloc(u32, ranges.items.len);
    @memset(builder.mapping, missing);
    builder.mapping[0] = 0;
    try builder.queue.append(a, 0);
    const params = try a.alloc(ir.Value, signature.params.len);
    for (params, signature.params) |*param, ty| param.* = try builder.wasmValue(ty);
    try builder.blocks.append(a, .{ .params = try builder.flatten(params) });
    try builder.block_values.append(a, params);
    var index: usize = 0;
    while (index < builder.queue.items.len) : (index += 1) {
        const byte_block = builder.queue.items[index];
        const range = ranges.items[byte_block];
        var nodes: std.ArrayList(ir.Node) = .empty;
        var locals: [ir.max_arguments]ir.Value = undefined;
        var stack: std.ArrayList(ir.Value) = .empty;
        const block_params = builder.block_values.items[index];
        if (index == 0) {
            @memcpy(locals[0..params.len], params);
            for (local_types[params.len..], params.len..) |ty, i|
                locals[i] = try builder.defaultValue(&nodes, ty);
        } else {
            @memcpy(locals[0..local_types.len], block_params[0..local_types.len]);
            try stack.appendSlice(a, block_params[local_types.len..]);
        }
        var terminator: ?ir.Terminator = null;
        for (instructions.items[range.start..range.end]) |inst| {
            if (inst.op == .prefix_fc and inst.immediate == 13) {
                try builder.runtimeCall(&nodes, inst, .{ .kind = .elem_drop, .index = inst.secondary_index }, &.{}, &.{}, &.{});
                continue;
            }
            if (inst.op == .table_get or inst.op == .table_set or (inst.op == .prefix_fc and inst.immediate >= 12 and inst.immediate <= 17)) {
                const table = metadata.tableType(module, inst.memory_index) orelse return error.InvalidTable;
                const target: RuntimeTarget = .{ .index = inst.memory_index, .kind = switch (inst.op) {
                    .table_get => .table_get,
                    .table_set => .table_set,
                    else => switch (inst.immediate) {
                        12 => .table_init,
                        14 => .table_copy,
                        15 => .table_grow,
                        16 => .table_size,
                        else => .table_fill,
                    },
                } };
                const count: usize = switch (target.kind) {
                    .table_get => 1,
                    .table_set, .table_grow => 2,
                    .table_fill, .table_copy, .table_init => 3,
                    else => 0,
                };
                if (count > stack.items.len) return error.InvalidControlFlow;
                const start = stack.items.len - count;
                var operands: [4]ir.Value = undefined;
                @memcpy(operands[0..count], stack.items[start..]);
                const has_secondary = target.kind == .table_copy or target.kind == .table_init;
                if (has_secondary) operands[count] = try builder.constant(&nodes, .i32, inst.secondary_index);
                const arguments = try builder.flatten(operands[0 .. count + @intFromBool(has_secondary)]);
                stack.shrinkRetainingCapacity(start);
                const result: ?ir.Value = switch (target.kind) {
                    .table_get => try builder.wasmValue(table.elem),
                    .table_size, .table_grow => try builder.value(if (table.limits.is_64) .i64 else .i32),
                    else => null,
                };
                const results = if (result) |out| try builder.flatten(&.{out}) else &.{};
                try builder.runtimeCall(&nodes, inst, target, arguments, results, &.{});
                if (result) |out| try stack.append(a, out);
                continue;
            }
            if (inst.op == .prefix_fc and inst.immediate >= 8) {
                const count: usize = if (inst.immediate == 9) 0 else 3;
                if (stack.items.len < count) return error.InvalidControlFlow;
                const start = stack.items.len - count;
                var operands: [4]ir.Value = undefined;
                @memcpy(operands[0..count], stack.items[start..]);
                stack.shrinkRetainingCapacity(start);
                const has_secondary = inst.immediate == 8 or inst.immediate == 10;
                if (has_secondary) operands[3] = try builder.constant(&nodes, .i32, inst.secondary_index);
                const arguments = try a.dupe(ir.Value, operands[0 .. count + @intFromBool(has_secondary)]);
                const parameter_types = try a.alloc(ir.Type, arguments.len);
                for (arguments, parameter_types) |value, *ty| ty.* = builder.types.items[value];
                const target: RuntimeTarget = .{
                    .kind = switch (inst.immediate) {
                        8 => .memory_init,
                        9 => .data_drop,
                        10 => .memory_copy,
                        11 => .memory_fill,
                        else => return error.UnsupportedOpcode,
                    },
                    .index = if (inst.immediate == 9) inst.secondary_index else inst.memory_index,
                };
                try nodes.append(a, .{ .op = .call, .trap_site = inst.offset, .call = .{
                    .target = @bitCast(target),
                    .arguments = arguments,
                    .parameter_types = parameter_types,
                    .results = &.{},
                    .result_types = &.{},
                    .fp_mode = .strict,
                    .safepoint = .{ .id = inst.offset, .values = &.{} },
                } });
                continue;
            }
            switch (inst.op) {
                .nop, .block, .loop, .end => {},
                .local_get, .local_set, .local_tee => {
                    if (inst.immediate >= local_types.len) return error.InvalidControlFlow;
                    const local: usize = @intCast(inst.immediate);
                    if (inst.op == .local_get) {
                        try stack.append(a, locals[local]);
                    } else {
                        locals[local] = stack.pop() orelse return error.InvalidControlFlow;
                        if (inst.op == .local_tee) try stack.append(a, locals[local]);
                    }
                },
                .drop => {
                    _ = stack.pop() orelse return error.InvalidControlFlow;
                },
                .global_get, .global_set => {
                    const wasm_ty = metadata.globalValType(module, @intCast(inst.immediate)) orelse return error.InvalidGlobal;
                    const ty = try valueType(wasm_ty);
                    const address = try builder.constant(&nodes, .i64, 0);
                    if (inst.op == .global_get) {
                        const out = try builder.wasmValue(wasm_ty);
                        try nodes.append(a, .{ .op = .load, .out = out, .lhs = address, .trap_site = inst.offset, .memory = .{
                            .region = inst.secondary_index,
                            .width = if (ty == .v128) .quad else if (ir.is32(ty)) .word else .double,
                        } });
                        if (builder.references.items[out]) |reference| try nodes.append(a, .{ .op = .load, .out = reference.high, .lhs = address, .trap_site = inst.offset, .memory = .{
                            .region = inst.secondary_index,
                            .offset = 8,
                            .width = .double,
                        } });
                        try stack.append(a, out);
                    } else {
                        var value = stack.pop() orelse return error.InvalidControlFlow;
                        if (ty == .v128) {
                            try nodes.append(a, .{ .op = .store, .lhs = address, .rhs = value, .trap_site = inst.offset, .memory = .{ .region = inst.secondary_index, .width = .quad } });
                            continue;
                        }
                        if (builder.references.items[value]) |reference| {
                            try nodes.append(a, .{ .op = .store, .lhs = address, .rhs = value, .trap_site = inst.offset, .memory = .{ .region = inst.secondary_index, .width = .double } });
                            try nodes.append(a, .{ .op = .store, .lhs = address, .rhs = reference.high, .trap_site = inst.offset, .memory = .{ .region = inst.secondary_index, .offset = 8, .width = .double } });
                            continue;
                        }
                        // Scalar Cells use a canonical low 64-bit word, including
                        // zeroed upper i32/f32 bits, as in Spasm's global.set.
                        if (ty == .f32 or ty == .f64) {
                            const bits = try builder.value(if (ty == .f32) .i32 else .i64);
                            try nodes.append(a, .{ .op = .reinterpret, .out = bits, .lhs = value });
                            value = bits;
                        }
                        if (ir.is32(ty)) {
                            const wide = try builder.value(.i64);
                            try nodes.append(a, .{ .op = .zext_i32, .out = wide, .lhs = value });
                            value = wide;
                        }
                        try nodes.append(a, .{ .op = .store, .lhs = address, .rhs = value, .trap_site = inst.offset, .memory = .{ .region = inst.secondary_index, .width = .double } });
                    }
                },
                .i32_const, .i64_const, .f32_const, .f64_const => {
                    const ty: ir.Type = switch (inst.op) {
                        .i32_const => .i32,
                        .i64_const => .i64,
                        .f32_const => .f32,
                        else => .f64,
                    };
                    try stack.append(a, try builder.constant(&nodes, ty, inst.immediate));
                },
                .@"return" => {
                    if (stack.items.len < signature.results.len) return error.InvalidControlFlow;
                    const values = stack.items[stack.items.len - signature.results.len ..];
                    const roots = try builder.roots(&.{}, values);
                    if (roots.len != 0) try builder.runtimeCall(&nodes, inst, .{ .kind = .pin_references, .index = 0 }, &.{}, &.{}, roots);
                    terminator = .{ .return_ = try builder.flatten(values) };
                },
                .call, .call_indirect, .call_ref, .return_call, .return_call_indirect, .return_call_ref => {
                    const target: u32 = @intCast(inst.immediate);
                    const direct = inst.op == .call or inst.op == .return_call;
                    const indirect = inst.op == .call_indirect or inst.op == .return_call_indirect;
                    const tail = inst.op == .return_call or inst.op == .return_call_indirect or inst.op == .return_call_ref;
                    const callee = if (direct) try callSignature(module, target) else try typeSignature(module, target);
                    const dynamic = !direct;
                    const selector = if (dynamic) stack.pop() orelse return error.InvalidControlFlow else 0;
                    if (callee.params.len > stack.items.len) return error.InvalidControlFlow;
                    const roots = if (tail) &.{} else try builder.roots(locals[0..local_types.len], stack.items);
                    const start = stack.items.len - callee.params.len;
                    var operands: std.ArrayList(ir.Value) = .empty;
                    try operands.appendSlice(a, stack.items[start..]);
                    if (indirect) try operands.append(a, try builder.constant(&nodes, .i32, inst.memory_index));
                    if (dynamic) try operands.append(a, selector);
                    const arguments = try builder.flatten(operands.items);
                    stack.shrinkRetainingCapacity(start);
                    const runtime_target: RuntimeTarget = .{ .index = target, .kind = if (direct) .function else if (indirect) .call_indirect else .call_ref };
                    if (tail) {
                        const id: u32 = @intCast(tail_calls.items.len);
                        try tail_calls.append(a, runtime_target);
                        terminator = .{ .exit = .{ .id = id, .values = arguments } };
                        continue;
                    }
                    const results = try a.alloc(ir.Value, callee.results.len);
                    for (callee.results, results) |ty, *out| out.* = try builder.wasmValue(ty);
                    try builder.runtimeCall(&nodes, inst, runtime_target, arguments, try builder.flatten(results), roots);
                    try stack.appendSlice(a, results);
                },
                .ref_null => try stack.append(a, try builder.defaultValue(&nodes, @fromBackingInt(@intCast(@as(u32, @intCast(inst.immediate)))))),
                .ref_func => {
                    const out = try builder.wasmValue(.funcref);
                    try builder.runtimeCall(&nodes, inst, .{ .kind = .ref_func, .index = @intCast(inst.immediate) }, &.{}, try builder.flatten(&.{out}), &.{});
                    try stack.append(a, out);
                },
                .ref_as_non_null => {
                    const value = stack.getLastOrNull() orelse return error.InvalidControlFlow;
                    try builder.runtimeCall(&nodes, inst, .{ .kind = .ref_as_non_null, .index = 0 }, try builder.flatten(&.{value}), &.{}, &.{});
                },
                .ref_is_null => {
                    const value = stack.pop() orelse return error.InvalidControlFlow;
                    try stack.append(a, try builder.isNull(&nodes, value));
                },
                .memory_size => {
                    const bytes = try builder.value(.i64);
                    try nodes.append(a, .{ .op = .memory_length, .out = bytes, .immediate = inst.memory_index });
                    const shift = try builder.constant(&nodes, .i64, 16);
                    const pages = try builder.value(.i64);
                    try nodes.append(a, .{ .op = .shr_u, .out = pages, .lhs = bytes, .rhs = shift });
                    const result = if (memories[inst.memory_index].limits.is_64) pages else blk: {
                        const out = try builder.value(.i32);
                        try nodes.append(a, .{ .op = .trunc_i64, .out = out, .lhs = pages });
                        break :blk out;
                    };
                    try stack.append(a, result);
                },
                .memory_grow => {
                    const delta = stack.pop() orelse return error.InvalidControlFlow;
                    const ty: ir.Type = if (memories[inst.memory_index].limits.is_64) .i64 else .i32;
                    const out = try builder.value(ty);
                    const types = try a.dupe(ir.Type, &.{ty});
                    try nodes.append(a, .{ .op = .call, .trap_site = inst.offset, .call = .{
                        .target = @bitCast(RuntimeTarget{ .kind = .memory_grow, .index = inst.memory_index }),
                        .arguments = try a.dupe(ir.Value, &.{delta}),
                        .parameter_types = types,
                        .results = try a.dupe(ir.Value, &.{out}),
                        .result_types = types,
                        .fp_mode = .strict,
                        .safepoint = .{ .id = inst.offset, .values = &.{} },
                    } });
                    try stack.append(a, out);
                },
                .@"unreachable" => terminator = .{ .trap = .{ .reason = .unreachable_code, .site = inst.offset } },
                .@"if" => {
                    const condition = stack.pop() orelse return error.InvalidControlFlow;
                    terminator = .{ .branch = .{
                        .condition = condition,
                        .taken = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items),
                        .fallthrough = try builder.branchEdge(inst, locals[0..local_types.len], stack.items),
                    } };
                },
                .br_on_null, .br_on_non_null => {
                    const reference = stack.pop() orelse return error.InvalidControlFlow;
                    const condition = try builder.isNull(&nodes, reference);
                    if (inst.op == .br_on_non_null) try stack.append(a, reference);
                    const taken = try builder.branchEdge(inst, locals[0..local_types.len], stack.items);
                    if (inst.op == .br_on_null) try stack.append(a, reference) else _ = stack.pop();
                    const fallthrough = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items);
                    terminator = .{ .branch = .{
                        .condition = condition,
                        .taken = if (inst.op == .br_on_null) taken else fallthrough,
                        .fallthrough = if (inst.op == .br_on_null) fallthrough else taken,
                    } };
                },
                .select, .select_t => {
                    const condition = stack.pop() orelse return error.InvalidControlFlow;
                    const rhs = stack.pop() orelse return error.InvalidControlFlow;
                    if (stack.items.len == 0) return error.InvalidControlFlow;
                    const taken = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items);
                    stack.items[stack.items.len - 1] = rhs;
                    terminator = .{ .branch = .{
                        .condition = condition,
                        .taken = taken,
                        .fallthrough = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items),
                    } };
                },
                .br_table => {
                    const selector = stack.pop() orelse return error.InvalidControlFlow;
                    const taken = try builder.branchEdge(inst, locals[0..local_types.len], stack.items);
                    if (inst.table_default) {
                        terminator = .{ .jump = taken };
                    } else {
                        const case = try builder.constant(&nodes, .i32, inst.immediate);
                        const condition = try builder.value(.i32);
                        try nodes.append(a, .{ .op = .eq, .out = condition, .lhs = selector, .rhs = case });
                        try stack.append(a, selector);
                        terminator = .{ .branch = .{
                            .condition = condition,
                            .taken = taken,
                            .fallthrough = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items),
                        } };
                    }
                },
                .br, .br_if, .@"else" => {
                    const condition = if (inst.op == .br_if) stack.pop() orelse return error.InvalidControlFlow else null;
                    const edge = try builder.branchEdge(inst, locals[0..local_types.len], stack.items);
                    terminator = if (condition) |cond| .{ .branch = .{
                        .condition = cond,
                        .taken = edge,
                        .fallthrough = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items),
                    } } else .{ .jump = edge };
                },
                else => {
                    if (memoryOperation(inst)) |operation| {
                        const value = if (operation.store) stack.pop() orelse return error.InvalidControlFlow else 0;
                        const address = stack.pop() orelse return error.InvalidControlFlow;
                        const out = if (operation.store) null else try builder.value(operation.ty);
                        try nodes.append(a, .{ .op = if (operation.store) .store else .load, .out = out, .lhs = address, .rhs = value, .memory = .{ .region = inst.memory_index, .offset = inst.immediate, .width = operation.width, .signed = operation.signed }, .trap_site = inst.offset });
                        if (out) |result| try stack.append(a, result);
                        continue;
                    }
                    if (inst.op == .prefix_fd) {
                        const out = try builder.value(.v128);
                        if (inst.simd_opcode == 12) {
                            try nodes.append(a, .{ .op = .constant, .out = out, .immediate = inst.immediate, .immediate_hi = inst.immediate_hi });
                        } else {
                            const operation = vectorOperation(inst.simd_opcode) orelse return error.UnsupportedOpcode;
                            const rhs = stack.pop() orelse return error.InvalidControlFlow;
                            const lhs = stack.pop() orelse return error.InvalidControlFlow;
                            try nodes.append(a, .{ .op = operation.op, .vector_lane = operation.lane, .out = out, .lhs = lhs, .rhs = rhs });
                        }
                        try stack.append(a, out);
                        continue;
                    }
                    const op = scalarOperation(inst) orelse return error.UnsupportedOpcode;
                    const rhs = if (inst.op == .i32_eqz or inst.op == .i64_eqz)
                        try builder.constant(&nodes, if (inst.op == .i32_eqz) .i32 else .i64, 0)
                    else if (ir.inputCount(op) == 2)
                        stack.pop() orelse return error.InvalidControlFlow
                    else
                        0;
                    const lhs = stack.pop() orelse return error.InvalidControlFlow;
                    const ty: ir.Type = if (ir.isComparison(op)) .i32 else if (ir.conversionTypes(op)) |conversion| conversion.output else switch (inst.op) {
                        .i32_reinterpret_f32, .i32_trunc_f32_s, .i32_trunc_f32_u, .i32_trunc_f64_s, .i32_trunc_f64_u => .i32,
                        .i64_reinterpret_f64, .i64_trunc_f32_s, .i64_trunc_f32_u, .i64_trunc_f64_s, .i64_trunc_f64_u => .i64,
                        .f32_reinterpret_i32, .f32_convert_i32_s, .f32_convert_i32_u, .f32_convert_i64_s, .f32_convert_i64_u => .f32,
                        .f64_reinterpret_i64, .f64_convert_i32_s, .f64_convert_i32_u, .f64_convert_i64_s, .f64_convert_i64_u => .f64,
                        .prefix_fc => if (inst.immediate < 4) .i32 else .i64,
                        else => builder.types.items[lhs],
                    };
                    const out = try builder.value(ty);
                    try nodes.append(a, .{ .op = op, .out = out, .lhs = lhs, .rhs = rhs, .trap_site = if (ir.mayTrap(op)) inst.offset else null });
                    try stack.append(a, out);
                },
            }
        }
        const final_terminator = terminator orelse ir.Terminator{
            .jump = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items),
        };
        builder.blocks.items[index].nodes = nodes.items;
        builder.blocks.items[index].terminator = final_terminator;
    }
    const graph: ir.Graph = .{
        .types = builder.types.items,
        .blocks = builder.blocks.items,
        .argument_types = argument_types,
        .result_types = result_types,
        .memory_count = @intCast(memories.len + global_indices.items.len),
    };
    try graph.verify();
    return .{ .arena = arena, .graph = graph, .global_indices = global_indices.items, .tail_calls = tail_calls.items };
}

const MemoryOperation = struct { ty: ir.Type, width: ir.MemoryWidth, signed: bool = false, store: bool = false };

fn memoryOperation(inst: Instruction) ?MemoryOperation {
    return switch (inst.op) {
        .prefix_fd => switch (inst.simd_opcode) {
            0 => .{ .ty = .v128, .width = .quad },
            11 => .{ .ty = .v128, .width = .quad, .store = true },
            else => null,
        },
        .i32_load => .{ .ty = .i32, .width = .word },
        .i64_load => .{ .ty = .i64, .width = .double },
        .f32_load => .{ .ty = .f32, .width = .word },
        .f64_load => .{ .ty = .f64, .width = .double },
        .i32_load8_s => .{ .ty = .i32, .width = .byte, .signed = true },
        .i32_load8_u => .{ .ty = .i32, .width = .byte },
        .i32_load16_s => .{ .ty = .i32, .width = .half, .signed = true },
        .i32_load16_u => .{ .ty = .i32, .width = .half },
        .i64_load8_s => .{ .ty = .i64, .width = .byte, .signed = true },
        .i64_load8_u => .{ .ty = .i64, .width = .byte },
        .i64_load16_s => .{ .ty = .i64, .width = .half, .signed = true },
        .i64_load16_u => .{ .ty = .i64, .width = .half },
        .i64_load32_s => .{ .ty = .i64, .width = .word, .signed = true },
        .i64_load32_u => .{ .ty = .i64, .width = .word },
        .i32_store => .{ .ty = .i32, .width = .word, .store = true },
        .i64_store => .{ .ty = .i64, .width = .double, .store = true },
        .f32_store => .{ .ty = .f32, .width = .word, .store = true },
        .f64_store => .{ .ty = .f64, .width = .double, .store = true },
        .i32_store8 => .{ .ty = .i32, .width = .byte, .store = true },
        .i32_store16 => .{ .ty = .i32, .width = .half, .store = true },
        .i64_store8 => .{ .ty = .i64, .width = .byte, .store = true },
        .i64_store16 => .{ .ty = .i64, .width = .half, .store = true },
        .i64_store32 => .{ .ty = .i64, .width = .word, .store = true },
        else => null,
    };
}

const VectorOperation = struct { op: ir.Op, lane: ?ir.VectorLane = null };

fn vectorOperation(sub: u32) ?VectorOperation {
    if (simd.integerBinaryOp(sub)) |operation| {
        if (operation.kind != .add or operation.saturating) return null;
        return .{ .op = .vector_add, .lane = switch (operation.width) {
            1 => .i8x16,
            2 => .i16x8,
            4 => .i32x4,
            8 => .i64x2,
            else => return null,
        } };
    }
    if (simd.floatArithmeticOp(sub)) |operation| {
        if (operation.kind != .add) return null;
        return .{ .op = .vector_add, .lane = if (operation.double_precision) .f64x2 else .f32x4 };
    }
    return switch (sub) {
        78 => .{ .op = .bit_and },
        80 => .{ .op = .bit_or },
        81 => .{ .op = .bit_xor },
        else => null,
    };
}

fn scalarOperation(inst: Instruction) ?ir.Op {
    return switch (inst.op) {
        .prefix_fc => if (inst.immediate <= 7) (if (inst.immediate % 2 == 0) ir.Op.trunc_sat_s else .trunc_sat_u) else null,
        .i32_trunc_f32_s, .i32_trunc_f64_s, .i64_trunc_f32_s, .i64_trunc_f64_s => .trunc_s,
        .i32_trunc_f32_u, .i32_trunc_f64_u, .i64_trunc_f32_u, .i64_trunc_f64_u => .trunc_u,
        .f32_convert_i32_s, .f32_convert_i64_s, .f64_convert_i32_s, .f64_convert_i64_s => .convert_s,
        .f32_convert_i32_u, .f32_convert_i64_u, .f64_convert_i32_u, .f64_convert_i64_u => .convert_u,
        .f32_ceil, .f64_ceil => .fceil,
        .f32_floor, .f64_floor => .ffloor,
        .f32_trunc, .f64_trunc => .ftrunc,
        .f32_nearest, .f64_nearest => .fnearest,
        .i32_eqz, .i32_eq, .i64_eqz, .i64_eq => .eq,
        .i32_ne, .i64_ne => .ne,
        .i32_lt_s, .i64_lt_s => .lt_s,
        .i32_lt_u, .i64_lt_u => .lt_u,
        .i32_gt_s, .i64_gt_s => .gt_s,
        .i32_gt_u, .i64_gt_u => .gt_u,
        .i32_le_s, .i64_le_s => .le_s,
        .i32_le_u, .i64_le_u => .le_u,
        .i32_ge_s, .i64_ge_s => .ge_s,
        .i32_ge_u, .i64_ge_u => .ge_u,
        .i32_add, .i64_add => .add,
        .i32_sub, .i64_sub => .sub,
        .i32_mul, .i64_mul => .mul,
        .i32_div_s, .i64_div_s => .div_s,
        .i32_div_u, .i64_div_u => .div_u,
        .i32_rem_s, .i64_rem_s => .rem_s,
        .i32_rem_u, .i64_rem_u => .rem_u,
        .i32_and, .i64_and => .bit_and,
        .i32_or, .i64_or => .bit_or,
        .i32_xor, .i64_xor => .bit_xor,
        .i32_shl, .i64_shl => .shl,
        .i32_shr_s, .i64_shr_s => .shr_s,
        .i32_shr_u, .i64_shr_u => .shr_u,
        .i32_rotl, .i64_rotl => .rotl,
        .i32_rotr, .i64_rotr => .rotr,
        .i32_clz, .i64_clz => .clz,
        .i32_ctz, .i64_ctz => .ctz,
        .i32_popcnt, .i64_popcnt => .popcnt,
        .i32_extend8_s, .i64_extend8_s => .sext8,
        .i32_extend16_s, .i64_extend16_s => .sext16,
        .i64_extend32_s => .sext32,
        .i32_wrap_i64 => .trunc_i64,
        .i64_extend_i32_s => .sext_i32,
        .i64_extend_i32_u => .zext_i32,
        .f32_add, .f64_add => .fadd,
        .f32_sub, .f64_sub => .fsub,
        .f32_mul, .f64_mul => .fmul,
        .f32_div, .f64_div => .fdiv,
        .f32_min, .f64_min => .fmin,
        .f32_max, .f64_max => .fmax,
        .f32_copysign, .f64_copysign => .fcopysign,
        .f32_abs, .f64_abs => .fabs,
        .f32_neg, .f64_neg => .fneg,
        .f32_sqrt, .f64_sqrt => .fsqrt,
        .f32_eq, .f64_eq => .feq,
        .f32_ne, .f64_ne => .fne,
        .f32_lt, .f64_lt => .flt,
        .f32_gt, .f64_gt => .fgt,
        .f32_le, .f64_le => .fle,
        .f32_ge, .f64_ge => .fge,
        .f32_demote_f64 => .demote_f64,
        .f64_promote_f32 => .promote_f32,
        .i32_reinterpret_f32, .i64_reinterpret_f64, .f32_reinterpret_i32, .f64_reinterpret_i64 => .reinterpret,
        else => null,
    };
}

const Builder = struct {
    const Reference = struct { high: ir.Value, external: bool };
    a: std.mem.Allocator,
    types: std.ArrayList(ir.Type) = .empty,
    references: std.ArrayList(?Reference) = .empty,
    blocks: std.ArrayList(ir.Block) = .empty,
    block_values: std.ArrayList([]const ir.Value) = .empty,
    mapping: []u32 = &.{},
    queue: std.ArrayList(u32) = .empty,

    fn value(self: *Builder, ty: ir.Type) !ir.Value {
        if (self.types.items.len == ir.max_values) return error.PrototypeLimit;
        const id: ir.Value = @intCast(self.types.items.len);
        try self.types.append(self.a, ty);
        try self.references.append(self.a, null);
        return id;
    }

    fn wasmValue(self: *Builder, ty: wasm_types.ValType) !ir.Value {
        const low = try self.value(try valueType(ty));
        if (ty.isRef()) {
            const high = try self.value(.i64);
            self.references.items[low] = .{ .high = high, .external = ty.heapOf() == wasm_types.heap_abs_extern };
        }
        return low;
    }

    fn defaultValue(self: *Builder, nodes: *std.ArrayList(ir.Node), ty: wasm_types.ValType) !ir.Value {
        if (!ty.isRef()) return self.constant(nodes, try valueType(ty), 0);
        const out = try self.wasmValue(ty);
        for ([_]ir.Value{ out, self.references.items[out].?.high }) |word|
            try nodes.append(self.a, .{ .op = .constant, .out = word, .immediate = std.math.maxInt(u64) });
        return out;
    }

    fn isNull(self: *Builder, nodes: *std.ArrayList(ir.Node), low: ir.Value) !ir.Value {
        const reference = self.references.items[low] orelse return error.InvalidControlFlow;
        const sentinel = try self.constant(nodes, .i64, std.math.maxInt(u64));
        const lo = try self.value(.i32);
        const hi = try self.value(.i32);
        const out = try self.value(.i32);
        try nodes.appendSlice(self.a, &.{
            .{ .op = .eq, .out = lo, .lhs = low, .rhs = sentinel },
            .{ .op = .eq, .out = hi, .lhs = reference.high, .rhs = sentinel },
            .{ .op = .bit_and, .out = out, .lhs = lo, .rhs = hi },
        });
        return out;
    }

    fn flatten(self: *Builder, values: []const ir.Value) ![]const ir.Value {
        var lowered: std.ArrayList(ir.Value) = .empty;
        var words: usize = 0;
        for (values) |low| {
            const width = self.types.items[low].words() + @intFromBool(self.references.items[low] != null);
            if (width > ir.max_arguments - words) return error.PrototypeLimit;
            words += width;
            try lowered.append(self.a, low);
            if (self.references.items[low]) |reference| try lowered.append(self.a, reference.high);
        }
        return lowered.items;
    }

    fn runtimeCall(self: *Builder, nodes: *std.ArrayList(ir.Node), inst: Instruction, target: RuntimeTarget, arguments: []const ir.Value, results: []const ir.Value, captures: []const ir.Value) !void {
        const params = try self.a.alloc(ir.Type, arguments.len);
        for (arguments, params) |operand, *ty| ty.* = self.types.items[operand];
        const types = try self.a.alloc(ir.Type, results.len);
        for (results, types) |operand, *ty| ty.* = self.types.items[operand];
        try nodes.append(self.a, .{ .op = .call, .trap_site = inst.offset, .call = .{
            .target = @bitCast(target),
            .arguments = arguments,
            .parameter_types = params,
            .results = results,
            .result_types = types,
            .fp_mode = .strict,
            .safepoint = .{ .id = inst.offset, .values = captures },
        } });
    }

    fn roots(self: *Builder, locals: []const ir.Value, stack: []const ir.Value) ![]const ir.Value {
        var captures: std.ArrayList(ir.Value) = .empty;
        for ([_][]const ir.Value{ locals, stack }) |values| for (values) |low| {
            const reference = self.references.items[low] orelse continue;
            if (!reference.external or std.mem.indexOfScalar(ir.Value, captures.items, low) != null) continue;
            if (captures.items.len > ir.max_arguments - 2) return error.PrototypeLimit;
            try captures.appendSlice(self.a, &.{ low, reference.high });
        };
        return captures.items;
    }

    fn constant(self: *Builder, nodes: *std.ArrayList(ir.Node), ty: ir.Type, immediate: u64) !ir.Value {
        const out = try self.value(ty);
        try nodes.append(self.a, .{ .op = .constant, .out = out, .immediate = immediate });
        return out;
    }

    fn edge(self: *Builder, target: u32, locals: []const ir.Value, stack: []const ir.Value) !ir.Edge {
        if (target == 0 or target >= self.mapping.len) return error.InvalidControlFlow;
        if (locals.len + stack.len > ir.max_arguments) return error.PrototypeLimit;
        const values = try self.a.alloc(ir.Value, locals.len + stack.len);
        @memcpy(values[0..locals.len], locals);
        @memcpy(values[locals.len..], stack);
        const args = try self.flatten(values);
        if (self.mapping[target] == missing) {
            const params = try self.a.alloc(ir.Value, values.len);
            for (params, values) |*param, arg| {
                param.* = try self.value(self.types.items[arg]);
                if (self.references.items[arg]) |reference| {
                    const high = try self.value(.i64);
                    self.references.items[param.*] = .{ .high = high, .external = reference.external };
                }
            }
            self.mapping[target] = @intCast(self.blocks.items.len);
            try self.blocks.append(self.a, .{ .params = try self.flatten(params) });
            try self.block_values.append(self.a, params);
            try self.queue.append(self.a, target);
        }
        return .{ .target = self.mapping[target], .args = args };
    }

    fn branchEdge(self: *Builder, inst: Instruction, locals: []const ir.Value, stack: []const ir.Value) !ir.Edge {
        if (inst.val_count > stack.len or inst.pop_count > stack.len - inst.val_count) return error.InvalidControlFlow;
        if (inst.pop_count == 0) return self.edge(inst.target, locals, stack);
        const prefix = stack.len - inst.val_count - inst.pop_count;
        const carried = try self.a.alloc(ir.Value, stack.len - inst.pop_count);
        @memcpy(carried[0..prefix], stack[0..prefix]);
        @memcpy(carried[prefix..], stack[stack.len - inst.val_count ..]);
        return self.edge(inst.target, locals, carried);
    }
};
