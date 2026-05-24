// Deep tail recursion — exercises §15.10 PTC frame-reuse on the
// `tail_call` opcode. Workload sized so the recursion would
// trivially blow the 1024-frame stack ceiling without PTC; with
// PTC the same call site runs in one frame and the iteration
// count dominates the timing.
//
// Requires the `tail-call-optimization` feature flag — the bench
// driver enables every tracked feature. With the flag off the
// compiler emits ordinary `call` and the script throws
// RangeError instead of finishing.
function sum(n, acc) {
  return n === 0 ? acc : sum(n - 1, acc + 1);
}
print(sum(1000000, 0));
