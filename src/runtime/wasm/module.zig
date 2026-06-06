//! Parsed WebAssembly module representation.
//!
//! Mirrors §2.5 (Modules) of the Core specification. Each indexable
//! space — types, functions, tables, memories, globals, elements,
//! data, imports, exports — will land as a slice on this struct as
//! the decoder grows section by section. The current shape covers
//! only the preamble; sections arrive in subsequent steps.

const std = @import("std");

/// §5.2.2 — every well-formed module begins with the 4-byte magic
/// number `\0asm` followed by a little-endian u32 version. Version 1
/// is the only value defined by the Core specification.
pub const magic: [4]u8 = .{ 0x00, 0x61, 0x73, 0x6d };
pub const version: u32 = 1;

/// A decoded module. Owned by the caller's arena: the decoder
/// allocates section payloads inside whatever allocator the caller
/// passes to `decode`, and never frees them itself — the realm will
/// drop the whole arena when the `WebAssembly.Module` JS object is
/// collected.
pub const Module = struct {
    /// Wire-format version (always 1 today; the decoder rejects
    /// other values up front).
    version: u32 = version,
};
