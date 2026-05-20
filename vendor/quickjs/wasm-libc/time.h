/* Minimal <time.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt.
 *
 * cutils.h's monotonic-clock helpers reference these, but those
 * helpers are not called by libregexp / libunicode. The
 * declarations exist only so the header parses. */
#ifndef CYNIC_WASM_TIME_H
#define CYNIC_WASM_TIME_H

#include <stdint.h>

typedef long time_t;
typedef int clockid_t;

struct timespec {
    time_t tv_sec;
    long tv_nsec;
};

#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif
#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
#endif

int clock_gettime(clockid_t clk_id, struct timespec *tp);
time_t time(time_t *tloc);

#endif
