// globalThis is fully frozen under the SES default, not merely
// non-extensible. The realm-init freeze runs during installBuiltins;
// any debug globals added later by installTestGlobals are re-stamped
// non-writable / non-configurable so the freeze contract still holds
// for the test harness. A production realm therefore reports
// Object.isFrozen(globalThis) === true. (Top-level const/let here
// bind in the declarative environment record, not on globalThis, so
// asserting this from plain script is sound.)

if (!Object.isFrozen(globalThis)) {
  throw new Error("globalThis is not frozen under the SES default");
}
