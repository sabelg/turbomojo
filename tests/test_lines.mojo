"""Tests for the Text menu operations (move, join, sort lines, case), auto-closing pairs,
rulers and the trim-on-save setting."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from window import Window, WK_EDITOR
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from screen import Screen
from palette import theme
from highlight import Highlighter
from config import load_settings
from app import *
from appstate import App
from commands import (
    CM_NEW, CM_LINEUP, CM_LINEDOWN, CM_JOIN, CM_SORT, CM_UPPER, CM_LOWER, CM_UNDO, CM_SAVE, build_registry,
)
from term import key_event, alt, KEY_UP, KEY_DOWN, KEY_BACKSPACE, KEY_RIGHT, MOD_ALT, MOD_SHIFT
from signals import own_pid
from util import decode, to_str, env_or, run_system, read_file, bytes_to_str


def win(text: String) -> Window:
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 40, 12, 1)
    w.buf.load(decode(text))
    w.auto_pairs = True
    return w^


def text(w: Window) -> String:
    return to_str(w.buf.all_text())


def at(mut w: Window, r: Int, c: Int):
    w.cr = r
    w.cc = c
    w.sel = False
    w.sync_want()
    w.break_group()


def select(mut w: Window, r1: Int, c1: Int, r2: Int, c2: Int):
    w.sel = True
    w.ar = r1
    w.ac = c1
    w.cr = r2
    w.cc = c2


def typ(mut w: Window, s: String):
    for c in decode(s):
        w.multi(OP_TYPE, c, True, False, List[Int]())


# --------------------------------------------------------------- move lines
def test_move_one_line() raises:
    var w = win("a\nb\nc")
    at(w, 1, 1)
    assert_true(w.move_lines(-1))
    assert_equal(text(w), "b\na\nc")
    assert_equal(w.cr, 0)
    assert_equal(w.cc, 1)
    assert_false(w.move_lines(-1))                     # already at the top
    assert_true(w.move_lines(1))
    assert_true(w.move_lines(1))
    assert_equal(text(w), "a\nc\nb")
    assert_equal(w.cr, 2)
    assert_false(w.move_lines(1))
    w.undo()
    assert_equal(text(w), "a\nb\nc")                   # one step back per move


def test_move_selected_lines_keeps_the_selection() raises:
    var w = win("0\n1\n2\n3\n4")
    select(w, 1, 0, 2, 1)
    assert_true(w.move_lines(1))
    assert_equal(text(w), "0\n3\n1\n2\n4")
    assert_equal(to_str(w.selected_text()), "1\n2")
    assert_true(w.move_lines(-1))
    assert_true(w.move_lines(-1))
    assert_equal(text(w), "1\n2\n0\n3\n4")
    assert_equal(to_str(w.selected_text()), "1\n2")
    # a selection that ends at the start of a line does not take that line along
    select(w, 0, 0, 1, 0)
    assert_true(w.move_lines(1))
    assert_equal(text(w), "2\n1\n0\n3\n4")


def test_move_line_with_final_newline_and_unicode() raises:
    var w = win("日本\nab\n")
    at(w, 0, 0)
    assert_true(w.move_lines(1))
    assert_equal(text(w), "ab\n日本\n")
    assert_true(w.move_lines(1))                       # below the last real line: the empty one
    assert_equal(text(w), "ab\n\n日本")


# --------------------------------------------------------------- join lines
def test_join_removes_the_break_and_the_indentation() raises:
    var w = win("foo(a,\n        b,   \n    c)")
    at(w, 0, 2)
    assert_true(w.join_lines())
    assert_equal(text(w), "foo(a, b,   \n    c)")
    assert_equal(w.cc, 6)                              # at the place of the join
    assert_true(w.join_lines())
    assert_equal(text(w), "foo(a, b, c)")
    assert_false(w.join_lines())                       # last line
    w.undo()
    assert_equal(text(w), "foo(a, b,   \n    c)")


def test_join_with_empty_lines_adds_no_blank() raises:
    var w = win("a\n\nb\n   ")
    at(w, 0, 0)
    assert_true(w.join_lines())
    assert_equal(text(w), "a\nb\n   ")
    at(w, 1, 0)
    assert_true(w.join_lines())
    assert_equal(text(w), "a\nb")
    var w2 = win("\nx")
    assert_true(w2.join_lines())
    assert_equal(text(w2), "x")


def test_join_all_selected_lines_is_one_undo() raises:
    var w = win("a\n  b\n  c\nd")
    select(w, 0, 0, 2, 1)
    assert_true(w.join_lines())
    assert_equal(text(w), "a b c\nd")
    w.undo()
    assert_equal(text(w), "a\n  b\n  c\nd")


# --------------------------------------------------------------- sort lines
def test_sort_whole_text_keeps_the_final_newline() raises:
    var w = win("pear\napple\nfig\n")
    assert_equal(w.sort_lines(), 3)
    assert_equal(text(w), "apple\nfig\npear\n")
    assert_equal(w.sort_lines(), 0)                    # already sorted: nothing recorded
    w.undo()
    assert_equal(text(w), "pear\napple\nfig\n")


def test_sort_only_the_selected_lines() raises:
    var w = win("z\nc\nb\na\ny")
    select(w, 1, 0, 3, 1)
    assert_equal(w.sort_lines(), 3)
    assert_equal(text(w), "z\na\nb\nc\ny")


def test_sort_order_and_stability() raises:
    var w = win("b\nB\na\nab\n\nA\n10\n9\né")
    assert_equal(w.sort_lines(), 9)
    # by character code: empty, digits, capitals, small letters, then beyond ASCII
    assert_equal(text(w), "\n10\n9\nA\nB\na\nab\nb\né")
    var many = String("")
    for i in range(500):
        many += String((i * 7919) % 1000) + "\n"
    var w2 = win(many)
    _ = w2.sort_lines()
    for r in range(1, 500):
        assert_false(cps_less(w2.buf.line(r), w2.buf.line(r - 1)), "out of order at " + String(r))
    assert_equal(w2.buf.count(), 501)


# --------------------------------------------------------------------- case
def test_case_of_selection_and_word() raises:
    var w = win("hello World été")
    select(w, 0, 0, 0, 11)
    assert_true(w.change_case(True))
    assert_equal(text(w), "HELLO WORLD été")
    assert_equal(to_str(w.selected_text()), "HELLO WORLD")
    assert_false(w.change_case(True))                  # nothing left to change
    assert_true(w.change_case(False))
    assert_equal(text(w), "hello world été")
    at(w, 0, 13)                                       # inside "été": the word at the cursor
    assert_true(w.change_case(True))
    assert_equal(text(w), "hello world ÉTÉ")
    w.undo()
    assert_equal(text(w), "hello world été")
    at(w, 0, 5)
    w.cc = 5
    var blank = win("a  b")
    at(blank, 0, 2)
    assert_false(blank.change_case(True))              # no word there


def test_case_across_lines() raises:
    var w = win("ab\ncd\nef")
    select(w, 0, 1, 2, 1)
    assert_true(w.change_case(True))
    assert_equal(text(w), "aB\nCD\nEf")


# -------------------------------------------------------------------- pairs
def test_opening_bracket_inserts_its_partner() raises:
    var w = win("")
    typ(w, "f(")
    assert_equal(text(w), "f()")
    assert_equal(w.cc, 2)
    typ(w, "x[")
    assert_equal(text(w), "f(x[])")
    typ(w, "1")
    typ(w, "]")                                        # steps over the one that is there
    assert_equal(text(w), "f(x[1])")
    assert_equal(w.cc, 6)
    typ(w, ")")
    assert_equal(text(w), "f(x[1])")
    assert_equal(w.cc, 7)
    typ(w, " {")
    assert_equal(text(w), "f(x[1]) {}")


def test_no_partner_in_front_of_text() raises:
    var w = win("name")
    at(w, 0, 0)
    typ(w, "(")
    assert_equal(text(w), "(name")
    typ(w, "\"")
    assert_equal(text(w), "(\"name")


def test_missing_closer_is_typed_not_stepped_over() raises:
    var w = win("f(g(x)")
    at(w, 0, 5)                                        # before the only ")"; one is missing
    typ(w, ")")
    assert_equal(text(w), "f(g(x))")
    var w2 = win("f(x)")
    at(w2, 0, 3)                                       # balanced: step over
    typ(w2, ")")
    assert_equal(text(w2), "f(x)")
    assert_equal(w2.cc, 4)


def test_quotes() raises:
    var w = win("")
    typ(w, "s = \"")
    assert_equal(text(w), "s = \"\"")
    typ(w, "hi\"")
    assert_equal(text(w), "s = \"hi\"")
    assert_equal(w.cc, 8)
    # an apostrophe inside a word stays single
    var w2 = win("")
    typ(w2, "don't")
    assert_equal(text(w2), "don't")
    # three quotes in a row open a docstring without piling up closers
    var w3 = win("")
    typ(w3, "\"\"\"")
    assert_equal(text(w3), "\"\"\"")
    assert_equal(w3.cc, 3)


def test_backspace_removes_an_empty_pair() raises:
    var w = win("")
    typ(w, "a(")
    w.multi(OP_BACK, 0, False, False, List[Int]())
    assert_equal(text(w), "a")
    typ(w, "[x")
    w.multi(OP_BACK, 0, False, False, List[Int]())
    assert_equal(text(w), "a[]")
    w.multi(OP_BACK, 0, False, False, List[Int]())
    assert_equal(text(w), "a")
    var w2 = win("(x)")
    at(w2, 0, 1)
    w2.multi(OP_BACK, 0, False, False, List[Int]())    # not empty: only the "(" goes
    assert_equal(text(w2), "x)")


def test_typing_a_bracket_wraps_the_selection() raises:
    var w = win("call arg end")
    select(w, 0, 5, 0, 8)
    typ(w, "(")
    assert_equal(text(w), "call (arg) end")
    assert_equal(to_str(w.selected_text()), "arg")
    typ(w, "\"")
    assert_equal(text(w), "call (\"arg\") end")
    w.undo()
    assert_equal(text(w), "call (arg) end")
    w.undo()
    assert_equal(text(w), "call arg end")
    # an ordinary character replaces the selection as always
    select(w, 0, 5, 0, 8)
    typ(w, "x")
    assert_equal(text(w), "call x end")


def test_pairs_can_be_switched_off_and_overwrite_mode_has_none() raises:
    var w = win("")
    w.auto_pairs = False
    typ(w, "f(\"")
    assert_equal(text(w), "f(\"")
    var w2 = win("abc")
    at(w2, 0, 0)
    w2.multi(OP_TYPE, 40, False, False, List[Int]())   # overwrite mode
    assert_equal(text(w2), "(bc")


def test_pairs_with_several_cursors() raises:
    var w = win("a\nb")
    at(w, 0, 1)
    w.add_cursor(Cur(1, 1, False, 1, 1, 1))
    typ(w, "(x")
    assert_equal(text(w), "a(x)\nb(x)")
    typ(w, ")")
    assert_equal(text(w), "a(x)\nb(x)")
    w.undo()
    assert_equal(text(w), "a\nb")                      # the typing run is one step


# ------------------------------------------------------------------- rulers
def test_rulers_are_drawn_where_the_cell_is_free() raises:
    var p = theme(0)
    var w = win("0123456789abcdef\nshort\n")
    w.rulers.append(8)
    var scr = Screen(40, 12)
    w.draw(scr, p, Highlighter(), False, False, True, False)
    # text starts at screen column 1; the guide is after 8 characters: column 9
    assert_equal(scr.bg_at(9, 1), p.ruler_bg)
    assert_equal(scr.bg_at(9, 2), p.ruler_bg)          # also past the end of a short line
    assert_equal(scr.bg_at(9, 5), p.ed_bg)             # not below the text
    assert_equal(scr.bg_at(8, 1), p.ed_bg)
    assert_equal(scr.bg_at(10, 1), p.ed_bg)
    select(w, 0, 0, 0, 12)
    w.draw(scr, p, Highlighter(), False, False, True, False)
    assert_equal(scr.bg_at(9, 1), p.sel_bg)            # the selection wins
    w.sel = False
    w.left = 4                                         # scrolled sideways: the guide moves along
    w.draw(scr, p, Highlighter(), False, False, True, False)
    assert_equal(scr.bg_at(5, 1), p.ruler_bg)
    assert_equal(scr.bg_at(9, 1), p.ed_bg)


def test_settings() raises:
    var d = load_settings("", "")
    assert_true(d.auto_pairs)
    assert_false(d.trim_trailing)
    assert_equal(len(d.rulers), 0)
    var s = load_settings("[editor]\nauto_pairs = false\ntrim_trailing_whitespace = true\nrulers = [80, 100]\n", "")
    assert_false(s.auto_pairs)
    assert_true(s.trim_trailing)
    assert_equal(len(s.rulers), 2)
    assert_equal(s.rulers[1], 100)
    assert_equal(len(s.warnings), 0)
    var one = load_settings("[editor]\nrulers = 72\n", "")
    assert_equal(len(one.rulers), 1)
    var bad = load_settings("[editor]\nrulers = [80, \"wide\"]\n", "")
    assert_equal(len(bad.rulers), 0)
    assert_equal(len(bad.warnings), 1)
    var bad2 = load_settings("[editor]\nrulers = [0]\n", "")
    assert_equal(len(bad2.warnings), 1)


# ---------------------------------------------------------------------- app
def make(src: String) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode(src))
    return app^


def test_text_menu_commands_and_keys() raises:
    var r = build_registry()
    assert_equal(r.find_key(KEY_UP | MOD_ALT), CM_LINEUP)
    assert_equal(r.find_key(KEY_DOWN | MOD_ALT), CM_LINEDOWN)
    assert_equal(r.find_key(alt(106)), CM_JOIN)
    assert_equal(r.find_key(alt(117)), CM_UPPER)
    assert_equal(r.find_key(alt(108)), CM_LOWER)
    var app = make("b\na\nc d")
    var t = app.top()
    app.handle(key_event(KEY_DOWN | MOD_ALT))
    assert_equal(to_str(app.wins[t].buf.all_text()), "a\nb\nc d")
    app.exec(CM_SORT)
    assert_equal(app.status, "Already in order")
    app.handle(key_event(KEY_UP | MOD_ALT))
    app.exec(CM_SORT)
    assert_equal(app.status, "3 lines sorted")
    app.wins[t].goto(2, 0)
    app.handle(key_event(alt(117)))
    assert_equal(to_str(app.wins[t].buf.line(2)), "C d")
    app.handle(key_event(alt(106)))
    assert_equal(app.status, "No line to join")
    app.wins[t].goto(0, 0)
    app.handle(key_event(alt(106)))
    assert_equal(to_str(app.wins[t].buf.all_text()), "a b\nC d")


def test_typing_in_the_editor_closes_pairs_by_default() raises:
    var app = make("")
    var t = app.top()
    for c in decode("print(\"hi"):
        app.handle(key_event(c))
    assert_equal(to_str(app.wins[t].buf.line(0)), "print(\"hi\")")
    app.auto_pairs = False
    app.draw()                                         # settings reach the windows when drawing
    app.wins[t].goto(0, 11)
    for c in decode(" (["):
        app.handle(key_event(c))
    assert_equal(to_str(app.wins[t].buf.line(0)), "print(\"hi\") ([")


def test_trim_on_save_setting() raises:
    var dir = env_or("TMPDIR", "/tmp") + "/turbomojo-trimtest-" + String(own_pid())
    _ = run_system("rm -rf '" + dir + "' && mkdir -p '" + dir + "'")
    with open(dir + "/a.txt", "w") as f:
        f.write("one   \ntwo\t\nthree\n")
    var app = App()
    app.scr.resize(80, 25)
    app.trim_trailing = True
    app.open_path(dir + "/a.txt")
    var t = app.top()
    app.wins[t].goto(2, 5)
    app.wins[t].type_char(33, True)
    app.exec(CM_SAVE)
    assert_equal(bytes_to_str(read_file(dir + "/a.txt")), "one\ntwo\nthree!\n")
    # .editorconfig decides when it says something about the file
    with open(dir + "/.editorconfig", "w") as f:
        f.write("root = true\n[*.md]\ntrim_trailing_whitespace = false\n")
    with open(dir + "/b.md", "w") as f:
        f.write("hard break  \n")
    app.open_path(dir + "/b.md")
    var t2 = app.top()
    app.wins[t2].goto(0, 0)
    app.wins[t2].type_char(35, True)
    app.exec(CM_SAVE)
    assert_equal(bytes_to_str(read_file(dir + "/b.md")), "#hard break  \n")
    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
