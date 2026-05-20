/* Minimal <unistd.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt. cutils.h includes it for the POSIX
 * process helpers; libregexp / libunicode reference none of them. */
#ifndef CYNIC_WASM_UNISTD_H
#define CYNIC_WASM_UNISTD_H

#include <stddef.h>

typedef long ssize_t;

int usleep(unsigned int usec);
unsigned int sleep(unsigned int seconds);

#endif
