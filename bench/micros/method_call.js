// Hot method dispatch — `obj.method()` in a tight loop. Exercises
// both the call_method IC (callee cache) and the prototype-load IC
// (the method is on the receiver's prototype, not own). With both
// ICs warm, the fast path is shape pointer compare + slot load +
// direct callJSFunction; without them, every iteration walks the
// chain for the lookup AND dispatches the proxy / revocable /
// bound exotic-callee checks.
//
// Iteration count picked so wall time is ~50 ms on a warm IC,
// well above the spawn-overhead floor.
class Counter {
    constructor() { this.n = 0; }
    inc() { this.n += 1; return this.n; }
}
const c = new Counter();
let acc = 0;
for (let i = 0; i < 500_000; i++) {
    acc = c.inc();
}
print(acc);
