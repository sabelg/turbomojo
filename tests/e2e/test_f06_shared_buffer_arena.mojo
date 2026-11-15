"""E2E Test Suite for Feature #6:
Shared BufferId Arena for Split Views.
- Eliminates per-keystroke deep copies of TextBuffer, Rope, and undo history across cloned views.
- Maintains view-local cursors, scroll offsets, and fold states.
- Bidirectional edit propagation and shared undo/redo history.
- Sibling retention on closing split views.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from appstate import App
from app import *
from window import Window, WK_EDITOR
from buffer import TextBuffer, Pos
from util import decode, to_str
from harness import ScratchDir, make_test_app


# =========================================================================
# Tier 1 Tests (Happy Path)
# =========================================================================

def test_f06_t1_01_editor_allocation_and_buf_id_arena_registration() raises:
    """Verifies opening a file allocates an editor window, registers buffer in arena, and assigns buf_id."""
    var s = ScratchDir.create("f06_alloc")
    s.write("main.mojo", "var x = 1\nvar y = 2\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/main.mojo")

    assert_equal(len(app.wins), 1)
    assert_equal(app.wins[0].kind, WK_EDITOR)
    assert_true(app.wins[0].buf_id >= 0)
    assert_true(len(app.buffers) > app.wins[0].buf_id)
    assert_equal(app.wins[0].buf.count(), 3)
    assert_equal(to_str(app.wins[0].buf.line(0)), "var x = 1")
    s.cleanup()


def test_f06_t1_02_clone_editor_view_shares_buffer_id_and_rope_core() raises:
    """Verifies clone_editor_view creates a split view sharing buf_id, clone_group, and Rope core."""
    var s = ScratchDir.create("f06_clone")
    s.write("test.mojo", "def hello():\n    return 42\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/test.mojo")

    app.clone_editor_view(True)

    assert_equal(len(app.wins), 2)
    assert_equal(app.wins[0].kind, WK_EDITOR)
    assert_equal(app.wins[1].kind, WK_EDITOR)
    assert_equal(app.wins[0].buf_id, app.wins[1].buf_id)
    assert_equal(app.wins[0].clone_group, app.wins[1].clone_group)
    assert_true(app.wins[0].clone_group > 0)
    assert_true(app.same_shared_buffer(0, 1))
    assert_true(app.same_shared_buffer(1, 0))
    assert_true(app.has_shared_sibling(0))
    assert_true(app.has_shared_sibling(1))
    s.cleanup()


def test_f06_t1_03_edits_propagate_immediately_across_splits_via_sync() raises:
    """Verifies edits made in one split view propagate to sibling views on sync_shared_buffers."""
    var s = ScratchDir.create("f06_sync")
    s.write("data.mojo", "line 1\nline 2\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/data.mojo")
    app.clone_editor_view(True)

    _ = app.wins[0].buf.insert(0, 0, decode("MUTATED: "), 0, 0, 1)
    app.sync_shared_buffers(0)

    assert_equal(app.wins[0].buf.version, app.wins[1].buf.version)
    assert_true(app.wins[0].buf.modified)
    assert_true(app.wins[1].buf.modified)
    assert_equal(to_str(app.wins[0].buf.line(0)), "MUTATED: line 1")
    assert_equal(to_str(app.wins[1].buf.line(0)), "MUTATED: line 1")
    assert_equal(app.wins[1].sync_ver, app.wins[1].buf.version)
    s.cleanup()


def test_f06_t1_04_independent_view_local_cursors_and_scroll_offsets() raises:
    """Verifies cursors and scroll offsets remain independent across split views."""
    var s = ScratchDir.create("f06_cursor")
    s.write("doc.mojo", "row 0: abc\nrow 1: def\nrow 2: ghi\nrow 3: jkl\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/doc.mojo")
    app.clone_editor_view(True)

    # Window 0 cursor at row 0, col 2; scroll top 0
    app.wins[0].cr = 0
    app.wins[0].cc = 2
    app.wins[0].top = 0

    # Window 1 cursor at row 2, col 4; scroll top 1
    app.wins[1].cr = 2
    app.wins[1].cc = 4
    app.wins[1].top = 1

    # Edit in window 0 and sync
    _ = app.wins[0].buf.insert(0, 0, decode("# "), 0, 0, 1)
    app.sync_shared_buffers(0)

    # Verify view-local states are preserved
    assert_equal(app.wins[0].cr, 0)
    assert_equal(app.wins[0].top, 0)
    assert_equal(app.wins[1].cr, 2)
    assert_equal(app.wins[1].cc, 4)
    assert_equal(app.wins[1].top, 1)
    s.cleanup()


def test_f06_t1_05_independent_view_local_fold_states_across_splits() raises:
    """Verifies block folds remain view-local and do not leak across split views."""
    var s = ScratchDir.create("f06_folds")
    s.write("folds.mojo", "def f1():\n    pass\ndef f2():\n    pass\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/folds.mojo")
    app.clone_editor_view(True)

    # Fold block in window 0
    app.wins[0].buf.folds.append(0)
    app.wins[0].buf.fold_ends.append(1)

    _ = app.wins[0].buf.insert(2, 0, decode("# comment\n"), 0, 0, 1)
    app.sync_shared_buffers(0)

    # Window 0 retains fold; Window 1 fold list remains empty
    assert_equal(len(app.wins[0].buf.folds), 1)
    assert_equal(len(app.wins[1].buf.folds), 0)
    s.cleanup()


# =========================================================================
# Tier 2 Tests (Boundary & Corner Cases)
# =========================================================================

def test_f06_t2_01_shared_undo_redo_history_across_split_views() raises:
    """Verifies undo/redo history is shared across split views and propagates bidirectionally."""
    var s = ScratchDir.create("f06_undo")
    s.write("undo.mojo", "original\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/undo.mojo")
    app.clone_editor_view(True)

    # Edit in window 0 and sync
    _ = app.wins[0].buf.insert(0, 0, decode("edited: "), 0, 0, 1)
    app.sync_shared_buffers(0)

    assert_equal(len(app.wins[0].buf.undos), 1)
    assert_equal(len(app.wins[1].buf.undos), 1)

    # Perform undo in window 1
    _ = app.wins[1].buf.undo()
    app.sync_shared_buffers(1)

    assert_equal(to_str(app.wins[0].buf.line(0)), "original")
    assert_equal(to_str(app.wins[1].buf.line(0)), "original")
    assert_equal(len(app.wins[0].buf.redos), 1)
    assert_equal(len(app.wins[1].buf.redos), 1)
    s.cleanup()


def test_f06_t2_02_close_one_split_view_preserves_sibling_and_arena_buffer() raises:
    """Verifies closing a split view leaves the sibling view and shared buffer intact."""
    var s = ScratchDir.create("f06_close")
    s.write("keep.mojo", "content remains\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/keep.mojo")
    app.clone_editor_view(True)

    assert_equal(len(app.wins), 2)
    assert_true(app.has_shared_sibling(0))

    # Close window 1
    app.remove_window(1)

    assert_equal(len(app.wins), 1)
    assert_false(app.has_shared_sibling(0))
    assert_equal(to_str(app.wins[0].buf.line(0)), "content remains")
    assert_true(app.wins[0].buf_id >= 0)
    s.cleanup()


def test_f06_t2_03_three_way_split_horizontal_and_vertical_sync() raises:
    """Verifies 3-way split maintains shared buffer across all 3 windows."""
    var s = ScratchDir.create("f06_3way")
    s.write("tri.mojo", "init line\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/tri.mojo")
    app.clone_editor_view(True)   # win 1
    app.clone_editor_view(False)  # win 2

    assert_equal(len(app.wins), 3)
    assert_equal(app.wins[0].buf_id, app.wins[1].buf_id)
    assert_equal(app.wins[0].buf_id, app.wins[2].buf_id)
    assert_true(app.same_shared_buffer(0, 1))
    assert_true(app.same_shared_buffer(0, 2))
    assert_true(app.same_shared_buffer(1, 2))

    _ = app.wins[0].buf.insert(0, 0, decode("3WAY: "), 0, 0, 2)
    app.sync_shared_buffers(0)

    assert_equal(to_str(app.wins[1].buf.line(0)), "3WAY: init line")
    assert_equal(to_str(app.wins[2].buf.line(0)), "3WAY: init line")
    s.cleanup()


def test_f06_t2_04_save_file_synchronizes_disk_hash_and_cleans_dirty_flag() raises:
    """Verifies saving one split view synchronizes modified flag and disk state to siblings."""
    var s = ScratchDir.create("f06_save")
    s.write("save.mojo", "base\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/save.mojo")
    app.clone_editor_view(True)

    _ = app.wins[0].buf.insert(0, 0, decode("dirty "), 0, 0, 1)
    app.sync_shared_buffers(0)
    assert_true(app.wins[0].buf.modified)
    assert_true(app.wins[1].buf.modified)

    # Save window 0
    _ = app.save_window(0, 0)
    app.sync_shared_buffers(0)

    assert_false(app.wins[0].buf.modified)
    assert_false(app.wins[1].buf.modified)
    assert_equal(app.wins[0].disk_hash, app.wins[1].disk_hash)
    assert_equal(app.wins[0].disk_size, app.wins[1].disk_size)
    s.cleanup()


def test_f06_t2_05_cursor_clamping_on_truncation_by_sibling_view() raises:
    """Verifies cursor in sibling view is safely clamped when text is deleted by another view."""
    var s = ScratchDir.create("f06_clamp")
    s.write("clamp.mojo", "l0\nl1\nl2\nl3\nl4\n")
    var app = make_test_app(s)
    app.open_path(s.path + "/clamp.mojo")
    app.clone_editor_view(True)

    # Window 1 cursor at row 4, col 1
    app.wins[1].cr = 4
    app.wins[1].cc = 1

    # Window 0 deletes lines 2 through end (leaving lines 0 and 1, count 2)
    _ = app.wins[0].buf.delete(1, 2, 5, 0, 0, 0, 1)
    app.sync_shared_buffers(0)

    assert_equal(app.wins[1].buf.count(), 2)
    assert_true(app.wins[1].cr < app.wins[1].buf.count())
    assert_equal(app.wins[1].cr, 1)
    assert_true(app.wins[1].cc <= app.wins[1].buf.llen(app.wins[1].cr))
    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
