"""Tests for OSC 133 marks around a program run (P10-14c, src/marks.mojo): the shell
text puts the four marks in order around the "$ label" line, the command and its
status, and keeps the status; not for the Linux console or TERM=dumb; libghostty-vt
jumps between marked runs; in the Run window Ctrl-Shift-Up / Ctrl-Shift-Down go to
the run's prompt and say when there is none further, and the program's status still
shows when it ends."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from marks import *
from vt import *
from termsession import TS_RUN
from term import wait_readable, key_event, KEY_UP, KEY_DOWN, MOD_CTRL, MOD_SHIFT
from app import *
from appstate import App
from window import WK_TERM
from commands import CM_RUN
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, read_file, str_bytes, bytes_to_str

comptime MS = 1000000


def test_the_shell_text() raises:
    var t = marked_run("mojo run it's.mojo", "false", True, "\\n")
    var a = t.find("133;A")
    var b = t.find("133;B")
    var c = t.find("133;C")
    var core = t.find("; false;")
    var d = t.find("133;D;%d")
    assert_true(a >= 0 and a < b and b < c and c < core and core < d, t)
    assert_true(t.find("'mojo run it'\\''s.mojo'") > 0, t)        # quoted for the shell
    assert_true(t.find("st=$?") > core and t.endswith("$st"), t)
    var plain = marked_run("x", "true", False, "\\n")
    assert_equal(plain.find("133"), -1)
    assert_true(plain.endswith("st=$?"))
    assert_true(marks_wanted("xterm-256color") and marks_wanted("xterm-ghostty") and marks_wanted("tmux-256color"))
    assert_false(marks_wanted("linux") or marks_wanted("dumb") or marks_wanted("") or marks_wanted("vt100"))


def test_what_the_shell_writes() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-marks-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var script = marked_run("mojo run a.mojo", "echo out; (exit 3)", True, "\\n") + "; echo \"[$st]\""
    _ = write_file(d + "/s.sh", str_bytes(script))
    _ = run_system("sh " + shell_quote(d + "/s.sh") + " > " + shell_quote(d + "/out") + " 2>&1")
    var o = bytes_to_str(read_file(d + "/out"))
    var a = o.find("\x1b]133;A\x07")
    var label = o.find("$ mojo run a.mojo")
    var b = o.find("\x1b]133;B\x07")
    var c = o.find("\x1b]133;C\x07")
    var out = o.find("out\n")
    var end = o.find("\x1b]133;D;3\x07")
    assert_true(a == 0 and a < label and label < b and b < c and c < out and out < end, o)
    assert_true(o.endswith("[3]\n"), o)                      # the status is kept
    _ = run_system("rm -rf " + shell_quote(d))


def runs(n: Int, lines: Int) -> String:
    var s = String("")
    for k in range(n):
        s += OSC133_PROMPT + "$ run " + String(k + 1) + OSC133_INPUT + "\r\n" + OSC133_OUTPUT
        for j in range(lines):
            s += "output " + String(k + 1) + "." + String(j) + "\r\n"
        s += osc133_end(0)
    return s^


def test_the_terminal_jumps_between_runs() raises:
    var t = VtTerm()
    assert_true(t.open(40, 6))
    t.write_text(runs(3, 12))
    t.update()
    assert_true(t.at_bottom())
    var bottom = t.view_top()
    t.scroll_view(SCROLL_PROMPT, -1)
    t.update()
    assert_equal(t.row_text(0), "$ run 3")
    t.scroll_view(SCROLL_PROMPT, -1)
    t.update()
    assert_equal(t.row_text(0), "$ run 2")
    t.scroll_view(SCROLL_PROMPT, -5)                        # fewer left: the first
    t.update()
    assert_equal(t.row_text(0), "$ run 1")
    t.scroll_view(SCROLL_PROMPT, 1)
    t.update()
    assert_equal(t.row_text(0), "$ run 2")
    assert_true(t.view_top() < bottom)
    # without marks nothing moves
    var u = VtTerm()
    assert_true(u.open(40, 6))
    u.write_text("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\n")
    u.update()
    var top = u.view_top()
    u.scroll_view(SCROLL_PROMPT, -1)
    u.update()
    assert_equal(u.view_top(), top)


def turn(mut app: App):
    var fds = app.term_fds()
    _ = wait_readable(fds, 20)
    app.term_tick()


def screen_of(mut app: App) -> String:
    var s = app.term_take(TS_RUN)
    var text = s.vt.text()
    app.term_put(TS_RUN, s^)
    return text


def wait_screen(mut app: App, text: String) raises -> String:
    var deadline = Int(perf_counter_ns()) + 8000 * MS
    var shown = String("")
    while Int(perf_counter_ns()) < deadline:
        turn(app)
        shown = screen_of(app)
        if shown.find(text) >= 0:
            return shown
    assert_true(False, "no \"" + text + "\" on the terminal:\n" + shown)
    return shown


def top_row(mut app: App) -> String:
    var s = app.term_take(TS_RUN)
    s.vt.update()
    var r = s.vt.row_text(0)
    app.term_put(TS_RUN, s^)
    return r


def test_the_run_window() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-marks-run-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.compiler = "sh " + d + "/fake-mojo.sh"         # stands for `mojo`
    _ = write_file(d + "/fake-mojo.sh", str_bytes("i=0; while [ $i -lt 60 ]; do echo line $i; i=$((i+1)); done; exit 5\n"))
    _ = write_file(d + "/prog.mojo", str_bytes("def main():\n    pass\n"))
    app.open_path(d + "/prog.mojo")
    app.exec(CM_RUN)
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_TERM)
    _ = wait_screen(app, "ended with status 5")            # (the status is kept)
    assert_true(top_row(app).find("$ mojo run prog.mojo") < 0)  # (scrolled out of view)
    # Ctrl-Shift-Up: to the run's prompt
    app.handle(key_event(KEY_UP | MOD_CTRL | MOD_SHIFT))
    assert_equal(app.wins[app.top()].kind, WK_TERM)      # (still the Run window; the Message window,
                                                         #  made when the run ended, went in below)
    assert_true(top_row(app).startswith("$ mojo run prog.mojo"), top_row(app))
    # none earlier: it says so
    app.status = ""
    app.handle(key_event(KEY_UP | MOD_CTRL | MOD_SHIFT))
    assert_true(app.status.startswith("No earlier run marked here"), app.status)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
