// JSON.stringify hot loop — real-world workload that exercises
// own-property enumeration (Object.keys via the spec's
// EnumerableOwnProperties walk), recursive value serialization,
// and string concatenation. Different shape from the synthetic
// micros: tests the property *walk* path rather than property
// read/write specifically.
//
// Iteration count picked so wall time is ~60 ms. Useful proxy
// for any JS workload that touches `Object.keys(o).map(…)`,
// the React render diff, or any serialization path.
const obj = {
    name: "cynic",
    version: 0,
    features: ["esm", "promises", "iterators"],
    nested: { active: true, count: 42, tag: null },
};
let acc = 0;
for (let i = 0; i < 25_000; i++) {
    obj.version = i;
    obj.nested.count = i * 2;
    const s = JSON.stringify(obj);
    acc += s.length;
}
print(acc);
