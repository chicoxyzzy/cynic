//! Wasm Cells are logical values; the shared native ABI carries scalar words.
const std = @import("std");
const ValType = @import("types.zig").ValType;
const ir = @import("../jit/backend/ir.zig");

pub fn valueType(ty: ValType) !ir.Type {
    return switch (ty) {
        .i32 => .i32,
        .i64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        else => if (ty.isRef()) .i64 else error.UnsupportedType,
    };
}

pub fn wordCount(types: []const ValType) !usize {
    var count: usize = 0;
    for (types) |ty| {
        _ = try valueType(ty);
        const width: usize = if (ty.isRef()) 2 else 1;
        if (width > ir.max_arguments - count) return error.UnsupportedSignature;
        count += width;
    }
    return count;
}

pub fn writeTypes(types: []const ValType, out: []ir.Type) ![]const ir.Type {
    const count = try wordCount(types);
    if (count > out.len) return error.CallSignatureMismatch;
    var index: usize = 0;
    for (types) |ty| {
        out[index] = try valueType(ty);
        index += 1;
        if (ty.isRef()) {
            out[index] = .i64;
            index += 1;
        }
    }
    return out[0..count];
}

pub fn physicalTypes(allocator: std.mem.Allocator, types: []const ValType) ![]const ir.Type {
    const out = try allocator.alloc(ir.Type, try wordCount(types));
    errdefer allocator.free(out);
    return writeTypes(types, out);
}

pub fn pack(types: []const ValType, cells: []const u128, words: []u64) ![]const u64 {
    const count = try wordCount(types);
    if (cells.len != types.len or words.len < count) return error.CallSignatureMismatch;
    var index: usize = 0;
    for (types, cells) |ty, cell| {
        words[index] = ir.normalize(try valueType(ty), @truncate(cell));
        index += 1;
        if (ty.isRef()) {
            words[index] = @truncate(cell >> 64);
            index += 1;
        }
    }
    return words[0..count];
}

pub fn unpack(types: []const ValType, words: []const u64, cells: []u128) !void {
    if (try wordCount(types) != words.len or cells.len != types.len) return error.CallSignatureMismatch;
    var index: usize = 0;
    for (types, cells) |ty, *cell| {
        cell.* = ir.normalize(try valueType(ty), words[index]);
        index += 1;
        if (ty.isRef()) {
            cell.* |= @as(u128, words[index]) << 64;
            index += 1;
        }
    }
}
