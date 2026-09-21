// hyotan bridge: Linux syscalls and ARM64 instructions run inside this process.
// The signal recovery sequence follows main.c. Part of hyotan (GPLv3 + LICENSE.IOS).
#import "hyotan.h"
#include "hyotan-version.h"
#include <signal.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <arpa/inet.h>
#include <resolv.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <stddef.h>
#define ISH_INTERNAL
#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/fake.h"
#include "fs/fd.h"
#include "fs/real.h"
#include "fs/path.h"
#include "asbestos/frame.h"

extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile uint64_t jit_saved_pc;
extern void jit_crash_trampoline(void);
extern const char *sock_tmp_prefix;

static struct task *initTask;
static NSMutableDictionary<NSNumber *, HyotanProcess *> *processes;
static dispatch_queue_t controlQueue;
static NSString *bootFailure;

@interface HyotanProcess ()
@property(nonatomic, readwrite) int pid;
@property(nonatomic) int inputFD;
@property(nonatomic) dispatch_queue_t inputQueue;
@property(atomic) BOOL inputClosed;
@property(nonatomic, copy) void (^onExit)(int);
@property(nonatomic) dispatch_group_t readers;
@end

// Preserve the interpreter's CoW fault recovery, allowing unrelated crashes
// to reach the normal iOS crash reporter. No executable pages are created.
static void recoverGuestFault(int sig, siginfo_t *info, void *context) {
#if defined(__aarch64__)
    if (in_jit && (sig == SIGSEGV || sig == SIGBUS)) {
        ucontext_t *uc = context;
        struct cpu_state *cpu = (void *)uc->uc_mcontext->__ss.__x[1];
        struct fiber_frame *frame = (void *)cpu;
        cpu->segfault_addr = (uc->uc_mcontext->__ss.__x[7] - uc->uc_mcontext->__ss.__x[10]) & 0xffffffffffffULL;
        cpu->segfault_was_write = (uc->uc_mcontext->__es.__esr & 0x40) != 0;
        cpu->pc = jit_saved_pc;
        uc->uc_mcontext->__ss.__sp = frame->jit_exit_sp;
        uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;
        return;
    }
#endif
    signal(sig, SIG_DFL);
    raise(sig);
}

static void processExited(struct task *task, int status) {
    int pid = task->tgid;
    int code = status & 0x7f ? 128 + (status & 0x7f) : (status >> 8) & 0xff;
    dispatch_async(controlQueue, ^{
        HyotanProcess *process = processes[@(pid)];
        if (process) {
            [process closeInput];
            dispatch_group_notify(process.readers, dispatch_get_main_queue(), ^{
                if (process.onExit) process.onExit(code);
            });
            [processes removeObjectForKey:@(pid)];
        }
        current = initTask;
        // Also reap descendants adopted by our idle init process. Children
        // still owned by a guest parent remain available to its waitpid().
        while ((int_t)sys_wait4(-1, 0, 1 /* WNOHANG */, 0) > 0) {}
        current = NULL;
    });
}

// No host thread has started this child, so release its resources directly.
// do_exit() cannot be used here: it would terminate a libdispatch worker.
static void discardUnstartedTask(struct task *task) {
    mm_release(task->mm);
    task->mm = NULL;
    fdtable_release(task->files);
    task->files = NULL;
    fs_info_release(task->fs);
    task->fs = NULL;
    lock(&pids_lock);
    sighand_release(task->sighand);
    task->sighand = NULL;
    list_remove(&task->group_links);
    task_leave_session(task);
    list_remove(&task->group->pgroup);
    cond_destroy(&task->group->child_exit);
    cond_destroy(&task->group->stopped_cond);
    free(task->group);
    task_destroy(task);
    unlock(&pids_lock);
}

