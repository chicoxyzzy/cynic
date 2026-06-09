//! Diagnostics → playground-frame error text.
//!
//! Pulled out of `playground/wasm.zig` so `zig build test` can
//! exercise it. The playground entry only compiles for wasm32-freestanding,
//! but the format
//! helpers themselves have no wasm-specific dependencies — they just
//! walk a `Diagnostics` buffer and emit text. The allocator is
//! parameterised so production passes the WASM allocator and tests
//! pass `testing.allocator`.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const source = @import("source.zig");

const Diagnostics = diagnostic.Diagnostics;
const Diagnostic = diagnostic.Diagnostic;
const Span = source.Span;

const empty_span: Span = .{ .start = 0, .end = 0 };

/// Return the first error-severity diagnostic, or null if the buffer
/// holds only warnings / notes. Used by the playground's
/// parse-and-compile path to decide whether to surface a recorded
/// error or fall through to a context-aware fallback string.
pub fn firstError(diags: *const Diagnostics) ?Diagnostic {
    for (diags.items) |d| {
        if (d.severity == .err) return d;
    }
    return null;
}

/// Append every error-severity diagnostic to `buf` as one
/// `Class: code [start..end] — message?` line each. Warnings and
/// notes are dropped (the playground reports failures, not lint).
/// Emits nothing when no error diagnostics exist; callers pick the
/// right context-aware fallback via `formatDiagnostics`.
pub fn appendDiagnostics(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    diags: *const Diagnostics,
) !void {
    var wrote = false;
    for (diags.items) |d| {
        if (d.severity != .err) continue;
        if (wrote) try buf.append(allocator, '\n');
        wrote = true;
        var scratch: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&scratch, "{s}: {s} [{d}..{d}]", .{
            d.code.errorClass().name(),
            @tagName(d.code),
            d.span.start,
            d.span.end,
        });
        try buf.appendSlice(allocator, line);
        if (d.message.len != 0) {
            try buf.appendSlice(allocator, " — ");
            try buf.appendSlice(allocator, d.message);
        }
    }
}

/// Format `diags` for the playground's error section. If a recorded
/// error diagnostic exists, append it and return its span. If not
/// (an engine gap — a CompileError / ParseError throw without a
/// preceding `report()`), emit the caller's `fallback` text and
/// return an empty span. Keeps the per-caller `catch {}` blocks
/// short and stops the wrong context (parser vs compiler)
/// surfacing on a misclassified failure.
pub fn formatDiagnostics(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    diags: *const Diagnostics,
    fallback: []const u8,
) Span {
    if (firstError(diags)) |d| {
        appendDiagnostics(allocator, buf, diags) catch {};
        return d.span;
    }
    buf.appendSlice(allocator, fallback) catch {};
    return empty_span;
}

// ---------------------------------------------------------------------------
// Tests — hand-build a `Diagnostics` buffer and exercise each helper.
// No parser / compiler dependency; this keeps the test surface tight
// on the format logic itself.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn pushErr(
    allocator: std.mem.Allocator,
    diags: *Diagnostics,
    code: diagnostic.Code,
    start: u32,
    end: u32,
) !void {
    try diags.append(allocator, .{
        .severity = .err,
        .code = code,
        .span = .{ .start = start, .end = end },
    });
}

fn pushWarn(
    allocator: std.mem.Allocator,
    diags: *Diagnostics,
    code: diagnostic.Code,
    start: u32,
    end: u32,
) !void {
    try diags.append(allocator, .{
        .severity = .warning,
        .code = code,
        .span = .{ .start = start, .end = end },
    });
}

test "wasm_diag: firstError returns null on empty buffer" {
    var diags: Diagnostics = .empty;
    try testing.expect(firstError(&diags) == null);
}

test "wasm_diag: firstError returns null when only warnings" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    try pushWarn(testing.allocator, &diags, .unexpected_token, 0, 1);
    try testing.expect(firstError(&diags) == null);
}

