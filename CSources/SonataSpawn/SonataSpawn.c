// Close-on-spawn for every terminal child Sonata forks.
//
// SwiftTerm launches each worker, interactive session, supervisor, sidecar and
// inspector through PseudoTerminalHelpers.fork (Pty.swift), which is libc
// `forkpty` followed straight by `execve`. Nothing runs between the two, so the
// child inherits every descriptor Sonata has open that lacks FD_CLOEXEC.
// Foundation's Pipe does not set it. On 11/18 a worker forked two seconds into
// HealthMonitor's first cycle inherited the write end of GhostWorkerReaper's
// pgrep pipe; pgrep exited, but EOF never came while the worker lived, and the
// monitor hung in readDataToEndOfFile (memory c3cf3c8d).
//
// The 10/25 ListenerCloexecGate patched one descriptor (the :3211 listener).
// This closes the class: Sonata defines `forkpty` itself. A symbol defined in
// an object file the linker is given wins over the libSystem export, so
// SwiftTerm's call binds here. The child does what BSD forkpty does (close the
// master, login_tty the slave onto 0/1/2 as a new session's controlling tty)
// and then closes every descriptor above 2 before returning to SwiftTerm, which
// chdirs and execs. Closing happens in the child after fork, so a descriptor
// another thread opens mid-spawn is covered too: there is no race window.
//
// SonataSpawnTests checks a real SwiftTerm fork against an inheritable pipe; if
// SwiftTerm ever stops calling forkpty, that test fails.

#include "SonataSpawn.h"

#include <libproc.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <util.h>

int sonata_forkpty_closes_inherited_fds(void) { return 1; }

// Only syscalls from here down: this runs between fork and exec in a
// multithreaded parent's child, where malloc and locks are off limits.
void sonata_close_fds_above_stderr(void) {
    // List the open descriptors and close those above 2. A full buffer may mean
    // more remain, so list again; each pass shrinks the table. Bounded rounds,
    // then a brute-force sweep as the fallback if listing ever fails.
    struct proc_fdinfo fds[1024];
    for (int round = 0; round < 512; round++) {
        int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, (int)sizeof(fds));
        if (bytes <= 0) {
            break;
        }
        int count = bytes / (int)sizeof(fds[0]);
        int closed = 0;
        for (int i = 0; i < count; i++) {
            if (fds[i].proc_fd > STDERR_FILENO) {
                close(fds[i].proc_fd);
                closed++;
            }
        }
        if (closed == 0) {
            return;
        }
    }
    int limit = getdtablesize();
    for (int fd = STDERR_FILENO + 1; fd < limit; fd++) {
        close(fd);
    }
}

pid_t forkpty(int *amaster, char *name, struct termios *termp, struct winsize *winp) {
    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, name, termp, winp) == -1) {
        return -1;
    }
    pid_t pid = fork();
    if (pid == -1) {
        close(master);
        close(slave);
        return -1;
    }
    if (pid == 0) {
        close(master);
        if (login_tty(slave) == -1) {
            _exit(1);
        }
        sonata_close_fds_above_stderr();
        return 0;
    }
    close(slave);
    *amaster = master;
    return pid;
}
