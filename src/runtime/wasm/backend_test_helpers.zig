const std = @import("std");
const ir = @import("../jit/backend/ir.zig");

pub fn appendRefusalPrefix(allocator: std.mem.Allocator, body: *std.ArrayList(u8)) !void {
    // Exceed the SSA value budget without relying on an unimplemented opcode.
    // Spasm folds these discarded constants; Sarcasm executes them normally.
    for (0..ir.max_values) |_| try body.appendSlice(allocator, &.{ 0x41, 0, 0x1a });
}

pub fn refusedBody(allocator: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, 0);
    try appendRefusalPrefix(allocator, &body);
    try body.appendSlice(allocator, suffix);
    return body.toOwnedSlice(allocator);
}
