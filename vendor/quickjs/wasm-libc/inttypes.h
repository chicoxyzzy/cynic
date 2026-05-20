/* Minimal <inttypes.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt. Just the printf-format macros plus a
 * pull-through of <stdint.h> (compiler-provided). */
#ifndef CYNIC_WASM_INTTYPES_H
#define CYNIC_WASM_INTTYPES_H

#include <stdint.h>

#define PRId8  "d"
#define PRId16 "d"
#define PRId32 "d"
#define PRId64 "lld"
#define PRIu8  "u"
#define PRIu16 "u"
#define PRIu32 "u"
#define PRIu64 "llu"
#define PRIx8  "x"
#define PRIx16 "x"
#define PRIx32 "x"
#define PRIx64 "llx"
#define PRIX32 "X"
#define PRIX64 "llX"
#define PRIi32 "i"
#define PRIi64 "lli"

#endif
