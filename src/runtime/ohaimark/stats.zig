//! Opt-in rollout telemetry for Ohaimark.
//!
//! One `Stats` lives on the heap so child realms aggregate into the same
//! engine-local view. Counter and clock work is skipped while `enabled` is
//! false. Production enables Ohaimark by default, but enabling the tier never
//! implies always-on profiling overhead.

const std = @import("std");
const builtin = @import("builtin");
const Op = @import("../../bytecode/op.zig").Op;

/// The pipeline boundary at which a compile attempt stopped. These names are
/// part of the diagnostic output contract: append new stages rather than
/// reusing an existing bucket for a different pass.
pub const RefusalStage = enum(u8) {
    unsupported_target,
    executable_allocator,
    ir,
    specialization,
    representation,
    logical_deopt,
    physical_homes,
    physical_deopt,
    allocation,
    lowering,
    codegen,
    code_install,
    control_fusion,
};

pub const Refusal = struct {
    stage: RefusalStage,
    unsupported_opcode: ?Op = null,
};

pub const CompileResult = union(enum) {
    installed: usize,
    refused: Refusal,
};

const refusal_stage_count = @typeInfo(RefusalStage).@"enum".field_names.len;
const opcode_bucket_count = std.math.maxInt(u8) + 1;

pub const Stats = struct {
    pub const Stage = RefusalStage;

    enabled: bool = false,
    compile_attempts: u64 = 0,
    compile_successes: u64 = 0,
    compile_refusals: u64 = 0,
    compile_time_ns_total: u64 = 0,
    compile_time_ns_max: u64 = 0,
    code_bytes_installed: u64 = 0,
    executed_entries: u64 = 0,
    completed_entries: u64 = 0,
    guard_exits: u64 = 0,
    refusal_stages: [refusal_stage_count]u64 = std.mem.zeroes([refusal_stage_count]u64),
    unsupported_opcodes: [opcode_bucket_count]u64 = std.mem.zeroes([opcode_bucket_count]u64),

    pub const CompileTimer = struct {
        active: bool = false,
        started_ns: i128 = 0,
    };

    pub fn beginCompile(self: *Stats) CompileTimer {
        if (!self.enabled) return .{};
        self.compile_attempts +|= 1;
        return .{ .active = true, .started_ns = monotonicNs() };
    }

    pub fn finishCompile(
        self: *Stats,
        timer: CompileTimer,
        result: CompileResult,
    ) void {
        if (!timer.active) return;
        const now = monotonicNs();
        const elapsed_i = if (now > timer.started_ns) now - timer.started_ns else 0;
        const elapsed: u64 = @intCast(@min(
            elapsed_i,
            @as(i128, std.math.maxInt(u64)),
        ));
        self.compile_time_ns_total +|= elapsed;
        self.compile_time_ns_max = @max(self.compile_time_ns_max, elapsed);
        switch (result) {
            .installed => |installed_bytes| {
                self.compile_successes +|= 1;
                self.code_bytes_installed +|= @intCast(@min(
                    installed_bytes,
                    std.math.maxInt(u64),
                ));
            },
            .refused => |refusal| self.recordRefusal(refusal),
        }
    }

    pub fn refusalCount(self: *const Stats, stage: RefusalStage) u64 {
        return self.refusal_stages[@intFromEnum(stage)];
    }

    pub fn unsupportedOpcodeCount(self: *const Stats, op: Op) u64 {
        return self.unsupported_opcodes[@intFromEnum(op)];
    }

    fn recordRefusal(self: *Stats, refusal: Refusal) void {
        self.compile_refusals +|= 1;
        self.refusal_stages[@intFromEnum(refusal.stage)] +|= 1;
        if (refusal.unsupported_opcode) |op| {
            self.unsupported_opcodes[@intFromEnum(op)] +|= 1;
        }
    }

    pub fn recordEntry(self: *Stats) void {
        if (self.enabled) self.executed_entries +|= 1;
    }

    pub fn recordCompletion(self: *Stats) void {
        if (self.enabled) self.completed_entries +|= 1;
    }

    pub fn recordGuardExit(self: *Stats) void {
        if (self.enabled) self.guard_exits +|= 1;
    }

    /// Stable, allocation-free host telemetry consumed by the benchmark
    /// driver. A version's field set is fixed; changing it requires a new
    /// prefix. Human-facing reports may change freely, while automation must
    /// fail closed on an unknown record shape.
    pub fn formatMachineLine(self: Stats, buf: []u8) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "ohaimark-v1 attempts={d} published={d} refused={d} " ++
                "compile_ns={d} max_compile_ns={d} code_bytes={d} " ++
                "entries={d} completed={d} exits={d}\n",
            .{
                self.compile_attempts,
                self.compile_successes,
                self.compile_refusals,
                self.compile_time_ns_total,
                self.compile_time_ns_max,
                self.code_bytes_installed,
                self.executed_entries,
                self.completed_entries,
                self.guard_exits,
            },
        );
    }

    pub const ParseMachineLineError = error{
        InvalidMachineLine,
        InvalidCharacter,
        Overflow,
    };

    /// Parse the versioned record without relying on field order. Duplicate,
    /// missing, or unknown fields are rejected so a producer/consumer drift
    /// cannot silently turn rollout evidence into zeros.
    pub fn parseMachineLine(line: []const u8) ParseMachineLineError!Stats {
        const Field = enum(u4) {
            attempts,
            published,
            refused,
            compile_ns,
            max_compile_ns,
            code_bytes,
            entries,
            completed,
            exits,
        };
        const all_fields: u16 = (@as(u16, 1) << @typeInfo(Field).@"enum".field_names.len) - 1;

        var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n");
        const prefix = tokens.next() orelse return error.InvalidMachineLine;
        if (!std.mem.eql(u8, prefix, "ohaimark-v1")) return error.InvalidMachineLine;

        var out: Stats = .{ .enabled = true };
        var seen: u16 = 0;
        while (tokens.next()) |token| {
            const eq = std.mem.indexOfScalar(u8, token, '=') orelse
                return error.InvalidMachineLine;
            if (eq == 0 or eq + 1 == token.len) return error.InvalidMachineLine;
            const key = token[0..eq];
            const field: Field = if (std.mem.eql(u8, key, "attempts"))
                .attempts
            else if (std.mem.eql(u8, key, "published"))
                .published
            else if (std.mem.eql(u8, key, "refused"))
                .refused
            else if (std.mem.eql(u8, key, "compile_ns"))
                .compile_ns
            else if (std.mem.eql(u8, key, "max_compile_ns"))
                .max_compile_ns
            else if (std.mem.eql(u8, key, "code_bytes"))
                .code_bytes
            else if (std.mem.eql(u8, key, "entries"))
                .entries
            else if (std.mem.eql(u8, key, "completed"))
                .completed
            else if (std.mem.eql(u8, key, "exits"))
                .exits
            else
                return error.InvalidMachineLine;

            const bit = @as(u16, 1) << @intFromEnum(field);
            if (seen & bit != 0) return error.InvalidMachineLine;
            seen |= bit;
            const value = try std.fmt.parseInt(u64, token[eq + 1 ..], 10);
            switch (field) {
                .attempts => out.compile_attempts = value,
                .published => out.compile_successes = value,
                .refused => out.compile_refusals = value,
                .compile_ns => out.compile_time_ns_total = value,
                .max_compile_ns => out.compile_time_ns_max = value,
                .code_bytes => out.code_bytes_installed = value,
                .entries => out.executed_entries = value,
                .completed => out.completed_entries = value,
                .exits => out.guard_exits = value,
            }
        }
        if (seen != all_fields) return error.InvalidMachineLine;
        if (out.compile_successes +| out.compile_refusals != out.compile_attempts)
            return error.InvalidMachineLine;
        if (out.compile_time_ns_max > out.compile_time_ns_total)
            return error.InvalidMachineLine;
        if (out.completed_entries +| out.guard_exits != out.executed_entries)
            return error.InvalidMachineLine;
        return out;
    }

    /// Saturating aggregation for harness workers and per-fixture heaps.
    pub fn merge(self: *Stats, other: Stats) void {
        self.enabled = self.enabled or other.enabled;
        self.compile_attempts +|= other.compile_attempts;
        self.compile_successes +|= other.compile_successes;
        self.compile_refusals +|= other.compile_refusals;
        self.compile_time_ns_total +|= other.compile_time_ns_total;
        self.compile_time_ns_max = @max(self.compile_time_ns_max, other.compile_time_ns_max);
        self.code_bytes_installed +|= other.code_bytes_installed;
        self.executed_entries +|= other.executed_entries;
        self.completed_entries +|= other.completed_entries;
        self.guard_exits +|= other.guard_exits;
        for (&self.refusal_stages, other.refusal_stages) |*total, count| {
            total.* +|= count;
        }
        for (&self.unsupported_opcodes, other.unsupported_opcodes) |*total, count| {
            total.* +|= count;
        }
    }
};

