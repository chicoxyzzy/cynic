// A shadow installed via assignment (the override-mistake fix's
// synthetic-setter path) can be replaced via a subsequent
// `Object.defineProperty` with explicit attrs. The second define
// installs the new descriptor with the caller's attrs — the
// synthetic accessor was only on the prototype, not the receiver,
// so the second redefine sees an ordinary own data property.

const obj = {};

// First install: assignment routes through the prototype's
// synthetic setter, which installs a `{w:t, e:t, c:t}` data
// property on `obj`.
obj.toString = function () { return "first"; };
if (obj.toString() !== "first") {
  throw new Error("initial shadow assignment failed");
}

// Second install: defineProperty with explicit attrs replaces
// the own data property. The flags should be respected verbatim.
Object.defineProperty(obj, "toString", {
  value: function () { return "second"; },
  writable: false,
  enumerable: true,
  configurable: true,
});

if (obj.toString() !== "second") {
  throw new Error("defineProperty did not replace shadow");
}

const d = Object.getOwnPropertyDescriptor(obj, "toString");
if (d.writable !== false) {
  throw new Error("redefine did not preserve writable: false");
}
if (d.configurable !== true) {
  throw new Error("redefine did not preserve configurable: true");
}
