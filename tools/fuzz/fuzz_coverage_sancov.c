/* Stub definition for LLVM SanitizerCoverage's per-function
 * stack-depth probes. With `-fsanitize-coverage=trace-pc-guard`
 * enabled, LLVM emits references to `__sancov_lowest_stack` —
 * a thread-local that records the lowest stack pointer ever
 * observed. Fuzzilli's REPRL profile doesn't read this value
 * (it consumes only the edge bitmap), but the linker needs the
 * symbol defined.
 *
 * Defining the variable in C rather than Zig sidesteps a
 * Zig-on-macOS quirk: Zig's `export threadlocal var` emits a
 * TLS thunk with a uniqued data label, but LLVM's sancov pass
 * generates references to `__sancov_lowest_stack.<id>` (the
 * `__thread_data` label clang uses). C's `__thread` storage
 * class produces the exact symbol layout LLVM expects, so the
 * link resolves cleanly.
 *
 * Linked only into `cynic-fuzz` via `build.zig`; the regular
 * `cynic` binary ships without it.
 */

#include <stdint.h>

__thread uintptr_t __sancov_lowest_stack;
