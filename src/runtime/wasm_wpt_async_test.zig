//! Wasm JS API: asynchronously instantiate a WebAssembly module.
//! Bytes are copied before returning; imports are read after compilation.
//! A Module argument resolves imports synchronously, then queues instantiation.
//! https://webassembly.github.io/spec/js-api/#asynchronously-instantiate-a-webassembly-module
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

fn expectResult(realm: *Realm, source: []const u8) !void {
    const outcome = try lantern.evaluateScript(std.testing.allocator, realm, source);
    switch (outcome) {
        .value => |value| try std.testing.expect(value.isBool() and value.asBool()),
        else => return error.UnexpectedJavaScriptCompletion,
    }
}

fn expectAsync(setup: []const u8, after: []const u8, hardened: bool) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = hardened;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    realm.heap.setGcThreshold(1);
    try expectResult(&realm, setup);
    // Collect after the scheduling frames have disappeared. Pending jobs
    // must retain their own promises, modules, imports and captured values.
    realm.collectGarbage();
    try lantern.drainMicrotasks(std.testing.allocator, &realm);
    try expectResult(&realm, after);
}

// (module (type (func)) (import "m" "g" (global i32/externref))
//   (import "m" "s" (func)) (func call 0) (export "g" (global 0)) (start 1))
const start_module =
    \\function makeStartBytes(globalType = 127) {
    \\  return new Uint8Array([0,97,115,109,1,0,0,0,
    \\    1,4,1,96,0,0,
    \\    2,14,2,1,109,1,103,3,globalType,0,1,109,1,115,0,0,
    \\    3,2,1,0, 7,5,1,1,103,3,0, 8,1,1, 10,6,1,4,0,16,0,11]);
    \\}
;

// (module (func (export "f") (result i32) i32.const 7))
const constant_module =
    \\function makeConstantBytes() {
    \\  return new Uint8Array([0,97,115,109,1,0,0,0,
    \\    1,5,1,96,0,1,127, 3,2,1,0, 7,5,1,1,102,0,0,
    \\    10,6,1,4,0,65,7,11]);
    \\}
;

test "WPT async instantiate: BufferSource defers import getters and start until after return" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(start_module ++
            \\const events = [];
            \\let completed = false, failed = false;
            \\const imports = {get m() {
            \\  events.push('namespace');
            \\  return {
            \\    get g() { events.push('global'); return 7; },
            \\    get s() { events.push('start getter'); return () => { events.push('start'); }; }
            \\  };
            \\}};
            \\const promise = WebAssembly.instantiate(makeStartBytes(), imports);
            \\promise.then(result => {
            \\  completed = result.module instanceof WebAssembly.Module &&
            \\    result.instance instanceof WebAssembly.Instance && result.instance.exports.g.value === 7;
            \\}, () => { failed = true; });
            \\promise instanceof Promise && events.length === 0 && !completed && !failed;
        ,
            \\completed && !failed && events.join(',') === 'namespace,global,namespace,start getter,start';
        , hardened);
    }
}

test "WPT async instantiate: Module imports are synchronous but start is deferred" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(start_module ++
            \\const events = [];
            \\let completed = false, failed = false;
            \\const imports = {m: {
            \\  get g() { events.push('global'); return 7; },
            \\  get s() { events.push('start getter'); return () => { events.push('start'); }; }
            \\}};
            \\const promise = WebAssembly.instantiate(new WebAssembly.Module(makeStartBytes()), imports);
            \\promise.then(instance => {
            \\  completed = instance instanceof WebAssembly.Instance && instance.exports.g.value === 7;
            \\}, () => { failed = true; });
            \\imports.m = {g: 99, s() { events.push('replacement start'); }};
            \\events.join(',') === 'global,start getter' && !completed && !failed;
        ,
            \\completed && !failed && events.join(',') === 'global,start getter,start';
        , hardened);
    }
}

test "WPT async instantiate: copied BufferSource bytes survive offsets mutation and detachment" {
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
            \\  WebAssembly.instantiate(source).then(result => {
            \\    __collectGarbage();
            \\    const another = new WebAssembly.Instance(result.module);
            \\    if (result.instance.exports.f() === 7 && another.exports.f() === 7) completed++;
            \\    else failed = true;
            \\  }, () => { failed = true; });
            \\  view.fill(255);
            \\  buffer.transfer();
            \\  if (!buffer.detached) throw new Error('source did not detach');
            \\}
            \\completed === 0 && !failed;
        ,
            \\completed === 3 && !failed;
        , hardened);
    }
}

test "WPT async instantiate: BufferSource observes import object changes before its job" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(start_module ++
            \\let calls = 0, completed = false, failed = false;
            \\const imports = {m: {g: 1, s() { calls += 1; }}};
            \\WebAssembly.instantiate(makeStartBytes(), imports).then(result => {
            \\  completed = result.instance.exports.g.value === 9;
            \\}, () => { failed = true; });
            \\imports.m = {g: 9, s() { calls += 10; }};
            \\calls === 0 && !completed && !failed;
        ,
            \\completed && !failed && calls === 10;
        , hardened);
    }
}

