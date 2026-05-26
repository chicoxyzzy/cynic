// harden() on a primitive value returns the value unchanged.
// Primitives have no heap identity (no `[[Extensible]]` slot), so
// there's nothing to freeze — the walker bails before any work.

if (harden(42) !== 42) throw new Error("harden(number) regression");
if (harden("string") !== "string") throw new Error("harden(string) regression");
if (harden(true) !== true) throw new Error("harden(true) regression");
if (harden(false) !== false) throw new Error("harden(false) regression");
if (harden(null) !== null) throw new Error("harden(null) regression");
if (harden(undefined) !== undefined) throw new Error("harden(undefined) regression");

const sym = Symbol("k");
if (harden(sym) !== sym) throw new Error("harden(symbol) regression");

if (harden(1n) !== 1n) throw new Error("harden(bigint) regression");
