'use strict';
function sum(n) {
    let i = n;
    let acc = 0;
    while (i) {
        i = i - 1;
        acc = acc + i;
    }
    return acc;
}
const result = sum(2_000_000);
// (n-1)+...+0 = n*(n-1)/2
const expected = 2_000_000 * (2_000_000 - 1) / 2;
if (result !== expected) throw new Error('sum_loop produced ' + result);
print(result);
