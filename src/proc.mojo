"""A child process with pipes in both directions, driven without blocking.

popen() only gives one direction, so the child's standard input comes from a pipe created
here: the shell that popen starts redirects its stdin from that pipe's read end, and the
parent keeps the write end. Output is read through popen's stream. Both ends are
non-blocking: reads return what is there, and writes go through a queue that is flushed as
the child accepts data, so a busy or dead child can never stall the IDE."""
from std.ffi import external_call
from std.collections import List
from util import popen_read, shell_quote, str_bytes, bytes_to_str, SIGTERM

comptime SIGPIPE = 13
comptime SIGKILL = 9


def ignore_sigpipe():
    """Writing to a pipe whose reader has died must return an error, not kill us."""
    var act = List[UInt64](length=24, fill=0)
    act[0] = UInt64(1)                      # sa_handler = SIG_IGN
    var old = List[UInt64](length=24, fill=0)
    _ = external_call["sigaction", Int32](Int32(SIGPIPE), act.unsafe_ptr(), old.unsafe_ptr())


def set_nonblocking(fd: Int):
    var fl = external_call["fcntl", Int32](Int32(fd), Int32(3), Int32(0))
    _ = external_call["fcntl", Int32](Int32(fd), Int32(4), fl | Int32(2048))


struct Proc(Copyable, Movable):
    var fp: Int                 # popen stream (child's stdout)
    var out_fd: Int             # descriptor behind fp, non-blocking; poll this
    var in_fd: Int              # write end of the child's stdin, non-blocking
    var pid: Int                # 0 until the child has announced it
    var running: Bool           # started and not yet stopped
    var eof: Bool               # the child closed its output (it has exited or is exiting)
    var inbox: List[UInt8]      # bytes read but not yet taken
    var outbox: List[UInt8]     # bytes waiting to be written
    var write_failed: Bool      # the child can no longer be written to
    var exit_status: Int        # wait status after stop(), -1 before

    def __init__(out self):
        self.fp = 0
        self.out_fd = -1
        self.in_fd = -1
        self.pid = 0
        self.running = False
        self.eof = False
        self.inbox = List[UInt8]()
        self.outbox = List[UInt8]()
        self.write_failed = False
        self.exit_status = -1

    def start(mut self, cmd: String, stderr_path: String = "/dev/null") -> Bool:
        """Start `cmd` through the shell. Its stderr is appended to `stderr_path`."""
        if self.running:
            return False
        ignore_sigpipe()
        var fds = List[Int32](length=2, fill=0)
        if Int(external_call["pipe", Int32](fds.unsafe_ptr())) != 0:
            return False
        var in_r = Int(fds[0])
        var in_w = Int(fds[1])
        # the child must not inherit the write end, or it would never see end-of-input
        _ = external_call["fcntl", Int32](Int32(in_w), Int32(2), Int32(1))
        var line = "echo __PID__$$; exec " + cmd + " <&" + String(in_r) + " 2>>" + shell_quote(stderr_path)
        var fp = popen_read(line)
        _ = external_call["close", Int32](Int32(in_r))
        if fp == 0:
            _ = external_call["close", Int32](Int32(in_w))
            return False
        self.fp = fp
        self.out_fd = Int(external_call["fileno", Int32](fp))
        self.in_fd = in_w
        set_nonblocking(self.out_fd)
        set_nonblocking(self.in_fd)
        self.pid = 0
        self.running = True
        self.eof = False
        self.inbox.clear()
        self.outbox.clear()
        self.write_failed = False
        self.exit_status = -1
        return True

    def read_available(mut self) -> Int:
        """Move whatever the child has written into `inbox`. Returns the bytes added."""
        if not self.running or self.eof:
            return 0
        var buf = List[UInt8](length=65536, fill=0)
        var total = 0
        for _ in range(64):
            var n = external_call["read", Int](Int32(self.out_fd), buf.unsafe_ptr(), Int(65536))
            if n > 0:
                for k in range(n):
                    self.inbox.append(buf[k])
                total += n
            else:
                if n == 0:
                    self.eof = True
                break
        if self.pid == 0:
            self.take_pid_line()
        return total

    def take_pid_line(mut self):
        """The first line the shell prints is `__PID__<n>`; strip it from the stream."""
        var nl = -1
        for k in range(len(self.inbox)):
            if self.inbox[k] == 10:
                nl = k
                break
        if nl < 0:
            return
        var digits = List[UInt8]()
        for k in range(7, nl):
            digits.append(self.inbox[k])
        try:
            self.pid = atol(bytes_to_str(digits))
        except:
            self.pid = -1
        var rest = List[UInt8]()
        for k in range(nl + 1, len(self.inbox)):
            rest.append(self.inbox[k])
        self.inbox = rest^

    def take(mut self) -> List[UInt8]:
        """Take everything read so far (once the child's pid line has been consumed)."""
        var out = List[UInt8]()
        if self.pid == 0:
            return out^
        out = self.inbox.copy()
        self.inbox.clear()
        return out^

    def write(mut self, data: List[UInt8]):
        """Queue bytes for the child and send as much as it accepts right now."""
        for b in data:
            self.outbox.append(b)
        self.flush()

    def flush(mut self):
        if not self.running or self.write_failed or len(self.outbox) == 0:
            return
        var off = 0
        var n = len(self.outbox)
        while off < n:
            var w = external_call["write", Int](Int32(self.in_fd), self.outbox.unsafe_ptr().unsafe_offset(off), n - off)
            if w > 0:
                off += w
            else:
                # the pipe is full (try again later) or the reader is gone
                if not self.alive():
                    self.write_failed = True
                break
        if off > 0:
            var rest = List[UInt8]()
            for k in range(off, n):
                rest.append(self.outbox[k])
            self.outbox = rest^

    def wants_write(self) -> Bool:
        return self.running and not self.write_failed and len(self.outbox) > 0

    def alive(self) -> Bool:
        """True while the child process exists (unknown pid counts as alive until EOF)."""
        if not self.running or self.eof:
            return False
        if self.pid <= 0:
            return True
        return Int(external_call["kill", Int32](Int32(self.pid), Int32(0))) == 0

    def close_input(mut self):
        """Signal end-of-input to the child."""
        if self.in_fd >= 0:
            _ = external_call["close", Int32](Int32(self.in_fd))
            self.in_fd = -1
            self.write_failed = True

    def stop(mut self) -> Int:
        """End the child: close its input, ask it to terminate, force it if it does not
        go within half a second, and collect its exit status."""
        if not self.running:
            return self.exit_status
        self.close_input()
        _ = self.read_available()
        if self.pid > 0 and not self.eof:
            _ = external_call["kill", Int32](Int32(self.pid), Int32(SIGTERM))
            # a child that has exited closes its output, which shows up as end-of-file
            for _ in range(50):
                _ = self.read_available()
                if self.eof:
                    break
                _ = external_call["usleep", Int32](UInt32(10000))
            if not self.eof:
                _ = external_call["kill", Int32](Int32(self.pid), Int32(SIGKILL))
        self.exit_status = Int(external_call["pclose", Int32](self.fp))
        self.running = False
        self.eof = True
        self.fp = 0
        self.out_fd = -1
        return self.exit_status