test "WPT async instantiate: import getter and start throws reject with original identity" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(start_module ++
            \\let rejected = 0, failed = false;
            \\for (const moduleOverload of [false, true]) {
            \\  for (const stage of ['namespace','global','start getter','start']) {
            \\    const sentinel = {stage};
            \\    function fail(at) {
            \\      if (stage === at) { __collectGarbage(); throw sentinel; }
            \\    }
            \\    const imports = {get m() {
            \\      fail('namespace');
            \\      return {
            \\        get g() { fail('global'); return 7; },
            \\        get s() { fail('start getter'); return () => { fail('start'); }; }
            \\      };
            \\    }};
            \\    const bytes = makeStartBytes();
            \\    const source = moduleOverload ? new WebAssembly.Module(bytes) : bytes;
            \\    WebAssembly.instantiate(source, imports).then(() => { failed = true; }, reason => {
            \\      __collectGarbage();
            \\      if (reason === sentinel) rejected++; else failed = true;
            \\    });
            \\  }
            \\}
            \\rejected === 0 && !failed;
        ,
            \\rejected === 8 && !failed;
        , hardened);
    }
}

test "WPT async instantiate: nested promise reactions mutate imports before bytes job" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(start_module ++
            \\const events = [];
            \\let completed = false, failed = false;
            \\const imports = {m: {
            \\  get g() { events.push('old import'); return 1; },
            \\  s() { events.push('old start'); }
            \\}};
            \\WebAssembly.instantiate(makeStartBytes(), imports).then(result => {
            \\  events.push('fulfilled');
            \\  completed = result.instance.exports.g.value === 9;
            \\}, () => { failed = true; });
            \\Promise.resolve().then(() => {
            \\  events.push('reaction');
            \\  return Promise.resolve().then(() => {
            \\    events.push('nested reaction');
            \\    imports.m = {
            \\      get g() { events.push('new import'); return 9; },
            \\      s() { events.push('new start'); }
            \\    };
            \\  });
            \\});
            \\events.length === 0 && !completed && !failed;
        ,
            \\completed && !failed &&
            \\  events.join(',') === 'reaction,nested reaction,new import,new start,fulfilled';
        , hardened);
    }
}

test "WPT async instantiate: promise reactions drain between queued instantiations" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(start_module ++
            \\let entered = 0, completed = 0, nested = 0, failed = false;
            \\for (const id of [0,1]) {
            \\  WebAssembly.instantiate(makeStartBytes(), {m: {
            \\    g: id,
            \\    s() {
            \\      if (entered !== completed || completed !== nested) failed = true;
            \\      entered++;
            \\    }
            \\  }}).then(result => {
            \\    if (result.instance.exports.g.value !== id) failed = true;
            \\    completed++;
            \\    Promise.resolve().then(() => { nested++; });
            \\  }, () => { failed = true; });
            \\}
            \\entered === 0 && completed === 0 && nested === 0 && !failed;
        ,
            \\entered === 2 && completed === 2 && nested === 2 && !failed;
        , hardened);
    }
}

test "WPT async instantiate: import getter promise chains run before start" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(start_module ++
            \\const states = [];
            \\let failed = false;
            \\for (const moduleOverload of [false, true]) {
            \\  const state = {events: [], ready: false, completed: false};
            \\  states.push(state);
            \\  const imports = {m: {
            \\    get g() {
            \\      state.events.push('getter');
            \\      Promise.resolve().then(() => {
            \\        state.events.push('reaction');
            \\        return Promise.resolve().then(() => {
            \\          state.ready = true;
            \\          imports.m.s = () => { state.events.push('replacement start'); };
            \\          state.events.push('nested reaction');
            \\        });
            \\      });
            \\      return 7;
            \\    },
            \\    s() { state.events.push(state.ready ? 'start' : 'early start'); }
            \\  }};
            \\  const bytes = makeStartBytes();
            \\  WebAssembly.instantiate(moduleOverload ? new WebAssembly.Module(bytes) : bytes, imports)
            \\    .then(result => {
            \\      state.events.push('fulfilled');
            \\      const instance = moduleOverload ? result : result.instance;
            \\      state.completed = instance.exports.g.value === 7;
            \\    }, () => { failed = true; });
            \\  if (state.events.join(',') !== (moduleOverload ? 'getter' : '')) failed = true;
            \\}
            \\!failed;
        ,
            \\!failed && states.length === 2 && states.every(state => state.completed &&
            \\  state.events.join(',') === 'getter,reaction,nested reaction,start,fulfilled');
        , hardened);
    }
}

