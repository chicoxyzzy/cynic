// Coercible-object relational control. The loop condition uses ToBoolean,
// leaving exactly one object/Number JmpIfNotLt8 comparison per iteration.
// `valueOf` must remain on the shared IsLessThan coercion path and run once.
'use strict';

function run(limit) {
    const operand = {
        valueOf() {
            return 0.5;
        },
    };
    let remaining = limit;
    let hits = 0;
    while (remaining) {
        if (operand < 1) hits = (hits + 1) | 0;
        remaining = (remaining - 1) | 0;
    }
    return hits;
}

print(run(250_000));
