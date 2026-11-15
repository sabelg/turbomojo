"""E2E Test Suite for Feature #33:
Multi-File Agent Diff Queue & Per-Hunk Accept.
Covers multi-file agent diff review queue with '[' and ']' file navigation,
hunk-level diff staging/unstaging/reverting via with_hunk/without_hunk,
proposal approval/rejection lifecycle, and agent turn revert/review checkpoints.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from agentsvc import Proposal
from linediff import Hunk
from gitdiff import (
    Side, side_hunks, unified, with_hunk, without_hunk, hunk_at_line,
    DiffRow, DR_OLD, DR_NEW, DR_SAME,
)
from agent_diff import AgentProposalQueue, CheckpointEntry
from signals import own_pid
from swap import delete_file
from util import (
    env_or, run_system, shell_quote, str_bytes, bytes_to_str, read_file,
    write_file, path_exists, decode, to_str,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f33-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f33_case1_multi_file_queue_navigation() raises:
    """Verify queueing multiple file proposals and navigating between them via '[' and ']'."""
    var queue = AgentProposalQueue()
    queue.enqueue(Proposal("req1", "/tmp/a.mojo", "old_a", "new_a", True))
    queue.enqueue(Proposal("req2", "/tmp/b.mojo", "old_b", "new_b", True))
    queue.enqueue(Proposal("req3", "/tmp/c.mojo", "old_c", "new_c", True))

    assert_true(queue.active)
    assert_equal(len(queue.proposals), 3)
    assert_equal(queue.current_idx, 0)
    assert_equal(queue.current_proposal().path, "/tmp/a.mojo")

    # Navigate forward with ']'
    assert_true(queue.next_file())
    assert_equal(queue.current_idx, 1)
    assert_equal(queue.current_proposal().path, "/tmp/b.mojo")

    assert_true(queue.next_file())
    assert_equal(queue.current_idx, 2)
    assert_equal(queue.current_proposal().path, "/tmp/c.mojo")

    # At boundary, next_file returns False
    assert_false(queue.next_file())
    assert_equal(queue.current_idx, 2)

    # Navigate backward with '['
    assert_true(queue.prev_file())
    assert_equal(queue.current_idx, 1)
    assert_equal(queue.current_proposal().path, "/tmp/b.mojo")


def test_tier1_f33_case2_accept_proposal_writes_disk_and_advances() raises:
    """Verify accepting a proposal writes the new content and advances the queue."""
    var d = scratch("accept_adv")
    var p1 = d + "/file1.mojo"
    var p2 = d + "/file2.mojo"
    _ = write_file(p1, str_bytes("var x = 1\n"))
    _ = write_file(p2, str_bytes("var y = 2\n"))

    var queue = AgentProposalQueue()
    queue.enqueue(Proposal("req1", p1, "var x = 1\n", "var x = 100\n", True))
    queue.enqueue(Proposal("req2", p2, "var y = 2\n", "var y = 200\n", True))

    assert_true(queue.accept_current())
    assert_equal(bytes_to_str(read_file(p1)), "var x = 100\n")
    assert_equal(len(queue.proposals), 1)
    assert_equal(queue.current_proposal().path, p2)

    assert_true(queue.accept_current())
    assert_equal(bytes_to_str(read_file(p2)), "var y = 200\n")
    assert_false(queue.active)
    clean_scratch(d)


def test_tier1_f33_case3_reject_proposal_preserves_disk_and_advances() raises:
    """Verify rejecting a proposal leaves disk untouched and advances to next item."""
    var d = scratch("reject_pres")
    var p1 = d + "/keep.mojo"
    var p2 = d + "/next.mojo"
    _ = write_file(p1, str_bytes("original\n"))
    _ = write_file(p2, str_bytes("original 2\n"))

    var queue = AgentProposalQueue()
    queue.enqueue(Proposal("req1", p1, "original\n", "corrupted\n", True))
    queue.enqueue(Proposal("req2", p2, "original 2\n", "accepted 2\n", True))

    assert_true(queue.reject_current())
    assert_equal(bytes_to_str(read_file(p1)), "original\n")
    assert_equal(len(queue.proposals), 1)
    assert_equal(queue.current_proposal().path, p2)

    assert_true(queue.accept_current())
    assert_equal(bytes_to_str(read_file(p2)), "accepted 2\n")
    clean_scratch(d)


def test_tier1_f33_case4_per_hunk_with_hunk_and_without_hunk() raises:
    """Verify per-hunk transformations with_hunk (apply) and without_hunk (revert)."""
    var old_text = "line 1\nline 2\nline 3\nline 4\nline 5\n"
    var new_text = "line 1\nMODIFIED 2\nline 3\nMODIFIED 4\nline 5\n"

    var old_side = Side.of(old_text)
    var new_side = Side.of(new_text)

    var hunks = side_hunks(old_side, new_side)
    assert_equal(len(hunks), 2, "Expected exactly two distinct diff hunks")

    # Apply only hunk 0 onto old_side
    var with_hunk_0 = with_hunk(old_side, new_side, hunks[0])
    assert_equal(with_hunk_0.text(), "line 1\nMODIFIED 2\nline 3\nline 4\nline 5\n")

    # Revert hunk 0 from new_side
    var without_hunk_0 = without_hunk(old_side, new_side, hunks[0])
    assert_equal(without_hunk_0.text(), "line 1\nline 2\nline 3\nMODIFIED 4\nline 5\n")

    # Revert hunk 1 from new_side
    var without_hunk_1 = without_hunk(old_side, new_side, hunks[1])
    assert_equal(without_hunk_1.text(), "line 1\nMODIFIED 2\nline 3\nline 4\nline 5\n")

    # Test queue's per-hunk unstage method
    var queue = AgentProposalQueue()
    queue.enqueue(Proposal("req-hunk", "/tmp/hunk.mojo", old_text, new_text, True))
    assert_true(queue.unstage_hunk(0))
    assert_equal(queue.current_proposal().new, "line 1\nline 2\nline 3\nMODIFIED 4\nline 5\n")


def test_tier1_f33_case5_revert_turn_checkpoint_rollback() raises:
    """Verify revert_last_turn restores modified files and deletes newly created files."""
    var d = scratch("revert_turn")
    var p_mod = d + "/mod.mojo"
    var p_new = d + "/new.mojo"
    _ = write_file(p_mod, str_bytes("initial content\n"))

    var queue = AgentProposalQueue()
    queue.enqueue(Proposal("req1", p_mod, "initial content\n", "agent edit\n", True))
    queue.enqueue(Proposal("req2", p_new, "", "created file\n", False))

    # Accept both proposals
    queue.accept_all_session()
    assert_equal(bytes_to_str(read_file(p_mod)), "agent edit\n")
    assert_true(path_exists(p_new))

    # Roll back turn checkpoint
    var reverted = queue.revert_last_turn()
    assert_equal(reverted, 2)
    assert_equal(bytes_to_str(read_file(p_mod)), "initial content\n")
    assert_false(path_exists(p_new), "Created file should be deleted on revert")
    clean_scratch(d)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f33_bound1_empty_queue_safety() raises:
    """Verify operations on empty queue safely return without errors."""
    var queue = AgentProposalQueue()
    assert_false(queue.active)
    assert_false(queue.accept_current())
    assert_false(queue.reject_current())
    assert_false(queue.next_file())
    assert_false(queue.prev_file())
    assert_equal(queue.current_proposal().path, "")


def test_tier2_f33_bound2_revert_turn_with_no_snapshots() raises:
    """Verify revert_last_turn with zero checkpoints safely returns 0."""
    var queue = AgentProposalQueue()
    var count = queue.revert_last_turn()
    assert_equal(count, 0)


def test_tier2_f33_bound3_single_line_diff_hunk_boundaries() raises:
    """Verify hunk calculation on empty vs single-line addition."""
    var empty_side = Side.of("")
    var one_line = Side.of("hello\n")

    var hunks = side_hunks(empty_side, one_line)
    assert_equal(len(hunks), 1)
    assert_equal(hunks[0].a, 0)
    assert_equal(hunks[0].la, 0)
    assert_equal(hunks[0].b, 0)
    assert_equal(hunks[0].lb, 1)

    var diff_rows = unified(empty_side, one_line, hunks)
    assert_true(len(diff_rows) > 0)
    var found_add = False
    for r in diff_rows:
        if r.kind == DR_NEW:
            found_add = True
    assert_true(found_add, "Expected DR_NEW row for single-line addition")


def test_tier2_f33_bound4_accept_all_session_multiple_items() raises:
    """Verify accept_all_session consumes all queue items regardless of count."""
    var d = scratch("accept_all")
    var queue = AgentProposalQueue()

    for i in range(5):
        var p = d + "/file_" + String(i) + ".mojo"
        _ = write_file(p, str_bytes("old " + String(i) + "\n"))
        queue.enqueue(Proposal("req", p, "old " + String(i) + "\n", "new " + String(i) + "\n", True))

    assert_equal(len(queue.proposals), 5)
    queue.accept_all_session()

    assert_equal(len(queue.proposals), 0)
    assert_false(queue.active)

    for i in range(5):
        var p = d + "/file_" + String(i) + ".mojo"
        assert_equal(bytes_to_str(read_file(p)), "new " + String(i) + "\n")
    clean_scratch(d)


def test_tier2_f33_bound5_special_characters_and_binary_safety_in_diff() raises:
    """Verify diff engine handles unicode characters and whitespace differences without desync."""
    var old_s = Side.of("print('🔥 Mojo')\nvar s = \"abc\"\n")
    var new_s = Side.of("print('🔥 Mojo 1.2')\nvar s = \"abc\"\n")

    var hunks = side_hunks(old_s, new_s)
    assert_equal(len(hunks), 1)

    var applied = with_hunk(old_s, new_s, hunks[0])
    assert_equal(applied.text(), new_s.text())

    var reverted = without_hunk(old_s, new_s, hunks[0])
    assert_equal(reverted.text(), old_s.text())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
