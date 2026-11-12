"""Tests for breadcrumbs, the sticky scope header and the minimap (P7-05)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from outline import scan_outline, scope_path, breadcrumbs, sticky_rows, OutlineItem
from buffer import TextBuffer
from window import MINIMAP_W
from window_draw import braille, braille_dot
from config import load_settings
from term import Event, EV_MOUSE, MB_LEFT
from app import *
from appstate import App
from commands import CM_NEW
from util import decode, to_str


def source() -> String:
    var s = String("struct Counter:\n    var n: Int\n\n    def __init__(out self):\n        self.n = 0\n\n    def add(mut self, by: Int):\n")
    for k in range(30):
        s += "        self.n += by   # step " + String(k) + "\n"
    s += "\n\ndef main():\n    var c = Counter()\n    c.add(2)\n"
    return s^


def items_of(text: String) -> List[OutlineItem]:
    var b = TextBuffer()
    b.load(decode(text))
    return scan_outline(b)


def test_scopes() raises:
    var it = items_of(source())
    assert_equal(it[0].name, "Counter")
    var add_row = it[2].row                          # def add
    assert_equal(it[2].name, "add")
    var p = scope_path(it, add_row + 10)
    assert_equal(len(p), 2)
    assert_equal(breadcrumbs(it, p), " › Counter › add")
    assert_equal(breadcrumbs(it, scope_path(it, 1)), " › Counter")
    var main_row = it[len(it) - 1].row
    assert_equal(breadcrumbs(it, scope_path(it, main_row + 1)), " › main")
    assert_equal(breadcrumbs(it, scope_path(it, main_row - 1)), " › Counter › add")   # (blank lines end the block at the next def)
    # pinned: the headers scrolled away, at most `most`, never over the cursor
    var top = add_row + 5
    var s = sticky_rows(it, scope_path(it, top), top, top + 10, 3)
    assert_equal(len(s), 2)
    assert_equal(s[0], 0)
    assert_equal(s[1], add_row)
    assert_equal(len(sticky_rows(it, scope_path(it, top), top, top + 1, 3)), 1)      # cursor on the 2nd row
    assert_equal(len(sticky_rows(it, scope_path(it, top), top, top, 3)), 0)          # cursor on the 1st
    assert_equal(len(sticky_rows(it, scope_path(it, top), top, top + 10, 1)), 1)     # one at most: the inner one
    assert_equal(sticky_rows(it, scope_path(it, top), top, top + 10, 1)[0], add_row)
    assert_equal(len(sticky_rows(it, scope_path(it, 0), 0, 5, 3)), 0)                # nothing scrolled away


def editor(mut app: App) raises -> Int:
    app.exec(CM_NEW)
    var i = app.top()
    app.wins[i].buf.load(decode(source()))
    return i


def test_breadcrumbs_and_pinned_headers_on_screen() raises:
    var app = App()
    app.scr.resize(100, 20)
    var i = editor(app)
    var it = items_of(source())
    var add_row = it[2].row
    app.wins[i].top = add_row + 5
    app.wins[i].cr = add_row + 12
    app.draw()
    var w = app.wins[app.top()].copy()
    assert_equal(w.crumbs, " › Counter › add")
    assert_true(to_str(app.scr.row_text(w.y)).find("NONAME00.mojo › Counter › add") > 0, to_str(app.scr.row_text(w.y)))
    assert_equal(len(w.sticky), 2)
    assert_true(to_str(app.scr.row_text(w.y + 1)).find("struct Counter:") > 0, to_str(app.scr.row_text(w.y + 1)))
    assert_true(to_str(app.scr.row_text(w.y + 2)).find("def add(mut self, by: Int):") > 0)
    assert_true(to_str(app.scr.row_text(w.y + 3)).find("# step") > 0)
    # a click on a pinned header goes to it
    app.handle(Event(EV_MOUSE, 0, w.x + 10, w.y + 2, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, w.x + 10, w.y + 2, MB_LEFT, False, False, List[Int]()))
    assert_equal(app.wins[app.top()].cr, add_row)
    # switched off
    app.apply_settings(load_settings("[editor]\nbreadcrumbs = false\nsticky_scroll = false\n", ""))
    app.wins[app.top()].top = add_row + 5
    app.wins[app.top()].cr = add_row + 12
    app.draw()
    assert_equal(app.wins[app.top()].crumbs, "")
    assert_equal(len(app.wins[app.top()].sticky), 0)


def test_the_minimap() raises:
    assert_equal(braille(0), 0x2800)
    assert_equal(braille(0xFF), 0x28FF)
    assert_equal(braille_dot(0, 0), 0x01)
    assert_equal(braille_dot(1, 3), 0x80)
    assert_equal(braille_dot(1, 1), 0x10)
    var app = App()
    app.scr.resize(100, 20)
    var i = editor(app)
    var cols_before = app.wins[i].cols()
    app.apply_settings(load_settings("[editor]\nminimap = true\n", ""))
    app.draw()
    var w = app.wins[app.top()].copy()
    assert_true(w.minimap)
    assert_equal(w.cols(), cols_before - MINIMAP_W)
    var dots = 0
    for y in range(w.y + 1, w.y + w.h - 1):
        for x in range(w.x + w.w - 1 - MINIMAP_W, w.x + w.w - 1):
            var c = app.scr.ch[y * app.scr.w + x]
            if c > 0x2800 and c <= 0x28FF:
                dots += 1
    assert_true(dots > 5, String(dots))
    # not for a screen reader, nor in a narrow window
    app.apply_settings(load_settings("[editor]\nminimap = true\n[ui]\nscreen_reader = true\n", ""))
    app.draw()
    assert_false(app.wins[app.top()].minimap)
    app.apply_settings(load_settings("[editor]\nminimap = true\n", ""))
    app.wins[app.top()].w = 50
    app.draw()
    assert_false(app.wins[app.top()].minimap)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