// Bridged stdio uses nonblocking host pipes so a guest exit cannot leave a
// host read/write asleep after its one-shot wakeup signal has already arrived.
static ssize_t bridgeIO(struct fd *fd, void *buffer, size_t size, BOOL writing) {
    for (;;) {
        if (current && current->group && current->group->doing_group_exit)
            return _EINTR;
        ssize_t result = writing ? write(fd->real_fd, buffer, size) : read(fd->real_fd, buffer, size);
        if (result >= 0) return result;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return errno_map();
        if (fd->flags & O_NONBLOCK_) return _EAGAIN;
        struct pollfd descriptor = {.fd = fd->real_fd, .events = writing ? POLLOUT : POLLIN};
        if (poll(&descriptor, 1, 50) < 0) return errno_map();
    }
}
static ssize_t bridgeRead(struct fd *fd, void *buffer, size_t size) {
    return bridgeIO(fd, buffer, size, NO);
}
static ssize_t bridgeWrite(struct fd *fd, const void *buffer, size_t size) {
    return bridgeIO(fd, (void *)buffer, size, YES);
}

static struct fd *guestFD(int host, int flags) {
    static struct fd_ops stdioOps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stdioOps = realfs_fdops;
        stdioOps.read = bridgeRead;
        stdioOps.write = bridgeWrite;
        // Guest F_GETFL/F_SETFL operate on fd->flags. The host pipe must stay
        // nonblocking even when Linux requests a blocking descriptor.
        stdioOps.getflags = NULL;
        stdioOps.setflags = NULL;
    });
    if (fcntl(host, F_SETFL, fcntl(host, F_GETFL) | O_NONBLOCK) < 0) {
        close(host);
        return NULL;
    }
    struct fd *fd = adhoc_fd_create(&stdioOps);
    if (!fd) { close(host); return NULL; }
    fd->real_fd = host;
    fd->flags = flags;
    struct stat stat;
    if (fstat(host, &stat) == 0) {
        fd->stat.mode = stat.st_mode;
        fd->stat.inode = stat.st_ino;
        fd->stat.size = stat.st_size;
        fd->type = stat.st_mode & S_IFMT;
    }
    return fd;
}

static NSData *nulList(NSArray<NSString *> *strings) {
    NSMutableData *data = [NSMutableData data];
    char zero = 0;
    for (NSString *s in strings) {
        [data appendData:[s dataUsingEncoding:NSUTF8StringEncoding]];
        [data appendBytes:&zero length:1];
    }
    [data appendBytes:&zero length:1];
    return data;
}

static void readLines(int fd, HyotanProcess *process, BOOL isError, void (^output)(NSString *, BOOL)) {
    dispatch_group_enter(process.readers);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableData *pending = [NSMutableData data];
        uint8_t bytes[8192];
        for (;;) {
            ssize_t length = read(fd, bytes, sizeof(bytes));
            if (length < 0 && errno == EINTR) continue;
            if (length <= 0) break;
            [pending appendBytes:bytes length:(NSUInteger)length];
            for (;;) {
                const void *newline = memchr(pending.bytes, '\n', pending.length);
                if (!newline) break;
                NSUInteger n = (const uint8_t *)newline - (const uint8_t *)pending.bytes;
                NSString *line = [[NSString alloc] initWithBytes:pending.bytes length:n encoding:NSUTF8StringEncoding];
                if (!line) line = @"[invalid UTF-8]";
                dispatch_async(dispatch_get_main_queue(), ^{ output(line, isError); });
                [pending replaceBytesInRange:NSMakeRange(0, n + 1) withBytes:NULL length:0];
            }
        }
        if (pending.length) {
            NSString *line = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{ output(line ?: @"[invalid UTF-8]", isError); });
        }
        close(fd);
        dispatch_group_leave(process.readers);
    });
}

