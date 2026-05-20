/* Minimal <sys/time.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt. Referenced by cutils.h's wall-clock
 * helpers, which libregexp / libunicode do not call. */
#ifndef CYNIC_WASM_SYS_TIME_H
#define CYNIC_WASM_SYS_TIME_H

#include <time.h>

struct timeval {
    time_t tv_sec;
    long tv_usec;
};

struct timezone {
    int tz_minuteswest;
    int tz_dsttime;
};

int gettimeofday(struct timeval *tv, void *tz);

#endif
