Minimal libc header stubs for the wasm32-freestanding build.

`zig build wasm` compiles the vendored QuickJS-NG C
(libregexp.c / libunicode.c / cutils.h) for `wasm32-freestanding`,
which has no system libc headers. Zig ships the compiler-provided
headers (stdarg.h, stdbool.h, stddef.h, stdint.h, float.h,
assert.h) but not the libc ones (stdlib.h, string.h, stdio.h,
inttypes.h, math.h, time.h, sys/time.h, alloca.h).

This directory supplies just-enough declarations of the symbols
the QuickJS sources reference. The actual implementations live in
`src/wasm_shim.c` (mem*/str*/malloc family) or are unused (the
stdio/time symbols are only reached from QuickJS test `main()`
functions gated behind `#ifdef TEST`, which are never compiled).

This directory is placed FIRST on the C include path for the WASM
build only — the native build keeps using the real system libc.
