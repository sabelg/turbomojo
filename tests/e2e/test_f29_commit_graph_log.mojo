"""E2E Test Suite for Feature #29:
Commit Graph & History Browser (WK_GITLOG).
Scope: Interactive commit graph and history browser via `git log --graph`,
commit diff view, SHA extraction/copying, cherry-pick, and revert.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from window import WK_GITLOG
from git import (
    is_hex, is_uncommitted, ymd,
    CommitGraphNode, graph_log_command, parse_graph_log,
    commit_diff, cherry_pick, revert_commit,
)
from signals import own_pid
from util import (
    env_or, run_system, run_capture, shell_quote, str_bytes, bytes_to_str,
    write_file, read_file, path_exists, which, decode,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f29-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def git_cmd(d: String, args: String) -> Int:
    return run_system(
        "git -C "
        + shell_quote(d)
        + " -c user.name='LogTester' -c user.email='log@turbomojo.org' -c init.defaultBranch=main "
        + args
        + " >/dev/null 2>&1"
    )


def git_capture(d: String, args: String) -> String:
    var cap = run_capture("git -C " + shell_quote(d) + " " + args)
    return String(bytes_to_str(cap.out).strip())


# ---------------------------------------------------------------------------
# Tier 1: Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f29_case1_commit_graph_parser_single_branch() raises:
    """Verifies parsing of linear commit history with sha, author, timestamp, and summary."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c1_linear")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/a.txt", str_bytes("first\n"))
    assert_equal(git_cmd(d, "add a.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'feat: initial file'"), 0)

    _ = write_file(d + "/a.txt", str_bytes("first\nsecond\n"))
    assert_equal(git_cmd(d, "commit -am 'feat: second line'"), 0)

    var raw = git_capture(d, "log --graph --format=\"%h%x09%an%x09%at%x09%s%d\"")
    var nodes = parse_graph_log(raw)

    assert_equal(len(nodes), 2)
    assert_true(nodes[0].sha.byte_length() >= 7)
    assert_true(is_hex(nodes[0].sha))
    assert_equal(nodes[0].author, "LogTester")
    assert_equal(nodes[0].summary, "feat: second line")
    assert_true(nodes[0].timestamp > 1700000000)
    assert_true(nodes[0].decoration.find("HEAD") >= 0)

    assert_equal(nodes[1].summary, "feat: initial file")
    clean_scratch(d)


def test_tier1_f29_case2_commit_graph_branch_merge_lanes() raises:
    """Verifies parsing of branched history with lane bifurcation and merge commits."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c2_merge")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/root.txt", str_bytes("root\n"))
    assert_equal(git_cmd(d, "add root.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'root commit'"), 0)

    # Side branch
    assert_equal(git_cmd(d, "checkout -b feature"), 0)
    _ = write_file(d + "/feat.txt", str_bytes("feature content\n"))
    assert_equal(git_cmd(d, "add feat.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'add feature file'"), 0)

    # Main branch
    assert_equal(git_cmd(d, "checkout main"), 0)
    _ = write_file(d + "/main.txt", str_bytes("main content\n"))
    assert_equal(git_cmd(d, "add main.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'add main file'"), 0)

    # Merge
    assert_equal(git_cmd(d, "merge --no-ff feature -m 'merge feature into main'"), 0)

    var raw = git_capture(d, "log --graph --format=\"%h%x09%an%x09%at%x09%s%d\"")
    var nodes = parse_graph_log(raw)

    assert_true(len(nodes) >= 4)
    var seen_merge = False
    for n in nodes:
        if n.summary == "merge feature into main":
            seen_merge = True
    assert_true(seen_merge, "Merge commit must be parsed")
    clean_scratch(d)


def test_tier1_f29_case3_commit_diff_view_extraction() raises:
    """Verifies commit diff retrieval containing patch headers and hunk line changes."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c3_diff")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/diff_test.mojo", str_bytes("fn old_func():\n    pass\n"))
    assert_equal(git_cmd(d, "add diff_test.mojo"), 0)
    assert_equal(git_cmd(d, "commit -m 'v1'"), 0)

    _ = write_file(d + "/diff_test.mojo", str_bytes("def new_func():\n    print('updated')\n"))
    assert_equal(git_cmd(d, "commit -am 'v2: modernize syntax'"), 0)

    var head_sha = git_capture(d, "rev-parse --short HEAD")
    var diff_out = commit_diff(d, head_sha)

    assert_true(diff_out.find("diff --git a/diff_test.mojo b/diff_test.mojo") >= 0)
    assert_true(diff_out.find("-fn old_func():") >= 0)
    assert_true(diff_out.find("+def new_func():") >= 0)
    clean_scratch(d)