test "WPT async instantiate: active data and element segments wait for core instantiation" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(
            \\let completed = 0, failed = false;
            \\for (const moduleOverload of [false, true]) {
            \\  const memory = new WebAssembly.Memory({initial: 1});
            \\  const view = new Uint8Array(memory.buffer);
            \\  view[0] = 9;
            \\  // (module (import "m" "m" (memory 1)) (data (i32.const 0) "*"))
            \\  const memoryBytes = new Uint8Array([0,97,115,109,1,0,0,0,
            \\    2,8,1,1,109,1,109,2,0,1, 11,7,1,0,65,0,11,1,42]);
            \\  WebAssembly.instantiate(moduleOverload ? new WebAssembly.Module(memoryBytes) : memoryBytes,
            \\    {m: {m: memory}}).then(() => {
            \\      if (view[0] === 42) completed++; else failed = true;
            \\    }, () => { failed = true; });
            \\  if (view[0] !== 9) failed = true;
            \\  Promise.resolve().then(() => { view[0] = 55; });
            \\  const table = new WebAssembly.Table({element: 'anyfunc', initial: 1});
            \\  // Imports a table and initializes slot zero to a () -> i32 function returning 7.
            \\  const tableBytes = new Uint8Array([0,97,115,109,1,0,0,0,
            \\    1,5,1,96,0,1,127, 2,9,1,1,109,1,116,1,112,0,1,
            \\    3,2,1,0, 9,7,1,0,65,0,11,1,0, 10,6,1,4,0,65,7,11]);
            \\  WebAssembly.instantiate(moduleOverload ? new WebAssembly.Module(tableBytes) : tableBytes,
            \\    {m: {t: table}}).then(() => {
            \\      const fn = table.get(0);
            \\      if (typeof fn === 'function' && fn() === 7) completed++; else failed = true;
            \\    }, () => { failed = true; });
            \\  if (table.get(0) !== null) failed = true;
            \\  Promise.resolve().then(() => { table.set(0, null); });
            \\}
            \\completed === 0 && !failed;
        ,
            \\completed === 4 && !failed;
        , hardened);
    }
}

test "WPT async instantiate: nested microtask drains do not run another Wasm task" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(start_module ++
            \\let active = false, failed = false, getters = 0, starts = 0, completed = 0;
            \\function drainInsideCallback() {
            \\  if (active) failed = true;
            \\  active = true;
            \\  __drainMicrotasks();
            \\  active = false;
            \\}
            \\for (const moduleOverload of [false, true]) {
            \\  const bytes = makeStartBytes();
            \\  WebAssembly.instantiate(moduleOverload ? new WebAssembly.Module(bytes) : bytes, {m: {
            \\    get g() { getters++; drainInsideCallback(); return 7; },
            \\    s() { drainInsideCallback(); starts++; }
            \\  }}).then(result => {
            \\    const instance = moduleOverload ? result : result.instance;
            \\    if (instance.exports.g.value === 7) completed++; else failed = true;
            \\  }, () => { failed = true; });
            \\}
            \\getters === 1 && starts === 0 && completed === 0 && !active && !failed;
        ,
            \\getters === 2 && starts === 2 && completed === 2 && !active && !failed;
        , hardened);
    }
}

test "WPT async instantiate: import object validation rejects at call time before byte decoding" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(constant_module ++
            \\const bytes = makeConstantBytes();
            \\const module = new WebAssembly.Module(bytes);
            \\const states = [];
            \\let rejected = 0, accepted = 0, failed = false;
            \\for (const source of [bytes, module, new Uint8Array([0])]) {
            \\  for (const imports of [null, true, 0, '', Symbol('invalid'), 1n]) {
            \\    const events = [];
            \\    states.push(events);
            \\    WebAssembly.instantiate(source, imports).then(() => { failed = true; }, reason => {
            \\      if (reason instanceof TypeError) rejected++; else failed = true;
            \\      events.push('rejection');
            \\    });
            \\    Promise.resolve().then(() => { events.push('checkpoint'); });
            \\  }
            \\}
            \\for (const imports of [undefined, {}, function() {}, new Proxy(function() {}, {})]) {
            \\  WebAssembly.instantiate(bytes, imports).then(result => {
            \\    if (result.instance.exports.f() === 7) accepted++; else failed = true;
            \\  }, () => { failed = true; });
            \\}
            \\rejected === 0 && accepted === 0 && !failed && states.every(events => events.length === 0);
        ,
            \\rejected === 18 && accepted === 4 && !failed &&
            \\  states.every(events => events.join(',') === 'rejection,checkpoint');
        , hardened);
    }
}

test "WPT async instantiate: malformed byte rejection waits for the task checkpoint" {
    for ([_]bool{ false, true }) |hardened| {
        try expectAsync(
            \\const events = [];
            \\let rejected = false, failed = false, getters = 0;
            \\WebAssembly.instantiate(new Uint8Array([0]), {get m() { getters++; return {}; }})
            \\  .then(() => { failed = true; }, reason => {
            \\    __collectGarbage();
            \\    rejected = reason instanceof WebAssembly.CompileError;
            \\    events.push('rejection');
            \\  });
            \\Promise.resolve().then(() => {
            \\  events.push('reaction');
            \\  return Promise.resolve().then(() => { events.push('nested reaction'); });
            \\});
            \\events.length === 0 && !rejected && !failed && getters === 0;
        ,
            \\rejected && !failed && getters === 0 &&
            \\  events.join(',') === 'reaction,nested reaction,rejection';
        , hardened);
    }
}
