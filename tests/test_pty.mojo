"""Tests for programs on a pseudo-terminal (src/pty.mojo). They start real programs
(sh, stty, cat) on real ptys."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from std.ffi import external_call
from pty import *
from term import wait_readable
from signals import own_pid
from util import bytes_to_str, env_or, run_system, read_file

comptime MS = 1000000


def now() -> Int:
    return Int(perf_counter_ns())


def collect(mut p: Pty, until: String, timeout_ms: Int = 5000) -> String:
    """Read until `until` was written (or the program ended / the time is up)."""
    var got = List[UInt8]()
    var deadline = now() + timeout_ms * MS
    while now() < deadline:
        var fds = List[Int]()
        fds.append(p.master)
        _ = wait_readable(fds, 20)
        p.flush()
        _ = p.read_available()
        for b in p.take():
            got.append(b)
        if until.byte_length() > 0 and bytes_to_str(got).find(until) >= 0:
            break
        if p.eof:
            break
    return bytes_to_str(got)


def wait_exit(mut p: Pty, timeout_ms: Int = 5000) -> Bool:
    var deadline = now() + timeout_ms * MS
    while now() < deadline:
        if p.poll_exit():
            return True
        _ = external_call["usleep", Int32](UInt32(10000))
    return False


def sh(script: String) -> List[String]:
    var a = List[String]()
    a.append("sh")
    a.append("-c")
    a.append(script)
    return a^


def alive(pid: Int) -> Bool:
    return Int(external_call["kill", Int32](Int32(pid), Int32(0))) == 0


def test_a_program_sees_a_terminal() raises:
    var p = Pty()
    var env = List[String]()
    env.append("TURBOMOJO_TEST=yes")
    var d = env_or("TMPDIR", "/tmp")
    assert_true(p.start(sh("tty; test -t 0 && test -t 1 && echo both-ttys; stty size; echo \"$TERM $TURBOMOJO_TEST\"; pwd; exit 7"), d, env, 30, 100))
    assert_true(p.pid > 0 and p.master >= 0)
    assert_true(p.slave_name.startswith("/dev/pts/"), p.slave_name)
    var out = collect(p, "")
    assert_true(out.find(p.slave_name + "\r\n") >= 0, out)
    assert_true(out.find("both-ttys\r\n") >= 0, out)
    assert_true(out.find("30 100\r\n") >= 0, out)
    assert_true(out.find("xterm-256color yes\r\n") >= 0, out)
    assert_true(out.find("\r\n") > 0, "the terminal turns \\n into \\r\\n, as a real one does")
    assert_true(p.eof, "the end of the program is noticed")
    assert_true(wait_exit(p))
    assert_equal(exit_code(p.status), 7)
    _ = p.stop()
    assert_equal(p.master, -1)
    assert_false(p.start(List[String](), "", List[String](), 24, 80), "nothing to start")


def test_input_goes_to_the_program_and_echoes() raises:
    var p = Pty()
    assert_true(p.start(sh("read line; echo \"got <$line>\"; cat"), "", List[String](), 24, 80))
    p.write_text("hello there\r")
    var out = collect(p, "got <hello there>")
    assert_true(out.find("hello there") >= 0 and out.find("got <hello there>") >= 0, out)
    # cat echoes what it is given; Ctrl-D on an empty line ends it
    p.write_text("abc\r")
    out = collect(p, "abc\r\nabc")
    assert_true(out.find("abc\r\nabc") >= 0, out)
    p.write_text("\x04")
    _ = collect(p, "")
    assert_true(wait_exit(p))
    assert_equal(exit_code(p.status), 0)
    _ = p.stop()


def test_ctrl_c_interrupts_like_a_terminal() raises:
    var p = Pty()
    assert_true(p.start(sh("trap 'echo caught-int; exit 5' INT; echo ready; while true; do sleep 0.1; done"), "", List[String](), 24, 80))
    _ = collect(p, "ready")
    p.write_text("\x03")                # the terminal turns it into SIGINT for the program
    var out = collect(p, "caught-int")
    assert_true(out.find("caught-int") >= 0, out)
    assert_true(wait_exit(p))
    assert_equal(exit_code(p.status), 5)
    _ = p.stop()


def test_resizing_tells_the_program() raises:
    var p = Pty()
    assert_true(p.start(sh("trap 'stty size' WINCH; echo ready; while true; do sleep 0.05; done"), "", List[String](), 24, 80))
    _ = collect(p, "ready")
    p.resize(40, 132)
    var out = collect(p, "40 132")
    assert_true(out.find("40 132") >= 0, out)
    assert_equal(p.rows, 40)
    p.resize(40, 132)                    # the same size: nothing to tell
    var pid = p.pid
    var st = p.stop()
    assert_false(alive(pid), "stopping ends the program")
    assert_equal(exit_code(st), 128 + 1, "ended by SIGHUP, as when a terminal closes")


def test_a_program_that_ignores_the_hangup_is_killed() raises:
    var p = Pty()
    assert_true(p.start(sh("trap '' HUP; echo ready; while true; do sleep 0.05; done"), "", List[String](), 24, 80))
    _ = collect(p, "ready")
    var pid = p.pid
    var t0 = now()
    var st = p.stop()
    assert_true((now() - t0) // MS < 3000)
    assert_false(alive(pid))
    assert_equal(exit_code(st), 128 + 9)


def test_the_child_does_not_inherit_the_ides_files() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-pty-" + String(own_pid())
    _ = run_system("mkdir -p '" + d + "'")
    # a descriptor the IDE has open (here: a pipe) must not be in the child
    var fds = List[Int32](length=2, fill=0)
    _ = external_call["pipe", Int32](fds.unsafe_ptr())
    _ = external_call["dup2", Int32](fds[0], Int32(77))        # a number ls itself will not use
    var p = Pty()
    assert_true(p.start(sh("ls /proc/self/fd | tr '\\n' ' '; echo; echo done"), d, List[String](), 24, 80))
    var out = collect(p, "done")
    assert_true(out.find("0 1 2 ") >= 0, out)
    assert_true(out.find(" 77 ") < 0, out)
    _ = p.stop()
    # a program that does not exist: the child says so and ends with 127
    var q = Pty()
    var bad = List[String]()
    bad.append("no-such-program-turbomojo")
    assert_true(q.start(bad, "", List[String](), 24, 80))
    _ = collect(q, "")
    assert_true(wait_exit(q))
    assert_equal(exit_code(q.status), 127)
    _ = q.stop()
    _ = external_call["close", Int32](Int32(77))
    _ = external_call["close", Int32](fds[0])
    _ = external_call["close", Int32](fds[1])
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
