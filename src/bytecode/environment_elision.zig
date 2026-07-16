//! Shared post-bytecode environment summary for execution tiers.
//!
//! A zero-slot `make_environment` has no observable allocation identity, but
//! dropping it shifts the depth interpreted by every `lda_env` / `sta_env` in
//! the same chunk. Bistromath and Ohaimark use this summary to share that
//! semantic boundary instead of maintaining tier-specific opcode scans.

const std = @import("std");

const Op = @import("op.zig").Op;

pub const Summary = struct {
    has_make_environment: bool = false,
    has_environment_access: bool = false,
    all_allocations_empty: bool = true,
    max_access_depth: u8 = 0,

    /// Whether every `make_environment` in this chunk may execute as a no-op.
    /// Environment access without a local allocation remains valid: it reads
    /// an environment inherited by the current frame.
    pub fn canElideMakeEnvironments(self: Summary) bool {
        return self.all_allocations_empty and
            !(self.has_make_environment and self.has_environment_access);
    }
};

pub const AnalyzeError = error{MalformedBytecode};

pub fn analyze(code: []const u8) AnalyzeError!Summary {
    var summary: Summary = .{};
    var pc: usize = 0;
    while (pc < code.len) {
        const op = std.enums.fromInt(Op, code[pc]) orelse return error.MalformedBytecode;
        const operand_size: usize = Op.operandSize(op);
        if (operand_size > code.len - pc - 1) return error.MalformedBytecode;

        switch (op) {
            .make_environment => {
                summary.has_make_environment = true;
                summary.all_allocations_empty = summary.all_allocations_empty and
                    code[pc + 1] == 0;
            },
            .lda_env, .sta_env => {
                summary.has_environment_access = true;
                summary.max_access_depth = @max(summary.max_access_depth, code[pc + 1]);
            },
            else => {},
        }
        pc += 1 + operand_size;
    }
    return summary;
}

test "environment elision summarizes empty allocation" {
    const code = [_]u8{
        @intFromEnum(Op.make_environment), 0,
        @intFromEnum(Op.lda_undefined),    @intFromEnum(Op.return_),
    };
    const summary = try analyze(&code);
    try std.testing.expect(summary.has_make_environment);
    try std.testing.expect(!summary.has_environment_access);
    try std.testing.expect(summary.all_allocations_empty);
    try std.testing.expect(summary.canElideMakeEnvironments());
}

test "environment elision rejects a real allocation" {
    const code = [_]u8{
        @intFromEnum(Op.make_environment), 1,
        @intFromEnum(Op.return_),
    };
    const summary = try analyze(&code);
    try std.testing.expect(summary.has_make_environment);
    try std.testing.expect(!summary.all_allocations_empty);
    try std.testing.expect(!summary.canElideMakeEnvironments());
}

test "environment elision preserves depth when allocation and access coexist" {
    const load_code = [_]u8{
        @intFromEnum(Op.make_environment), 0,
        @intFromEnum(Op.lda_env),          3,
        7,                                 @intFromEnum(Op.return_),
    };
    const load_summary = try analyze(&load_code);
    try std.testing.expect(load_summary.has_environment_access);
    try std.testing.expectEqual(@as(u8, 3), load_summary.max_access_depth);
    try std.testing.expect(!load_summary.canElideMakeEnvironments());

    const store_code = [_]u8{
        @intFromEnum(Op.sta_env),          5, 2,
        @intFromEnum(Op.make_environment), 0, @intFromEnum(Op.return_),
    };
    const store_summary = try analyze(&store_code);
    try std.testing.expect(store_summary.has_environment_access);
    try std.testing.expectEqual(@as(u8, 5), store_summary.max_access_depth);
    try std.testing.expect(!store_summary.canElideMakeEnvironments());
}

test "environment elision permits inherited environment access" {
    const code = [_]u8{
        @intFromEnum(Op.lda_env), 2, 1,
        @intFromEnum(Op.return_),
    };
    const summary = try analyze(&code);
    try std.testing.expect(!summary.has_make_environment);
    try std.testing.expect(summary.has_environment_access);
    try std.testing.expect(summary.canElideMakeEnvironments());
}

test "environment elision reports malformed bytecode" {
    const truncated = [_]u8{@intFromEnum(Op.make_environment)};
    try std.testing.expectError(error.MalformedBytecode, analyze(&truncated));

    const unknown = [_]u8{0xff};
    try std.testing.expectError(error.MalformedBytecode, analyze(&unknown));
}
