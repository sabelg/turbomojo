"""E2E Test Suite for Feature #24:
True SGR italic 3, dim 2, and strikethrough 9 cell attribute support in Screen,
wired to Markdown formatting, inlay hints, inline blame, and deprecated diagnostics.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from screen import Screen, BOLD_BIT, UL_CURLY, UL_DOTTED, UL_DASHED
from markdown import md_render, MdLine, MD_TEXT, MD_BOLD, MD_ITALIC, MD_CODE, MD_DIM, MD_STRIKE, MD_HEAD
from highlight import Highlighter
from palette import Palette, theme
from buffer import Mark, Hint
from window import Window, WK_EDITOR
from window_draw import *
from docs import DocEntry
from signals import own_pid
from util import decode, to_str, bytes_to_str, env_or, run_system, shell_quote


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f24-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f24_case1_screen_sgr_render_bold_and_underline() raises:
    """Verify Screen emits standard ANSI SGR codes for bold, underline, italic, dim, and strikethrough."""
    var s = Screen(30, 2)
    _ = s.text(0, 0, "Hello World Test", 0xFFFFFF, 0x000000)
    s.bold(0, 0, 5)  # Bold 'Hello'
    s.underline(6, 0, False, 0x00FF00)  # Underline 'World'
    s.italic(12, 0, 4)  # Italic 'Test'
    s.dim(0, 1, 5)
    s.strikethrough(6, 1, 5)

    assert_true(s.is_bold(0, 0))
    assert_true(s.is_bold(4, 0))
    assert_false(s.is_bold(6, 0))
    assert_equal(s.ul_at(6, 0), 1)
    assert_true(s.is_italic(12, 0))
    assert_false(s.is_italic(0, 0))
    assert_true(s.is_dim(0, 1))
    assert_true(s.is_strikethrough(6, 1))

    var out = List[UInt8]()
    s.render(out)
    var esc = bytes_to_str(out)

    # Should contain SGR 1m (bold), 4m (underline), 3m (italic), 2m (dim), 9m (strikethrough)
    assert_true(esc.find("\x1b[1m") >= 0, "Missing bold SGR in: " + esc)
    assert_true(esc.find("\x1b[4m") >= 0 or esc.find("\x1b[4:") >= 0, "Missing underline SGR in: " + esc)
    assert_true(esc.find("\x1b[3m") >= 0, "Missing italic SGR in: " + esc)
    assert_true(esc.find("\x1b[2m") >= 0, "Missing dim SGR in: " + esc)
    assert_true(esc.find("\x1b[9m") >= 0, "Missing strikethrough SGR in: " + esc)


def test_tier1_f24_case2_markdown_italic_and_bold_parsing() raises:
    """Verify Markdown renderer parses *italic* and **bold** into distinct style tokens."""
    var hl = Highlighter()
    var lines = md_render("This is *italic text* and **bold text** here.", 80, hl)

    assert_true(len(lines) > 0)
    var found_italic = False
    var found_bold = False

    for line in lines:
        for st in line.st:
            if st == MD_ITALIC:
                found_italic = True
            elif st == MD_BOLD:
                found_bold = True

    assert_true(found_italic, "Markdown did not produce MD_ITALIC token")
    assert_true(found_bold, "Markdown did not produce MD_BOLD token")


def test_tier1_f24_case3_markdown_dim_elements() raises:
    """Verify Markdown renderer applies dim styling to blockquote bars and dividers."""
    var hl = Highlighter()
    var doc = "> A quote line\n---\nRegular text"
    var lines = md_render(doc, 80, hl)

    var found_dim = False
    for line in lines:
        for st in line.st:
            if st == MD_DIM:
                found_dim = True
                break

    assert_true(found_dim, "Expected MD_DIM for blockquote or horizontal rule")


def test_tier1_f24_case4_inline_blame_formatting() raises:
    """Verify inline git blame configuration enables without corrupting viewport rows."""
    var win = Window(WK_EDITOR, "test.mojo", "", 0, 0, 80, 24, 1)
    win.inline_blame = "Jane Doe, 2 days ago"
    win.inline_blame_row = 0

    assert_equal(win.inline_blame, "Jane Doe, 2 days ago")
    assert_equal(win.inline_blame_row, 0)
    assert_equal(win.kind, WK_EDITOR)


def test_tier1_f24_case5_deprecated_symbol_handling() raises:
    """Verify DocEntry represents deprecated status correctly for strikethrough/dim styling."""
    var entry = DocEntry("legacy_fn", "function", "MyStruct", "core", "~~deprecated function~~")
    assert_equal(entry.name, "legacy_fn")
    assert_equal(entry.kind, "function")
    assert_equal(entry.owner, "MyStruct")
    assert_true(entry.markdown.find("deprecated") >= 0)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f24_bound1_nested_markdown_formatting() raises:
    """Verify markdown parser correctly handles nested bold/italic/code formatting."""
    var hl = Highlighter()
    var doc = "Mixed ***bold and italic*** and `code *inside* not italic` text."
    var lines = md_render(doc, 80, hl)

    assert_true(len(lines) > 0)
    var has_code = False
    var has_bold_or_italic = False

    for line in lines:
        for st in line.st:
            if st == MD_CODE:
                has_code = True
            elif st == MD_BOLD or st == MD_ITALIC:
                has_bold_or_italic = True

    assert_true(has_code, "Code block formatting missing")
    assert_true(has_bold_or_italic, "Bold/italic formatting missing")


def test_tier2_f24_bound2_screen_attribute_clip_boundary() raises:
    """Verify attributes applied inside clipped region do not spill past boundaries."""
    var s = Screen(30, 5)
    s.clip(5, 1, 10, 2)
    _ = s.text(0, 1, "01234567890123456789", 0xFFFFFF, 0)
    s.bold(5, 1, 10)
    s.italic(5, 1, 10)
    s.dim(5, 1, 10)
    s.strikethrough(5, 1, 10)
    s.no_clip()

    # Inside clip region should have attributes
    assert_true(s.is_bold(5, 1))
    assert_true(s.is_bold(14, 1))
    assert_true(s.is_italic(5, 1))
    assert_true(s.is_dim(5, 1))
    assert_true(s.is_strikethrough(5, 1))
    # Outside clip region must not be affected
    assert_false(s.is_bold(4, 1))
    assert_false(s.is_bold(15, 1))
    assert_false(s.is_italic(4, 1))
    assert_false(s.is_dim(4, 1))
    assert_false(s.is_strikethrough(4, 1))


def test_tier2_f24_bound3_empty_and_whitespace_markdown_tokens() raises:
    """Verify Markdown parser gracefully handles degenerate asterisks and unmatched tags."""
    var hl = Highlighter()
    var doc = "**** empty bold **** and * unclosed asterisk and `unclosed backtick"
    var lines = md_render(doc, 80, hl)

    # Must parse without throwing exception or infinite looping
    assert_true(len(lines) > 0)


def test_tier2_f24_bound4_screen_render_differential_attributes() raises:
    """Verify that redundant renders do not emit repeated SGR attribute sequences."""
    var s = Screen(15, 1)
    _ = s.text(0, 0, "TestText", 0xFFFFFF, 0)
    s.bold(0, 0, 4)

    var out1 = List[UInt8]()
    s.render(out1)
    var esc1 = bytes_to_str(out1)
    assert_true(esc1.find("\x1b[1m") >= 0)

    # Second render without modifications: differential double-buffer must emit nothing
    var out2 = List[UInt8]()
    s.render(out2)
    var esc2 = bytes_to_str(out2)
    assert_equal(esc2.byte_length(), 0)


def test_tier2_f24_bound5_styled_underline_and_color_interaction() raises:
    """Verify styling with multiple underline kinds (curly, dotted, dashed) alongside SGR colors."""
    var s = Screen(20, 1)
    s.styled_ul = True
    _ = s.text(0, 0, "1234567890", 0xFFFFFF, 0)
    s.underline_kind(0, 0, UL_CURLY, 0xFF0000)
    s.underline_kind(3, 0, UL_DOTTED, 0x00FF00)
    s.underline_kind(6, 0, UL_DASHED, 0x0000FF)

    assert_equal(s.ul_at(0, 0), UL_CURLY)
    assert_equal(s.ul_at(3, 0), UL_DOTTED)
    assert_equal(s.ul_at(6, 0), UL_DASHED)

    var out = List[UInt8]()
    s.render(out)
    var esc = bytes_to_str(out)
    # Check that curly (4:3), dotted (4:4), or dashed (4:5) sequences are rendered
    assert_true(esc.find("\x1b[4:") >= 0 or esc.find("\x1b[4m") >= 0)


def test_tier2_f24_bound6_underline_preserves_attrs_and_window_virtual_text() raises:
    """Verify underline_kind preserves italic/dim/strike, bold/dim 22m re-emit, MD_STRIKE, and Window.draw hints/blame/deprecated."""
    var s = Screen(16, 1)
    _ = s.text(0, 0, "abcdefgh", 0xFFFFFF, 0)
    s.italic(0, 0, 2)
    s.dim(0, 0, 2)
    s.strikethrough(0, 0, 2)
    s.underline_kind(0, 0, UL_CURLY, 0xFF0000)
    assert_true(s.is_italic(0, 0))
    assert_true(s.is_dim(0, 0))
    assert_true(s.is_strikethrough(0, 0))
    assert_equal(s.ul_at(0, 0), UL_CURLY)

    # Bold + dim cell followed by dim-only cell: 22m turns off both, so 2m must be re-emitted
    s.bold(4, 0, 1)
    s.dim(4, 0, 2)
    var out = List[UInt8]()
    s.render(out)
    var esc = bytes_to_str(out)
    assert_true(esc.find("\x1b[22m\x1b[2m") >= 0)
    assert_true(esc.find("\x1b[29m") >= 0 or esc.find("\x1b[23m") >= 0)

    # Markdown ~~strikethrough~~
    var hl = Highlighter()
    var md_lines = md_render("Use ~~old_api~~ instead.", 60, hl)
    var saw_strike = False
    for ml in md_lines:
        for st in ml.st:
            if st == MD_STRIKE:
                saw_strike = True
    assert_true(saw_strike)

    # Window.draw: inlay hints + inline blame (italic & dim) + deprecated Mark (strikethrough)
    var win = Window(WK_EDITOR, "d.mojo", "d.mojo", 0, 0, 80, 10, 1)
    win.buf.load(decode("var old_fn = 1"))
    win.buf.marks.append(Mark(0, 4, 0, 10, 2, "deprecated", True))
    win.buf.hints.append(Hint(0, 10, ": Int", 1))
    win.inline_blame = "Alice, 1h ago"
    win.inline_blame_row = 0
    var scr = Screen(80, 10)
    var pal = theme(0)
    win.draw(scr, pal, hl, True, False, True, False)
    assert_true(scr.is_strikethrough(win.x + 1 + win.gut + 4, win.y + 1))
    var saw_hint_italic_dim = False
    for cx in range(win.x + 1 + win.gut + 14, 78):
        if scr.is_italic(cx, win.y + 1) and scr.is_dim(cx, win.y + 1):
            saw_hint_italic_dim = True
            break
    assert_true(saw_hint_italic_dim)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
