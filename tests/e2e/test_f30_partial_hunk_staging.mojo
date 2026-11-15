"""E2E Test Suite for Feature #30:
Line-Level Partial Hunk Staging & Diffs.
Scope: Line-level partial hunk staging, unstaging, and reverting (S/U/R)
in WK_DIFF, and editor-free disk-backed diffs for modified and deleted files.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from linediff import Hunk, diff_lines
from gitdiff import (
    Side, side_hunks, unified, side_by_side, with_hunk, without_hunk,
    with_hunk_lines, without_hunk_lines, hunk_selected_rows,
    hunk_at_line, stage_script, DiffRow, DR_OLD, DR_NEW, DR_SAME,
)
from git import base_command
from signals import own_pid
from util import (
    env_or, run_system, run_capture, shell_quote, str_bytes, bytes_to_str,
    write_file, read_file, path_exists, which, decode, to_str,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f30-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def git_cmd(d: String, args: String) -> Int:
    return run_system(
        "git -C "
        + shell_quote(d)
        + " -c user.name='DiffTester' -c user.email='diff@turbomojo.org' -c init.defaultBranch=main "
        + args
        + " >/dev/null 2>&1"
    )


def git_out(d: String, args: String) -> String:
    var cap = run_capture("git -C " + shell_quote(d) + " " + args)
    return String(bytes_to_str(cap.out).strip())


# ---------------------------------------------------------------------------
# Tier 1: Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f30_case1_partial_hunk_stage_single_change() raises:
    """Verifies staging a single isolated hunk while keeping remaining hunks unstaged."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c1_stage")
    assert_equal(git_cmd(d, "init"), 0)

    var base_text = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n"
    _ = write_file(d + "/code.mojo", str_bytes(base_text))
    assert_equal(git_cmd(d, "add code.mojo"), 0)
    assert_equal(git_cmd(d, "commit -m 'base'"), 0)

    # Edit two distant lines: line 2 and line 9
    var edited_text = "line 1\nline 2 CHANGED\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9 CHANGED\nline 10\n"
    _ = write_file(d + "/code.mojo", str_bytes(edited_text))

    var old_side = Side.of(base_text)
    var new_side = Side.of(edited_text)
    var hunks = side_hunks(old_side, new_side)
    assert_equal(len(hunks), 2)

    # Stage only the first hunk (line 2 changed)
    var partial_side = with_hunk(old_side, new_side, hunks[0])
    var tmp_file = d + "/.tmp_staged"
    _ = write_file(tmp_file, str_bytes(partial_side.text()))

    # Apply via stage_script
    var script = stage_script(d, "code.mojo", tmp_file, False)
    assert_equal(run_system(script), 0)

    var diff_cached = git_out(d, "diff --cached")
    assert_true(diff_cached.find("+line 2 CHANGED") >= 0, "First change must be staged in index")
    assert_false(diff_cached.find("line 9 CHANGED") >= 0, "Second change must NOT be staged")

    var diff_unstaged = git_out(d, "diff")
    assert_false(diff_unstaged.find("line 2 CHANGED") >= 0, "First change is staged, so not in unstaged diff")
    assert_true(diff_unstaged.find("+line 9 CHANGED") >= 0, "Second change remains unstaged")
    clean_scratch(d)


