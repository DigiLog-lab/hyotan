#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <pthread.h>
#include "kernel/calls.h"
#include "fs/fd.h"
#include "fs/real.h"
#include "debug.h"

// Host pipes stay nonblocking; Linux blocking semantics are implemented with
// bounded waits so group exit cannot miss the one-shot host wakeup signal.
static ssize_t pipe_io(struct fd *fd, void *buffer, size_t size, bool writing) {
    for (;;) {
        if (current->group->doing_group_exit) return _EINTR;
        ssize_t result = writing ? write(fd->real_fd, buffer, size) : read(fd->real_fd, buffer, size);
        if (result >= 0) return result;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return errno_map();
        if (fd->flags & O_NONBLOCK_) return _EAGAIN;
        struct pollfd descriptor = {.fd = fd->real_fd, .events = writing ? POLLOUT : POLLIN};
        if (poll(&descriptor, 1, 50) < 0) return errno_map();
    }
}
static ssize_t pipe_read(struct fd *fd, void *buffer, size_t size) {
    return pipe_io(fd, buffer, size, false);
}
static ssize_t pipe_write(struct fd *fd, const void *buffer, size_t size) {
    return pipe_io(fd, (void *)buffer, size, true);
}
static struct fd_ops pipe_ops;
static pthread_once_t pipe_once = PTHREAD_ONCE_INIT;
static void init_pipe_ops(void) {
    pipe_ops = realfs_fdops;
    pipe_ops.read = pipe_read;
    pipe_ops.write = pipe_write;
    pipe_ops.getflags = NULL;
    pipe_ops.setflags = NULL;
}

static fd_t pipe_f_create(int pipe_fd, int flags) {
    pthread_once(&pipe_once, init_pipe_ops);
    if (fcntl(pipe_fd, F_SETFL, fcntl(pipe_fd, F_GETFL) | O_NONBLOCK) < 0)
        return errno_map();
    struct fd *fd = adhoc_fd_create(&pipe_ops);
    if (fd == NULL)
        return _ENOMEM;
    fd->real_fd = pipe_fd;
    fd->flags = flags & ~O_CLOEXEC_;
    fd->stat.mode = S_IFIFO | 0660;
    fd->stat.uid = current->uid;
    fd->stat.gid = current->gid;
    return f_install(fd, flags);
}

int_t sys_pipe2(addr_t pipe_addr, int_t flags) {
    STRACE("pipe2(%#x, %#x)", pipe_addr, flags);
    if (flags & ~(O_CLOEXEC_|O_NONBLOCK_)) {
        FIXME("unsupported pipe2 flags");
        return _EINVAL;
    }

    int p[2];
    int err = pipe(p);
    if (err < 0)
        return err;

    int fp[2];
    err = fp[0] = pipe_f_create(p[0], flags);
    if (fp[0] < 0)
        goto close_pipe;
    err = fp[1] = pipe_f_create(p[1], flags | O_WRONLY_);
    if (fp[1] < 0)
        goto close_fake_0;

    err = _EFAULT;
    if (user_put(pipe_addr, fp))
        goto close_fake_1;
    STRACE(" [%d %d]", fp[0], fp[1]);
    return 0;

close_fake_1:
    f_close(fp[1]);
close_fake_0:
    f_close(fp[0]);
close_pipe:
    close(p[0]);
    close(p[1]);
    return err;
}

int_t sys_pipe(addr_t pipe_addr) {
    return sys_pipe2(pipe_addr, 0);
}
