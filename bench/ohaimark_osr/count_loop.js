// Single call, hot backedges — only OSR can promote the body to T2.
// Countdown via truthiness (no relational op) so the current Ohaimark
// opcode surface can compile the loop (docs/ohaimark.md §3.17).
'use strict';
function count(n) {
    let i = n;
    let acc = 0;
    while (i) {
        acc = acc + 1;
        i = i - 1;
    }
    return acc;
}
const result = count(5_000_000);
if (result !== 5_000_000) throw new Error('count_loop produced ' + result);
print(result);
