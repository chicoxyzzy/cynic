// Under `--unhardened`, globalThis is extensible and intrinsic
// constructors are writable. The corresponding hardened tests
// (`globalthis_intrinsic_rebind_throws.js`,
// `globalthis_add_new_property_throws.js`) assert the inverse.

if (!Object.isExtensible(globalThis)) {
  throw new Error("globalThis unexpectedly non-extensible under --unhardened");
}

// New property on globalThis should succeed (no throw).
globalThis.cynicUnhardenedNew = 42;
if (globalThis.cynicUnhardenedNew !== 42) {
  throw new Error("globalThis property add failed under --unhardened");
}

// Intrinsic constructors should be writable.
const original_array = globalThis.Array;
globalThis.Array = "stomped";
if (globalThis.Array !== "stomped") {
  throw new Error("intrinsic rebind failed under --unhardened");
}
// Put it back so subsequent tests in the same realm (if any)
// don't see a corrupted Array. Single-fixture runs make this
// belt-and-suspenders.
globalThis.Array = original_array;
