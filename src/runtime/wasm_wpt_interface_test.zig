//! WPT-derived WebAssembly JS API shape and immutable-exports regressions.
//! WebIDL §3.7 interface objects, attributes, and operations; Wasm JS API
//! §5 exports-object creation and §5.10 NativeError classes.
const std = @import("std");
const testing = std.testing;
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectWasm(source: []const u8, hardened: bool) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.hardened = hardened;
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    switch (outcome) {
        .value => |value| try testing.expect(value.isBool() and value.asBool()),
        else => return error.WasmThrewUnexpectedly,
    }
}

const adder_bytes =
    "new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11])";

const descriptor_helpers =
    \\function dataProperty(object, name, enumerable, length) {
    \\    const descriptor = Object.getOwnPropertyDescriptor(object, name);
    \\    return descriptor !== undefined && descriptor.writable === true &&
    \\        descriptor.enumerable === enumerable && descriptor.configurable === true &&
    \\        descriptor.value === object[name] &&
    \\        (length === undefined || (object[name].length === length && object[name].name === name));
    \\}
;

test "WPT interface: namespace interface constructors are nonenumerable" {
    try expectWasm(descriptor_helpers ++
        \\let correct = true;
        \\for (const name of ['Module', 'Instance', 'Memory', 'Table', 'Global', 'Tag', 'Exception', 'CompileError', 'LinkError', 'RuntimeError']) {
        \\    correct = correct && dataProperty(WebAssembly, name, false);
        \\}
        \\correct;
    , false);
}

test "WPT interface: namespace and static operations follow WebIDL descriptors" {
    try expectWasm(descriptor_helpers ++
        \\let correct = true;
        \\for (const name of ['validate', 'compile', 'instantiate']) {
        \\    correct = correct && dataProperty(WebAssembly, name, true, 1);
        \\}
        \\for (const [name, length] of [['exports', 1], ['imports', 1], ['customSections', 2]]) {
        \\    correct = correct && dataProperty(WebAssembly.Module, name, true, length);
        \\}
        \\correct;
    , false);
}

test "WPT interface: prototype operations are enumerable with required-argument arities" {
    try expectWasm(descriptor_helpers ++
        \\let correct = true;
        \\for (const [prototype, name, length] of [
        \\    [WebAssembly.Memory.prototype, 'grow', 1],
        \\    [WebAssembly.Table.prototype, 'get', 1],
        \\    [WebAssembly.Table.prototype, 'set', 1],
        \\    [WebAssembly.Table.prototype, 'grow', 1],
        \\    [WebAssembly.Exception.prototype, 'is', 1],
        \\    [WebAssembly.Exception.prototype, 'getArg', 2]
        \\]) {
        \\    correct = correct && dataProperty(prototype, name, true, length);
        \\}
        \\correct;
    , false);
}

test "WPT interface: memory and table attributes are enumerable accessors" {
    try expectWasm(
        \\let correct = true;
        \\for (const [prototype, name] of [[WebAssembly.Memory.prototype, 'buffer'], [WebAssembly.Table.prototype, 'length']]) {
        \\    const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
        \\    correct = correct && descriptor.enumerable && descriptor.configurable &&
        \\        typeof descriptor.get === 'function' && descriptor.get.length === 0 &&
        \\        descriptor.get.name === 'get ' + name && descriptor.set === undefined;
        \\}
        \\correct;
    , false);
}

test "WPT interface: Wasm NativeError constructors inherit from Error" {
    try expectWasm(
        \\let correct = true;
        \\for (const name of ['CompileError', 'LinkError', 'RuntimeError']) {
        \\    const constructor = WebAssembly[name];
        \\    const instance = new constructor('message');
        \\    correct = correct && Object.getPrototypeOf(constructor) === Error &&
        \\        Object.getPrototypeOf(constructor.prototype) === Error.prototype &&
        \\        instance instanceof Error && instance instanceof constructor &&
        \\        instance.name === name && instance.message === 'message';
        \\}
        \\correct;
    , false);
}

test "WPT exports: an empty exports namespace is frozen" {
    try expectWasm(
        \\const module = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0]));
        \\const instance = new WebAssembly.Instance(module);
        \\Object.getPrototypeOf(instance.exports) === null &&
        \\    Object.isFrozen(instance.exports) && Object.isExtensible(instance);
    , false);
}

test "WPT exports: properties are frozen while exported functions remain extensible" {
    try expectWasm("const instance = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ "));" ++
        \\const exports = instance.exports;
        \\const descriptor = Object.getOwnPropertyDescriptor(exports, 'add');
        \\Object.isFrozen(exports) && descriptor.writable === false && descriptor.enumerable === true &&
        \\    descriptor.configurable === false && descriptor.value === exports.add &&
        \\    Reflect.set(exports, 'add', 0) === false && Reflect.deleteProperty(exports, 'add') === false &&
        \\    Reflect.defineProperty(exports, 'extra', {value: 1}) === false &&
        \\    Object.isExtensible(exports.add) && exports.add(2, 3) === 5;
    , false);
}

test "WPT exports: the frozen namespace remains callable under hardened defaults" {
    try expectWasm("const instance = new WebAssembly.Instance(new WebAssembly.Module(" ++ adder_bytes ++ "));" ++
        \\Object.isFrozen(instance.exports) && instance.exports.add(20, 22) === 42;
    , true);
}
