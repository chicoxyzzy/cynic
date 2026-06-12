// Dense array-literal construction + indexed read in a tight loop —
// exercises the fused `make_array_n` opcode (the `[a, b, c]` literal)
// and `lda_computed` (the int32-keyed `a[i]` read) on the Bistromath
// fast path. Unlike ctor_array_build there is no `new`, so the loop
// body is array-gated, not construct-gated: every opcode is in
// Bistromath's compilable set, so the whole loop tiers up. The A/B is
// whether compiling these two opcodes beats staying interpreted, given
// the per-iteration array allocation (shared `Heap.makeDenseArray`,
// identical in both tiers) is a fixed cost the dispatch saving competes
// against.
//
// Iteration count picked so wall time is a couple hundred ms.
'use strict';
let acc = 0;
for (let i = 0; i < 3_000_000; i++) {
    const a = [(i + 1) | 0, (i + 2) | 0, (i + 3) | 0];
    acc = (acc + a[0] + a[1] + a[2]) | 0;
}
print(acc);
