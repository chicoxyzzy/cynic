/* Minimal <stdio.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt.
 *
 * The QuickJS sources reference printf / fprintf only from debug
 * dump code (DUMP_REOP) and from #ifdef TEST main() functions.
 * `FILE` / `stdout` / `stderr` are declared so those lines parse;
 * the shim's printf/fprintf are no-ops. */
#ifndef CYNIC_WASM_STDIO_H
#define CYNIC_WASM_STDIO_H

#include <stddef.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _CYNIC_FILE FILE;
extern FILE *stdout;
extern FILE *stderr;
extern FILE *stdin;

int printf(const char *format, ...);
int fprintf(FILE *stream, const char *format, ...);
int snprintf(char *str, size_t size, const char *format, ...);
int vsnprintf(char *str, size_t size, const char *format, va_list ap);
int fputs(const char *s, FILE *stream);
int putchar(int c);

#ifndef EOF
#define EOF (-1)
#endif

#ifdef __cplusplus
}
#endif

#endif
