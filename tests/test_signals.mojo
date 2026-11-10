"""Tests for signal handling: signalfd delivery, child signal masks, emergency save."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from signals import SignalFd, send_signal, own_pid
from term import wait_readable
from app import *
from appstate import App, now_ns, RESIZE_POLL_MS
from commands import CM_NEW
from swap import list_swap_files, swap_decode, read_bytes
from util import (
    run_capture, run_system, decode, bytes_to_str, path_exists, env_or, SIGTERM, SIGWINCH,
    SIGHUP, SIGCONT, SIGTSTP,
)


def ready(s: SignalFd, timeout_ms: Int) -> Bool:
    var fds = List[Int]()
    fds.append(s.fd)
    return wait_readable(fds, timeout_ms) != 0


def test_open_and_close() raises:
    var s = SignalFd()
    assert_false(s.active())
    assert_true(s.open())
    assert_true(s.active())
    assert_equal(len(s.read_all()), 0)   # nothing pending, and reading does not block
    assert_true(s.open())                # opening twice is harmless
    s.close()
    assert_false(s.active())
    assert_equal(len(s.read_all()), 0)


def test_resize_signal_arrives_on_the_descriptor() raises:
    var s = SignalFd()
    _ = s.open()
    assert_false(ready(s, 0))
    send_signal(own_pid(), SIGWINCH)
    assert_true(ready(s, 1000))
    var got = s.read_all()
    assert_equal(len(got), 1)
    assert_equal(got[0], SIGWINCH)
    assert_false(ready(s, 0))            # consumed
    s.close()


def test_terminate_signals_are_received_instead_of_killing_us() raises:
    var s = SignalFd()
    _ = s.open()
    send_signal(own_pid(), SIGTERM)
    send_signal(own_pid(), SIGHUP)
    assert_true(ready(s, 1000))
    var got = s.read_all()
    assert_equal(len(got), 2)
    assert_true(SIGTERM in got)
    assert_true(SIGHUP in got)
    s.close()                            # still alive to run this line


def test_signal_delivery_is_reliable_with_runtime_threads() raises:
    # The Mojo runtime has many worker threads; a signal may land on any of them.
    # Every one of 300 signals must be seen and none may kill the process.
    var s = SignalFd()
    _ = s.open()
    var seen = 0
    for i in range(300):
        send_signal(own_pid(), SIGTERM if i % 2 == 0 else SIGWINCH)
        if ready(s, 1000):
            var got = s.read_all()
            if len(got) == 1 and got[0] == (SIGTERM if i % 2 == 0 else SIGWINCH):
                seen += 1
    assert_equal(seen, 300)
    s.close()


def test_repeated_signal_is_reported_once_per_read() raises:
    var s = SignalFd()
    _ = s.open()
    for _ in range(5):
        send_signal(own_pid(), SIGWINCH)
    assert_true(ready(s, 1000))
    var got = s.read_all()
    assert_equal(len(got), 1)
    assert_equal(got[0], SIGWINCH)
    s.close()


def child_mask(field: String) raises -> Int:
    """A signal mask (hex from /proc) of a child process started by run_capture."""
    var r = run_capture("grep " + field + " /proc/self/status")
    var parts = bytes_to_str(r.out).split(":")
    return atol(String(String(parts[1]).strip()), 16)


def test_children_start_with_default_signal_handling() raises:
    # A compiler started by the IDE must still be stoppable with SIGTERM.
    var s = SignalFd()
    _ = s.open()
    var blocked = child_mask("SigBlk")
    var ignored = child_mask("SigIgn")
    var caught = child_mask("SigCgt")
    for sig in [SIGTERM, SIGHUP, SIGWINCH, SIGTSTP, SIGCONT]:
        assert_equal((blocked >> (sig - 1)) & 1, 0, "child has signal blocked: " + String(sig))
        assert_equal((ignored >> (sig - 1)) & 1, 0, "child ignores signal: " + String(sig))
        assert_equal((caught >> (sig - 1)) & 1, 0, "child inherited a handler: " + String(sig))
    s.close()


def test_close_restores_default_handling() raises:
    var s = SignalFd()
    _ = s.open()
    s.close()
    # SIGWINCH is ignored by default: it must neither kill us nor be recorded
    send_signal(own_pid(), SIGWINCH)
    assert_equal(len(s.read_all()), 0)
    var again = SignalFd()
    assert_true(again.open())            # the fixed descriptor is free again
    again.close()


def test_idle_loop_sleeps_long_once_signals_are_on_a_descriptor() raises:
    var app = App()
    app.show_clock = False
    assert_equal(app.next_timeout_ms(now_ns(), False, 30), RESIZE_POLL_MS)
    _ = app.sig.open()
    assert_true(app.next_timeout_ms(now_ns(), False, 30) >= 60000)
    app.sig.close()


def scratch() -> String:
    return env_or("TMPDIR", "/tmp") + "/turbomojo-test-recovery-" + String(own_pid())


def test_emergency_save_keeps_only_modified_buffers_as_swap_files() raises:
    var app = App()
    app.scr.resize(80, 25)
    app.recovery_dir = scratch()
    _ = run_system("rm -rf '" + app.recovery_dir + "'")
    app.exec(CM_NEW)                     # stays unmodified
    app.exec(CM_NEW)
    var t = app.top()
    app.wins[t].title = "notes.mojo"
    for c in decode("unsaved work"):
        app.wins[t].type_char(c, True)
    assert_equal(app.emergency_save(), 1)
    assert_equal(app.recovered, 1)
    var files = list_swap_files(app.recovery_dir)
    assert_equal(len(files), 1)
    var info = swap_decode(read_bytes(files[0]))
    assert_true(info.ok)
    assert_equal(info.title, "notes.mojo")
    assert_equal(info.pid, own_pid())
    assert_equal(bytes_to_str(info.content), "unsaved work\n")
    _ = run_system("rm -rf '" + app.recovery_dir + "'")


def test_emergency_save_with_nothing_modified_creates_nothing() raises:
    var app = App()
    app.scr.resize(80, 25)
    app.recovery_dir = scratch() + "-none"
    app.exec(CM_NEW)
    assert_equal(app.emergency_save(), 0)
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)
    _ = run_system("rm -rf '" + app.recovery_dir + "'")


def test_terminate_signal_saves_and_stops_the_loop() raises:
    var app = App()
    app.scr.resize(80, 25)
    app.recovery_dir = scratch() + "-term"
    app.exec(CM_NEW)
    app.wins[0].type_char(120, True)
    assert_true(app.running)
    app.on_signal(SIGTERM)
    assert_false(app.running)
    assert_equal(app.recovered, 1)
    _ = run_system("rm -rf '" + app.recovery_dir + "'")


def test_resize_signal_changes_nothing_by_itself() raises:
    var app = App()
    app.on_signal(SIGWINCH)
    assert_true(app.running)
    assert_equal(app.recovered, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
