"""Tests for cursor discipline (P10-15, Screen.render): a frame sends only the cells
that changed and nothing at all when none did; after any update - the status line, a
notice, a typed key - the terminal's cursor ends on the editor's caret; with no caret
(a list window, an open menu) it waits hidden on the focused row or item, not where
the last cell was written; the cursor is hidden and shown, and its shape sent, only
when that changes; a terminal window's program gets its cursor shown."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from screen import Screen
from app import *
from appstate import App, M_MENU
from window import WK_TERM
from termsession import TS_RUN
from term import key_event, wait_readable, KEY_DOWN
from commands import CM_EXPLORER, CM_RUN
from notify import NL_DONE
from signals import own_pid
from util import to_str, env_or, run_system, shell_quote, write_file, str_bytes, bytes_to_str

comptime MS = 1000000


def frame(mut scr: Screen) -> String:
    var out = List[UInt8]()
    scr.render(out)
    return bytes_to_str(out)


def last_cup(s: String) -> Tuple[Int, Int]:
    """The last cursor position `ESC [ row ; col H` in `s`, 0-based (x, y); (-1, -1)."""
    var b = s.as_bytes()
    var best = (-1, -1)
    var i = 0
    while i + 2 < len(b):
        if Int(b[i]) == 27 and Int(b[i + 1]) == 91:
            var j = i + 2
            var row = 0
            var col = 0
            var nd = 0
            while j < len(b) and Int(b[j]) >= 48 and Int(b[j]) <= 57:
                row = row * 10 + Int(b[j]) - 48
                j += 1
                nd += 1
            if nd > 0 and j < len(b) and Int(b[j]) == 59:
                j += 1
                var nc = 0
                while j < len(b) and Int(b[j]) >= 48 and Int(b[j]) <= 57:
                    col = col * 10 + Int(b[j]) - 48
                    j += 1
                    nc += 1
                if nc > 0 and j < len(b) and Int(b[j]) == 72:
                    best = (col - 1, row - 1)
        i += 1
    return best


def count(s: String, part: String) -> Int:
    var n = 0
    var at = s.find(part)
    while at >= 0:
        n += 1
        at = s.find(part, at + part.byte_length())
    return n


def test_only_what_changed() raises:
    var scr = Screen(20, 5)
    scr.sync = True
    _ = scr.text(0, 0, "hello world", 0xFFFFFF, 0)
    scr.cx = 3
    scr.cy = 2
    scr.cvis = True
    var first = frame(scr)
    assert_true(first.find("hello world") >= 0)
    assert_equal(count(first, "\x1b[?25h"), 1)
    assert_equal(count(first, "\x1b[3 q"), 1)
    # nothing changed: nothing is sent
    assert_equal(frame(scr), "")
    # one cell: only it, then the cursor back on the caret - not hidden and shown
    # again (the synchronized frame shows all at once), the shape not sent again
    _ = scr.text(6, 0, "W", 0xFFFFFF, 0)
    var one = frame(scr)
    assert_true(one.find("W") >= 0 and one.find("hello") < 0 and one.find("orld") < 0, one)
    assert_equal(last_cup(one)[0], 3)
    assert_equal(last_cup(one)[1], 2)
    assert_equal(count(one, "\x1b[?25"), 0, one)
    assert_equal(count(one, " q"), 0)
    # the caret alone moves: just the move
    scr.cx = 4
    var mv = frame(scr)
    assert_equal(mv, "\x1b[?2026h\x1b[3;5H\x1b[?2026l")
    # a block caret: the shape, once
    scr.cblock = True
    assert_equal(count(frame(scr), "\x1b[1 q"), 1)
    assert_equal(frame(scr), "")
    # no caret: hidden once, and waiting on the focus cell
    scr.cvis = False
    scr.fx = 1
    scr.fy = 4
    var hid = frame(scr)
    assert_equal(count(hid, "\x1b[?25l"), 1)
    assert_equal(last_cup(hid)[1], 4)
    assert_equal(frame(scr), "")
    # without synchronized output a visible caret is hidden while cells change
    var plain = Screen(10, 3)
    plain.sync = False
    plain.cvis = True
    plain.cx = 1
    plain.cy = 1
    _ = frame(plain)
    _ = plain.text(0, 0, "x", 0xFFFFFF, 0)
    var p = frame(plain)
    assert_true(p.startswith("\x1b[?25l") and p.endswith("\x1b[?25h"), p)
    # a resize says it all again
    scr.resize(20, 5)
    assert_true(count(frame(scr), "\x1b[?25l") == 1)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-cursor-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    var x = 1\n    print(x)\n"))
    _ = write_file(d + "/b.txt", str_bytes("b\n"))
    return d


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    return app^


def step(mut app: App) -> String:
    app.draw()
    return frame(app.scr)


def test_the_cursor_comes_back_to_the_caret() raises:
    var d = scratch("caret")
    var app = ide(d)
    app.open_path(d + "/a.mojo")
    _ = step(app)
    var caret = (app.scr.cx, app.scr.cy)
    assert_true(app.scr.cvis)
    # the status line changes
    app.say("Something to say on the status line")
    var s = step(app)
    assert_true(s.byte_length() > 0 and to_str(app.scr.row_text(app.scr.h - 1)).find("Something to say") >= 0)
    assert_equal(last_cup(s)[0], caret[0])
    assert_equal(last_cup(s)[1], caret[1])
    # a notice (a toast, at the bottom right)
    app.notify(NL_DONE, "Build succeeded", "a.mojo in 1.0 s", True)
    var n = step(app)
    assert_true(n.byte_length() > 0 and to_str(app.scr.to_text()).find("Build succeeded") >= 0)
    assert_equal(last_cup(n)[0], caret[0])
    assert_equal(last_cup(n)[1], caret[1])
    # a key that moves the caret
    app.handle(key_event(KEY_DOWN))
    var k = step(app)
    assert_equal(last_cup(k)[1], caret[1] + 1)
    assert_equal(count(k, "\x1b[?25h"), 0)          # (shown all along)
    # nothing new: nothing sent
    assert_equal(step(app), "")
    _ = run_system("rm -rf " + shell_quote(d))


def test_no_caret_waits_on_the_focus() raises:
    var d = scratch("focus")
    var app = ide(d)
    app.exec(CM_EXPLORER)
    var xi = app.explorer_index()
    app.focus(xi)
    _ = step(app)
    assert_false(app.scr.cvis)
    var row = app.wins[xi].y + 1 + app.wins[xi].cr - app.wins[xi].top
    assert_equal(app.scr.fy, row)
    app.notify(NL_DONE, "Committed", "far from the explorer", True)     # (a toast, top right)
    var s = step(app)
    assert_true(s.byte_length() > 0 and to_str(app.scr.to_text()).find("Committed") >= 0)
    assert_equal(last_cup(s)[1], row, "the hidden cursor is left where the toast was written")
    assert_equal(count(s, "\x1b[?25h"), 0)
    app.handle(key_event(KEY_DOWN))
    var k = step(app)
    assert_equal(last_cup(k)[1], row + 1)
    # an open menu: on its marked item, and it follows the selection
    app.open_menu(0)
    var m = step(app)
    var y0 = last_cup(m)[1]
    assert_true(y0 >= 2, m)
    app.handle(key_event(KEY_DOWN))
    var m2 = step(app)
    assert_true(last_cup(m2)[1] > y0, m2)
    assert_false(app.scr.cvis)
    _ = run_system("rm -rf " + shell_quote(d))


def test_a_terminal_window_shows_its_cursor() raises:
    var d = scratch("term")
    var app = ide(d)
    app.compiler = "sh " + d + "/fake-mojo.sh"
    _ = write_file(d + "/fake-mojo.sh", str_bytes("printf 'name? '; read n; echo $n\n"))
    app.open_path(d + "/a.mojo")
    app.exec(CM_RUN)
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_TERM)
    var deadline = Int(perf_counter_ns()) + 8000 * MS
    var shown = False
    while Int(perf_counter_ns()) < deadline and not shown:
        var fds = app.term_fds()
        _ = wait_readable(fds, 20)
        app.term_tick()
        var s = app.term_take(TS_RUN)
        shown = s.vt.text().find("name?") >= 0
        app.term_put(TS_RUN, s^)
    assert_true(shown)
    app.draw()
    assert_true(app.scr.cvis, "the program's cursor was taken away")
    assert_equal(app.scr.cx, app.wins[t].x + 1 + 6)          # after "name? "
    _ = app.trun.pty.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
