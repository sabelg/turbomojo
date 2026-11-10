"""Tests for the crash guard's normal-path behaviour and the error log helpers.

The fatal-signal path itself is exercised by scripts/smoke.sh with TURBOMOJO_FAULT, in a
real terminal, because it ends the process."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from crash import CrashGuard, fd_in_use, crash_slot, fatal_signals, CRASH_PAGE_FD, CRASH_LOG_FD, SAVED_STDERR_FD
from signals import own_pid
from app import *
from appstate import App
from util import (
    run_capture, run_system, bytes_to_str, str_bytes, env_or, path_exists, timestamp,
    append_line, decode,
)


def scratch(tag: String) -> String:
    return env_or("TMPDIR", "/tmp") + "/turbomojo-crashtest-" + String(own_pid()) + "-" + tag


def read_file(path: String) raises -> String:
    var s: String
    with open(path, "r") as f:
        s = f.read()
    return s


def write_stderr(s: String):
    var b = str_bytes(s)
    _ = external_call["write", Int](Int(2), b.unsafe_ptr(), len(b))


def test_each_fatal_signal_has_its_own_slot() raises:
    var seen = List[Int]()
    for s in fatal_signals():
        var k = crash_slot(s)
        assert_true(k >= 0 and k < 6)
        assert_false(k in seen)
        seen.append(k)
    assert_equal(crash_slot(15), -1)   # SIGTERM is not a crash


def test_install_and_uninstall() raises:
    var dir = scratch("install")
    var log = dir + "/sub/crash.log"
    var g = CrashGuard()
    assert_false(fd_in_use(CRASH_PAGE_FD))
    var termios = List[UInt8](length=60, fill=7)
    assert_true(g.install(termios, log, "header line"))
    assert_true(g.installed)
    assert_true(fd_in_use(CRASH_PAGE_FD))
    assert_true(fd_in_use(CRASH_LOG_FD))
    assert_true(fd_in_use(SAVED_STDERR_FD))
    assert_true(path_exists(log), "log file and its directory are created")
    assert_true(g.install(termios, log, "again"))   # second call is a no-op
    g.uninstall()
    assert_false(g.installed)
    assert_false(fd_in_use(CRASH_PAGE_FD))
    assert_false(fd_in_use(CRASH_LOG_FD))
    assert_false(fd_in_use(SAVED_STDERR_FD))
    assert_equal(read_file(log), "", "nothing is logged unless something goes wrong")
    _ = run_system("rm -rf '" + dir + "'")


def test_stderr_goes_to_the_log_only_while_the_ui_is_up() raises:
    var dir = scratch("stderr")
    var log = dir + "/crash.log"
    var g = CrashGuard()
    var termios = List[UInt8](length=60, fill=0)
    assert_true(g.install(termios, log, "h"))
    g.set_tui(True)
    write_stderr("into the log\n")
    g.set_tui(False)
    write_stderr("")                     # back on the real stderr (nothing visible)
    assert_equal(read_file(log), "into the log\n")
    g.set_tui(True)
    write_stderr("second\n")
    g.uninstall()                        # also restores stderr
    assert_equal(read_file(log), "into the log\nsecond\n")
    _ = run_system("rm -rf '" + dir + "'")


def test_guard_can_be_installed_again_after_uninstall() raises:
    var dir = scratch("again")
    var g = CrashGuard()
    var termios = List[UInt8](length=60, fill=0)
    assert_true(g.install(termios, dir + "/a.log", "h"))
    g.uninstall()
    assert_true(g.install(termios, dir + "/b.log", "h"))
    g.uninstall()
    _ = run_system("rm -rf '" + dir + "'")


def test_set_tui_without_install_is_harmless() raises:
    var g = CrashGuard()
    g.set_tui(True)
    g.set_tui(False)
    g.uninstall()
    assert_false(g.installed)


def test_timestamp_format() raises:
    var t = decode(timestamp())
    assert_equal(len(t), 19)             # YYYY-MM-DD HH:MM:SS
    assert_equal(t[4], 45)
    assert_equal(t[7], 45)
    assert_equal(t[10], 32)
    assert_equal(t[13], 58)
    assert_equal(t[16], 58)
    assert_equal(t[0], 50)               # year starts with 2
    for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]:
        assert_true(t[i] >= 48 and t[i] <= 57)


def test_append_line_creates_directories_and_appends() raises:
    var dir = scratch("append")
    var path = dir + "/deep/er/log.txt"
    assert_true(append_line(path, "one"))
    assert_true(append_line(path, "two"))
    assert_equal(read_file(path), "one\ntwo\n")
    _ = run_system("rm -rf '" + dir + "'")


def test_log_error_is_silent_until_the_ide_runs() raises:
    var dir = scratch("logerr")
    var app = App()
    assert_equal(app.log_path, "")
    app.log_error("must not be written anywhere")
    app.log_path = dir + "/crash.log"
    app.log_error("first problem")
    var text = read_file(app.log_path)
    assert_true(text.endswith("  error: first problem\n"))
    assert_equal(len(decode(text)), 19 + len(decode("  error: first problem\n")))
    _ = run_system("rm -rf '" + dir + "'")


def test_terminal_does_not_install_the_guard_without_a_log_path() raises:
    var app = App()
    assert_false(app.term.guard.installed)
    assert_equal(app.term.crash_log, "")
    assert_false(fd_in_use(CRASH_PAGE_FD))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
