// Hot property reads — every `.x` is an ArrayHashMap lookup today.
// Inline-cache work would collapse this; this bench is the
// before-picture.
const o = { x: 0, y: 1, z: 2, w: 3 };
let acc = 0;
for (let i = 0; i < 500_000; i++) {
    acc = acc + o.x + o.y + o.z + o.w;
}
print(acc);
