// Tight numeric division loop. The numerator and divisor stay Int32 while the
// result is a Double, exercising Lantern's per-site raw operand profile on
// every iteration without letting the compiler fold the division.
'use strict';
function run() {
    let quotient = 0;
    let numerator = 1;
    const divisor = 3;
    for (let i = 0; i < 3_000_000; i++) {
        quotient = numerator / divisor;
        numerator = (numerator + 1) | 0;
    }
    return quotient;
}
print(run());
