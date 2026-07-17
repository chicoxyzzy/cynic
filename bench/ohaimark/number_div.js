// Number-specialized division under the same repeated-entry shape as
// number_mul. Compilation time is part of the measured child lifetime.
'use strict';
function divide(a, b) {
    return a / b;
}

let result = 0;
for (let i = 0; i < 5_000_000; i++) {
    result = divide(i + 0.5, 3);
}
if (!(result > 1_666_665 && result < 1_666_667)) {
    throw new Error('number_div produced an invalid result');
}
print(result);
