/* Minimal <errno.h> for the wasm32-freestanding QuickJS build.
 * See wasm-libc/README.txt. */
#ifndef CYNIC_WASM_ERRNO_H
#define CYNIC_WASM_ERRNO_H

extern int errno;

#define EPERM   1
#define ENOENT  2
#define EINTR   4
#define EIO     5
#define ENOMEM  12
#define EINVAL  22
#define ERANGE  34
#define ETIMEDOUT 110
#define EAGAIN  11
#define EBUSY   16

#endif
