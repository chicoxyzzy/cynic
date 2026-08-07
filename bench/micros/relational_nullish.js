// Undefined/null relational control. Parameters keep the comparison out of
// constant folding; the truthy countdown leaves one undefined/null
// JmpIfNotLt8 per iteration and pins the undefined-to-false result.
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

print(run(undefined, null, 3_000_000));
