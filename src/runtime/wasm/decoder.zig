//! WebAssembly binary-format decoder.
//!
//! Streaming reader over a `[]const u8` of WASM bytes. Today it
//! handles only the §5.2.2 preamble — magic + version. Section
//! decoding lands in the next step.
//!
//! Error policy: every parse failure surfaces as a `DecodeError`
//! variant; the caller translates it to a `WebAssembly.CompileError`
//! at the JS-API boundary. The decoder never panics on malformed
//! input.

const std = @import("std");
const module_mod = @import("module.zig");

const Module = module_mod.Module;

pub const DecodeError = error{
    /// Buffer ended mid-preamble or mid-section.
    Truncated,
    /// Magic number (`\0asm`) mismatch — not a WebAssembly binary.
    BadMagic,
    /// Wire-format version other than 1.
    BadVersion,
};

/// Decode the bytes of a WebAssembly binary into a `Module`. The
/// allocator is unused today; it threads through so section decoders
/// can allocate their payloads against it once they arrive.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Module {
    _ = allocator;

    if (bytes.len < 8) return error.Truncated;

    if (!std.mem.eql(u8, bytes[0..4], &module_mod.magic)) {
        return error.BadMagic;
    }

    const wire_version = std.mem.readInt(u32, bytes[4..8], .little);
    if (wire_version != module_mod.version) return error.BadVersion;

    return Module{ .version = wire_version };
}
