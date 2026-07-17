// Stable receiver shape trains one monomorphic named-load IC before T2 takes
// over. Keeping the load in a leaf isolates generated property-read code from
// the unsupported call loop that drives it.
'use strict';
function readX(object) {
    return object.x;
}

const object = { x: 17, y: 23 };
let result = 0;
for (let i = 0; i < 5_000_000; i++) {
    result = readX(object);
}
if (result !== 17) {
    throw new Error('named_load produced an invalid result');
}
print(result);
