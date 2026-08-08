//! Target-neutral non-reentrant helpers for Ohaimark frame safepoints.
//!
//! Generated code stages the exact pre-operation Lantern frame before crossing
//! this ABI. Helpers may allocate or mutate typed engine state, but must never
//! invoke JavaScript; tier-down always replays the original bytecode.

const std = @import("std");

const lantern = @import("../lantern/interpreter.zig");
const JSObject = @import("../object.zig").JSObject;
const JSString = @import("../string.zig").JSString;
const Realm = @import("../realm.zig").Realm;
const ir = @import("ir.zig");

const helper_ok: u64 = 0;
const helper_tier_down: u64 = 1;
const helper_out_of_memory: u64 = 2;

/// A deliberately bounded set of non-reentrant helper calls. Adding a
/// JS-reentrant operation here requires native continuation ownership and
/// stack maps first.
pub const Helper = union(enum) {
    allocate: ir.EnvironmentAllocation,
    store: ir.EnvironmentStore,
    unmapped_arguments_object,
    ordinary_function: ir.FunctionTemplateRef,
    set_home: ir.HomeObject,
    object_method_property: ir.ObjectMethodProperty,
    object_literal: ir.ObjectLiteral,
    dense_array_literal: ir.DenseArrayLiteral,
    array_literal,
    dense_array_append: ir.DenseArrayAppend,
    template_property: ir.TemplateProperty,
    computed_delete: ir.ComputedDelete,
    global_store: ir.GlobalStore,
};

pub const Call = struct {
    target: usize,
    arg2: ?u64 = null,
    arg3: ?u64 = null,
};

pub fn call(helper: Helper) Call {
    return switch (helper) {
        .allocate => |site| .{
            .target = @intFromPtr(&allocateEnvironment),
            .arg2 = site.slot_count,
        },
        .store => |site| .{
            .target = @intFromPtr(&storeEnvironment),
            .arg2 = site.depth,
            .arg3 = site.slot,
        },
        .unmapped_arguments_object => .{
            .target = @intFromPtr(&createUnmappedArgumentsObject),
        },
        .ordinary_function => |template| .{
            .target = @intFromPtr(&createOrdinaryFunction),
            .arg2 = template.template_index,
        },
        .set_home => |home| .{
            .target = @intFromPtr(&setHomeObject),
            .arg2 = home.object_register,
        },
        .object_method_property => |property| .{
            .target = @intFromPtr(&defineObjectMethodProperty),
            .arg2 = property.key_constant,
            .arg3 = property.object_register,
        },
        .object_literal => |literal| switch (literal) {
            .plain => .{
                .target = @intFromPtr(&createPlainObjectLiteral),
            },
            .shape => |template| .{
                .target = @intFromPtr(&createShapedObjectLiteral),
                .arg2 = template,
            },
        },
        .dense_array_literal => |literal| .{
            .target = @intFromPtr(&createDenseArrayLiteral),
            .arg2 = literal.base,
            .arg3 = literal.count,
        },
        .array_literal => .{
            .target = @intFromPtr(&createArrayLiteral),
        },
        .dense_array_append => |append| .{
            .target = @intFromPtr(&appendDenseArrayLiteralElement),
            .arg2 = append.key_constant,
            .arg3 = append.object_register,
        },
        .template_property => |property| .{
            .target = @intFromPtr(&defineTemplateProperty),
            .arg2 = property.object_register,
            .arg3 = property.slot,
        },
        .computed_delete => |delete| .{
            .target = @intFromPtr(&deleteComputedProperty),
            .arg2 = delete.object_register,
            .arg3 = delete.key_register,
        },
        .global_store => |store| .{
            .target = @intFromPtr(&storeGlobalForFrame),
            .arg2 = store.key_constant,
        },
    };
}

pub fn returnsTaggedResult(helper: Helper) bool {
    return switch (helper) {
        .unmapped_arguments_object,
        .ordinary_function,
        .object_literal,
        .dense_array_literal,
        .array_literal,
        .computed_delete,
        => true,
        else => false,
    };
}

pub fn outOfMemoryStatus(helper: Helper) ?u64 {
    return switch (helper) {
        .unmapped_arguments_object,
        .ordinary_function,
        .object_method_property,
        .object_literal,
        .dense_array_literal,
        .dense_array_append,
        .computed_delete,
        => helper_out_of_memory,
        .array_literal => helper_tier_down,
        else => null,
    };
}

pub fn nodeRequiresScope(kind: ir.NodeKind) bool {
    return switch (kind) {
        .allocate_environment,
        .store_environment,
        .create_unmapped_arguments_object,
        .create_ordinary_function,
        .set_home,
        .define_object_method_property,
        .create_object_literal,
        .create_dense_array_literal,
        .create_array_literal,
        .append_dense_array_literal_element,
        .define_template_property,
        .delete_computed_property,
        .store_global,
        => true,
        else => false,
    };
}

