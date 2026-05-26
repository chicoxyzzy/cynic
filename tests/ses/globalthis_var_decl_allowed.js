// Cynic carve-out (commit 3a4be3c): top-level `var` declarations
// succeed under hardened mode even though globalThis is
// non-extensible. The §9.1.1.4.15 CanDeclareGlobalVar /
// §9.1.1.4.16 CanDeclareGlobalFunction algorithms intentionally
// skip the extensibility check in the SES posture, so script-
// and module-mode top-level decls keep working in code that
// wasn't written with SES in mind.
//
// This is one of the entries in
// `tools/test262/ses_divergent.zig` under the
// `intentional_design_carveout` category.

var cynicTopLevelVar = 42;

if (cynicTopLevelVar !== 42) {
  throw new Error("top-level var did not bind");
}
if (globalThis.cynicTopLevelVar !== 42) {
  throw new Error("top-level var did not surface on globalThis");
}
