"""What differs between the systems TurboMojo is built for, chosen when it is compiled:
the numbers of system calls' flags and signals, the layout of `struct termios`, and
which Linux-only facilities exist.

Linux (x86-64 and aarch64, glibc) is what TurboMojo is developed and tested on; its
values are checked against the system's own by tests/test_platform.mojo. The macOS
values are taken from Darwin's headers (sys/termios.h, sys/ttycom.h, sys/fcntl.h,
sys/signal.h, sys/errno.h) and have NOT been tried on a Mac: a macOS build is
unverified (docs/JOURNAL.md, P9-03, lists what would have to be checked there).
"""
from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.collections import List

comptime IS_MACOS = CompilationTarget.is_macos()

# ------------------------------------------------------------- open, fcntl
comptime O_RDWR = 2
comptime O_NONBLOCK = 0x4 if IS_MACOS else 0x800
comptime O_NOCTTY = 0x20000 if IS_MACOS else 0x100
comptime O_CLOEXEC = 0x1000000 if IS_MACOS else 0x80000
comptime F_GETFD = 1
comptime F_SETFD = 2
comptime F_GETFL = 3
comptime F_SETFL = 4
comptime FD_CLOEXEC = 1

# ------------------------------------------------------------------- ioctl
comptime TIOCGWINSZ = 0x40087468 if IS_MACOS else 0x5413
comptime TIOCSWINSZ = 0x80087467 if IS_MACOS else 0x5414

# ----------------------------------------------------------------- signals
comptime SIGHUP = 1
comptime SIGINT = 2
comptime SIGQUIT = 3
comptime SIGKILL = 9
comptime SIGPIPE = 13
comptime SIGTERM = 15
comptime SIGSTOP = 17 if IS_MACOS else 19
comptime SIGTSTP = 18 if IS_MACOS else 20
comptime SIGCONT = 19 if IS_MACOS else 18
comptime SIGCHLD = 20 if IS_MACOS else 17
comptime SIGWINCH = 28

comptime EAGAIN = 35 if IS_MACOS else 11

# ------------------------------------------------------------ struct termios
# Linux: four 32-bit flag words, c_line, c_cc[32], two speeds: 60 bytes.
# macOS: four 64-bit flag words (tcflag_t is unsigned long), c_cc[20], two speeds: 72.
comptime TERMIOS_SIZE = 72 if IS_MACOS else 60
comptime TC_FLAG_BYTES = 8 if IS_MACOS else 4
comptime TC_IFLAG = 0
comptime TC_OFLAG = 8 if IS_MACOS else 4
comptime TC_CFLAG = 16 if IS_MACOS else 8
comptime TC_LFLAG = 24 if IS_MACOS else 12
comptime TC_CC = 32 if IS_MACOS else 17
comptime VMIN = 16 if IS_MACOS else 6
comptime VTIME = 17 if IS_MACOS else 5
comptime TCSAFLUSH = 2

comptime BRKINT = 0x2
comptime ICRNL = 0x100
comptime INPCK = 0x10
comptime ISTRIP = 0x20
comptime IXON = 0x200 if IS_MACOS else 0x400
comptime OPOST = 0x1
comptime CS8 = 0x300 if IS_MACOS else 0x30
comptime ECHO = 0x8
comptime ICANON = 0x100 if IS_MACOS else 0x2
comptime ISIG = 0x80 if IS_MACOS else 0x1
comptime IEXTEN = 0x400 if IS_MACOS else 0x8000

# ----------------------------------------------------------- struct sigaction
# Linux: sa_handler 8B @ 0, sa_mask 128B @ 8, sa_flags 4B @ 136 (or 152B total).
# macOS (arm64): sa_handler 8B @ 0, sa_mask 4B @ 8, sa_flags 4B @ 12 (16B total).
comptime SIGACTION_SIZE = 16 if IS_MACOS else 152
comptime SA_FLAGS_OFFSET = 12 if IS_MACOS else 136


def init_sigaction(handler: Int, flags: Int = 0) -> List[UInt8]:
    var b = List[UInt8](length=SIGACTION_SIZE, fill=0)
    for i in range(8):
        b[i] = UInt8((handler >> (8 * i)) & 0xFF)
    for i in range(4):
        b[SA_FLAGS_OFFSET + i] = UInt8((flags >> (8 * i)) & 0xFF)
    return b^


