"""Crash guard: restore the terminal and write a crash log when the IDE dies hard.

A failed bounds check or a memory fault kills the process through a signal. Without help
the terminal is left in raw mode, on the alternate screen, with mouse reporting on. The
guard installs a handler for the fatal signals that

  1. puts the terminal back (escape sequences + the saved termios),
  2. tells the user on the terminal that the IDE crashed and where the log is,
  3. writes a header to the crash log, then
  4. re-installs the Mojo runtime's own handler and re-raises, so the runtime still prints
     its stack trace (into the log, because stderr points there while the UI is up).

The handler cannot use any program state, so everything it needs lives behind fixed file
descriptors: a memory page (memfd) with the saved termios and signal actions, the log, and
a copy of the original stderr. It performs only system calls and allocates nothing."""
from std.ffi import external_call
from std.collections import List
from util import run_system, shell_quote, dirname, str_bytes

comptime CRASH_PAGE_FD = 251
comptime CRASH_LOG_FD = 252
comptime SAVED_STDERR_FD = 253

comptime PAGE_SIZE = 4096
comptime OFF_TERMIOS = 0          # 60 bytes of struct termios
comptime OFF_TUI_FLAG = 126       # 1 while the full-screen UI owns the terminal
comptime OFF_ACTIONS = 128        # saved struct sigaction per fatal signal
comptime ACTION_SLOT = 160
comptime OFF_SCRATCH = 1280
comptime OFF_HEADER_LEN = 2046    # big-endian uint16
comptime OFF_HEADER = 2048        # session header text for the log
comptime HEADER_MAX = 1024
comptime SIGACTION_BYTES = 152

comptime SIGILL = 4
comptime SIGTRAP = 5
comptime SIGABRT = 6
comptime SIGBUS = 7
comptime SIGFPE = 8
comptime SIGSEGV = 11


def crash_slot(sig: Int) -> Int:
    if sig == SIGSEGV:
        return 0
    if sig == SIGBUS:
        return 1
    if sig == SIGILL:
        return 2
    if sig == SIGFPE:
        return 3
    if sig == SIGABRT:
        return 4
    if sig == SIGTRAP:
        return 5
    return -1


def fatal_signals() -> List[Int]:
    var out = List[Int]()
    for s in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP]:
        out.append(s)
    return out^


def crash_handler_c(sig: Int32):
    """Runs on a fatal signal. System calls only; no allocation."""
    var p = external_call["mmap", Pointer[UInt8, MutAnyOrigin]](
        Int(0), Int(PAGE_SIZE), Int32(3), Int32(1), Int32(CRASH_PAGE_FD), Int(0)
    )
    if p[unsafe_offset=OFF_TUI_FLAG] == 1:
        var esc = "\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[0 q\x1b[?25h\x1b[?1049l"
        _ = external_call["write", Int](Int(1), esc.unsafe_ptr(), esc.byte_length())
        _ = external_call["tcsetattr", Int32](Int32(0), Int32(0), p)
    var note = "\nTurboMojo crashed. The terminal has been restored; see the crash log:\n  "
    _ = external_call["write", Int](Int(SAVED_STDERR_FD), note.unsafe_ptr(), note.byte_length())
    var hlen = Int(p[unsafe_offset=OFF_HEADER_LEN]) * 256 + Int(p[unsafe_offset=OFF_HEADER_LEN + 1])
    # the header starts with the log path on its own line
    _ = external_call["write", Int](Int(SAVED_STDERR_FD), p.unsafe_offset(OFF_HEADER), hlen)
    var sep = "\n=== crash ===\n"
    _ = external_call["write", Int](Int(CRASH_LOG_FD), sep.unsafe_ptr(), sep.byte_length())
    _ = external_call["write", Int](Int(CRASH_LOG_FD), p.unsafe_offset(OFF_HEADER), hlen)
    # hand over to the runtime's handler: it prints the stack trace and ends the process
    var slot = crash_slot(Int(sig))
    if slot >= 0:
        _ = external_call["sigaction", Int32](
            sig, p.unsafe_offset(OFF_ACTIONS + slot * ACTION_SLOT), p.unsafe_offset(OFF_SCRATCH)
        )
    _ = external_call["raise", Int32](sig)


def fd_in_use(fd: Int) -> Bool:
    return Int(external_call["fcntl", Int32](Int32(fd), Int32(1), Int32(0))) != -1


