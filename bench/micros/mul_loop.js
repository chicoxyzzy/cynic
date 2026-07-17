// Tight numeric multiplication loop. One operand stays Int32 and the other is
// a Double, exercising Lantern's per-site raw operand profile and fused Number
// path on every iteration without letting the compiler fold the product.
'use strict';
function run() {
    let product = 0;
    let value = 1;
    const factor = 1.0000001;
    for (let i = 0; i < 3_000_000; i++) {
        product = value * factor;
        value = (value + 1) | 0;
    }
    return product;
}
print(run());
