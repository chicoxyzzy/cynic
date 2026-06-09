// The WebAssembly JS-API surface is frozen at realm init under the SES
// default, same as every other primordial. The namespace object plus
// each constructor prototype (Module, Instance, Memory, Table, Global,
// Tag, Exception) and the three error prototypes (CompileError,
// LinkError, RuntimeError) are a distinct frozen surface — none is
// reached by the other primordials_* fixtures, and the ~100 behaviour
// tests in src/runtime/wasm_js_test.zig assert API semantics, not the
// hardened-realm freeze. The surface installs regardless of
// --allow=wasm (only Module/Instance *construction* is gated), so a
// guest cannot monkeypatch e.g. WebAssembly.Memory.prototype.grow.

if (!Object.isFrozen(WebAssembly)) {
  throw new Error("WebAssembly namespace object is not frozen");
}

const prototypes = [
  WebAssembly.Module.prototype,
  WebAssembly.Instance.prototype,
  WebAssembly.Memory.prototype,
  WebAssembly.Table.prototype,
  WebAssembly.Global.prototype,
  WebAssembly.Tag.prototype,
  WebAssembly.Exception.prototype,
  WebAssembly.CompileError.prototype,
  WebAssembly.LinkError.prototype,
  WebAssembly.RuntimeError.prototype,
];

for (const proto of prototypes) {
  if (Object.isExtensible(proto)) {
    throw new Error(
      "WebAssembly intrinsic prototype unexpectedly extensible: " +
        Object.prototype.toString.call(proto)
    );
  }
}
