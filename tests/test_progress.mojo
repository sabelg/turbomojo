"""Tests for the response-time ladder (P10-06, src/progress.mojo, src/app_progress.mojo):
the stages and their limits; the time and the output as they are shown; a build shows
nothing in its first second, then a spinner, the time and the cancel key on the
status line, and beyond ten seconds the Compiling box with the output so far and its
last line - which leaves the keyboard to the editor; the loop wakes when the first
second ends; an agent's turn has the same ladder, with its steps so far."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from progress import *
from app import *
from appstate import App, now_ns, M_NORMAL, JOB_BUILD, JOB_TESTS, SPINNER_MS
from commands import CM_NEW, CM_CANCEL
from term import key_event
from util import decode, to_str, str_bytes

comptime SEC = 1000000000


def test_the_stages() raises:
    assert_equal(progress_stage(0), PS_QUIET)
    assert_equal(progress_stage(999), PS_QUIET)
    assert_equal(progress_stage(1000), PS_SPINNER)
    assert_equal(progress_stage(9999), PS_SPINNER)
    assert_equal(progress_stage(10000), PS_BOX)
    assert_equal(elapsed_text(0), "0.0 s")
    assert_equal(elapsed_text(3250), "3.2 s")
    assert_equal(elapsed_text(59999), "59.9 s")
    assert_equal(elapsed_text(65000), "1 min 05 s")
    assert_equal(elapsed_text(754000), "12 min 34 s")


def test_the_output_so_far() raises:
    assert_equal(output_lines(List[UInt8]()), 0)
    assert_equal(output_lines(str_bytes("a\nb\n")), 2)
    assert_equal(output_lines(str_bytes("a\nb")), 2)
    assert_equal(last_output_line(str_bytes("one\ntwo\n\n  \n")), "two")
    # a progress bar redrawing itself: its latest state; colours left out
    assert_equal(last_output_line(str_bytes("start\n\x1b[32m 10%\r 55%\r 90%\x1b[0m")), "90%")
    assert_equal(last_output_line(str_bytes("\x1b[1;31merror:\x1b[0m bad thing\n")), "error: bad thing")
    assert_equal(last_output_line(List[UInt8]()), "")


def app_building(seconds_ago: Int, output: String = "") raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode("x\n"))
    app.job.active = True
    app.job.kind = JOB_BUILD
    app.job.path = "/p/hello.mojo"
    app.job.data = str_bytes(output)
    app.job.t0 = now_ns() - seconds_ago * SEC
    app.draw()
    return app^


def status(app: App) -> String:
    return to_str(app.scr.row_text(app.scr.h - 1))


def screen(app: App) -> String:
    return to_str(app.scr.to_text())


def test_a_build_climbs_the_ladder() raises:
    # the first second: nothing
    var a = app_building(0)
    assert_true(status(a).find("Building") < 0, status(a))
    assert_true(screen(a).find(" Compiling ") < 0)
    var t = a.next_timeout_ms(now_ns(), False, 30)
    assert_true(t > SPINNER_MS and t <= 1001, String(t))       # wakes when the second ends
    # then the spinner, the time and the key that stops it
    var b = app_building(3)
    assert_true(status(b).find("Building hello.mojo 3.") >= 0, status(b))
    assert_true(status(b).find(b.reg.key_label(CM_CANCEL) + " cancels") >= 0, status(b))
    assert_true(screen(b).find(" Compiling ") < 0)
    assert_equal(b.next_timeout_ms(now_ns(), False, 30), SPINNER_MS)
    # beyond ten seconds: the box, with what is done so far
    var c = app_building(12, "Compiling module a\nCompiling module b\n\x1b[2K 40%\r 75%")
    var s = screen(c)
    assert_true(s.find(" Compiling ") >= 0, s)
    assert_true(s.find("Main file:  hello.mojo") >= 0, s)
    assert_true(s.find("Elapsed:    12.") >= 0, s)
    assert_true(s.find("Output:     3 lines") >= 0, s)
    assert_true(s.find("75%") >= 0, s)
    assert_true(s.find(c.reg.key_label(CM_CANCEL) + " cancels") >= 0, s)
    # and the keyboard stays with the editor
    var top = c.top()
    assert_equal(c.mode, M_NORMAL)
    c.handle(key_event(65))
    assert_equal(c.top(), top)
    assert_equal(to_str(c.wins[top].buf.line(0)), "Ax")
    # a test run has its own title
    c.job.kind = JOB_TESTS
    c.job.exe = "tests/test_a.mojo"
    c.draw()
    assert_true(screen(c).find(" Running tests ") >= 0)
    # a screen reader gets the status line only
    c.reader = True
    c.draw()
    assert_true(screen(c).find(" Running tests ") < 0)


def test_the_agents_turn() raises:
    var app = App()
    app.scr.resize(120, 30)
    app.exec(CM_NEW)
    app.agent.prompt_id = 7                     # (a turn, as the status line sees it)
    app.agent.prompt_ns = now_ns()
    app.draw()
    assert_true(status(app).find("Agent") < 0, status(app))
    app.agent.prompt_ns = now_ns() - 4 * SEC
    app.draw()
    assert_true(status(app).find("Agent 4.") >= 0, status(app))
    assert_true(status(app).find("steps") < 0)
    app.chat.user("fix it")
    var none = List[String]()
    app.chat.tool("t1", "Read a.mojo", "completed", none)
    app.chat.tool("t2", "Edit a.mojo", "in_progress", none)
    app.agent.prompt_ns = now_ns() - 15 * SEC
    app.draw()
    assert_true(status(app).find("Agent 15.") >= 0 and status(app).find("2 steps, Esc in its panel stops") >= 0, status(app))
    assert_equal(app.chat.turn_steps(), 2)
    app.chat.user("again")
    assert_equal(app.chat.turn_steps(), 0)
    app.agent.prompt_id = -1


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
