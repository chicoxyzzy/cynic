// Companion to globalthis_var_decl_allowed: top-level function
// declarations are part of the same SES carve-out and also
// succeed against a non-extensible globalThis.

function cynicTopLevelFn() { return "ok"; }

if (typeof cynicTopLevelFn !== "function") {
  throw new Error("top-level function did not bind");
}
if (cynicTopLevelFn() !== "ok") {
  throw new Error("top-level function did not call");
}
if (globalThis.cynicTopLevelFn !== cynicTopLevelFn) {
  throw new Error("top-level function did not surface on globalThis");
}
