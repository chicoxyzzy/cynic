// Tight int32 arithmetic loop — exercises Op.add / Op.lt / Op.jmp
// dispatch density. Workload chosen so a fast interpreter finishes
// in a couple hundred ms.
let sum = 0;
for (let i = 0; i < 5_000_000; i++) {
    sum = (sum + i) | 0;
}
print(sum);
