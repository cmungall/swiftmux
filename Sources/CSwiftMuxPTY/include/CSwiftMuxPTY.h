#ifndef CSWIFTMUXPTY_H
#define CSWIFTMUXPTY_H

#include <sys/types.h>

/// Wraps forkpty(3). Returns pid (0 in child, >0 in parent), or -1 on error.
/// On success, *amaster is set to the master fd in the parent.
pid_t swiftmux_forkpty(int *amaster, unsigned short rows, unsigned short cols);

/// Wraps ioctl(fd, TIOCSWINSZ, &ws). Returns 0 on success, -1 on error.
int swiftmux_set_winsize(int fd, unsigned short rows, unsigned short cols);

#endif