test "wasm_diag: firstError returns the first err-severity entry" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    try pushWarn(testing.allocator, &diags, .unexpected_token, 0, 1);
    try pushErr(testing.allocator, &diags, .unexpected_token, 4, 9);
    try pushErr(testing.allocator, &diags, .unexpected_token, 11, 12);

    const first = firstError(&diags) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 4), first.span.start);
    try testing.expectEqual(@as(u32, 9), first.span.end);
}

test "wasm_diag: appendDiagnostics emits one line per error" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    try pushErr(testing.allocator, &diags, .unexpected_token, 4, 9);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendDiagnostics(testing.allocator, &buf, &diags);

    try testing.expectEqualStrings(
        "SyntaxError: unexpected_token [4..9]",
        buf.items,
    );
}

test "wasm_diag: appendDiagnostics newline-joins multiple errors" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    try pushErr(testing.allocator, &diags, .unexpected_token, 0, 3);
    try pushErr(testing.allocator, &diags, .unexpected_token, 10, 15);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendDiagnostics(testing.allocator, &buf, &diags);

    try testing.expectEqualStrings(
        "SyntaxError: unexpected_token [0..3]\nSyntaxError: unexpected_token [10..15]",
        buf.items,
    );
}

test "wasm_diag: appendDiagnostics drops warnings" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    try pushWarn(testing.allocator, &diags, .unexpected_token, 0, 3);
    try pushErr(testing.allocator, &diags, .unexpected_token, 10, 15);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendDiagnostics(testing.allocator, &buf, &diags);

    // Only the error line is in the output — the warning is silent.
    try testing.expectEqualStrings(
        "SyntaxError: unexpected_token [10..15]",
        buf.items,
    );
}

test "wasm_diag: appendDiagnostics includes message when present" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    try diags.append(testing.allocator, .{
        .severity = .err,
        .code = .unexpected_token,
        .span = .{ .start = 4, .end = 9 },
        .message = "expected `;`",
    });

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendDiagnostics(testing.allocator, &buf, &diags);

    try testing.expectEqualStrings(
        "SyntaxError: unexpected_token [4..9] — expected `;`",
        buf.items,
    );
}

test "wasm_diag: formatDiagnostics with recorded error uses it" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    try pushErr(testing.allocator, &diags, .unexpected_token, 7, 12);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const span = formatDiagnostics(
        testing.allocator,
        &buf,
        &diags,
        "SyntaxError: fallback unused",
    );

    try testing.expectEqualStrings(
        "SyntaxError: unexpected_token [7..12]",
        buf.items,
    );
    try testing.expectEqual(@as(u32, 7), span.start);
    try testing.expectEqual(@as(u32, 12), span.end);
}

test "wasm_diag: formatDiagnostics empty buffer uses fallback and empty span" {
    var diags: Diagnostics = .empty;
    // No deinit needed — never appended.

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const span = formatDiagnostics(
        testing.allocator,
        &buf,
        &diags,
        "SyntaxError: failed to compile (engine did not record a diagnostic)",
    );

    try testing.expectEqualStrings(
        "SyntaxError: failed to compile (engine did not record a diagnostic)",
        buf.items,
    );
    try testing.expectEqual(@as(u32, 0), span.start);
    try testing.expectEqual(@as(u32, 0), span.end);
}

test "wasm_diag: formatDiagnostics with warnings-only buffer uses fallback" {
    // Only-warnings is the same "no recorded error" case as an
    // empty buffer — the fallback must fire, not the warning text.
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    try pushWarn(testing.allocator, &diags, .unexpected_token, 0, 5);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const span = formatDiagnostics(
        testing.allocator,
        &buf,
        &diags,
        "SyntaxError: failed to parse",
    );

    try testing.expectEqualStrings(
        "SyntaxError: failed to parse",
        buf.items,
    );
    try testing.expectEqual(@as(u32, 0), span.start);
}
