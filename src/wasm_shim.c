/* Freestanding-WASM libc shim for the vendored QuickJS-NG C
 * (libregexp.c / libunicode.c).
 *
 * A `wasm32-freestanding` target has no libc: the C sources reach
 * for `malloc` / `free` / `realloc`, the `mem*` / `str*` family,
 * and a few stdio symbols (`printf` / `fprintf` / `vsnprintf`).
 * This file satisfies every one of those undefined references so
 * the QuickJS C links cleanly into the WASM module.
 *
 * Allocation routes through two C-ABI hooks implemented on the Zig
 * side (`src/wasm.zig`): `cynic_host_alloc` / `cynic_host_free` /
 * `cynic_host_realloc`. That keeps a single allocator — the Zig
 * `WasmAllocator` — owning every byte, native and C alike.
 *
 * The `mem*` / `str*` functions are written from scratch here.
 * They are small and only exercised by the regex compiler, so a
 * straightforward byte loop is fine; the Zig side never calls
 * them. `printf` / `fprintf` are stubbed to no-ops — the only
 * caller is libregexp's `DUMP_REOP` bytecode dumper, which is
 * debug output with no place to go inside a sandboxed module.
 * `vsnprintf` / `snprintf` get a real (minimal) implementation
 * because libregexp's error path formats a diagnostic string
 * through them.
 */

typedef unsigned long size_t;
typedef __builtin_va_list va_list;
#define va_start __builtin_va_start
#define va_end __builtin_va_end
#define va_arg __builtin_va_arg

/* ---- allocation: forwarded to the Zig WasmAllocator ---- */

extern void *cynic_host_alloc(size_t n);
extern void cynic_host_free(void *p);
extern void *cynic_host_realloc(void *p, size_t n);

void *malloc(size_t n) { return cynic_host_alloc(n); }
void free(void *p) { cynic_host_free(p); }
void *realloc(void *p, size_t n) { return cynic_host_realloc(p, n); }

void *calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    char *p = (char *)cynic_host_alloc(total);
    if (p) {
        for (size_t i = 0; i < total; i++) p[i] = 0;
    }
    return p;
}

/* ---- mem* family ---- */

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d == s || n == 0) return dst;
    if (d < s) {
        for (size_t i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (size_t i = n; i > 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    for (size_t i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *pa = (const unsigned char *)a;
    const unsigned char *pb = (const unsigned char *)b;
    for (size_t i = 0; i < n; i++) {
        if (pa[i] != pb[i]) return (int)pa[i] - (int)pb[i];
    }
    return 0;
}

void *memchr(const void *s, int c, size_t n) {
    const unsigned char *p = (const unsigned char *)s;
    for (size_t i = 0; i < n; i++) {
        if (p[i] == (unsigned char)c) return (void *)(p + i);
    }
    return 0;
}

/* ---- str* family ---- */

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

int strcmp(const char *a, const char *b) {
    while (*a && (*a == *b)) {
        a++;
        b++;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char ca = (unsigned char)a[i];
        unsigned char cb = (unsigned char)b[i];
        if (ca != cb) return (int)ca - (int)cb;
        if (ca == 0) return 0;
    }
    return 0;
}

char *strchr(const char *s, int c) {
    for (;; s++) {
        if (*s == (char)c) return (char *)s;
        if (!*s) return 0;
    }
}

/* ---- abort: surfaces as a WASM trap ---- */

void abort(void) {
    __builtin_trap();
}

/* `assert` expands to a call to this when NDEBUG is unset. The
 * build compiles the C with -DNDEBUG so this is normally unused;
 * provide it anyway for safety. */
void __assert_fail(const char *expr, const char *file, int line,
                   const char *func) {
    (void)expr;
    (void)file;
    (void)line;
    (void)func;
    __builtin_trap();
}

/* ---- minimal stdio ---- */

/* libregexp's DUMP_REOP dump path calls printf. There is no
 * console in a freestanding module — discard. */
int printf(const char *fmt, ...) {
    (void)fmt;
    return 0;
}

int fprintf(void *stream, const char *fmt, ...) {
    (void)stream;
    (void)fmt;
    return 0;
}

int fputs(const char *s, void *stream) {
    (void)s;
    (void)stream;
    return 0;
}

int putchar(int c) {
    return c;
}

/* A small, correct-enough vsnprintf for libregexp's error-message
 * path. Supports the conversions QuickJS actually formats with:
 * %s, %c, %d / %i, %u, %x, %%. Width / precision / length
 * modifiers are skipped (consumed but ignored) — error strings
 * stay readable without them. Always NUL-terminates when size>0
 * and returns the would-be length, matching C99. */

static void vsn_putc(char *buf, size_t size, size_t *pos, char c) {
    if (*pos + 1 < size) buf[*pos] = c;
    (*pos)++;
}

static void vsn_puts(char *buf, size_t size, size_t *pos, const char *s) {
    if (!s) s = "(null)";
    while (*s) vsn_putc(buf, size, pos, *s++);
}

static void vsn_putu(char *buf, size_t size, size_t *pos,
                     unsigned long v, int base, int upper) {
    char tmp[32];
    int n = 0;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (v == 0) tmp[n++] = '0';
    while (v) {
        tmp[n++] = digits[v % (unsigned)base];
        v /= (unsigned)base;
    }
    while (n > 0) vsn_putc(buf, size, pos, tmp[--n]);
}

static void vsn_puti(char *buf, size_t size, size_t *pos, long v) {
    if (v < 0) {
        vsn_putc(buf, size, pos, '-');
        vsn_putu(buf, size, pos, (unsigned long)(-v), 10, 0);
    } else {
        vsn_putu(buf, size, pos, (unsigned long)v, 10, 0);
    }
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    size_t pos = 0;
    for (const char *p = fmt; *p; p++) {
        if (*p != '%') {
            vsn_putc(buf, size, &pos, *p);
            continue;
        }
        p++;
        /* skip flags / width / precision / length modifiers */
        while (*p == '-' || *p == '+' || *p == ' ' || *p == '#' ||
               *p == '0' || *p == '.' || (*p >= '1' && *p <= '9') ||
               *p == 'l' || *p == 'h' || *p == 'z') {
            p++;
        }
        switch (*p) {
            case 's':
                vsn_puts(buf, size, &pos, va_arg(ap, const char *));
                break;
            case 'c':
                vsn_putc(buf, size, &pos, (char)va_arg(ap, int));
                break;
            case 'd':
            case 'i':
                vsn_puti(buf, size, &pos, (long)va_arg(ap, int));
                break;
            case 'u':
                vsn_putu(buf, size, &pos, (unsigned long)va_arg(ap, unsigned int), 10, 0);
                break;
            case 'x':
                vsn_putu(buf, size, &pos, (unsigned long)va_arg(ap, unsigned int), 16, 0);
                break;
            case 'X':
                vsn_putu(buf, size, &pos, (unsigned long)va_arg(ap, unsigned int), 16, 1);
                break;
            case 'p':
                vsn_puts(buf, size, &pos, "0x");
                vsn_putu(buf, size, &pos, (unsigned long)va_arg(ap, void *), 16, 0);
                break;
            case '%':
                vsn_putc(buf, size, &pos, '%');
                break;
            case '\0':
                p--;
                break;
            default:
                vsn_putc(buf, size, &pos, '%');
                vsn_putc(buf, size, &pos, *p);
                break;
        }
    }
    if (size > 0) {
        buf[pos < size ? pos : size - 1] = '\0';
    }
    return (int)pos;
}

int snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return n;
}
