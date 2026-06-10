//! Executable-memory allocator for the JIT substrate — the one place
//! in the engine that owns mmap'd code pages, W^X transitions, and
//! instruction-cache maintenance. Every tier (Bistromath, Ohaimark,
//! Spasm) installs code through here and never touches a syscall.
//! Design record: docs/jit.md §8.
//!
//! W^X by construction: the only write path is `install`, which
//! copies a finished buffer into the region inside a transient write
//! window — per-thread `pthread_jit_write_protect_np` on macOS/arm64
//! (where `mprotect` on a `MAP_JIT` region has failed since 11.2),
//! page-protection flips elsewhere. No writable pointer into the
//! region ever escapes this file.
//!
//! Thread affinity: an allocator belongs to one engine and is not
//! thread-safe — the same contract as the rest of the runtime. The
//! macOS/arm64 write window is per-thread, so installs must happen
//! on the thread that will run the code.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this target can host the JIT at all. Non-native targets
/// (the playground's `wasm32-freestanding` build) compile the tiers
/// out behind this switch — docs/jit.md §8.
pub const supported = switch (builtin.os.tag) {
    .macos, .linux => switch (builtin.cpu.arch) {
        .aarch64, .x86_64 => true,
        else => false,
    },
    else => false,
};

/// macOS/arm64: `MAP_JIT` pages with the per-thread write toggle
/// (hardware W^X). Everywhere else W^X is enforced with `mprotect`.
const darwin_jit = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: ?*anyopaque, len: usize) void;
// compiler_rt's cache-maintenance entry point. Real work on
// non-Apple aarch64; Zig's compiler_rt explicitly excludes Apple
// platforms there, hence `sys_icache_invalidate` above.
extern fn __clear_cache(start: *anyopaque, end: *anyopaque) void;

pub const Error = error{
    /// The fixed code region is exhausted. Callers degrade: the tier
    /// marks the chunk `dont_compile` and stays interpreted
    /// (docs/jit.md §4.1) — never abort the host.
    OutOfCodeMemory,
    /// Reserving the region failed at init (or the target has no
    /// JIT support at all).
    CodeRegionUnavailable,
};

/// Installed slots are 16-byte aligned: AArch64 only needs 4, but 16
/// keeps slots cache-line-tidy and covers x86_64 for free.
const slot_align = 16;

pub const CodeAllocator = struct {
    gpa: std.mem.Allocator,
    region: []align(std.heap.page_size_min) u8,
    /// Bump offset — everything below is allocated or free-listed.
    top: usize = 0,
    /// Freed slots, reused first-fit. No coalescing or splitting:
    /// compiled functions are small and few (docs/jit.md §8 —
    /// "fragmentation is a non-problem at this scale"); revisit
    /// with real fragmentation data.
    free_list: std.ArrayListUnmanaged(Slot) = .empty,

    const Slot = struct { off: usize, len: usize };

    pub fn init(gpa: std.mem.Allocator, reserve_bytes: usize) Error!CodeAllocator {
        if (comptime !supported) {
            return error.CodeRegionUnavailable;
        } else {
            const len = std.mem.alignForward(usize, @max(reserve_bytes, 1), std.heap.pageSize());
            // With the per-thread toggle the region is mapped RWX
            // once and the hardware enforces W^X per thread; on the
            // mprotect path it starts RW and pages flip to R-X as
            // code is installed.
            const prot: std.posix.PROT = if (comptime darwin_jit)
                .{ .READ = true, .WRITE = true, .EXEC = true }
            else
                .{ .READ = true, .WRITE = true };
            const flags = comptime blk: {
                var f: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
                if (darwin_jit) f.JIT = true;
                break :blk f;
            };
            const region = std.posix.mmap(null, len, prot, flags, -1, 0) catch
                return error.CodeRegionUnavailable;
            if (comptime darwin_jit) {
                // Fresh MAP_JIT memory: leave the calling thread in
                // the execute-protected state until the first write.
                pthread_jit_write_protect_np(1);
            }
            return .{ .gpa = gpa, .region = region };
        }
    }

    pub fn deinit(self: *CodeAllocator) void {
        self.free_list.deinit(self.gpa);
        std.posix.munmap(self.region);
        self.* = undefined;
    }

    /// Copy a finished code buffer into the region and return the
    /// executable slice (16-byte aligned). The write happens inside
    /// a transient write window; the i-cache is invalidated before
    /// returning, so the result is immediately callable.
    pub fn install(self: *CodeAllocator, code: []const u8) Error![]const u8 {
        const slot = try self.allocSlot(code.len);
        const dst = self.region[slot.off..][0..code.len];
        self.beginWrite(dst);
        @memcpy(dst, code);
        self.endWrite(dst);
        flushICache(dst);
        return dst;
    }

    /// Return a slot to the free list. The bytes stay mapped and
    /// executable; calling through a freed slice is a caller bug of
    /// the use-after-free class.
    pub fn free(self: *CodeAllocator, code: []const u8) void {
        const off = @intFromPtr(code.ptr) - @intFromPtr(self.region.ptr);
        const len = std.mem.alignForward(usize, @max(code.len, 1), slot_align);
        self.free_list.append(self.gpa, .{ .off = off, .len = len }) catch {
            // Bookkeeping OOM: leak the slot inside the region; the
            // region itself is still reclaimed wholesale at deinit.
        };
    }

    fn allocSlot(self: *CodeAllocator, len: usize) Error!Slot {
        const want = std.mem.alignForward(usize, @max(len, 1), slot_align);
        for (self.free_list.items, 0..) |slot, i| {
            if (slot.len >= want) {
                _ = self.free_list.swapRemove(i);
                return slot;
            }
        }
        if (self.top + want > self.region.len) return error.OutOfCodeMemory;
        const slot: Slot = .{ .off = self.top, .len = want };
        self.top += want;
        return slot;
    }

    fn beginWrite(self: *CodeAllocator, dst: []u8) void {
        if (comptime darwin_jit) {
            pthread_jit_write_protect_np(0);
        } else {
            self.protectPages(dst, .{ .READ = true, .WRITE = true });
        }
    }

    fn endWrite(self: *CodeAllocator, dst: []u8) void {
        if (comptime darwin_jit) {
            pthread_jit_write_protect_np(1);
        } else {
            self.protectPages(dst, .{ .READ = true, .EXEC = true });
        }
    }

    /// Flip protection on the pages spanning `dst`. Pages shared
    /// with already-installed code flip with them — safe under the
    /// single-threaded-allocator contract, and they return to R-X
    /// before `install` hands anything back.
    fn protectPages(self: *CodeAllocator, dst: []u8, prot: std.posix.PROT) void {
        const page = std.heap.pageSize();
        const base = @intFromPtr(self.region.ptr);
        const lo = std.mem.alignBackward(usize, @intFromPtr(dst.ptr) - base, page);
        const hi = @min(
            std.mem.alignForward(usize, @intFromPtr(dst.ptr) - base + dst.len, page),
            self.region.len,
        );
        const pages = self.region[lo..hi];
        const rc = std.c.mprotect(@alignCast(@ptrCast(pages.ptr)), pages.len, prot);
        // mprotect over pages this allocator owns, with a valid
        // protection, cannot fail recoverably; a failure would leave
        // the new code non-executable and fault at the call site.
        std.debug.assert(rc == 0);
    }
};

