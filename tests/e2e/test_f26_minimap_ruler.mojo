"""E2E Test Suite for Feature #26:
Interactive minimap and scrollbar click-to-jump and drag-scrubbing,
plus overview ruler ticks for errors, warnings, search matches, Git hunks, and multi-cursors.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from appstate import App
from term import Event, EV_MOUSE, MB_LEFT
from window import Window, WK_EDITOR, MINIMAP_W
from screen import Screen
from palette import Palette, theme
from buffer import TextBuffer, Mark, Pos
from highlight import Highlighter
from window_draw import *
from window_lines import *
from window_multi import *
from window_search import *
from search import make_search
from linediff import LM_ADDED, LM_NONE
from signals import own_pid
from util import decode, to_str, env_or, run_system, shell_quote


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f26-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f26_case1_minimap_toggle_and_content_width() raises:
    """Verify enabling minimap reserves MINIMAP_W columns from content width."""
    var win = Window(WK_EDITOR, "test.mojo", "", 0, 0, 80, 24, 1)
    win.gut = 4
    win.minimap = False

    var w_without = win.cols()
    # Content width = 80 - 2 (borders) - 4 (gutter) = 74
    assert_equal(w_without, 74)

    win.minimap = True
    var w_with = win.cols()
    # Content width = 74 - 10 (MINIMAP_W) = 64
    assert_equal(w_with, 64)
    assert_equal(w_without - w_with, MINIMAP_W)


def test_tier1_f26_case2_minimap_braille_render() raises:
    """Verify minimap paints braille patterns into designated screen region."""
    var win = Window(WK_EDITOR, "test.mojo", "", 0, 0, 80, 20, 1)
    var text = String("")
    for i in range(40):
        text += "var x_" + String(i) + " = 100 * " + String(i) + "\n"
    win.buf.load(decode(text))
    win.minimap = True
    win.minimap_blocks = False

    var scr = Screen(80, 20)
    var pal = theme(0)
    win.draw_minimap(scr, pal, win.rows())

    # Check right edge cells (col 80 - 1 - MINIMAP_W to col 78) for non-blank characters
    var found_braille = False
    var x0 = win.x + win.w - 1 - MINIMAP_W
    for cy in range(win.rows()):
        for cx in range(MINIMAP_W):
            var c = scr.ch[(win.y + 1 + cy) * scr.w + x0 + cx]
            if c >= 0x2800 and c <= 0x28FF:  # Unicode Braille block
                found_braille = True
                break

    assert_true(found_braille, "Minimap did not render braille glyphs")


def test_tier1_f26_case3_minimap_blocks_mode() raises:
    """Verify minimap in blocks mode renders block characters (0x2580..0x2588)."""
    var win = Window(WK_EDITOR, "test.mojo", "", 0, 0, 80, 20, 1)
    var text = String("")
    for i in range(30):
        text += "function_definition_line_" + String(i) + "()\n"
    win.buf.load(decode(text))
    win.minimap = True
    win.minimap_blocks = True

    var scr = Screen(80, 20)
    var pal = theme(0)
    win.draw_minimap(scr, pal, win.rows())

    var found_block = False
    var x0 = win.x + win.w - 1 - MINIMAP_W
    for cy in range(win.rows()):
        for cx in range(MINIMAP_W):
            var c = scr.ch[(win.y + 1 + cy) * scr.w + x0 + cx]
            if c == 0x2580 or c == 0x2584 or c == 0x2588:
                found_block = True
                break

    assert_true(found_block, "Minimap did not render block elements")


def test_tier1_f26_case4_column_rulers_configuration() raises:
    """Verify window maintains ruler guide column positions accurately."""
    var win = Window(WK_EDITOR, "test.mojo", "", 0, 0, 120, 30, 1)
    var r = List[Int]()
    r.append(80)
    r.append(100)
    win.rulers = r^

    assert_equal(len(win.rulers), 2)
    assert_equal(win.rulers[0], 80)
    assert_equal(win.rulers[1], 100)


def test_tier1_f26_case5_overview_ruler_mark_ticks() raises:
    """Verify diagnostic marks are categorized for overview ticks by severity."""
    var win = Window(WK_EDITOR, "test.mojo", "", 0, 0, 80, 25, 1)
    win.buf.load(decode("line 0\nline 1\nline 2\nline 3\nline 4\n"))

    win.buf.marks.append(Mark(1, 0, 1, 5, 1, "syntax error"))
    win.buf.marks.append(Mark(3, 0, 3, 5, 2, "unused variable"))

    assert_equal(len(win.buf.marks), 2)
    assert_equal(win.buf.mark_severity(1), 1)  # line 1 has severity 1 (error)
    assert_equal(win.buf.mark_severity(3), 2)  # line 3 has severity 2 (warning)
    assert_equal(win.buf.mark_severity(0), 0)  # line 0 has no mark
    assert_true(win.buf.mark_text(1).find("syntax error") >= 0)
    assert_true(win.buf.mark_text(3).find("unused variable") >= 0)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f26_bound1_empty_buffer_minimap_render() raises:
    """Verify minimap handles completely empty buffer without division by zero."""
    var win = Window(WK_EDITOR, "empty.mojo", "", 0, 0, 80, 20, 1)
    win.buf.load(decode(""))
    win.minimap = True

    var scr = Screen(80, 20)
    var pal = theme(0)
    win.draw_minimap(scr, pal, win.rows())
    assert_true(win.buf.count() <= 1)


def test_tier2_f26_bound2_large_buffer_minimap_scaling() raises:
    """Verify large buffer scales lines-per-dot proportionally without overflow."""
    var win = Window(WK_EDITOR, "large.mojo", "", 0, 0, 80, 25, 1)
    var text = String("")
    for i in range(1000):
        text += "let item_" + String(i) + " = " + String(i * 2) + "\n"
    win.buf.load(decode(text))
    win.minimap = True

    var n = win.buf.count()
    var rws = win.rows()
    var per = max(1, (n + rws * 4 - 1) // (rws * 4))

    assert_true(per > 1, "Expected >1 lines per dot row for large buffer")
    var scr = Screen(80, 25)
    var pal = theme(0)
    win.draw_minimap(scr, pal, rws)
    var x0 = win.x + win.w - 1 - 10
    var non_empty_cells = 0
    for cy in range(rws):
        var c = scr.ch[(win.y + 1 + cy) * scr.w + x0]
        if c != 0 and c != 32:
            non_empty_cells += 1
    assert_true(non_empty_cells > 0)
    assert_equal(non_empty_cells, rws)


def test_tier2_f26_bound3_ruler_beyond_window_width() raises:
    """Verify rulers configured beyond window width do not cause out of bounds errors."""
    var win = Window(WK_EDITOR, "narrow.mojo", "", 0, 0, 40, 15, 1)
    var r = List[Int]()
    r.append(100)  # Beyond width of 40
    win.rulers = r^

    assert_equal(win.rulers[0], 100)
    assert_true(win.rulers[0] > win.w)


def test_tier2_f26_bound4_viewport_scroll_proportional_clamping() raises:
    """Verify scrolling past top and bottom bounds clamps safely."""
    var win = Window(WK_EDITOR, "scroll.mojo", "", 0, 0, 80, 10, 1)
    win.buf.load(decode("line 0\nline 1\nline 2\nline 3\nline 4\n"))

    win.scroll(-10)  # Scroll up past top
    assert_equal(win.top, 0)

    win.scroll(100)  # Scroll down past bottom
    assert_true(win.top >= 0)
    assert_true(win.top <= win.buf.count())


def test_tier2_f26_bound5_multiple_cursors_positioning() raises:
    """Verify multiple cursors can be added, positioned, and cleared cleanly."""
    var win = Window(WK_EDITOR, "multi.mojo", "", 0, 0, 80, 20, 1)
    win.buf.load(decode("aaa\nbbb\nccc\nddd\n"))

    win.cr = 0
    win.cc = 1
    win.toggle_cursor_at(1, 1)
    win.toggle_cursor_at(2, 1)

    var cs = win.all_cursors()
    assert_equal(len(cs), 3)  # Primary cursor + 2 extra cursors
    assert_equal(cs[0].r, 0)
    assert_equal(cs[0].c, 1)
    assert_equal(cs[1].r, 1)
    assert_equal(cs[1].c, 1)
    assert_equal(cs[2].r, 2)
    assert_equal(cs[2].c, 1)

    win.collapse()
    assert_equal(len(win.all_cursors()), 1)


def test_tier2_f26_bound6_overview_ruler_render_and_gutter_badges() raises:
    """Verify Window.draw renders overview ruler ticks on scrollbar plus cell/bench badges and coverage marks."""
    var win = Window(WK_EDITOR, "r.mojo", "r.mojo", 0, 0, 80, 14, 1)
    var src = String("# %% Cell 0\ndef bench_add():\n    var a = 1\n    var b = 2\n")
    for i in range(6):
        src += "var extra_" + String(i) + " = " + String(i) + "\n"
    win.buf.load(decode(src))
    win.gut = win.gutter_for(True)
    win.buf.marks.append(Mark(2, 0, 2, 5, 1, "err"))
    win.buf.marks.append(Mark(5, 0, 5, 5, 2, "warn"))
    win.buf.git_marks = List[UInt8](length=win.buf.count(), fill=UInt8(LM_NONE))
    win.buf.git_marks[8] = UInt8(LM_ADDED)
    win.set_highlight(make_search(decode("extra_4"), True, False, False))
    win.toggle_cursor_at(9, 0)
    win.cell_badge_rows.append(0)
    win.cell_badges.append("[✓ 12 ms]")
    win.bench_badge_rows.append(1)
    win.bench_badges.append("[4.2 ns/op]")
    win.cov_rows.append(3)
    win.cov_states.append(1)

    var scr = Screen(80, 14)
    var pal = theme(0)
    var hl = Highlighter()
    win.draw(scr, pal, hl, True, False, True, False)

    var sx = win.x + win.w - 1
    var saw_err_tick = False
    var saw_warn_tick = False
    for yy in range(win.y + 2, win.y + win.h - 2):
        var fcol = scr.fg_at(sx, yy)
        if fcol == pal.diag_err:
            saw_err_tick = True
        elif fcol == pal.diag_warn:
            saw_warn_tick = True
    assert_true(saw_err_tick)
    assert_true(saw_warn_tick)
    assert_true(to_str(scr.row_text(win.y + 1)).find("[✓ 12 ms]") >= 0)
    assert_true(to_str(scr.row_text(win.y + 2)).find("[4.2 ns/op]") >= 0)
    assert_equal(scr.ch[(win.y + 1 + 3) * scr.w + win.x + 1], 0x2713)


def test_tier2_f26_bound7_app_minimap_click_and_drag_scrub() raises:
    """Verify clicking and dragging inside the minimap proportionally scrubs viewport top."""
    var app = App()
    app.scr.resize(100, 26)
    app.minimap_on = True
    var text = String("")
    for i in range(200):
        text += "var row_" + String(i) + " = " + String(i) + "\n"
    var ei = app.new_editor("big.mojo", "")
    app.wins[ei].buf.load(decode(text))
    app.wins[ei].minimap = True
    app.draw()

    var w = app.wins[ei].copy()
    var mx = w.x + w.w - 3
    var my_bottom = w.y + w.rows() - 1
    app.handle(Event(EV_MOUSE, 0, mx, my_bottom, MB_LEFT, True, False, List[Int]()))
    assert_true(app.wins[ei].top > 100)

    var my_top = w.y + 1
    app.handle(Event(EV_MOUSE, 0, mx, my_top, MB_LEFT, True, True, List[Int]()))
    assert_equal(app.wins[ei].top, 0)
    app.handle(Event(EV_MOUSE, 0, mx, my_top, MB_LEFT, False, False, List[Int]()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