def test_tier1_f29_case4_cherry_pick_operation() raises:
    """Verifies interactive cherry-pick of a commit from another branch."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c4_cp")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/base.txt", str_bytes("base\n"))
    assert_equal(git_cmd(d, "add base.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'base'"), 0)

    assert_equal(git_cmd(d, "checkout -b experiment"), 0)
    _ = write_file(d + "/experiment.txt", str_bytes("experimental innovation\n"))
    assert_equal(git_cmd(d, "add experiment.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'add experiment'"), 0)
    var exp_sha = git_capture(d, "rev-parse HEAD")

    assert_equal(git_cmd(d, "checkout main"), 0)
    assert_false(path_exists(d + "/experiment.txt"))

    # Cherry-pick experiment commit onto main
    assert_equal(cherry_pick(d, exp_sha), 0)
    assert_true(path_exists(d + "/experiment.txt"))
    assert_equal(git_capture(d, "log -1 --format=%s"), "add experiment")
    clean_scratch(d)


def test_tier1_f29_case5_revert_commit_operation() raises:
    """Verifies interactive revert of an existing commit in history."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c5_revert")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/stable.txt", str_bytes("stable line\n"))
    assert_equal(git_cmd(d, "add stable.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'stable release'"), 0)

    _ = write_file(d + "/buggy.txt", str_bytes("introduced regression\n"))
    assert_equal(git_cmd(d, "add buggy.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'introduce regression'"), 0)
    var bad_sha = git_capture(d, "rev-parse HEAD")

    assert_true(path_exists(d + "/buggy.txt"))

    # Revert the regression commit
    assert_equal(revert_commit(d, bad_sha), 0)
    assert_false(path_exists(d + "/buggy.txt"))

    var latest_summary = git_capture(d, "log -1 --format=%s")
    assert_true(latest_summary.find("Revert \"introduce regression\"") >= 0)
    clean_scratch(d)


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Edge Cases
# ---------------------------------------------------------------------------

def test_tier2_f29_bound1_empty_repository_log() raises:
    """Verifies that an empty repository with zero commits produces an empty node list."""
    var empty_raw = String("")
    var nodes = parse_graph_log(empty_raw)
    assert_equal(len(nodes), 0)


def test_tier2_f29_bound2_initial_root_commit_diff() raises:
    """Verifies diff generation on initial root commit which has no parent commit."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b2_rootdiff")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/first.mojo", str_bytes("print('first')\n"))
    assert_equal(git_cmd(d, "add first.mojo"), 0)
    assert_equal(git_cmd(d, "commit -m 'root commit'"), 0)

    var root_sha = git_capture(d, "rev-parse HEAD")
    var diff_out = commit_diff(d, root_sha)

    assert_true(diff_out.find("diff --git") >= 0)
    assert_true(diff_out.find("+print('first')") >= 0)
    clean_scratch(d)


def test_tier2_f29_bound3_sha_copying_and_validation() raises:
    """Verifies SHA extraction, validation, and sanitization for clipboard copy."""
    var sample_line = "*   3f8a9bc\tTurboTest\t1700000000\tInitial setup (HEAD -> main)"
    var nodes = parse_graph_log(sample_line)
    assert_equal(len(nodes), 1)
    var sha = nodes[0].sha
    assert_equal(sha, "3f8a9bc")
    assert_true(is_hex(sha))
    assert_false(is_uncommitted(sha))

    # Lane symbols stripped cleanly
    var lane_only = "| /"
    var lane_nodes = parse_graph_log(lane_only)
    assert_equal(len(lane_nodes), 1)
    assert_equal(lane_nodes[0].sha, "")


def test_tier2_f29_bound4_cherry_pick_conflict_handling() raises:
    """Verifies that cherry-picking a conflicting commit fails gracefully with non-zero exit."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b4_cpconflict")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/conflict.txt", str_bytes("original version\n"))
    assert_equal(git_cmd(d, "add conflict.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'base version'"), 0)

    assert_equal(git_cmd(d, "checkout -b side"), 0)
    _ = write_file(d + "/conflict.txt", str_bytes("side change text\n"))
    assert_equal(git_cmd(d, "commit -am 'side commit'"), 0)
    var side_sha = git_capture(d, "rev-parse HEAD")

    assert_equal(git_cmd(d, "checkout main"), 0)
    _ = write_file(d + "/conflict.txt", str_bytes("divergent main text\n"))
    assert_equal(git_cmd(d, "commit -am 'main commit'"), 0)

    # Cherry-pick should fail due to conflict
    var cp_res = cherry_pick(d, side_sha)
    assert_true(cp_res != 0, "Cherry-pick on conflicting changes must return non-zero exit code")

    # Abort cleanly
    _ = run_system("git -C " + shell_quote(d) + " cherry-pick --abort >/dev/null 2>&1")
    clean_scratch(d)


def test_tier2_f29_bound5_unicode_commit_messages_and_tags() raises:
    """Verifies parsing of commit graph entries containing emojis, quotes, and tag decorations."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b5_unicode")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/unicode.txt", str_bytes("unicode content 🚀\n"))
    assert_equal(git_cmd(d, "add unicode.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'feat: add rocket 🚀 and quotes \"hello\"'"), 0)
    assert_equal(git_cmd(d, "tag -a v1.0.0 -m 'Release v1.0.0'"), 0)

    var raw = git_capture(d, "log --graph --format=\"%h%x09%an%x09%at%x09%s%d\"")
    var nodes = parse_graph_log(raw)

    assert_equal(len(nodes), 1)
    assert_true(nodes[0].summary.find("🚀") >= 0, "Emoji must be preserved in summary")
    assert_true(nodes[0].summary.find("\"hello\"") >= 0, "Quotes must be preserved")
    assert_true(nodes[0].decoration.find("tag: v1.0.0") >= 0, "Tag decoration must be present")
    assert_equal(WK_GITLOG, 19)
    assert_true(graph_log_command(d, "unicode.txt").find("unicode.txt") >= 0)
    assert_equal(ymd(1700000000).byte_length(), 10)
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
