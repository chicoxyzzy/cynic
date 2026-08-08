'use strict';
function mulAcc(n) {
    let i = n;
    let acc = 1;
    while (i) {
        acc = acc * 1;
        i = i - 1;
    }
    return acc + n;
}
const result = mulAcc(2_000_000);
if (result !== 2_000_001) throw new Error('mul_acc_loop produced ' + result);
print(result);
