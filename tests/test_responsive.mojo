"""Tests for the responsive layout, first part (P10-16a, src/responsive.mojo): below
40x10 the IDE shows a "terminal too small" screen, keys do nothing to the files but
the quit key still quits, and the IDE comes back as it was when the terminal grows;
in a narrow window the minimap, then the breadcrumbs, then the line numbers give way."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from responsive import *
from app import *
from appstate import App, M_NORMAL
from commands import CM_QUIT
from term import key_event
from signals import own_pid
from util import cp_len, env_or, run_system, shell_quote, write_file, str_bytes, to_str


def test_the_limits_and_the_words() raises:
    assert_true(too_small(39, 30) and too_small(100, 9))
    assert_false(too_small(40, 10))
    var l = too_small_lines(30, 8, "Alt-X")
    for line in l:
        assert_true(line.byte_length() <= 28, line)
    var all = " ".join(l)
    assert_equal(all, "Terminal too small: 30x8. TurboMojo needs at least 40x10. Make the window larger or the font smaller. Alt-X quits.")
    assert_equal(" ".join(too_small_lines(30, 8, "")).find("quits"), -1)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-resp-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/a.mojo", str_bytes("struct Counter:\n    var n: Int\n\n    def add(mut self):\n        self.n += 1\n"))
    return d


def screen(app: App) -> String:
    return to_str(app.scr.to_text())


def test_too_small() raises:
    var d = scratch("small")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    app.draw()
    var t = app.top_editor()
    var before = to_str(app.wins[t].buf.all_text())
    app.scr.resize(30, 8)
    app.draw()
    var s = screen(app)
    assert_true(s.find("Terminal too small: 30x8.") >= 0, s)
    assert_true(s.find("40x10") >= 0)
    assert_true(s.find("Counter") < 0)              # (nothing of the IDE behind it)
    # keys do nothing to the file
    for c in "xyz".codepoints():
        app.handle(key_event(Int(c)))
    app.handle(key_event(13))
    assert_equal(to_str(app.wins[t].buf.all_text()), before)
    assert_equal(app.mode, M_NORMAL)
    # the terminal grows: the IDE as it was
    app.scr.resize(100, 30)
    app.draw()
    s = screen(app)
    assert_true(s.find("Terminal too small") < 0 and s.find("struct Counter") >= 0, s)
    # the quit key still quits
    app.scr.resize(30, 8)
    app.draw()
    var quit_key = app.reg.key_label(CM_QUIT)
    assert_true(screen(app).replace("\n", " ").find(quit_key + " quits") >= 0, screen(app))
    var k = -1
    for c in app.reg.cmds:
        if c.id == CM_QUIT and len(c.keys) > 0:
            k = c.keys[0]
    assert_true(k > 0)
    app.running = True
    app.handle(key_event(k))
    assert_false(app.running)
    _ = run_system("rm -rf " + shell_quote(d))


def narrow(d: String, w: Int) raises -> App:
    var app = App()
    app.scr.resize(120, 30)
    app.cwd = d
    app.minimap_on = True
    app.open_path(d + "/a.mojo")
    var t = app.top_editor()
    app.wins[t].w = w
    app.wins[t].cr = 4
    app.draw()
    return app^


def test_what_gives_way_in_a_narrow_window() raises:
    var d = scratch("narrow")
    var wide = narrow(d, 80)
    var t = wide.top_editor()
    assert_true(wide.wins[t].minimap and wide.wins[t].gut > 0)
    assert_true(wide.wins[t].crumbs.find("Counter") >= 0, wide.wins[t].crumbs)
    var a = narrow(d, MINIMAP_MIN_W - 1)
    t = a.top_editor()
    assert_false(a.wins[t].minimap)
    assert_true(a.wins[t].crumbs.find("Counter") >= 0 and a.wins[t].gut > 0)
    var b = narrow(d, CRUMBS_MIN_W - 1)
    t = b.top_editor()
    assert_equal(b.wins[t].crumbs, "")
    assert_true(b.wins[t].gut > 0)
    var c = narrow(d, GUTTER_MIN_W - 1)
    t = c.top_editor()
    assert_equal(c.wins[t].gut, 0)
    # the text then starts right after the frame
    var row = to_str(c.scr.row_text(c.wins[t].y + 1))
    var x0 = c.wins[t].x
    var at = row.find("struct Counter")
    assert_true(at >= 0, row)
    assert_equal(cp_len(String(row[byte=0:at])), x0 + 1)         # right after the frame
    var e = narrow(d, GUTTER_MIN_W)
    assert_true(e.wins[e.top_editor()].gut > 0)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
