// Object-coercion binary bitwise AND loop. The RHS emits
// LdaSmi16 -> BitAnd; successor threading must enter the shared
// ToNumeric/valueOf path exactly once on every iteration.
'use strict';
const operand = {
    valueOf() {
        return 32769;
    },
};
let masked = 0;
for (let i = 0; i < 1_000_000; i++) {
    masked = operand & 32767;
}
print(masked);
