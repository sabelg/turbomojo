"""Tests for soft wrap: where lines break, drawing, cursor movement by screen rows,
scrolling inside long lines, mouse mapping, and the option in the app."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from window import Window, WK_EDITOR
from window_search import *
from window_multi import *
from window_draw import *
from buffer import Pos
from screen import Screen
from palette import theme
from highlight import Highlighter
from app import *
from appstate import App
from commands import CM_NEW, CM_WRAP, build_registry
from term import key_event, alt, KEY_DOWN, KEY_END
from util import decode, to_str


def win(text: String, w: Int, h: Int) -> Window:
    """A window whose text area is (w - 2) columns: rows wrap at w - 3."""
    var x = Window(WK_EDITOR, "t.mojo", "", 0, 0, w, h, 1)
    x.buf.load(decode(text))
    x.set_wrap(True)
    return x^


def breaks(w: Window, r: Int) -> String:
    var starts = List[Int]()
    var vs = List[Int]()
    w.wrap_layout(w.buf.line(r), starts, vs)
    var out = String("")
    for i in range(len(starts)):
        out += String(starts[i]) + "@" + String(vs[i]) + " "
    return out


def at(mut w: Window, r: Int, c: Int):
    w.cr = r
    w.cc = c
    w.sel = False
    w.sync_want()


def rows_text(w: Window) -> List[String]:
    var scr = Screen(w.w, w.h)
    w.draw(scr, theme(0), Highlighter(), True, False, True, False)
    var out = List[String]()
    for y in range(1, w.h - 1):
        var cps = scr.row_text(y)
        # drop the frame on both sides
        var inner = List[Int]()
        for i in range(1, len(cps)):
            if i == len(cps) - 1 and len(cps) == w.w:
                break
            inner.append(cps[i])
        while len(inner) > 0 and inner[len(inner) - 1] == 32:
            _ = inner.pop()
        out.append(to_str(inner))
    return out^


# ------------------------------------------------------------------- layout
def test_rows_break_after_the_last_blank_that_fits() raises:
    # text area 20 columns, rows of 19
    var w = win("aaaa bbbb cccc dddd eeee ffff\nshort\n", 22, 10)
    assert_equal(breaks(w, 0), "0@0 19@19 ")           # "aaaa bbbb cccc dddd" is exactly 19
    assert_equal(breaks(w, 1), "0@0 ")
    assert_equal(breaks(w, 2), "0@0 ")                 # an empty line is one row
    var w2 = win("aaaa bbbb cccc ddddd eeee", 22, 10)
    assert_equal(breaks(w2, 0), "0@0 15@15 ")          # "ddddd" does not fit: it moves down whole
    assert_equal(w2.row_segs(0), 2)


def test_long_words_are_cut() raises:
    var s = String("")
    for _ in range(50):
        s += "x"
    var w = win(s, 22, 10)
    assert_equal(breaks(w, 0), "0@0 19@19 38@38 ")


def test_wide_characters_and_tabs_count_by_screen_columns() raises:
    var cjk = String("")
    for _ in range(15):
        cjk += "日"
    var w = win(cjk + "\n\tab\tcd efgh ijkl mnop", 22, 10)
    assert_equal(breaks(w, 0), "0@0 9@18 ")            # nine fit in 19 columns, never half of one
    # tab to column 4, "ab", tab to column 8, "cd efgh " reaches column 16; "ijkl" would end at 20
    assert_equal(breaks(w, 1), "0@0 12@16 ")           # "i" is character 12 at column 16


def test_no_wrap_is_one_row_per_line() raises:
    var w = win("aaaa bbbb cccc dddd eeee ffff", 22, 10)
    w.set_wrap(False)
    assert_equal(breaks(w, 0), "0@0 ")
    assert_equal(w.row_segs(0), 1)


def test_rows_cover_the_line_exactly_and_fit_the_width() raises:
    # many random lines: the rows are a partition of the line and none is too wide
    var seed = 12345
    var pieces: List[String] = ["a", "bb", "word", " ", "  ", "\t", "日本", "x_y_z", "longerwordhere", ",", "🔥"]
    for round in range(300):
        var s = String("")
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        var n = (seed >> 8) % 40
        for _ in range(n):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            s += pieces[(seed >> 8) % len(pieces)]
        var w = win(s, 14 + round % 20, 6)
        var ln = w.buf.line(0)
        var starts = List[Int]()
        var vs = List[Int]()
        w.wrap_layout(ln, starts, vs)
        var width = w.cols() - 1
        assert_equal(starts[0], 0)
        for k in range(len(starts)):
            var end = len(ln) if k + 1 == len(starts) else starts[k + 1]
            assert_true(end > starts[k] or len(ln) == 0, "empty row in: " + s)
            assert_equal(vs[k], w.vcol(0, starts[k]))
            var wide = w.vcol(0, end) - vs[k]
            # a single character wider than the row (a tab) is the only excuse
            assert_true(wide <= width or end - starts[k] == 1, "row too wide (" + String(wide) + " > " + String(width) + ") in: " + s)


# ------------------------------------------------------------------ drawing
def test_wrapped_lines_are_drawn_on_following_rows() raises:
    var w = win("aaaa bbbb cccc dddd eeee ffff\nnext", 22, 6)
    var t = rows_text(w)
    assert_equal(t[0], "aaaa bbbb cccc dddd")
    assert_equal(t[1], " eeee ffff")
    assert_equal(t[2], "next")
    assert_equal(w.left, 0)


def test_line_numbers_only_on_the_first_row_of_a_line() raises:
    var w = win("aaaa bbbb cccc dddd eeee ffff\nnext", 26, 6)
    w.gut = w.gutter_for(True)                         # 4 columns: text area 20 again
    var t = rows_text(w)
    assert_equal(t[0], "  1 aaaa bbbb cccc dddd")
    assert_equal(t[1], "     eeee ffff")
    assert_equal(t[2], "  2 next")


def test_selection_and_current_line_cover_all_rows_of_a_line() raises:
    var p = theme(0)
    var w = win("aaaa bbbb cccc dddd eeee ffff\nnext", 22, 6)
    at(w, 0, 2)
    var scr = Screen(22, 6)
    w.draw(scr, p, Highlighter(), True, True, True, False)
    assert_equal(scr.bg_at(5, 1), p.curline_bg)
    assert_equal(scr.bg_at(5, 2), p.curline_bg)        # the continuation row too
    assert_equal(scr.bg_at(5, 3), p.ed_bg)
    w.sel = True
    w.ar = 0
    w.ac = 17
    w.cc = 22                                          # from "dd" on row 1 into " ee" on row 2
    w.draw(scr, p, Highlighter(), True, False, True, False)
    assert_equal(scr.bg_at(1 + 17, 1), p.sel_bg)
    assert_equal(scr.bg_at(1 + 18, 1), p.sel_bg)
    assert_equal(scr.bg_at(1 + 0, 2), p.sel_bg)        # index 19 is the first cell of row 2
    assert_equal(scr.bg_at(1 + 2, 2), p.sel_bg)
    assert_equal(scr.bg_at(1 + 3, 2), p.ed_bg)


# ----------------------------------------------------------------- movement
def test_up_and_down_move_by_screen_rows() raises:
    var w = win("aaaa bbbb cccc dddd eeee ffff gggg\nnext line here", 22, 8)
    assert_equal(breaks(w, 0), "0@0 19@19 ")           # second row: " eeee ffff gggg"
    at(w, 0, 6)
    w.move_vert(1, False)
    assert_equal(w.cr, 0)
    assert_equal(w.cc, 25)                             # same offset 6 on the second row
    w.move_vert(1, False)
    assert_equal(w.cr, 1)
    assert_equal(w.cc, 6)
    w.move_vert(-1, False)
    assert_equal(w.cr, 0)
    assert_equal(w.cc, 25)
    w.move_vert(-1, False)
    assert_equal(w.cc, 6)
    w.move_vert(-1, False)                             # first row of the text: stays
    assert_equal(w.cr, 0)
    assert_equal(w.cc, 6)


def test_offset_is_remembered_across_short_rows() raises:
    var w = win("0123456789abcdef\nab\n0123456789abcdef", 22, 8)
    at(w, 0, 12)
    w.move_vert(1, False)
    assert_equal(w.cc, 2)
    w.move_vert(1, False)
    assert_equal(w.cr, 2)
    assert_equal(w.cc, 12)


def test_cursor_cell_follows_the_wrapped_position() raises:
    var w = win("aaaa bbbb cccc dddd eeee ffff\nnext", 22, 6)
    at(w, 0, 0)
    assert_equal(w.cursor_cell().r, 1)
    assert_equal(w.cursor_cell().c, 1)
    at(w, 0, 18)
    assert_equal(w.cursor_cell().r, 1)
    assert_equal(w.cursor_cell().c, 19)
    at(w, 0, 19)                                       # first character of the second row
    assert_equal(w.cursor_cell().r, 2)
    assert_equal(w.cursor_cell().c, 1)
    at(w, 0, 29)                                       # end of the line
    assert_equal(w.cursor_cell().r, 2)
    assert_equal(w.cursor_cell().c, 11)
    at(w, 1, 4)
    assert_equal(w.cursor_cell().r, 3)
    assert_equal(w.cursor_cell().c, 5)


def test_mouse_position_maps_back_to_the_text() raises:
    var w = win("aaaa bbbb cccc dddd eeee ffff\nnext\n", 22, 8)
    # every character position, shown where cursor_cell says, is found again by a click
    for r in range(2):
        for c in range(w.buf.llen(r) + 1):
            at(w, r, c)
            var cell = w.cursor_cell()
            var p = w.screen_to_pos(cell.c, cell.r)
            assert_equal(p.r, r, "row for " + String(r) + ":" + String(c))
            assert_equal(p.c, c, "column for " + String(r) + ":" + String(c))
    # right of a wrapped row's text: its last character; below the text: the end
    var p2 = w.screen_to_pos(20, 1)
    assert_equal(p2.c, 18)
    var p3 = w.screen_to_pos(5, 6)
    assert_equal(p3.r, 2)


# ---------------------------------------------------------------- scrolling
def test_a_line_taller_than_the_window_can_be_reached_everywhere() raises:
    var s = String("")
    for i in range(120):
        s += "w" + String(i) + " "
    var w = win("first\n" + s + "\nlast", 22, 7)          # 5 text rows
    var total = w.row_segs(1)
    assert_true(total > 20, "the long line must take many rows")
    at(w, 1, w.buf.llen(1))
    w.ensure_visible()
    var cell = w.cursor_cell()
    assert_true(cell.r >= 1 and cell.r <= 5, "cursor row " + String(cell.r))
    assert_equal(w.top, 1)
    assert_true(w.top_seg > 0)                          # scrolled inside the line
    # walk up through every screen row; the cursor stays in view all the way
    var steps = 0
    while w.cr > 0 and steps < 500:
        w.move_vert(-1, False)
        w.ensure_visible()
        var c2 = w.cursor_cell()
        assert_true(c2.r >= 1 and c2.r <= 5, "lost the cursor at step " + String(steps))
        assert_true(c2.c >= 1 and c2.c <= 20, "cursor column " + String(c2.c))
        steps += 1
    assert_equal(w.cr, 0)
    assert_equal(steps, total)                          # the rows above the last one, then line 0


def test_scrolling_moves_by_screen_rows() raises:
    var w = win("aaaa bbbb cccc dddd eeee ffff\nnext\nthird", 22, 6)
    w.scroll(1)
    assert_equal(w.top, 0)
    assert_equal(w.top_seg, 1)
    assert_equal(rows_text(w)[0], " eeee ffff")
    w.scroll(1)
    assert_equal(w.top, 1)
    assert_equal(w.top_seg, 0)
    w.scroll(-5)
    assert_equal(w.top, 0)
    assert_equal(w.top_seg, 0)
    w.scroll(100)
    assert_equal(w.top, 2)                              # the last line stays reachable


def test_typing_past_the_edge_wraps_instead_of_scrolling() raises:
    var w = win("", 22, 6)
    for c in decode("the quick brown fox jumps over"):
        w.type_char(c, True)
        w.ensure_visible()
    assert_equal(w.left, 0)
    var t = rows_text(w)
    assert_equal(t[0], "the quick brown fox")
    assert_equal(t[1], " jumps over")
    assert_equal(w.cursor_cell().r, 2)
    assert_equal(w.cursor_cell().c, 12)


def test_resizing_rewraps() raises:
    var w = win("aaaa bbbb cccc dddd eeee ffff", 22, 6)
    assert_equal(w.row_segs(0), 2)
    w.w = 14                                            # text area 12, rows of 11
    assert_equal(breaks(w, 0), "0@0 10@10 20@20 ")
    w.w = 40
    assert_equal(w.row_segs(0), 1)


# ---------------------------------------------------------------------- app
def test_option_toggles_every_editor_and_new_ones() raises:
    var r = build_registry()
    assert_equal(r.find_key(alt(122)), CM_WRAP)
    var app = App()
    app.scr.resize(80, 25)
    app.exec(CM_NEW)
    app.exec(CM_NEW)
    assert_false(app.wins[0].wrap)
    app.handle(key_event(alt(122)))
    assert_true(app.soft_wrap)
    assert_equal(app.status, "Soft wrap on")
    for i in range(len(app.wins)):
        assert_true(app.wins[i].wrap)
    app.exec(CM_NEW)
    assert_true(app.wins[app.top()].wrap)
    app.exec(CM_WRAP)
    for i in range(len(app.wins)):
        assert_false(app.wins[i].wrap)
        assert_equal(app.wins[i].top_seg, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
