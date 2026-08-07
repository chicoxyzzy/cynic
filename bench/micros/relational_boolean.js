// Primitive Boolean relational control. Parameters keep the comparison out of
// constant folding; the truthy countdown leaves one Boolean/Boolean
// JmpIfNotLt8 per iteration.
'use strict';

function run(left, right, limit) {
    let remaining = limit;
    let hits = 0;
    while (remaining) {
        if (left < right) hits = (hits + 1) | 0;
        remaining = (remaining - 1) | 0;
    }
    return hits;
}

print(run(false, true, 3_000_000));
