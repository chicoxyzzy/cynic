// Promise reaction chain — every `.then` enqueues a microtask,
// every settlement allocates a fresh sub-Promise + reaction record.
// Stresses the microtask drain + GC under reaction churn.
// Iteration count picked so Cynic's wall-time is ~25 ms — at 2k
// iters the fixture was 5 ms, well below the spawn-overhead + timer-
// granularity floor that produced 20 % noise across peers in the
// cross-engine harness. Bumping further (15k flaky, 30k segfault)
// surfaces a separate Cynic bug in the reaction drain — see the
// upstream-gap log; the bench backs off until that's tracked down.
let p = Promise.resolve(0);
for (let i = 0; i < 10000; i++) {
    p = p.then(v => v + 1);
}
p.then(v => print(v));
