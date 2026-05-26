// The synthetic-accessor setter installs the value on the
// **receiver**, not on the frozen prototype. Two separate
// instances must each get their own shadow without leaking to
// each other or to the prototype.

const a = function () {};
const b = function () {};

a.toString = function () { return "a"; };

if (a.toString() !== "a") {
  throw new Error("a shadow failed");
}

// `b` hasn't been touched — it should still see the prototype's
// `toString`, not `a`'s shadow.
if (b.toString === a.toString) {
  throw new Error("shadow leaked from a to sibling instance b");
}

// And the prototype itself stays untouched.
if (Function.prototype.toString === a.toString) {
  throw new Error("shadow leaked onto Function.prototype");
}
