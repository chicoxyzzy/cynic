//! Target-independent Ohaimark entry result words.
//!
//! Generated entries return either a canonical JavaScript `Value` or one of
//! these noncanonical NaN payloads. `Value.fromDouble` canonicalizes NaN and
//! tagged values occupy a disjoint range, so no user value can collide with a
//! control result.

const std = @import("std");

const Value = @import("../value.zig").Value;

pub const EntryResult = enum(u32) {
    resume_interp = 0,
    done = 1,
    safe_point = 2,
};

/// The generated entry reconstructed the exact Lantern frame and requests
/// interpreter resumption at `frame.ip`.
pub const resume_sentinel_bits: u64 = 0x7FFA_0000_0000_0001;

/// An OSR stub rejected its incoming header values before optimized execution.
pub const osr_bail_sentinel_bits: u64 = 0x7FFA_0000_0000_0002;

/// A compact call staged its parent and appended a bytecode child frame.
pub const call_pushed_sentinel_bits: u64 = 0x7FFA_0000_0000_0003;

/// A frame-push helper exhausted host memory after staging the parent.
pub const host_oom_sentinel_bits: u64 = 0x7FFA_0000_0000_0004;

/// Generated code reconstructed the loop header specifically because its
/// execution poll found pending work. Lantern must run the canonical safe
/// point before dispatching the reconstructed frame.
pub const safepoint_sentinel_bits: u64 = 0x7FFA_0000_0000_0005;

comptime {
    const sentinels = [_]u64{
        resume_sentinel_bits,
        osr_bail_sentinel_bits,
        call_pushed_sentinel_bits,
        host_oom_sentinel_bits,
        safepoint_sentinel_bits,
    };
    for (sentinels, 0..) |sentinel, index| {
        const decoded: f64 = @bitCast(sentinel -% Value.double_encode_offset);
        std.debug.assert(std.math.isNan(decoded));
        std.debug.assert(sentinel != Value.fromDouble(std.math.nan(f64)).bits);
        for (sentinels[0..index]) |prior| std.debug.assert(sentinel != prior);
    }
}
