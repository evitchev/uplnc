/* tshim.c: the narrow C platform shim for the UPLNC IDE (IDE.md section 2.1).
 *
 * Every function takes and returns intptr_t-compatible values, so the UPLNC
 * side never sees a bare C `int` return with an unspecified upper half (the
 * hazard examples/cint.he documents). Every C struct -- termios, winsize,
 * pollfd, sigaction -- stays on this side of the boundary. Compiled by the
 * same cc that links the target (langdrv.pl accepts .c inputs), so cross
 * builds get the target's own libc definitions of these structs.
 */
#define _GNU_SOURCE             /* posix_openpt and friends, cfmakeraw */
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>

static struct termios tsh_saved;
static intptr_t tsh_have_saved = 0;
static volatile sig_atomic_t tsh_winch = 0;
static struct sigaction tsh_oldpipe;
static intptr_t tsh_pipe_off = 0;

/* Once the IDE writes to a child (tsh_child), a write after that child has
 * died must fail with EPIPE rather than kill the IDE: SIGPIPE is ignored
 * from then on. An ignored signal stays ignored across exec, so every child
 * the shim starts puts the old disposition back first (tsh_childpipe). */
static void tsh_nopipe(void)
{
    struct sigaction ign;
    if (tsh_pipe_off) return;
    ign.sa_handler = SIG_IGN;
    sigemptyset(&ign.sa_mask);
    ign.sa_flags = 0;
    if (sigaction(SIGPIPE, &ign, &tsh_oldpipe) == 0) tsh_pipe_off = 1;
}

static void tsh_childpipe(void)
{
    if (tsh_pipe_off) sigaction(SIGPIPE, &tsh_oldpipe, 0);
}

/* enter raw mode on stdin, saving the exact prior state; 0 ok, -1 error.
 * Only the first call saves: entering raw mode again after a program the
 * IDE ran (Run) starts from that same state, so a program that leaves the
 * terminal in an odd mode cannot change what tsh_rawoff finally restores. */
intptr_t tsh_rawon(void)
{
    struct termios t;
    if (!tsh_have_saved) {
        if (tcgetattr(0, &tsh_saved) != 0) return -1;
        tsh_have_saved = 1;
    }
    t = tsh_saved;
    cfmakeraw(&t);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(0, TCSAFLUSH, &t) != 0) return -1;
    return 0;
}

/* restore the exact state tsh_rawon saved; a no-op if it never ran */
intptr_t tsh_rawoff(void)
{
    if (!tsh_have_saved) return 0;
    return tcsetattr(0, TCSAFLUSH, &tsh_saved) != 0 ? -1 : 0;
}

/* the terminal size as rows*65536+cols, or -1 */
intptr_t tsh_winsz(void)
{
    struct winsize w;
    if (ioctl(1, TIOCGWINSZ, &w) != 0) return -1;
    return ((intptr_t)w.ws_row << 16) | (intptr_t)w.ws_col;
}

static void tsh_onwinch(int sig)
{
    (void)sig;
    tsh_winch = 1;
}

/* install the SIGWINCH handler; 0 ok, -1 error */
intptr_t tsh_sigwinch(void)
{
    struct sigaction sa;
    sa.sa_handler = tsh_onwinch;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;   /* poll() must see EINTR so a resize wakes the wait */
    return sigaction(SIGWINCH, &sa, 0) != 0 ? -1 : 0;
}

/* read-and-clear the resize flag */
intptr_t tsh_tookwinch(void)
{
    intptr_t w = tsh_winch;
    tsh_winch = 0;
    return w;
}

/* wait up to ms for fd to become readable or reach EOF: 1 ready, 0 timeout or
 * resize interruption (the caller checks tsh_tookwinch), -1 descriptor/error */
intptr_t tsh_poll(intptr_t fd, intptr_t ms)
{
    struct pollfd p;
    int r;
    p.fd = (int)fd;
    p.events = POLLIN;
    p.revents = 0;
    do {
        r = poll(&p, 1, (int)ms);
    } while (r < 0 && errno == EINTR && !tsh_winch);
    if (r < 0) return tsh_winch ? 0 : -1;
    if (r == 0) return 0;
    if (p.revents & POLLNVAL) return -1;
    if (p.revents & (POLLIN | POLLHUP)) return 1;
    if (p.revents & POLLERR) return -1;
    return 0;
}

/* read up to n bytes; the byte count, 0 at EOF, -1 on error */
intptr_t tsh_read(intptr_t fd, char *buf, intptr_t n)
{
    ssize_t r;
    do {
        r = read((int)fd, buf, (size_t)n);
    } while (r < 0 && errno == EINTR);
    return (intptr_t)r;
}

