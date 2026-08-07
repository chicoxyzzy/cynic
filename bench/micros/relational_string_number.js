// Mixed String/Number relational control. Parameters keep the comparison out
// of constant folding; the truthy countdown leaves one String/Number
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

print(run('1', 2, 1_000_000));
