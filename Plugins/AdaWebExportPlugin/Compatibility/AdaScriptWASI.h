#ifndef ADA_SCRIPT_WASI_COMPATIBILITY_H
#define ADA_SCRIPT_WASI_COMPATIBILITY_H

// The pinned AdaScript VM's POSIX utilities do not yet recognize WASI.
// Keep this guarded: SwiftPM passes global C flags to host macro tools as well.
#if defined(__wasi__)
#include <sys/stat.h>
#include <sys/time.h>

// WASI has no process file-creation mask. Directory permissions are controlled
// by the host's preopened capabilities; there is no mask to save or restore.
// This supplies the POSIX helper used by the VM's directory_create function.
static inline mode_t umask(mode_t mask) {
    (void)mask;
    return 0;
}
#endif

#endif
