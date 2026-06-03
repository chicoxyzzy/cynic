//! §25.2 SharedArrayBuffer backing store — a refcounted, **non-GC**
//! byte block shared across agents.
//!
//! Unlike a plain ArrayBuffer (whose bytes live in the owning realm's
//! GC-swept allocator), a SharedArrayBuffer's data block must outlive
//! any single realm and be reachable from multiple agents (each its own
//! thread + heap). So it lives here: page-allocated, atomically
//! refcounted, freed only when the last referencing `SharedArrayBuffer`
//! object — across all agents — is gone.
//!
//! The block also carries the futex state (`mutex` / `cond`) that
//! cross-thread `Atomics.wait` / `Atomics.notify` park on
//! (see `docs/multi-agent-atomics.md`).

const std = @import("std");

pub const SharedDataBlock = struct {
    /// The shared bytes, allocated to `max_byte_length` up front so a
    /// growable buffer can `grow` in place without moving the store
    /// (other agents' views stay valid). The live data is
    /// `bytes[0..byte_length]`.
    bytes: []u8,
    /// §25.2.x [[ArrayBufferByteLength]] — current length. Grows
    /// monotonically (grow-only) up to `max_byte_length`.
    byte_length: usize,
    /// §25.2.x [[ArrayBufferMaxByteLength]] — capacity. Equals
    /// `byte_length` for a non-growable buffer.
    max_byte_length: usize,
    /// Reference count across all referencing `SharedArrayBuffer`
    /// objects (in any agent). Atomic so cross-thread broadcast /
    /// sweep is race-free.
    refcount: std.atomic.Value(usize),
    // NOTE: the futex state (mutex/cond) for cross-thread
    // `Atomics.wait` / `notify` is added in Phase B (see
    // docs/multi-agent-atomics.md) using the `std.Io` concurrency
    // model the engine/harness already use. Phase A is thread-free.

    /// Allocate a zeroed block of `max_byte_length` bytes (≥
    /// `byte_length`), refcount 1. Uses the process-global page
    /// allocator — never a realm's GC heap.
    pub fn create(byte_length: usize, max_byte_length: usize) !*SharedDataBlock {
        const gpa = std.heap.page_allocator;
        const self = try gpa.create(SharedDataBlock);
        errdefer gpa.destroy(self);
        const bytes = try gpa.alloc(u8, max_byte_length);
        @memset(bytes, 0);
        self.* = .{
            .bytes = bytes,
            .byte_length = byte_length,
            .max_byte_length = max_byte_length,
            .refcount = std.atomic.Value(usize).init(1),
        };
        return self;
    }

    /// Add a reference (a new `SharedArrayBuffer` object now points
    /// here — e.g. via `$262.agent.broadcast`).
    pub fn retain(self: *SharedDataBlock) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Drop a reference; free the block when the last one goes. Called
    /// from a `SharedArrayBuffer` object's extension `deinit` (GC sweep
    /// or realm teardown).
    pub fn release(self: *SharedDataBlock) void {
        // `.acq_rel` so the final decrement happens-after every prior
        // release across threads before we free.
        if (self.refcount.fetchSub(1, .acq_rel) == 1) {
            const gpa = std.heap.page_allocator;
            gpa.free(self.bytes);
            gpa.destroy(self);
        }
    }

    /// The live data slice (`bytes[0..byte_length]`).
    pub fn live(self: *SharedDataBlock) []u8 {
        return self.bytes[0..self.byte_length];
    }
};
