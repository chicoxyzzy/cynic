// Constructor write IC vs. array-literal construction in the same
// hot loop — the common `const p = new Point(x, y); const a = [p.x,
// p.y, …]` shape (think a parser emitting node tuples, a render loop
// building child arrays, a serializer packing rows).
//
// `make_array` used to install the array exotic's §23.1.4 `length`
// through `setWithFlags`, whose non-default branch bumps the global
// transition-write-IC invalidation epoch. A fresh array literal is
// never a prototype, so that bump was a false positive: it deopted
// the constructor's `this.x = …` transition IC on every iteration,
// forcing the slow `strictSetProperty` → `lookupAccessor`
// prototype-chain walk. This fixture stays on the IC fast path only
// when array construction leaves the epoch alone.
//
// Iteration count picked so wall time is ~60 ms.
'use strict';
class Point {
    constructor(x, y) {
        this.x = x;
        this.y = y;
    }
}
let acc = 0;
for (let i = 0; i < 1_500_000; i++) {
    const p = new Point(i & 255, i & 127);
    const a = [p.x, p.y, (i >> 2) & 255];
    acc += a[0] + a[1] + a[2];
    if ((i & 4095) === 0) acc &= 0x7fffffff;
}
print(acc);
