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
    /// §25.4.11/.12 — per-4-byte-slot count of agents currently parked
    /// in `Atomics.wait` on that slot. `wait` bumps its slot before
    /// parking and clears it after; `notify` reads it to return the
    /// number it woke (`std.Thread.Futex` itself reports no count). One
    /// entry per i32 slot (`max_byte_length / 4`).
    waiters: []std.atomic.Value(u32),
    /// Per-slot notify-sequence word that `std.Thread.Futex` parks on.
    /// `notify` bumps it (and wakes); `wait` parks while it's unchanged.
    /// Crucially this is NOT the data element — a plain `Atomics.store`
    /// / `xor` mutates the element but must NOT wake a waiter (only a
    /// `notify` does), so the wait list is keyed on this separate word.
    notify_seq: []std.atomic.Value(u32),

    /// Allocate a zeroed block of `max_byte_length` bytes (≥
    /// `byte_length`), refcount 1. Uses the process-global page
    /// allocator — never a realm's GC heap.
    pub fn create(byte_length: usize, max_byte_length: usize) !*SharedDataBlock {
        const gpa = std.heap.page_allocator;
        const self = try gpa.create(SharedDataBlock);
        errdefer gpa.destroy(self);
        const bytes = try gpa.alloc(u8, max_byte_length);
        errdefer gpa.free(bytes);
        @memset(bytes, 0);
        const slots = max_byte_length / 4;
        const waiters = try gpa.alloc(std.atomic.Value(u32), slots);
        errdefer gpa.free(waiters);
        for (waiters) |*w| w.* = std.atomic.Value(u32).init(0);
        const notify_seq = try gpa.alloc(std.atomic.Value(u32), slots);
        for (notify_seq) |*w| w.* = std.atomic.Value(u32).init(0);
        self.* = .{
            .bytes = bytes,
            .byte_length = byte_length,
            .max_byte_length = max_byte_length,
            .refcount = std.atomic.Value(usize).init(1),
            .waiters = waiters,
            .notify_seq = notify_seq,
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
            gpa.free(self.notify_seq);
            gpa.free(self.waiters);
            gpa.free(self.bytes);
            gpa.destroy(self);
        }
    }

    /// The live data slice (`bytes[0..byte_length]`).
    pub fn live(self: *SharedDataBlock) []u8 {
        return self.bytes[0..self.byte_length];
    }
};
