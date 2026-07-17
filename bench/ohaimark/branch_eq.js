// A tiny strict-equality branch exercises control-flow graph construction,
// tagged comparison lowering, and direct completion from both successor
// blocks. Alternating inputs keeps both paths live after tier-up.
'use strict';
function select(equal, different) {
    if (equal === different) return equal;
    return different;
}

let result = 0;
for (let i = 0; i < 2_500_000; i++) {
    result = select(i, i);
    result = select(result, i + 1);
}
if (result !== 2_500_000) {
    throw new Error('branch_eq produced an invalid result');
}
print(result);
