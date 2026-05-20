/* Minimal <stdlib.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt. */
#ifndef CYNIC_WASM_STDLIB_H
#define CYNIC_WASM_STDLIB_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *malloc(size_t size);
void free(void *ptr);
void *realloc(void *ptr, size_t size);
void *calloc(size_t nmemb, size_t size);

/* alloca is a compiler builtin — alias it so QuickJS's
 * `#include <alloca.h>` + bare `alloca` calls resolve. */
#define alloca __builtin_alloca

void abort(void) __attribute__((noreturn));
void exit(int status) __attribute__((noreturn));

int atoi(const char *nptr);
long atol(const char *nptr);
double atof(const char *nptr);
long strtol(const char *nptr, char **endptr, int base);
double strtod(const char *nptr, char **endptr);

char *getenv(const char *name);
void qsort(void *base, size_t nmemb, size_t size,
           int (*compar)(const void *, const void *));

#ifndef NULL
#define NULL ((void *)0)
#endif

#ifdef __cplusplus
}
#endif

#endif
