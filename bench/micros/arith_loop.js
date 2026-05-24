// Tight int32 arithmetic loop — exercises Op.add / Op.lt / Op.jmp
// dispatch density. Workload chosen so a fast interpreter finishes
// in a couple hundred ms.
//
// `"use strict"` matters for cross-engine comparison — JSC's PTC
// (and several other engine semantics) only fire in strict mode.
// Cynic is strict by default, so the directive is a no-op here.
'use strict';
let sum = 0;
for (let i = 0; i < 5_000_000; i++) {
    sum = (sum + i) | 0;
}
print(sum);
