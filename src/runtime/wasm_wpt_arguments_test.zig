//! Required arguments follow WebIDL overload resolution; a Tag argument
//! requires a branded Tag object (Wasm JS API §5.1 and §5.9).
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectTrue(source: []const u8) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    realm.allow_wasm_compile = true;
    try realm.installBuiltins();
    const result = try lantern.evaluateScript(std.testing.allocator, &realm, source);
    switch (result) {
        .value, .yielded => |value| try std.testing.expect(value.isBool() and value.asBool()),
        .thrown => return error.UnexpectedJavaScriptException,
    }
}

const helpers =
    \\function throwsTypeError(callback) {
    \\  try { callback(); } catch (error) { return error instanceof TypeError; }
    \\  return false;
    \\}
;

test "WPT arguments: customSections requires a section name but accepts explicit undefined" {
    try expectTrue(helpers ++
        \\const module = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,
        \\  0,11,9,117,110,100,101,102,105,110,101,100,99]));
        \\const sections = WebAssembly.Module.customSections(module, undefined);
        \\throwsTypeError(() => WebAssembly.Module.customSections()) &&
        \\  throwsTypeError(() => WebAssembly.Module.customSections(module)) &&
        \\  sections.length === 1 && new Uint8Array(sections[0])[0] === 99
    );
}

test "WPT arguments: Exception is requires a tag argument" {
    try expectTrue(helpers ++
        \\const tag = new WebAssembly.Tag({parameters: []});
        \\const other = new WebAssembly.Tag({parameters: []});
        \\const exception = new WebAssembly.Exception(tag, []);
        \\throwsTypeError(() => exception.is()) && exception.is(tag) === true &&
        \\  exception.is(other) === false
    );
}

test "WPT arguments: Exception is rejects unbranded tag arguments" {
    try expectTrue(helpers ++
        \\const tag = new WebAssembly.Tag({parameters: []});
        \\const exception = new WebAssembly.Exception(tag, []);
        \\let correct = true;
        \\for (const invalid of [undefined, null, true, '', Symbol(), 1, {},
        \\    function () {}, WebAssembly.Tag.prototype, Object.create(tag), new Proxy(tag, {})]) {
        \\  correct = throwsTypeError(() => exception.is(invalid)) && correct;
        \\}
        \\correct
    );
}

test "WPT arguments: Exception getArg requires both tag and index" {
    try expectTrue(helpers ++
        \\const tag = new WebAssembly.Tag({parameters: ['i32']});
        \\const exception = new WebAssembly.Exception(tag, [42]);
        \\throwsTypeError(() => exception.getArg()) &&
        \\  throwsTypeError(() => exception.getArg(tag)) && exception.getArg(tag, 0) === 42
    );
}
