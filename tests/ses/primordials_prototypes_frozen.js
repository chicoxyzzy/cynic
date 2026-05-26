// All primordial prototypes are frozen at realm init under the
// SES default. `Object.isExtensible` must return false on each;
// asking-for-add throws TypeError per
// `built-ins/Object/prototype/extensibility.js` (one of the
// Phase 3 witnesses).

const protos = [
  Object.prototype, Array.prototype, Function.prototype,
  String.prototype, Number.prototype, Boolean.prototype,
  Error.prototype, RegExp.prototype, Date.prototype,
  Map.prototype, Set.prototype, WeakMap.prototype, WeakSet.prototype,
  Promise.prototype, Symbol.prototype,
];

for (const proto of protos) {
  if (Object.isExtensible(proto)) {
    throw new Error(
      "primordial prototype unexpectedly extensible: " +
        Object.prototype.toString.call(proto)
    );
  }
}
