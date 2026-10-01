//! Wasm JS API "create a host function": IteratorToList(GetIteratorFromMethod)
//! precedes arity validation and ToWebAssemblyValue. ECMA-262 IteratorToList does
//! not close the iterator on abrupt completion or a later arity mismatch.
const std = @import("std");
const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const spasm = @import("wasm/spasm.zig");

const Options = struct {
    hardened: bool = true,
    gc_pressure: bool = false,
    jit_enabled: bool = false,
};

fn expectResult(realm: *Realm, source: []const u8) !void {
    const outcome = try lantern.evaluateScript(std.testing.allocator, realm, source);
    switch (outcome) {
        .value => |value| try std.testing.expect(value.isBool() and value.asBool()),
        else => return error.UnexpectedJavaScriptCompletion,
    }
}

fn expectTrue(source: []const u8, options: Options) !void {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.hardened = options.hardened;
    realm.allow_wasm_compile = true;
    realm.jit_enabled = options.jit_enabled;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    if (options.gc_pressure) realm.heap.setGcThreshold(1);
    try expectResult(&realm, source);
    if (options.jit_enabled) {
        try std.testing.expectEqual(@as(usize, 1), realm.wasm_instances.items.len);
        try std.testing.expect(realm.wasm_instances.items[0].spasm_runs > 0);
        try std.testing.expectEqual(@as(u32, 0), realm.wasm_instances.items[0].spasm_refusals);
    }
}

// (module (type $t (func (param ...) (result ...)))
//   (import "h" "f" (func $f (type $t)))
//   (func (export "run") (type $t) local.get 0 ... call $f))
// All fixture counts and section lengths are below 128 (single-byte ULEB).
const helpers =
    \\function makeCall(results, host, params = []) {
    \\  const type = [1, 96, params.length, ...params, results.length, ...results];
    \\  const body = [0];
    \\  for (let i = 0; i < params.length; i++) body.push(32, i);
    \\  body.push(16, 0, 11);
    \\  const bytes = new Uint8Array([0,97,115,109,1,0,0,0,
    \\    1,type.length,...type, 2,7,1,1,104,1,102,0,0, 3,2,1,0,
    \\    7,7,1,3,114,117,110,0,1, 10,body.length+2,1,body.length,...body]);
    \\  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {h: {f: host}}).exports.run;
    \\}
    \\function throwsTypeError(callback) {
    \\  try { callback(); } catch (error) { return error instanceof TypeError; }
    \\  return false;
    \\}
;

test "WPT multivalue imports: consume iterator before ordered numeric conversions" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(helpers ++
            \\const events = [];
            \\const run = makeCall([127, 124], (x, y) => {
            \\  if (x !== 4.2 || y !== 7) throw new Error('arguments');
            \\  let i = 0;
            \\  const iterable = {
            \\    get [Symbol.iterator]() {
            \\      events.push('iterator:get');
            \\      return function() {
            \\        if (this !== iterable) throw new Error('iterator receiver');
            \\        events.push('iterator:call');
            \\        const iterator = {
            \\          get next() {
            \\            events.push('next:get');
            \\            return function() {
            \\              if (this !== iterator || arguments.length !== 0) throw new Error('next call');
            \\              const j = ++i;
            \\              events.push('next:' + j);
            \\              return {
            \\                get done() { events.push('done:' + j); return j === 3; },
            \\                get value() {
            \\                  if (j === 3) throw new Error('completed value read');
            \\                  events.push('value:' + j);
            \\                  return {get valueOf() {
            \\                    events.push('convert:get:' + j);
            \\                    return () => { events.push('convert:call:' + j); return j === 1 ? 2 : 7.3; };
            \\                  }};
            \\                }
            \\              };
            \\            };
            \\          }
            \\        };
            \\        return iterator;
            \\      };
            \\    }
            \\  };
            \\  return iterable;
            \\}, [124, 127]);
            \\const result = run(4.2, 7);
            \\result.length === 2 && result[0] === 2 && result[1] === 7.3 &&
            \\  events.join(',') === 'iterator:get,iterator:call,next:get,next:1,done:1,value:1,next:2,done:2,value:2,next:3,done:3,convert:get:1,convert:call:1,convert:get:2,convert:call:2';
        , .{ .hardened = hardened });
    }
}

