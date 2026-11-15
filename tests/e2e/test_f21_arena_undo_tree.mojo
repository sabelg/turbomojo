"""E2E Test Suite for Feature #21: Non-Linear Arena Undo Tree (g-/g+).
Covers Tier 1 (5 Happy Path tests) and Tier 2 (5 Boundary/Corner tests).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from buffer import (
    TextBuffer, UndoRec, Pos, Mark,
    DiffSpan, compute_diff_span, replace_all_text_diff,
    UndoNode, UndoTreeArena
)
from signals import own_pid
from util import decode, to_str, env_or, run_system, shell_quote

comptime UNDO_INSERT = 1
comptime UNDO_DELETE = 2


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f21-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def buf_text(b: TextBuffer) -> String:
    return to_str(b.all_text())


# ---------------------------------------------------------------------------
# Tier 1: Isolated Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f21_case1_prefix_suffix_diff_trimming() raises:
    """Verify prefix and suffix trimming computes minimal replacement span."""
    var old_s = "def calculate(a: Int, b: Int) -> Int:\n    return a + b\n"
    var new_s = "def calculate(a: Int, b: Int) -> Int:\n    return a * b\n"
    var diff = compute_diff_span(decode(old_s), decode(new_s))
    
    # Common prefix is everything up to '+'
    assert_equal(diff.del_text, decode("+"))
    assert_equal(diff.ins_text, decode("*"))
    assert_true(diff.prefix_len > 40)
    assert_equal(diff.suffix_len, 3) # " b\n"


def test_tier1_f21_case2_linear_undo_redo_roundtrip() raises:
    """Sequential edits, undos, and redos on TextBuffer."""
    var b = TextBuffer()
    b.load(decode("init\n"))
    
    _ = b.insert(1, 0, decode("line2\n"), 1, 0, 1)
    assert_equal(buf_text(b), "init\nline2\n")
    
    _ = b.insert(2, 0, decode("line3\n"), 2, 0, 2)
    assert_equal(buf_text(b), "init\nline2\nline3\n")
    
    # Undo step 2
    _ = b.undo()
    assert_equal(buf_text(b), "init\nline2\n")
    
    # Undo step 1
    _ = b.undo()
    assert_equal(buf_text(b), "init\n")
    
    # Redo step 1
    _ = b.redo()
    assert_equal(buf_text(b), "init\nline2\n")
    
    # Redo step 2
    _ = b.redo()
    assert_equal(buf_text(b), "init\nline2\nline3\n")


def test_tier1_f21_case3_branching_undo_tree_arena_creation() raises:
    """Branch creation: edits on divergent branches are preserved simultaneously."""
    var b = TextBuffer()
    b.load(decode("base\n"))
    var arena = UndoTreeArena(decode("base\n"))
    
    # Branch 1
    _ = replace_all_text_diff(b, decode("base\neditA\n"))
    var id_a = arena.record_state(b.all_text(), "editA")
    
    _ = replace_all_text_diff(b, decode("base\neditA\neditA2\n"))
    var id_a2 = arena.record_state(b.all_text(), "editA2")
    
    # Undo back to base
    assert_true(arena.undo_branch(b))
    assert_true(arena.undo_branch(b))
    assert_equal(buf_text(b), "base\n")
    assert_equal(arena.active, 0)
    
    # Branch 2 from base
    _ = replace_all_text_diff(b, decode("base\neditB\n"))
    var id_b = arena.record_state(b.all_text(), "editB")
    
    # Root (node 0) must now have 2 children: id_a (1) and id_b (3)
    assert_equal(len(arena.nodes[0].children), 2)
    assert_equal(arena.nodes[0].children[0], id_a)
    assert_equal(arena.nodes[0].children[1], id_b)
    
    # Jump between branches
    assert_true(arena.jump_to_node(id_a2, b))
    assert_equal(buf_text(b), "base\neditA\neditA2\n")
    assert_true(arena.jump_to_node(id_b, b))
    assert_equal(buf_text(b), "base\neditB\n")


def test_tier1_f21_case4_vim_g_minus_and_g_plus_chronological_navigation() raises:
    """Vim g- / g+ steps chronologically across divergent branches."""
    var b = TextBuffer()
    b.load(decode("v0"))
    var arena = UndoTreeArena(decode("v0"))
    
    _ = arena.record_state(decode("v1"), "seq 1") # seq 1
    _ = arena.record_state(decode("v2"), "seq 2") # seq 2
    
    # Undo back to v1
    assert_true(arena.undo_branch(b))
    assert_equal(buf_text(b), "v1")
    
    # Create branch at seq 3
    _ = arena.record_state(decode("v3_branch"), "seq 3") # seq 3
    b.load(decode("v3_branch"))
    assert_equal(buf_text(b), "v3_branch")
    
    # Vim g- should step: seq 3 -> seq 2 (on alternate branch!) -> seq 1 -> seq 0
    assert_true(arena.vim_g_minus(b))
    assert_equal(buf_text(b), "v2")
    assert_true(arena.vim_g_minus(b))
    assert_equal(buf_text(b), "v1")
    assert_true(arena.vim_g_minus(b))
    assert_equal(buf_text(b), "v0")
    assert_false(arena.vim_g_minus(b)) # at root
    
    # Vim g+ should step forward: seq 0 -> seq 1 -> seq 2 -> seq 3
    assert_true(arena.vim_g_plus(b))
    assert_equal(buf_text(b), "v1")
    assert_true(arena.vim_g_plus(b))
    assert_equal(buf_text(b), "v2")
    assert_true(arena.vim_g_plus(b))
    assert_equal(buf_text(b), "v3_branch")


def test_tier1_f21_case5_undo_tree_visual_picker_and_direct_jump() raises:
    """Undo tree visual picker text rendering and jumping to arbitrary nodes."""
    var b = TextBuffer()
    b.load(decode("zero\n"))
    var arena = UndoTreeArena(decode("zero\n"))
    
    _ = arena.record_state(decode("one\n"), "first commit")
    _ = arena.record_state(decode("two\n"), "second commit")
    
    var view = arena.render_visual_picker()
    assert_true(view.find("[0] (seq 0): root") >= 0)
    assert_true(view.find("[1] (seq 1): first commit") >= 0)
    assert_true(view.find("* [2] (seq 2): second commit") >= 0)
    
    # Jump directly to root
    assert_true(arena.jump_to_node(0, b))
    assert_equal(buf_text(b), "zero\n")
    var view2 = arena.render_visual_picker()
    assert_true(view2.find("* [0] (seq 0): root") >= 0)


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f21_bound1_empty_buffer_and_identity_replace() raises:
    """Replacing buffer with identical text or replacing empty buffer with empty."""
    var b = TextBuffer()
    b.load(decode(""))
    var diff_empty = replace_all_text_diff(b, decode(""))
    assert_equal(len(diff_empty.del_text), 0)
    assert_equal(len(diff_empty.ins_text), 0)
    assert_equal(buf_text(b), "")
    
    b.load(decode("same content"))
    var diff_same = replace_all_text_diff(b, decode("same content"))
    assert_equal(len(diff_same.del_text), 0)
    assert_equal(len(diff_same.ins_text), 0)
    assert_equal(buf_text(b), "same content")


def test_tier2_f21_bound2_disjoint_full_replacement_zero_affixes() raises:
    """Complete text replacement with zero common prefix and suffix."""
    var b = TextBuffer()
    b.load(decode("AAAA"))
    var diff = replace_all_text_diff(b, decode("BBBB"))
    assert_equal(diff.prefix_len, 0)
    assert_equal(diff.suffix_len, 0)
    assert_equal(diff.del_text, decode("AAAA"))
    assert_equal(diff.ins_text, decode("BBBB"))
    assert_equal(buf_text(b), "BBBB")
    
    _ = b.undo()
    assert_equal(buf_text(b), "AAAA")


def test_tier2_f21_bound3_deep_tree_multiple_branches_and_leaves() raises:
    """Create 15 states across 4 branching paths in arena."""
    var b = TextBuffer()
    b.load(decode("init"))
    var arena = UndoTreeArena(decode("init"))
    
    var leaf_ids = List[Int]()
    for branch in range(4):
        _ = arena.jump_to_node(0, b)
        for step in range(3):
            var txt = "b" + String(branch) + "_s" + String(step)
            var nid = arena.record_state(decode(txt), txt)
            if step == 2:
                leaf_ids.append(nid)
                
    assert_equal(len(arena.nodes[0].children), 4)
    assert_equal(len(leaf_ids), 4)
    
    # Jump between all leaves
    for k in range(len(leaf_ids)):
        var lid = leaf_ids[k]
        assert_true(arena.jump_to_node(lid, b))
        var expected = "b" + String(k) + "_s2"
        assert_equal(buf_text(b), expected)


def test_tier2_f21_bound4_grouped_atomic_transactions() raises:
    """Multiple insert/delete actions with same group are undone as one transaction."""
    var b = TextBuffer()
    b.load(decode("hello world\n"))
    
    # Grouped edit: delete 'world' and insert 'Mojo' under group 99
    _ = b.delete(0, 6, 0, 11, 0, 6, 99)
    _ = b.insert(0, 6, decode("Mojo"), 0, 10, 99)
    assert_equal(buf_text(b), "hello Mojo\n")
    
    # A single undo call must revert both grouped operations back to original
    _ = b.undo()
    assert_equal(buf_text(b), "hello world\n")
    
    # Redo brings both back
    _ = b.redo()
    assert_equal(buf_text(b), "hello Mojo\n")


def test_tier2_f21_bound5_utf8_multibyte_prefix_suffix_boundaries() raises:
    """Multi-byte UTF-8 characters (emojis, umlauts) in diff trimming and undo."""
    var original = "🚀 TurboMojo: Äpfel & Übergrößen 🔥\n"
    var modified = "🚀 TurboMojo: Orangen & Übergrößen 🔥\n"
    var b = TextBuffer()
    b.load(decode(original))
    
    var diff = replace_all_text_diff(b, decode(modified))
    assert_equal(diff.del_text, decode("Äpfel"))
    assert_equal(diff.ins_text, decode("Orangen"))
    assert_equal(buf_text(b), modified)
    
    _ = b.undo()
    assert_equal(buf_text(b), original)


def test_tier2_f21_bound6_textbuffer_builtin_undo_tree_and_vim_g_minus_plus() raises:
    """Integrated non-linear undo tree on TextBuffer and App Vim g-/g+."""
    var b = TextBuffer()
    b.load(decode("base\n"))
    _ = b.insert(1, 0, decode("branchA\n"), 1, 0, 1)
    assert_equal(buf_text(b), "base\nbranchA\n")

    # Undo back to base and create alternate branchB
    _ = b.undo()
    assert_equal(buf_text(b), "base\n")
    _ = b.insert(1, 0, decode("branchB\n"), 1, 0, 2)
    assert_equal(buf_text(b), "base\nbranchB\n")

    # Tree lines must show branch
    var lines = b.undo_tree_lines()
    assert_equal(len(lines), 3)
    assert_true(lines[0].find("[branch 2]") >= 0)

    # g- (undo_earlier) steps chronologically to branchA (seq 1), then root (seq 0)
    var s1 = b.undo_earlier()
    assert_true(s1[0])
    assert_equal(buf_text(b), "base\nbranchA\n")
    var s0 = b.undo_earlier()
    assert_true(s0[0])
    assert_equal(buf_text(b), "base\n")
    assert_false(b.undo_earlier()[0])

    # g+ (undo_later) steps forward to branchA (seq 1), then branchB (seq 2)
    assert_true(b.undo_later()[0])
    assert_equal(buf_text(b), "base\nbranchA\n")
    assert_true(b.undo_later()[0])
    assert_equal(buf_text(b), "base\nbranchB\n")
    assert_false(b.undo_later()[0])

    # Direct jump to branchA node 1
    assert_true(b.undo_jump_to(1)[0])
    assert_equal(buf_text(b), "base\nbranchA\n")
    # Linear undo from branchA node 1 also works seamlessly
    _ = b.undo()
    assert_equal(buf_text(b), "base\n")
    _ = b.redo()
    assert_equal(buf_text(b), "base\nbranchA\n")


def test_tier2_f21_bound7_cell_folding_and_deprecated_mark() raises:
    """Verify # %% cell folding in TextBuffer and Mark.deprecated default arg."""
    var b = TextBuffer()
    b.load(decode("# %% Cell 1\nx = 1\ny = 2\n# %% Cell 2\nz = 3"))
    assert_true(b.foldable(0))
    assert_equal(b.block_end(0), 2)
    assert_true(b.foldable(3))
    assert_equal(b.block_end(3), 4)
    assert_true(b.set_fold(0, True))
    assert_equal(b.hidden_by(1), 0)
    assert_equal(b.hidden_by(2), 0)
    assert_equal(b.hidden_by(3), -1)

    var m1 = Mark(0, 0, 0, 5, 2, "warn")
    assert_false(m1.deprecated)
    var m2 = Mark(0, 0, 0, 5, 2, "old api", True)
    assert_true(m2.deprecated)


# ---------------------------------------------------------------------------
# Test Runner
# ---------------------------------------------------------------------------

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
