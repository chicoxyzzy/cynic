//! §25.2 SharedArrayBuffer — single-agent coverage.
//!
//! Cynic is single-agent-per-isolate, so a SharedArrayBuffer is an
//! ArrayBuffer that is never detachable and grow-only (`grow`, not
//! `resize`). These tests pin the constructor + prototype surface and
//! the cross-guards: `ArrayBuffer.prototype.*` rejects a shared
//! receiver (§25.1.5.x "If IsSharedArrayBuffer(O) throw TypeError"),
//! and TypedArray / DataView accept a shared-backed buffer.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const Value = @import("value.zig").Value;

/// Evaluate `source` as a script and return the completion value; a
/// thrown completion surfaces as a Zig error so a value assertion
/// never silently passes on a throw.
fn run(source: []const u8) !Value {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => error.ScriptThrewUnexpectedly,
    };
}

/// Assert the script's completion is the int32 `want`. Test sources
/// end in a `… ? 1 : 0`-style boolean-to-int probe so each is a single
/// expectation.
fn expectInt(source: []const u8, want: i32) !void {
    const v = try run(source);
    if (!v.isInt32()) {
        std.debug.print("expected int32 {d}, got non-int completion\n", .{want});
        return error.ResultNotInt;
    }
    try testing.expectEqual(want, v.asInt32());
}

fn expectTrue(source: []const u8) !void {
    try expectInt(source, 1);
}

// ── constructor / global ────────────────────────────────────────────

test "SharedArrayBuffer: installed as a callable global" {
    try expectTrue("typeof SharedArrayBuffer === 'function' ? 1 : 0");
}

test "SharedArrayBuffer: byteLength" {
    try expectInt("new SharedArrayBuffer(8).byteLength", 8);
    try expectInt("new SharedArrayBuffer(0).byteLength", 0);
}

test "SharedArrayBuffer: requires new" {
    try expectTrue(
        "var c='none'; try { SharedArrayBuffer(8); } catch(e){ c=e.constructor.name; } c==='TypeError' ? 1 : 0",
    );
}

test "SharedArrayBuffer: @@toStringTag" {
    try expectTrue("SharedArrayBuffer.prototype[Symbol.toStringTag] === 'SharedArrayBuffer' ? 1 : 0");
    try expectTrue("Object.prototype.toString.call(new SharedArrayBuffer(1)) === '[object SharedArrayBuffer]' ? 1 : 0");
}

test "SharedArrayBuffer: @@species is the constructor" {
    try expectTrue("SharedArrayBuffer[Symbol.species] === SharedArrayBuffer ? 1 : 0");
}

// ── growable / grow ─────────────────────────────────────────────────

test "SharedArrayBuffer: growable flag" {
    try expectTrue("new SharedArrayBuffer(4, { maxByteLength: 8 }).growable === true ? 1 : 0");
    try expectTrue("new SharedArrayBuffer(4).growable === false ? 1 : 0");
}

test "SharedArrayBuffer: maxByteLength" {
    try expectInt("new SharedArrayBuffer(4, { maxByteLength: 8 }).maxByteLength", 8);
    // Non-growable → maxByteLength equals byteLength.
    try expectInt("new SharedArrayBuffer(4).maxByteLength", 4);
}

test "SharedArrayBuffer: grow extends byteLength" {
    try expectInt(
        \\var sab = new SharedArrayBuffer(4, { maxByteLength: 8 });
        \\sab.grow(8);
        \\sab.byteLength;
    , 8);
}

test "SharedArrayBuffer: grow is grow-only (shrink throws RangeError)" {
    try expectTrue(
        \\var sab = new SharedArrayBuffer(4, { maxByteLength: 8 });
        \\var c='none'; try { sab.grow(2); } catch(e){ c=e.constructor.name; }
        \\c === 'RangeError' ? 1 : 0;
    );
}

test "SharedArrayBuffer: grow beyond max throws RangeError" {
    try expectTrue(
        \\var sab = new SharedArrayBuffer(4, { maxByteLength: 8 });
        \\var c='none'; try { sab.grow(16); } catch(e){ c=e.constructor.name; }
        \\c === 'RangeError' ? 1 : 0;
    );
}

// ── slice ───────────────────────────────────────────────────────────

test "SharedArrayBuffer: slice returns a SharedArrayBuffer" {
    try expectInt("new SharedArrayBuffer(8).slice(0, 4).byteLength", 4);
    try expectTrue("(new SharedArrayBuffer(8).slice(0, 4) instanceof SharedArrayBuffer) ? 1 : 0");
}

// ── never detachable ────────────────────────────────────────────────

test "SharedArrayBuffer: no detach/transfer/resize surface" {
    try expectTrue("(SharedArrayBuffer.prototype.transfer === undefined) ? 1 : 0");
    try expectTrue("(SharedArrayBuffer.prototype.resize === undefined) ? 1 : 0");
    try expectTrue("!('detached' in SharedArrayBuffer.prototype) ? 1 : 0");
}

// ── cross-guards: ArrayBuffer.prototype rejects a shared receiver ────

test "ArrayBuffer.prototype.byteLength rejects a SharedArrayBuffer" {
    // §25.1.5.1 step 3 — "If IsSharedArrayBuffer(O) is true, throw a
    // TypeError exception."
    try expectTrue(
        \\var d = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, 'byteLength').get;
        \\var c='none'; try { d.call(new SharedArrayBuffer(8)); } catch(e){ c=e.constructor.name; }
        \\c === 'TypeError' ? 1 : 0;
    );
}

test "ArrayBuffer.prototype.slice rejects a SharedArrayBuffer" {
    try expectTrue(
        \\var c='none'; try { ArrayBuffer.prototype.slice.call(new SharedArrayBuffer(8), 0, 4); }
        \\catch(e){ c=e.constructor.name; }
        \\c === 'TypeError' ? 1 : 0;
    );
}

// ── views accept a shared-backed buffer ─────────────────────────────

test "TypedArray over a SharedArrayBuffer" {
    try expectInt("new Int32Array(new SharedArrayBuffer(8)).length", 2);
    try expectTrue("(new Uint8Array(new SharedArrayBuffer(4)).buffer instanceof SharedArrayBuffer) ? 1 : 0");
}

test "DataView over a SharedArrayBuffer" {
    try expectInt(
        \\var dv = new DataView(new SharedArrayBuffer(8));
        \\dv.setInt32(0, 1234);
        \\dv.getInt32(0);
    , 1234);
}

test "ArrayBuffer.isView true for a shared-backed TypedArray" {
    try expectTrue("ArrayBuffer.isView(new Int32Array(new SharedArrayBuffer(8))) ? 1 : 0");
}
