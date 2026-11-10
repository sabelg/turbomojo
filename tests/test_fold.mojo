"""Tests for folding by indentation: blocks, hidden lines, edits around folds, drawing,
movement and the commands."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from buffer import TextBuffer, Pos
from window import Window, WK_EDITOR
from window_search import *
from window_multi import *
from window_draw import *
from screen import Screen
from palette import theme
from highlight import Highlighter, C_STR
from app import *
from appstate import App
from commands import CM_NEW, CM_FOLD, CM_FOLDALL, CM_UNFOLDALL, CM_UNDO, build_registry
from term import Event, EV_MOUSE, MB_LEFT, key_event, alt, KEY_ENTER, KEY_DOWN, KEY_UP, KEY_END
from util import decode, to_str

comptime SRC = "struct S:\n    var a: Int\n\n    def f(self):\n        x = 1\n        y = 2\n\n    def g(self):\n        pass\n\n\ndef main():\n    print(1)\nz = 0"
# rows: 0 struct, 1 var, 2 blank, 3 def f, 4 x, 5 y, 6 blank, 7 def g, 8 pass, 9 blank,
#       10 blank, 11 def main, 12 print, 13 z


def buf(text: String) -> TextBuffer:
    var b = TextBuffer()
    b.load(decode(text))
    return b^


def win(text: String) -> Window:
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 40, 12, 1)
    w.buf.load(decode(text))
    return w^


def folds(b: TextBuffer) -> String:
    var out = String("")
    for i in range(len(b.folds)):
        out += String(b.folds[i]) + "-" + String(b.fold_ends[i]) + " "
    return out


def visible(b: TextBuffer) -> String:
    """The visible rows, separated by spaces."""
    var out = String("")
    var r = 0
    while r < b.count():
        out += String(r) + " "
        r = b.next_row(r)
    return out


def shown(w: Window) -> List[String]:
    var scr = Screen(w.w, w.h)
    w.draw(scr, theme(0), Highlighter(), True, False, True, False)
    var out = List[String]()
    for y in range(1, w.h - 1):
        var cps = scr.row_text(y)
        var inner = List[Int]()
        for i in range(1, len(cps)):
            if i == len(cps) - 1 and len(cps) == w.w:
                break
            inner.append(cps[i])
        while len(inner) > 0 and inner[len(inner) - 1] == 32:
            _ = inner.pop()
        out.append(to_str(inner))
    return out^


# ------------------------------------------------------------------- blocks
def test_indentation_and_blocks() raises:
    var b = buf(SRC)
    assert_equal(b.indent_cols(0), 0)
    assert_equal(b.indent_cols(4), 8)
    assert_equal(b.indent_cols(2), -1)                 # blank
    assert_equal(b.block_end(0), 8)                    # the struct, without the blank lines after it
    assert_equal(b.block_end(3), 5)
    assert_equal(b.block_end(7), 8)
    assert_equal(b.block_end(11), 12)
    assert_equal(b.block_end(1), 1)                    # no block under "var a"
    assert_equal(b.block_end(13), 13)
    assert_equal(b.block_end(2), 2)                    # a blank line starts nothing
    assert_true(b.foldable(0) and b.foldable(3) and b.foldable(11))
    assert_false(b.foldable(1) or b.foldable(5) or b.foldable(13) or b.foldable(9))
    var t = buf("a:\n\tb\n\t\tc\nd")
    assert_equal(t.indent_cols(2), 8)                  # two tabs of width 4
    assert_equal(t.block_end(0), 2)


def test_fold_hides_the_block_and_unfold_shows_it() raises:
    var b = buf(SRC)
    assert_true(b.set_fold(3, True))
    assert_equal(folds(b), "3-5 ")
    assert_equal(visible(b), "0 1 2 3 6 7 8 9 10 11 12 13 ")
    assert_equal(b.hidden_by(4), 3)
    assert_equal(b.hidden_by(3), -1)
    assert_equal(b.hidden_by(6), -1)
    assert_equal(b.prev_row(6), 3)
    assert_equal(b.prev_row(0), -1)
    assert_false(b.set_fold(1, True))                  # nothing to fold there
    assert_true(b.set_fold(3, False))
    assert_equal(visible(b), "0 1 2 3 4 5 6 7 8 9 10 11 12 13 ")
    assert_false(b.set_fold(3, False))


def test_nested_folds() raises:
    var b = buf(SRC)
    _ = b.set_fold(3, True)
    _ = b.set_fold(0, True)
    assert_equal(folds(b), "0-8 3-5 ")
    assert_equal(visible(b), "0 9 10 11 12 13 ")
    assert_equal(b.hidden_by(4), 0)                    # the outermost one
    _ = b.set_fold(0, False)
    assert_equal(visible(b), "0 1 2 3 6 7 8 9 10 11 12 13 ")   # the inner one is still folded


def test_fold_all_and_unfold_all() raises:
    var b = buf(SRC)
    assert_equal(b.fold_all(), 4)
    assert_equal(folds(b), "0-8 3-5 7-8 11-12 ")
    assert_equal(visible(b), "0 9 10 11 13 ")
    b.unfold_all()
    assert_equal(len(b.folds), 0)
    assert_equal(b.next_row(0), 1)


def test_edits_move_and_remove_folds() raises:
    var b = buf(SRC)
    _ = b.set_fold(3, True)
    _ = b.set_fold(11, True)
    _ = b.insert(0, 0, decode("# top\n# two\n"), 0, 0, 0)       # two lines above everything
    b.sync_folds()
    assert_equal(folds(b), "5-7 13-14 ")
    _ = b.delete(0, 0, 1, 0, 0, 0, 0)                           # one of them away again
    b.sync_folds()
    assert_equal(folds(b), "4-6 12-13 ")
    _ = b.undo()
    b.sync_folds()
    assert_equal(folds(b), "5-7 13-14 ")
    _ = b.redo()
    # typing inside the folded header line keeps the fold
    _ = b.insert(4, 4, decode("x"), 0, 0, 0)
    b.sync_folds()
    assert_equal(folds(b), "4-6 12-13 ")
    # a new line added to the block makes the fold longer
    _ = b.insert(6, b.llen(6), decode("\n        z = 3"), 0, 0, 0)
    b.sync_folds()
    assert_equal(folds(b), "4-7 13-14 ")
    # deleting the header line removes its fold
    _ = b.delete(3, b.llen(3), 4, b.llen(4), 0, 0, 0)
    b.sync_folds()
    assert_equal(folds(b), "12-13 ")
    # a header that no longer has a block under it stops being a fold
    _ = b.delete(13, 0, 13, 4, 0, 0, 0)                         # dedent "print(1)"
    b.sync_folds()
    assert_equal(folds(b), "")


def test_loading_another_text_drops_the_folds() raises:
    var b = buf(SRC)
    _ = b.set_fold(0, True)
    b.load(decode("a:\n    b\n"))
    assert_equal(len(b.folds), 0)
    assert_equal(b.next_row(0), 1)


# ------------------------------------------------------------------- window
def test_folded_block_is_drawn_as_one_line() raises:
    var w = win(SRC)
    w.gut = w.gutter_for(True)
    _ = w.toggle_fold(3)
    var t = shown(w)
    assert_equal(t[0], "  1▾struct S:")
    assert_equal(t[1], "  2     var a: Int")
    assert_equal(t[3], "  4▸    def f(self):  ⋯ 2 lines")
    assert_equal(t[4], "  7")
    assert_equal(t[5], "  8▾    def g(self):")
    _ = w.toggle_fold(0)
    t = shown(w)
    assert_equal(t[0], "  1▸struct S:  ⋯ 8 lines")
    assert_equal(t[1], " 10")
    assert_equal(t[3], " 12▾def main():")


def test_fold_from_inside_a_block_moves_the_cursor_to_its_header() raises:
    var w = win(SRC)
    w.cr = 5
    w.cc = 8
    assert_true(w.toggle_fold(5))                      # "y = 2" is inside def f
    assert_equal(w.cr, 3)
    assert_equal(w.buf.fold_index(3), 0)
    assert_true(w.toggle_fold(3))                      # on the header: unfold
    assert_equal(len(w.buf.folds), 0)
    w.cr = 13
    assert_false(w.toggle_fold(13))                    # top level, no block: nothing happens
    w.cr = 9
    assert_false(w.toggle_fold(9))                     # blank line after the struct
    w.cr = 2
    assert_true(w.toggle_fold(2))                      # blank line inside the struct: folds the struct
    assert_equal(w.cr, 0)
    assert_equal(w.buf.fold_index(0), 0)


def test_movement_skips_hidden_lines() raises:
    var w = win(SRC)
    _ = w.toggle_fold(3)
    w.cr = 2
    w.cc = 0
    w.sync_want()
    w.move_vert(1, False)
    assert_equal(w.cr, 3)
    w.move_vert(1, False)
    assert_equal(w.cr, 6)
    w.move_vert(-1, False)
    assert_equal(w.cr, 3)
    w.cc = w.buf.llen(3)
    w.move_right(False, False)                         # from the end of the header
    assert_equal(w.cr, 6)
    assert_equal(w.cc, 0)
    w.move_left(False, False)
    assert_equal(w.cr, 3)
    assert_equal(w.cc, w.buf.llen(3))
    assert_equal(len(w.buf.folds), 1)                  # none of this opened the fold


def test_jumping_into_a_fold_opens_it() raises:
    var w = win(SRC)
    _ = w.toggle_fold(3)
    _ = w.toggle_fold(0)
    w.goto(4, 2)                                       # e.g. a search hit or an error position
    w.ensure_visible()
    assert_equal(w.cr, 4)
    assert_equal(w.buf.hidden_by(4), -1)
    assert_equal(len(w.buf.folds), 0)                  # both enclosing folds are open


def test_cursor_cell_and_clicks_with_folds() raises:
    var w = win(SRC)
    _ = w.toggle_fold(0)                               # rows shown: 0, 9, 10, 11, 12, 13
    w.cr = 11
    w.cc = 4
    w.ensure_visible()
    assert_equal(w.cursor_cell().r, 4)                 # fourth text row of the window
    assert_equal(w.cursor_cell().c, 5)
    var p = w.screen_to_pos(3, 5)                      # the row below: line 12
    assert_equal(p.r, 12)
    assert_equal(p.c, 2)
    var p0 = w.screen_to_pos(1, 1)
    assert_equal(p0.r, 0)
    w.scroll(1)
    assert_equal(w.top, 9)
    w.scroll(-1)
    assert_equal(w.top, 0)


def test_syntax_colours_resume_correctly_after_a_fold() raises:
    var p = theme(0)
    var w = win("def a():\n    \"\"\"doc\n    more\"\"\"\n    pass\nyy = 1")
    _ = w.toggle_fold(0)
    w.sync_lex(5)
    var scr = Screen(40, 12)
    w.draw(scr, p, Highlighter(), False, False, True, False)
    # row 2 of the window shows "yy = 1": not coloured as part of the hidden docstring
    assert_equal(to_str(scr.row_text(2)).find("yy = 1") >= 0, True)
    assert_true(scr.fg_at(1, 2) != p.syn[C_STR], "text after the fold is coloured as a string")


def test_folds_and_soft_wrap_together() raises:
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 22, 8, 1)
    w.buf.load(decode("head:\n    aaaa bbbb cccc dddd eeee\n    x\ntail tail tail tail tail tail"))
    w.set_wrap(True)
    var t = shown(w)
    assert_equal(t[0], "head:")
    assert_equal(t[1], "    aaaa bbbb cccc")
    _ = w.toggle_fold(0)
    t = shown(w)
    assert_equal(t[0], "head:  ⋯ 2 lines")
    assert_equal(t[1], "tail tail tail tail")
    assert_equal(t[2], " tail tail")
    w.cr = 3
    w.cc = 22
    w.ensure_visible()
    assert_equal(w.cursor_cell().r, 3)


def test_cursor_is_never_left_on_a_hidden_line() raises:
    var w = win(SRC)
    var seed = 7
    for step in range(400):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        var k = (seed >> 8) % 6
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        var row = (seed >> 8) % w.buf.count()
        if k == 0:
            _ = w.toggle_fold(row)
        elif k == 1:
            w.move_vert(1, False)
        elif k == 2:
            w.move_vert(-1, False)
        elif k == 3:
            w.move_right(False, False)
        elif k == 4:
            w.move_left(False, False)
        else:
            w.goto(row, 0)
        w.ensure_visible()
        assert_equal(w.buf.hidden_by(w.cr), -1, "cursor hidden at step " + String(step))
        assert_equal(w.buf.hidden_by(w.top), -1, "top hidden at step " + String(step))
        var cell = w.cursor_cell()
        assert_true(cell.r >= 1 and cell.r <= 10, "cursor out of view at step " + String(step))


# ---------------------------------------------------------------------- app
def make(src: String) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode(src))
    return app^


def test_fold_commands_and_keys() raises:
    var r = build_registry()
    assert_equal(r.find_key(alt(45)), CM_FOLD)
    assert_equal(r.find_key(alt(61)), CM_UNFOLDALL)
    var app = make(SRC)
    var t = app.top()
    app.wins[t].cr = 4
    app.handle(key_event(alt(45)))
    assert_equal(app.wins[t].buf.fold_index(3), 0)
    assert_equal(app.wins[t].cr, 3)
    app.wins[t].cr = 13
    app.handle(key_event(alt(45)))
    assert_equal(app.status, "Nothing to fold here")
    app.exec(CM_FOLDALL)
    assert_equal(app.status, "4 blocks folded")
    assert_equal(app.wins[t].buf.hidden_by(app.wins[t].cr), -1)
    app.handle(key_event(alt(61)))
    assert_equal(len(app.wins[t].buf.folds), 0)


def test_typing_a_new_line_after_a_folded_header_opens_it() raises:
    var app = make(SRC)
    var t = app.top()
    _ = app.wins[t].toggle_fold(11)
    app.wins[t].cr = 11
    app.wins[t].cc = app.wins[t].buf.llen(11)
    app.handle(key_event(KEY_ENTER))
    app.draw()
    # the cursor is on the new line inside the block, so the block has to be visible
    assert_equal(app.wins[t].cr, 12)
    assert_equal(app.wins[t].buf.hidden_by(12), -1)
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[t].buf.all_text()), SRC)


def test_click_on_the_gutter_marker_toggles_the_fold() raises:
    var app = make(SRC)
    var t = app.top()
    app.draw()                                         # sets the gutter width
    var mx = app.wins[t].x + app.wins[t].gut
    var my = app.wins[t].y + 1 + 3                     # line 4: "def f"
    app.handle(Event(EV_MOUSE, 0, mx, my, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, mx, my, MB_LEFT, False, False, List[Int]()))
    assert_equal(app.wins[t].buf.fold_index(3), 0)
    app.handle(Event(EV_MOUSE, 0, mx, my, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, mx, my, MB_LEFT, False, False, List[Int]()))
    assert_equal(len(app.wins[t].buf.folds), 0)
    # the same column on a line that starts no block is an ordinary click
    app.handle(Event(EV_MOUSE, 0, mx, my - 2, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, mx, my - 2, MB_LEFT, False, False, List[Int]()))
    assert_equal(len(app.wins[t].buf.folds), 0)
    assert_equal(app.wins[t].cr, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
