// Two-limb StringToBigInt relational control. The values straddle the u64
// boundary, pinning the allocation-free wide parser and exact comparison.
'use strict';

function run(left, right, limit) {
    let remaining = limit;
    let hits = 0;
    while (remaining) {
        if (left < right) hits = (hits + 1) | 0;
        remaining = (remaining - 1) | 0;
    }
    return hits;
}

print(run(18446744073709551615n, '18446744073709551616', 1_000_000));
