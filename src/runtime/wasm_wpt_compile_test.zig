//! Wasm JS API asynchronous compilation and WebIDL §3.2.24.1 promises.
//! Compilation completion is a host task; argument-conversion failures are
//! already-rejected promises. Every API promise uses the realm's %Promise%.
//! https://webassembly.github.io/spec/js-api/#asynchronously-compile-a-webassembly-module
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const Value = @import("value.zig").Value;
const heap = @import("heap.zig");
const lantern = @import("lantern/interpreter.zig");
const Snapshot = @import("snapshot.zig").Snapshot;

fn install(realm: *Realm, hardened: bool) !void {
    realm.hardened = hardened;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    realm.heap.setGcThreshold(1);
}

fn evaluate(realm: *Realm, source: []const u8) !Value {
    return switch (try lantern.evaluateScript(std.testing.allocator, realm, source)) {
        .value => |value| value,
        else => error.UnexpectedJavaScriptCompletion,
    };
}

fn expectTrue(realm: *Realm, source: []const u8) !void {
    const value = try evaluate(realm, source);
    try std.testing.expect(value.isBool() and value.asBool());
}

fn expectAsync(setup: []const u8, after: []const u8, hardened: bool) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm, hardened);
    try expectTrue(&realm, setup);
    realm.collectGarbage();
    try lantern.drainMicrotasks(std.testing.allocator, &realm);
    try expectTrue(&realm, after);
}

const empty_bytes = "new Uint8Array([0,97,115,109,1,0,0,0])";
const constant_module =
    \\function makeConstantBytes() {
    \\  return new Uint8Array([0,97,115,109,1,0,0,0,
    \\    1,5,1,96,0,1,127, 3,2,1,0, 7,5,1,1,102,0,0,
    \\    10,6,1,4,0,65,7,11]);
    \\}
;

test "WPT async compile: success waits beyond ordinary promise checkpoints" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(constant_module ++
            \\const events = [];
            \\let completed = false, failed = false;
            \\const pending = WebAssembly.compile(makeConstantBytes());
            \\pending.then(module => {
            \\  __collectGarbage();
            \\  events.push('compiled');
            \\  completed = module instanceof WebAssembly.Module && new WebAssembly.Instance(module).exports.f() === 7;
            \\}, () => { failed = true; });
            \\Promise.resolve().then(() => {
            \\  events.push('reaction');
            \\  return Promise.resolve().then(() => { events.push('nested reaction'); });
            \\});
            \\__drainMicrotasks();
            \\pending instanceof Promise && !completed && !failed && events.join(',') === 'reaction,nested reaction';
        ,
            \\completed && !failed && events.join(',') === 'reaction,nested reaction,compiled';
        , hardened);
    }
}

test "WPT async compile: malformed bytes reject after ordinary promise checkpoints" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(
            \\const events = [];
            \\let completed = false, failed = false;
            \\WebAssembly.compile(new Uint8Array([0,97,115,109,1,0,0])).then(
            \\  () => { failed = true; }, reason => {
            \\    __collectGarbage();
            \\    events.push('rejected');
            \\    completed = reason instanceof WebAssembly.CompileError;
            \\  });
            \\Promise.resolve().then(() => {
            \\  events.push('reaction');
            \\  return Promise.resolve().then(() => { events.push('nested reaction'); });
            \\});
            \\__drainMicrotasks();
            \\!completed && !failed && events.join(',') === 'reaction,nested reaction';
        ,
            \\completed && !failed && events.join(',') === 'reaction,nested reaction,rejected';
        , hardened);
    }
}

test "WPT async compile: invalid BufferSource rejects within the ordinary checkpoint" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(
            \\let rejected = 0, failed = false;
            \\const events = [];
            \\for (const source of [undefined, null, 17, {}, []]) {
            \\  const pending = WebAssembly.compile(source);
            \\  if (!(pending instanceof Promise)) failed = true;
            \\  pending.then(() => { failed = true; }, reason => {
            \\    if (reason instanceof TypeError) rejected++; else failed = true;
            \\    events.push('rejected');
            \\  });
            \\}
            \\Promise.resolve().then(() => { events.push('reaction'); });
            \\__drainMicrotasks();
            \\rejected === 5 && !failed && events.join(',') === 'rejected,rejected,rejected,rejected,rejected,reaction';
        ,
            \\rejected === 5 && !failed;
        , hardened);
    }
}