/// Monotonic compile timing without threading an `std.Io` handle through the
/// runtime compiler. This mirrors heap GC timing; freestanding builds have no
/// host clock and report zero while preserving every count.
fn monotonicNs() i128 {
    if (builtin.os.tag == .freestanding) return 0;
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.nsec));
}

test "Ohaimark stats stay inert while disabled" {
    var stats: Stats = .{};
    const timer = stats.beginCompile();
    stats.finishCompile(timer, .{ .installed = 128 });
    stats.recordEntry();
    stats.recordCompletion();
    stats.recordGuardExit();
    try std.testing.expectEqual(@as(u64, 0), stats.compile_attempts);
    try std.testing.expectEqual(@as(u64, 0), stats.code_bytes_installed);
    try std.testing.expectEqual(@as(u64, 0), stats.executed_entries);
    try std.testing.expectEqual(@as(u64, 0), stats.completed_entries);
    try std.testing.expectEqual(@as(u64, 0), stats.guard_exits);
}

test "Ohaimark stats merge saturates counters and keeps maxima" {
    var total: Stats = .{
        .enabled = true,
        .compile_attempts = std.math.maxInt(u64) - 1,
        .compile_time_ns_max = 7,
    };
    total.merge(.{
        .compile_attempts = 5,
        .compile_successes = 2,
        .compile_time_ns_max = 11,
        .executed_entries = 3,
    });
    try std.testing.expectEqual(std.math.maxInt(u64), total.compile_attempts);
    try std.testing.expectEqual(@as(u64, 2), total.compile_successes);
    try std.testing.expectEqual(@as(u64, 11), total.compile_time_ns_max);
    try std.testing.expectEqual(@as(u64, 3), total.executed_entries);
}