fn allocateEnvironment(
    realm: *Realm,
    frame: *lantern.CallFrame,
    slot_count_raw: u64,
) callconv(.c) u64 {
    const slot_count = std.math.cast(u8, slot_count_raw) orelse
        return helper_tier_down;
    const environment = realm.heap.allocateEnvironment(
        frame.env,
        slot_count,
    ) catch return helper_tier_down;
    frame.env = environment;
    return helper_ok;
}

fn storeEnvironment(
    realm: *Realm,
    frame: *lantern.CallFrame,
    depth_raw: u64,
    slot_raw: u64,
) callconv(.c) u64 {
    const depth = std.math.cast(u8, depth_raw) orelse
        return helper_tier_down;
    const slot = std.math.cast(u8, slot_raw) orelse
        return helper_tier_down;
    var environment = frame.env orelse return helper_tier_down;
    var remaining = depth;
    while (remaining > 0) : (remaining -= 1) {
        environment = environment.parent orelse return helper_tier_down;
    }
    if (@as(usize, slot) >= environment.slots.len) return helper_tier_down;
    realm.heap.storeEnvSlot(environment, slot, frame.accumulator);
    return helper_ok;
}

fn createUnmappedArgumentsObject(
    realm: *Realm,
    frame: *lantern.CallFrame,
) callconv(.c) u64 {
    return switch (lantern.createUnmappedArgumentsObjectForFrame(
        realm,
        realm.allocator,
        frame,
    )) {
        .value => |value| blk: {
            frame.accumulator = value;
            break :blk helper_ok;
        },
        .invalid_frame => helper_tier_down,
        .out_of_memory => helper_out_of_memory,
    };
}

fn createOrdinaryFunction(
    realm: *Realm,
    frame: *lantern.CallFrame,
    template_raw: u64,
) callconv(.c) u64 {
    const template = std.math.cast(u16, template_raw) orelse
        return helper_tier_down;
    return switch (lantern.createOrdinaryFunctionForFrame(
        realm,
        realm.allocator,
        frame,
        template,
    )) {
        .value => |value| blk: {
            frame.accumulator = value;
            break :blk helper_ok;
        },
        .invalid_frame, .unsupported_template => helper_tier_down,
        .out_of_memory => helper_out_of_memory,
    };
}

fn setHomeObject(
    realm: *Realm,
    frame: *lantern.CallFrame,
    object_register_raw: u64,
) callconv(.c) u64 {
    const object_register = std.math.cast(u8, object_register_raw) orelse
        return helper_tier_down;
    return switch (lantern.setHomeObjectForFrame(
        realm,
        frame,
        frame.accumulator,
        object_register,
    )) {
        .ok => helper_ok,
        .invalid_frame => helper_tier_down,
    };
}

fn defineObjectMethodProperty(
    realm: *Realm,
    frame: *lantern.CallFrame,
    key_raw: u64,
    object_register_raw: u64,
) callconv(.c) u64 {
    const key_constant = std.math.cast(u16, key_raw) orelse
        return helper_tier_down;
    const object_register = std.math.cast(u8, object_register_raw) orelse
        return helper_tier_down;
    return switch (lantern.defineObjectMethodPropertyForFrame(
        realm,
        realm.allocator,
        frame,
        frame.accumulator,
        key_constant,
        object_register,
    )) {
        .ok => helper_ok,
        .invalid_frame, .tier_down => helper_tier_down,
        .out_of_memory => helper_out_of_memory,
    };
}

fn createPlainObjectLiteral(
    realm: *Realm,
    frame: *lantern.CallFrame,
) callconv(.c) u64 {
    return createObjectLiteral(realm, frame, .plain);
}

fn createShapedObjectLiteral(
    realm: *Realm,
    frame: *lantern.CallFrame,
    template_raw: u64,
) callconv(.c) u64 {
    const template = std.math.cast(u16, template_raw) orelse
        return helper_tier_down;
    return createObjectLiteral(realm, frame, .{ .shape = template });
}

fn createObjectLiteral(
    realm: *Realm,
    frame: *lantern.CallFrame,
    literal: lantern.ObjectLiteralKind,
) u64 {
    return switch (lantern.createObjectLiteralForFrame(
        realm,
        realm.allocator,
        frame,
        literal,
    )) {
        .value => |value| blk: {
            frame.accumulator = value;
            break :blk helper_ok;
        },
        .invalid_frame => helper_tier_down,
        .out_of_memory => helper_out_of_memory,
    };
}

fn createDenseArrayLiteral(
    realm: *Realm,
    frame: *lantern.CallFrame,
    base_raw: u64,
    count_raw: u64,
) callconv(.c) u64 {
    const base = std.math.cast(u8, base_raw) orelse
        return helper_tier_down;
    const count = std.math.cast(u8, count_raw) orelse
        return helper_tier_down;
    return switch (lantern.createDenseArrayLiteralForFrame(
        realm,
        frame,
        base,
        count,
    )) {
        .value => |value| blk: {
            frame.accumulator = value;
            break :blk helper_ok;
        },
        .invalid_frame => helper_tier_down,
        .out_of_memory => helper_out_of_memory,
    };
}