test "WPT multivalue imports: mixed numeric and reference results preserve identity" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(helpers ++
            \\const fn = makeCall([], () => {});
            \\const reference = {tag: 42};
            \\const run = makeCall([127,126,124,111,112],
            \\  () => [4294967297, 18446744073709551619n, -0, reference, fn]);
            \\const result = run();
            \\result.length === 5 && result[0] === 1 && result[1] === 3n &&
            \\  Object.is(result[2], -0) && result[3] === reference && result[4] === fn;
        , .{ .hardened = hardened, .gc_pressure = true });
    }
}

test "WPT multivalue imports: arity mismatch consumes excess values without conversion or close" {
    try expectTrue(helpers ++
        \\let ok = true, conversions = 0, closes = 0;
        \\for (const count of [0, 1, 3, 20]) {
        \\  let nexts = 0, values = 0;
        \\  const run = makeCall([127,127], () => ({
        \\    [Symbol.iterator]() { return {
        \\      next() {
        \\        const index = nexts++;
        \\        return {done: index === count, get value() {
        \\          values++;
        \\          return {valueOf() { conversions++; return 7; }};
        \\        }};
        \\      },
        \\      get return() { closes++; throw new Error('unexpected close'); }
        \\    }; }
        \\  }));
        \\  ok = throwsTypeError(run) && nexts === count + 1 && values === count && ok;
        \\}
        \\const sentinel = {};
        \\let nexts = 0, caught = false;
        \\const run = makeCall([127,127], () => ({
        \\  [Symbol.iterator]() { return {
        \\    next() {
        \\      if (++nexts === 20) throw sentinel;
        \\      return {done: false, value: {valueOf() { conversions++; return 1; }}};
        \\    },
        \\    get return() { closes++; throw new Error('unexpected close'); }
        \\  }; }
        \\}));
        \\try { run(); } catch (error) { caught = error === sentinel; }
        \\ok && caught && nexts === 20 && conversions === 0 && closes === 0;
    , .{});
}

test "WPT multivalue imports: missing or malformed iterator protocol throws TypeError" {
    try expectTrue(helpers ++
        \\let ok = true;
        \\for (const value of [undefined, null, 1, {},
        \\    {[Symbol.iterator]: 1}, {[Symbol.iterator]() { return 1; }},
        \\    {[Symbol.iterator]() { return {next: 1}; }},
        \\    {[Symbol.iterator]() { return {next() { return 1; }}; }}]) {
        \\  ok = throwsTypeError(makeCall([127,127], () => value)) && ok;
        \\}
        \\const result = makeCall([127,127], () => '12')();
        \\let receiver;
        \\Object.defineProperty(Number.prototype, Symbol.iterator, {get() {
        \\  receiver = this;
        \\  if (this !== 42) throw new Error('boxed iterator getter receiver');
        \\  return function() {
        \\    if (this !== 42) throw new Error('boxed iterator method receiver');
        \\    return [3,4][Symbol.iterator]();
        \\  };
        \\}});
        \\const numbers = makeCall([127,127], () => 42)();
        \\ok && result[0] === 1 && result[1] === 2 && receiver === 42 &&
        \\  numbers[0] === 3 && numbers[1] === 4;
    , .{ .hardened = false });
}

test "WPT multivalue imports: function objects and Proxy iterator methods are supported" {
    try expectTrue(helpers ++
        \\let calls = 0, index = 0;
        \\function iterable() {}
        \\function iterator() {}
        \\function proxy(fn) {
        \\  return new Proxy(fn, {apply(target, receiver, args) {
        \\    calls++; return Reflect.apply(target, receiver, args);
        \\  }});
        \\}
        \\iterable[Symbol.iterator] = proxy(function() {
        \\  if (this !== iterable) throw new Error('iterator receiver');
        \\  return iterator;
        \\});
        \\iterator.next = proxy(function() {
        \\  if (this !== iterator || arguments.length !== 0) throw new Error('next receiver');
        \\  function result() {}
        \\  result.done = index === 2;
        \\  result.value = ++index;
        \\  return result;
        \\});
        \\const result = makeCall([127,127], () => iterable)();
        \\result[0] === 1 && result[1] === 2 && calls === 4;
    , .{ .gc_pressure = true });
}

