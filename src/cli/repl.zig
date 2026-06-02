//! `cynic repl` — interactive read-eval-print loop. Persistent
//! realm across lines so `let x = 1` followed by `x + 1` evaluates
//! to `2`. Pure host-loop wiring; the engine pipeline is the same
//! `evaluateScript` + `drainMicrotasks` shape `cynic run` uses.
//!
//! Each input line is treated as a full script (not just an
//! expression — this is what V8's `d8` REPL and SpiderMonkey's
//! `js` shell do). After evaluation, the result of the script's
//! final expression statement is printed when it's not
//! `undefined`; assignments and declarations print nothing.
//! Microtasks drain between lines so a `Promise.resolve(v).then(cb)`
//! at line N runs `cb` before the line N+1 prompt.
//!
//! Errors don't kill the REPL — a parse error, a compile error,
//! or an uncaught throw is reported and the next prompt fires.
//! End-of-stream (Ctrl-D on a fresh prompt) and the `.exit` /
//! `.quit` meta-commands both terminate cleanly.

const std = @import("std");
const cynic = @import("cynic");

const Realm = cynic.runtime.Realm;
const Value = cynic.runtime.Value;
const JSString = cynic.runtime.JSString;
const FeatureSet = cynic.runtime.FeatureSet;
const heap_mod = cynic.runtime.heap;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    feature_flags: FeatureSet,
    gc_threshold: ?u32,
    debug_globals: bool,
    unhardened: bool,
    allow_eval: bool,
) !void {
    var realm = Realm.init(allocator);
    defer realm.deinit();
    realm.feature_flags = feature_flags;
    // `--unhardened` — drop the SES posture (frozen primordials,
    // override-mistake fix) atomically. Must be set BEFORE
    // `installBuiltins` so the Phase 1 freeze pass at the tail
    // of intrinsic install sees the relaxed flag. Mirrors
    // `cli/run.zig` and `cli/eval.zig`.
    if (unhardened) realm.hardened = false;
    // `--allow=eval` — open the runtime-code-construction gate. See
    // `Realm.allow_eval`.
    if (allow_eval) realm.allow_eval = true;
    if (gc_threshold) |n| realm.heap.setGcThreshold(n);
    try realm.installBuiltins();
    // REPL is a debug / exploration context — install the debug
    // hooks so users can call `__collectGarbage()` etc. interactively
    // when --debug-globals is set. Default off keeps the REPL's
    // realm production-shaped (same policy as `cynic run`).
    if (debug_globals) try realm.installTestGlobals();

    // Session-lifetime source arena. The compiled chunk produced
    // by `compileScriptAsChunk` is owned by the realm (via
    // `realm.script_chunks`) and outlives the line that produced
    // it, and **identifier spans in that chunk borrow the source
    // bytes directly** — they're not copied into the constant
    // pool. So line N's `let x = …` keeps a binding called `x`
    // whose name slice points into line N's source buffer; if
    // we freed that buffer at line N+1 it would dangle, and a
    // later `x` read would resolve through corrupt key bytes.
    // We grow monotonically here — RSS is bounded by the total
    // bytes the user types in one session, which is plenty for
    // an interactive shell. A really long session is a feature,
    // not a leak; nothing prevents `.exit` and restart.
    var source_arena: std.heap.ArenaAllocator = .init(allocator);
    defer source_arena.deinit();

    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    try stdout.writeStreamingAll(io, "Cynic REPL. Type .exit / .quit or press Ctrl-D to leave.\n");

    // Stdin reader — `takeDelimiter('\n')` returns the line minus
    // the newline, or `null` on EOF. Buffer sized to hold a typical
    // pasted snippet; multi-kilobyte expressions overflow and are
    // reported as `StreamTooLong`.
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &read_buf);

    while (true) {
        try stdout.writeStreamingAll(io, "> ");

        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stderr.writeStreamingAll(io, "error: input exceeded REPL line buffer (16 KiB). Save to a file and use `cynic run`.\n");
                continue;
            },
            error.ReadFailed => return err,
        } orelse {
            // EOF — clean exit. Match `d8` / `js` convention: a
            // newline on the way out so the next shell prompt
            // doesn't land on the same line as our final `> `.
            try stdout.writeStreamingAll(io, "\n");
            return;
        };

        // Meta-commands. Trim trailing CR for terminals that send
        // CRLF; otherwise `.exit` typed on Windows wouldn't match.
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.eql(u8, trimmed, ".exit") or std.mem.eql(u8, trimmed, ".quit")) return;
        if (trimmed.len == 0) continue;

        // Copy into the session-lifetime source arena. See the
        // arena's introductory comment for why we can't reset
        // between lines — every chunk pinned in the realm holds
        // identifier-name slices that point into this buffer.
        const src = try source_arena.allocator().dupe(u8, trimmed);

        const outcome = cynic.runtime.evaluateScript(allocator, &realm, src) catch |err| {
            var line_buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&line_buf, "{t}\n", .{err});
            try stderr.writeStreamingAll(io, msg);
            continue;
        };

        // Microtask drain at job boundary — `Promise.resolve(v).then(cb)`
        // at line N runs `cb` before the line N+1 prompt. Mirrors
        // `cynic run`'s drain at the end of each script.
        cynic.runtime.lantern.drainMicrotasks(allocator, &realm) catch {};

        // Flush any `print` / `console.log` buffered during the
        // line's evaluation, then clear so line N+1's output starts
        // fresh.
        if (realm.output.items.len > 0) {
            try stdout.writeStreamingAll(io, realm.output.items);
            realm.output.clearRetainingCapacity();
        }

        switch (outcome) {
            .value, .yielded => |v| {
                // Suppress `undefined` results — same convention
                // as `d8` / `js`: a declaration / assignment /
                // statement that returns `undefined` is treated
                // as silent. Concrete values print.
                if (!v.isUndefined()) try printValue(io, v);
            },
            .thrown => |v| {
                try stderr.writeStreamingAll(io, "Uncaught: ");
                try printValueToStream(io, stderr, v);
                try stderr.writeStreamingAll(io, "\n");
            },
        }
    }
}

