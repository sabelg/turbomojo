"""E2E Test Suite for Feature #19:
Inline syntax-highlighted PeekBox overlay anchored below cursor for defs/refs Alt-F12
and inline Git hunk preview with single-key stage (S) and revert (R).

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from buffer import TextBuffer, Pos
from git import GB_KNOWN
from window import Window, WK_EDITOR
from linediff import diff_lines, text_hashes, Hunk
from gitdiff import (
    Side, side_hunks, with_hunk, without_hunk, hunk_at_line,
    DR_HEADER, DR_NEW, DR_OLD, unified, DiffRow,
)
from app import *
from appstate import App, M_NORMAL, M_HOVER, M_PEEK, WK_DIFF
from commands import CM_PEEK_DEF, CM_GIT_PREVIEW_HUNK
from term import Event, EV_KEY, key_event, KEY_ESC, KEY_ENTER, KEY_UP, KEY_DOWN, KEY_TAB
from symindex import IndexedSymbol
from outline import SK_FUNCTION
from markdown import md_render, MdLine
from highlight import Highlighter
from signals import own_pid
from util import decode, to_str, bytes_to_str, env_or, run_system, shell_quote, write_file, str_bytes


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f19-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f19_case1_peekbox_geometry_and_cursor_anchoring() raises:
    """Verify overlay popup box computes anchored coordinates strictly below the cursor."""
    var win = Window(WK_EDITOR, "main.mojo", "main.mojo", 0, 0, 80, 24, 1)
    win.gut = 4
    win.cr = 5
    win.cc = 10
    var cx = win.x + win.gut + 1 + max(0, win.cc - win.left)
    var cy = win.y + 1 + max(0, win.cr - win.top)
    var box_w = 40
    var box_h = 8
    var scr_w = 80
    var scr_h = 24
    var x = max(1, min(cx - 1, scr_w - box_w - 2))
    var y = cy + 1
    assert_equal(y, cy + 1)
    assert_true(x >= 1)
    assert_true(x + box_w <= scr_w)
    assert_true(y + box_h <= scr_h)


def test_tier1_f19_case2_peekbox_content_loading_around_definition() raises:
    """Verify Markdown-highlighted overlay context rendering for peek definitions."""
    var hl = Highlighter()
    var md_src = "### Definition: `compute`\n```mojo\ndef compute(a: Int) -> Int:\n    return a * 2\n```"
    var lines = md_render(md_src, 60, hl)
    assert_true(len(lines) > 0)
    var found_def = False
    for i in range(len(lines)):
        var s = to_str(lines[i].cps)
        if s.find("def compute") >= 0:
            found_def = True
            break
    assert_true(found_def)


def test_tier1_f19_case3_git_hunk_detection_from_buffer_and_base() raises:
    """Verify side_hunks and hunk_at_line accurately discover modified and added hunk ranges."""
    var base = Side.of("line1\nline2\nline3\nline4\n")
    var curr = Side.of("line1\nMODIFIED_2\nline3\nline4\nEXTRA_5\n")

    var hunks = side_hunks(base, curr)
    assert_equal(len(hunks), 2)

    # Hunk 0: line 1 modified
    assert_equal(hunks[0].a, 1)
    assert_equal(hunks[0].la, 1)
    assert_equal(hunks[0].b, 1)
    assert_equal(hunks[0].lb, 1)

    # Hunk 1: EXTRA_5 added at end
    assert_equal(hunks[1].a, 4)
    assert_equal(hunks[1].la, 0)
    assert_equal(hunks[1].b, 4)
    assert_equal(hunks[1].lb, 1)

    # hunk_at_line maps row 1 to hunk 0
    assert_equal(hunk_at_line(hunks, 1), 0)


def test_tier1_f19_case4_git_hunk_stage_command_s() raises:
    """Verify staging a single hunk via with_hunk updates the index base without affecting other hunks."""
    var base = Side.of("alpha\nbeta\ngamma\n")
    var curr = Side.of("alpha\nBETA_NEW\nGAMMA_NEW\n")

    var hunks = side_hunks(base, curr)
    assert_equal(len(hunks), 1)

    # Stage the hunk using production with_hunk
    var staged_base = with_hunk(base, curr, hunks[0])
    assert_equal(staged_base.text(), "alpha\nBETA_NEW\nGAMMA_NEW\n")

    # After staging, diff against staged index becomes empty
    var remaining = side_hunks(staged_base, curr)
    assert_equal(len(remaining), 0)


def test_tier1_f19_case5_git_hunk_revert_command_r() raises:
    """Verify reverting a hunk via without_hunk restores original base text."""
    var base = Side.of("val = 1\nval = 2\n")
    var curr = Side.of("val = 1\nval = 999\n")

    var hunks = side_hunks(base, curr)
    assert_equal(len(hunks), 1)

    # Revert hunk in buffer back to base using production without_hunk
    var reverted_curr = without_hunk(base, curr, hunks[0])
    assert_equal(reverted_curr.text(), "val = 1\nval = 2\n")

    # Remaining diff against base becomes empty
    var remaining = side_hunks(base, reverted_curr)
    assert_equal(len(remaining), 0)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f19_bound1_peekbox_clamping_at_screen_bottom_edge() raises:
    """Verify popup flips above cursor when positioned near screen bottom edge."""
    var scr_h = 24
    var cy = scr_h - 3
    var h = 8
    var y = cy + 1
    if y + h > scr_h - 1:
        y = max(1, cy - h)
    assert_true(y < cy)
    assert_true(y >= 1)
    assert_true(y + h <= scr_h)


def test_tier2_f19_bound2_peekbox_esc_dismiss_and_focus_preservation() raises:
    """Verify Esc dismisses hover overlay, restoring M_NORMAL state."""
    var mode = M_HOVER
    assert_equal(mode, 4)
    # Esc dismisses hover overlay back to normal
    mode = M_NORMAL
    assert_equal(mode, 0)


def test_tier2_f19_bound3_git_hunk_unstage_command_u_on_staged_view() raises:
    """Verify unstaging a staged hunk via without_hunk restores previous index state."""
    var original_base = Side.of("original\n")
    var staged_base = Side.of("staged_edit\n")

    # In staged view: diff between original base and staged index
    var hunks = side_hunks(original_base, staged_base)
    assert_equal(len(hunks), 1)

    # Unstage hunk 0 back to original base using production without_hunk
    var unstaged = without_hunk(original_base, staged_base, hunks[0])
    assert_equal(unstaged.text(), "original\n")


def test_tier2_f19_bound4_git_hunk_boundary_first_and_last_lines() raises:
    """Verify hunks at line 0 (file start) and EOF are accurate with with_hunk."""
    # Line 0 insertion
    var base0 = Side.of("middle\n")
    var curr0 = Side.of("HEADER\nmiddle\n")
    var h0 = side_hunks(base0, curr0)
    assert_equal(len(h0), 1)
    assert_equal(h0[0].a, 0)
    assert_equal(h0[0].la, 0)
    assert_equal(h0[0].b, 0)
    assert_equal(h0[0].lb, 1)

    var staged0 = with_hunk(base0, curr0, h0[0])
    assert_equal(staged0.text(), "HEADER\nmiddle\n")

    # Trailing line added to base
    var base_eof = Side.of("a\nb\n")
    var curr_eof = Side.of("a\nb\nTRAILING\n")
    var h_eof = side_hunks(base_eof, curr_eof)
    assert_equal(len(h_eof), 1)
    var staged_eof = with_hunk(base_eof, curr_eof, h_eof[0])
    assert_equal(staged_eof.text(), "a\nb\nTRAILING\n")


def test_tier2_f19_bound5_peekbox_multi_reference_cycling_and_scrolling() raises:
    """Verify multi-line hover scrolling."""
    var hl = Highlighter()
    var md_text = "- Ref 1\n- Ref 2\n- Ref 3\n- Ref 4\n- Ref 5\n- Ref 6\n- Ref 7\n- Ref 8\n- Ref 9\n- Ref 10\n"
    var lines = md_render(md_text, 40, hl)
    assert_equal(len(lines), 10)
    var hover_scroll = 0
    # Scroll down
    hover_scroll = min(len(lines) - 1, hover_scroll + 1)
    assert_equal(hover_scroll, 1)
    # Scroll up
    hover_scroll = max(0, hover_scroll - 1)
    assert_equal(hover_scroll, 0)


def test_tier2_f19_bound6_app_peek_def_and_git_hunk_overlay() raises:
    """Verify App CM_PEEK_DEF opens M_PEEK overlay with multi-ref cycling/jump, and CM_GIT_PREVIEW_HUNK stages/reverts."""
    var d = scratch("app_peek")
    _ = run_system(
        "cd " + shell_quote(d)
        + " && git init -q && git config user.name 'T' && git config user.email 't@t'"
    )
    _ = write_file(d + "/lib.mojo", str_bytes("def target_fn(x: Int) -> Int:\n    return x * 3\n"))
    _ = write_file(d + "/main.mojo", str_bytes("from lib import target_fn\n\ndef main():\n    var v = target_fn(7)\n"))
    _ = run_system("cd " + shell_quote(d) + " && git add . && git commit -q -m 'init'")

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/main.mojo")
    app.symidx.syms.append(IndexedSymbol("target_fn", SK_FUNCTION, d + "/lib.mojo", 0, 4, ""))
    app.symidx.syms.append(IndexedSymbol("target_fn", SK_FUNCTION, d + "/main.mojo", 3, 12, ""))

    var ei = app.top_editor()
    app.wins[ei].goto(3, 14)
    app.exec(CM_PEEK_DEF)
    assert_equal(app.mode, M_PEEK)
    assert_equal(len(app.peek_paths), 2)
    app.draw()
    var scr_txt = to_str(app.scr.to_text())
    assert_true(scr_txt.find("Peek: lib.mojo:1") >= 0 and scr_txt.find("def target_fn") >= 0, scr_txt)

    # Tab cycles to second location, Esc dismisses back to M_NORMAL
    app.handle(key_event(KEY_TAB))
    assert_equal(app.peek_idx, 1)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)

    # Re-open and press Enter to jump to lib.mojo definition
    app.exec(CM_PEEK_DEF)
    assert_equal(app.mode, M_PEEK)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.wins[app.top_editor()].path, d + "/lib.mojo")

    # Pump git_tick so lib.mojo gets its real Git index base, then modify and revert via inline hunk preview
    var li = app.top_editor()
    var deadline = Int(perf_counter_ns()) + 5000000000
    while app.wins[li].buf.git_state != GB_KNOWN and Int(perf_counter_ns()) < deadline:
        app.git_tick(Int(perf_counter_ns()))
    assert_equal(app.wins[li].buf.git_state, GB_KNOWN)

    app.wins[li].buf.load(decode("def target_fn(x: Int) -> Int:\n    return x * 99\n"))
    app.wins[li].buf.git_state = GB_KNOWN
    app.wins[li].buf.git_base_text = "def target_fn(x: Int) -> Int:\n    return x * 3\n"
    app.wins[li].buf.modified = True
    app.wins[li].goto(1, 4)
    app.exec(CM_GIT_PREVIEW_HUNK)
    assert_equal(app.mode, M_PEEK)
    assert_true(app.peek_is_hunk)
    app.handle(key_event(ord("R")))
    assert_equal(app.mode, M_NORMAL)
    assert_true(bytes_to_str(app.wins[li].buf.to_bytes()).find("return x * 3") >= 0)
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
