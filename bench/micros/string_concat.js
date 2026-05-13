// String allocation churn — each `+` allocates a fresh JSString.
// Stresses the GC trigger and string-pool growth.
let s = "";
for (let i = 0; i < 5000; i++) {
    s = s + (i & 0xff).toString();
}
print(s.length);