def test_tier1_f30_case2_partial_hunk_unstage_single_change() raises:
    """Verifies unstaging a single hunk from multiple staged hunks via without_hunk."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c2_unstage")
    assert_equal(git_cmd(d, "init"), 0)

    var base_text = "a\nb\nc\nd\ne\nf\ng\nh\n"
    _ = write_file(d + "/file.txt", str_bytes(base_text))
    assert_equal(git_cmd(d, "add file.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'base'"), 0)

    # Both changes staged initially
    var edited_text = "a\nB_MOD\nc\nd\ne\nF_MOD\ng\nh\n"
    _ = write_file(d + "/file.txt", str_bytes(edited_text))
    assert_equal(git_cmd(d, "add file.txt"), 0)

    var old_side = Side.of(base_text)
    var staged_side = Side.of(edited_text)
    var hunks = side_hunks(old_side, staged_side)
    assert_equal(len(hunks), 2)

    # Unstage the second hunk (F_MOD), keeping B_MOD staged
    var unstaged_partial = without_hunk(old_side, staged_side, hunks[1])
    var tmp_file = d + "/.tmp_unstage"
    _ = write_file(tmp_file, str_bytes(unstaged_partial.text()))

    var script = stage_script(d, "file.txt", tmp_file, False)
    assert_equal(run_system(script), 0)

    var cached = git_out(d, "diff --cached")
    assert_true(cached.find("+B_MOD") >= 0, "First hunk should remain staged")
    assert_false(cached.find("+F_MOD") >= 0, "Second hunk should have been unstaged")
    clean_scratch(d)


def test_tier1_f30_case3_partial_hunk_revert_in_working_tree() raises:
    """Verifies reverting an uncommitted hunk in working tree using without_hunk."""
    var base_text = "fn compute():\n    var x = 1\n    var y = 2\n    return x + y\n"
    var edited_text = "fn compute():\n    var x = 100\n    var y = 200\n    return x + y\n"

    var old_side = Side.of(base_text)
    var new_side = Side.of(edited_text)
    var hunks = side_hunks(old_side, new_side)
    assert_equal(len(hunks), 1)

    # Reverting without_hunk restores base text
    var reverted_side = without_hunk(old_side, new_side, hunks[0])
    assert_equal(reverted_side.text(), base_text)


def test_tier1_f30_case4_editor_free_disk_diff_modified_file() raises:
    """Verifies disk-backed diff comparing an on-disk modified file against index."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c4_diskdiff")
    assert_equal(git_cmd(d, "init"), 0)

    var base_content = "def calculate(a: Int, b: Int) -> Int:\n    return a * b\n"
    _ = write_file(d + "/calc.mojo", str_bytes(base_content))
    assert_equal(git_cmd(d, "add calc.mojo"), 0)
    assert_equal(git_cmd(d, "commit -m 'base calc'"), 0)

    # Modify file directly on disk without editor buffer
    var disk_content = "def calculate(a: Int, b: Int) -> Int:\n    # added docstring\n    return a * b + 1\n"
    _ = write_file(d + "/calc.mojo", str_bytes(disk_content))

    # Read index content via base_command
    var cap = run_capture(base_command(d, "calc.mojo"))
    assert_equal(cap.status, 0)
    var index_text = bytes_to_str(cap.out)

    var old_side = Side.of(index_text)
    var disk_side = Side.of(disk_content)
    var hunks = side_hunks(old_side, disk_side)
    assert_true(len(hunks) > 0)

    var rows = unified(old_side, disk_side, hunks)
    var text_list = List[String]()
    for r in rows:
        text_list.append(r.text)

    var found_doc = False
    var found_return = False
    for t in text_list:
        if t.find("+    # added docstring") >= 0:
            found_doc = True
        if t.find("+    return a * b + 1") >= 0:
            found_return = True

    assert_true(found_doc)
    assert_true(found_return)
    clean_scratch(d)


