// Primitive Number relational loop. The first loop compares Double/Int32;
// the second compares Double/Double. Both compile their sole loop condition
// to JmpIfNotLt8, isolating Lantern's fused Number comparison fast path.
'use strict';

function runMixed(limit) {
    let value = 0.5;
    let count = 0;
    while (value < limit) {
        value = value + 1;
        count = (count + 1) | 0;
    }
    return count;
}

function runDouble(limit) {
    let value = 0.25;
    let count = 0;
    while (value < limit) {
        value = value + 1;
        count = (count + 1) | 0;
    }
    return count;
}

print(runMixed(1_000_000) + runDouble(1_000_000.75));
