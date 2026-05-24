// Deep tail recursion — exercises §15.10 PTC frame-reuse on the
// `tail_call` opcode. Workload sized so the recursion would
// trivially blow the 1024-frame stack ceiling without PTC; with
// PTC the same call site runs in one frame and the iteration
// count dominates the timing.
//
// `"use strict"` is mandatory: per spec PTC only fires in strict
// code, and JSC (the only other PTC-shipping engine) follows the
// letter. Without it this fixture errors on JSC in the cross-
// engine harness; without it on most engines the script throws
// RangeError at the 1024-frame stack ceiling. Cynic is always
// strict, so the directive is a no-op here.
'use strict';
function sum(n, acc) {
  return n === 0 ? acc : sum(n - 1, acc + 1);
}
print(sum(1000000, 0));
