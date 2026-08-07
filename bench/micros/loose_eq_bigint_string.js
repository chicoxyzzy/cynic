// Mixed BigInt/String loose-equality control. Parameters keep both operand
// orders out of constant folding; two comparisons per iteration pin
// §7.2.14 StringToBigInt parsing through the interpreter's allocating path.
'use strict';

function run(bigint, string, limit) {
    let remaining = limit;
    let hits = 0;
    while (remaining) {
        if (bigint == string) hits = (hits + 1) | 0;
        if (string == bigint) hits = (hits + 1) | 0;
        remaining = (remaining - 1) | 0;
    }
    return hits;
}

print(run(1n, '1', 125_000));