test "Ohaimark stats merge refusal stage and opcode histograms" {
    var first: Stats = .{ .enabled = true };
    first.recordRefusal(.{ .stage = .ir, .unsupported_opcode = .bit_or });
    first.refusal_stages[@intFromEnum(RefusalStage.codegen)] = std.math.maxInt(u64) - 1;
    var second: Stats = .{ .enabled = true };
    second.recordRefusal(.{ .stage = .ir, .unsupported_opcode = .bit_or });
    second.recordRefusal(.{ .stage = .lowering });
    second.recordRefusal(.{ .stage = .control_fusion });
    second.refusal_stages[@intFromEnum(RefusalStage.codegen)] = 5;

    first.merge(second);

    try std.testing.expectEqual(@as(u64, 2), first.refusalCount(.ir));
    try std.testing.expectEqual(@as(u64, 1), first.refusalCount(.lowering));
    try std.testing.expectEqual(@as(u64, 1), first.refusalCount(.control_fusion));
    try std.testing.expectEqual(std.math.maxInt(u64), first.refusalCount(.codegen));
    try std.testing.expectEqual(@as(u64, 2), first.unsupportedOpcodeCount(.bit_or));
}

test "Ohaimark stats machine line round-trips rollout counters" {
    const expected: Stats = .{
        .enabled = true,
        .compile_attempts = 11,
        .compile_successes = 7,
        .compile_refusals = 4,
        .compile_time_ns_total = 123_456,
        .compile_time_ns_max = 45_678,
        .code_bytes_installed = 9_876,
        .executed_entries = 321,
        .completed_entries = 300,
        .guard_exits = 21,
    };
    var buf: [512]u8 = undefined;
    const line = try expected.formatMachineLine(&buf);
    try std.testing.expectEqualStrings(
        "ohaimark-v1 attempts=11 published=7 refused=4 compile_ns=123456 max_compile_ns=45678 code_bytes=9876 entries=321 completed=300 exits=21\n",
        line,
    );

    const actual = try Stats.parseMachineLine(line);
    try std.testing.expect(actual.enabled);
    try std.testing.expectEqual(expected.compile_attempts, actual.compile_attempts);
    try std.testing.expectEqual(expected.compile_successes, actual.compile_successes);
    try std.testing.expectEqual(expected.compile_refusals, actual.compile_refusals);
    try std.testing.expectEqual(expected.compile_time_ns_total, actual.compile_time_ns_total);
    try std.testing.expectEqual(expected.compile_time_ns_max, actual.compile_time_ns_max);
    try std.testing.expectEqual(expected.code_bytes_installed, actual.code_bytes_installed);
    try std.testing.expectEqual(expected.executed_entries, actual.executed_entries);
    try std.testing.expectEqual(expected.completed_entries, actual.completed_entries);
    try std.testing.expectEqual(expected.guard_exits, actual.guard_exits);
}

test "Ohaimark stats machine line rejects missing and unknown fields" {
    try std.testing.expectError(
        error.InvalidMachineLine,
        Stats.parseMachineLine("ohaimark-v1 attempts=1\n"),
    );
    try std.testing.expectError(
        error.InvalidMachineLine,
        Stats.parseMachineLine(
            "ohaimark-v1 attempts=1 published=1 refused=0 compile_ns=1 max_compile_ns=1 code_bytes=1 entries=1 completed=1 surprise=1 exits=0\n",
        ),
    );
    try std.testing.expectError(
        error.InvalidMachineLine,
        Stats.parseMachineLine(
            "ohaimark-v1 attempts=1 attempts=1 published=1 refused=0 compile_ns=1 max_compile_ns=1 code_bytes=1 entries=1 completed=1 exits=0\n",
        ),
    );
    try std.testing.expectError(
        error.InvalidMachineLine,
        Stats.parseMachineLine(
            "ohaimark-v1 attempts=2 published=1 refused=0 compile_ns=1 max_compile_ns=2 code_bytes=1 entries=2 completed=1 exits=0\n",
        ),
    );
}
