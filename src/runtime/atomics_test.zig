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

// ── element-width dispatch ──────────────────────────────────────────

test "Atomics.add wraps at the element width (Int8Array)" {
    // 127 +% 1 → -128 (two's-complement 8-bit wrap); old returned.
    try expectTrue(
        \\var ta = new Int8Array(new SharedArrayBuffer(4));
        \\ta[0] = 127;
        \\(Atomics.add(ta, 0, 1) === 127) && (ta[0] === -128) ? 1 : 0;
    );
}

test "Atomics on Uint16Array (load/store/and)" {
    try expectTrue(
        \\var ta = new Uint16Array(new SharedArrayBuffer(8));
        \\(Atomics.store(ta, 1, 0xBEEF) === 0xBEEF) &&
        \\(Atomics.load(ta, 1) === 0xBEEF) &&
        \\(Atomics.and(ta, 1, 0x0FF0) === 0xBEEF) && (ta[1] === 0x0EE0) ? 1 : 0;
    );
}

test "Atomics.compareExchange on Uint32Array with a high-bit value" {
    // 0x80000000 round-trips as an unsigned Uint32 element.
    try expectTrue(
        \\var ta = new Uint32Array(new SharedArrayBuffer(4));
        \\ta[0] = 0x80000000;
        \\(Atomics.compareExchange(ta, 0, 0x80000000, 1) === 0x80000000) && (ta[0] === 1) ? 1 : 0;
    );
}

test "Atomics.exchange on a non-shared Uint8Array" {
    try expectTrue(
        \\var ta = new Uint8Array(4);
        \\ta[2] = 9;
        \\(Atomics.exchange(ta, 2, 250) === 9) && (ta[2] === 250) ? 1 : 0;
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

// ── Atomics.pause ───────────────────────────────────────────────────

test "Atomics.pause returns undefined" {
    try expectTrue("Atomics.pause() === undefined ? 1 : 0");
    try expectTrue("Atomics.pause(0) === undefined && Atomics.pause(42) === undefined ? 1 : 0");
}

test "Atomics.pause has name 'pause' and length 0" {
    try expectTrue("Atomics.pause.name === 'pause' && Atomics.pause.length === 0 ? 1 : 0");
}

test "Atomics.pause throws TypeError on a non-integral argument" {
    try expectTrue(
        "var c='none'; try { Atomics.pause(1.5); } catch(e){ c=e.constructor.name; } c==='TypeError' ? 1 : 0",
    );
}

// ── store -0 normalization ──────────────────────────────────────────

test "Atomics.store normalizes -0 to +0 in its return value" {
    // §25.4.13 — store returns ToIntegerOrInfinity(value); Object.is(-0,+0)
    // is false, so the return must be +0.
    try expectTrue(
        \\var ta = new Int32Array(new SharedArrayBuffer(8));
        \\Object.is(Atomics.store(ta, 0, -0), +0) ? 1 : 0;
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

// ── waitAsync ───────────────────────────────────────────────────────

test "Atomics.waitAsync is a function with name/length" {
    try expectTrue("typeof Atomics.waitAsync === 'function' && Atomics.waitAsync.name === 'waitAsync' && Atomics.waitAsync.length === 4 ? 1 : 0");
}

test "Atomics.waitAsync requires a shared buffer" {
    try expectTrue(
        \\var c='none'; try { Atomics.waitAsync(new Int32Array(8), 0, 0); } catch(e){ c=e.constructor.name; }
        \\c === 'TypeError' ? 1 : 0;
    );
}

test "Atomics.waitAsync returns {async:false, value:'not-equal'} on mismatch" {
    try expectTrue(
        \\var r = Atomics.waitAsync(new Int32Array(new SharedArrayBuffer(8)), 0, 123);
        \\r.async === false && r.value === 'not-equal' ? 1 : 0;
    );
}

test "Atomics.waitAsync returns {async:false, value:'timed-out'} on zero timeout" {
    try expectTrue(
        \\var r = Atomics.waitAsync(new Int32Array(new SharedArrayBuffer(8)), 0, 0, 0);
        \\r.async === false && r.value === 'timed-out' ? 1 : 0;
    );
}

test "Atomics.waitAsync returns {async:true, value:<promise>} when it would block" {
    try expectTrue(
        \\var r = Atomics.waitAsync(new Int32Array(new SharedArrayBuffer(8)), 0, 0);
        \\r.async === true && (r.value instanceof Promise) ? 1 : 0;
    );
}
