//! Regressions identified by the pinned WPT WebAssembly JS API corpus.
//! AddressValueToU64 (i32) uses Web IDL [EnforceRange] unsigned long.
//! Current AddressValue dictionary members are `any`: collect the dictionary
//! before the constructor converts its initial/maximum numeric values.

const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectTrue(source: []const u8) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    // Bounds allocations even if a regression accepts a huge address value.
    realm.setMemoryLimit(realm.heap.bytes_live + 16 * 1024 * 1024);
    const outcome = try lantern.evaluateScript(std.testing.allocator, &realm, source);
    const result = switch (outcome) {
        .value => |v| v,
        .yielded => return error.UnexpectedYield,
        .thrown => return error.UnexpectedThrow,
    };
    try std.testing.expect(result.isBool() and result.asBool());
}

const throws_helper =
    \\function throwsType(f, type) { try { f(); } catch (e) { return e instanceof type; } return false; }
;

test "WPT Memory: constructor enforces unsigned address conversion" {
    try expectTrue(throws_helper ++
        \\const invalid = [NaN, Infinity, -Infinity, -1, 4294967296, 68719476736, Symbol(), 0n];
        \\let ok = true;
        \\for (const value of invalid) {
        \\  ok = throwsType(() => new WebAssembly.Memory({ initial: value }), TypeError) && ok;
        \\  ok = throwsType(() => new WebAssembly.Memory({ initial: 0, maximum: value }), TypeError) && ok;
        \\}
        \\const memory = new WebAssembly.Memory({ initial: -0.5, maximum: 1.9 });
        \\ok && memory.buffer.byteLength === 0 && memory.grow(1.9) === 0 && memory.buffer.byteLength === 65536;
    );
}

test "WPT Memory: memory32 limits reject invalid maximum before allocation" {
    try expectTrue(throws_helper ++
        \\throwsType(() => new WebAssembly.Memory({ initial: 0, maximum: 65537 }), RangeError) &&
        \\throwsType(() => new WebAssembly.Memory({ initial: 0, maximum: 4294967295 }), RangeError) &&
        \\new WebAssembly.Memory({ initial: 0, maximum: 65536 }).buffer.byteLength === 0;
    );
}

test "WPT Memory: grow requires an argument and enforces unsigned conversion" {
    try expectTrue(throws_helper ++
        \\const memory = new WebAssembly.Memory({ initial: 0, maximum: 2 });
        \\const invalid = [undefined, NaN, Infinity, -Infinity, -1, 4294967296, Symbol(), 0n];
        \\let ok = throwsType(() => memory.grow(), TypeError);
        \\for (const value of invalid) ok = throwsType(() => memory.grow(value), TypeError) && ok;
        \\ok && memory.grow(-0.5) === 0 && memory.grow("1.9") === 0 && memory.buffer.byteLength === 65536;
    );
}

test "WPT Memory: descriptor getters precede numeric coercion" {
    try expectTrue(
        \\const calls = [];
        \\const descriptor = {
        \\  get initial() { calls.push("initial"); return { valueOf() { calls.push("initial number"); return 0; } }; },
        \\  get maximum() { calls.push("maximum"); return { valueOf() { calls.push("maximum number"); return 1; } }; }
        \\};
        \\const memory = new WebAssembly.Memory(descriptor);
        \\calls.join(",") === "initial,maximum,initial number,maximum number" && memory.buffer.byteLength === 0;
    );
}

test "WPT Memory: callable and proxy descriptors use ordinary Get" {
    try expectTrue(
        \\function descriptor() {}
        \\Object.defineProperty(descriptor, "initial", { get() { return 0; } });
        \\const first = new WebAssembly.Memory(descriptor);
        \\const second = new WebAssembly.Memory(new Proxy({}, {
        \\  has() { throw new Error("unexpected HasProperty"); },
        \\  get(target, key) { return key === "initial" ? 0 : undefined; }
        \\}));
        \\first.buffer.byteLength === 0 && second.buffer.byteLength === 0;
    );
}

test "WPT Memory: grow coercion runs once and observes reentrant growth" {
    try expectTrue(
        \\const memory = new WebAssembly.Memory({ initial: 0, maximum: 3 });
        \\let calls = 0;
        \\const previous = memory.grow({ valueOf() { calls++; memory.grow(1); return 1; } });
        \\const sentinel = {};
        \\let preserved = false;
        \\try { memory.grow({ valueOf() { throw sentinel; } }); } catch (e) { preserved = e === sentinel; }
        \\calls === 1 && previous === 1 && memory.buffer.byteLength === 131072 && preserved;
    );
}

test "WPT Table: constructor enforces unsigned address conversion" {
    try expectTrue(throws_helper ++
        \\const invalid = [NaN, Infinity, -Infinity, -1, 4294967296, 68719476736, Symbol(), 0n];
        \\let ok = true;
        \\for (const value of invalid) {
        \\  ok = throwsType(() => new WebAssembly.Table({ element: "externref", initial: value }), TypeError) && ok;
        \\  ok = throwsType(() => new WebAssembly.Table({ element: "externref", initial: 0, maximum: value }), TypeError) && ok;
        \\}
        \\const table = new WebAssembly.Table({ element: "externref", initial: -0.5, maximum: 4294967295.9 });
        \\ok && table.length === 0 && table.grow(1.9) === 0 && table.length === 1;
    );
}

