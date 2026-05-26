// Override-mistake fix — assignment to an own data property
// whose name collides with a frozen non-writable prototype slot
// should succeed as instance shadowing, not throw TypeError.
//
// Under spec-literal OrdinarySet, `f.toString = ...` would throw
// because Function.prototype.toString is non-writable. Cynic
// demotes each frozen prototype data slot into a synthetic
// accessor pair; the setter writes the value onto the receiver
// as an own data property.
//
// Spec-faithful pre-SES behaviour: V8 / JSC / SpiderMonkey
// silently install the shadow. SES with the override-mistake
// fix preserves that behaviour even though the prototype is
// now frozen.

const f = function () { return 1; };
f.toString = function () { return "shadowed"; };

if (f.toString() !== "shadowed") {
  throw new Error("override-mistake fix did not install shadow toString");
}

// The prototype itself stays untouched.
if (Function.prototype.toString === f.toString) {
  throw new Error("shadow leaked back onto Function.prototype");
}