@implementation HyotanProcess
- (instancetype)init {
    if ((self = [super init])) {
        _inputFD = -1;
        _inputQueue = dispatch_queue_create("hyotan.input", DISPATCH_QUEUE_SERIAL);
        _readers = dispatch_group_create();
    }
    return self;
}
- (void)writeLine:(NSString *)line {
    if (self.inputClosed) return;
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(self.inputQueue, ^{
        const uint8_t *bytes = data.bytes;
        size_t remaining = data.length;
        while (remaining && self.inputFD >= 0 && !self.inputClosed) {
            ssize_t n = write(self.inputFD, bytes, remaining);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                struct pollfd descriptor = {.fd = self.inputFD, .events = POLLOUT};
                poll(&descriptor, 1, 100);
                continue;
            }
            if (n <= 0) { [self closeInput]; break; }
            bytes += n;
            remaining -= n;
        }
    });
}
- (void)closeInput {
    // Interrupt an in-flight write even when the guest is not reading stdin.
    self.inputClosed = YES;
    dispatch_async(self.inputQueue, ^{
        if (self.inputFD >= 0) { close(self.inputFD); self.inputFD = -1; }
    });
}
- (void)terminate {
    [self closeInput];
    dispatch_async(controlQueue, ^{
        if (processes[@(self.pid)] != self) return;
        lock(&pids_lock);
        struct task *task = pid_get_task(self.pid);
        if (task) send_signal(task, SIGTERM_, SIGINFO_NIL);
        unlock(&pids_lock);
    });
}
- (void)inspectInputForTesting:(void (^)(BOOL))completion {
    dispatch_async(self.inputQueue, ^{
        BOOL open = self.inputFD >= 0 && fcntl(self.inputFD, F_GETFD) >= 0;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(open); });
    });
}
@end