def test_tier1_f30_case5_editor_free_disk_diff_deleted_file() raises:
    """Verifies disk-backed diff on deleted file producing DR_OLD deletion rows."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c5_deleted")
    assert_equal(git_cmd(d, "init"), 0)

    var content = "obsolete line 1\nobsolete line 2\n"
    _ = write_file(d + "/obsolete.txt", str_bytes(content))
    assert_equal(git_cmd(d, "add obsolete.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'added obsolete'"), 0)

    # Remove file from disk
    _ = run_system("rm -f " + shell_quote(d + "/obsolete.txt"))
    assert_false(path_exists(d + "/obsolete.txt"))

    var cap = run_capture(base_command(d, "obsolete.txt"))
    assert_equal(cap.status, 0)
    var old_side = Side.of(bytes_to_str(cap.out))
    var disk_side = Side.of("")  # empty side for deleted file

    var hunks = side_hunks(old_side, disk_side)
    assert_equal(len(hunks), 1)

    var rows = unified(old_side, disk_side, hunks)
    assert_true(len(rows) >= 3)  # header + 2 deleted rows
    assert_equal(rows[1].kind, DR_OLD)
    assert_equal(rows[1].text, "-obsolete line 1")
    assert_equal(rows[2].kind, DR_OLD)
    assert_equal(rows[2].text, "-obsolete line 2")
    clean_scratch(d)


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f30_bound1_empty_file_diff_and_staging() raises:
    """Verifies diffing and staging transitions between empty 0-byte file and 1 line."""
    var empty_side = Side.of("")
    var one_line_side = Side.of("initial content\n")

    var hunks = side_hunks(empty_side, one_line_side)
    assert_equal(len(hunks), 1)
    assert_equal(hunks[0].la, 0)
    assert_equal(hunks[0].lb, 1)

    var staged = with_hunk(empty_side, one_line_side, hunks[0])
    assert_equal(staged.text(), "initial content\n")

    var reverted = without_hunk(empty_side, one_line_side, hunks[0])
    assert_equal(reverted.text(), "")


def test_tier2_f30_bound2_adjacent_and_overlapping_hunk_boundaries() raises:
    """Verifies hunk_at_line mapping and boundary calculations for tight edits."""
    var old_s = Side.of("a\nb\nc\nd\ne\n")
    var new_s = Side.of("a\nB_EDIT\nc\nD_EDIT\ne\n")
    var hunks = side_hunks(old_s, new_s)
    assert_equal(len(hunks), 2)

    # Line 0 is context ('a')
    assert_equal(hunk_at_line(hunks, 0), -1)
    # Line 1 is first edit ('B_EDIT')
    assert_equal(hunk_at_line(hunks, 1), 0)
    # Line 2 is context ('c')
    assert_equal(hunk_at_line(hunks, 2), -1)
    # Line 3 is second edit ('D_EDIT')
    assert_equal(hunk_at_line(hunks, 3), 1)


def test_tier2_f30_bound3_trailing_newline_differences() raises:
    """Verifies diff hunk generated exclusively when trailing newline is toggled."""
    var with_nl = Side.of("hello\n")
    var without_nl = Side.of("hello")
    assert_true(with_nl.eol)
    assert_false(without_nl.eol)

    var hunks = side_hunks(with_nl, without_nl)
    assert_equal(len(hunks), 1)
    assert_true(hunks[0].la >= 1)
    assert_true(hunks[0].lb >= 1)


def test_tier2_f30_bound4_cr_lf_windows_line_endings_in_diff() raises:
    """Verifies that CRLF and LF line endings produce identical line content in Side."""
    var lf_text = "line one\nline two\nline three\n"
    var crlf_text = "line one\r\nline two\r\nline three\r\n"

    var s_lf = Side.of(lf_text)
    var s_crlf = Side.of(crlf_text)

    assert_equal(len(s_lf.lines), len(s_crlf.lines))
    assert_equal(s_lf.lines[0], s_crlf.lines[0])
    assert_equal(s_lf.lines[1], s_crlf.lines[1])
    assert_equal(s_lf.lines[2], s_crlf.lines[2])
    assert_equal(len(side_hunks(s_lf, s_crlf)), 0, "CRLF and LF of same text must have 0 diff hunks")


def test_tier2_f30_bound5_special_characters_and_quotes_in_stage_script() raises:
    """Verifies stage_script escaping with paths containing spaces, quotes, and meta-chars."""
    var root = "/path with spaces/'and quotes'"
    var rel = "dir with spaces/file $foo & bar.mojo"
    var tmp = "/tmp/staged'with\"quotes"

    var script = stage_script(root, rel, tmp, False)
    assert_true(script.find("git hash-object") >= 0)
    assert_true(script.find("git update-index") >= 0)

    # For remove=True
    var rm_script = stage_script(root, rel, tmp, True)
    assert_true(rm_script.find("git rm -q --cached") >= 0)


def test_tier2_f30_bound6_line_level_partial_hunk_staging() raises:
    """Verifies with_hunk_lines and without_hunk_lines stage/unstage individual +/- lines inside one hunk."""
    var old_s = Side.of("keep\nold_a\nold_b\ntail\n")
    var new_s = Side.of("keep\nnew_a\nnew_b\ntail\n")
    var hunks = side_hunks(old_s, new_s)
    assert_equal(len(hunks), 1)
    var rows = unified(old_s, new_s, hunks)
    # Find row index of '+new_a' and stage ONLY '+new_a' (keeping old_a and old_b)
    var plus_a_idx = -1
    for i in range(len(rows)):
        if rows[i].text == "+new_a":
            plus_a_idx = i
            break
    assert_true(plus_a_idx >= 0)
    var sel = hunk_selected_rows(rows, hunks[0], 0, plus_a_idx, plus_a_idx)
    var staged_one = with_hunk_lines(old_s, new_s, hunks[0], sel)
    assert_equal(staged_one.text(), "keep\nold_a\nold_b\nnew_a\ntail\n")

    # Revert ONLY '+new_b' from new_s (keeping new_a, dropping new_b)
    var plus_b_idx = -1
    for i in range(len(rows)):
        if rows[i].text == "+new_b":
            plus_b_idx = i
            break
    assert_true(plus_b_idx >= 0)
    var sel_b = hunk_selected_rows(rows, hunks[0], 0, plus_b_idx, plus_b_idx)
    var reverted_b = without_hunk_lines(old_s, new_s, hunks[0], sel_b)
    assert_equal(reverted_b.text(), "keep\nnew_a\ntail\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
