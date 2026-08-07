// Arbitrary-precision StringToBigInt relational control. The values straddle
// the u128 boundary, pinning the validated handoff to the full parser.
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

print(
    run(
        340282366920938463463374607431768211455n,
        '340282366920938463463374607431768211456',
        200_000,
    ),
);
