'use strict';
function sum(n) {
    let i = n;
    let acc = 0;
    while (i) {
        acc = acc + 1;
        if (acc === 1_000) acc = 0;
        i = i - 1;
    }
    return acc;
}
const result = sum(2_000_000);
if (result !== 0) throw new Error('sum_loop produced ' + result);
print(result);
