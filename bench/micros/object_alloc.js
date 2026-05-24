// Fresh-object allocation churn — every iteration produces a new
// JSObject + 2 string-keyed properties. Stresses heap allocation,
// GC frequency, and the property-bag write path.
// Iteration count picked so Cynic's wall-time is ~90 ms — at 100k
// iters the fixture was 23 ms with a 16 % spread (GC-cycle jitter
// dominates that small a window). 400k iters drops the relative
// spread well under 10 % across peers.
'use strict';
let last = null;
for (let i = 0; i < 400_000; i++) {
    last = { a: i, b: i + 1 };
}
print(last.a + last.b);
