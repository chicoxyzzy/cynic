//! Unit tests for the WebAssembly engine. Sibling files (`decoder.zig`,
//! `module.zig`, …) also carry their own `test` blocks; this file
//! aggregates higher-level behavioural tests that span more than one
//! module.

const std = @import("std");
const testing = std.testing;

const wasm = @import("wasm.zig");

/// The eight-byte preamble of every well-formed wasm binary:
/// `\0asm\x01\x00\x00\x00` (magic + version 1, little-endian).
const empty_module_bytes: []const u8 = &.{
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
};

test "wasm decoder: accepts the empty-module preamble" {
    const m = try wasm.decode(testing.allocator, empty_module_bytes);
    try testing.expectEqual(@as(u32, 1), m.version);
}

test "wasm decoder: rejects an input shorter than the preamble" {
    const truncated: []const u8 = &.{ 0x00, 0x61, 0x73, 0x6d };
    try testing.expectError(error.Truncated, wasm.decode(testing.allocator, truncated));
}

test "wasm decoder: rejects an empty input" {
    const empty: []const u8 = &.{};
    try testing.expectError(error.Truncated, wasm.decode(testing.allocator, empty));
}

test "wasm decoder: rejects a bad magic number" {
    const bad_magic: []const u8 = &.{
        0xde, 0xad, 0xbe, 0xef,
        0x01, 0x00, 0x00, 0x00,
    };
    try testing.expectError(error.BadMagic, wasm.decode(testing.allocator, bad_magic));
}

test "wasm decoder: rejects wire version 2" {
    const v2: []const u8 = &.{
        0x00, 0x61, 0x73, 0x6d,
        0x02, 0x00, 0x00, 0x00,
    };
    try testing.expectError(error.BadVersion, wasm.decode(testing.allocator, v2));
}

test "wasm decoder: rejects wire version 0" {
    const v0: []const u8 = &.{
        0x00, 0x61, 0x73, 0x6d,
        0x00, 0x00, 0x00, 0x00,
    };
    try testing.expectError(error.BadVersion, wasm.decode(testing.allocator, v0));
}
