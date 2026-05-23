// Hot property writes — every `.x = ...` is a property-bag put
// today, plus a shadow shape update on top now that hidden classes
// landed. Inline-cache work on `sta_property` collapses the hash
// lookup and the exotic / accessor walk; this is the mirror of
// `prop_access` for the write side.
const o = { x: 0, y: 1, z: 2, w: 3 };
for (let i = 0; i < 500_000; i++) {
    o.x = i;
    o.y = i + 1;
    o.z = i + 2;
    o.w = i + 3;
}
print(o.x + o.y + o.z + o.w);
