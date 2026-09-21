#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

// Run this Linux binary inside the iOS app to exercise the exact hardening
// calls that official Codex performs before main(), including enforcement.
int main(void) {
    if (prctl(PR_GET_DUMPABLE) != 1 || prctl(PR_SET_DUMPABLE, 0) != 0 ||
        prctl(PR_GET_DUMPABLE) != 0) {
        perror("dumpable state");
        return 1;
    }
    errno = 0;
    if (prctl(PR_SET_DUMPABLE, 2) != -1 || errno != EINVAL)
        return 2;
    struct rlimit limit = {0, 0};
    if (setrlimit(RLIMIT_CORE, &limit) != 0) {
        perror("setrlimit");
        return 3;
    }

    int ready[2];
    int release[2];
    if (pipe(ready) || pipe(release))
        return 4;
    pid_t child = fork();
    if (child < 0)
        return 5;
    if (child == 0) {
        close(ready[0]);
        close(release[1]);
        char value = prctl(PR_GET_DUMPABLE) == 0 ? '0' : '1';
        if (write(ready[1], &value, 1) != 1)
            _exit(6);
        if (read(release[0], &value, 1) != 1)
            _exit(7);
        _exit(0);
    }
    close(ready[1]);
    close(release[0]);
    char value;
    if (read(ready[0], &value, 1) != 1 || value != '0')
        return 8;
    char path[80];
    snprintf(path, sizeof(path), "/proc/%d/mem", (int)child);
    errno = 0;
    int fd = open(path, O_RDONLY);
    ssize_t n = fd < 0 ? -1 : pread(fd, &value, 1, (off_t)(long)&value);
    int denied = n == -1 && (errno == EACCES || errno == EPERM);
    if (fd >= 0)
        close(fd);
    if (write(release[1], "x", 1) != 1)
        return 9;
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status))
        return 10;
    if (!denied)
        return 11;
    puts("prctl=ok core_limit=0 fork_inheritance=ok protected_proc_mem=denied");
    return 0;
}
