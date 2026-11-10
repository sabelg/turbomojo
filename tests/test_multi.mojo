"""Tests for multi-cursor editing (src/window_multi.mojo) and its commands in the app."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from window import Window, WK_EDITOR, Cur
from window_search import *
from window_multi import *
from window_draw import *
from screen import Screen
from palette import theme
from highlight import Highlighter
from app import *
from appstate import App, M_NORMAL
from commands import (
    CM_NEW, CM_ADDNEXT, CM_CURABOVE, CM_CURBELOW, CM_UNDO, CM_REDO, CM_COPY, CM_CUT, CM_PASTE, CM_DUPLINE,
    build_registry,
)
from term import (
    Event, EV_MOUSE, MB_LEFT, key_event, KEY_ESC, KEY_ENTER, KEY_BACKSPACE, KEY_DELETE, KEY_LEFT, KEY_RIGHT,
    KEY_UP, KEY_DOWN, KEY_HOME, KEY_END, KEY_TAB, MOD_ALT, MOD_CTRL, MOD_SHIFT, alt, Terminal,
)
from util import decode, to_str, str_bytes


def win(text: String) -> Window:
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 40, 12, 1)
    w.buf.load(decode(text))
    return w^


def text(w: Window) -> String:
    return to_str(w.buf.all_text())


def at(mut w: Window, r: Int, c: Int):
    w.cr = r
    w.cc = c
    w.sel = False
    w.sync_want()


def plus(mut w: Window, r: Int, c: Int):
    w.add_cursor(Cur(r, c, False, r, c, w.vcol(r, c)))


def cursors(w: Window) -> String:
    """All cursors in document order as "r:c", selections as "r:a-c"; the main one has
    a "*" in front."""
    var cs = w.all_cursors()
    var main = len(cs) - 1
    var order = List[Int]()
    for i in range(len(cs)):
        var k = len(order)
        order.append(i)
        while k > 0 and pos_lt(cur_start(cs[order[k]]), cur_start(cs[order[k - 1]])):
            var t = order[k - 1]
            order[k - 1] = order[k]
            order[k] = t
            k -= 1
    var out = String("")
    for oi in order:
        var c = cs[oi].copy()
        if oi == main:
            out += "*"
        out += String(c.r) + ":"
        if c.sel and (c.ar != c.r or c.ac != c.c):
            out += String(c.ac) + "-" if c.ar == c.r else String(c.ar) + "," + String(c.ac) + "-"
        out += String(c.c) + " "
    return out


def typ(mut w: Window, s: String):
    for c in decode(s):
        w.multi(OP_TYPE, c, True, False, List[Int]())


def op(mut w: Window, o: Int):
    w.multi(o, 0, False, False, List[Int]())


# ------------------------------------------------------------------ editing
def test_typing_at_several_cursors() raises:
    var w = win("ab\ncd\nef")
    at(w, 0, 1)
    plus(w, 1, 1)
    plus(w, 2, 1)
    assert_equal(cursors(w), "0:1 1:1 *2:1 ")
    typ(w, "XY")
    assert_equal(text(w), "aXYb\ncXYd\neXYf")
    assert_equal(cursors(w), "0:3 1:3 *2:3 ")


def test_cursors_on_one_line_shift_each_other() raises:
    var w = win("abcdef")
    at(w, 0, 1)
    plus(w, 0, 3)
    plus(w, 0, 5)
    typ(w, "--")
    assert_equal(text(w), "a--bc--de--f")
    assert_equal(cursors(w), "0:3 0:7 *0:11 ")
    op(w, OP_BACK)
    assert_equal(text(w), "a-bc-de-f")
    assert_equal(cursors(w), "0:2 0:5 *0:8 ")
    op(w, OP_DEL)
    assert_equal(text(w), "a-c-e-")
    assert_equal(cursors(w), "0:2 0:4 *0:6 ")


def test_one_step_is_one_undo() raises:
    var w = win("ab\ncd\nef")
    at(w, 0, 0)
    plus(w, 1, 0)
    plus(w, 2, 0)
    typ(w, "x")
    w.break_group()
    op(w, OP_NEWLINE)
    assert_equal(text(w), "x\nab\nx\ncd\nx\nef")
    w.undo()
    assert_equal(text(w), "xab\nxcd\nxef")       # the three line breaks together
    w.undo()
    assert_equal(text(w), "ab\ncd\nef")          # the three letters together
    w.redo()
    assert_equal(text(w), "xab\nxcd\nxef")
    assert_false(w.has_multi())                  # undo goes back to one cursor


def test_typing_run_is_undone_together() raises:
    var w = win("a\nb")
    at(w, 0, 1)
    plus(w, 1, 1)
    typ(w, "123")
    assert_equal(text(w), "a123\nb123")
    w.undo()
    assert_equal(text(w), "a\nb")


def test_newline_with_several_cursors_moves_the_later_ones_down() raises:
    var w = win("ab cd\nef")
    at(w, 0, 2)
    plus(w, 0, 5)
    plus(w, 1, 1)
    w.multi(OP_NEWLINE, 0, False, False, List[Int]())
    assert_equal(text(w), "ab\n cd\n\ne\nf")
    assert_equal(cursors(w), "1:0 2:0 *4:0 ")


def test_backspace_joining_lines_keeps_later_cursors_in_place() raises:
    var w = win("ab\ncd\nef")
    at(w, 1, 0)
    plus(w, 1, 1)
    plus(w, 2, 1)
    op(w, OP_BACK)
    # (1,0) joins line 1 to line 0; (1,1) removes the "c"; (2,1) removes the "e"
    assert_equal(text(w), "abd\nf")
    assert_equal(cursors(w), "0:2 *1:0 ")        # the first two met and became one


def test_cursors_that_meet_are_merged() raises:
    var w = win("abc")
    at(w, 0, 1)
    plus(w, 0, 2)
    op(w, OP_BACK)
    assert_equal(text(w), "c")
    assert_equal(w.cursor_count(), 1)
    assert_equal(cursors(w), "*0:0 ")
    var w2 = win("ab\ncd")
    at(w2, 0, 1)
    plus(w2, 1, 1)
    w2.multi(OP_VERT, -1, False, False, List[Int]())
    assert_equal(cursors(w2), "*0:1 ")           # both ended on the first line


def test_movement_moves_every_cursor() raises:
    var w = win("hello world\nab\nlonger line")
    at(w, 0, 3)
    plus(w, 1, 1)
    plus(w, 2, 8)
    w.multi(OP_RIGHT, 0, False, False, List[Int]())
    assert_equal(cursors(w), "0:4 1:2 *2:9 ")
    w.multi(OP_END, 0, False, False, List[Int]())
    assert_equal(cursors(w), "0:11 1:2 *2:11 ")
    w.multi(OP_HOME, 0, False, False, List[Int]())
    assert_equal(cursors(w), "0:0 1:0 *2:0 ")
    w.multi(OP_RIGHT, 0, True, True, List[Int]())      # Shift+Ctrl+Right: select a word each
    assert_equal(cursors(w), "0:0-6 1:0-2 *2:0-7 ")
    typ(w, "Z")
    assert_equal(text(w), "Zworld\nZ\nZline")


def test_vertical_move_remembers_each_column() raises:
    var w = win("abcdef\nab\nabcdef\nabcdef")
    at(w, 0, 5)
    plus(w, 2, 3)
    w.multi(OP_VERT, 1, False, False, List[Int]())
    assert_equal(cursors(w), "1:2 *3:3 ")
    w.multi(OP_VERT, 1, False, False, List[Int]())
    assert_equal(cursors(w), "2:5 *3:3 ")              # column 5 came back after the short line


def test_overwrite_mode_and_wide_characters() raises:
    var w = win("日本語\nabc")
    at(w, 0, 1)
    plus(w, 1, 1)
    w.multi(OP_TYPE, 0x1F525, False, False, List[Int]())   # overwrite
    assert_equal(text(w), "日🔥語\na🔥c")
    assert_equal(cursors(w), "0:2 *1:2 ")


def test_edits_far_apart_in_a_long_text() raises:
    var src = String("")
    for i in range(300):
        src += "line " + String(i) + "\n"
    var w = win(src)
    at(w, 0, 0)
    for r in range(1, 300):
        plus(w, r, 0)
    assert_equal(w.cursor_count(), 300)
    typ(w, "> ")
    assert_equal(to_str(w.buf.line(0)), "> line 0")
    assert_equal(to_str(w.buf.line(150)), "> line 150")
    assert_equal(to_str(w.buf.line(299)), "> line 299")
    w.undo()
    assert_equal(to_str(w.buf.all_text()), src)


# ------------------------------------------------------------ adding cursors
def test_add_next_occurrence() raises:
    var w = win("foo bar foo\nfoobar foo")
    at(w, 0, 1)
    assert_true(w.add_next_occurrence())                # first: select the word
    assert_equal(cursors(w), "*0:0-3 ")
    assert_true(w.add_next_occurrence())
    assert_equal(cursors(w), "0:0-3 *0:8-11 ")
    assert_true(w.add_next_occurrence())
    assert_true(w.add_next_occurrence())
    assert_equal(cursors(w), "0:0-3 0:8-11 1:0-3 *1:7-10 ")   # plain text: "foobar" counts
    assert_false(w.add_next_occurrence())               # all taken
    typ(w, "x")
    assert_equal(text(w), "x bar x\nxbar x")
    w.undo()
    assert_equal(text(w), "foo bar foo\nfoobar foo")


def test_add_next_occurrence_wraps_and_is_case_exact() raises:
    var w = win("ab AB ab")
    at(w, 0, 7)
    assert_true(w.add_next_occurrence())
    assert_equal(cursors(w), "*0:6-8 ")
    assert_true(w.add_next_occurrence())
    assert_equal(cursors(w), "*0:0-2 0:6-8 ")
    assert_false(w.add_next_occurrence())
    var blank = win("   ")
    at(blank, 0, 1)
    assert_false(blank.add_next_occurrence())           # no word under the cursor


def test_add_cursor_above_and_below() raises:
    var w = win("abcdef\nab\nabcdef\nabcdef")
    at(w, 1, 2)
    w.want = 4                                         # came from a longer line
    assert_true(w.add_cursor_vert(1))
    assert_equal(cursors(w), "1:2 *2:4 ")
    assert_true(w.add_cursor_vert(1))
    assert_equal(cursors(w), "1:2 2:4 *3:4 ")
    assert_false(w.add_cursor_vert(1))                 # last line
    assert_true(w.add_cursor_vert(-1))
    assert_equal(cursors(w), "*0:4 1:2 2:4 3:4 ")
    assert_false(w.add_cursor_vert(-1))


def test_toggle_cursor() raises:
    var w = win("abc\ndef")
    at(w, 0, 0)
    w.toggle_cursor_at(1, 2)
    assert_equal(cursors(w), "0:0 *1:2 ")
    w.toggle_cursor_at(0, 0)                           # on an existing one: it goes away
    assert_equal(cursors(w), "*1:2 ")
    w.toggle_cursor_at(1, 2)                           # the only cursor stays
    assert_equal(cursors(w), "*1:2 ")
    w.toggle_cursor_at(9, 99)                          # outside the text: clamped
    assert_equal(cursors(w), "1:2 *1:3 ")              # the newest cursor is the main one


def test_other_ways_of_moving_drop_the_extra_cursors() raises:
    var w = win("ab ab\nab")
    at(w, 0, 0)
    plus(w, 1, 0)
    w.goto(1, 1)
    assert_false(w.has_multi())
    plus(w, 0, 0)
    assert_true(w.find_next(decode("ab"), True))
    assert_false(w.has_multi())
    plus(w, 1, 0)
    w.select_all()
    assert_false(w.has_multi())


# ---------------------------------------------------------------- clipboard
def test_copy_joins_selections_and_paste_deals_them_out() raises:
    var w = win("one two\nthree")
    at(w, 0, 0)
    _ = w.add_next_occurrence()                        # "one"
    w.add_cursor(Cur(0, 7, True, 0, 4, 7))             # "two"
    w.add_cursor(Cur(1, 5, True, 1, 0, 5))             # "three"
    assert_equal(to_str(w.selections_text()), "one\ntwo\nthree")
    # three lines for three cursors: one each
    var w2 = win("a\nb\nc")
    at(w2, 0, 1)
    plus(w2, 1, 1)
    plus(w2, 2, 1)
    w2.paste_multi(decode("1\n2\n3"))
    assert_equal(text(w2), "a1\nb2\nc3")
    w2.undo()
    assert_equal(text(w2), "a\nb\nc")
    # any other shape: the whole text at each cursor
    var w3 = win("a\nb")
    at(w3, 0, 1)
    plus(w3, 1, 1)
    w3.paste_multi(decode("xy"))
    assert_equal(text(w3), "axy\nbxy")
    # one cursor: an ordinary paste
    var w4 = win("a")
    at(w4, 0, 1)
    w4.paste_multi(decode("1\n2"))
    assert_equal(text(w4), "a1\n2")


# ------------------------------------------------------------------ drawing
def test_extra_cursors_and_selections_are_drawn() raises:
    var p = theme(0)
    var h = Highlighter()
    var w = win("abcd\nefgh\nij")
    at(w, 0, 1)
    plus(w, 1, 2)
    w.add_cursor(Cur(2, 2, True, 2, 0, 2))             # selection "ij", the main cursor
    w.add_cursor(Cur(0, 4, True, 0, 2, 4))             # selection "cd", now main
    var scr = Screen(40, 12)
    w.draw(scr, p, h, True, False, True, False)
    # text starts at screen column 1, row 1
    assert_equal(scr.bg_at(3, 1), p.sel_bg)            # "c" (main selection)
    assert_equal(scr.bg_at(1, 3), p.sel_bg)            # "i" (selection of another cursor)
    assert_true(scr.bg_at(3, 2) != p.ed_bg, "the extra cursor at 1:2 must stand out")
    assert_equal(scr.fg_at(3, 2), p.ed_bg)
    assert_true(scr.bg_at(2, 1) != p.ed_bg, "the extra cursor at 0:1 must stand out")
    assert_equal(scr.bg_at(1, 2), p.ed_bg)             # ordinary text
    w.collapse()
    w.sel = False
    w.draw(scr, p, h, True, False, True, False)
    assert_equal(scr.bg_at(3, 2), p.ed_bg)
    assert_equal(scr.bg_at(1, 3), p.ed_bg)


# --------------------------------------------------------- column selection
def test_box_select_takes_the_same_columns_on_every_row() raises:
    var w = win("abcdef\nabcdef\nabcdef\nabcdef")
    w.box_select(1, 1, 3, 4)
    assert_equal(cursors(w), "1:1-4 2:1-4 *3:1-4 ")
    assert_equal(to_str(w.selections_text()), "bcd\nbcd\nbcd")
    # dragging the other way: the cursors sit on the left edge
    w.box_select(3, 4, 1, 1)
    assert_equal(cursors(w), "*1:4-1 2:4-1 3:4-1 ")
    assert_true(w.box_active())


def test_box_select_on_ragged_lines() raises:
    var w = win("abcdefgh\nab\n\nabcde")
    w.box_select(0, 3, 3, 6)
    # short lines get a cursor at their end; the last line is cut at its end
    assert_equal(cursors(w), "0:3-6 1:2 2:0 *3:3-5 ")
    typ(w, "X")
    assert_equal(text(w), "abcXgh\nabX\nX\nabcX")
    w.undo()
    assert_equal(text(w), "abcdefgh\nab\n\nabcde")


def test_box_select_uses_screen_columns() raises:
    # a tab (4 columns) and wide characters (2 columns each)
    var w = win("\tabcd\n日本語xy\nabcdefgh")
    w.box_select(0, 4, 2, 6)
    assert_equal(cursors(w), "0:1-3 1:2-3 *2:4-6 ")
    assert_equal(to_str(w.selections_text()), "ab\n語\nef")


def test_zero_width_box_is_a_column_of_cursors() raises:
    var w = win("ab\ncd\nef")
    w.box_select(0, 1, 2, 1)
    assert_equal(cursors(w), "0:1 1:1 *2:1 ")
    typ(w, "|")
    assert_equal(text(w), "a|b\nc|d\ne|f")


def test_box_extend_with_keys() raises:
    var w = win("abcdef\nabcdef\nabcdef")
    at(w, 0, 2)
    w.box_extend(1, 0)
    assert_equal(cursors(w), "0:2 *1:2 ")
    w.box_extend(1, 0)
    w.box_extend(0, 1)
    w.box_extend(0, 1)
    assert_equal(cursors(w), "0:2-4 1:2-4 *2:2-4 ")
    w.box_extend(-1, 0)                                # shrink back up
    assert_equal(cursors(w), "0:2-4 *1:2-4 ")
    w.box_extend(0, -3)                                # past the fixed corner: flips
    assert_equal(cursors(w), "0:2-1 *1:2-1 ")
    w.box_extend(-1, 0)
    assert_equal(cursors(w), "*0:2-1 ")
    assert_false(w.has_multi())
    w.box_extend(-1, 0)                                # top of the text: stays
    assert_equal(cursors(w), "*0:2-1 ")


def test_box_can_reach_past_short_lines() raises:
    var w = win("ab\nabcdefgh")
    at(w, 0, 2)
    w.box_extend(0, 1)
    w.box_extend(0, 1)
    w.box_extend(0, 1)                                 # columns 2..5: beyond the first line
    w.box_extend(1, 0)
    assert_equal(cursors(w), "0:2 *1:2-5 ")


def test_box_starts_from_an_ordinary_selection() raises:
    var w = win("abcdef\nabcdef")
    at(w, 0, 1)
    w.move_right(True, False)
    w.move_right(True, False)                          # "bc" selected
    w.box_extend(1, 0)
    assert_equal(cursors(w), "0:1-3 *1:1-3 ")


def test_a_new_box_starts_after_other_cursor_work() raises:
    var w = win("abcdef\nabcdef\nabcdef")
    w.box_select(0, 1, 1, 3)
    w.multi(OP_RIGHT, 0, False, False, List[Int]())    # ordinary movement ends the box
    assert_false(w.box_active())
    assert_equal(cursors(w), "0:3 *1:3 ")
    w.box_extend(1, 0)                                 # starts again at the main cursor
    assert_equal(cursors(w), "1:3 *2:3 ")
    w.goto(0, 0)
    assert_false(w.box_active())


def test_block_copy_and_paste() raises:
    var w = win("abcd\nefgh\n\n\n")
    w.box_select(0, 1, 1, 3)
    var clip = w.selections_text()
    assert_equal(to_str(clip), "bc\nfg")
    w.box_select(2, 0, 3, 0)                           # two cursors on the empty lines
    w.paste_multi(clip)
    assert_equal(text(w), "abcd\nefgh\nbc\nfg\n")


# ---------------------------------------------------------------------- app
def make(src: String) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode(src))
    return app^


def keys(mut app: App, s: String) raises:
    for c in decode(s):
        app.handle(key_event(c))


def test_keys_and_commands_in_the_app() raises:
    var r = build_registry()
    assert_equal(r.find_key(alt(100)), CM_ADDNEXT)
    assert_equal(r.find_key(KEY_UP | MOD_CTRL | MOD_ALT), CM_CURABOVE)
    assert_equal(r.find_key(KEY_DOWN | MOD_SHIFT | MOD_ALT), CM_CURBELOW)
    var app = make("val = val + val\nother")
    var t = app.top()
    app.handle(key_event(alt(100)))
    app.handle(key_event(alt(100)))
    app.handle(key_event(alt(100)))
    assert_equal(app.wins[t].cursor_count(), 3)
    assert_equal(app.status, "3 cursors")
    keys(app, "total")
    assert_equal(to_str(app.wins[t].buf.line(0)), "total = total + total")
    app.handle(key_event(KEY_BACKSPACE))
    assert_equal(to_str(app.wins[t].buf.line(0)), "tota = tota + tota")
    app.handle(key_event(alt(100)))                    # nothing selected any more: selects a word
    app.handle(key_event(KEY_ESC))                     # Esc: one cursor again
    assert_false(app.wins[t].has_multi())
    keys(app, "!")
    assert_equal(app.wins[t].cursor_count(), 1)
    app.exec(CM_UNDO)
    app.exec(CM_UNDO)
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[t].buf.line(0)), "val = val + val")


def test_cursor_below_then_type_and_cut_paste() raises:
    var app = make("a1\nb2\nc3")
    var t = app.top()
    app.handle(key_event(KEY_DOWN | MOD_CTRL | MOD_ALT))
    app.handle(key_event(KEY_DOWN | MOD_CTRL | MOD_ALT))
    assert_equal(app.wins[t].cursor_count(), 3)
    app.handle(key_event(KEY_RIGHT | MOD_SHIFT))       # select the first letter on each line
    app.exec(CM_CUT)
    assert_equal(to_str(app.wins[t].buf.all_text()), "1\n2\n3")
    assert_equal(to_str(app.clipboard), "a\nb\nc")
    app.handle(key_event(KEY_END))
    app.exec(CM_PASTE)
    assert_equal(to_str(app.wins[t].buf.all_text()), "1a\n2b\n3c")
    assert_equal(app.wins[t].cursor_count(), 3)
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[t].buf.all_text()), "1\n2\n3")


def test_single_cursor_commands_collapse_first() raises:
    var app = make("a\nb\nc")
    var t = app.top()
    app.handle(key_event(KEY_DOWN | MOD_CTRL | MOD_ALT))
    assert_equal(app.wins[t].cursor_count(), 2)
    app.exec(CM_DUPLINE)                               # works on the main cursor's line only
    assert_false(app.wins[t].has_multi())
    assert_equal(to_str(app.wins[t].buf.all_text()), "a\nb\nb\nc")


def test_alt_click_adds_a_cursor_and_a_plain_click_drops_them() raises:
    var app = make("abcdef\nabcdef\nabcdef")
    var t = app.top()
    var wx = app.wins[t].x + 1 + app.wins[t].gut
    var wy = app.wins[t].y + 1
    app.handle(Event(EV_MOUSE, MOD_ALT, wx + 3, wy + 1, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, MOD_ALT, wx + 3, wy + 1, MB_LEFT, False, False, List[Int]()))
    app.handle(Event(EV_MOUSE, MOD_ALT, wx + 5, wy + 2, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, MOD_ALT, wx + 5, wy + 2, MB_LEFT, False, False, List[Int]()))
    assert_equal(app.wins[t].cursor_count(), 3)
    keys(app, "_")
    assert_equal(to_str(app.wins[t].buf.all_text()), "_abcdef\nabc_def\nabcde_f")
    app.handle(Event(EV_MOUSE, 0, wx + 1, wy, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, wx + 1, wy, MB_LEFT, False, False, List[Int]()))
    assert_false(app.wins[t].has_multi())
    assert_equal(app.wins[t].cr, 0)
    assert_equal(app.wins[t].cc, 1)


def test_ctrl_shift_alt_arrows_select_a_column() raises:
    var app = make("abcdef\nabcdef\nabcdef")
    var t = app.top()
    var all = MOD_CTRL | MOD_SHIFT | MOD_ALT
    app.handle(key_event(KEY_RIGHT))
    app.handle(key_event(KEY_DOWN | all))
    app.handle(key_event(KEY_DOWN | all))
    app.handle(key_event(KEY_RIGHT | all))
    app.handle(key_event(KEY_RIGHT | all))
    assert_equal(cursors(app.wins[t]), "0:1-3 1:1-3 *2:1-3 ")
    assert_equal(app.status, "3 lines in the column selection")
    keys(app, "_")
    assert_equal(to_str(app.wins[t].buf.all_text()), "a_def\na_def\na_def")
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[t].buf.all_text()), "abcdef\nabcdef\nabcdef")
    # the same keys parsed from what a terminal sends (modifier parameter 8)
    var term = Terminal()
    var evs = term.feed(str_bytes("\x1b[1;8B"), False)
    assert_equal(len(evs), 1)
    assert_equal(evs[0].key, KEY_DOWN | all)


def test_alt_drag_selects_a_column() raises:
    var app = make("abcdef\nabcdef\nabcdef\nabcdef")
    var t = app.top()
    var wx = app.wins[t].x + 1 + app.wins[t].gut
    var wy = app.wins[t].y + 1
    app.handle(Event(EV_MOUSE, MOD_ALT, wx + 1, wy, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, MOD_ALT, wx + 3, wy + 1, MB_LEFT, True, True, List[Int]()))
    app.handle(Event(EV_MOUSE, MOD_ALT, wx + 4, wy + 2, MB_LEFT, True, True, List[Int]()))
    app.handle(Event(EV_MOUSE, MOD_ALT, wx + 4, wy + 2, MB_LEFT, False, False, List[Int]()))
    assert_equal(cursors(app.wins[t]), "0:1-4 1:1-4 *2:1-4 ")
    app.exec(CM_COPY)
    assert_equal(to_str(app.clipboard), "bcd\nbcd\nbcd")
    # a later plain drag is an ordinary selection again
    app.handle(Event(EV_MOUSE, 0, wx, wy + 3, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, wx + 2, wy + 3, MB_LEFT, True, True, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, wx + 2, wy + 3, MB_LEFT, False, False, List[Int]()))
    assert_equal(cursors(app.wins[t]), "*3:0-2 ")


def test_mouse_modifiers_are_parsed() raises:
    var term = Terminal()
    var evs = term.feed(str_bytes("\x1b[<8;5;3M\x1b[<0;5;3M\x1b[<20;2;2M"), False)
    assert_equal(len(evs), 3)
    assert_equal(evs[0].kind, EV_MOUSE)
    assert_equal(evs[0].button, MB_LEFT)
    assert_equal(evs[0].key, MOD_ALT)
    assert_equal(evs[0].mx, 4)
    assert_equal(evs[1].key, 0)
    assert_equal(evs[2].key, MOD_SHIFT | MOD_CTRL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
