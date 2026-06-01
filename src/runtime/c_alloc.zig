//! Target-aware C allocator access for the vendored libunicode host
//! hook (`normalizeRealloc` in `builtins/string.zig`, backing
//! `unicode_normalize`).
//!
//! libunicode allocates the normalization output through a
//! caller-supplied `realloc`-style callback. On a hosted target the
//! natural choice is libc's `malloc` / `free` / `realloc` via `std.c`.
//! But the `wasm32-freestanding` playground build has no libc — `std.c`
//! exposes no allocator there. For that target the C `malloc` family is
//! instead provided by `src/wasm_shim.c`, which forwards to the
//! module's Zig `WasmAllocator`.
//!
//! This module hides the split: `malloc` / `free` / `realloc` here
//! resolve to `std.c` on a hosted target and to the shim's C symbols
//! (bound via `extern`) on freestanding, so a single allocator backs
//! every byte regardless of target.

const std = @import("std");

const freestanding = @import("builtin").os.tag == .freestanding;

// On freestanding these resolve to the symbols defined in
// `src/wasm_shim.c`; that file is linked into the WASM module.
const shim = struct {
    extern fn malloc(usize) ?*anyopaque;
    extern fn free(?*anyopaque) void;
    extern fn realloc(?*anyopaque, usize) ?*anyopaque;
};

pub fn malloc(size: usize) ?*anyopaque {
    return if (freestanding) shim.malloc(size) else std.c.malloc(size);
}

pub fn free(ptr: *anyopaque) void {
    if (freestanding) shim.free(ptr) else std.c.free(ptr);
}

pub fn realloc(ptr: *anyopaque, size: usize) ?*anyopaque {
    return if (freestanding) shim.realloc(ptr, size) else std.c.realloc(ptr, size);
}

/// Shared `realloc`-style callback body for the QuickJS host hooks.
/// `size == 0` frees and returns null; a null `ptr` allocates.
pub fn reallocHook(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (size == 0) {
        if (ptr) |p| free(p);
        return null;
    }
    if (ptr) |p| return realloc(p, size);
    return malloc(size);
}
