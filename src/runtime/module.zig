//! `ModuleRecord` — Cynic's runtime module instance.
//!
//! Per ECMA-262 §16.2.1.5 ModuleRecord, each unique module
//! source has one MR. Cynic's later shape:
//! • `source_url` — resolved (canonical) URL; doubles as
//! the cache key on `realm.modules`.
//! • `exports` — JSObject namespace populated as the
//! module body runs. Per-named-export property; default
//! under `"default"`.
//! • `state` — uninstantiated → evaluating → evaluated.
//! Cycles are broken by returning the partial `exports`
//! when a module that's still `evaluating` is re-entered.
//!
//! later does eager linking + evaluation: `module_load`
//! opcode parses, compiles, runs the module synchronously and
//! caches the result. Top-level await + true two-phase
//! linking (§16.2.1.5.2 Link, §16.2.1.5.4 Evaluate) are
//! later.

const std = @import("std");

const Value = @import("value.zig").Value;
const JSObject = @import("object.zig").JSObject;
const Chunk = @import("../bytecode/chunk.zig").Chunk;

pub const ModuleState = enum(u8) {
    /// Module hasn't started evaluating — entry just allocated.
    uninstantiated,
    /// Module body is currently running; cycles route here and
    /// receive the in-progress exports namespace.
    evaluating,
    /// Module body returned successfully; `exports` is final.
    evaluated,
    /// Module body threw — `exports` is whatever was populated
    /// before the throw. Subsequent imports also throw.
    errored,
};

pub const ModuleRecord = struct {
    /// Resolved URL — canonical key into `realm.modules`. Owned
    /// by the realm allocator.
    source_url: []const u8,
    /// Namespace object containing the module's exports.
    /// Populated as `export` declarations run; finalized at
    /// module-body Return. Borrowed pointer — the heap owns
    /// the JSObject.
    exports: *JSObject,
    /// The compiled module chunk. Lives for the realm's
    /// lifetime — heap-allocated `JSFunction`s declared inside
    /// the module hold non-owning pointers into this chunk's
    /// `function_templates`. Cleaning up early would
    /// invalidate those pointers, so we keep the chunk pinned
    /// until `realm.deinit`.
    chunk: ?Chunk = null,
    state: ModuleState = .uninstantiated,
    /// If `state ==.errored`, the thrown value is stashed
    /// here so subsequent imports can re-throw it.
    error_value: Value = Value.undefined_,
    /// Mark-sweep bit, written by `Heap.markValue`.
    marked: bool = false,

    pub fn init(allocator: std.mem.Allocator, source_url: []const u8, exports: *JSObject) !*ModuleRecord {
        const m = try allocator.create(ModuleRecord);
        m.* = .{ .source_url = source_url, .exports = exports };
        return m;
    }

    pub fn deinit(self: *ModuleRecord, allocator: std.mem.Allocator) void {
        if (self.chunk) |*c| c.deinit(allocator);
        allocator.destroy(self);
    }
};
