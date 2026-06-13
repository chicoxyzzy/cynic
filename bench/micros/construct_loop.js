// A hot function that constructs (`new Point`) and then does real
// arithmetic on the result. The A/B fixture behind the `new_call`
// codegen experiment (docs/ctor-array-build-gap.md L5).
//
// `step` does NOT tier up: `new_call` is dont_compile in Bistromath, so
// any constructing function stays interpreted. Two prototypes taught
// Bistromath to compile `new_call` — a general `constructValue` helper,
// then a full construct IC (`helperConstructDirect` + cached proto).
// Both were correct (differential + gc-stress clean) and both were a
// ~18-19% REGRESSION on this fixture (min-of-41, control-validated).
// The IC made no difference: the §10.1.14 proto walk it skips was never
// the cost. The real cost is the compiled construct running the ctor via
// a nested `runFrames`, while the interpreter's `new_call` pushes the
// construct frame and re-enters its dispatch loop in place. Closing that
// needs in-line frame-reentry (a major change), not an IC — see
// docs/ctor-array-build-gap.md L5. This fixture is the A/B for that work.
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
