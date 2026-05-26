// Top-level `let` is lexical, not var — it binds into the script
// scope but does NOT install a property on globalThis. The SES
// frozen-globalThis posture doesn't apply (no extensibility
// check is involved), so this works the same as it would under
// any spec-conforming engine.

let cynicTopLevelLet = 42;

if (cynicTopLevelLet !== 42) {
  throw new Error("top-level let did not bind");
}

// Critically: `let` does NOT surface on globalThis.
if ("cynicTopLevelLet" in globalThis) {
  throw new Error("top-level let leaked onto globalThis");
}
if (globalThis.cynicTopLevelLet !== undefined) {
  throw new Error("top-level let surfaced as globalThis property");
}
