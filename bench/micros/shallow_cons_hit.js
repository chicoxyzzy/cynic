// Exact-hit control for Heap's bounded shallow ConsString memo.
// This is the two-pair expression shape repeated by all 32 leaves in
// each Splay payload tree. After the first iteration, both concatenations
// reuse their exact immutable operand pairs.
'use strict';
const prefix = "String for key ";
const tag = "0.1234567890123456";
const suffix = " in leaf node";
let total = 0;
for (let i = 0; i < 500_000; i++) {
    const inner = prefix + tag;
    const outer = inner + suffix;
    total += outer.length;
}
print(total);