test "WPT async compile: copied BufferSource survives offsets mutation and detachment" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(constant_module ++
            \\let completed = 0, failed = false;
            \\for (const kind of [0,1,2]) {
            \\  const bytes = makeConstantBytes();
            \\  const offset = kind === 0 ? 0 : 3;
            \\  const buffer = new ArrayBuffer(bytes.length + (kind === 0 ? 0 : 8));
            \\  const view = new Uint8Array(buffer, offset, bytes.length);
            \\  view.set(bytes);
            \\  const source = kind === 0 ? buffer : kind === 1 ? view : new DataView(buffer, offset, bytes.length);
            \\  WebAssembly.compile(source).then(module => {
            \\    __collectGarbage();
            \\    if (module instanceof WebAssembly.Module && new WebAssembly.Instance(module).exports.f() === 7) completed++;
            \\    else failed = true;
            \\  }, () => { failed = true; });
            \\  view.fill(255);
            \\  buffer.transfer();
            \\  if (!buffer.detached) throw new Error('source did not detach');
            \\}
            \\__drainMicrotasks();
            \\completed === 0 && !failed;
        ,
            \\completed === 3 && !failed;
        , hardened);
    }
}

test "WPT async compile: promise checkpoints separate completion tasks" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(
            \\let completed = 0, checkpointed = 0, failed = false;
            \\for (const valid of [true, false, true]) {
            \\  const source = valid ? new Uint8Array([0,97,115,109,1,0,0,0]) : new Uint8Array(0);
            \\  function settled(correct) {
            \\    if (!correct || completed !== checkpointed) failed = true;
            \\    completed++;
            \\    Promise.resolve().then(() => Promise.resolve().then(() => { checkpointed++; }));
            \\  }
            \\  WebAssembly.compile(source).then(
            \\    module => settled(valid && module instanceof WebAssembly.Module),
            \\    reason => settled(!valid && reason instanceof WebAssembly.CompileError));
            \\}
            \\__drainMicrotasks();
            \\completed === 0 && checkpointed === 0 && !failed;
        ,
            \\completed === 3 && checkpointed === 3 && !failed;
        , hardened);
    }
}

test "WPT async compile: module then getter runs in the completion task" {
    try expectAsync(
        \\const events = [];
        \\let completed = false, failed = false;
        \\Object.defineProperty(WebAssembly.Module.prototype, 'then', {get() {
        \\  __collectGarbage();
        \\  events.push('then getter');
        \\  __drainMicrotasks();
        \\  return undefined;
        \\}});
        \\WebAssembly.compile(new Uint8Array([0,97,115,109,1,0,0,0])).then(module => {
        \\  completed = module instanceof WebAssembly.Module;
        \\  events.push('compiled');
        \\}, () => { failed = true; });
        \\events.push('returned');
        \\Promise.resolve().then(() => { events.push('reaction'); });
        \\__drainMicrotasks();
        \\!completed && !failed && events.join(',') === 'returned,reaction';
    ,
        \\completed && !failed && events.join(',') === 'returned,reaction,then getter,compiled';
    , false);
}

