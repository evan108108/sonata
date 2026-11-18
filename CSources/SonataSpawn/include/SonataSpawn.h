#ifndef SONATA_SPAWN_H
#define SONATA_SPAWN_H

/// Sonata links its own `forkpty` (SonataSpawn.c) ahead of libSystem's, so the
/// child of every SwiftTerm terminal spawn closes descriptors above stderr
/// before it execs. Returns 1; Sonata calls it so a test (and the startup log)
/// can prove the override is the one linked in.
int sonata_forkpty_closes_inherited_fds(void);

/// Close every descriptor above 2 in the calling process. Async-signal-safe:
/// it is meant for a freshly forked child. Exposed for tests.
void sonata_close_fds_above_stderr(void);

#endif
