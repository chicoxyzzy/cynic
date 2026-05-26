// `delete globalThis.Array` must throw under SES (Array is
// non-configurable on the frozen globalThis). Strict-mode
// `delete` of a non-configurable property is always a TypeError
// per §13.5.1.2; Cynic is strict-only.

let threw = false;
try {
  delete globalThis.Array;
} catch (e) {
  threw = e instanceof TypeError;
}

if (!threw) {
  throw new Error("delete globalThis.Array did not throw TypeError");
}

// And Array still works.
if (typeof Array !== "function" || !Array.isArray([])) {
  throw new Error("Array binding corrupted despite rejected delete");
}
