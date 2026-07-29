// Tight numeric remainder loop. Both operands stay Int32, the dividend
// changes to prevent constant folding, and the checksum keeps every result
// observable while exercising Lantern's direct Number::remainder path.
'use strict';
function run() {
    let checksum = 0;
    let dividend = 1;
    const divisor = 97;
    for (let i = 0; i < 3_000_000; i++) {
        checksum = (checksum + (dividend % divisor)) | 0;
        dividend = (dividend + 1) | 0;
    }
    return checksum;
}
print(run());
