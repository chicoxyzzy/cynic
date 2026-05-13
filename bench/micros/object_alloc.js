// Fresh-object allocation churn — every iteration produces a new
// JSObject + 2 string-keyed properties. Stresses heap allocation,
// GC frequency, and the property-bag write path.
let last = null;
for (let i = 0; i < 100_000; i++) {
    last = { a: i, b: i + 1 };
}
print(last.a + last.b);
