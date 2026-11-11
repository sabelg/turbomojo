"""A program running on a pseudo-terminal: what the integrated terminal and the REPL run.

The pty is opened with posix_openpt / grantpt / unlockpt / ptsname_r, then the child is
forked: it becomes a session leader (setsid), opens the pty's slave side - which makes
it its controlling terminal - as standard input, output and error, closes every other
descriptor the IDE has open, puts the signals the IDE ignores back to their defaults,
and execs the program. Everything the child needs (the strings, the pointer array) is
made before the fork, so the child only calls C functions until it execs.

The master side is non-blocking: `read_available` takes what is there, writes go
through a queue that is flushed as the program accepts them. When the program ends,
reading the master gives an error (EIO); `poll_exit` collects the exit status without
waiting. `resize` tells the program the terminal's new size (it receives SIGWINCH).
"""
from std.ffi import external_call
from std.collections import List
from util import bytes_to_str

comptime O_RDWR = 2
comptime O_NOCTTY = 0x100
comptime TIOCSWINSZ = 0x5414     # Linux
comptime WNOHANG = 1
comptime SIGHUP = 1
comptime SIGKILL = 9
comptime SIGPIPE = 13


def c_string(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    out.append(0)
    return out^


def exit_code(status: Int) -> Int:
    """The exit code in a wait status, or 128 + the signal that ended the program."""
    if status & 127 == 0:
        return (status >> 8) & 255
    return 128 + (status & 127)


struct Pty(Copyable, Movable):
    var master: Int             # the IDE's side (-1: none)
    var pid: Int                # the program (0: none)
    var slave_name: String
    var running: Bool           # started, and its exit not collected yet
    var eof: Bool               # the program's side is closed (it has ended)
    var status: Int             # its wait status once collected (-1 before)
    var inbox: List[UInt8]      # read, not yet taken
    var outbox: List[UInt8]     # waiting to be written
    var rows: Int
    var cols: Int

    def __init__(out self):
        self.master = -1
        self.pid = 0
        self.slave_name = ""
        self.running = False
        self.eof = False
        self.status = -1
        self.inbox = List[UInt8]()
        self.outbox = List[UInt8]()
        self.rows = 24
        self.cols = 80

    def start(mut self, argv: List[String], cwd: String, env: List[String], rows: Int, cols: Int) -> Bool:
        """Start argv[0] (looked up on PATH) with these arguments, in `cwd`, with
        "NAME=value" entries added to its environment, on a terminal of rows x cols."""
        if self.running or len(argv) == 0:
            return False
        var m = Int(external_call["posix_openpt", Int32](Int32(O_RDWR | O_NOCTTY)))
        if m < 0:
            return False
        var name = List[UInt8](length=128, fill=0)
        if Int(external_call["grantpt", Int32](Int32(m))) != 0 or Int(external_call["unlockpt", Int32](Int32(m))) != 0 or Int(external_call["ptsname_r", Int32](Int32(m), name.unsafe_ptr(), Int(128))) != 0:
            _ = external_call["close", Int32](Int32(m))
            return False
        var n = 0
        while n < len(name) and name[n] != 0:
            n += 1
        var nb = List[UInt8]()
        for i in range(n):
            nb.append(name[i])
        self.slave_name = bytes_to_str(nb)
        self.master = m
        self.rows = rows
        self.cols = cols
        self.set_size()
        # everything the child uses, made now
        var args = List[List[UInt8]]()
        for a in argv:
            args.append(c_string(a))
        var ptrs = List[Int](length=len(args) + 1, fill=0)
        for i in range(len(args)):
            ptrs[i] = Int(args[i].unsafe_ptr())
        var envs = List[List[UInt8]]()
        envs.append(c_string("TERM=xterm-256color"))
        envs.append(c_string("COLORTERM=truecolor"))
        for e in env:
            envs.append(c_string(e))
        var dir = c_string(cwd)
        var slave = self.slave_name.copy()
        var dfl = List[UInt64](length=24, fill=0)       # sigaction: SIG_DFL
        var old = List[UInt64](length=24, fill=0)
        var pid = Int(external_call["fork", Int32]())
        if pid == 0:
            # the child: no Mojo allocations from here on, only C calls, then exec
            _ = external_call["setsid", Int32]()
            var s = Int(external_call["openat", Int32](Int32(-100), slave.as_c_string_span(), Int32(O_RDWR), Int32(0)))
            if s >= 0:
                _ = external_call["dup2", Int32](Int32(s), Int32(0))
                _ = external_call["dup2", Int32](Int32(s), Int32(1))
                _ = external_call["dup2", Int32](Int32(s), Int32(2))
            _ = external_call["close_range", Int32](UInt32(3), UInt32(0xFFFFFFFF), Int32(0))
            _ = external_call["sigaction", Int32](Int32(SIGPIPE), dfl.unsafe_ptr(), old.unsafe_ptr())
            for i in range(len(envs)):
                _ = external_call["putenv", Int32](envs[i].unsafe_ptr())
            if cwd.byte_length() > 0:
                _ = external_call["chdir", Int32](dir.unsafe_ptr())
            _ = external_call["execvp", Int32](args[0].unsafe_ptr(), ptrs.unsafe_ptr())
            external_call["_exit", NoneType](Int32(127))
        # (the buffers above must live until the fork has copied them)
        _ = name[0]
        _ = ptrs[0]
        _ = dir[0]
        _ = slave.byte_length()
        _ = dfl[0]
        _ = old[0]
        _ = len(args)
        _ = len(envs)
        if pid < 0:
            _ = external_call["close", Int32](Int32(m))
            self.master = -1
            return False
        var fl = external_call["fcntl", Int32](Int32(m), Int32(3), Int32(0))
        _ = external_call["fcntl", Int32](Int32(m), Int32(4), fl | Int32(2048))     # O_NONBLOCK
        self.pid = pid
        self.running = True
        self.eof = False
        self.status = -1
        self.inbox.clear()
        self.outbox.clear()
        return True

    def fd(self) -> Int:
        return self.master if not self.eof else -1

    def set_size(self):
        var ws = List[UInt16](length=4, fill=0)
        ws[0] = UInt16(self.rows)
        ws[1] = UInt16(self.cols)
        _ = external_call["ioctl", Int32](Int32(self.master), UInt64(TIOCSWINSZ), ws.unsafe_ptr())

    def resize(mut self, rows: Int, cols: Int):
        """The terminal has a new size; the program is told (SIGWINCH)."""
        if rows == self.rows and cols == self.cols:
            return
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        if self.master >= 0:
            self.set_size()

    def read_available(mut self) -> Int:
        """Read what the program has written; returns the number of bytes."""
        if self.master < 0 or self.eof:
            return 0
        var buf = List[UInt8](length=16384, fill=0)
        var got = 0
        for _ in range(64):
            var r = external_call["read", Int](Int32(self.master), buf.unsafe_ptr(), Int(16384))
            if r > 0:
                for i in range(r):
                    self.inbox.append(buf[i])
                got += r
                continue
            if r == 0:
                self.eof = True
            elif self.hung_up():
                self.eof = True                 # EIO: the program's side is closed
            break
        return got

    def hung_up(self) -> Bool:
        """The other side of the pty is closed (poll says POLLHUP)."""
        var pf = List[Int32](length=2, fill=0)
        pf[0] = Int32(self.master)
        pf[1] = Int32(1)
        var r = external_call["poll", Int32](pf.unsafe_ptr(), UInt64(1), Int32(0))
        if Int(r) <= 0:
            return False
        return ((Int(pf[1]) >> 16) & 0x18) != 0      # POLLHUP or POLLERR

    def take(mut self) -> List[UInt8]:
        var out = self.inbox^
        self.inbox = List[UInt8]()
        return out^

    def write(mut self, data: List[UInt8]):
        for b in data:
            self.outbox.append(b)
        self.flush()

    def write_text(mut self, text: String):
        var b = List[UInt8]()
        for c in text.as_bytes():
            b.append(c)
        self.write(b)

    def flush(mut self):
        if self.master < 0 or self.eof or len(self.outbox) == 0:
            return
        var w = external_call["write", Int](Int32(self.master), self.outbox.unsafe_ptr(), len(self.outbox))
        if w > 0:
            var rest = List[UInt8]()
            for i in range(w, len(self.outbox)):
                rest.append(self.outbox[i])
            self.outbox = rest^

    def wants_write(self) -> Bool:
        return len(self.outbox) > 0 and not self.eof

    def poll_exit(mut self) -> Bool:
        """True once the program has ended (its status is then in `status`)."""
        if not self.running:
            return self.pid > 0
        var st = List[Int32](length=1, fill=0)
        var r = Int(external_call["waitpid", Int32](Int32(self.pid), st.unsafe_ptr(), Int32(WNOHANG)))
        if r == self.pid:
            self.status = Int(st[0])
            self.running = False
            return True
        return False

    def stop(mut self) -> Int:
        """End the program (SIGHUP to its process group, as a closing terminal does;
        SIGKILL if it is still there after half a second) and close the pty. Returns
        the wait status."""
        if self.running:
            _ = external_call["kill", Int32](Int32(-self.pid), Int32(SIGHUP))
            for _ in range(50):
                if self.poll_exit():
                    break
                _ = external_call["usleep", Int32](UInt32(10000))
            if self.running:
                _ = external_call["kill", Int32](Int32(-self.pid), Int32(SIGKILL))
                _ = external_call["kill", Int32](Int32(self.pid), Int32(SIGKILL))
                var st = List[Int32](length=1, fill=0)
                _ = external_call["waitpid", Int32](Int32(self.pid), st.unsafe_ptr(), Int32(0))
                self.status = Int(st[0])
                self.running = False
        if self.master >= 0:
            _ = external_call["close", Int32](Int32(self.master))
            self.master = -1
        self.eof = True
        return self.status
