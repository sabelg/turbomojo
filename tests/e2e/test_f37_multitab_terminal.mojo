"""E2E Test Suite for Feature #37:
Multi-Tab Terminals & Clickable Links.
- Dynamic multi-terminal windows (TS_SHELL, TS_RUN, TS_REPL).
- Clickable file:line and file:line:col navigation links in WK_TERM.
- Link resolution and editor jump to exact line and column.
- Terminal scrollback navigation and ended session cleanup.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from appstate import App
from app import *
from window import Window, WK_TERM, WK_EDITOR
from termsession import TS_SHELL, TS_RUN, TS_REPL, TermSession
from links import find_refs, FileRef
from term import KEY_ENTER, KEY_ESC, fkey
from util import decode, to_str, path_exists
from harness import ScratchDir, make_test_app
from vt import VtReply


# =========================================================================
# Tier 1 Tests (Happy Path)
# =========================================================================

def test_f37_t1_01_open_multiple_terminal_windows_coexistence() raises:
    """Verifies multiple terminal windows coexist with distinct session paths and bottom docking."""
    var s = ScratchDir.create("f37_multi")
    var app = make_test_app(s)

    _ = app.term_open_window(TS_SHELL)
    _ = app.term_open_window(TS_RUN)

    assert_equal(len(app.wins), 2)
    assert_equal(app.wins[0].kind, WK_TERM)
    assert_equal(app.wins[1].kind, WK_TERM)
    assert_equal(app.wins[0].path, "terminal:shell")
    assert_equal(app.wins[1].path, "terminal:run")
    assert_equal(app.term_kind_of(0), TS_SHELL)
    assert_equal(app.term_kind_of(1), TS_RUN)
    assert_true(app.wins[0].y > 0)
    assert_true(app.wins[1].y > 0)
    s.cleanup()


def test_f37_t1_02_switch_active_terminal_and_focus() raises:
    """Verifies switching focus between open terminal sessions updates active window index."""
    var s = ScratchDir.create("f37_focus")
    var app = make_test_app(s)
    _ = app.term_open_window(TS_SHELL)
    _ = app.term_open_window(TS_RUN)

    # Focus shell (window 0 pops and appends to top)
    app.focus(0)
    assert_equal(app.term_kind_of(app.top()), TS_SHELL)
    assert_equal(app.term_index(TS_SHELL), app.top())

    # Focus run (window 0 pops and appends to top)
    app.focus(0)
    assert_equal(app.term_kind_of(app.top()), TS_RUN)
    assert_equal(app.term_index(TS_RUN), app.top())
    s.cleanup()


def test_f37_t1_03_clickable_file_line_link_detection_find_refs() raises:
    """Verifies find_refs detects path:line and path:line:col in terminal diagnostic output."""
    var line1 = "src/main.mojo:42:10: error: undefined symbol 'Foo'"
    var refs1 = find_refs(decode(line1))
    assert_equal(len(refs1), 1)
    assert_equal(refs1[0].path, "src/main.mojo")
    assert_equal(refs1[0].line, 42)
    assert_equal(refs1[0].col, 10)

    var line2 = "at tests/test_buffer.mojo:120: assertion failed"
    var refs2 = find_refs(decode(line2))
    assert_equal(len(refs2), 1)
    assert_equal(refs2[0].path, "tests/test_buffer.mojo")
    assert_equal(refs2[0].line, 120)
    assert_equal(refs2[0].col, 0)


def test_f37_t1_04_terminal_link_resolution_and_editor_jump() raises:
    """Verifies resolving a terminal reference and opening it jumps to the target line and column."""
    var s = ScratchDir.create("f37_jump")
    s.write("target.mojo", "row 0\nrow 1\nrow 2\nrow 3 target\nrow 4\n")
    var app = make_test_app(s)

    var out_line = "error: target.mojo:4:3: failure"
    var refs = find_refs(decode(out_line))
    assert_equal(len(refs), 1)

    var resolved = app.link_resolve(refs[0].path)
    assert_true(resolved.byte_length() > 0)
    assert_true(path_exists(resolved))

    # Navigate
    app.open_path(resolved)
    var top = app.top()
    app.wins[top].goto(refs[0].line - 1, max(0, refs[0].col - 1))

    assert_equal(app.wins[top].kind, WK_EDITOR)
    assert_equal(app.wins[top].path, resolved)
    assert_equal(app.wins[top].cr, 3)
    assert_equal(app.wins[top].cc, 2)
    s.cleanup()


def test_f37_t1_05_terminal_scrollback_view_scrolling() raises:
    """Verifies term_scroll scrolls viewport back and forward cleanly."""
    var s = ScratchDir.create("f37_scroll")
    var app = make_test_app(s)
    _ = app.term_open_window(TS_SHELL)

    # Scroll back 5 lines
    app.term_scroll(TS_SHELL, -5)

    # Scroll forward to bottom
    app.term_scroll(TS_SHELL, 5)

    var ts = app.term_take(TS_SHELL)
    assert_true(ts.vt.at_bottom())
    app.term_put(TS_SHELL, ts^)
    s.cleanup()


# =========================================================================
# Tier 2 Tests (Boundary & Corner Cases)
# =========================================================================

def test_f37_t2_01_close_one_terminal_retains_sibling_terminal_session() raises:
    """Verifies closing one terminal window leaves sibling terminal session open."""
    var s = ScratchDir.create("f37_close")
    var app = make_test_app(s)
    _ = app.term_open_window(TS_SHELL)
    _ = app.term_open_window(TS_RUN)

    assert_equal(len(app.wins), 2)

    # Close shell window (index 0)
    app.term_close_window(0)

    assert_equal(len(app.wins), 1)
    assert_equal(app.term_kind_of(0), TS_RUN)
    assert_equal(app.term_index(TS_SHELL), -1)
    assert_equal(app.term_index(TS_RUN), 0)
    s.cleanup()


def test_f37_t2_02_terminal_process_exit_ended_state_and_title_update() raises:
    """Verifies process termination triggers ended_note status and appends (ended) to title."""
    var s = ScratchDir.create("f37_exit")
    var app = make_test_app(s)
    var ti = app.term_open_window(TS_RUN)

    # Configure session as terminated
    var sess = app.term_take(TS_RUN)
    sess.started = True
    sess.pty.pid = 12345
    sess.pty.running = False
    sess.pty.eof = True
    sess.pty.status = 0
    sess.title = "Run - build"

    # Pump session to detect exit
    var replies = List[VtReply]()
    app.term_pump(sess, replies, ti)

    assert_true(sess.ended_note.find("ended with status 0") >= 0)
    assert_true(app.wins[ti].title.find("(ended)") >= 0)
    app.term_put(TS_RUN, sess^)
    s.cleanup()


def test_f37_t2_03_link_detection_boundary_cases_colons_and_missing_files() raises:
    """Verifies link detection handles trailing periods and returns empty string for missing files."""
    var s = ScratchDir.create("f37_bound")
    var app = make_test_app(s)

    # Trailing period after column should not corrupt numbers
    var line1 = "Found at src/foo.mojo:12:4."
    var refs1 = find_refs(decode(line1))
    assert_equal(len(refs1), 1)
    assert_equal(refs1[0].path, "src/foo.mojo")
    assert_equal(refs1[0].line, 12)
    assert_equal(refs1[0].col, 4)

    # Text without line digits should produce zero refs
    var line2 = "Inspect file.mojo for details"
    var refs2 = find_refs(decode(line2))
    assert_equal(len(refs2), 0)

    # link_resolve for non-existent file returns empty string
    assert_equal(app.link_resolve("nonexistent_path_xyz.mojo"), "")
    s.cleanup()


def test_f37_t2_04_ansi_stripped_terminal_link_detection() raises:
    """Verifies find_refs parses paths extracted from terminal screens stripped of ANSI escapes."""
    # Simulate ANSI-stripped text line from VT screen buffer
    var line = "Error: src/engine.mojo:88:12: syntax error"
    var refs = find_refs(decode(line))
    assert_equal(len(refs), 1)
    assert_equal(refs[0].path, "src/engine.mojo")
    assert_equal(refs[0].line, 88)
    assert_equal(refs[0].col, 12)
    assert_equal(refs[0].start, 7)
    assert_equal(refs[0].end, 28)


def test_f37_t2_05_terminal_key_navigation_and_ended_session_esc_close() raises:
    """Verifies IDE keys are reserved and ESC closes an ended terminal session."""
    var s = ScratchDir.create("f37_keys")
    var app = make_test_app(s)
    _ = app.term_open_window(TS_RUN)

    # Reserved keys check
    assert_true(app.term_reserved(fkey(6)))
    assert_true(app.term_reserved(fkey(10)))

    # Mark session as ended
    app.trun.ended_note = "[ended]"

    # ESC closes ended session window
    var handled = app.term_key(KEY_ESC)
    assert_true(handled)
    assert_equal(app.term_index(TS_RUN), -1)
    s.cleanup()


def test_f37_t2_06_multitab_shell_new_next_prev_close() raises:
    """Verifies multi-tab shell terminals update [1/N] title and cycle cleanly."""
    var s = ScratchDir.create("f37_tabs")
    var app = make_test_app(s)
    app.term_new_tab()
    assert_equal(app.term_tab_count(), 1)
    app.term_new_tab()
    assert_equal(app.term_tab_count(), 2)
    var ti = app.term_index(TS_SHELL)
    assert_true(ti >= 0)
    assert_true(app.wins[ti].title.startswith("[2/2]"))
    app.term_prev_tab()
    assert_true(app.wins[ti].title.startswith("[1/2]"))
    app.term_next_tab()
    assert_true(app.wins[ti].title.startswith("[2/2]"))
    app.term_close_tab()
    assert_equal(app.term_tab_count(), 1)
    assert_false(app.wins[ti].title.startswith("["))
    app.term_close_tab()
    assert_equal(app.term_index(TS_SHELL), -1)
    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
