"""Tests for Help > Exercises (P7-15, help/exercises/, src/app_exercises.mojo): the
built-in exercises are the files; with the real compiler each one is wrong until
fixed (it does not build, with a message TurboMojo explains, or prints the wrong
line) and its solution (tests/exercise_solutions/) prints the expected line; in the
IDE the first choice picks where to start, a failed check fills the Problems page so
F1 explains it, a fixed one is marked done, and Reset gives the original back."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from exercise_pages import EX_COUNT, ex_key, ex_text
from app_exercises import ex_expect, ex_title, ex_passed, EX_START_PYTHON
from errhelp import explain_for
from dialog import D_EXERCISES
from window import WK_EXPLAIN
from term import key_event, fkey, wait_readable, KEY_ENTER, KEY_ESC
from commands import CM_EXERCISES, CM_EX_CHECK, CM_SAVE
from app import *
from appstate import App, M_DIALOG, M_NORMAL
from signals import own_pid
from util import env_or, run_system, run_capture, shell_quote, write_file, read_file, str_bytes, bytes_to_str, getcwd, which, decode, to_str, path_exists

comptime MS = 1000000


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-ex-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def test_the_built_in_exercises_are_the_files() raises:
    var order = bytes_to_str(read_file(getcwd() + "/help/exercises/ORDER")).split()
    assert_equal(len(order), EX_COUNT)
    for i in range(EX_COUNT):
        assert_equal(ex_key(i), String(order[i]))
        var t = ex_text(i)
        assert_equal(bytes_to_str(read_file(getcwd() + "/help/exercises/" + ex_key(i) + ".mojo")), t)
        assert_true(t.startswith("# Exercise " + String(i + 1) + " of " + String(EX_COUNT) + ": "), ex_key(i))
        assert_true(ex_expect(t).byte_length() > 0, ex_key(i))
    assert_equal(ex_title(ex_text(0)), "a new name needs var")
    assert_true(ex_passed("x\ncount = 3\n", "count = 3"))
    assert_false(ex_passed("count = 33\n", "count = 3"))


def first_error(output: String) -> String:
    for l in output.split("\n"):
        var s = String(l)
        var k = s.find(" error: ")
        if k >= 0:
            return String(s[byte=k + 8:])
    return ""


def test_each_is_wrong_until_fixed() raises:
    if which("mojo").byte_length() == 0:
        return
    var d = scratch("real")
    for i in range(EX_COUNT):
        var key = ex_key(i)
        var expect = ex_expect(ex_text(i))
        _ = write_file(d + "/e.mojo", str_bytes(ex_text(i)))
        var r = run_capture("cd " + shell_quote(d) + " && timeout 60 mojo run e.mojo 2>&1")
        var out = bytes_to_str(r.out)
        assert_false(r.status == 0 and ex_passed(out, expect), key + " is right already")
        if r.status != 0:
            var msg = first_error(out)
            assert_true(explain_for(msg) >= 0, key + ": no explanation for " + msg)   # F1 will help
        var s = run_capture("cd " + shell_quote(getcwd() + "/tests/exercise_solutions") + " && timeout 60 mojo run " + key + ".mojo 2>&1")
        assert_equal(s.status, 0, key + ": " + bytes_to_str(s.out))
        assert_true(ex_passed(bytes_to_str(s.out), expect), key + ": the solution printed " + bytes_to_str(s.out))
    _ = run_system("rm -rf " + shell_quote(d))


def wait_job(mut app: App) raises:
    var deadline = Int(perf_counter_ns()) + 120000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active, "the check did not end")


def test_doing_an_exercise() raises:
    var d = scratch("ide")
    var app = App()
    app.scr.resize(110, 34)
    app.ex_home = d + "/exercises"
    app.exec(CM_EXERCISES)
    assert_equal(app.dlg.kind, D_EXERCISES)
    assert_equal(app.dlg.buttons[1], "Some ~P~ython")                 # the first time: where to start
    app.exercises_button(1, 0)
    app.mode = M_NORMAL
    var path = d + "/exercises/" + ex_key(EX_START_PYTHON) + ".mojo"
    assert_equal(app.wins[app.top()].path, path)                      # started at exercise 2
    assert_true(to_str(app.wins[app.top()].buf.all_text()).find("Help > Exercise done?.") > 0)   # (no key: none named)
    if which("mojo").byte_length() == 0:
        return
    # not done yet: the Problems page has the error, F1 explains it
    app.exec(CM_EX_CHECK)
    wait_job(app)
    assert_true(app.status.startswith("Not yet: "), app.status)
    assert_true(len(app.prob_build) >= 1)
    var row = -1
    for r in range(app.wins[app.top()].buf.count()):
        if to_str(app.wins[app.top()].buf.line(r)).startswith("fn greet"):
            row = r
    app.focus(app.find_editor(path))
    app.wins[app.top()].goto(row, 0)
    app.handle(key_event(fkey(1)))
    assert_equal(app.wins[app.top()].kind, WK_EXPLAIN)
    assert_true(app.wins[app.top()].path == "explain:fn-removed", app.wins[app.top()].path)
    app.handle(key_event(KEY_ESC))
    # fixed: done, and the list marks it
    var ei = app.find_editor(path)
    var fixed = to_str(app.wins[ei].buf.all_text()).replace("fn greet", "def greet")
    app.wins[ei].buf.load(decode(fixed))
    app.wins[ei].buf.modified = True
    app.focus(ei)
    app.exec(CM_EX_CHECK)
    wait_job(app)
    assert_true(app.status.startswith("✓ Exercise 2 done. Next: Help > Exercises (3. text is not a number)"), app.status)
    assert_equal(bytes_to_str(read_file(d + "/exercises/done")), ex_key(EX_START_PYTHON) + "\n")
    if app.mode == M_DIALOG:
        app.handle(key_event(KEY_ESC))
    app.exec(CM_EXERCISES)
    assert_true(app.dlg.items[1].startswith("✓ 2."), app.dlg.items[1])
    assert_equal(app.dlg.list_sel, 0)                                 # (1 is not done: it is first)
    assert_equal(app.dlg.buttons[0], "~O~pen")
    # Reset: the original again
    app.exercises_button(1, 1)
    app.mode = M_NORMAL
    assert_true(to_str(app.wins[app.find_editor(path)].buf.all_text()).find("fn greet") > 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_not_an_exercise() raises:
    var app = App()
    app.scr.resize(100, 30)
    app.ex_home = "/nowhere/exercises"
    app.open_path("/nowhere/x.mojo")
    app.exec(CM_EX_CHECK)
    assert_equal(app.status, "Open an exercise first (Help > Exercises)")
    var none = App()
    none.exec(CM_EXERCISES)
    assert_equal(none.status, "There is no folder for the exercises")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