test "WPT multivalue imports: callable Proxy iterable iterator and result objects perform Get" {
    try expectTrue(helpers ++
        \\let ok = true;
        \\for (const trapped of [false, true]) {
        \\  let gets = 0, index = 0;
        \\  function wrap(target) {
        \\    return new Proxy(target, trapped ? {get(target, key, receiver) {
        \\      if (key !== Symbol.iterator && key !== 'next' && key !== 'done' && key !== 'value')
        \\        throw new Error('unexpected key');
        \\      gets++;
        \\      return Reflect.get(target, key, receiver);
        \\    }} : {});
        \\  }
        \\  function iterable() {}
        \\  function iterator() {}
        \\  iterator.next = function() {
        \\    function result() {}
        \\    result.done = index === 2;
        \\    result.value = ++index + 2;
        \\    return wrap(result);
        \\  };
        \\  iterable[Symbol.iterator] = () => wrap(iterator);
        \\  const result = makeCall([127,127], () => wrap(iterable))();
        \\  ok = result[0] === 3 && result[1] === 4 && gets === (trapped ? 7 : 0) && ok;
        \\}
        \\let target = function() {};
        \\Object.defineProperty(target, Symbol.iterator, {get() {
        \\  if (this !== revocable.proxy) throw new Error('lost proxy receiver');
        \\  return () => [3,4][Symbol.iterator]();
        \\}});
        \\const revocable = Proxy.revocable(target, {get get() {
        \\  revocable.revoke(); __collectGarbage(); return undefined;
        \\}});
        \\target = null;
        \\const afterRevocation = makeCall([127,127], () => revocable.proxy)();
        \\ok = afterRevocation[0] === 3 && afterRevocation[1] === 4 && ok;
        \\for (const accessor of [false, true]) {
        \\  const target = function() {};
        \\  Object.defineProperty(target, Symbol.iterator, accessor ? {get: undefined} :
        \\    {value: () => [3,4][Symbol.iterator]()});
        \\  const proxy = new Proxy(target, {get() { return () => [3,4][Symbol.iterator](); }});
        \\  ok = throwsTypeError(makeCall([127,127], () => proxy)) && ok;
        \\}
        \\ok;
    , .{ .gc_pressure = true });
}

test "WPT multivalue imports: primitive iterable lookup retains original prototypes" {
    try expectTrue(helpers ++
        \\const iteratorKey = Symbol.iterator;
        \\const cases = [[Number,42,'Number'], [Boolean,true,'Boolean'],
        \\  [Symbol,Symbol('iterable'),'Symbol'], [BigInt,7n,'BigInt']];
        \\let ok = true;
        \\for (const [constructor, primitive, name] of cases) {
        \\  Object.defineProperty(constructor.prototype, iteratorKey, {get() {
        \\    if (this !== primitive) throw new Error('boxed getter receiver');
        \\    return function() {
        \\      if (this !== primitive) throw new Error('boxed method receiver');
        \\      return [3,4][iteratorKey]();
        \\    };
        \\  }});
        \\  globalThis[name] = undefined;
        \\  const result = makeCall([127,127], () => primitive)();
        \\  ok = result[0] === 3 && result[1] === 4 && ok;
        \\}
        \\ok;
    , .{ .hardened = false });
}

test "WPT multivalue imports: iterator and coercion throws preserve identity without close" {
    try expectTrue(helpers ++
        \\let ok = true, closes = 0;
        \\for (const stage of ['host','iterator:get','iterator:call','next:get','next:call',
        \\    'done:get','value:get','convert:get','convert:call']) {
        \\  const sentinel = {};
        \\  function fail(at) { if (stage === at) { __collectGarbage(); throw sentinel; } }
        \\  const run = makeCall([127,127], () => {
        \\    fail('host');
        \\    let i = 0;
        \\    return {get [Symbol.iterator]() {
        \\      fail('iterator:get');
        \\      return function() {
        \\        fail('iterator:call');
        \\        return {
        \\          get next() {
        \\            fail('next:get');
        \\            return function() {
        \\              fail('next:call');
        \\              return {
        \\                get done() { fail('done:get'); return i++ === 2; },
        \\                get value() {
        \\                  fail('value:get');
        \\                  return {get valueOf() {
        \\                    fail('convert:get');
        \\                    return () => { fail('convert:call'); return 7; };
        \\                  }};
        \\                }
        \\              };
        \\            };
        \\          },
        \\          get return() { closes++; throw new Error('unexpected close'); }
        \\        };
        \\      };
        \\    }};
        \\  });
        \\  let caught = false;
        \\  try { run(); } catch (error) { caught = error === sentinel; }
        \\  ok = caught && ok;
        \\}
        \\ok && closes === 0;
    , .{ .gc_pressure = true });
}

