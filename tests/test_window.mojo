"""Tests for editor behaviour in src/window.mojo: typing, indentation, selection, search."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from window import Window, WK_EDITOR, ACT_OTHER
from util import decode, to_str


def win(text: String) -> Window:
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 40, 12, 1)
    w.buf.load(decode(text))
    return w^


def text(w: Window) -> String:
    return to_str(w.buf.all_text())


def typ(mut w: Window, s: String):
    for c in decode(s):
        w.type_char(c, True)


def at(mut w: Window, r: Int, c: Int):
    w.cr = r
    w.cc = c
    w.sel = False
    w.sync_want()
    w.break_group()


def assert_cursor(w: Window, r: Int, c: Int) raises:
    assert_equal(w.cr, r)
    assert_equal(w.cc, c)


# ------------------------------------------------------------------ typing
def test_typing_inserts_and_moves_cursor() raises:
    var w = win("ad")
    at(w, 0, 1)
    typ(w, "bc")
    assert_equal(text(w), "abcd")
    assert_cursor(w, 0, 3)
    assert_true(w.buf.modified)


def test_typed_run_is_one_undo_step() raises:
    var w = win("")
    typ(w, "hello")
    w.undo()
    assert_equal(text(w), "")
    assert_cursor(w, 0, 0)
    w.redo()
    assert_equal(text(w), "hello")
    assert_cursor(w, 0, 5)


def test_moving_the_cursor_starts_a_new_undo_step() raises:
    var w = win("")
    typ(w, "ab")
    w.move_left(False, False)
    typ(w, "X")
    assert_equal(text(w), "aXb")
    w.undo()
    assert_equal(text(w), "ab")
    w.undo()
    assert_equal(text(w), "")


def test_overwrite_mode_replaces_characters() raises:
    var w = win("abc")
    at(w, 0, 1)
    w.type_char(88, False)
    assert_equal(text(w), "aXc")
    assert_cursor(w, 0, 2)
    at(w, 0, 3)
    w.type_char(89, False)   # at end of line it appends
    assert_equal(text(w), "aXcY")


def test_typing_replaces_selection_and_undoes_in_one_step() raises:
    var w = win("hello world")
    at(w, 0, 6)
    w.end(True, False)
    assert_equal(to_str(w.selected_text()), "world")
    typ(w, "X")
    assert_equal(text(w), "hello X")
    w.undo()
    assert_equal(text(w), "hello world")


# --------------------------------------------------------------- newline
def test_newline_keeps_indentation() raises:
    var w = win("    x = 1")
    at(w, 0, 9)
    w.newline(True)
    assert_equal(text(w), "    x = 1\n    ")
    assert_cursor(w, 1, 4)


def test_newline_after_colon_indents_one_level() raises:
    var w = win("    if a:")
    at(w, 0, 9)
    w.newline(True)
    assert_equal(text(w), "    if a:\n        ")
    assert_cursor(w, 1, 8)


def test_newline_after_colon_with_trailing_spaces() raises:
    var w = win("def f():  ")
    at(w, 0, 10)
    w.newline(True)
    assert_cursor(w, 1, 4)


def test_newline_in_tab_indented_file_uses_tabs() raises:
    var w = win("\tif a:\n\tpass")
    assert_true(w.buf.use_tabs)
    at(w, 0, 6)
    w.newline(True)
    assert_equal(text(w), "\tif a:\n\t\t\n\tpass")
    assert_cursor(w, 1, 2)


def test_newline_without_auto_indent() raises:
    var w = win("    x")
    at(w, 0, 5)
    w.newline(False)
    assert_equal(text(w), "    x\n")
    assert_cursor(w, 1, 0)


def test_newline_splits_line_and_carries_tail() raises:
    var w = win("    foo(bar)")
    at(w, 0, 8)
    w.newline(True)
    assert_equal(text(w), "    foo(\n    bar)")
    assert_cursor(w, 1, 4)


def test_newline_inside_indentation_does_not_grow_it() raises:
    var w = win("    x")
    at(w, 0, 2)
    w.newline(True)
    assert_equal(text(w), "  \n    x")
    assert_cursor(w, 1, 2)


# -------------------------------------------------------------- backspace
def test_backspace_deletes_previous_char() raises:
    var w = win("abc")
    at(w, 0, 2)
    w.backspace()
    assert_equal(text(w), "ac")
    assert_cursor(w, 0, 1)


def test_backspace_in_indentation_goes_to_previous_tab_stop() raises:
    var w = win("        x")
    at(w, 0, 8)
    w.backspace()
    assert_equal(text(w), "    x")
    assert_cursor(w, 0, 4)
    var v = win("      x")
    at(v, 0, 6)
    v.backspace()
    assert_equal(text(v), "    x")


def test_backspace_after_text_removes_single_space() raises:
    var w = win("x =    1")
    at(w, 0, 7)
    w.backspace()
    assert_equal(text(w), "x =   1")


def test_backspace_on_tab_removes_one_tab() raises:
    var w = win("\t\tx")
    at(w, 0, 2)
    w.backspace()
    assert_equal(text(w), "\tx")
    assert_cursor(w, 0, 1)


def test_backspace_at_line_start_joins_lines() raises:
    var w = win("ab\ncd")
    at(w, 1, 0)
    w.backspace()
    assert_equal(text(w), "abcd")
    assert_cursor(w, 0, 2)
    at(w, 0, 0)
    w.backspace()   # at the very start: nothing happens
    assert_equal(text(w), "abcd")


def test_backspace_and_delete_remove_selection() raises:
    var w = win("hello world")
    at(w, 0, 0)
    w.move_right(True, True)
    w.backspace()
    assert_equal(text(w), "world")
    var v = win("hello world")
    at(v, 0, 5)
    v.end(True, False)
    v.delete_fwd()
    assert_equal(text(v), "hello")


def test_delete_forward() raises:
    var w = win("ab\ncd")
    at(w, 0, 1)
    w.delete_fwd()
    assert_equal(text(w), "a\ncd")
    w.delete_fwd()   # at end of line: joins the next line
    assert_equal(text(w), "acd")
    at(w, 0, 3)
    w.delete_fwd()   # at end of buffer: nothing
    assert_equal(text(w), "acd")


# -------------------------------------------------------------------- tab
def test_tab_inserts_spaces_to_next_stop() raises:
    var w = win("ab")
    at(w, 0, 2)
    w.tab(False)
    assert_equal(text(w), "ab  ")
    w.tab(False)
    assert_equal(text(w), "ab      ")
    assert_cursor(w, 0, 8)


def test_tab_inserts_tab_char_when_buffer_uses_tabs() raises:
    var w = win("\tx\n\ty")
    at(w, 0, 2)
    w.tab(False)
    assert_equal(text(w), "\tx\t\n\ty")


def test_tab_indents_selected_lines_and_skips_blank_ones() raises:
    var w = win("a\n\nb\nc")
    at(w, 0, 0)
    w.move_vert(2, True)
    w.end(True, False)
    w.tab(False)
    assert_equal(text(w), "    a\n\n    b\nc")
    assert_true(w.has_sel())
    w.tab(True)
    assert_equal(text(w), "a\n\nb\nc")


def test_selection_ending_at_line_start_excludes_that_line() raises:
    var w = win("a\nb\nc")
    at(w, 0, 0)
    w.move_vert(2, True)   # selection ends at (2, 0)
    w.tab(False)
    assert_equal(text(w), "    a\n    b\nc")


def test_shift_tab_outdents_current_line_partially() raises:
    var w = win("  x")
    at(w, 0, 3)
    w.tab(True)
    assert_equal(text(w), "x")
    assert_cursor(w, 0, 1)
    w.tab(True)   # nothing left to remove
    assert_equal(text(w), "x")


def test_block_indent_is_one_undo_step() raises:
    var w = win("a\nb")
    w.select_all()
    w.tab(False)
    assert_equal(text(w), "    a\n    b")
    w.undo()
    assert_equal(text(w), "a\nb")


# ---------------------------------------------------------------- comments
def test_toggle_comment_single_line() raises:
    var w = win("    x = 1")
    at(w, 0, 6)
    w.toggle_comment()
    assert_equal(text(w), "    # x = 1")
    assert_cursor(w, 0, 8)
    w.toggle_comment()
    assert_equal(text(w), "    x = 1")
    assert_cursor(w, 0, 6)


def test_toggle_comment_block_uses_smallest_indent_and_skips_blanks() raises:
    var w = win("def f():\n    a\n\n        b")
    at(w, 1, 0)
    w.move_vert(2, True)
    w.end(True, False)
    w.toggle_comment()
    assert_equal(text(w), "def f():\n    # a\n\n    #     b")
    w.undo()
    assert_equal(text(w), "def f():\n    a\n\n        b")


def test_toggle_comment_uncomments_only_when_all_lines_are_commented() raises:
    var w = win("# a\nb")
    w.select_all()
    w.toggle_comment()
    assert_equal(text(w), "# # a\n# b")
    var v = win("#a\n# b")
    v.select_all()
    v.toggle_comment()
    assert_equal(text(v), "a\nb")


# ------------------------------------------------------------------- lines
def test_duplicate_line() raises:
    var w = win("a\nb")
    at(w, 0, 1)
    w.duplicate_line()
    assert_equal(text(w), "a\na\nb")
    assert_cursor(w, 1, 1)


def test_delete_line_variants() raises:
    var w = win("a\nb\nc")
    at(w, 1, 0)
    var cut = w.delete_line()
    assert_equal(to_str(cut), "b\n")
    assert_equal(text(w), "a\nc")
    at(w, 1, 0)
    _ = w.delete_line()      # last line
    assert_equal(text(w), "a")
    assert_cursor(w, 0, 0)
    _ = w.delete_line()      # only line: becomes empty
    assert_equal(text(w), "")
    assert_equal(w.buf.count(), 1)


# ---------------------------------------------------------------- movement
def test_left_right_wrap_between_lines() raises:
    var w = win("ab\ncd")
    at(w, 0, 2)
    w.move_right(False, False)
    assert_cursor(w, 1, 0)
    w.move_left(False, False)
    assert_cursor(w, 0, 2)
    at(w, 1, 2)
    w.move_right(False, False)   # end of buffer
    assert_cursor(w, 1, 2)
    at(w, 0, 0)
    w.move_left(False, False)    # start of buffer
    assert_cursor(w, 0, 0)


def test_word_movement() raises:
    var w = win("foo.bar(baz)  qux")
    at(w, 0, 0)
    w.move_right(False, True)
    assert_cursor(w, 0, 4)    # start of bar
    w.move_right(False, True)
    assert_cursor(w, 0, 8)    # start of baz
    w.move_right(False, True)
    assert_cursor(w, 0, 14)   # start of qux
    w.move_left(False, True)
    assert_cursor(w, 0, 8)
    w.move_left(False, True)
    assert_cursor(w, 0, 4)


def test_smart_home_toggles_between_indent_and_column_zero() raises:
    var w = win("    abc")
    at(w, 0, 6)
    w.home(False, False)
    assert_cursor(w, 0, 4)
    w.home(False, False)
    assert_cursor(w, 0, 0)
    w.home(False, False)
    assert_cursor(w, 0, 4)


def test_end_and_document_home_end() raises:
    var w = win("ab\ncdef\ng")
    at(w, 1, 1)
    w.end(False, False)
    assert_cursor(w, 1, 4)
    w.home(False, True)
    assert_cursor(w, 0, 0)
    w.end(False, True)
    assert_cursor(w, 2, 1)


def test_vertical_movement_remembers_column() raises:
    var w = win("abcdef\nab\nabcdef")
    at(w, 0, 5)
    w.move_vert(1, False)
    assert_cursor(w, 1, 2)
    w.move_vert(1, False)
    assert_cursor(w, 2, 5)
    w.move_vert(5, False)        # clamped to the last line
    assert_cursor(w, 2, 5)
    w.move_vert(-9, False)
    assert_cursor(w, 0, 5)


# ---------------------------------------------------------- visual columns
def test_visual_columns_with_tabs() raises:
    var w = win("\tab\n\t\tc\nx\ty")
    assert_equal(w.vcol(0, 0), 0)
    assert_equal(w.vcol(0, 1), 4)
    assert_equal(w.vcol(0, 3), 6)
    assert_equal(w.vcol(1, 2), 8)
    assert_equal(w.vcol(2, 2), 4)   # tab after one char fills to column 4
    assert_equal(w.col_at_vcol(0, 4), 1)
    assert_equal(w.col_at_vcol(0, 5), 2)
    assert_equal(w.col_at_vcol(0, 1), 0)   # left part of the tab -> before it
    assert_equal(w.col_at_vcol(0, 3), 1)   # right part of the tab -> after it
    assert_equal(w.col_at_vcol(0, 99), 3)


def test_visual_columns_with_wide_and_combining() raises:
    var w = win("日本x\ncafe\u0301!")
    assert_equal(w.vcol(0, 1), 2)
    assert_equal(w.vcol(0, 2), 4)
    assert_equal(w.vcol(0, 3), 5)
    assert_equal(w.col_at_vcol(0, 0), 0)
    assert_equal(w.col_at_vcol(0, 1), 1)   # right half of 日 -> after it
    assert_equal(w.col_at_vcol(0, 2), 1)
    assert_equal(w.col_at_vcol(0, 4), 2)
    assert_equal(w.vcol(1, 5), 4)          # accent adds no width
    assert_equal(w.vcol(1, 6), 5)


def test_vertical_movement_uses_visual_columns() raises:
    var w = win("\tx\nabcdefg\n日本語")
    at(w, 0, 1)                 # visual column 4
    w.move_vert(1, False)
    assert_cursor(w, 1, 4)
    w.move_vert(1, False)
    assert_cursor(w, 2, 2)      # after 日本 = visual column 4


def test_arrow_keys_step_over_combining_marks() raises:
    var w = win("cafe\u0301!")
    at(w, 0, 3)
    w.move_right(False, False)
    assert_cursor(w, 0, 5)      # past e + accent in one step
    w.move_left(False, False)
    assert_cursor(w, 0, 3)


# --------------------------------------------------------------- selection
def test_shift_movement_selects() raises:
    var w = win("hello")
    at(w, 0, 1)
    w.move_right(True, False)
    w.move_right(True, False)
    assert_true(w.has_sel())
    assert_equal(to_str(w.selected_text()), "el")
    w.move_left(False, False)   # plain arrow collapses to the selection start
    assert_false(w.has_sel())
    assert_cursor(w, 0, 1)


def test_backward_selection_is_normalised() raises:
    var w = win("ab\ncd")
    at(w, 1, 1)
    w.move_vert(-1, True)
    var s = w.sel_range()
    assert_equal(s.r1, 0)
    assert_equal(s.c1, 1)
    assert_equal(s.r2, 1)
    assert_equal(s.c2, 1)
    assert_equal(to_str(w.selected_text()), "b\nc")
    assert_true(w.in_sel(0, 1))
    assert_true(w.in_sel(1, 0))
    assert_false(w.in_sel(1, 1))
    assert_false(w.in_sel(0, 0))


def test_select_all() raises:
    var w = win("ab\ncd")
    w.select_all()
    assert_equal(to_str(w.selected_text()), "ab\ncd")
    w.insert_text(decode("z"), ACT_OTHER)
    assert_equal(text(w), "z")


# ------------------------------------------------------------------ search
def test_find_next_selects_and_advances_and_wraps() raises:
    var w = win("fib a\nb fib\nFIB")
    assert_true(w.find_next(decode("fib"), False))
    assert_cursor(w, 0, 3)
    assert_equal(to_str(w.selected_text()), "fib")
    assert_true(w.find_next(decode("fib"), False))
    assert_cursor(w, 1, 5)
    assert_true(w.find_next(decode("fib"), False))
    assert_cursor(w, 2, 3)          # case-insensitive match
    assert_true(w.find_next(decode("fib"), False))
    assert_cursor(w, 0, 3)          # wrapped


def test_find_case_sensitive_and_missing() raises:
    var w = win("fib\nFIB")
    at(w, 0, 3)
    assert_true(w.find_next(decode("FIB"), True))
    assert_cursor(w, 1, 3)
    at(w, 0, 1)
    assert_false(w.find_next(decode("nope"), False))
    assert_cursor(w, 0, 1)
    assert_false(w.find_next(decode(""), False))


def test_find_overlapping_matches() raises:
    var w = win("aaa")
    assert_true(w.find_next(decode("aa"), False))
    assert_cursor(w, 0, 2)
    assert_true(w.find_next(decode("aa"), False))
    assert_cursor(w, 0, 3)


def test_replace_all_counts_and_is_one_undo() raises:
    var w = win("a b a\na")
    var n = w.replace_all(decode("a"), decode("xy"), False)
    assert_equal(n, 3)
    assert_equal(text(w), "xy b xy\nxy")
    w.undo()
    assert_equal(text(w), "a b a\na")


def test_replace_all_does_not_rescan_replacement() raises:
    var w = win("aa")
    var n = w.replace_all(decode("a"), decode("aa"), False)
    assert_equal(n, 2)
    assert_equal(text(w), "aaaa")


def test_sel_matches() raises:
    var w = win("Foo foo")
    _ = w.find_next(decode("foo"), True)
    assert_true(w.sel_matches(decode("foo"), True))
    assert_false(w.sel_matches(decode("fo"), True))
    assert_false(w.sel_matches(decode("FOO"), True))
    assert_true(w.sel_matches(decode("FOO"), False))


# ---------------------------------------------------------------- brackets
def test_match_bracket() raises:
    var w = win("f(a[1], {b: (c)})\n)")
    at(w, 0, 1)
    var p = w.match_bracket()
    assert_equal(p.r, 0)
    assert_equal(p.c, 16)
    at(w, 0, 17)            # just after the closing paren
    var q = w.match_bracket()
    assert_equal(q.c, 1)
    at(w, 0, 3)
    assert_equal(w.match_bracket().c, 5)
    at(w, 0, 2)             # on a letter with no bracket before it... '(' is before
    assert_equal(w.match_bracket().c, 16)
    at(w, 1, 0)             # unbalanced closer
    assert_equal(w.match_bracket().r, -1)


def test_match_bracket_across_lines() raises:
    var w = win("x = [\n    1,\n]")
    at(w, 0, 4)
    var p = w.match_bracket()
    assert_equal(p.r, 2)
    assert_equal(p.c, 0)
    at(w, 2, 0)
    var q = w.match_bracket()
    assert_equal(q.r, 0)
    assert_equal(q.c, 4)


# ------------------------------------------------------------------- misc
def test_replace_all_text_is_one_undo_and_keeps_line_endings() raises:
    var w = win("a\r\nb\r\n")
    w.replace_all_text(decode("x\ny\n"))
    assert_equal(text(w), "x\ny\n")
    assert_true(w.buf.crlf)
    w.undo()
    assert_equal(text(w), "a\nb\n")


def test_goto_clamps() raises:
    var w = win("ab\ncd")
    w.goto(99, 99)
    assert_cursor(w, 1, 2)
    w.goto(-5, -5)
    assert_cursor(w, 0, 0)


def test_gutter_width() raises:
    var w = win("x")
    assert_equal(w.gutter_for(False), 0)
    assert_equal(w.gutter_for(True), 4)    # 3 digits minimum + 1 space


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
