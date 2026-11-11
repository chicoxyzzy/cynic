//! Immediate-free non-GC storage charged to the owning heap's live-byte limit.
const std = @import("std");
const Heap = @import("heap.zig").Heap;

pub const QuotaAllocator = struct {
    backing: std.mem.Allocator,
    heap: *Heap,

    pub fn allocator(self: *QuotaAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *QuotaAllocator = @ptrCast(@alignCast(ctx));
        self.heap.charge(len) catch return null;
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse {
            self.heap.discharge(len);
            return null;
        };
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *QuotaAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            self.heap.charge(delta) catch return false;
            if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
                self.heap.discharge(delta);
                return false;
            }
        } else {
            if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
            self.heap.discharge(memory.len - new_len);
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *QuotaAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            self.heap.charge(delta) catch return null;
            const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse {
                self.heap.discharge(delta);
                return null;
            };
            return ptr;
        }
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.heap.discharge(memory.len - new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *QuotaAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.heap.discharge(memory.len);
    }
};
