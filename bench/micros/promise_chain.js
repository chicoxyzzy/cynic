// Promise reaction chain — every `.then` enqueues a microtask,
// every settlement allocates a fresh sub-Promise + reaction record.
// Stresses the microtask drain + GC under reaction churn.
let p = Promise.resolve(0);
for (let i = 0; i < 2000; i++) {
    p = p.then(v => v + 1);
}
p.then(v => print(v));