# ------------------------------------------------- Linux-only facilities
# Where these are missing TurboMojo falls back: the window size is polled instead of
# signalfd/eventfd waking the loop, files are checked by time and size instead of
# inotify, the crash handler keeps its page in an ordinary file mapping instead of
# memfd, descriptors are duplicated with dup2 + FD_CLOEXEC instead of dup3.
comptime HAVE_EVENTFD = not IS_MACOS
comptime HAVE_INOTIFY = not IS_MACOS
comptime HAVE_MEMFD = not IS_MACOS
comptime HAVE_STATX = not IS_MACOS
comptime HAVE_DUP3 = not IS_MACOS


def tc_get(t: List[UInt8], off: Int) -> Int:
    """A termios flag word (32 bits on Linux, 64 on macOS)."""
    var v = 0
    for k in range(TC_FLAG_BYTES):
        v |= Int(t[off + k]) << (8 * k)
    return v


def tc_set(mut t: List[UInt8], off: Int, v: Int):
    for k in range(TC_FLAG_BYTES):
        t[off + k] = UInt8((v >> (8 * k)) & 0xFF)


def raw_termios(saved: List[UInt8]) -> List[UInt8]:
    """The terminal settings of raw mode, made from the saved ones (cfmakeraw, less
    the output side): no echo, no line editing, no signals from keys, 8-bit, reads
    that never wait (the event loop waits in poll)."""
    var t = saved.copy()
    tc_set(t, TC_IFLAG, tc_get(t, TC_IFLAG) & ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON))
    tc_set(t, TC_OFLAG, tc_get(t, TC_OFLAG) & ~OPOST)
    tc_set(t, TC_CFLAG, tc_get(t, TC_CFLAG) | CS8)
    tc_set(t, TC_LFLAG, tc_get(t, TC_LFLAG) & ~(ECHO | ICANON | IEXTEN | ISIG))
    t[TC_CC + VMIN] = 0
    t[TC_CC + VTIME] = 0
    return t^


# --------------------------------------------------------- portable helpers
def dup_cloexec(fd: Int32, target: Int) -> Int32:
    """Duplicate `fd` onto the descriptor number `target`, close-on-exec."""
    comptime if HAVE_DUP3:
        return external_call["dup3", Int32](fd, Int32(target), Int32(O_CLOEXEC))
    else:
        var d = external_call["dup2", Int32](fd, Int32(target))
        if Int(d) == target:
            _ = external_call["fcntl", Int32](Int32(target), Int32(F_SETFD), Int32(FD_CLOEXEC))
        return d


def close_from(low: Int):
    """Close every descriptor from `low` up (in a child after fork: C calls only). Linux
    has close_range; macOS has not (found by linking for it, P11-12), so there each one
    up to the table size is closed."""
    comptime if IS_MACOS:
        var top = Int(external_call["getdtablesize", Int32]())
        for fd in range(low, min(top, 65536)):
            _ = external_call["close", Int32](Int32(fd))
    else:
        _ = external_call["close_range", Int32](UInt32(low), UInt32(0xFFFFFFFF), Int32(0))


def make_nonblocking(fd: Int):
    var fl = external_call["fcntl", Int32](Int32(fd), Int32(F_GETFL), Int32(0))
    _ = external_call["fcntl", Int32](Int32(fd), Int32(F_SETFL), fl | Int32(O_NONBLOCK))


def le_at(b: List[UInt8], off: Int, n: Int) -> Int:
    var v = 0
    for i in range(n):
        v |= Int(b[off + i]) << (8 * i)
    return v


def stat_size_mtime(path: String) -> Tuple[Bool, Int, Int, Int]:
    """(exists, size, mtime seconds, mtime nanoseconds) of a file. Linux: statx(2),
    whose layout is the same on every architecture. macOS: stat(2) with the 64-bit-inode
    `struct stat` (st_mtimespec at 48, st_size at 96) - unverified."""
    var p = String(path)
    var buf = List[UInt8](length=256, fill=0)
    comptime if HAVE_STATX:
        # statx(AT_FDCWD, path, flags=0, STATX_MTIME | STATX_SIZE, &buf)
        var r = external_call["statx", Int32](Int32(-100), p.as_c_string_span(), Int32(0), UInt32(0x40 | 0x200), buf.unsafe_ptr())
        if Int(r) != 0:
            return (False, 0, 0, 0)
        return (True, le_at(buf, 40, 8), le_at(buf, 112, 8), le_at(buf, 120, 4))
    else:
        var r = external_call["stat", Int32](p.as_c_string_span(), buf.unsafe_ptr())
        if Int(r) != 0:
            return (False, 0, 0, 0)
        return (True, le_at(buf, 96, 8), le_at(buf, 48, 8), le_at(buf, 56, 8))
