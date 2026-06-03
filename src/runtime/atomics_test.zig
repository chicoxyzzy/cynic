//! §25.4 Atomics — single-agent coverage.
//!
//! On a single agent the read-modify-write / load / store /
//! compareExchange / isLockFree operations are ordinary sequential
//! operations on the backing store; `notify` always returns 0 (no
//! other agent waits) and `wait` returns `"not-equal"` / `"timed-out"`.
//! Cross-agent behaviour (`$262.agent`) is out of scope here.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const Value = @import("value.zig").Value;

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

// ── object / metadata ───────────────────────────────────────────────

test "Atomics: installed as a namespace object" {
    try expectTrue("typeof Atomics === 'object' && Atomics !== null ? 1 : 0");
}

test "Atomics: @@toStringTag" {
    try expectTrue("Atomics[Symbol.toStringTag] === 'Atomics' ? 1 : 0");
    try expectTrue("Object.prototype.toString.call(Atomics) === '[object Atomics]' ? 1 : 0");
}

test "Atomics: isLockFree" {
    try expectTrue("Atomics.isLockFree(1) && Atomics.isLockFree(2) && Atomics.isLockFree(4) ? 1 : 0");
    try expectTrue("Atomics.isLockFree(8) ? 1 : 0");
    try expectTrue("!Atomics.isLockFree(3) && !Atomics.isLockFree(0) ? 1 : 0");
}

// ── read-modify-write ───────────────────────────────────────────────

test "Atomics.add returns the old value and stores the sum" {
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(8));
        \\(Atomics.add(ta, 0, 5) === 0) && (ta[0] === 5) &&
        \\(Atomics.add(ta, 0, 3) === 5) && (ta[0] === 8) ? 1 : 0;
    );
}

test "Atomics.sub/and/or/xor" {
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(4));
        \\ta[0] = 12;
        \\(Atomics.sub(ta, 0, 4) === 12) && (ta[0] === 8) &&
        \\(Atomics.and(ta, 0, 12) === 8) && (ta[0] === 8) &&
        \\(Atomics.or(ta, 0, 1) === 8) && (ta[0] === 9) &&
        \\(Atomics.xor(ta, 0, 9) === 9) && (ta[0] === 0) ? 1 : 0;
    );
}

test "Atomics.exchange" {
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(4));
        \\ta[0] = 7;
        \\(Atomics.exchange(ta, 0, 42) === 7) && (ta[0] === 42) ? 1 : 0;
    );
}

test "Atomics.compareExchange" {
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(4));
        \\ta[0] = 8;
        \\// matching expected -> replaces, returns old
        \\var a = Atomics.compareExchange(ta, 0, 8, 99);
        \\// non-matching expected -> unchanged, returns current
        \\var b = Atomics.compareExchange(ta, 0, 5, 123);
        \\(a === 8) && (b === 99) && (ta[0] === 99) ? 1 : 0;
    );
}

test "Atomics.load / store" {
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(8));
        \\(Atomics.store(ta, 1, 42) === 42) && (Atomics.load(ta, 1) === 42) ? 1 : 0;
    );
}

test "Atomics works on a non-shared integer TypedArray" {
    try expectTrue(
        \\var ta = new Int32Array(4);
        \\(Atomics.add(ta, 0, 1) === 0) && (ta[0] === 1) ? 1 : 0;
    );
}

test "Atomics on a BigInt64Array" {
    try expectTrue(
        \\var ta = new BigInt64Array(new SharedArrayBuffer(8));
        \\(Atomics.add(ta, 0, 5n) === 0n) && (ta[0] === 5n) &&
        \\(Atomics.compareExchange(ta, 0, 5n, 9n) === 5n) && (ta[0] === 9n) ? 1 : 0;
    );
}

// ── validation ──────────────────────────────────────────────────────

test "Atomics on a Float array throws TypeError" {
    try expectTrue(
        \\var c='none'; try { Atomics.add(new Float64Array(2), 0, 1); } catch(e){ c=e.constructor.name; }
        \\c === 'TypeError' ? 1 : 0;
    );
}

test "Atomics on a Uint8ClampedArray throws TypeError" {
    try expectTrue(
        \\var c='none'; try { Atomics.add(new Uint8ClampedArray(2), 0, 1); } catch(e){ c=e.constructor.name; }
        \\c === 'TypeError' ? 1 : 0;
    );
}

test "Atomics out-of-range index throws RangeError" {
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(8));
        \\var c='none'; try { Atomics.add(ta, 99, 1); } catch(e){ c=e.constructor.name; }
        \\c === 'RangeError' ? 1 : 0;
    );
}

// ── wait / notify ───────────────────────────────────────────────────

test "Atomics.notify returns 0 (no waiters, single agent)" {
    try expectInt("Atomics.notify(new Int32Array(new SharedArrayBuffer(8)), 0, 1)", 0);
    // notify on a non-shared buffer returns 0 (does not throw).
    try expectInt("Atomics.notify(new Int32Array(8), 0, 1)", 0);
}

test "Atomics.wait requires a shared buffer (TypeError on non-shared)" {
    try expectTrue(
        \\var c='none'; try { Atomics.wait(new Int32Array(8), 0, 0); } catch(e){ c=e.constructor.name; }
        \\c === 'TypeError' ? 1 : 0;
    );
}

test "Atomics.wait returns 'not-equal' when the value differs" {
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(8));
        \\Atomics.wait(ta, 0, 123) === 'not-equal' ? 1 : 0;
    );
}

test "Atomics.wait returns 'timed-out' on a zero timeout with matching value" {
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(8));
        \\Atomics.wait(ta, 0, 0, 0) === 'timed-out' ? 1 : 0;
    );
}
