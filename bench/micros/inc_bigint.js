// Primitive BigInt register updates. Each IncReg / DecReg reaches incOrDec's
// BigInt arm and allocates the type-matched bumped value.
'use strict';

function run(limit, value) {
    for (let i = 0; i < limit; i++) {
        value++;
        value--;
    }
    return value;
}

print(run(500_000, 0n));