fn printValue(io: std.Io, v: Value) !void {
    try printValueToStream(io, std.Io.File.stdout(), v);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn printValueToStream(io: std.Io, out: std.Io.File, v: Value) !void {
    var buf: [512]u8 = undefined;
    if (v.isInt32()) {
        const m = try std.fmt.bufPrint(&buf, "{d}", .{v.asInt32()});
        try out.writeStreamingAll(io, m);
    } else if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) {
            try out.writeStreamingAll(io, "NaN");
        } else if (std.math.isInf(d)) {
            try out.writeStreamingAll(io, if (d > 0) "Infinity" else "-Infinity");
        } else {
            const m = try std.fmt.bufPrint(&buf, "{d}", .{d});
            try out.writeStreamingAll(io, m);
        }
    } else if (v.isBool()) {
        try out.writeStreamingAll(io, if (v.asBool()) "true" else "false");
    } else if (v.isNull()) {
        try out.writeStreamingAll(io, "null");
    } else if (v.isUndefined()) {
        try out.writeStreamingAll(io, "undefined");
    } else if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        try out.writeStreamingAll(io, s.flatBytes());
    } else if (heap_mod.valueAsPlainObject(v)) |obj| {
        // Errors get a `Name: message`-style render — without it
        // an uncaught `ReferenceError: x is not defined` shows up
        // as `Uncaught: [object]` in the REPL, which is useless
        // for the very case (debugging) the REPL exists to serve.
        // We pull `name` through the prototype chain (it's set on
        // each error subtype's prototype: `Error.prototype.name
        // === "Error"`, `RangeError.prototype.name === "RangeError"`,
        // etc.) and `message` from the instance's own props (the
        // §20.5.7.1.1 init writes it there). No `@@toPrimitive` /
        // user-`toString` invocation — we can't safely re-enter
        // the engine to display a thrown value (it might throw
        // again, and we'd lose the original).
        if (obj.has_error_data) {
            const name_str = lookupChain(obj, "name");
            try out.writeStreamingAll(io, if (name_str.len > 0) name_str else "Error");
            if (obj.lookupOwn("message")) |msg_v| {
                if (msg_v.isString()) {
                    const ms: *JSString = @ptrCast(@alignCast(msg_v.asString()));
                    const bytes = ms.flatBytes();
                    if (bytes.len > 0) {
                        try out.writeStreamingAll(io, ": ");
                        try out.writeStreamingAll(io, bytes);
                    }
                }
            }
        } else {
            try out.writeStreamingAll(io, "[object Object]");
        }
    } else {
        // Symbols, functions, BigInts — punt for now, the
        // REPL's value-display ergonomics aren't worth a full
        // ToString round-trip yet.
        try out.writeStreamingAll(io, "[object]");
    }
}

/// Walk the prototype chain looking for `key` and return its
/// string value if found (and a string). Returns an empty slice
/// otherwise. Used by the error-display path to read `name`,
/// which lives on `<Sub>Error.prototype` rather than the instance.
/// Takes `anytype` because `JSObject` isn't re-exported from the
/// cynic root module — the parameter is always a `*JSObject` at
/// the only call site, and Zig infers the field/method names.
///
/// Under the SES posture (default) `<Sub>Error.prototype.name` is
/// not a data property — Phase 3's override-mistake fix demoted
/// it to a synthetic accessor pair on the prototype. The getter
/// is a `JSFunction` whose `synth_accessor.value` holds the
/// captured "TypeError" / "RangeError" / etc. string. We check
/// the captured value directly instead of invoking the getter
/// (no re-entry into the engine to display an already-thrown
/// value).
fn lookupChain(start: anytype, key: []const u8) []const u8 {
    var cur = @as(?@TypeOf(start), start);
    while (cur) |o| : (cur = o.prototype) {
        if (o.lookupOwn(key)) |v| {
            if (v.isString()) {
                const s: *JSString = @ptrCast(@alignCast(v.asString()));
                return s.flatBytes();
            }
        }
        if (o.getAccessor(key)) |acc| {
            if (acc.getter) |g| {
                if (g.synth_accessor) |cell| {
                    if (cell.value.isString()) {
                        const s: *JSString = @ptrCast(@alignCast(cell.value.asString()));
                        return s.flatBytes();
                    }
                }
            }
        }
    }
    return "";
}
