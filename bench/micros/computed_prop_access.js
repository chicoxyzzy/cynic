// Monomorphic computed-string reads. Keep the key in a function parameter so
// the compiler emits `lda_computed` rather than the named-property opcode;
// this is the control for changes that route around the computed-key IC.
'use strict';
function sumComputed(o, key, n) {
    let sum = 0;
    for (let i = 0; i < n; i++) {
        sum = (sum + o[key]) | 0;
    }
    return sum;
}

const o = { value: 7 };
print(sumComputed(o, 'value', 3_000_000));
