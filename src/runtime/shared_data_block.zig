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
//! The block also carries the §25.4 wait list that cross-thread
//! `Atomics.wait` / `Atomics.notify` park on (see
//! `docs/multi-agent-atomics.md`).

const std = @import("std");

/// Process-global count of currently-live shared data blocks (created
/// minus freed). A diagnostic hook: a host that creates and destroys
/// many short-lived blocks can assert this returns to its baseline to
/// catch a block that was never released (a leaked reference pinning
/// shared memory). Bumped in `create`, dropped when the final reference
/// is released and the block is freed.
pub var live_blocks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// One parked `Atomics.wait`. The node lives on the *waiting thread's
/// stack* and is linked into its block's wait list for the duration of
/// the wait — the list owns no memory. A waiter unlinks itself (under
/// `wait_lock`) before its frame returns, so `notify` (which only walks
/// the list under the same lock) can never touch a dead node.
pub const Waiter = struct {
    /// §25.4 keys the wait list on the byte index within the block, so
    /// two views over the same block waiting on the same byte share a
    /// key while different indices don't collide.
    byte_pos: usize,
    /// Raised by `notify` (under `wait_lock`); the waiter polls it.
    woken: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    next: ?*Waiter = null,
};

pub const SharedDataBlock = struct {
    /// The shared bytes, allocated to `max_byte_length` up front so a
    /// growable buffer can `grow` in place without moving the store
    /// (other agents' views stay valid). The live data is
    /// `bytes[0..byte_length]`.
    bytes: []u8,
    /// §25.2.x [[ArrayBufferByteLength]] — current length. Grows
    /// monotonically (grow-only) up to `max_byte_length`. Atomic so a
    /// cross-agent `grow` is observed coherently: the `grow` does a
    /// release-store and every reader (length-tracking view length,
    /// `byteLength`, `live()`) an acquire-load, so an agent that sees
    /// the new length also sees the (pre-zeroed) capacity behind it.
    byte_length: std.atomic.Value(usize),
    /// §25.2.x [[ArrayBufferMaxByteLength]] — capacity. Equals
    /// `byte_length` for a non-growable buffer.
    max_byte_length: usize,
    /// Reference count across all referencing `SharedArrayBuffer`
    /// objects (in any agent). Atomic so cross-thread broadcast /
    /// sweep is race-free.
    refcount: std.atomic.Value(usize),
    /// §25.4.11/.12 wait-list spinlock — the spec's "critical section"
    /// guarding the list (and the wait-time value compare) against
    /// concurrent `wait` / `notify` across agents.
    wait_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Head of the intrusive list of parked waiters (stack-allocated
    /// nodes; see `Waiter`). Touched only under `wait_lock`.
    wait_head: ?*Waiter = null,

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
        self.* = .{
            .bytes = bytes,
            .byte_length = std.atomic.Value(usize).init(byte_length),
            .max_byte_length = max_byte_length,
            .refcount = std.atomic.Value(usize).init(1),
        };
        _ = live_blocks.fetchAdd(1, .monotonic);
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
            _ = live_blocks.fetchSub(1, .monotonic);
        }
    }

    /// The live data slice (`bytes[0..byte_length]`).
    pub fn live(self: *SharedDataBlock) []u8 {
        return self.bytes[0..self.byte_length.load(.acquire)];
    }

    // ── §25.4 wait list ─────────────────────────────────────────────
    // The lock makes the wait-time value-compare + AddWaiter atomic
    // w.r.t. notify (the spec's EnterCriticalSection), and lets notify
    // wake EXACTLY `count` waiters on a byte index — a per-slot
    // sequence word can only wake-all, which fails `notify(ta, i, 1)`
    // against several parked agents.

    pub fn lockWaiters(self: *SharedDataBlock) void {
        while (self.wait_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    pub fn unlockWaiters(self: *SharedDataBlock) void {
        self.wait_lock.store(false, .release);
    }

    /// Append `w` at the tail. Caller holds `wait_lock`. §25.4.11.13
    /// AddWaiter adds to the END of the list and §25.4.12 Notify wakes
    /// from the FRONT, so a head-first walk in `wakeWaiters` wakes the
    /// oldest waiter first (FIFO), which `notify-in-order` asserts.
    pub fn addWaiter(self: *SharedDataBlock, w: *Waiter) void {
        w.next = null;
        var pp: *?*Waiter = &self.wait_head;
        while (pp.*) |cur| pp = &cur.next;
        pp.* = w;
    }

    /// Unlink `w` if present. Caller holds `wait_lock`.
    pub fn removeWaiter(self: *SharedDataBlock, w: *Waiter) void {
        var pp: *?*Waiter = &self.wait_head;
        while (pp.*) |cur| {
            if (cur == w) {
                pp.* = cur.next;
                return;
            }
            pp = &cur.next;
        }
    }

    /// Wake up to `count` not-yet-woken waiters parked on `byte_pos`;
    /// return how many were woken. Caller holds `wait_lock`.
    pub fn wakeWaiters(self: *SharedDataBlock, byte_pos: usize, count: u32) u32 {
        var n: u32 = 0;
        var cur = self.wait_head;
        while (cur) |w| : (cur = w.next) {
            if (n >= count) break;
            if (w.byte_pos == byte_pos and !w.woken.load(.monotonic)) {
                w.woken.store(true, .release);
                n += 1;
            }
        }
        return n;
    }
};
