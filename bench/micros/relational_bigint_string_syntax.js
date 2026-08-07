// Non-decimal StringToBigInt relational control. Three invocations keep
// whitespace, signed decimal, and radix-prefixed spellings in the measured
// path while leaving one BigInt/String JmpIfNotLt8 per iteration.
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
    run(1n, ' 2 ', 333_333) +
        run(-2n, '-1', 333_333) +
        run(0n, '0x10', 333_334),
);
