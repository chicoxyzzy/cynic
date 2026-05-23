// String allocation churn — each `+` allocates a fresh JSString.
// Stresses the GC trigger and string-pool growth.
// Iteration count picked so Cynic's wall-time is ~70 ms. At 5k iters
// the fixture was 4 ms (spawn-overhead-dominated, 14 % spread on
// jsc); ConsString ropes scale this sub-linearly (12× work was 4×
// time), so the bump needs to be larger than naive arithmetic
// suggests. 300k brings Cynic to ~70 ms.
let s = "";
for (let i = 0; i < 300000; i++) {
    s = s + (i & 0xff).toString();
}
print(s.length);
