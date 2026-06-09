//! Fuzzilli host hook — `fuzzilli(op, arg)`. Installed by
//! `Realm.installTestGlobals`; reachable only from a debug-enabled
//! realm (production `cynic` CLI never installs it). The REPRL
//! protocol loop that drives this from Fuzzilli's parent lives in
//! `tools/fuzz/fuzz_reprl.zig` — kept outside `src/` so the runtime
//! library and the production `cynic` binary carry no fuzzing code.
//!
//! Two ops, both tracking Fuzzilli's convention so the upstream
//! profile's `additionalCode` stays portable across engines:
//!   - `"FUZZILLI_CRASH"` — abort the process. Lets Fuzzilli verify
//!     it actually detects crashes (regression-guard against a
//!     broken harness silently masking real bugs).
//!   - `"FUZZILLI_PRINT"` — stringify `arg` and write a line to
//!     `DWFD` (Fuzzilli's differential output sink). Silently
//!     no-op when `DWFD` isn't open (running outside REPRL).

const std = @import("std");
const builtin = @import("builtin");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const NativeError = @import("../function.zig").NativeError;

/// Fuzzilli REPRL is POSIX-only — it speaks over inherited fds via
/// libc. On `freestanding` / `wasm` there are no file descriptors
/// (`std.posix.fd_t` is `void`, `std.c.write` is unavailable), so the
/// host's I/O compiles out there (see `writeAll`). The playground's
/// `wasm32-freestanding` build reaches this module through
/// `installTestGlobals`, so it MUST compile on that target.
const fuzzilli_host = builtin.target.os.tag != .freestanding and builtin.target.os.tag != .wasi;

/// Fuzzilli's differential output sink (data-write fd). Engine
/// writes `FUZZILLI_PRINT` output here; Fuzzilli reads it for
/// differential comparison. Must stay in sync with `tools/fuzz/fuzz_reprl.zig`'s
/// fd constants — the REPRL protocol mandates the exact numbers. Typed
/// as `i32` (== `std.posix.fd_t` on POSIX) so the declaration is valid
/// on `freestanding`, where `fd_t` is `void`.
pub const DWFD: i32 = 103;

pub fn fuzzilliNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    if (args.len < 1 or !args[0].isString()) return Value.undefined_;
    const op_str: *JSString = @ptrCast(@alignCast(args[0].asString()));
    const op = op_str.flatBytes();

    if (std.mem.eql(u8, op, "FUZZILLI_CRASH")) {
        // Any crash code triggers an immediate abort — Fuzzilli's
        // protocol cares only that the parent observes a crash. The
        // per-code flavors (null deref, assert fail, …) are a later
        // refinement. `@panic` is the right path: Debug emits a
        // stack trace, ReleaseSafe catches it cleanly.
        @panic("FUZZILLI_CRASH");
    } else if (std.mem.eql(u8, op, "FUZZILLI_PRINT")) {
        var stack_buf: [256]u8 = undefined;
        const rendered: []const u8 = if (args.len >= 2)
            renderValue(&stack_buf, args[1])
        else
            "";
        writeAll(DWFD, rendered) catch {};
        writeAll(DWFD, "\n") catch {};
    }
    return Value.undefined_;
}

fn renderValue(buf: []u8, v: Value) []const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        const bytes = s.flatBytes();
        const n = @min(buf.len, bytes.len);
        @memcpy(buf[0..n], bytes[0..n]);
        return buf[0..n];
    }
    if (v.isInt32()) {
        return std.fmt.bufPrint(buf, "{d}", .{v.asInt32()}) catch buf[0..0];
    }
    if (v.isDouble()) {
        return std.fmt.bufPrint(buf, "{d}", .{v.asDouble()}) catch buf[0..0];
    }
    if (v.isBool()) return if (v.asBool()) "true" else "false";
    if (v.isNull()) return "null";
    if (v.isUndefined()) return "undefined";
    return "[object]";
}

fn writeAll(fd: i32, buf: []const u8) !void {
    // `std.posix.write` is gone in 0.17-dev; `std.c.write` is the
    // stable path on libc-linked builds. A -1 / 0 return means the
    // sink is closed — for FUZZILLI_PRINT that's the "running
    // outside REPRL" case, which the caller swallows. POSIX-only: the
    // libc body is comptime-excluded on `freestanding` / `wasm`, where
    // there is no `std.c.write` and `FUZZILLI_PRINT` is never driven.
    if (comptime fuzzilli_host) {
        var written: usize = 0;
        while (written < buf.len) {
            const n = std.c.write(fd, buf[written..].ptr, buf.len - written);
            if (n <= 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }
}
