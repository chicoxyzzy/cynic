// A hot function that constructs (`new Point`) and then does real
// arithmetic on the result. The A/B fixture behind the `new_call`
// codegen experiment (docs/ctor-array-build-gap.md L5).
//
// `step` currently does NOT tier up: `new_call` is dont_compile in
// Bistromath, so any constructing function stays interpreted. A
// prototype taught Bistromath to compile `new_call` (routing the
// construct through the shared `constructValue` helper); it was
// correct (differential + gc-stress clean) but a measured REGRESSION
// — ~18% slower than interpreted on this fixture — because the
// compiled path takes the general [[Construct]] every time, while the
// interpreter's `new_call` has an inline construct-IC fast path
// (cached callee + prototype, no GetPrototypeFromConstructor walk).
// Compiling construct only pays off with a compiled construct IC; the
// general-helper form is net-negative, so it stays dont_compile. This
// fixture is the A/B for when the IC lands.
//
// Iteration count picked so wall time is a couple hundred ms.
'use strict';
function Point(x, y) {
    this.x = x;
    this.y = y;
}
function step(i) {
    const p = new Point(i, i + 1);
    let s = (p.x + p.y) | 0;
    s = (s * 3 + i) | 0;
    s = (s ^ (s + 7)) | 0;
    return s;
}
let acc = 0;
for (let i = 0; i < 1_500_000; i++) {
    acc = (acc + step(i)) | 0;
}
print(acc);
