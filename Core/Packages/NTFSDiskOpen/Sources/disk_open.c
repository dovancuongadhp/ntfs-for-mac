/*
 * macOS refuses open() on a removable disk, even as root. ntfs-format gets a
 * descriptor from authopen and passes it in the environment; mkntfs then
 * calls open() on the same path, and this interpose hands that descriptor
 * back. File images and every other path keep the real open().
 *
 * The interpose has to live in its own library. dyld does not apply an
 * interpose tuple to the image that contains it, so linking this file into
 * ntfs-mkfs itself would leave mkntfs's open() unchanged.
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee }

static int (*real_open)(const char *, int, ...) = NULL;
static int resolving_open = 0;

static int call_real_open(const char *path, int flags, mode_t mode) {
    if (real_open == NULL) {
        if (resolving_open) {
            errno = EIO;
            return -1;
        }
        resolving_open = 1;
        // libc's open() is the symbol we replace. Calling it here would recurse.
        // open$NOCANCEL is the syscall wrapper underneath it.
        real_open = dlsym(RTLD_DEFAULT, "open$NOCANCEL");
        resolving_open = 0;
        if (real_open == NULL) {
            errno = EIO;
            return -1;
        }
    }
    return real_open(path, flags, mode);
}

static int disk_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    const char *disk = getenv("NTFS_FOR_MAC_DISK_PATH");
    const char *text = getenv("NTFS_FOR_MAC_DISK_FD");
    if (disk != NULL && text != NULL && path != NULL && strcmp(path, disk) == 0) {
        char *end = NULL;
        long value = strtol(text, &end, 10);
        if (end != text && *end == '\0' && value >= 0) {
            int duped = fcntl((int)value, F_DUPFD, 0);
            if (duped >= 0) return duped;
            return -1;
        }
    }
    return call_real_open(path, flags, mode);
}

DYLD_INTERPOSE(disk_open, open);
