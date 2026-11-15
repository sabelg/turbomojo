"""E2E Test Suite for Feature #5:
Worktree & Submodule Git Index / inotify.
Scope: Git status polling and inotify watches in linked git worktrees and
submodules by resolving `gitdir:` pointers and `commondir`.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from git import (
    find_repo, resolve_git_dir, rel_to, status_command, GitStatus,
    GS_NONE, GS_UNTRACKED, GS_MODIFIED, GS_ADDED, status_letter,
)
from watch import file_sig, FileSig
from signals import own_pid
from util import (
    env_or, run_system, run_capture, shell_quote, str_bytes, bytes_to_str,
    read_file, write_file, path_exists, is_dir, join_path, which,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f05-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def git_cmd(d: String, args: String) -> Int:
    return run_system(
        "git -C "
        + shell_quote(d)
        + " -c user.name='TurboTest' -c user.email='test@turbomojo.org' -c init.defaultBranch=main "
        + args
        + " >/dev/null 2>&1"
    )


# ---------------------------------------------------------------------------
# Tier 1: Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f05_case1_standard_repo_resolve_git_dir() raises:
    """Verifies that a standard repo resolves (root/.git, root/.git) with valid index."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c1_std")
    assert_equal(git_cmd(d, "init"), 0)
    _ = write_file(d + "/hello.mojo", str_bytes("def main():\n    print('hello')\n"))
    assert_equal(git_cmd(d, "add hello.mojo"), 0)
    assert_equal(git_cmd(d, "commit -m 'initial commit'"), 0)

    var res = resolve_git_dir(d)
    var expected_git = join_path(d, ".git")
    assert_equal(res[0], expected_git)
    assert_equal(res[1], expected_git)
    assert_true(path_exists(join_path(res[0], "index")))
    assert_equal(find_repo(d), d)
    assert_equal(find_repo(d + "/hello.mojo"), d)
    clean_scratch(d)


