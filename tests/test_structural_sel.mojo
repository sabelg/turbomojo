"""Tests for structural expand/shrink selection, multi-cursor skip, and indent scope guides."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from window import Window, WK_EDITOR
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from screen import Screen
from palette import theme
from highlight import Highlighter
from config import load_settings
from util import decode, to_str


def test_expand_and_shrink_selection() raises:
    var w = Window(WK_EDITOR, "demo.mojo", "", 0, 0, 80, 24, 1)
    var code = (
        "def compute(x: Int) -> Int:\n"
        "    if x > 0:\n"
        "        var msg = call_fn(\"hello world\")\n"
        "        return len(msg)\n"
        "    return 0\n"
    )
    w.buf.load(decode(code))
    # Put cursor on 'hello' inside "hello world" on row 2:
    # `        var msg = call_fn("hello world")` -> 'h' is at col 27, cursor at col 29
    w.goto(2, 29)
    assert_false(w.has_sel())

    # 1. Word: "hello"
    assert_true(w.expand_selection())
    assert_equal(to_str(w.selected_text()), "hello")

    # 2. Inner string: "hello world" (without quotes)
    assert_true(w.expand_selection())
    assert_equal(to_str(w.selected_text()), "hello world")

    # 3. Outer string: "\"hello world\""
    assert_true(w.expand_selection())
    assert_equal(to_str(w.selected_text()), "\"hello world\"")

    # 4. Outer parens: "(\"hello world\")"
    assert_true(w.expand_selection())
    assert_equal(to_str(w.selected_text()), "(\"hello world\")")

    # Keep expanding up to enclosing `if` block, `def` block, and full buffer
    var steps = 4
    while w.expand_selection() and steps < 16:
        steps += 1
    assert_equal(to_str(w.selected_text()), code)

    # Shrink all the way back to the original zero-width cursor at (2, 29)
    for _ in range(steps):
        assert_true(w.shrink_selection())
    assert_false(w.has_sel())
    assert_equal(w.cr, 2)
    assert_equal(w.cc, 29)


def test_skip_next_occurrence() raises:
    var w = Window(WK_EDITOR, "multi.mojo", "", 0, 0, 80, 20, 1)
    w.buf.load(decode("alpha beta\nalpha gamma\nalpha delta\n"))
    w.goto(0, 2)

    # Select first "alpha" at row 0
    assert_true(w.add_next_occurrence())
    assert_equal(w.cursor_count(), 1)
    assert_equal(w.cr, 0)

    # Add second cursor on row 1
    assert_true(w.add_next_occurrence())
    assert_equal(w.cursor_count(), 2)
    assert_equal(w.cr, 1)

    # Skip row 1 so the second cursor moves to row 2 while keeping row 0!
    assert_true(w.skip_next_occurrence())
    assert_equal(w.cursor_count(), 2)
    assert_equal(w.cr, 2)
    assert_equal(w.extra[0].r, 0)


def test_indent_guides_render_and_setting() raises:
    var s = load_settings("[editor]\nindent_guides = true\n", "")
    assert_true(s.indent_guides)
    assert_equal(len(s.warnings), 0)

    var w = Window(WK_EDITOR, "guides.mojo", "", 0, 0, 50, 12, 1)
    w.indent_guides = True
    w.buf.indent_size = 4
    w.buf.load(decode("def outer():\n    if True:\n\n        pass\n"))
    var scr = Screen(50, 12)
    var pal = theme(0)
    var hl = Highlighter()
    w.draw(scr, pal, hl, True, False, True, False)

    # Row 0 (`def outer():`, y=1): no guide at col 0 (x=1)
    assert_equal(scr.ch[1 * scr.w + 1], 100)  # 'd'
    # Row 1 (`    if True:`, y=2): guide 0x2506 (`┆`) at col 0 (x=1)
    assert_equal(scr.ch[2 * scr.w + 1], 0x2506)
    # Row 2 (blank line inside `if True:`, y=3): interpolated guides at col 0 (x=1) and col 4 (x=5)
    assert_equal(scr.ch[3 * scr.w + 1], 0x2506)
    assert_equal(scr.ch[3 * scr.w + 5], 0x2506)
    # Row 3 (`        pass`, y=4): guides at col 0 (x=1) and col 4 (x=5)
    assert_equal(scr.ch[4 * scr.w + 1], 0x2506)
    assert_equal(scr.ch[4 * scr.w + 5], 0x2506)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