test "WPT Table: get and set distinguish conversion from bounds errors" {
    try expectTrue(throws_helper ++
        \\const table = new WebAssembly.Table({ element: "externref", initial: 1 });
        \\const invalid = [undefined, NaN, Infinity, -Infinity, -1, 4294967296, Symbol(), 0n];
        \\let ok = throwsType(() => table.get(), TypeError) && throwsType(() => table.set(), TypeError);
        \\for (const value of invalid) {
        \\  ok = throwsType(() => table.get(value), TypeError) && ok;
        \\  ok = throwsType(() => table.set(value, 7), TypeError) && ok;
        \\}
        \\table.set({ valueOf() { return -0.5; } }, 7);
        \\ok && table.get({ valueOf() { return 0; } }) === 7 &&
        \\throwsType(() => table.get(4294967295), RangeError) &&
        \\throwsType(() => table.set(1, 7), RangeError);
    );
}

test "WPT Table: set converts index and value before checking bounds" {
    try expectTrue(throws_helper ++
        \\const table = new WebAssembly.Table({ element: "anyfunc", initial: 0 });
        \\let conversions = 0;
        \\const badValue = throwsType(() => table.set({ valueOf() { conversions++; return 1; } }, {}), TypeError);
        \\const outOfBounds = throwsType(() => table.set(1, null), RangeError);
        \\const sentinel = {};
        \\let preserved = false;
        \\try { table.set({ valueOf() { throw sentinel; } }, {}); } catch (e) { preserved = e === sentinel; }
        \\badValue && conversions === 1 && outOfBounds && preserved;
    );
}

test "WPT Table: descriptor getters and element conversion precede numeric coercion" {
    try expectTrue(
        \\const calls = [];
        \\const descriptor = {
        \\  get element() { calls.push("element"); return { toString() { calls.push("element string"); return "externref"; } }; },
        \\  get initial() { calls.push("initial"); return { valueOf() { calls.push("initial number"); return 0; } }; },
        \\  get maximum() { calls.push("maximum"); return { valueOf() { calls.push("maximum number"); return 1; } }; }
        \\};
        \\const table = new WebAssembly.Table(new Proxy(descriptor, {
        \\  has() { throw new Error("unexpected HasProperty"); },
        \\  get(target, key) { return target[key]; }
        \\}));
        \\calls.join(",") === "element,element string,initial,maximum,initial number,maximum number" && table.length === 0;
    );
}

test "WPT Table: omitted externref values default to undefined" {
    try expectTrue(
        \\const table = new WebAssembly.Table({ element: "externref", initial: 1, maximum: 2 });
        \\let ok = table.get(0) === undefined;
        \\table.set(0, null);
        \\ok = table.get(0) === null && ok;
        \\table.set(0);
        \\ok = table.get(0) === undefined && ok;
        \\table.grow(1);
        \\const funcs = new WebAssembly.Table({ element: "anyfunc", initial: 1 });
        \\ok && table.get(1) === undefined && funcs.get(0) === null;
    );
}

test "WPT Table: grow requires an argument and enforces unsigned conversion" {
    try expectTrue(throws_helper ++
        \\const table = new WebAssembly.Table({ element: "externref", initial: 0, maximum: 2 });
        \\const invalid = [undefined, NaN, Infinity, -Infinity, -1, 4294967296, Symbol(), 0n];
        \\let ok = throwsType(() => table.grow(), TypeError);
        \\for (const value of invalid) ok = throwsType(() => table.grow(value), TypeError) && ok;
        \\ok && table.grow(-0.5) === 0 && table.grow("1.9") === 0 && table.length === 1;
    );
}

test "WPT Table: grow returns size captured before reentrant coercion" {
    try expectTrue(
        \\const table = new WebAssembly.Table({ element: "externref", initial: 0, maximum: 3 });
        \\let calls = 0;
        \\const marker = {};
        \\const previous = table.grow({ valueOf() { calls++; table.grow(1, 17); return 1; } }, marker);
        \\calls === 1 && previous === 0 && table.length === 2 && table.get(0) === 17 && table.get(1) === marker;
    );
}

test "WPT Table: bounded allocation failure is a catchable RangeError" {
    try expectTrue(throws_helper ++
        \\const table = new WebAssembly.Table({ element: "externref", initial: 0 });
        \\throwsType(() => table.grow(4294967295), RangeError) && table.length === 0;
    );
}

test "WPT Table: element enum accepts computed strings and rejects funcref spelling" {
    try expectTrue(throws_helper ++
        \\const prefix = "extern";
        \\const table = new WebAssembly.Table({ element: { toString() { return prefix + "ref"; } }, initial: 0 });
        \\table.length === 0 && throwsType(() => new WebAssembly.Table({ element: "funcref", initial: 0 }), TypeError);
    );
}
