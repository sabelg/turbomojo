"""Signal handling for the event loop.

The Mojo runtime starts worker threads before main() runs, and a signal sent to the process
may be delivered on any of them, so blocking signals in the main thread (signalfd) is not
reliable. Instead a minimal handler is installed; it only adds to an eventfd, which the
event loop polls. The handler makes one async-signal-safe call and allocates nothing.

The eventfd lives at a fixed descriptor number because the handler cannot carry state."""
from std.ffi import external_call
from std.collections import List
from util import SIGHUP, SIGINT, SIGTERM, SIGCONT, SIGTSTP, SIGWINCH

comptime SIGNAL_EVENT_FD = 250      # fixed descriptor the handler writes to
comptime EFD_FLAGS = 0x80800        # EFD_NONBLOCK | EFD_CLOEXEC
comptime O_CLOEXEC = 0x80000


def signal_slot(sig: Int) -> Int:
    """Each managed signal gets its own byte of the 64-bit event counter."""
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
    """The C-level handler: record the signal in the eventfd and return."""
    var slot = signal_slot(Int(sig))
    _ = external_call["eventfd_write", Int32](Int32(SIGNAL_EVENT_FD), UInt64(1) << UInt64(8 * slot))


struct SignalFd(Copyable, Movable):
    var fd: Int

    def __init__(out self):
        self.fd = -1

    def active(self) -> Bool:
        return self.fd >= 0

    def open(mut self) -> Bool:
        """Create the event descriptor and install the handlers. False if unavailable
        (the caller then falls back to polling the terminal size)."""
        if self.fd >= 0:
            return True
        # refuse to clobber a descriptor that is already in use
        if Int(external_call["fcntl", Int32](Int32(SIGNAL_EVENT_FD), Int32(1), Int32(0))) != -1:
            return False
        var e = external_call["eventfd", Int32](UInt32(0), Int32(EFD_FLAGS))
        if Int(e) < 0:
            return False
        var d = external_call["dup3", Int32](e, Int32(SIGNAL_EVENT_FD), Int32(O_CLOEXEC))
        _ = external_call["close", Int32](e)
        if Int(d) != SIGNAL_EVENT_FD:
            return False
        self.fd = SIGNAL_EVENT_FD
        for s in managed_signals():
            _ = external_call["signal", Int](Int32(s), on_signal_c)
        return True

    def read_all(self) -> List[Int]:
        """Signals received since the last call, each listed once (empty when none)."""
        var out = List[Int]()
        if self.fd < 0:
            return out^
        var v = List[UInt64](length=1, fill=0)
        if Int(external_call["eventfd_read", Int32](Int32(self.fd), v.unsafe_ptr())) != 0:
            return out^
        for s in managed_signals():
            if (v[0] >> UInt64(8 * signal_slot(s))) & UInt64(255) != 0:
                out.append(s)
        return out^

    def close(mut self):
        """Restore default signal behaviour and release the descriptor."""
        if self.fd < 0:
            return
        # a zeroed struct sigaction means SIG_DFL with no flags
        var dfl = List[UInt64](length=24, fill=0)
        var old = List[UInt64](length=24, fill=0)
        for s in managed_signals():
            _ = external_call["sigaction", Int32](Int32(s), dfl.unsafe_ptr(), old.unsafe_ptr())
        _ = external_call["close", Int32](Int32(self.fd))
        self.fd = -1


def send_signal(pid: Int, sig: Int):
    _ = external_call["kill", Int32](Int32(pid), Int32(sig))


def own_pid() -> Int:
    return Int(external_call["getpid", Int32]())