def move_fd(fd: Int32, target: Int) -> Bool:
    """Move a descriptor to a fixed number (close-on-exec) and close the original."""
    if Int(fd) < 0:
        return False
    var d = external_call["dup3", Int32](fd, Int32(target), Int32(0x80000))
    _ = external_call["close", Int32](fd)
    return Int(d) == target


def page_write(data: List[UInt8], n: Int, off: Int):
    _ = external_call["pwrite", Int](Int32(CRASH_PAGE_FD), data.unsafe_ptr(), n, off)


struct CrashGuard(Copyable, Movable):
    var installed: Bool
    var log_path: String

    def __init__(out self):
        self.installed = False
        self.log_path = ""

    def install(mut self, saved_termios: List[UInt8], log_path: String, header: String) -> Bool:
        """Set up the descriptors and handlers. `header` (pid, time, version...) is what
        the handler writes to the log; the log path is put on its first line."""
        if self.installed:
            return True
        if fd_in_use(CRASH_PAGE_FD) or fd_in_use(CRASH_LOG_FD) or fd_in_use(SAVED_STDERR_FD):
            return False
        _ = run_system("mkdir -p " + shell_quote(dirname(log_path)))
        var name = String("turbomojo-crash")
        if not move_fd(external_call["memfd_create", Int32](name.as_c_string_span(), UInt32(1)), CRASH_PAGE_FD):
            return False
        _ = external_call["ftruncate", Int32](Int32(CRASH_PAGE_FD), Int(PAGE_SIZE))
        var lp = String(log_path)
        # O_WRONLY | O_CREAT | O_APPEND, mode 0644
        if not move_fd(external_call["openat", Int32](Int32(-100), lp.as_c_string_span(), Int32(0x441), Int32(420)), CRASH_LOG_FD):
            _ = external_call["close", Int32](Int32(CRASH_PAGE_FD))
            return False
        if not move_fd(external_call["dup", Int32](Int32(2)), SAVED_STDERR_FD):
            _ = external_call["close", Int32](Int32(CRASH_PAGE_FD))
            _ = external_call["close", Int32](Int32(CRASH_LOG_FD))
            return False
        page_write(saved_termios, min(60, len(saved_termios)), OFF_TERMIOS)
        var h = str_bytes(log_path + "\n" + header + "\n")
        var hn = min(len(h), HEADER_MAX)
        page_write(h, hn, OFF_HEADER)
        var ln = List[UInt8]()
        ln.append(UInt8(hn >> 8))
        ln.append(UInt8(hn & 255))
        page_write(ln, 2, OFF_HEADER_LEN)
        # remember the runtime's handlers, then put ours in front of them
        for s in fatal_signals():
            var dfl = List[UInt64](length=24, fill=0)
            var old = List[UInt64](length=24, fill=0)
            _ = external_call["sigaction", Int32](Int32(s), dfl.unsafe_ptr(), old.unsafe_ptr())
            _ = external_call["pwrite", Int](
                Int32(CRASH_PAGE_FD), old.unsafe_ptr(), Int(SIGACTION_BYTES), OFF_ACTIONS + crash_slot(s) * ACTION_SLOT
            )
            _ = external_call["signal", Int](Int32(s), crash_handler_c)
        self.installed = True
        self.log_path = log_path
        return True

    def set_tui(self, on: Bool):
        """Tell the handler whether the full-screen UI is up. While it is, stderr goes to
        the crash log (anything printed there would only corrupt the screen)."""
        if not self.installed:
            return
        var flag = List[UInt8](length=1, fill=UInt8(1 if on else 0))
        page_write(flag, 1, OFF_TUI_FLAG)
        _ = external_call["dup2", Int32](Int32(CRASH_LOG_FD if on else SAVED_STDERR_FD), Int32(2))

    def uninstall(mut self):
        """Put the runtime's handlers and stderr back and release the descriptors."""
        if not self.installed:
            return
        self.set_tui(False)
        for s in fatal_signals():
            var saved = List[UInt64](length=24, fill=0)
            var old = List[UInt64](length=24, fill=0)
            _ = external_call["pread", Int](
                Int32(CRASH_PAGE_FD), saved.unsafe_ptr(), Int(SIGACTION_BYTES), OFF_ACTIONS + crash_slot(s) * ACTION_SLOT
            )
            _ = external_call["sigaction", Int32](Int32(s), saved.unsafe_ptr(), old.unsafe_ptr())
        for fd in [CRASH_PAGE_FD, CRASH_LOG_FD, SAVED_STDERR_FD]:
            _ = external_call["close", Int32](Int32(fd))
        self.installed = False
