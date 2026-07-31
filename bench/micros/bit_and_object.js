// Object-coercion binary bitwise AND loop. The RHS emits
// LdaSmi16 -> BitAnd, but the object LHS must decline primitive-Number
// successor threading and run the ordinary ToNumeric/valueOf path.
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
