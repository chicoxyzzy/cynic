//! Immutable optimization feedback copied from a chunk's typed inline-cache
//! tables. Shape pointers are safe to retain because a realm's `ShapeTree`
//! owns them for its whole lifetime. GC-managed function/object pointers stay
//! in the live IC cells and are deliberately absent here; future codegen must
//! guard through the cell index instead of accidentally rooting or dangling a
//! callee, prototype, or for-in snapshot. A snapshot is a transient compiler
//! input and must not outlive the realm `ShapeTree` owning its shape pointers;
//! a future background compiler must pin that realm lifetime explicitly.

const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const Shape = @import("../shape.zig").Shape;

pub const LoadMode = enum {
    cold,
    own_data,
    prototype_data,
    synthetic_accessor,
};

pub const Load = struct {
    mode: LoadMode,
    receiver_shape: ?*Shape,
    holder_shape: ?*Shape,
    slot: u32,
    revision: u64,
};

pub const StoreMode = enum {
    cold,
    own_data,
    transition,
};

pub const Store = struct {
    mode: StoreMode,
    receiver_shape: ?*Shape,
    holder_shape: ?*Shape,
    post_shape: ?*Shape,
    slot: u32,
    revision: u64,
    guard_epoch: u64,
};

pub const ComputedMode = enum {
    cold,
    monomorphic,
    megamorphic,
};

pub const Computed = struct {
    mode: ComputedMode,
    receiver_shape: ?*Shape,
    slot: u32,
    key_len: u8,
    key_buf: [chunk_mod.computed_key_cap]u8,

    pub fn key(self: *const Computed) []const u8 {
        return self.key_buf[0..self.key_len];
    }
};

pub const CallMode = enum {
    cold,
    direct,
    construct,
};

pub const Call = struct {
    mode: CallMode,
    initial_shape: ?*Shape,
};

pub const ForInMode = enum {
    cold,
    monomorphic,
};

pub const ForIn = struct {
    mode: ForInMode,
    receiver_shape: ?*Shape,
    guard_epoch: u64,
};

pub const Binary = struct {
    mode: chunk_mod.BinaryTypeMode,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    loads: []Load,
    stores: []Store,
    computed: []Computed,
    calls: []Call,
    for_in: []ForIn,
    binary: []Binary,

    pub fn capture(allocator: std.mem.Allocator, chunk: *const Chunk) !Snapshot {
        const loads = try allocator.alloc(Load, chunk.inline_load_caches.len);
        errdefer allocator.free(loads);
        const stores = try allocator.alloc(Store, chunk.inline_store_caches.len);
        errdefer allocator.free(stores);
        const computed = try allocator.alloc(Computed, chunk.inline_computed_caches.len);
        errdefer allocator.free(computed);
        const calls = try allocator.alloc(Call, chunk.inline_call_caches.len);
        errdefer allocator.free(calls);
        const for_in = try allocator.alloc(ForIn, chunk.inline_forin_caches.len);
        errdefer allocator.free(for_in);
        const binary = try allocator.alloc(Binary, chunk.inline_binary_profiles.len);
        errdefer allocator.free(binary);

        for (chunk.inline_load_caches, loads) |cell, *out| {
            const mode: LoadMode = if (cell.shape == null)
                .cold
            else if (cell.kind == .synthetic_accessor)
                .synthetic_accessor
            else if (cell.proto == null)
                .own_data
            else
                .prototype_data;
            out.* = .{
                .mode = mode,
                .receiver_shape = cell.shape,
                .holder_shape = if (mode == .prototype_data or mode == .synthetic_accessor)
                    cell.proto_shape
                else
                    null,
                .slot = cell.slot,
                // Own-property cells normally carry zero here. Global-load
                // cells reuse `proto_rev` for GlobalBindings.decl_revision,
                // so retain it in the pointer-free snapshot for the global
                // specialization to validate against live realm state.
                .revision = cell.proto_rev,
            };
        }

        for (chunk.inline_store_caches, stores) |cell, *out| {
            const mode: StoreMode = if (cell.post_shape != null)
                .transition
            else if (cell.shape != null)
                .own_data
            else
                .cold;
            out.* = .{
                .mode = mode,
                .receiver_shape = if (mode == .transition) cell.pre_shape else cell.shape,
                .holder_shape = if (mode == .cold) null else cell.proto_shape,
                .post_shape = if (mode == .transition) cell.post_shape else null,
                .slot = cell.slot,
                .revision = if (mode == .cold) 0 else cell.proto_rev,
                .guard_epoch = if (mode == .transition) cell.guard_epoch else 0,
            };
        }

        for (chunk.inline_computed_caches, computed) |cell, *out| {
            const mode: ComputedMode = if (cell.cached_key_len == chunk_mod.computed_key_megamorphic)
                .megamorphic
            else if (cell.shape != null and cell.cached_key_len > 0 and
                cell.cached_key_len <= chunk_mod.computed_key_cap)
                .monomorphic
            else
                .cold;
            out.* = .{
                .mode = mode,
                .receiver_shape = if (mode == .monomorphic) cell.shape else null,
                .slot = cell.slot,
                .key_len = if (mode == .monomorphic) cell.cached_key_len else 0,
                .key_buf = @splat(0),
            };
            if (mode == .monomorphic) {
                @memcpy(out.key_buf[0..out.key_len], cell.cached_key_buf[0..out.key_len]);
            }
        }

        for (chunk.inline_call_caches, calls) |cell, *out| {
            const mode: CallMode = if (cell.callee == null)
                .cold
            else if (cell.proto != null)
                .construct
            else
                .direct;
            out.* = .{
                .mode = mode,
                .initial_shape = if (mode == .construct) cell.initial_shape else null,
            };
        }

        for (chunk.inline_forin_caches, for_in) |cell, *out| {
            const ready = cell.recv_shape != null and cell.proto != null and cell.snapshot != null;
            out.* = .{
                .mode = if (ready) .monomorphic else .cold,
                .receiver_shape = if (ready) cell.recv_shape else null,
                .guard_epoch = if (ready) cell.guard_epoch else 0,
            };
        }

        for (chunk.inline_binary_profiles, binary) |profile, *out| {
            out.* = .{ .mode = profile.mode() };
        }

        return .{
            .allocator = allocator,
            .loads = loads,
            .stores = stores,
            .computed = computed,
            .calls = calls,
            .for_in = for_in,
            .binary = binary,
        };
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.loads);
        self.allocator.free(self.stores);
        self.allocator.free(self.computed);
        self.allocator.free(self.calls);
        self.allocator.free(self.for_in);
        self.allocator.free(self.binary);
        self.* = undefined;
    }
};
