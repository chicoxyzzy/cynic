//! Wasm exception state stays frontend-owned; the backend only branches.
const std = @import("std");
const interpreter = @import("interpreter.zig");
const Module = @import("module.zig").Module;
const types = @import("types.zig");
const abi = @import("backend_abi.zig");
const native = @import("../jit/backend/native.zig");
const ir = @import("../jit/backend/ir.zig");

pub fn tagSignature(module: *const Module, index: u32) !types.FuncType {
    var imported: u32 = 0;
    for (module.imports) |entry| if (entry.desc == .tag) {
        if (index == imported) return module.types[entry.desc.tag];
        imported += 1;
    };
    if (index < imported or index - imported >= module.tags.len) return error.UnknownTag;
    return module.types[module.tags[index - imported].type_index];
}

// Keep payload/signature buffers off the ordinary recursive call bridge.
pub noinline fn raise(state: *State, instance: *interpreter.Instance, index: u32, request: native.CallRequest, local: bool) !void {
    if (index >= instance.tag_identities.len) return error.UnknownTag;
    const tag = instance.tag_identities[index];
    var parameter_types: [ir.max_arguments]ir.Type = undefined;
    if (request.results.len != 0 or !std.mem.eql(ir.Type, request.parameter_types, try abi.writeTypes(tag.params, &parameter_types))) return error.CallSignatureMismatch;
    var payload: [ir.max_arguments]u128 = undefined;
    try abi.unpack(tag.params, request.arguments, payload[0..tag.params.len]);
    if (local) {
        state.deinit(instance.gpa);
        const record = try instance.gpa.create(interpreter.ExnRecord);
        errdefer instance.gpa.destroy(record);
        record.* = .{ .tag = tag, .payload = try instance.gpa.dupe(u128, payload[0..tag.params.len]) };
        state.temporary = record;
        state.record = record;
    } else {
        instance.pending_exn = instance.internExnRecord(tag, payload[0..tag.params.len], interpreter.REF_NULL) orelse return error.OutOfMemory;
    }
    return error.UncaughtException;
}

pub fn raiseRef(instance: *interpreter.Instance, request: native.CallRequest) !void {
    if (request.arguments.len != 2 or request.results.len != 0) return error.CallSignatureMismatch;
    const reference = @as(u128, request.arguments[0]) | (@as(u128, request.arguments[1]) << 64);
    if (reference == interpreter.REF_NULL) return error.NullExnRef;
    // Validated Wasm can only obtain a non-null exnref from a caught record.
    instance.pending_exn = @ptrFromInt(@as(usize, @truncate(reference)));
    return error.UncaughtException;
}

pub const State = struct {
    record: ?*const interpreter.ExnRecord = null,
    temporary: ?*interpreter.ExnRecord = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.temporary) |record| {
            allocator.free(record.payload);
            allocator.destroy(record);
        }
        self.* = .{};
    }

    fn materialize(self: *State, instance: *interpreter.Instance) !void {
        if (self.temporary) |record| {
            try instance.exn_pool.append(instance.gpa, record);
            self.temporary = null;
        }
    }

    pub fn classify(self: *State, instance: *interpreter.Instance, err: anyerror) bool {
        if (err == error.UncaughtException and self.temporary != null) return true;
        self.record = switch (err) {
            error.UncaughtException => instance.pending_exn,
            error.HostThrew => if (instance.host_exn_hook) |hook|
                (if (instance.host_exn_ctx) |ctx| hook(ctx, instance) else null)
            else
                null,
            else => return false,
        };
        if (self.record == null) return false;
        instance.pending_exn = null;
        return true;
    }

    pub fn matches(self: *const State, instance: *const interpreter.Instance, index: u32) !bool {
        const record = self.record orelse return error.InvalidNativeResult;
        if (index >= instance.tag_identities.len) return error.UnknownTag;
        return record.tag == instance.tag_identities[index];
    }

    pub noinline fn payload(self: *State, instance: *interpreter.Instance, flags: u32, request: native.CallRequest) !void {
        const record = self.record orelse return error.InvalidNativeResult;
        if (flags > 3 or request.arguments.len != 0) return error.CallSignatureMismatch;
        const params: []const types.ValType = if (flags & 1 != 0) record.tag.params else &.{};
        const with_ref = flags & 2 != 0;
        var result_types: [ir.max_arguments]ir.Type = undefined;
        const count = (try abi.writeTypes(params, &result_types)).len;
        const extra: usize = if (with_ref) 2 else 0;
        if (extra > result_types.len - count) return error.CallSignatureMismatch;
        @memset(result_types[count..][0..extra], .i64);
        const words = try abi.wordCount(params);
        if (request.results.len != words + extra or !std.mem.eql(ir.Type, request.result_types, result_types[0 .. count + extra])) return error.CallSignatureMismatch;
        if (with_ref) try self.materialize(instance);
        _ = try abi.pack(params, if (flags & 1 != 0) record.payload else &.{}, request.results);
        if (with_ref) {
            request.results[words] = @intFromPtr(record);
            request.results[words + 1] = 0;
        }
        self.deinit(instance.gpa);
    }

    pub fn propagate(self: *State, instance: *interpreter.Instance) !void {
        try self.materialize(instance);
        instance.pending_exn = self.record orelse return error.InvalidNativeResult;
        self.record = null;
        return error.UncaughtException;
    }
};
