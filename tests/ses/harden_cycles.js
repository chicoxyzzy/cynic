// harden() terminates on cyclic object graphs — the traversal
// must mark visited objects so it doesn't recurse forever.

const a = {};
const b = {};
a.b = b;
b.a = a;

harden(a);

if (Object.isExtensible(a)) {
  throw new Error("harden did not freeze a");
}
if (Object.isExtensible(b)) {
  throw new Error("harden did not traverse cycle to b");
}