/// Invalidate the instruction cache for freshly written code.
/// x86_64 has coherent i/d-caches — nothing to do there.
fn flushICache(code: []const u8) void {
    switch (comptime builtin.cpu.arch) {
        .aarch64 => if (comptime builtin.os.tag == .macos) {
            sys_icache_invalidate(@constCast(@ptrCast(code.ptr)), code.len);
        } else {
            const start: *anyopaque = @constCast(@ptrCast(code.ptr));
            const end: *anyopaque = @constCast(@ptrCast(code.ptr + code.len));
            __clear_cache(start, end);
        },
        else => {},
    }
}

/// View installed code as a callable function pointer.
pub fn asFn(comptime F: type, code: []const u8) F {
    return @ptrCast(@alignCast(code.ptr));
}

// A hand-assembled `return 42` for the host ISA — the substrate's
// hello-world, also used by the masm tests as a known-good payload.
pub const ret42_stub: []const u8 = switch (builtin.cpu.arch) {
    // movz x0, #42 ; ret
    .aarch64 => &.{ 0x40, 0x05, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6 },
    // mov eax, 42 ; ret
    .x86_64 => &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 },
    else => &.{},
};

test "jit code_alloc: install and execute a return-42 stub" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer ca.deinit();
    const code = try ca.install(ret42_stub);
    const f = asFn(*const fn () callconv(.c) u64, code);
    try std.testing.expectEqual(@as(u64, 42), f());
}

test "jit code_alloc: a freed slot is reused first-fit" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer ca.deinit();
    const a = try ca.install(ret42_stub);
    ca.free(a);
    const b = try ca.install(ret42_stub);
    try std.testing.expectEqual(a.ptr, b.ptr);
    // And the reused slot still runs.
    const f = asFn(*const fn () callconv(.c) u64, b);
    try std.testing.expectEqual(@as(u64, 42), f());
}

test "jit code_alloc: exhaustion is a catchable error, not an abort" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try CodeAllocator.init(std.testing.allocator, 1);
    defer ca.deinit();
    // The one-byte reservation rounds up to a single page; fill it.
    const blob: [1024]u8 = @splat(0);
    var installs: usize = 0;
    while (installs < 1024) : (installs += 1) {
        _ = ca.install(&blob) catch |err| {
            try std.testing.expect(err == error.OutOfCodeMemory);
            break;
        };
    } else return error.TestUnexpectedResult; // never hit the wall
    try std.testing.expect(installs >= 1);
}

test "jit code_alloc: installs are 16-byte aligned" {
    if (comptime !supported) return error.SkipZigTest;
    var ca = try CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer ca.deinit();
    const a = try ca.install(&.{ 0x01, 0x02, 0x03 });
    const b = try ca.install(&.{ 0x04, 0x05 });
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(a.ptr) % slot_align);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(b.ptr) % slot_align);
}
