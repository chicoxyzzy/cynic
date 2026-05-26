// Override-mistake fix — `Object.defineProperty(receiver, key,
// dataDescriptor)` works through a synthetic accessor pair on a
// frozen prototype, installing a fresh own data property on the
// receiver.
//
// The synthetic accessor's setter is internal: it does an
// `OrdinaryDefineOwnProperty` on the receiver with a default
// `{w:t, e:t, c:t}` data descriptor, not a `[[Set]]` redirect.
// `defineProperty` with an explicit descriptor must therefore
// install with the descriptor the caller passed, not the
// setter's defaults.

const obj = {};
Object.defineProperty(obj, "toString", {
  value: function () { return "defined"; },
  writable: false,
  enumerable: false,
  configurable: false,
});

if (obj.toString() !== "defined") {
  throw new Error("defineProperty over synthetic accessor did not install value");
}

const d = Object.getOwnPropertyDescriptor(obj, "toString");
if (d === undefined) {
  throw new Error("defineProperty installed no own descriptor");
}
if (d.writable !== false) {
  throw new Error("descriptor writable flag was not preserved");
}
if (d.configurable !== false) {
  throw new Error("descriptor configurable flag was not preserved");
}
