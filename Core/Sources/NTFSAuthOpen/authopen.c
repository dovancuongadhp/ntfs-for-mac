#include "ntfs_authopen.h"

#include <Security/Authorization.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

struct ntfs_disk_session {
    AuthorizationRef auth;
    int error;
};

static int fail(ntfs_disk_session *session, int error) {
    if (session) session->error = error;
    return -1;
}

ntfs_disk_session *ntfs_disk_session_begin(const char *partition, const char *whole, int *error) {
    if (error) *error = ntfs_auth_io;
    if (!partition || !whole) return NULL;

    char *rights[2] = { NULL, NULL };
    if (asprintf(&rights[0], "sys.openfile.readwrite.%s", partition) < 0) return NULL;
    if (asprintf(&rights[1], "sys.openfile.readwrite.%s", whole) < 0) {
        free(rights[0]);
        return NULL;
    }
    AuthorizationItem items[2] = {
        { rights[0], 0, NULL, 0 },
        { rights[1], 0, NULL, 0 },
    };
    AuthorizationRights request = { 2, items };
    char prompt[] = "NTFS for Mac needs permission to format this drive.";
    AuthorizationItem environmentItems[] = {
        { "prompt", strlen(prompt), prompt, 0 },
    };
    AuthorizationEnvironment environment = { 1, environmentItems };
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed
        | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize;

    ntfs_disk_session *session = calloc(1, sizeof(*session));
    OSStatus status = errAuthorizationInternal;
    if (session) {
        status = AuthorizationCreate(&request, &environment, flags, &session->auth);
    }
    free(rights[0]);
    free(rights[1]);
    if (status == errAuthorizationSuccess) return session;

    int reason = status == errAuthorizationCanceled ? ntfs_auth_cancelled : ntfs_auth_denied;
    if (error) *error = reason;
    if (session) {
        if (session->auth) AuthorizationFree(session->auth, kAuthorizationFlagDefaults);
        free(session);
    }
    return NULL;
}

static int receive_fd(int sock) {
    char data[64];
    char control[CMSG_SPACE(sizeof(int))];
    struct iovec iov = { data, sizeof(data) };
    struct msghdr message = { 0 };
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    ssize_t received = recvmsg(sock, &message, 0);
    if (received < 0) return -1;
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_type != SCM_RIGHTS || header->cmsg_len < CMSG_LEN(sizeof(int))) return -1;
    int fd = -1;
    memcpy(&fd, CMSG_DATA(header), sizeof(fd));
    return fd;
}

int ntfs_disk_session_open(ntfs_disk_session *session, const char *path) {
    if (!session || !session->auth || !path) return fail(session, ntfs_auth_io);
    AuthorizationExternalForm form;
    if (AuthorizationMakeExternalForm(session->auth, &form) != errAuthorizationSuccess) {
        return fail(session, ntfs_auth_io);
    }

    int output[2] = { -1, -1 };
    int input[2] = { -1, -1 };
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, output) != 0 || pipe(input) != 0) {
        return fail(session, ntfs_auth_io);
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, input[1]);
    posix_spawn_file_actions_addclose(&actions, output[0]);

    char mode[16];
    snprintf(mode, sizeof(mode), "%d", O_RDWR);
    char *argv[] = {
        "authopen", "-stdoutpipe", "-extauth", "-o", mode, (char *)path, NULL,
    };
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, "/usr/libexec/authopen", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(input[0]);
    close(output[1]);
    if (spawned != 0) {
        close(input[1]);
        close(output[0]);
        return fail(session, ntfs_auth_io);
    }

    ssize_t wrote = write(input[1], form.bytes, sizeof(form.bytes));
    close(input[1]);
    int fd = wrote == (ssize_t)sizeof(form.bytes) ? receive_fd(output[0]) : -1;
    close(output[0]);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || fd < 0) {
        if (fd >= 0) close(fd);
        return fail(session, ntfs_auth_denied);
    }
    session->error = 0;
    return fd;
}

int ntfs_disk_session_error(const ntfs_disk_session *session) {
    return session ? session->error : ntfs_auth_io;
}

void ntfs_disk_session_end(ntfs_disk_session *session) {
    if (!session) return;
    if (session->auth) AuthorizationFree(session->auth, kAuthorizationFlagDefaults);
    free(session);
}

int ntfs_spawn_with_disk_fd(const char *executable, char *const argv[], const char *diskPath, int fd) {
    if (!executable || !argv || !diskPath || fd < 0) return 127;
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return 127;
    if (fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC) != 0) return 127;

    int count = 0;
    while (environ[count]) count++;
    char **envp = calloc((size_t)count + 3, sizeof(char *));
    if (!envp) return 127;
    int used = 0;
    for (int index = 0; index < count; index++) {
        if (strncmp(environ[index], "NTFS_FOR_MAC_DISK_PATH=", 23) == 0) continue;
        if (strncmp(environ[index], "NTFS_FOR_MAC_DISK_FD=", 21) == 0) continue;
        envp[used++] = environ[index];
    }
    char pathVar[1100];
    char fdVar[64];
    snprintf(pathVar, sizeof(pathVar), "NTFS_FOR_MAC_DISK_PATH=%s", diskPath);
    snprintf(fdVar, sizeof(fdVar), "NTFS_FOR_MAC_DISK_FD=%d", fd);
    envp[used++] = pathVar;
    envp[used] = fdVar;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addinherit_np(&actions, fd);
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, executable, &actions, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    free(envp);
    if (spawned != 0) return 127;

    int status = 0;
    if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status)) return 127;
    return WEXITSTATUS(status);
}
