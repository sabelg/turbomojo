"""Tests for src/platform.mojo (P9-03) on the system it is built on: every constant is
the system's own (read through Python's termios, os, fcntl, signal and errno modules,
which take them from the C headers), and raw_termios, applied with tcsetattr to a real
pseudo-terminal, gives the settings raw mode needs (read back by Python). The macOS
values cannot be checked here."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from platform import *
from signals import own_pid
from util import env_or, run_capture, run_system, shell_quote, write_file, read_file, str_bytes, bytes_to_str, which

comptime ASK = """import termios, os, fcntl, signal, errno
names = {
  "ECHO": termios.ECHO, "ICANON": termios.ICANON, "ISIG": termios.ISIG, "IEXTEN": termios.IEXTEN,
  "IXON": termios.IXON, "ICRNL": termios.ICRNL, "BRKINT": termios.BRKINT, "INPCK": termios.INPCK,
  "ISTRIP": termios.ISTRIP, "OPOST": termios.OPOST, "CS8": termios.CS8, "VMIN": termios.VMIN,
  "VTIME": termios.VTIME, "TCSAFLUSH": termios.TCSAFLUSH, "TIOCGWINSZ": termios.TIOCGWINSZ,
  "TIOCSWINSZ": termios.TIOCSWINSZ, "O_RDWR": os.O_RDWR, "O_NONBLOCK": os.O_NONBLOCK,
  "O_NOCTTY": os.O_NOCTTY, "O_CLOEXEC": os.O_CLOEXEC, "F_GETFD": fcntl.F_GETFD,
  "F_SETFD": fcntl.F_SETFD, "F_GETFL": fcntl.F_GETFL, "F_SETFL": fcntl.F_SETFL,
  "FD_CLOEXEC": fcntl.FD_CLOEXEC, "SIGHUP": signal.SIGHUP, "SIGINT": signal.SIGINT,
  "SIGQUIT": signal.SIGQUIT, "SIGKILL": signal.SIGKILL, "SIGPIPE": signal.SIGPIPE,
  "SIGTERM": signal.SIGTERM, "SIGSTOP": signal.SIGSTOP, "SIGTSTP": signal.SIGTSTP,
  "SIGCONT": signal.SIGCONT, "SIGCHLD": signal.SIGCHLD, "SIGWINCH": signal.SIGWINCH,
  "EAGAIN": errno.EAGAIN}
for k, v in names.items():
    print(k, v)
"""


def system_values() raises -> List[String]:
    var r = run_capture("python3 -c " + shell_quote(ASK))
    assert_equal(r.status, 0, bytes_to_str(r.out))
    var out = List[String]()
    for l in bytes_to_str(r.out).split("\n"):
        out.append(String(l))
    return out^


def value_of(lines: List[String], name: String) raises -> Int:
    for l in lines:
        if String(l).startswith(name + " "):
            return atol(String(String(l)[byte=name.byte_length() + 1:]).strip())
    assert_true(False, "the system has no " + name)
    return -1


def test_the_constants_are_the_systems() raises:
    if which("python3").byte_length() == 0:
        return
    assert_false(IS_MACOS)                     # (these tests run on Linux)
    var v = system_values()
    assert_equal(ECHO, value_of(v, "ECHO"))
    assert_equal(ICANON, value_of(v, "ICANON"))
    assert_equal(ISIG, value_of(v, "ISIG"))
    assert_equal(IEXTEN, value_of(v, "IEXTEN"))
    assert_equal(IXON, value_of(v, "IXON"))
    assert_equal(ICRNL, value_of(v, "ICRNL"))
    assert_equal(BRKINT, value_of(v, "BRKINT"))
    assert_equal(INPCK, value_of(v, "INPCK"))
    assert_equal(ISTRIP, value_of(v, "ISTRIP"))
    assert_equal(OPOST, value_of(v, "OPOST"))
    assert_equal(CS8, value_of(v, "CS8"))
    assert_equal(VMIN, value_of(v, "VMIN"))
    assert_equal(VTIME, value_of(v, "VTIME"))
    assert_equal(TCSAFLUSH, value_of(v, "TCSAFLUSH"))
    assert_equal(TIOCGWINSZ, value_of(v, "TIOCGWINSZ"))
    assert_equal(TIOCSWINSZ, value_of(v, "TIOCSWINSZ"))
    assert_equal(O_RDWR, value_of(v, "O_RDWR"))
    assert_equal(O_NONBLOCK, value_of(v, "O_NONBLOCK"))
    assert_equal(O_NOCTTY, value_of(v, "O_NOCTTY"))
    assert_equal(O_CLOEXEC, value_of(v, "O_CLOEXEC"))
    assert_equal(F_GETFD, value_of(v, "F_GETFD"))
    assert_equal(F_SETFD, value_of(v, "F_SETFD"))
    assert_equal(F_GETFL, value_of(v, "F_GETFL"))
    assert_equal(F_SETFL, value_of(v, "F_SETFL"))
    assert_equal(FD_CLOEXEC, value_of(v, "FD_CLOEXEC"))
    assert_equal(SIGHUP, value_of(v, "SIGHUP"))
    assert_equal(SIGINT, value_of(v, "SIGINT"))
    assert_equal(SIGQUIT, value_of(v, "SIGQUIT"))
    assert_equal(SIGKILL, value_of(v, "SIGKILL"))
    assert_equal(SIGPIPE, value_of(v, "SIGPIPE"))
    assert_equal(SIGTERM, value_of(v, "SIGTERM"))
    assert_equal(SIGSTOP, value_of(v, "SIGSTOP"))
    assert_equal(SIGTSTP, value_of(v, "SIGTSTP"))
    assert_equal(SIGCONT, value_of(v, "SIGCONT"))
    assert_equal(SIGCHLD, value_of(v, "SIGCHLD"))
    assert_equal(SIGWINCH, value_of(v, "SIGWINCH"))
    assert_equal(EAGAIN, value_of(v, "EAGAIN"))


comptime TTY = """import ctypes, os, sys, termios
libc = ctypes.CDLL(None)
m, s = os.openpty()
size = int(sys.argv[2])
if sys.argv[1] == "get":
    buf = ctypes.create_string_buffer(size)
    assert libc.tcgetattr(s, buf) == 0
    sys.stdout.write(buf.raw.hex())