@implementation HyotanRuntime
+ (NSString *)version {
    return @HYOTAN_VERSION;
}
- (instancetype)init {
    if ((self = [super init])) {
        _environment = @[@"HOME=/root", @"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", @"LANG=C.UTF-8", @"TERM=dumb"];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            controlQueue = dispatch_queue_create("hyotan.control", DISPATCH_QUEUE_SERIAL);
            processes = [NSMutableDictionary dictionary];
        });
    }
    return self;
}
- (void)bootRoot:(NSString *)root workspace:(NSString *)workspace completion:(void (^)(NSString *))completion {
    dispatch_async(controlQueue, ^{
        NSString *error = bootFailure;
        if (!initTask && !error) {
            struct sigaction action = {0};
            action.sa_sigaction = recoverGuestFault;
            action.sa_flags = SA_SIGINFO;
            sigemptyset(&action.sa_mask);
            sigaction(SIGSEGV, &action, NULL);
            sigaction(SIGBUS, &action, NULL);
            int err = mount_root(&fakefs, [[root stringByAppendingPathComponent:@"data"] fileSystemRepresentation]);
            if (err == 0) err = become_first_process();
            if (err == 0) {
                initTask = current;
                current->thread = pthread_self();
                generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
                generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
                generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
                generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
                generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
                generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
                err = do_mount(&procfs, "proc", "/proc", "", 0);
                if (err == 0) err = do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
                if (err == 0) err = fakefs_bind_mount("/workspace", workspace.fileSystemRepresentation, false);
                exit_hook = processExited;
                // Resolve DNS using the device's active resolver configuration.
                struct __res_state resolver = {0};
                NSMutableString *dns = [NSMutableString string];
                if (res_ninit(&resolver) == 0) {
                    union res_sockaddr_union servers[8];
                    int count = res_getservers(&resolver, servers, 8);
                    for (int i = 0; i < MIN(count, 8); i++) {
                        char address[INET6_ADDRSTRLEN];
                        const char *value = NULL;
                        if (servers[i].sin.sin_family == AF_INET)
                            value = inet_ntop(AF_INET, &servers[i].sin.sin_addr, address, sizeof(address));
                        else if (servers[i].sin.sin_family == AF_INET6)
                            value = inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr, address, sizeof(address));
                        if (value) [dns appendFormat:@"nameserver %s\n", value];
                    }
                    res_nclose(&resolver);
                }
                if (dns.length) {
                    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_TRUNC_ | O_CREAT_, 0644);
                    if (!IS_ERR(fd)) { fd->ops->write(fd, dns.UTF8String, [dns lengthOfBytesUsingEncoding:NSUTF8StringEncoding]); fd_close(fd); }
                }
                NSString *socketPrefix = [NSTemporaryDirectory() stringByAppendingString:@"s"];
                if ([socketPrefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < 82)
                    sock_tmp_prefix = strdup(socketPrefix.fileSystemRepresentation);
                current = NULL;
            }
            if (err < 0) {
                error = [NSString stringWithFormat:@"Linux boot failed (%d)", err];
                bootFailure = error;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
- (HyotanProcess *)run:(NSString *)executable arguments:(NSArray<NSString *> *)arguments
              started:(void (^)(int))started output:(void (^)(NSString *, BOOL))output exited:(void (^)(int))exited {
    HyotanProcess *process = [[HyotanProcess alloc] init];
    process.onExit = exited;
    dispatch_async(controlQueue, ^{
        if (!initTask || bootFailure) { dispatch_async(dispatch_get_main_queue(), ^{ output(@"Linux is not running", YES); exited(125); }); return; }
        int input[2] = {-1, -1}, out[2] = {-1, -1}, errout[2] = {-1, -1};
        int err = 0;
        if (pipe(input) || pipe(out) || pipe(errout)) err = -errno;
        if (!err && fcntl(input[1], F_SETFL, O_NONBLOCK) < 0) err = -errno;
        if (!err) err = become_new_init_child();
        if (!err) {
            struct task *task = current;
            task->files->files[0] = guestFD(input[0], O_RDONLY_); input[0] = -1;
            task->files->files[1] = guestFD(out[1], O_WRONLY_); out[1] = -1;
            task->files->files[2] = guestFD(errout[1], O_WRONLY_); errout[1] = -1;
            if (!task->files->files[0] || !task->files->files[1] || !task->files->files[2]) err = _ENOMEM;
            if (!err) {
                struct fd *pwd = generic_open("/workspace", O_RDONLY_, 0);
                if (IS_ERR(pwd)) err = (int)PTR_ERR(pwd);
                else fs_chdir(task->fs, pwd);
            }
            NSArray *args = [@[executable] arrayByAddingObjectsFromArray:arguments];
            NSData *argv = nulList(args);
            NSData *envp = nulList(self.environment);
            if (!err) err = do_execve(executable.UTF8String, args.count, argv.bytes, envp.bytes);
            if (!err) {
                process.pid = task->pid;
                int inputFD = input[1]; input[1] = -1;
                dispatch_sync(process.inputQueue, ^{
                    if (process.inputClosed) close(inputFD);
                    else process.inputFD = inputFD;
                });
                processes[@(task->pid)] = process;
                readLines(out[0], process, NO, output); out[0] = -1;
                readLines(errout[0], process, YES, output); errout[0] = -1;
                task_start(task);
                dispatch_async(dispatch_get_main_queue(), ^{ started(process.pid); });
            } else discardUnstartedTask(task);
            current = NULL;
        }
        if (err) {
            [process closeInput];
            for (int i = 0; i < 2; i++) { if (input[i] >= 0) close(input[i]); if (out[i] >= 0) close(out[i]); if (errout[i] >= 0) close(errout[i]); }
            dispatch_async(dispatch_get_main_queue(), ^{ output([NSString stringWithFormat:@"failed to start %@ (%d)", executable, err], YES); exited(126); });
        }
    });
    return process;
}
- (void)inspectForTesting:(void (^)(NSDictionary<NSString *, NSNumber *> *))completion {
    dispatch_async(controlQueue, ^{
        NSUInteger tasks = 0, zombies = 0;
        lock(&pids_lock);
        for (int pid = 1; pid <= MAX_PID; pid++) {
            struct task *task = pid_get_task_zombie(pid);
            if (task) { tasks++; if (task->zombie) zombies++; }
        }
        unlock(&pids_lock);
        NSUInteger openFDs = 0;
        long limit = sysconf(_SC_OPEN_MAX);
        for (int fd = 0; fd < limit; fd++)
            if (fcntl(fd, F_GETFD) >= 0) openFDs++;
        NSDictionary *state = @{
            @"ready": @(initTask != NULL && bootFailure == nil),
            @"tasks": @(tasks), @"zombies": @(zombies),
            @"managed": @(processes.count), @"hostFDs": @(openFDs),
        };
        dispatch_async(dispatch_get_main_queue(), ^{ completion(state); });
    });
}
@end
