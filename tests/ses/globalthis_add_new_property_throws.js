// Assigning to a brand-new property on globalThis (via direct
// member assignment, not a top-level `var` decl) must throw under
// SES: globalThis is non-extensible, so OrdinarySet's
// CreateDataProperty step fails per §10.1.9.
//
// The carve-out for top-level `var` / `function` (which Cynic
// deliberately preserves for sloppy web-compat reasons —
// `cynic run somescript.js` should work even when `somescript.js`
// declares `var foo = 1`) only kicks in for actual top-level
// declarations, not arbitrary property writes.

let threw = false;
try {
  globalThis.cynicBrandNewPropertyAtRuntime = 42;
} catch (e) {
  threw = e instanceof TypeError;
}

if (!threw) {
  throw new Error(
    "globalThis.cynicBrandNewPropertyAtRuntime = ... did not throw"
  );
}

// And the property wasn't installed.
if ("cynicBrandNewPropertyAtRuntime" in globalThis) {
  throw new Error("the rejected assignment partially installed the property");
}
