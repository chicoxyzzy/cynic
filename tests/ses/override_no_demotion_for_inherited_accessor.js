// The override-mistake fix demotes a frozen prototype's **data**
// slot into a synthetic accessor pair. It does NOT touch existing
// accessor slots — a getter-only inherited property has no setter,
// so assignment to the receiver throws TypeError per the spec
// §10.1.9.2 OrdinarySetWithOwnDescriptor step 4.d.
//
// This is the dual of the override-mistake fix: SES doesn't
// silently break legitimate getter-only inheritance just because
// the prototype was frozen.

const parent = {};
Object.defineProperty(parent, "x", {
  get() { return 1; },
  // no setter
  configurable: false,
  enumerable: true,
});
Object.freeze(parent);

const child = Object.create(parent);

let threw = false;
try {
  child.x = 2;
} catch (e) {
  threw = e instanceof TypeError;
}
if (!threw) {
  throw new Error(
    "assignment through getter-only inherited accessor did not throw"
  );
}

// The getter still returns the original value.
if (child.x !== 1) {
  throw new Error("getter return value changed unexpectedly");
}
