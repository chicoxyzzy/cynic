// The primordial namespace objects — Math, JSON, Reflect, Atomics —
// are frozen at realm init under the SES default. They are neither
// constructors nor prototypes, so they are a distinct frozen surface
// from primordials_constructors_frozen.js / _prototypes_frozen.js:
// Object.isFrozen must hold (every own method non-writable +
// non-configurable, the object non-extensible), so swapping
// Math.random or adding JSON.parse5 is impossible.

const namespaces = { Math, JSON, Reflect, Atomics };

for (const name of Object.keys(namespaces)) {
  if (!Object.isFrozen(namespaces[name])) {
    throw new Error("primordial namespace object not frozen: " + name);
  }
}