def test_tier1_f05_case2_linked_worktree_resolve_gitdir_and_commondir() raises:
    """Verifies that a linked git worktree resolves gitdir and commondir back to main repo."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c2_wt")
    var main_repo = d + "/main_repo"
    var wt_repo = d + "/wt_branch"
    _ = run_system("mkdir -p " + shell_quote(main_repo))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/root.mojo", str_bytes("var x = 1\n"))
    assert_equal(git_cmd(main_repo, "add root.mojo"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'root commit'"), 0)

    # Create linked worktree
    assert_equal(git_cmd(main_repo, "worktree add -b feat_wt " + shell_quote(wt_repo)), 0)
    assert_true(path_exists(wt_repo + "/.git"))
    assert_false(is_dir(wt_repo + "/.git"))  # .git is a pointer file

    var dirs = resolve_git_dir(wt_repo)
    var gitdir = dirs[0]
    var commondir = dirs[1]

    assert_true(gitdir.find("worktrees") >= 0, "gitdir must point to worktrees dir: " + gitdir)
    assert_true(path_exists(join_path(gitdir, "index")), "worktree must possess dedicated index")
    assert_true(path_exists(join_path(gitdir, "HEAD")), "worktree must possess dedicated HEAD")
    assert_equal(commondir, join_path(main_repo, ".git"))
    assert_equal(find_repo(wt_repo), wt_repo)
    clean_scratch(d)


def test_tier1_f05_case3_worktree_git_status_polling() raises:
    """Verifies status polling and GitStatus parsing in a linked worktree with changes."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c3_poll")
    var main_repo = d + "/main"
    var wt_repo = d + "/wt"
    _ = run_system("mkdir -p " + shell_quote(main_repo))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/base.txt", str_bytes("line 1\nline 2\n"))
    assert_equal(git_cmd(main_repo, "add base.txt"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'initial'"), 0)
    assert_equal(git_cmd(main_repo, "worktree add -b dev_branch " + shell_quote(wt_repo)), 0)

    # In worktree, modify tracked file and create untracked file
    _ = write_file(wt_repo + "/base.txt", str_bytes("line 1\nline 2 modified\n"))
    _ = write_file(wt_repo + "/untracked.mojo", str_bytes("var wt_untracked = True\n"))

    var cmd = status_command(wt_repo)
    var cap = run_capture(cmd)
    assert_equal(cap.status, 0)

    var st = GitStatus()
    st.root = wt_repo
    st.parse(bytes_to_str(cap.out))

    assert_equal(st.branch, "dev_branch")
    assert_equal(st.code_of(wt_repo + "/base.txt"), GS_MODIFIED)
    assert_equal(st.code_of(wt_repo + "/untracked.mojo"), GS_UNTRACKED)
    assert_equal(status_letter(st.code_of(wt_repo + "/base.txt")), "M")
    assert_equal(status_letter(st.code_of(wt_repo + "/untracked.mojo")), "U")
    clean_scratch(d)


def test_tier1_f05_case4_submodule_gitdir_resolution() raises:
    """Verifies submodule gitdir pointer resolution pointing to .git/modules/<name>."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c4_subm")
    var upstream = d + "/sub_upstream"
    var superproj = d + "/superproj"
    _ = run_system("mkdir -p " + shell_quote(upstream) + " " + shell_quote(superproj))

    assert_equal(git_cmd(upstream, "init"), 0)
    _ = write_file(upstream + "/lib.mojo", str_bytes("def helper(): pass\n"))
    assert_equal(git_cmd(upstream, "add lib.mojo"), 0)
    assert_equal(git_cmd(upstream, "commit -m 'submodule initial'"), 0)

    assert_equal(git_cmd(superproj, "init"), 0)
    _ = write_file(superproj + "/main.mojo", str_bytes("def main(): pass\n"))
    assert_equal(git_cmd(superproj, "add main.mojo"), 0)
    assert_equal(git_cmd(superproj, "commit -m 'super initial'"), 0)

    # Add submodule
    assert_equal(
        run_system("git -c protocol.file.allow=always -C " + shell_quote(superproj)
                   + " submodule add " + shell_quote(upstream) + " deps/sublib >/dev/null 2>&1"),
        0,
    )
    var subm_path = superproj + "/deps/sublib"
    assert_true(path_exists(subm_path + "/.git"))
    assert_false(is_dir(subm_path + "/.git"))

    var dirs = resolve_git_dir(subm_path)
    assert_true(dirs[0].find("modules") >= 0, "gitdir should point to modules dir: " + dirs[0])
    assert_true(path_exists(join_path(dirs[0], "index")))
    assert_equal(find_repo(subm_path), subm_path)
    clean_scratch(d)


def test_tier1_f05_case5_worktree_index_watch_signature_change() raises:
    """Verifies that staging a file in a worktree modifies the resolved index file signature."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c5_sig")
    var main_repo = d + "/main"
    var wt_repo = d + "/wt"
    _ = run_system("mkdir -p " + shell_quote(main_repo))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/init.txt", str_bytes("hello\n"))
    assert_equal(git_cmd(main_repo, "add init.txt"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'init'"), 0)
    assert_equal(git_cmd(main_repo, "worktree add -b wt_sig " + shell_quote(wt_repo)), 0)

    var dirs = resolve_git_dir(wt_repo)
    var wt_index = join_path(dirs[0], "index")
    assert_true(path_exists(wt_index))

    var sig_before = file_sig(wt_index)
    _ = write_file(wt_repo + "/added.mojo", str_bytes("var staged = 42\n"))
    assert_equal(git_cmd(wt_repo, "add added.mojo"), 0)

    var sig_after = file_sig(wt_index)
    assert_false(sig_before.same(sig_after), "Index file signature must change after git add")
    clean_scratch(d)


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Edge Cases
# ---------------------------------------------------------------------------

def test_tier2_f05_bound1_empty_or_malformed_gitdir_file() raises:
    """Verifies that an empty or malformed .git file returns ('', '') safely."""
    var d = scratch("t2_b1_malformed")
    _ = write_file(d + "/.git", str_bytes(""))
    var res_empty = resolve_git_dir(d)
    assert_equal(res_empty[0], "")
    assert_equal(res_empty[1], "")

    _ = write_file(d + "/.git", str_bytes("invalid pointer without prefix\n"))
    var res_invalid = resolve_git_dir(d)
    assert_equal(res_invalid[0], "")
    assert_equal(res_invalid[1], "")
    clean_scratch(d)


def test_tier2_f05_bound2_nonexistent_target_gitdir() raises:
    """Verifies that a .git pointing to a non-existent path returns ('', '')."""
    var d = scratch("t2_b2_nonexistent")
    _ = write_file(d + "/.git", str_bytes("gitdir: /tmp/nonexistent_path_turbomojo_12345/nowhere\n"))
    var res = resolve_git_dir(d)
    assert_equal(res[0], "")
    assert_equal(res[1], "")
    clean_scratch(d)


def test_tier2_f05_bound3_nested_submodule_relative_paths() raises:
    """Verifies resolution of relative gitdir pointer containing parent directory traversal."""
    var d = scratch("t2_b3_relative")
    var target_gitdir = d + "/super/.git/modules/sub1/modules/sub2"
    var submodule_dir = d + "/super/sub1/sub2"
    _ = run_system("mkdir -p " + shell_quote(target_gitdir) + " " + shell_quote(submodule_dir))
    _ = write_file(target_gitdir + "/index", str_bytes("dummy index content\n"))

    # relative pointer from super/sub1/sub2/.git to super/.git/modules/sub1/modules/sub2
    _ = write_file(submodule_dir + "/.git", str_bytes("gitdir: ../../.git/modules/sub1/modules/sub2\n"))

    var res = resolve_git_dir(submodule_dir)
    assert_equal(res[0], target_gitdir)
    assert_equal(res[1], target_gitdir)
    clean_scratch(d)


def test_tier2_f05_bound4_commondir_relative_traversal() raises:
    """Verifies relative commondir resolution with ../.. traversing to parent repo."""
    var d = scratch("t2_b4_commondir")
    var main_git = d + "/repo/.git"
    var wt_gitdir = main_git + "/worktrees/wt_feature"
    var wt_worktree = d + "/wt_feature"
    _ = run_system("mkdir -p " + shell_quote(wt_gitdir) + " " + shell_quote(wt_worktree))

    _ = write_file(wt_worktree + "/.git", str_bytes("gitdir: " + wt_gitdir + "\n"))
    _ = write_file(wt_gitdir + "/commondir", str_bytes("../..\n"))
    _ = write_file(wt_gitdir + "/index", str_bytes("index data\n"))

    var res = resolve_git_dir(wt_worktree)
    assert_equal(res[0], wt_gitdir)
    assert_equal(res[1], main_git)
    clean_scratch(d)


def test_tier2_f05_bound5_detached_head_worktree_status() raises:
    """Verifies that a worktree created with detached HEAD parses correctly."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b5_detached")
    var main_repo = d + "/main"
    var wt_repo = d + "/wt_detached"
    _ = run_system("mkdir -p " + shell_quote(main_repo))

    assert_equal(git_cmd(main_repo, "init"), 0)
    _ = write_file(main_repo + "/init.mojo", str_bytes("var v = 100\n"))
    assert_equal(git_cmd(main_repo, "add init.mojo"), 0)
    assert_equal(git_cmd(main_repo, "commit -m 'first commit'"), 0)

    # Detached worktree
    assert_equal(git_cmd(main_repo, "worktree add --detach " + shell_quote(wt_repo) + " HEAD"), 0)

    var res = resolve_git_dir(wt_repo)
    assert_true(res[0].byte_length() > 0)
    assert_true(path_exists(join_path(res[0], "index")))

    var cap = run_capture(status_command(wt_repo))
    assert_equal(cap.status, 0)

    var st = GitStatus()
    st.root = wt_repo
    st.parse(bytes_to_str(cap.out))
    assert_equal(st.branch, "(detached)")
    assert_equal(st.changed_count(), 0)
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
