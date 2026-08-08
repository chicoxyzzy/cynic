//! Target-neutral retry policy for property-feedback compilation refusals.

const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;

pub const Error = error{RetryableFeedback};

pub const Site = union(enum) {
    named_load: u16,
    named_store: u16,
    computed_load: u16,
    computed_store: u16,

    pub fn key(self: Site) u32 {
        const kind, const index = switch (self) {
            .named_load => |value| .{ @as(u32, 0), value },
            .named_store => |value| .{ @as(u32, 1), value },
            .computed_load => |value| .{ @as(u32, 2), value },
            .computed_store => |value| .{ @as(u32, 3), value },
        };
        return (kind << 16) | index;
    }
};

/// `0` means the live IC remains generic; `1` means the current monomorphic
/// footprint is eligible for optimized own-data lowering.
pub fn fingerprint(chunk: *const Chunk, key: u32) ?u64 {
    const index: usize = @intCast(key & 0xffff);
    return switch (key >> 16) {
        0 => if (index >= chunk.inline_load_caches.len)
            null
        else
            @as(u64, @intFromBool(
                chunk.inline_load_caches[index].shape != null,
            )),
        1 => if (index >= chunk.inline_store_caches.len)
            null
        else
            @as(u64, @intFromBool(
                chunk.inline_store_caches[index].shape != null and
                    chunk.inline_store_caches[index].post_shape == null,
            )),
        2, 3 => if (index >= chunk.inline_computed_caches.len)
            null
        else blk: {
            const cell = chunk.inline_computed_caches[index];
            break :blk @as(u64, @intFromBool(
                cell.shape != null and
                    cell.cached_key_len > 0 and
                    cell.cached_key_len <= chunk_mod.computed_key_cap,
            ));
        },
        else => null,
    };
}

test "feedback retry keys keep property classes disjoint" {
    const testing = @import("std").testing;
    try testing.expect(
        (Site{ .named_load = 7 }).key() !=
            (Site{ .named_store = 7 }).key(),
    );
    try testing.expect(
        (Site{ .computed_load = 7 }).key() !=
            (Site{ .computed_store = 7 }).key(),
    );
}
