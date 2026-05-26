// harden() on a function freezes both the function object and
// its `.prototype` slot. The traversal follows `[[Prototype]]`
// links and own-property values; the `prototype` property is a
// regular own data property, so it's caught the same way.

function F() {}
F.prototype.extra = "kept";
harden(F);

if (Object.isExtensible(F)) {
  throw new Error("harden did not freeze the function");
}
if (Object.isExtensible(F.prototype)) {
  throw new Error("harden did not freeze F.prototype");
}

const d = Object.getOwnPropertyDescriptor(F.prototype, "extra");
if (d.writable !== false || d.configurable !== false) {
  throw new Error("harden did not lock F.prototype.extra");
}
