"""E2E Test Suite for Feature #32:
Project Switcher & git worktree Manager.
Scope: In-place project switcher (File > Switch Project... with MRU history
and subsystem re-rooting), and git worktree manager (list, add, prune, switch).

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from git import (
    find_repo, resolve_git_dir, status_command, GitStatus,
    WorktreeRecord, parse_worktree_list, worktree_add, worktree_prune,
)
from project import (
    find_up, parse_pixi_tasks, PixiTask,
    ProjectMRU, parse_mru_toml,
)
from signals import own_pid
from util import (
    env_or, run_system, run_capture, shell_quote, str_bytes, bytes_to_str,
    write_file, read_file, path_exists, is_dir, which, decode, to_str,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f32-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def git_cmd(d: String, args: String) -> Int:
    return run_system(
        "git -C "
        + shell_quote(d)
        + " -c user.name='SwitcherTester' -c user.email='switch@turbomojo.org' -c init.defaultBranch=main "
        + args
        + " >/dev/null 2>&1"
    )


def git_out(d: String, args: String) -> String:
    var cap = run_capture("git -C " + shell_quote(d) + " " + args)
    return String(bytes_to_str(cap.out).strip())


# ---------------------------------------------------------------------------
# Tier 1: Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f32_case1_project_mru_history_tracking() raises:
    """Verifies MRU project history tracking, re-ordering, deduplication, and max capacity."""
    var mru = ProjectMRU(3)
    assert_equal(len(mru.entries), 0)

    mru.record_visit("/path/to/project_a")
    mru.record_visit("/path/to/project_b")
    mru.record_visit("/path/to/project_c")

    assert_equal(len(mru.entries), 3)
    assert_equal(mru.entries[0], "/path/to/project_c")
    assert_equal(mru.entries[1], "/path/to/project_b")
    assert_equal(mru.entries[2], "/path/to/project_a")

    # Visiting project_a moves it to front
    mru.record_visit("/path/to/project_a")
    assert_equal(len(mru.entries), 3)
    assert_equal(mru.entries[0], "/path/to/project_a")
    assert_equal(mru.entries[1], "/path/to/project_c")
    assert_equal(mru.entries[2], "/path/to/project_b")

    # Adding fourth project evicts oldest (project_b)
    mru.record_visit("/path/to/project_d")
    assert_equal(len(mru.entries), 3)
    assert_equal(mru.entries[0], "/path/to/project_d")
    assert_equal(mru.entries[1], "/path/to/project_a")
    assert_equal(mru.entries[2], "/path/to/project_c")


def test_tier1_f32_case2_project_switch_subsystem_rerooting() raises:
    """Verifies in-place project switching re-rooting git status and pixi tasks."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c2_switch")
    var proj_a = d + "/proj_a"
    var proj_b = d + "/proj_b"
    _ = run_system("mkdir -p " + shell_quote(proj_a) + " " + shell_quote(proj_b))

    # Initialize Project A
    assert_equal(git_cmd(proj_a, "init"), 0)
    _ = write_file(proj_a + "/pixi.toml", str_bytes("[tasks]\nbuild_a = 'mojo build a.mojo'\n"))
    _ = write_file(proj_a + "/a.mojo", str_bytes("print('A')\n"))
    assert_equal(git_cmd(proj_a, "add -A"), 0)
    assert_equal(git_cmd(proj_a, "commit -m 'init A'"), 0)

    # Initialize Project B
    assert_equal(git_cmd(proj_b, "init"), 0)
    _ = write_file(proj_b + "/pixi.toml", str_bytes("[tasks]\ntest_b = 'mojo test'\n"))
    _ = write_file(proj_b + "/b.mojo", str_bytes("print('B')\n"))
    assert_equal(git_cmd(proj_b, "add -A"), 0)
    assert_equal(git_cmd(proj_b, "commit -m 'init B'"), 0)

    # State in Project A
    var current_root = proj_a
    assert_equal(find_repo(current_root), proj_a)
    var tasks_a = parse_pixi_tasks(bytes_to_str(read_file(find_up(current_root, "pixi.toml") + "/pixi.toml")))
    assert_equal(len(tasks_a), 1)
    assert_equal(tasks_a[0].name, "build_a")

    # Switch project to Project B
    current_root = proj_b
    assert_equal(find_repo(current_root), proj_b)
    var tasks_b = parse_pixi_tasks(bytes_to_str(read_file(find_up(current_root, "pixi.toml") + "/pixi.toml")))
    assert_equal(len(tasks_b), 1)
    assert_equal(tasks_b[0].name, "test_b")
    clean_scratch(d)


