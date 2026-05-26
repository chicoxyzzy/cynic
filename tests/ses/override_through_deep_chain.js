// The override-mistake fix should compose through a multi-level
// prototype chain. A leaf object whose chain ends at a frozen
// primordial can shadow at any level; shadows at one level don't
// affect peers at higher levels.

const mid = Object.create(Object.prototype);
mid.toString = function () { return "mid"; };

const leaf = Object.create(mid);
leaf.toString = function () { return "leaf"; };

if (leaf.toString() !== "leaf") {
  throw new Error("leaf shadow did not win lookup");
}
if (mid.toString() !== "mid") {
  throw new Error("mid's shadow was clobbered by leaf install");
}
// Original primordial untouched.
if (Object.prototype.toString === leaf.toString) {
  throw new Error("leaked all the way to Object.prototype");
}
if (Object.prototype.toString === mid.toString) {
  throw new Error("mid's shadow leaked to Object.prototype");
}