const collecting_reentry = helpers ++
    \\let depth = 0;
    \\const run = makeCall([111,127,126,124,111], () => {
    \\  const current = depth;
    \\  let i = 0;
    \\  return {get [Symbol.iterator]() {
    \\    __collectGarbage();
    \\    return function() {
    \\      __collectGarbage();
    \\      return {get next() {
    \\        __collectGarbage();
    \\        return function() {
    \\          __collectGarbage();
    \\          const index = i++;
    \\          return {
    \\            get done() { __collectGarbage(); return index === 5; },
    \\            get value() {
    \\              __collectGarbage();
    \\              if (index === 0 || index === 4) return {tag: current + index};
    \\              return {[Symbol.toPrimitive](hint) {
    \\                if (hint !== 'number') throw new Error('coercion hint');
    \\                if (index === 1 && current === 0) {
    \\                  depth = 1;
    \\                  const nested = run();
    \\                  depth = 0;
    \\                  if (nested[0].tag !== 1 || nested[1] !== 11 ||
    \\                      nested[2] !== 101n || nested[3] !== 2.5 || nested[4].tag !== 5)
    \\                    throw new Error('nested results');
    \\                }
    \\                __collectGarbage();
    \\                if (index === 1) return 10 + current;
    \\                if (index === 2) return current === 0 ? 100n : 101n;
    \\                return 1.5 + current;
    \\              }};
    \\            }
    \\          };
    \\        };
    \\      }};
    \\    };
    \\  }};
    \\});
    \\const result = run();
    \\__collectGarbage();
    \\result[0].tag === 0 && result[1] === 10 && result[2] === 100n &&
    \\  result[3] === 1.5 && result[4].tag === 4;
;

test "WPT multivalue imports: GC1 retains fresh results across iterator and reentrant coercion" {
    for ([_]bool{ false, true }) |hardened| {
        try expectTrue(collecting_reentry, .{ .hardened = hardened, .gc_pressure = true });
    }
}

test "WPT multivalue imports: actual Spasm entry survives collecting host reentry" {
    if (comptime !spasm.full_coverage_supported) return error.SkipZigTest;
    try expectTrue(collecting_reentry, .{ .gc_pressure = true, .jit_enabled = true });
}

test "WPT multivalue imports: sixteen parameters and results retain the host boundary" {
    try expectTrue(helpers ++
        \\const types = new Array(16).fill(127);
        \\const values = Array.from({length: 16}, (_, i) => i + 1);
        \\const result = makeCall(types, (...args) => args, types)(...values);
        \\let calls = 0;
        \\const host = () => { calls++; return []; };
        \\let ok = result.length === 16 && result.every((value, i) => value === values[i]);
        \\ok = throwsTypeError(() => makeCall(new Array(17).fill(127), host)) && ok;
        \\ok = throwsTypeError(() => makeCall([127,127], host, new Array(17).fill(127))) && ok;
        \\const scalar = {get [Symbol.iterator]() { throw new Error('unexpected iteration'); }, valueOf() { return 21; }};
        \\ok && calls === 0 && makeCall([], () => scalar)() === undefined &&
        \\  makeCall([127], () => scalar)() === 21;
    , .{});
}

test "WPT multivalue imports: forbidden result types reject before calling JavaScript" {
    try expectTrue(helpers ++
        \\let calls = 0, ok = true;
        \\for (const type of [123,105]) {
        \\  const run = makeCall([127,type], () => { calls++; return [1,null]; });
        \\  ok = throwsTypeError(run) && ok;
        \\}
        \\ok && calls === 0;
    , .{});
}

test "WPT multivalue imports: endless native iterator consumes fuel and terminates uncatchably" {
    var realm = Realm.init(std.testing.allocator);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = false;
    realm.ohaimark_enabled = false;
    try realm.installBuiltins();
    try expectResult(&realm, helpers ++
        \\let caught = false;
        \\const step = {done: false, value: 1};
        \\const run = makeCall([127,127], () => ({
        \\  [Symbol.iterator]() { return {next: Object.prototype.valueOf.bind(step)}; }
        \\}));
        \\true;
    );
    realm.setFuel(64);
    const outcome = try lantern.evaluateScript(std.testing.allocator, &realm,
        \\try { run(); } catch (error) { caught = true; }
    );
    switch (outcome) {
        .thrown => {},
        else => return error.ExpectedFuelTermination,
    }
    try std.testing.expectEqual(@as(?Realm.TerminationReason, .fuel_exhausted), realm.terminationReason());
    realm.clearTermination();
    realm.setFuel(std.math.maxInt(u64));
    try expectResult(&realm, "caught === false;");
}
