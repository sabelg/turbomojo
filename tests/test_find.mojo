"""Tests for searching: options (case, whole word, regular expression, in selection),
match counting and highlighting, replacing with capture groups, and the Find/Replace
dialogs with search-as-you-type."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from search import Search, make_search
from window import Window, WK_EDITOR, Range
from window_search import *
from window_draw import *
from screen import Screen
from palette import theme
from highlight import Highlighter
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_FIND, D_REPLACE, D_INFO
from commands import CM_NEW, CM_FIND, CM_REPLACE, CM_AGAIN, CM_UNDO
from term import key_event, KEY_ESC, KEY_ENTER, KEY_BACKSPACE, KEY_TAB, alt, ctrl
from util import decode, to_str


def win(text: String) -> Window:
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 40, 12, 1)
    w.buf.load(decode(text))
    return w^


def text(w: Window) -> String:
    return to_str(w.buf.all_text())


def lit(p: String) -> Search:
    return make_search(decode(p), False, False, False)


def rx(p: String) -> Search:
    return make_search(decode(p), True, False, True)


def where(w: Window) -> String:
    """The selection as "row:from-to"."""
    if not w.has_sel():
        return "none"
    var q = w.sel_range()
    return String(q.r1) + ":" + String(q.c1) + "-" + String(q.c2)


def walk(mut w: Window, s: Search, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        if not w.search_next(s):
            out += "none "
        else:
            out += where(w) + " "
    return out


# ------------------------------------------------------------------ options
def test_matches_do_not_overlap_and_search_wraps() raises:
    var w = win("aaaa")
    assert_equal(walk(w, lit("aa"), 3), "0:0-2 0:2-4 0:0-2 ")
    assert_equal(w.count_matches(lit("aa"), 1000).r1, 2)


def test_case_option() raises:
    var w = win("Fib fib FIB")
    assert_equal(walk(w, lit("fib"), 3), "0:0-3 0:4-7 0:8-11 ")
    var cs = make_search(decode("fib"), True, False, False)
    var w2 = win("Fib fib FIB")
    assert_equal(walk(w2, cs, 2), "0:4-7 0:4-7 ")
    var w3 = win("ÉTÉ été")
    assert_equal(w3.count_matches(lit("été"), 1000).r1, 2)


def test_whole_word_option() raises:
    var w = win("fib fibo fib_x xfib (fib)")
    var s = make_search(decode("fib"), False, True, False)
    assert_equal(walk(w, s, 3), "0:0-3 0:21-24 0:0-3 ")
    assert_equal(w.count_matches(s, 1000).r1, 2)
    # a pattern that is not made of word characters is not held back
    var w2 = win("a += b")
    assert_true(w2.search_next(make_search(decode("+="), False, True, False)))
    assert_equal(where(w2), "0:2-4")


def test_regular_expression_option() raises:
    var w = win("x1 = 10\nyy = 200\nz = a")
    var s = rx("(\\w+) = (\\d+)")
    assert_equal(walk(w, s, 3), "0:0-7 1:0-8 0:0-7 ")
    assert_equal(w.count_matches(s, 1000).r1, 2)
    var ws = make_search(decode("\\w+"), True, True, True)
    var w2 = win("ab cd")
    assert_equal(walk(w2, ws, 2), "0:0-2 0:3-5 ")


def test_regex_case_follows_the_case_option() raises:
    var w = win("Foo foo")
    assert_equal(w.count_matches(make_search(decode("fo+"), True, False, True), 100).r1, 1)
    assert_equal(w.count_matches(make_search(decode("fo+"), False, False, True), 100).r1, 2)


def test_empty_matches_are_skipped() raises:
    var w = win("ab xx")
    var s = rx("x*")
    assert_equal(walk(w, s, 2), "0:3-5 0:3-5 ")
    assert_equal(w.count_matches(s, 1000).r1, 1)
    var w2 = win("abc")
    assert_false(w2.search_next(rx("x*")))
    assert_equal(w2.replace_matches(rx("^"), decode("> ")), 0)


def test_bad_pattern_finds_nothing() raises:
    var w = win("a(b")
    var s = rx("a(b")
    assert_false(s.ok)
    assert_true(s.error.byte_length() > 0)
    assert_false(w.search_next(s))
    assert_equal(w.replace_matches(s, decode("x")), 0)
    assert_equal(w.count_matches(s, 100).r1, 0)
    assert_equal(text(w), "a(b")
    # the same text is fine as plain text
    assert_true(w.search_next(lit("a(b")))
    assert_false(make_search(decode(""), False, False, False).ok)


def test_count_reports_the_selected_match() raises:
    var w = win("ab ab\nab")
    var s = lit("ab")
    var c0 = w.count_matches(s, 1000)
    assert_equal(c0.r1, 3)
    assert_equal(c0.c1, 0)              # nothing selected yet
    _ = w.search_next(s)
    _ = w.search_next(s)
    var c = w.count_matches(s, 1000)
    assert_equal(c.c1, 2)
    _ = w.search_next(s)
    assert_equal(w.count_matches(s, 1000).c1, 3)
    # counting stops at the line limit and says so
    var cut = w.count_matches(s, 1)
    assert_equal(cut.r1, 2)
    assert_equal(cut.r2, 1)


def test_selection_is_a_match_only_when_exact() raises:
    var w = win("abc abc")
    var s = lit("abc")
    _ = w.search_next(s)
    assert_true(w.sel_is_match(s))
    w.cc = 2                            # shrink the selection
    assert_false(w.sel_is_match(s))
    w.sel = False
    assert_false(w.sel_is_match(s))


# ------------------------------------------------------------------ replace
def test_replace_with_capture_groups() raises:
    var w = win("x=1, yy=22\nz=3")
    var n = w.replace_matches(rx("(\\w+)=(\\w+)"), decode("$2=$1 <$0>"))
    assert_equal(n, 3)
    assert_equal(text(w), "1=x <x=1>, 22=yy <yy=22>\n3=z <z=3>")
    w.undo()
    assert_equal(text(w), "x=1, yy=22\nz=3")    # one undo step for everything


def test_plain_replace_does_not_expand_dollars() raises:
    var w = win("a b")
    assert_equal(w.replace_matches(lit("a"), decode("$1\\n")), 1)
    assert_equal(text(w), "$1\\n b")


def test_replace_sees_the_original_line() raises:
    # anchors and word boundaries are judged on the text before any replacement
    var w = win("    x\n  y\nz")
    assert_equal(w.replace_matches(rx("^\\s+"), decode("")), 2)
    assert_equal(text(w), "x\ny\nz")
    var w2 = win("a a")
    assert_equal(w2.replace_matches(lit("a"), decode("aa")), 2)
    assert_equal(text(w2), "aa aa")
    var w3 = win("ab")
    assert_equal(w3.replace_matches(rx("\\b\\w"), decode("")), 1)   # only the first letter
    assert_equal(text(w3), "b")


def test_replace_can_insert_line_breaks() raises:
    var w = win("a, b, c\nd, e")
    assert_equal(w.replace_matches(rx(", "), decode("\\n")), 3)
    assert_equal(text(w), "a\nb\nc\nd\ne")
    w.undo()
    assert_equal(text(w), "a, b, c\nd, e")


def test_replace_current_match() raises:
    var w = win("k1=v1 k2=v2")
    var s = rx("(\\w+)=(\\w+)")
    assert_false(w.replace_current(s, decode("x")))     # nothing selected
    _ = w.search_next(s)
    assert_true(w.replace_current(s, decode("$2:$1")))
    assert_equal(text(w), "v1:k1 k2=v2")
    assert_equal(w.cc, 5)
    assert_false(w.has_sel())
    _ = w.search_next(s)
    assert_equal(where(w), "0:6-11")
    w.undo()
    assert_equal(text(w), "k1=v1 k2=v2")


# ------------------------------------------------------------- in selection
def test_scope_limits_find_count_and_replace() raises:
    var w = win("ab ab ab\nab ab ab\nab ab ab")
    w.scope = Range(0, 3, 1, 5)          # from the second "ab" to the middle of row 1
    w.scope_on = True
    var s = lit("ab")
    assert_equal(w.count_matches(s, 1000).r1, 4)
    assert_equal(walk(w, s, 5), "0:3-5 0:6-8 1:0-2 1:3-5 0:3-5 ")
    assert_equal(w.replace_matches(s, decode("X")), 4)
    assert_equal(text(w), "ab X X\nX X ab\nab ab ab")
    w.undo()
    assert_equal(text(w), "ab ab ab\nab ab ab\nab ab ab")


def test_scope_edge_cuts_a_match_in_two() raises:
    var w = win("abcabc")
    w.scope = Range(0, 1, 0, 5)          # "bcab": no whole "abc" inside
    w.scope_on = True
    assert_false(w.search_next(lit("abc")))
    assert_equal(w.count_matches(lit("abc"), 100).r1, 0)
    assert_equal(w.count_matches(lit("ca"), 100).r1, 1)


def test_scope_follows_single_replacements() raises:
    var w = win("aa aa aa aa")
    w.scope = Range(0, 0, 0, 5)          # the first two
    w.scope_on = True
    var s = lit("aa")
    var n = 0
    while w.search_next(s) and n < 10:
        assert_true(w.replace_current(s, decode("bbbb")))
        n += 1
    assert_equal(n, 2)
    assert_equal(text(w), "bbbb bbbb aa aa")
    assert_equal(w.scope.c2, 9)


# --------------------------------------------------------------- highlights
def test_all_matches_are_highlighted() raises:
    var p = theme(0)
    var h = Highlighter()
    var w = win("ab cd ab\nxx ab")
    var s = lit("ab")
    w.set_highlight(s)
    _ = w.search_next(s)                 # selects the first one
    var scr = Screen(40, 12)
    w.draw(scr, p, h, True, False, True, False)
    # row 0 of the text is screen row 1; text starts at column 1
    assert_equal(scr.bg_at(1, 1), p.sel_bg)          # the selected match
    assert_equal(scr.bg_at(7, 1), p.match_bg)        # another match
    assert_equal(scr.bg_at(8, 1), p.match_bg)
    assert_equal(scr.bg_at(4, 1), p.ed_bg)           # "cd" is not one
    assert_equal(scr.bg_at(4, 2), p.match_bg)        # second line
    assert_equal(scr.bg_at(1, 2), p.ed_bg)
    w.clear_highlight()
    w.sel = False
    w.draw(scr, p, h, True, False, True, False)
    assert_equal(scr.bg_at(7, 1), p.ed_bg)
    assert_equal(scr.bg_at(1, 1), p.ed_bg)


def test_highlights_respect_the_scope() raises:
    var p = theme(0)
    var h = Highlighter()
    var w = win("ab ab ab")
    w.scope = Range(0, 3, 0, 5)
    w.scope_on = True
    w.set_highlight(lit("ab"))
    var scr = Screen(40, 12)
    w.draw(scr, p, h, True, False, True, False)
    assert_equal(scr.bg_at(1, 1), p.ed_bg)
    assert_equal(scr.bg_at(4, 1), p.match_bg)
    assert_equal(scr.bg_at(7, 1), p.ed_bg)


# ------------------------------------------------------------------ dialogs
def make(src: String) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode(src))
    return app^


def keys(mut app: App, s: String) raises:
    for c in decode(s):
        app.handle(key_event(c))


def ed(app: App) -> Int:
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_EDITOR:
            return i
    return -1


def test_search_as_you_type() raises:
    var app = make("alpha beta\nbeta gamma\nalphabet")
    app.exec(CM_FIND)
    assert_equal(app.dlg.kind, D_FIND)
    var e = ed(app)
    assert_equal(app.dlg.note, "")
    keys(app, "b")
    assert_equal(where(app.wins[e]), "0:6-7")
    assert_equal(app.dlg.note, "Match 1 of 3")
    assert_true(app.wins[e].hs_on)
    keys(app, "et")
    assert_equal(where(app.wins[e]), "0:6-9")
    assert_equal(app.dlg.note, "Match 1 of 3")
    keys(app, "a ")
    assert_equal(where(app.wins[e]), "1:0-5")       # "beta " only on the second line
    assert_equal(app.dlg.note, "Match 1 of 1")
    keys(app, "q")
    assert_equal(app.dlg.note, "No matches")
    assert_false(app.wins[e].has_sel())             # back where the search started
    assert_equal(app.wins[e].cr, 0)
    app.handle(key_event(KEY_BACKSPACE))
    assert_equal(where(app.wins[e]), "1:0-5")


def test_search_starts_at_the_cursor_and_cancel_restores_it() raises:
    var app = make("ab\nab\nab")
    var e = ed(app)
    app.wins[e].cr = 1
    app.wins[e].cc = 1
    app.exec(CM_FIND)
    keys(app, "ab")
    assert_equal(where(app.wins[e]), "2:0-2")
    assert_equal(app.dlg.note, "Match 3 of 3")
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    assert_false(app.wins[e].has_sel())
    assert_equal(app.wins[e].cr, 1)
    assert_equal(app.wins[e].cc, 1)
    assert_false(app.wins[e].hs_on)


def test_enter_keeps_the_match_and_search_again_moves_on() raises:
    var app = make("ab\nab\nab")
    var e = ed(app)
    app.exec(CM_FIND)
    keys(app, "ab")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(where(app.wins[e]), "0:0-2")
    assert_true(app.wins[e].hs_on)                  # matches stay highlighted
    assert_equal(app.status, "Match 1 of 3")
    app.exec(CM_AGAIN)
    assert_equal(where(app.wins[e]), "1:0-2")
    assert_equal(app.status, "Match 2 of 3")
    app.handle(key_event(KEY_ESC))                  # Esc in the editor clears the marks
    assert_false(app.wins[e].hs_on)


def test_not_found_is_reported_on_enter() raises:
    var app = make("abc")
    var e = ed(app)
    app.exec(CM_FIND)
    keys(app, "zzz")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_INFO)
    assert_false(app.wins[e].has_sel())


def test_options_are_toggled_with_alt_keys_and_remembered() raises:
    var app = make("Fib fib fibs")
    var e = ed(app)
    app.exec(CM_FIND)
    keys(app, "fib")
    assert_equal(app.dlg.note, "Match 1 of 3")
    app.handle(key_event(alt(105)))                 # Alt+I: case sensitive
    assert_equal(app.dlg.note, "Match 1 of 2")
    assert_equal(where(app.wins[e]), "0:4-7")
    app.handle(key_event(alt(119)))                 # Alt+W: whole words
    assert_equal(app.dlg.note, "Match 1 of 1")
    app.handle(key_event(KEY_ENTER))
    assert_true(app.find_case)
    assert_true(app.find_word)
    assert_false(app.find_regex)
    app.exec(CM_FIND)                               # the next dialog starts the same way
    assert_true(app.dlg.check_vals[0])
    assert_true(app.dlg.check_vals[1])
    assert_equal(to_str(app.dlg.fields[0].text), "fib")
    app.handle(key_event(KEY_ESC))


def test_regex_errors_show_in_the_dialog() raises:
    var app = make("f(x) g(y)")
    var e = ed(app)
    app.exec(CM_FIND)
    app.handle(key_event(alt(120)))                 # Alt+X: regular expression
    keys(app, "\\w\\(")
    assert_equal(where(app.wins[e]), "0:0-2")
    assert_equal(app.dlg.note, "Match 1 of 2")
    keys(app, "(")
    assert_true(app.dlg.note.startswith("Pattern error: missing )"), app.dlg.note)
    assert_false(app.wins[e].has_sel())
    app.handle(key_event(KEY_ENTER))                # cannot accept a broken pattern
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_FIND)
    keys(app, "\\w)")
    assert_equal(app.dlg.note, "Match 1 of 2")
    assert_equal(where(app.wins[e]), "0:0-3")


def test_replace_one_by_one_keeps_the_dialog_open() raises:
    var app = make("a=1 b=2 c=3")
    var e = ed(app)
    app.find_regex = True
    app.exec(CM_REPLACE)
    assert_equal(app.dlg.kind, D_REPLACE)
    keys(app, "(\\w)=(\\d)")
    assert_equal(app.dlg.note, "Match 1 of 3")
    app.handle(key_event(KEY_TAB))
    keys(app, "$2=$1")
    app.handle(key_event(alt(114)))                 # Alt+R: Replace
    assert_equal(to_str(app.wins[e].buf.line(0)), "1=a b=2 c=3")
    assert_equal(app.mode, M_DIALOG)
    assert_equal(where(app.wins[e]), "0:4-7")
    assert_equal(app.dlg.note, "Match 1 of 2")      # "1=a" no longer matches
    app.handle(key_event(alt(114)))
    app.handle(key_event(alt(114)))
    assert_equal(to_str(app.wins[e].buf.line(0)), "1=a 2=b 3=c")
    app.handle(key_event(KEY_ESC))
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[e].buf.line(0)), "1=a 2=b c=3")   # one step per replace


def test_change_all_reports_the_count() raises:
    var app = make("one two one\none")
    var e = ed(app)
    app.exec(CM_REPLACE)
    keys(app, "one")
    app.handle(key_event(KEY_TAB))
    keys(app, "1")
    app.handle(key_event(alt(97)))                  # Alt+A: Change all
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[e].buf.all_text()), "1 two 1\n1")
    assert_equal(app.status, "3 occurrence(s) replaced")
    assert_false(app.wins[e].hs_on)
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[e].buf.all_text()), "one two one\none")


def test_multi_line_selection_turns_on_in_selection() raises:
    var app = make("x x\nx x\nx x\nx x")
    var e = ed(app)
    # select from row 1 column 0 to row 2 column 3
    app.wins[e].sel = True
    app.wins[e].ar = 1
    app.wins[e].ac = 0
    app.wins[e].cr = 2
    app.wins[e].cc = 3
    app.exec(CM_REPLACE)
    assert_true(app.dlg.check_vals[3])
    assert_equal(to_str(app.dlg.fields[0].text), "")   # several lines are not a search text
    keys(app, "x")
    assert_equal(app.dlg.note, "Match 1 of 4")
    assert_equal(where(app.wins[e]), "1:0-1")
    app.handle(key_event(KEY_TAB))
    keys(app, "yy")
    app.handle(key_event(alt(97)))
    assert_equal(to_str(app.wins[e].buf.all_text()), "x x\nyy yy\nyy yy\nx x")
    assert_false(app.wins[e].scope_on)                 # the limit ends with the dialog
    # and without a selection the option explains itself
    app.wins[e].sel = False
    app.exec(CM_FIND)
    app.handle(key_event(alt(115)))                    # Alt+S
    keys(app, "x")
    assert_equal(app.dlg.note, "Nothing is selected")
    app.handle(key_event(KEY_ESC))


def test_single_line_selection_seeds_the_search_text() raises:
    var app = make("foo bar foo")
    var e = ed(app)
    app.wins[e].sel = True
    app.wins[e].ar = 0
    app.wins[e].ac = 4
    app.wins[e].cr = 0
    app.wins[e].cc = 7
    app.exec(CM_FIND)
    assert_equal(to_str(app.dlg.fields[0].text), "bar")
    assert_false(app.dlg.check_vals[3])
    assert_equal(app.dlg.note, "Match 1 of 1")
    assert_equal(where(app.wins[e]), "0:4-7")
    app.handle(key_event(KEY_ESC))
    assert_equal(where(app.wins[e]), "0:4-7")          # the old selection is back


def test_huge_text_searches_on_enter_only() raises:
    var src = String("")
    for i in range(50010):
        src += "row\n"
    src += "needle here\nneedle again\n"
    var app = make(src)
    var e = ed(app)
    app.exec(CM_FIND)
    keys(app, "needle")
    assert_equal(app.dlg.note, "Large text: press Enter to search")
    assert_false(app.wins[e].has_sel())             # nothing was scanned while typing
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(where(app.wins[e]), "50010:0-6")
    app.exec(CM_AGAIN)
    assert_equal(where(app.wins[e]), "50011:0-6")
    # this match lies beyond the lines that are counted: no misleading number
    assert_equal(app.status, "Found (the text is too long to count the matches)")


def test_match_is_scrolled_clear_of_the_dialog() raises:
    var src = String("")
    for i in range(60):
        src += "line " + String(i) + "\n"
    src += "needle\n"
    var app = make(src)
    var e = ed(app)
    app.exec(CM_FIND)
    keys(app, "needle")
    assert_equal(app.wins[e].cr, 60)
    app.draw()
    var row_y = app.wins[e].y + 1 + (app.wins[e].cr - app.wins[e].top)
    assert_true(row_y < app.dlg.dy, "match at screen row " + String(row_y) + ", dialog starts at " + String(app.dlg.dy))
    assert_true(row_y > app.wins[e].y)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.wins[e].top, 0)                   # the view goes back too


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