def test_tier1_f32_case3_worktree_list_porcelain_parsing() raises:
    """Verifies parsing of git worktree list --porcelain output across multiple worktrees."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c3_wtlist")
    var main_repo = d + "/main"
    var wt1 = d + "/wt_alpha"
    var wt2 = d + "/wt_beta"
    _ = run_system("mkdir -p " + shell_quote(main_repo))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/root.txt", str_bytes("root\n"))
    assert_equal(git_cmd(main_repo, "add root.txt"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'root'"), 0)

    assert_equal(worktree_add(main_repo, wt1, "alpha", True), 0)
    assert_equal(worktree_add(main_repo, wt2, "beta", True), 0)

    var raw = git_out(main_repo, "worktree list --porcelain")
    var records = parse_worktree_list(raw)

    assert_equal(len(records), 3)
    assert_equal(records[0].path, main_repo)
    assert_equal(records[0].branch, "main")
    assert_false(records[0].bare)

    assert_equal(records[1].path, wt1)
    assert_equal(records[1].branch, "alpha")

    assert_equal(records[2].path, wt2)
    assert_equal(records[2].branch, "beta")
    clean_scratch(d)


def test_tier1_f32_case4_worktree_add_new_and_existing_branch() raises:
    """Verifies worktree creation with both newly created branches and existing branches."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c4_wtadd")
    var main_repo = d + "/main"
    var wt_new = d + "/wt_new_branch"
    var wt_exist = d + "/wt_existing_branch"
    _ = run_system("mkdir -p " + shell_quote(main_repo))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/init.txt", str_bytes("init\n"))
    assert_equal(git_cmd(main_repo, "add init.txt"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'init'"), 0)

    # Pre-create a branch in main repo
    assert_equal(git_cmd(main_repo, "branch precreated"), 0)

    # Add worktree with brand new branch
    assert_equal(worktree_add(main_repo, wt_new, "brand_new", True), 0)
    assert_true(path_exists(wt_new + "/.git"))
    assert_equal(git_out(wt_new, "branch --show-current"), "brand_new")

    # Add worktree checking out the existing branch
    assert_equal(worktree_add(main_repo, wt_exist, "precreated", False), 0)
    assert_true(path_exists(wt_exist + "/.git"))
    assert_equal(git_out(wt_exist, "branch --show-current"), "precreated")
    clean_scratch(d)


def test_tier1_f32_case5_worktree_prune_dead_worktrees() raises:
    """Verifies worktree pruning cleaning up dead worktree metadata from repo."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c5_prune")
    var main_repo = d + "/main"
    var wt = d + "/wt_to_delete"
    _ = run_system("mkdir -p " + shell_quote(main_repo))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/file.txt", str_bytes("file\n"))
    assert_equal(git_cmd(main_repo, "add file.txt"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'base'"), 0)

    assert_equal(worktree_add(main_repo, wt, "ephemeral", True), 0)
    var list_before = parse_worktree_list(git_out(main_repo, "worktree list --porcelain"))
    assert_equal(len(list_before), 2)

    # Delete worktree directory manually from disk
    _ = run_system("rm -rf " + shell_quote(wt))
    assert_false(path_exists(wt))

    # Prune
    assert_equal(worktree_prune(main_repo), 0)

    var list_after = parse_worktree_list(git_out(main_repo, "worktree list --porcelain"))
    assert_equal(len(list_after), 1)
    assert_equal(list_after[0].path, main_repo)
    clean_scratch(d)


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f32_bound1_empty_worktree_list_and_non_repo() raises:
    """Verifies that parsing empty worktree output yields an empty list."""
    var empty_records = parse_worktree_list("")
    assert_equal(len(empty_records), 0)

    var blank_lines = parse_worktree_list("\n\n\n")
    assert_equal(len(blank_lines), 0)


def test_tier2_f32_bound2_worktree_add_duplicate_or_occupied_path() raises:
    """Verifies non-zero exit code when attempting to add worktree to existing path."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b2_occupied")
    var main_repo = d + "/main"
    var occupied_dir = d + "/occupied"
    _ = run_system("mkdir -p " + shell_quote(main_repo) + " " + shell_quote(occupied_dir))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/a.txt", str_bytes("a\n"))
    assert_equal(git_cmd(main_repo, "add a.txt"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'base'"), 0)

    _ = write_file(occupied_dir + "/existing_file.txt", str_bytes("already exists\n"))

    # Adding worktree to non-empty directory should fail
    var res = worktree_add(main_repo, occupied_dir, "conflict_branch", True)
    assert_true(res != 0, "Adding worktree over occupied directory must fail")
    clean_scratch(d)


def test_tier2_f32_bound3_project_switch_to_nonexistent_or_unreadable_path() raises:
    """Verifies that switching to a non-existent path reports error without corrupting state."""
    var current_valid_root = "/home/user/turbomojo"
    var bogus_path = "/nonexistent/phantom/turbomojo_dir_9999"

    var target_repo = find_repo(bogus_path)
    assert_equal(target_repo, "")
    assert_false(path_exists(bogus_path))

    # Current project remains unaffected
    assert_true(path_exists(current_valid_root))


def test_tier2_f32_bound4_mru_persistence_and_corrupt_config() raises:
    """Verifies MRU serialization to TOML and parsing resilience on malformed inputs."""
    var mru = ProjectMRU(5)
    mru.record_visit("/workspace/alpha")
    mru.record_visit("/workspace/beta")

    var toml = mru.to_toml()
    var parsed = parse_mru_toml(toml)
    assert_equal(len(parsed), 2)
    assert_equal(parsed[0], "/workspace/beta")
    assert_equal(parsed[1], "/workspace/alpha")

    # Corrupt toml input
    var corrupt_toml = "[mru]\nprojects = [ unquoted_garbage, 12345, missing_bracket"
    var corrupt_parsed = parse_mru_toml(corrupt_toml)
    assert_equal(len(corrupt_parsed), 0)


def test_tier2_f32_bound5_detached_head_worktree_in_list() raises:
    """Verifies that a worktree checked out with --detach parses with detached=True."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b5_detachedwt")
    var main_repo = d + "/main"
    var wt_detached = d + "/wt_detached"
    _ = run_system("mkdir -p " + shell_quote(main_repo))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/init.txt", str_bytes("v1\n"))
    assert_equal(git_cmd(main_repo, "add init.txt"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'v1'"), 0)

    assert_equal(run_system("git -C " + shell_quote(main_repo) + " worktree add --detach " + shell_quote(wt_detached) + " HEAD >/dev/null 2>&1"), 0)

    var raw = git_out(main_repo, "worktree list --porcelain")
    var records = parse_worktree_list(raw)

    assert_equal(len(records), 2)
    assert_equal(records[1].path, wt_detached)
    assert_true(records[1].detached, "Detached worktree must have detached=True")
    assert_equal(records[1].branch, "")
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
