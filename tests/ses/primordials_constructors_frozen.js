// All primordial constructors are frozen too, not just their
// prototypes. Monkey-patching a constructor (e.g. adding a new
// static method) should fail under SES.

const ctors = [
  Object, Array, Function, String, Number, Boolean,
  Error, RegExp, Date, Map, Set, WeakMap, WeakSet,
  Promise, Symbol,
];

for (const C of ctors) {
  if (Object.isExtensible(C)) {
    throw new Error("primordial constructor unexpectedly extensible: " + C.name);
  }
}
