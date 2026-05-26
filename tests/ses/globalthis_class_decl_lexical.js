// Top-level `class` is lexical (like let / const), so the SES
// frozen-globalThis posture doesn't matter — the class binds into
// the script-scope declarative env, not onto globalThis.

class CynicTopLevelClass {
  static greet() { return "hi"; }
}

if (typeof CynicTopLevelClass !== "function") {
  throw new Error("top-level class did not bind");
}
if (CynicTopLevelClass.greet() !== "hi") {
  throw new Error("class static did not resolve");
}

// Class names don't surface on globalThis.
if ("CynicTopLevelClass" in globalThis) {
  throw new Error("top-level class leaked onto globalThis");
}
