// Re-hardening an already-frozen object is a no-op: the visited
// set short-circuits before any flag stamping, so the value and
// descriptor are unchanged.

const o = { x: 1, y: { nested: true } };
harden(o);

const desc_before = Object.getOwnPropertyDescriptor(o, "x");
const ext_before = Object.isExtensible(o);

harden(o);

const desc_after = Object.getOwnPropertyDescriptor(o, "x");
const ext_after = Object.isExtensible(o);

if (desc_before.value !== desc_after.value) {
  throw new Error("re-harden mutated value");
}
if (desc_before.writable !== desc_after.writable) {
  throw new Error("re-harden flipped writable bit");
}
if (desc_before.configurable !== desc_after.configurable) {
  throw new Error("re-harden flipped configurable bit");
}
if (ext_before !== ext_after) {
  throw new Error("re-harden flipped extensibility");
}
