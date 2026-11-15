"""Signal handling for the event loop.

The Mojo runtime starts worker threads before main() runs, and a signal sent to the process
may be delivered on any of them, so blocking signals in the main thread (signalfd) is not
reliable. Instead a minimal handler is installed; it only adds to an eventfd, which the
event loop polls. The handler makes one async-signal-safe call and allocates nothing.

The eventfd lives at a fixed descriptor number because the handler cannot carry state."""
from std.ffi import external_call
from std.collections import List
from util import SIGHUP, SIGINT, SIGTERM, SIGCONT, SIGTSTP, SIGWINCH

comptime SIGNAL_READ_FD = 250       # descriptor the event loop polls
comptime SIGNAL_WRITE_FD = 249      # descriptor the signal handler writes to
comptime SIGNAL_EVENT_FD = 250      # fixed descriptor alias
from platform import dup_cloexec, make_nonblocking


def signal_slot(sig: Int) -> Int:
    """Each managed signal gets its own bit in the signal mask."""
    if sig == SIGHUP:
        return 0
    if sig == SIGINT:
        return 1
    if sig == SIGTERM:
        return 2
    if sig == SIGCONT:
        return 3
    if sig == SIGTSTP:
        return 4
    if sig == SIGWINCH:
        return 5
    return 6


def managed_signals() -> List[Int]:
    var out = List[Int]()
    for s in [SIGHUP, SIGINT, SIGTERM, SIGCONT, SIGTSTP, SIGWINCH]:
        out.append(s)
    return out^


def on_signal_c(sig: Int32):
    """The C-level handler: async-signal-safe 1-byte write to self-pipe (no heap allocation)."""
    var b = UInt8(sig)
    _ = external_call["write", Int](Int32(SIGNAL_WRITE_FD), Pointer(to=b), Int(1))


struct SignalFd(Copyable, Movable):
    var fd: Int

    def __init__(out self):
        self.fd = -1

    def active(self) -> Bool:
        return self.fd >= 0

    def open(mut self) -> Bool:
        """Create the self-pipe pair and install handlers. Works on Linux and macOS."""
        if self.fd >= 0:
            return True
        # refuse to clobber descriptors that are already in use
        if Int(external_call["fcntl", Int32](Int32(SIGNAL_READ_FD), Int32(1), Int32(0))) != -1:
            return False
        if Int(external_call["fcntl", Int32](Int32(SIGNAL_WRITE_FD), Int32(1), Int32(0))) != -1:
            return False
        var fds = List[Int32](length=2, fill=0)
        if Int(external_call["pipe", Int32](fds.unsafe_ptr())) != 0:
            return False
        var r = dup_cloexec(fds[0], SIGNAL_READ_FD)
        var w = dup_cloexec(fds[1], SIGNAL_WRITE_FD)
        _ = external_call["close", Int32](fds[0])
        _ = external_call["close", Int32](fds[1])
        if Int(r) != SIGNAL_READ_FD or Int(w) != SIGNAL_WRITE_FD:
            return False
        make_nonblocking(SIGNAL_READ_FD)
        make_nonblocking(SIGNAL_WRITE_FD)
        self.fd = SIGNAL_READ_FD
        for s in managed_signals():
            _ = external_call["signal", Int](Int32(s), on_signal_c)
        return True

    def read_all(self) -> List[Int]:
        """Signals received since last call, each listed once in order of arrival."""
        var out = List[Int]()
        if self.fd < 0:
            return out^
        var buf = List[UInt8](length=128, fill=0)
        var seen_mask = 0
        while True:
            var n = external_call["read", Int](Int32(self.fd), buf.unsafe_ptr(), Int(128))
            if n <= 0:
                break
            for i in range(n):
                var sig = Int(buf[i])
                var slot = signal_slot(sig)
                if slot <= 5:
                    var bit = 1 << slot
                    if (seen_mask & bit) == 0:
                        seen_mask |= bit
                        out.append(sig)
        return out^

    def close(mut self):
        """Restore default signal behaviour and release pipe descriptors."""
        if self.fd < 0:
            return
        # a zeroed struct sigaction means SIG_DFL with no flags
        var dfl = List[UInt64](length=24, fill=0)
        var old = List[UInt64](length=24, fill=0)
        for s in managed_signals():
            _ = external_call["sigaction", Int32](Int32(s), dfl.unsafe_ptr(), old.unsafe_ptr())
        _ = external_call["close", Int32](Int32(SIGNAL_READ_FD))
        _ = external_call["close", Int32](Int32(SIGNAL_WRITE_FD))
        self.fd = -1


def send_signal(pid: Int, sig: Int):
    _ = external_call["kill", Int32](Int32(pid), Int32(sig))


def own_pid() -> Int:
    return Int(external_call["getpid", Int32]())
