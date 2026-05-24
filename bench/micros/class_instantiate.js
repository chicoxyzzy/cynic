// `new Class(args)` allocation churn — exercises class
// instantiation: `OrdinaryCreateFromConstructor` (proto lookup +
// fresh JSObject + prototype wire), constructor body execution
// (the `this.x = …` writes go through sta_property's write IC),
// frame setup, and the literal-shape template cache (if the
// constructor body uses property writes that benefit from
// shape stability).
//
// Companion to object_alloc but for class-based allocation.
// Real-world equivalent: React `createElement`, `new Date()`
// in formatting loops, `new URL()` parsers.
//
// Iteration count picked so wall time is ~60 ms.
class Point {
    constructor(x, y) {
        this.x = x;
        this.y = y;
    }
}
let last = null;
for (let i = 0; i < 400_000; i++) {
    last = new Point(i, i + 1);
}
print(last.x + last.y);
