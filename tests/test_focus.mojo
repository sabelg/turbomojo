"""Tests for focus shown in more than one way (P10-01): the window with the focus has a
double frame, a bold title and the terminal's cursor; one without it has a single frame,
a plain title, its selected row muted (not gone) and, for an editor, a muted cell where
its cursor is; the shown tab is in brackets as well as in other colours. And the
renderer's bold: switched on and off, kept beside an underline, cleared by redrawing."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from screen import Screen, BOLD_BIT
from palette import mix
from commands import CM_NEW, CM_MESSAGE
from app import *
from appstate import App
from util import decode, to_str, bytes_to_str


def test_bold_in_the_renderer() raises:
    var s = Screen(20, 3)
    _ = s.text(1, 0, "Title", 0xFFFFFF, 0x0000AA)
    s.bold(1, 0, 5)
    assert_true(s.is_bold(1, 0) and s.is_bold(5, 0))
    assert_false(s.is_bold(6, 0))
    s.underline(2, 0, True, 0xFF0000)
    assert_true(s.is_bold(2, 0))                       # an underline keeps the bold
    assert_equal(s.ul_at(2, 0), 3)                      # and the kind is still read right
    var out = List[UInt8]()
    s.render(out)
    var esc = bytes_to_str(out)
    var on = esc.find("\x1b[1m")
    var off = esc.find("\x1b[22m")
    assert_true(on >= 0 and off > on, esc)
    assert_true(esc.find("Title") > on or esc.find("T") > on)
    # drawn again: no longer bold
    _ = s.text(1, 0, "Other", 0xFFFFFF, 0x0000AA)
    assert_false(s.is_bold(1, 0))
    assert_equal(mix(0xFFFFFF, 0x000000, 50), 0x7F7F7F)


def two_editors() raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode("first window\nsecond line\n"))
    app.wins[app.top()].x = 0
    app.wins[app.top()].w = 50
    app.wins[app.top()].goto(1, 3)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode("other text\n"))
    app.wins[app.top()].x = 50
    app.wins[app.top()].w = 50
    return app^


def title_bold(app: App, i: Int) -> Bool:
    var w = app.wins[i].copy()
    for x in range(w.x + 1, w.x + w.w - 1):
        var c = app.scr.ch[w.y * app.scr.w + x]
        if c > 64 and c < 123 and app.scr.is_bold(x, w.y):
            return True
    return False


def test_the_focused_window_is_shown_three_ways() raises:
    var app = two_editors()
    app.draw()
    var front = app.top()
    var back = 0 if front != 0 else 1
    for i in range(len(app.wins)):
        if app.wins[i].kind == 0 and i != front:
            back = i
    var f = app.wins[front].copy()
    var b = app.wins[back].copy()
    assert_equal(app.scr.ch[f.y * app.scr.w + f.x], 0x2554)       # double frame
    assert_equal(app.scr.ch[b.y * app.scr.w + b.x], 0x250C)       # single frame
    assert_true(title_bold(app, front))
    assert_false(title_bold(app, back))
    assert_true(app.scr.cvis)
    assert_true(app.scr.cx >= f.x and app.scr.cx < f.x + f.w)    # the one cursor is in front
    # the window behind still shows where its cursor is: a muted cell
    var cell = app.wins[back].cursor_cell()
    var cbg = app.scr.bg_at(cell.c, cell.r)
    assert_true(cbg != app.pal.ed_bg, "no mark where the cursor of the window behind is")
    assert_true(app.scr.bg_at(cell.c + 3, cell.r) == app.pal.ed_bg)


def test_a_list_without_the_focus_keeps_its_row_muted() raises:
    var app = two_editors()
    app.exec(CM_MESSAGE)
    var mi = app.msg_index()
    app.wins[mi].buf.load(decode("one\ntwo\nthree\n"))
    app.wins[mi].cr = 1
    app.focus(mi)
    app.draw()
    mi = app.top()
    var y = app.wins[mi].y + 2
    var x = app.wins[mi].x + 3
    assert_equal(app.scr.bg_at(x, y), app.pal.msg_sel_bg)        # with the focus: the selection
    # the focus goes elsewhere: the row is still marked, muted
    app.focus(0)
    app.draw()
    mi = app.msg_index()
    y = app.wins[mi].y + 2
    var muted = app.scr.bg_at(x, y)
    assert_true(muted != app.pal.msg_sel_bg, "the row looks the same with and without the focus")
    assert_true(muted != app.pal.msg_bg, "the row is no longer marked")
    assert_equal(app.scr.bg_at(x, y + 1), app.pal.msg_bg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
