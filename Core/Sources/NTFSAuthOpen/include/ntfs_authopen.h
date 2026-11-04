#ifndef NTFS_AUTHOPEN_H
#define NTFS_AUTHOPEN_H

/// Why `ntfs_disk_session_begin` or `ntfs_disk_session_open` failed.
enum {
    ntfs_auth_cancelled = 1,
    ntfs_auth_denied = 2,
    ntfs_auth_io = 3,
};

/// One administrator prompt covering `partition` and `whole` (both device paths).
typedef struct ntfs_disk_session ntfs_disk_session;

ntfs_disk_session *ntfs_disk_session_begin(const char *partition, const char *whole, int *error);
/// Read-write descriptor for `path`, or -1. On failure the reason is `ntfs_disk_session_error`.
int ntfs_disk_session_open(ntfs_disk_session *session, const char *path);
int ntfs_disk_session_error(const ntfs_disk_session *session);
void ntfs_disk_session_end(ntfs_disk_session *session);

/// Runs `executable` with a NULL-terminated `argv` (including argv0). The child
/// inherits `fd` and sees NTFS_FOR_MAC_DISK_PATH / NTFS_FOR_MAC_DISK_FD, which
/// make mkntfs reuse this descriptor instead of opening the disk itself.
/// Returns the child's exit status, or 127 if it could not be started.
int ntfs_spawn_with_disk_fd(const char *executable, char *const argv[], const char *diskPath, int fd);

#endif
