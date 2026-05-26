// **Known gap** — pin the current (buggy) behaviour of harden()
// on array indexed slots, per the comment in
// src/runtime/builtins/harden.zig:
//
//   "Array-exotic indexed slots (§10.4.2) live in `obj.elements`,
//    not `obj.properties`, so the bag-only walk below misses them.
//    The root array becomes non-extensible and the *values* at
//    each slot freeze transitively (good), but `a[0] = …` doesn't
//    throw on a hardened array because the slot's flags weren't
//    stamped."
//
// When the gap closes (harden grows an `Object.freeze`-style
// indexed-slot flag pass), this test should flip to assert that
// indexed writes throw TypeError.

const a = [1, 2, 3];
harden(a);

// The root array IS non-extensible (good — push() / new index
// throws on extend).
if (Object.isExtensible(a)) {
  throw new Error("hardened array unexpectedly extensible");
}

// Current gap: indexed write silently DOES NOT throw. Pin it so
// a fix is detected as a regression on this test.
let threw = false;
try {
  a[0] = 99;
} catch (e) {
  threw = true;
}

if (threw) {
  throw new Error(
    "harden indexed-slot gap appears closed — update this test " +
      "to assert TypeError on `a[0] = ...` and remove the pin"
  );
}