test "WPT async compile: WebAssembly ignores replaced deleted and accessor Promise globals" {
    try expectAsync(
        \\const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'Promise');
        \\const NativePromise = Promise;
        \\const nativeThen = Promise.prototype.then;
        \\let touched = 0, completed = 0, rejected = 0, failed = false;
        \\for (const mutation of [0,1,2]) {
        \\  const bytes = new Uint8Array([0,97,115,109,1,0,0,0]);
        \\  const module = new WebAssembly.Module(bytes);
        \\  const pending = [];
        \\  if (mutation === 0) globalThis.Promise = function() { touched++; throw new Error('replacement Promise'); };
        \\  if (mutation === 1) delete globalThis.Promise;
        \\  if (mutation === 2) Object.defineProperty(globalThis, 'Promise', {configurable: true, get() {
        \\    touched++; throw new Error('Promise getter');
        \\  }});
        \\  try {
        \\    pending.push(WebAssembly.compile(bytes));
        \\    pending.push(WebAssembly.instantiate(bytes));
        \\    pending.push(WebAssembly.instantiate(module));
        \\    pending.push(WebAssembly.compile(null));
        \\    pending.push(WebAssembly.compile(new Uint8Array(0)));
        \\    pending.push(WebAssembly.instantiate(null));
        \\    pending.push(WebAssembly.instantiate(new Uint8Array(0)));
        \\    pending.push(WebAssembly.instantiate(module, 17));
        \\    for (let index = 0; index < pending.length; index++) {
        \\      const promise = pending[index];
        \\      if (Object.getPrototypeOf(promise) !== NativePromise.prototype) failed = true;
        \\      nativeThen.call(promise, result => {
        \\        __collectGarbage();
        \\        if ((index === 0 && result instanceof WebAssembly.Module) ||
        \\            (index === 1 && result.module instanceof WebAssembly.Module && result.instance instanceof WebAssembly.Instance) ||
        \\            (index === 2 && result instanceof WebAssembly.Instance)) completed++;
        \\        else failed = true;
        \\      }, reason => {
        \\        __collectGarbage();
        \\        if (((index === 3 || index === 5 || index === 7) && reason instanceof TypeError) ||
        \\            ((index === 4 || index === 6) && reason instanceof WebAssembly.CompileError)) rejected++;
        \\        else failed = true;
        \\      });
        \\    }
        \\  } finally {
        \\    Object.defineProperty(globalThis, 'Promise', descriptor);
        \\  }
        \\}
        \\touched === 0 && !failed;
    ,
        \\touched === 0 && completed === 9 && rejected === 15 && !failed;
    , false);
}

test "WPT async compile: saved Promise methods retain intrinsic identity with a changed global" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm, false);
    try expectTrue(&realm,
        \\const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'Promise');
        \\const NativePromise = Promise;
        \\const nativeThen = Promise.prototype.then;
        \\const nativeFinally = Promise.prototype.finally;
        \\let touched = 0, fulfilled = 0, rejected = 0, finalized = 0, failed = false;
        \\for (const mutation of [0,1,2]) {
        \\  const sentinel = {};
        \\  if (mutation === 0) globalThis.Promise = function() { touched++; throw new Error('replacement Promise'); };
        \\  if (mutation === 1) delete globalThis.Promise;
        \\  if (mutation === 2) Object.defineProperty(globalThis, 'Promise', {configurable: true, get() {
        \\    touched++; throw new Error('Promise getter');
        \\  }});
        \\  try {
        \\    const resolved = NativePromise.resolve(17);
        \\    const refused = NativePromise.reject(sentinel);
        \\    if (NativePromise.resolve(resolved) !== resolved) failed = true;
        \\    for (const promise of [resolved, refused]) {
        \\      const final = nativeFinally.call(promise, () => { __collectGarbage(); finalized++; });
        \\      const chain = nativeThen.call(final, value => {
        \\        if (value === 17) fulfilled++; else failed = true;
        \\      }, reason => {
        \\        if (reason === sentinel) rejected++; else failed = true;
        \\      });
        \\      if (Object.getPrototypeOf(promise) !== NativePromise.prototype ||
        \\          Object.getPrototypeOf(final) !== NativePromise.prototype ||
        \\          Object.getPrototypeOf(chain) !== NativePromise.prototype) failed = true;
        \\    }
        \\    __drainMicrotasks();
        \\  } finally {
        \\    Object.defineProperty(globalThis, 'Promise', descriptor);
        \\  }
        \\}
        \\touched === 0 && fulfilled === 3 && rejected === 3 && finalized === 6 && !failed;
    );
}

test "WPT async compile: borrowed Promise resolve and reject honor a replacement constructor" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm, false);
    try expectTrue(&realm,
        \\const NativePromise = Promise;
        \\let constructed = 0, resolved = 0, rejected = 0;
        \\const sentinel = {};
        \\function Replacement(executor) {
        \\  constructed++;
        \\  executor(value => { if (value === 17) resolved++; }, reason => { if (reason === sentinel) rejected++; });
        \\}
        \\globalThis.Promise = Replacement;
        \\const fulfilled = NativePromise.resolve.call(Replacement, 17);
        \\const refused = NativePromise.reject.call(Replacement, sentinel);
        \\constructed === 2 && resolved === 1 && rejected === 1 &&
        \\  fulfilled instanceof Replacement && refused instanceof Replacement &&
        \\  !(fulfilled instanceof NativePromise) && !(refused instanceof NativePromise);
    );
}

