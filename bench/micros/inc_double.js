// Fractional Double register updates. The parameter keeps the value outside
// Int32 so every IncReg / DecReg reaches incOrDec's Double arm.
'use strict';

function run(limit, value) {
    for (let i = 0; i < limit; i++) {
        value++;
        value--;
    }
    return value;
}

print(run(4_000_000, 0.5));
