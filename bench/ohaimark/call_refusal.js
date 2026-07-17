// The wrapper's call opcode is intentionally outside Ohaimark's current IR.
// It should be refused once and remain on Bistromath, while the arithmetic
// callee publishes into T2. This measures refusal economics on a call-heavy
// shape without forcing thresholds or manufacturing a compiler success.
'use strict';
function multiply(value, factor) {
    return value * factor;
}
function invoke(callback, value, factor) {
    return callback(value, factor);
}

let result = 0;
for (let i = 0; i < 5_000_000; i++) {
    result = invoke(multiply, i + 0.5, 1.0000001);
}
if (!(result > 4_999_999 && result < 5_000_001)) {
    throw new Error('call_refusal produced an invalid result');
}
print(result);