fn expectIntrinsicAfterPublicDeletion(realm: *Realm) !void {
    try expectTrue(realm,
        \\delete Promise.prototype.constructor;
        \\delete globalThis.Promise;
        \\!('Promise' in globalThis);
    );
    // No saved JS constructor reference: only the realm intrinsic may retain it.
    realm.collectGarbage();
    try expectTrue(realm,
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0]);
        \\globalThis.compiled = WebAssembly.compile(bytes);
        \\globalThis.fromBytes = WebAssembly.instantiate(bytes);
        \\globalThis.fromModule = WebAssembly.instantiate(new WebAssembly.Module(bytes));
        \\true;
    );
    realm.collectGarbage();
    const names = [_][]const u8{ "compiled", "fromBytes", "fromModule" };
    for (names) |name| {
        const value = realm.globals.get(name) orelse return error.MissingPromise;
        const promise = heap.valueAsPlainObject(value) orelse return error.ExpectedPromise;
        try std.testing.expect(promise.isPromise());
        try std.testing.expect(promise.prototype == realm.intrinsics.promise_prototype);
        try std.testing.expectEqual(.pending, promise.brand.promise_state);
    }
    try lantern.drainMicrotasks(std.testing.allocator, realm);
    for (names) |name| {
        const value = realm.globals.get(name) orelse return error.MissingPromise;
        const promise = heap.valueAsPlainObject(value) orelse return error.ExpectedPromise;
        try std.testing.expectEqual(.fulfilled, promise.brand.promise_state);
    }
}

test "WPT async compile: intrinsic Promise survives deleting its public constructor roots" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    try install(&realm, false);
    try expectIntrinsicAfterPublicDeletion(&realm);
}

test "WPT async compile: restored snapshot retains the intrinsic Promise constructor" {
    const image = blk: {
        var source = Realm.init(std.testing.allocator);
        defer source.deinit();
        try install(&source, false);
        // Capture before evaluating any user script; mutate only the restored realm.
        break :blk try Snapshot.capture(&source, std.testing.allocator);
    };
    defer std.testing.allocator.free(image);
    const restored = try Snapshot.restore(std.testing.allocator, image);
    defer {
        restored.deinit();
        std.testing.allocator.destroy(restored);
    }
    restored.heap.setGcThreshold(1);
    try expectIntrinsicAfterPublicDeletion(restored);
}

test "WPT async compile: pending jobs retain their sole promise and result roots" {
    for ([_]bool{ false, true }) |hardened| {
        inline for ([_]bool{ false, true }) |valid| {
            var realm = Realm.init(std.testing.allocator);
            defer realm.deinit();
            try install(&realm, hardened);
            const value = try evaluate(&realm, if (valid)
                "WebAssembly.compile(" ++ empty_bytes ++ ");"
            else
                "WebAssembly.compile(new Uint8Array(0));");
            const promise = heap.valueAsPlainObject(value) orelse return error.ExpectedPromise;
            try std.testing.expect(promise.isPromise());
            try std.testing.expectEqual(.pending, promise.brand.promise_state);
            // The scheduling stack has returned and no global stores this promise.
            // The queued completion owns the only GC-visible root until it runs.
            realm.collectGarbage();
            try std.testing.expectEqual(.pending, promise.brand.promise_state);
            const scope = try realm.heap.openScope();
            defer scope.close();
            try scope.push(value);
            try lantern.drainMicrotasks(std.testing.allocator, &realm);
            realm.collectGarbage();
            try std.testing.expectEqual(if (valid) .fulfilled else .rejected, promise.brand.promise_state);
            const result = heap.valueAsPlainObject(promise.promise_value) orelse return error.ExpectedCompletionObject;
            if (valid) try std.testing.expect(result.getWasmModule() != null);
        }
    }
}

test "WPT async compile: teardown releases undrained successful and failed completions" {
    for ([_]bool{ false, true }) |hardened| {
        var realm = Realm.init(std.testing.allocator);
        defer realm.deinit();
        try install(&realm, hardened);
        try expectTrue(&realm,
            \\let callbacks = 0;
            \\WebAssembly.compile(new Uint8Array([0,97,115,109,1,0,0,0])).then(() => { callbacks++; });
            \\WebAssembly.compile(new Uint8Array(0)).then(undefined, () => { callbacks++; });
            \\__drainMicrotasks();
            \\callbacks === 0;
        );
        realm.collectGarbage();
        // std.testing.allocator checks cleanup of both queued payloads at teardown.
    }
}