/* write all n bytes; n, or -1 on error */
intptr_t tsh_write(intptr_t fd, const char *buf, intptr_t n)
{
    intptr_t done = 0;
    while (done < n) {
        ssize_t r = write((int)fd, buf + done, (size_t)(n - done));
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        done += r;
    }
    return done;
}

/* pipe() into two FULL-WIDTH slots -- the packed-C-int hazard IDE.md
 * section 2.1 documents is owned here, on the C side, forever */
intptr_t tsh_pipe(intptr_t *fds)
{
    int p[2];
    if (pipe(p) != 0) return -1;
    fds[0] = (intptr_t)p[0];
    fds[1] = (intptr_t)p[1];
    return 0;
}

intptr_t tsh_close(intptr_t fd)
{
    return close((int)fd) != 0 ? -1 : 0;
}

/* Run argv (argv[0] found on PATH) to completion for the IDE's build: stdin
 * is /dev/null and stdout+stderr go to one pipe, so the child never touches
 * the terminal the IDE holds in raw mode. Up to cap bytes of that output land
 * in out (the rest is read and dropped, so the child cannot block on a full
 * pipe) and *outn gets the count. Returns the exit status (0-255), 128+signal
 * if the child was killed, 127 if it could not be executed, or -1 if it
 * could not be started at all. */
intptr_t tsh_run(char *const *argv, char *out, intptr_t cap, intptr_t *outn)
{
    int p[2], st, nul;
    pid_t pid;
    intptr_t n = 0;
    *outn = 0;
    if (pipe(p) != 0) return -1;
    pid = fork();
    if (pid < 0) {
        close(p[0]);
        close(p[1]);
        return -1;
    }
    if (pid == 0) {
        static const char msg[] = "cannot run ";
        tsh_childpipe();
        nul = open("/dev/null", O_RDONLY);
        if (nul > 0) {
            dup2(nul, 0);
            close(nul);
        }
        dup2(p[1], 1);
        dup2(p[1], 2);
        close(p[0]);
        close(p[1]);
        execvp(argv[0], argv);
        /* exec failed: say so in the captured output, best effort */
        (void)!write(2, msg, sizeof msg - 1);
        (void)!write(2, argv[0], strlen(argv[0]));
        (void)!write(2, "\n", 1);
        _exit(127);
    }
    close(p[1]);
    for (;;) {
        char tmp[4096];
        ssize_t r = read(p[0], tmp, sizeof tmp), i;
        if (r < 0) {
            if (errno == EINTR) continue;   /* a resize: keep draining */
            break;
        }
        if (r == 0) break;
        for (i = 0; i < r; i++)
            if (n < cap) out[n++] = tmp[i];
    }
    close(p[0]);
    while (waitpid(pid, &st, 0) < 0)
        if (errno != EINTR) return -1;
    *outn = n;
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    if (WIFSIGNALED(st)) return 128 + WTERMSIG(st);
    return -1;
}

/* Run argv (argv[0] found on PATH) on the IDE's own terminal and wait for it:
 * the Run command, once the caller has given the terminal back (tuidone).
 * Meanwhile the IDE ignores SIGINT and SIGQUIT, as system() does, so Ctrl-C
 * and Ctrl-\ end the program and not the IDE; the child gets back the
 * dispositions the IDE had. Returns the exit status (0-255), 256+signal if
 * a signal ended it, or -1 if it could not be started; a program that
 * cannot be executed says so on stderr and exits 127. */
intptr_t tsh_spawn(char *const *argv)
{
    struct sigaction ign, oldint, oldquit;
    pid_t pid;
    int st;
    intptr_t r = -1;
    ign.sa_handler = SIG_IGN;
    sigemptyset(&ign.sa_mask);
    ign.sa_flags = 0;
    sigaction(SIGINT, &ign, &oldint);
    sigaction(SIGQUIT, &ign, &oldquit);
    pid = fork();
    if (pid == 0) {
        static const char msg[] = "cannot run ";
        sigaction(SIGINT, &oldint, 0);
        sigaction(SIGQUIT, &oldquit, 0);
        tsh_childpipe();
        execvp(argv[0], argv);
        (void)!write(2, msg, sizeof msg - 1);
        (void)!write(2, argv[0], strlen(argv[0]));
        (void)!write(2, "\n", 1);
        _exit(127);
    }
    if (pid > 0) {
        for (;;) {
            if (waitpid(pid, &st, 0) >= 0) {
                if (WIFEXITED(st)) r = WEXITSTATUS(st);
                else if (WIFSIGNALED(st)) r = 256 + WTERMSIG(st);
                break;
            }
            if (errno != EINTR) break;   /* a resize interrupts the wait */
        }
    }
    sigaction(SIGINT, &oldint, 0);
    sigaction(SIGQUIT, &oldquit, 0);
    return r;
}

