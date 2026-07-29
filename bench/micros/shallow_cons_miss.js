// Eligible-miss control for Heap's bounded shallow ConsString memo.
// `tag` is a fresh flat string every iteration, so `prefix + tag`
// remains a shallow <=64-byte candidate but exact operand identity
// never repeats. This isolates the two-slot probe/publish overhead.
'use strict';
const prefix = "String for key ";
let total = 0;
let last = "";
for (let i = 0; i < 500_000; i++) {
    const tag = (i + 1_000_000).toString();
    last = prefix + tag;
    total += last.length;
}
print(total + last.length);
