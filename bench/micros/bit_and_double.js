// Double-heavy binary bitwise AND loop. The RHS emits LdaSmi16 -> BitAnd,
// while adding 0.5 after every result keeps the next LHS outside Int32.
// This pins one failed Int32 probe plus the shared ToNumeric / ToInt32
// fallback on every iteration.
'use strict';
function run() {
    let value = 0.5;
    for (let i = 0; i < 5_000_000; i++) {
        value = (value & 32767) + 0.5;
    }
    return value;
}
print(run());
