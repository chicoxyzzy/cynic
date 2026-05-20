/* Minimal <assert.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt. The WASM C is compiled with -DNDEBUG
 * so `assert` is a no-op; the non-NDEBUG branch is provided for
 * completeness and traps via __builtin_trap. */
#ifndef CYNIC_WASM_ASSERT_H
#define CYNIC_WASM_ASSERT_H

#undef assert
#ifdef NDEBUG
#define assert(expr) ((void)0)
#else
#define assert(expr) ((expr) ? (void)0 : __builtin_trap())
#endif

#ifndef static_assert
#define static_assert _Static_assert
#endif

#endif