else:
    raw = bytes.fromhex(open(sys.argv[3]).read())
    buf = ctypes.create_string_buffer(raw, size)
    assert libc.tcsetattr(s, termios.TCSAFLUSH, buf) == 0
    a = termios.tcgetattr(s)
    print(a[0], a[1], a[2], a[3], a[6][termios.VMIN], a[6][termios.VTIME])
"""


def test_raw_mode_on_a_real_pty() raises:
    if which("python3").byte_length() == 0:
        return
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-platform-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/tty.py", str_bytes(TTY))
    var got = run_capture("python3 " + shell_quote(d + "/tty.py") + " get " + String(TERMIOS_SIZE))
    assert_equal(got.status, 0, bytes_to_str(got.out))
    var hx = bytes_to_str(got.out)
    assert_equal(hx.byte_length(), TERMIOS_SIZE * 2)
    var saved = List[UInt8]()
    for k in range(TERMIOS_SIZE):
        saved.append(UInt8(atol(String(hx[byte=2 * k:2 * k + 2]), 16)))
    # a fresh pty is in cooked mode: echo and line editing on (read at our offsets)
    assert_true(tc_get(saved, TC_LFLAG) & ECHO != 0)
    assert_true(tc_get(saved, TC_LFLAG) & ICANON != 0)
    var raw = raw_termios(saved)
    var out = String("")
    for b in raw:
        var h = hex(Int(b))
        var digits = String(h[byte=2:])
        out += ("0" + digits) if digits.byte_length() == 1 else digits
    _ = write_file(d + "/raw.hex", str_bytes(out))
    var back = run_capture("python3 " + shell_quote(d + "/tty.py") + " set " + String(TERMIOS_SIZE) + " " + shell_quote(d + "/raw.hex"))
    assert_equal(back.status, 0, bytes_to_str(back.out))
    var f = String(bytes_to_str(back.out).strip()).split(" ")
    var iflag = atol(String(f[0]))
    var oflag = atol(String(f[1]))
    var cflag = atol(String(f[2]))
    var lflag = atol(String(f[3]))
    assert_equal(lflag & (ECHO | ICANON | ISIG | IEXTEN), 0)       # what raw mode turns off...
    assert_equal(iflag & (BRKINT | ICRNL | INPCK | ISTRIP | IXON), 0)
    assert_equal(oflag & OPOST, 0)
    assert_equal(cflag & CS8, CS8)                                 # ...and on
    assert_equal(atol(String(f[4])), 0)                            # VMIN
    assert_equal(atol(String(f[5])), 0)                            # VTIME
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_helpers() raises:
    var st = stat_size_mtime("/etc/hostname")
    assert_true(st[0])
    assert_true(st[1] > 0 and st[2] > 1000000000)
    assert_false(stat_size_mtime("/no/such/file")[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
