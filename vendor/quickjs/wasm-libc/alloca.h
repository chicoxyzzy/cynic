/* Minimal <alloca.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt. `alloca` maps to the compiler builtin
 * (also #define'd in this directory's stdlib.h). */
#ifndef CYNIC_WASM_ALLOCA_H
#define CYNIC_WASM_ALLOCA_H

#ifndef alloca
#define alloca __builtin_alloca
#endif

#endif
