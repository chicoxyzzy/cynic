/* Minimal <pthread.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt.
 *
 * cutils.h defines js_thread_t / js_mutex_t etc. as typedefs of
 * these pthread types and wraps them in inline helpers. libregexp
 * / libunicode never call any of those helpers — the WASM module
 * is single-threaded — so opaque type definitions plus function
 * declarations are enough for the header to parse; the unreferenced
 * inline helpers are dropped by the compiler. */
#ifndef CYNIC_WASM_PTHREAD_H
#define CYNIC_WASM_PTHREAD_H

#include <stddef.h>

typedef struct { void *o; } pthread_once_t;
typedef struct { void *m; } pthread_mutex_t;
typedef struct { void *c; } pthread_cond_t;
typedef struct { void *a; } pthread_condattr_t;
typedef struct { void *a; } pthread_mutexattr_t;
typedef struct { void *a; } pthread_attr_t;
typedef unsigned long pthread_t;

#define PTHREAD_ONCE_INIT {0}
#define PTHREAD_MUTEX_INITIALIZER {0}
#define PTHREAD_COND_INITIALIZER {0}
#define PTHREAD_CREATE_DETACHED 1
#define PTHREAD_CREATE_JOINABLE 0

int pthread_once(pthread_once_t *once_control, void (*init_routine)(void));
int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr);
int pthread_mutex_destroy(pthread_mutex_t *mutex);
int pthread_mutex_lock(pthread_mutex_t *mutex);
int pthread_mutex_unlock(pthread_mutex_t *mutex);
int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr);
int pthread_cond_destroy(pthread_cond_t *cond);
int pthread_cond_signal(pthread_cond_t *cond);
int pthread_cond_broadcast(pthread_cond_t *cond);
int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);
int pthread_condattr_init(pthread_condattr_t *attr);
int pthread_condattr_destroy(pthread_condattr_t *attr);
int pthread_condattr_setclock(pthread_condattr_t *attr, int clock_id);
int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start_routine)(void *), void *arg);
int pthread_join(pthread_t thread, void **retval);

struct timespec;
int pthread_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                           const struct timespec *abstime);
int pthread_attr_init(pthread_attr_t *attr);
int pthread_attr_destroy(pthread_attr_t *attr);
int pthread_attr_setstacksize(pthread_attr_t *attr, size_t stacksize);
int pthread_attr_setdetachstate(pthread_attr_t *attr, int detachstate);

#endif
