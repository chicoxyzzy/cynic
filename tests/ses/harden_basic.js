// harden() deep-freezes a reachable object graph. After
// hardening, every reachable own property is non-writable +
// non-configurable, and every reachable object is
// non-extensible.

const o = { a: 1, b: { c: 2 } };
harden(o);

if (Object.isExtensible(o)) {
  throw new Error("harden did not lock extensibility on root");
}
if (Object.isExtensible(o.b)) {
  throw new Error("harden did not traverse into nested object");
}

const dA = Object.getOwnPropertyDescriptor(o, "a");
if (dA.writable !== false) {
  throw new Error("harden left a.writable === true");
}
if (dA.configurable !== false) {
  throw new Error("harden left a.configurable === true");
}

const dC = Object.getOwnPropertyDescriptor(o.b, "c");
if (dC.writable !== false || dC.configurable !== false) {
  throw new Error("harden did not lock nested own properties");
}