/* Start argv (argv[0] found on PATH) as a child the IDE talks to -- the
 * debugger. Its stdin is a pipe whose write end goes into fds[0]; its stdout
 * and stderr share one pipe whose read end goes into fds[1]. Both ends are
 * close-on-exec, so later children (a build, Run) do not hold them open. The
 * child gets a session of its own: it has no controlling terminal, so
 * nothing typed at the IDE reaches it. Returns its pid, or -1; a program
 * that cannot be executed says so on its output and exits 127. */
intptr_t tsh_child(char *const *argv, intptr_t *fds)
{
    int in[2], out[2], a, b;
    pid_t pid;
    if (pipe(in) != 0) return -1;
    if (pipe(out) != 0) {
        close(in[0]);
        close(in[1]);
        return -1;
    }
    tsh_nopipe();
    pid = fork();
    if (pid < 0) {
        close(in[0]);
        close(in[1]);
        close(out[0]);
        close(out[1]);
        return -1;
    }
    if (pid == 0) {
        static const char msg[] = "cannot run ";
        tsh_childpipe();
        setsid();
        /* above 2 first: with a standard descriptor closed, a pipe end can
           be 0, 1 or 2, and the dup2s would overwrite one another */
        a = fcntl(in[0], F_DUPFD, 3);
        b = fcntl(out[1], F_DUPFD, 3);
        dup2(a, 0);
        dup2(b, 1);
        dup2(b, 2);
        close(a);
        close(b);
        if (in[0] > 2) close(in[0]);
        if (in[1] > 2) close(in[1]);
        if (out[0] > 2) close(out[0]);
        if (out[1] > 2) close(out[1]);
        execvp(argv[0], argv);
        (void)!write(2, msg, sizeof msg - 1);
        (void)!write(2, argv[0], strlen(argv[0]));
        (void)!write(2, "\n", 1);
        _exit(127);
    }
    close(in[0]);
    close(out[1]);
    fcntl(in[1], F_SETFD, FD_CLOEXEC);
    fcntl(out[0], F_SETFD, FD_CLOEXEC);
    fds[0] = (intptr_t)in[1];
    fds[1] = (intptr_t)out[0];
    return (intptr_t)pid;
}

/* Has child pid ended? With hang 0, -2 while it still runs; otherwise wait
 * for it. Returns the exit status (0-255), 256+signal, or -1 (no such
 * child). */
intptr_t tsh_wait(intptr_t pid, intptr_t hang)
{
    int st;
    pid_t r;
    for (;;) {
        r = waitpid((pid_t)pid, &st, hang ? 0 : WNOHANG);
        if (r == 0) return -2;
        if (r > 0) break;
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    if (WIFSIGNALED(st)) return 256 + WTERMSIG(st);
    return -1;
}

intptr_t tsh_kill(intptr_t pid, intptr_t sig)
{
    return kill((pid_t)pid, (int)sig) != 0 ? -1 : 0;
}

/* A pseudo-terminal for the program being debugged: returns the master
 * side's descriptor, puts the slave's path into name (NUL-terminated, at
 * most cap bytes) and its descriptor into *slave. The caller keeps the
 * slave open, so the master never reads a hangup while no program has it
 * open, between runs. Both are close-on-exec. -1 on error. */
intptr_t tsh_openpty(char *name, intptr_t cap, intptr_t *slave)
{
    int m, sl;
    char *p;
    m = posix_openpt(O_RDWR | O_NOCTTY);
    if (m < 0) return -1;
    if (grantpt(m) != 0 || unlockpt(m) != 0 || (p = ptsname(m)) == 0
            || (intptr_t)strlen(p) >= cap) {
        close(m);
        return -1;
    }
    strcpy(name, p);
    sl = open(name, O_RDWR | O_NOCTTY);
    if (sl < 0) {
        close(m);
        return -1;
    }
    fcntl(m, F_SETFD, FD_CLOEXEC);
    fcntl(sl, F_SETFD, FD_CLOEXEC);
    *slave = (intptr_t)sl;
    return (intptr_t)m;
}

/* A monotonic clock in milliseconds, for deadlines. Only differences mean
 * anything: on a 32-bit target the count wraps after about 24 days, and a
 * difference taken in the same width stays right across the wrap. */
intptr_t tsh_clock(void)
{
    struct timespec t;
    uint64_t ms;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return 0;
    ms = (uint64_t)t.tv_sec * 1000u + (uint64_t)t.tv_nsec / 1000000u;
    return (intptr_t)ms;
}

/* the kernel's machine name (uname -m) into buf, NUL-terminated and
 * truncated to fit; 0 ok, -1 error. Under qemu-user this is the guest's. */
intptr_t tsh_machine(char *buf, intptr_t cap)
{
    struct utsname u;
    if (cap < 1 || uname(&u) != 0) return -1;
    strncpy(buf, u.machine, (size_t)cap - 1);
    buf[cap - 1] = 0;
    return 0;
}
