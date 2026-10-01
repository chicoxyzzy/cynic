//! A debug microtask checkpoint inside a promise reaction must not
//! start a WebAssembly host task before that reaction returns.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectTrue(realm: *Realm, source: []const u8) !void {
    const outcome = try lantern.evaluateScript(std.testing.allocator, realm, source);
    switch (outcome) {
        .value => |value| try std.testing.expect(value.isBool() and value.asBool()),
        else => return error.UnexpectedJavaScriptCompletion,
    }
}

test "WPT async instantiate: ordinary reactions cannot start Wasm during debug drains" {
    for ([_]bool{ false, true }) |hardened| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        realm.hardened = hardened;
        realm.allow_wasm_compile = true;
        realm.jit_enabled = false;
        realm.ohaimark_enabled = false;
        try realm.installBuiltins();
        try realm.installTestGlobals();
        realm.heap.setGcThreshold(1);
        // A defined start wrapper calls the import, isolating job ordering
        // from the core's separate direct host-import entry limitation.
        try expectTrue(&realm,
            \\let events = [], activeReaction = false, failed = false, starts = 0, completed = 0;
            \\// (module (import "m" "s" (func)) (func call 0) (start 1))
            \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0,
            \\  1,4,1,96,0,0, 2,7,1,1,109,1,115,0,0,
            \\  3,2,1,0, 8,1,1, 10,6,1,4,0,16,0,11]);
            \\for (const moduleOverload of [false, true]) {
            \\  const source = moduleOverload ? new WebAssembly.Module(bytes) : bytes;
            \\  WebAssembly.instantiate(source, {m: {s() {
            \\    if (activeReaction) failed = true;
            \\    starts++;
            \\    events.push('start');
            \\  }}}).then(() => { completed++; }, () => { failed = true; });
            \\}
            \\Promise.resolve().then(() => {
            \\  activeReaction = true;
            \\  events.push('before');
            \\  Promise.resolve().then(() => { events.push('nested reaction'); });
            \\  __drainMicrotasks();
            \\  if (starts !== 0) failed = true;
            \\  events.push('after');
            \\  activeReaction = false;
            \\});
            \\starts === 0 && completed === 0 && !failed;
        );
        realm.collectGarbage();
        try lantern.drainMicrotasks(std.testing.allocator, &realm);
        try expectTrue(&realm,
            \\!failed && !activeReaction && starts === 2 && completed === 2 &&
            \\  events.join(',') === 'before,nested reaction,after,start,start';
        );
    }
}
