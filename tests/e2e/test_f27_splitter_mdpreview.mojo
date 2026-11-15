"""E2E Test Suite for Feature #27:
Tiled splitter mouse drag resizing, rich tab bar disambiguating duplicate filenames,
close buttons, middle-click close, pinned tabs, and scroll-synchronized side-by-side Markdown preview WK_MDPREVIEW.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from appstate import App
from commands import CM_PIN_TAB, CM_CLOSE, CM_MD_PREVIEW
from term import Event, EV_MOUSE, MB_LEFT, MB_MIDDLE
from layout import Layout, L_GROUP, L_ROW, L_COL, PANE_MIN_W, PANE_MIN_H, RATIO_MIN, RATIO_MAX
from window import Window, WK_EDITOR, WK_MDPREVIEW
from screen import Screen
from palette import theme
from window_draw import *
from markdown import md_render, MdLine, MD_BLOCK, MD_TEXT, MD_CODE, MD_STRIKE
from highlight import Highlighter
from signals import own_pid
from util import decode, to_str, env_or, run_system, shell_quote


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f27-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def rect(l: Layout, g: Int) -> String:
    return String(l.gx[g]) + "," + String(l.gy[g]) + " " + String(l.gw[g]) + "x" + String(l.gh[g])


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f27_case1_layout_split_side_by_side() raises:
    """Verify Layout.split(True) splits current group into horizontal side-by-side panes."""
    var l = Layout()
    l.add(1)
    l.add(2)
    var err = l.split(True)
    assert_equal(err, "")
    assert_equal(l.describe(), "([1*] | [2*]!)")

    var gs = l.groups()
    assert_equal(len(gs), 2)


def test_tier1_f27_case2_layout_split_vertical_col() raises:
    """Verify Layout.split(False) splits current group into vertical stacked panes."""
    var l = Layout()
    l.add(1)
    l.add(2)
    var err = l.split(False)
    assert_equal(err, "")
    assert_equal(l.describe(), "([1*] / [2*]!)")

    var gs = l.groups()
    assert_equal(len(gs), 2)


def test_tier1_f27_case3_layout_resize_ratio_adjustment() raises:
    """Verify Layout.resize alters split ratio and geometry proportionally."""
    var l = Layout()
    l.add(1)
    l.add(2)
    _ = l.split(True)
    l.place(0, 0, 100, 30)

    var gs = l.groups()
    assert_equal(rect(l, gs[0]), "0,0 50x30")
    assert_equal(rect(l, gs[1]), "50,0 50x30")

    # Resize current group (gs[1]) by growing it
    assert_true(l.resize(100))
    l.place(0, 0, 100, 30)
    assert_equal(rect(l, gs[0]), "0,0 40x30")
    assert_equal(rect(l, gs[1]), "40,0 60x30")


def test_tier1_f27_case4_tab_addition_and_navigation() raises:
    """Verify tabs can be added to a group and navigated with next_tab."""
    var l = Layout()
    l.add(10)
    l.add(20)
    l.add(30)
    assert_equal(l.describe(), "[10 20 30*]!")

    l.next_tab(1)
    assert_equal(l.describe(), "[10* 20 30]!")

    l.next_tab(1)
    assert_equal(l.describe(), "[10 20* 30]!")


def test_tier1_f27_case5_markdown_task_checkboxes_parsing() raises:
    """Verify Markdown renderer parses task list items and checkboxes."""
    var hl = Highlighter()
    var doc = "- [ ] Unchecked task item\n- [x] Completed task item\n"
    var lines = md_render(doc, 80, hl)

    assert_true(len(lines) >= 2)
    var rendered = String("")
    for line in lines:
        rendered += to_str(line.cps) + "\n"

    assert_true(rendered.find("Unchecked") >= 0)
    assert_true(rendered.find("Completed") >= 0)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f27_bound1_ratio_min_max_clamping() raises:
    """Verify Layout split ratio strictly clamps at RATIO_MIN (150) and RATIO_MAX (850)."""
    var l = Layout()
    l.add(1)
    l.add(2)
    _ = l.split(True)

    # Attempt to grow beyond max limit
    for _ in range(10):
        _ = l.resize(200)

    var p = l.parent[l.cur]
    assert_true(l.ratio[p] <= RATIO_MAX)
    assert_true(l.ratio[p] >= RATIO_MIN)

    # Attempt to shrink beyond min limit
    for _ in range(15):
        _ = l.resize(-200)

    assert_true(l.ratio[p] >= RATIO_MIN)
    assert_true(l.ratio[p] <= RATIO_MAX)


def test_tier2_f27_bound2_minimum_pane_dimension_enforcement() raises:
    """Verify geometry place preserves PANE_MIN_W and PANE_MIN_H boundaries."""
    var l = Layout()
    l.add(1)
    l.add(2)
    _ = l.split(True)

    # Place in tight geometry: 32 columns wide (16 per pane minimum)
    l.place(0, 0, 32, 10)
    var gs = l.groups()
    assert_true(l.gw[gs[0]] >= PANE_MIN_W)
    assert_true(l.gw[gs[1]] >= PANE_MIN_W)


def test_tier2_f27_bound3_duplicate_filename_tab_disambiguation() raises:
    """Verify window title attributes distinguish duplicate file basenames by path, pinned tabs, and WK_MDPREVIEW."""
    var w1 = Window(WK_EDITOR, "init.mojo", "src/core/init.mojo", 0, 0, 40, 20, 1)
    var w2 = Window(WK_EDITOR, "init.mojo", "src/net/init.mojo", 40, 0, 40, 20, 2)

    assert_equal(w1.title, "init.mojo")
    assert_equal(w2.title, "init.mojo")
    assert_true(w1.path != w2.path)
    assert_true(w1.path.find("core") >= 0)
    assert_true(w2.path.find("net") >= 0)

    # Disambiguated titles include parent directories
    var t1 = w1.tab_title(True)
    var t2 = w2.tab_title(True)
    assert_equal(t1, "init.mojo — core")
    assert_equal(t2, "init.mojo — net")

    # Pinned tab shows pinned indicator
    w1.pinned = True
    assert_true(w1.pinned)
    var t1_pinned = w1.tab_title(True)
    assert_true(t1_pinned.find("📌") >= 0)

    # Markdown preview window
    var w_prev = Window(WK_MDPREVIEW, "README.md", "README.md", 40, 0, 40, 20, 3)
    assert_equal(w_prev.kind, WK_MDPREVIEW)
    w_prev.preview_peer_wid = 1
    assert_equal(w_prev.preview_peer_wid, 1)


def test_tier2_f27_bound4_close_active_tab_in_multi_tab_group() raises:
    """Verify removing the currently active tab promotes neighboring tab cleanly."""
    var l = Layout()
    l.add(1)
    l.add(2)
    l.add(3)
    l.activate(2)  # [1 2* 3]!

    l.remove(2)    # Remove active tab 2
    assert_equal(l.describe(), "[1 3*]!")
    assert_equal(l.shown(l.cur), 3)


def test_tier2_f27_bound5_markdown_code_block_syntax_in_preview() raises:
    """Verify Markdown renderer parses fenced multi-line code blocks into syntax tokens."""
    var hl = Highlighter()
    var doc = "```mojo\ndef add(a: Int, b: Int) -> Int:\n    return a + b\n```"
    var lines = md_render(doc, 80, hl)

    assert_true(len(lines) > 0)
    var has_block_token = False
    for line in lines:
        for st in line.st:
            if st >= MD_BLOCK:
                has_block_token = True
                break

    assert_true(has_block_token, "Markdown did not generate MD_BLOCK syntax tokens")


def test_tier2_f27_bound6_gfm_checkbox_glyphs_and_wk_mdpreview_draw() raises:
    """Verify GFM checkboxes render ☐/☑ glyphs and WK_MDPREVIEW Window.draw renders rich Markdown."""
    var hl = Highlighter()
    var doc = "# Title\n\n- [ ] Todo item\n- [x] Done ~~old~~ item\n\n```mojo\ndef main():\n    pass\n```\n"
    var lines = md_render(doc, 60, hl)
    var full = String("")
    for l in lines:
        full += to_str(l.cps) + "\n"
    assert_true(full.find("☐ Todo item") >= 0)
    assert_true(full.find("☑ Done old item") >= 0)

    var win = Window(WK_MDPREVIEW, "README.md", "README.md", 0, 0, 64, 14, 1)
    win.buf.load(decode(doc))
    var scr = Screen(64, 14)
    var pal = theme(0)
    win.draw(scr, pal, hl, True, False, False, False)

    var all_scr = String("")
    for ry in range(1, 13):
        all_scr += to_str(scr.row_text(ry)) + "\n"
    assert_true(all_scr.find("Title") >= 0)
    assert_true(all_scr.find("☐ Todo item") >= 0)
    assert_true(all_scr.find("☑ Done old item") >= 0)


def test_tier2_f27_bound7_app_pinned_tab_middle_close_mdpreview_and_splitter_drag() raises:
    """Verify App CM_PIN_TAB guard, middle-click close, CM_MD_PREVIEW scroll sync, and splitter mouse drag."""
    var d = scratch("app_f27")
    var md_src = "# Heading\n\n"
    for i in range(40):
        md_src += "- [x] Item " + String(i) + "\n"
    var app = App()
    app.scr.resize(110, 28)
    app.cwd = d
    app.tiled = True

    var e1 = app.new_editor("guide.md", d + "/guide.md")
    app.wins[e1].buf.load(decode(md_src))
    app.wins[e1].buf.modified = False
    app.layout_sync()

    # Pin guide.md and confirm CM_CLOSE refuses to close it
    app.exec(CM_PIN_TAB)
    assert_true(app.wins[e1].pinned)
    app.exec(CM_CLOSE)
    assert_equal(len(app.wins), 1)
    app.exec(CM_PIN_TAB)
    assert_false(app.wins[e1].pinned)

    # Open side-by-side live Markdown preview (creates split + WK_MDPREVIEW)
    app.exec(CM_MD_PREVIEW)
    app.draw()
    var pi = -1
    for k in range(len(app.wins)):
        if app.wins[k].kind == WK_MDPREVIEW:
            pi = k
    assert_true(pi >= 0)

    # Scroll source editor and verify WK_MDPREVIEW syncs proportionally
    app.focus(e1)
    app.wins[e1].top = 20
    app.sync_shared_buffers(e1)
    assert_true(app.wins[pi].top > 0)

    # Drag vertical splitter border between the two tiled panes
    var border_x = app.wins[e1].x + app.wins[e1].w
    var border_y = app.wins[e1].y + 4
    var w_before = app.wins[e1].w
    app.handle(Event(EV_MOUSE, 0, border_x, border_y, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, border_x + 12, border_y, MB_LEFT, True, True, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, border_x + 12, border_y, MB_LEFT, False, False, List[Int]()))
    assert_true(app.wins[e1].w > w_before)

    # Add a second tab in the preview pane group, then middle-click the WK_MDPREVIEW tab to close it
    app.focus(pi)
    var e2 = app.new_editor("notes.md", d + "/notes.md")
    app.wins[e2].buf.modified = False
    app.layout_sync()
    app.draw()
    var tx = -1
    for k in range(len(app.tab_wid)):
        if app.tab_wid[k] == app.wins[pi].wid:
            tx = (app.tab_x0[k] + app.tab_x1[k]) // 2
    var ty = app.wins[pi].y
    assert_true(tx >= 0)
    app.handle(Event(EV_MOUSE, 0, tx, ty, MB_MIDDLE, True, False, List[Int]()))
    assert_equal(len(app.wins), 2)
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