fn createArrayLiteral(
    realm: *Realm,
    frame: *lantern.CallFrame,
) callconv(.c) u64 {
    return switch (lantern.createArrayLiteralForFrame(realm, frame)) {
        .value => |value| blk: {
            frame.accumulator = value;
            break :blk helper_ok;
        },
        .out_of_memory => helper_tier_down,
    };
}

fn appendDenseArrayLiteralElement(
    realm: *Realm,
    frame: *lantern.CallFrame,
    key_raw: u64,
    object_register_raw: u64,
) callconv(.c) u64 {
    const key_constant = std.math.cast(u16, key_raw) orelse
        return helper_tier_down;
    const object_register = std.math.cast(u8, object_register_raw) orelse
        return helper_tier_down;
    return switch (lantern.appendDenseArrayLiteralElementForFrame(
        realm,
        realm.allocator,
        frame,
        frame.accumulator,
        key_constant,
        object_register,
    )) {
        .ok => helper_ok,
        .invalid_frame, .tier_down => helper_tier_down,
        .out_of_memory => helper_out_of_memory,
    };
}

fn deleteComputedProperty(
    realm: *Realm,
    frame: *lantern.CallFrame,
    object_register_raw: u64,
    key_register_raw: u64,
) callconv(.c) u64 {
    const object_register = std.math.cast(u8, object_register_raw) orelse
        return helper_tier_down;
    const key_register = std.math.cast(u8, key_register_raw) orelse
        return helper_tier_down;
    return switch (lantern.deleteComputedPropertyForFrame(
        realm,
        frame,
        object_register,
        key_register,
    )) {
        .ok => helper_ok,
        .tier_down => helper_tier_down,
        .out_of_memory => helper_out_of_memory,
    };
}

fn storeGlobalForFrame(
    realm: *Realm,
    frame: *lantern.CallFrame,
    key_constant_raw: u64,
) callconv(.c) u64 {
    const key_constant = std.math.cast(u16, key_constant_raw) orelse
        return helper_tier_down;
    if (key_constant >= frame.chunk.constants.len) return helper_tier_down;
    const key_value = frame.chunk.constants[key_constant];
    if (!key_value.isString()) return helper_tier_down;
    const key: *const JSString = @ptrCast(@alignCast(key_value.asString()));
    const bytes = key.flatBytesIfFlat() orelse return helper_tier_down;
    const executing_realm = frame.running_realm orelse realm;
    if (executing_realm.globals.hasLexicalDeclaration(bytes)) {
        return helper_tier_down;
    }
    const target = executing_realm.globals.target orelse
        return helper_tier_down;
    const shape = target.shape orelse return helper_tier_down;
    const entry = shape.lookup(bytes) orelse return helper_tier_down;
    if (entry.kind != .data or
        !entry.attrs.writable or
        entry.slot >= target.slotCount())
    {
        return helper_tier_down;
    }
    target.setSlot(entry.slot, frame.accumulator);
    executing_realm.heap.storeInternalSlot(
        .{ .object = target },
        frame.accumulator,
    );
    return helper_ok;
}

fn defineTemplateProperty(
    realm: *Realm,
    frame: *lantern.CallFrame,
    object_register_raw: u64,
    slot_raw: u64,
) callconv(.c) u64 {
    const object_register = std.math.cast(u8, object_register_raw) orelse
        return helper_tier_down;
    const slot = std.math.cast(u16, slot_raw) orelse
        return helper_tier_down;
    return switch (lantern.defineTemplatePropertyForFrame(
        realm,
        frame,
        frame.accumulator,
        object_register,
        slot,
    )) {
        .ok => helper_ok,
        .invalid_frame => helper_tier_down,
    };
}

/// The computed-store barrier cannot collect or invoke JavaScript.
pub fn storeBarrier(
    realm: *Realm,
    object: *JSObject,
    bits: u64,
) callconv(.c) void {
    realm.heap.storeInternalSlot(.{ .object = object }, .{ .bits = bits });
}

test "frame safepoint helper policy identifies rooted operations" {
    try std.testing.expect(nodeRequiresScope(.create_object_literal));
    try std.testing.expect(nodeRequiresScope(.delete_computed_property));
    try std.testing.expect(!nodeRequiresScope(.less_than));
    try std.testing.expect(returnsTaggedResult(.array_literal));
    try std.testing.expectEqual(
        helper_tier_down,
        outOfMemoryStatus(.array_literal).?,
    );
    try std.testing.expect(outOfMemoryStatus(.{
        .set_home = .{ .object_register = 0 },
    }) == null);
}
