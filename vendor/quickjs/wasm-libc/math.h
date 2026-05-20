/* Minimal <math.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt.
 *
 * cutils.h uses NAN / INFINITY / isnan / isinf inside inline
 * float16-conversion helpers. libregexp / libunicode do not call
 * libm directly. Everything here maps to a compiler builtin so no
 * libm link is required. */
#ifndef CYNIC_WASM_MATH_H
#define CYNIC_WASM_MATH_H

#ifndef NAN
#define NAN __builtin_nanf("")
#endif
#ifndef INFINITY
#define INFINITY __builtin_inff()
#endif
#ifndef HUGE_VAL
#define HUGE_VAL __builtin_huge_val()
#endif

#define isnan(x)  __builtin_isnan(x)
#define isinf(x)  __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#define signbit(x) __builtin_signbit(x)

#define fabs(x)      __builtin_fabs(x)
#define fabsf(x)     __builtin_fabsf(x)
#define floor(x)     __builtin_floor(x)
#define ceil(x)      __builtin_ceil(x)
#define round(x)     __builtin_round(x)
#define trunc(x)     __builtin_trunc(x)
#define sqrt(x)      __builtin_sqrt(x)
#define pow(x, y)    __builtin_pow(x, y)
#define copysign(x, y) __builtin_copysign(x, y)
#define ldexp(x, e)  __builtin_ldexp(x, e)
#define nextafter(x, y) __builtin_nextafter(x, y)
#define scalbn(x, e) __builtin_scalbn(x, e)

/* frexp has an out-parameter — a macro can't express it; declare
 * the builtin. cutils.h uses it only in float16 helpers, which
 * libregexp / libunicode never call. */
double frexp(double x, int *exp);

#endif
