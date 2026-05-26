// Re-assigning a globalThis-rooted intrinsic constructor throws
// TypeError under SES — the constructors are installed as
// non-writable + non-configurable data slots on the frozen
// globalThis, so `globalThis.Array = X` fails the spec's
// OrdinarySet step that rejects writes to non-writable slots.

let threw = false;
try {
  globalThis.Array = "stomped";
} catch (e) {
  threw = e instanceof TypeError;
}
if (!threw) {
  throw new Error("globalThis.Array reassignment did not throw TypeError");
}

// `Array` still points at the original constructor.
if (typeof Array !== "function" || !Array.isArray([])) {
  throw new Error("Array binding was corrupted despite the rejected assignment");
}
