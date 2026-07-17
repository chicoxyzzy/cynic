// Repeated leaf calls cross Ohaimark's natural function-entry threshold after
// Bistromath has already compiled the function and arithmetic feedback is
// mature. The result depends on the final input, preventing constant folding.
'use strict';
function multiply(a, b) {
    return a * b;
}

let result = 0;
for (let i = 0; i < 5_000_000; i++) {
    result = multiply(i + 0.5, 1.0000001);
}
if (!(result > 4_999_999 && result < 5_000_001)) {
    throw new Error('number_mul produced an invalid result');
}
print(result);
