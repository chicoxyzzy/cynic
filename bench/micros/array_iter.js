// for-of over a packed array — exercises iterator protocol +
// indexed reads on a §10.4.2 Array exotic.
'use strict';
const a = [];
for (let i = 0; i < 10_000; i++) a.push(i);
let sum = 0;
for (let pass = 0; pass < 100; pass++) {
    for (const v of a) sum = (sum + v) | 0;
}
print(sum);
