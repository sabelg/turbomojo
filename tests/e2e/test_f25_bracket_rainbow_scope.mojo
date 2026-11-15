"""E2E Test Suite for Feature #25:
Lexer-aware bracket matching skipping strings and comments, active indentation
scope guide for innermost def/struct/if, and optional CVD-safe 4-level rainbow delimiters.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from window import Window, WK_EDITOR
from buffer import TextBuffer, Pos
from vim_motion import match_fwd, match_back, open_of, close_of, indent_end, active_scope_range, ScopeRange
from window_search import *
from window_draw import *
from screen import Screen
from highlight import Highlighter
from palette import Palette, theme, cvd_rainbow_color, CVD_RAINBOW_0, CVD_RAINBOW_1, CVD_RAINBOW_2, CVD_RAINBOW_3
from signals import own_pid
from util import decode, to_str, env_or, run_system, shell_quote


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f25-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f25_case1_forward_bracket_matching() raises:
    """Verify match_fwd finds corresponding closing bracket across lines and skips strings/comments."""
    var buf = TextBuffer()
    buf.load(decode("def foo(\n    a: Int,\n    b: String\n):"))

    # '(' is on line 0 column 7
    var res = match_fwd(buf, 0, 7, 40, 41)  # 40 = '(', 41 = ')'
    assert_equal(res.r, 3)
    assert_equal(res.c, 0)

    # Lexer-aware: skip brackets inside strings and comments
    var buf2 = TextBuffer()
    buf2.load(decode('def foo(a: String = "()", b: Int = 1): # (comment\n    return 42'))
    var res2 = match_fwd(buf2, 0, 7, 40, 41)
    assert_equal(res2.r, 0)
    assert_equal(res2.c, 36)


def test_tier1_f25_case2_backward_bracket_matching() raises:
    """Verify match_back finds opening bracket backwards from closer and skips strings/comments."""
    var buf = TextBuffer()
    buf.load(decode("var x = [\n    1,\n    2\n]"))

    # ']' is on line 3 column 0
    var res = match_back(buf, 3, 0, 91, 93)  # 91 = '[', 93 = ']'
    assert_equal(res.r, 0)
    assert_equal(res.c, 8)

    # Lexer-aware: backward match skipping closer inside string literal
    var buf2 = TextBuffer()
    buf2.load(decode('var x = [ "]", 1 ] # [comment'))
    var res2 = match_back(buf2, 0, 17, 91, 93)
    assert_equal(res2.r, 0)
    assert_equal(res2.c, 8)


def test_tier1_f25_case3_window_match_bracket_method() raises:
    """Verify Window.match_bracket identifies counterpart delimiter for editor cursor."""
    var win = Window(WK_EDITOR, "test.mojo", "", 0, 0, 60, 20, 1)
    win.buf.load(decode("fn calculate() -> Int:\n    return (10 * 5)"))
    win.cr = 1
    win.cc = 11  # Position on '(' in '(10 * 5)'

    var p = win.match_bracket()
    assert_equal(p.r, 1)
    assert_equal(p.c, 18)  # Matches ')' at column 18


def test_tier1_f25_case4_active_indentation_calculation() raises:
    """Verify indent_end computes whitespace prefix columns accurately for active scope."""
    var line_flat = decode("def root():")
    var line_nested1 = decode("    var x = 10")
    var line_nested2 = decode("        var y = 20")

    assert_equal(indent_end(line_flat), 0)
    assert_equal(indent_end(line_nested1), 4)
    assert_equal(indent_end(line_nested2), 8)

    # Active indentation scope guide: innermost def/struct/if
    var buf = TextBuffer()
    buf.load(decode("struct S:\n    def method():\n        if True:\n            x = 10\n            y = 20\n"))
    var scope = active_scope_range(buf, 3)
    assert_equal(scope.r1, 2)
    assert_equal(scope.r2, 4)
    assert_equal(scope.indent, 8)


def test_tier1_f25_case5_bracket_palette_and_contrast() raises:
    """Verify palette defines valid non-zero bracket highlight colors and CVD-safe rainbow delimiters."""
    var p0 = theme(0)
    assert_true(p0.bracket_fg != 0 or p0.bracket_bg != 0)
    assert_true(p0.bracket_fg != p0.bracket_bg)

    var p1 = theme(1)
    assert_true(p1.bracket_fg != 0 or p1.bracket_bg != 0)

    # CVD-safe 4-level rainbow delimiters (Wong palette)
    assert_equal(cvd_rainbow_color(0), CVD_RAINBOW_0)
    assert_equal(cvd_rainbow_color(1), CVD_RAINBOW_1)
    assert_equal(cvd_rainbow_color(2), CVD_RAINBOW_2)
    assert_equal(cvd_rainbow_color(3), CVD_RAINBOW_3)
    assert_equal(cvd_rainbow_color(4), CVD_RAINBOW_0)  # wraps around modulo 4
    assert_equal(p0.rainbow_color(0), CVD_RAINBOW_0)
    assert_equal(p0.rainbow_color(3), CVD_RAINBOW_3)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f25_bound1_unbalanced_and_missing_brackets() raises:
    """Verify unbalanced brackets return Pos(-1, -1) gracefully without raising exceptions."""
    var buf = TextBuffer()
    buf.load(decode("def incomplete(\n    x = 10\n"))

    # Unclosed forward search from '('
    var fwd = match_fwd(buf, 0, 14, 40, 41)
    assert_equal(fwd.r, -1)
    assert_equal(fwd.c, -1)

    # Backward search in text with no opener at all
    var buf_no_open = TextBuffer()
    buf_no_open.load(decode("var x = 10\nvar y = 20\n"))
    var back = match_back(buf_no_open, 1, 5, 40, 41)
    assert_equal(back.r, -1)
    assert_equal(back.c, -1)


def test_tier2_f25_bound2_deeply_nested_bracket_delimiters() raises:
    """Verify deeply nested and interleaved brackets resolve to exact matching pair."""
    var buf = TextBuffer()
    buf.load(decode("a = ([{((42))}])"))

    # Match '{' at 6
    var match_brace = match_fwd(buf, 0, 6, 123, 125)
    assert_equal(match_brace.r, 0)
    assert_equal(match_brace.c, 13)

    # Match '[' at 5
    var match_sq = match_fwd(buf, 0, 5, 91, 93)
    assert_equal(match_sq.r, 0)
    assert_equal(match_sq.c, 14)


def test_tier2_f25_bound3_empty_lines_in_indentation_scope() raises:
    """Verify empty or blank lines return 0 or blank length for indent calculations."""
    var empty_line = decode("")
    var space_line = decode("        ")

    assert_equal(indent_end(empty_line), 0)
    assert_equal(indent_end(space_line), 8)


def test_tier2_f25_bound4_multiline_distance_limit() raises:
    """Verify bracket search behaves predictably and terminates cleanly across line bounds."""
    var buf = TextBuffer()
    var s = String("(\n")
    for _ in range(50):
        s += "    line\n"
    s += ")\n"
    buf.load(decode(s))

    var res = match_fwd(buf, 0, 0, 40, 41)
    assert_equal(res.r, 51)
    assert_equal(res.c, 0)


def test_tier2_f25_bound5_adjacent_and_interleaved_delimiters() raises:
    """Verify adjacent and empty brackets () [] {} match immediately adjacent characters."""
    var buf = TextBuffer()
    buf.load(decode("()[]{}"))

    var p_paren = match_fwd(buf, 0, 0, 40, 41)
    assert_equal(p_paren.r, 0)
    assert_equal(p_paren.c, 1)

    var p_bracket = match_fwd(buf, 0, 2, 91, 93)
    assert_equal(p_bracket.r, 0)
    assert_equal(p_bracket.c, 3)

    var p_brace = match_fwd(buf, 0, 4, 123, 125)
    assert_equal(p_brace.r, 0)
    assert_equal(p_brace.c, 5)


def test_tier2_f25_bound6_window_draw_rainbow_and_active_scope() raises:
    """Verify Window.draw colors code brackets with CVD rainbow colors and highlights active scope guide."""
    var win = Window(WK_EDITOR, "s.mojo", "s.mojo", 0, 0, 70, 12, 1)
    win.buf.load(decode('def outer():\n    if True:\n        var x = ([{1}]) # (ignore)\n'))
    win.indent_guides = True
    win.rainbow_brackets = True
    win.cr = 2
    win.cc = 8  # Not on a bracket so active bracket highlight doesn't override rainbow_fg

    var scr = Screen(70, 12)
    var pal = theme(1)
    var hl = Highlighter()
    win.draw(scr, pal, hl, True, False, True, False)

    var cx0 = win.x + 1 + win.gut
    var yy2 = win.y + 1 + 2
    # Outer scope guide at col 0 uses dim gutter_fg; active innermost scope (`if True:` at col 4) uses frame_act
    assert_equal(scr.fg_at(cx0 + 0, yy2), pal.gutter_fg)
    assert_equal(scr.fg_at(cx0 + 4, yy2), pal.frame_act)

    # Nested brackets `([{1}])` at cols 16, 17, 18 get depth 0, 1, 2 rainbow colors
    assert_equal(scr.fg_at(cx0 + 16, yy2), CVD_RAINBOW_0)
    assert_equal(scr.fg_at(cx0 + 17, yy2), CVD_RAINBOW_1)
    assert_equal(scr.fg_at(cx0 + 18, yy2), CVD_RAINBOW_2)
    assert_equal(scr.fg_at(cx0 + 20, yy2), CVD_RAINBOW_2)
    assert_equal(scr.fg_at(cx0 + 21, yy2), CVD_RAINBOW_1)
    assert_equal(scr.fg_at(cx0 + 22, yy2), CVD_RAINBOW_0)
    # Comment bracket `(` at col 26 is NOT colored with rainbow color
    assert_true(scr.fg_at(cx0 + 26, yy2) != CVD_RAINBOW_0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
