"""E2E Test Suite for Feature #31:
Async Remote Sync & Stash Picker.
Scope: Async background remote sync (Push P, Pull --rebase p, Fetch --prune F),
and interactive Stash List picker with preview, apply, pop, drop, and named push.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from git import (
    StashEntry, parse_stash_list, remote_sync_script,
    stash_push_script, stash_apply_script, stash_pop_script,
    stash_drop_script, stash_preview,
)
from signals import own_pid
from util import (
    env_or, run_system, run_capture, shell_quote, str_bytes, bytes_to_str,
    write_file, read_file, path_exists, which, decode, to_str,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f31-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def git_cmd(d: String, args: String) -> Int:
    return run_system(
        "git -C "
        + shell_quote(d)
        + " -c user.name='SyncTester' -c user.email='sync@turbomojo.org' -c init.defaultBranch=main "
        + args
        + " >/dev/null 2>&1"
    )


def git_out(d: String, args: String) -> String:
    var cap = run_capture("git -C " + shell_quote(d) + " " + args)
    return String(bytes_to_str(cap.out).strip())


# ---------------------------------------------------------------------------
# Tier 1: Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f31_case1_remote_push_to_bare_upstream() raises:
    """Verifies async remote Push (P) syncing commits to a bare upstream repository."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c1_push")
    var remote_dir = d + "/upstream.git"
    var local_dir = d + "/local"
    _ = run_system("mkdir -p " + shell_quote(remote_dir) + " " + shell_quote(local_dir))

    assert_equal(run_system("git init --bare -b main " + shell_quote(remote_dir) + " >/dev/null 2>&1"), 0)
    assert_equal(git_cmd(local_dir, "init"), 0)
    assert_equal(git_cmd(local_dir, "remote add origin " + shell_quote(remote_dir)), 0)

    _ = write_file(local_dir + "/code.mojo", str_bytes("def main(): print('remote ready')\n"))
    assert_equal(git_cmd(local_dir, "add code.mojo"), 0)
    assert_equal(git_cmd(local_dir, "commit -m 'initial release'"), 0)

    # Push to remote
    var push_cmd = remote_sync_script(local_dir, "P", "origin", "main")
    assert_equal(run_system(push_cmd + " >/dev/null 2>&1"), 0)

    # Verify upstream received commit
    var upstream_head = git_out(remote_dir, "rev-parse refs/heads/main")
    var local_head = git_out(local_dir, "rev-parse HEAD")
    assert_equal(upstream_head, local_head)
    clean_scratch(d)


def test_tier1_f31_case2_remote_fetch_prune_and_pull_rebase() raises:
    """Verifies Fetch --prune (F) and Pull --rebase (p) integrating upstream changes."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c2_sync")
    var remote_dir = d + "/upstream.git"
    var clone1 = d + "/clone1"
    var clone2 = d + "/clone2"
    _ = run_system("mkdir -p " + shell_quote(remote_dir) + " " + shell_quote(clone1))

    assert_equal(run_system("git init --bare -b main " + shell_quote(remote_dir) + " >/dev/null 2>&1"), 0)
    assert_equal(git_cmd(clone1, "init"), 0)
    assert_equal(git_cmd(clone1, "remote add origin " + shell_quote(remote_dir)), 0)

    _ = write_file(clone1 + "/init.txt", str_bytes("init\n"))
    assert_equal(git_cmd(clone1, "add init.txt"), 0)
    assert_equal(git_cmd(clone1, "commit -m 'initial'"), 0)
    assert_equal(git_cmd(clone1, "push -u origin main"), 0)

    assert_equal(run_system("git clone " + shell_quote(remote_dir) + " " + shell_quote(clone2) + " >/dev/null 2>&1"), 0)
    _ = git_cmd(clone2, "config user.name 'SyncTester'")
    _ = git_cmd(clone2, "config user.email 'sync@turbomojo.org'")

    # Clone1 pushes an upstream commit
    _ = write_file(clone1 + "/upstream_feat.txt", str_bytes("upstream work\n"))
    assert_equal(git_cmd(clone1, "add -A"), 0)
    assert_equal(git_cmd(clone1, "commit -m 'upstream work'"), 0)
    assert_equal(git_cmd(clone1, "push origin main"), 0)

    # Clone2 commits a local change
    _ = write_file(clone2 + "/local_feat.txt", str_bytes("local work\n"))
    assert_equal(git_cmd(clone2, "add local_feat.txt"), 0)
    assert_equal(git_cmd(clone2, "commit -m 'local work'"), 0)

    # Clone2 runs fetch --prune
    var fetch_cmd = remote_sync_script(clone2, "F", "origin")
    assert_equal(run_system(fetch_cmd + " >/dev/null 2>&1"), 0)

    # Clone2 runs pull --rebase
    var pull_cmd = remote_sync_script(clone2, "p", "origin", "main")
    assert_equal(run_system(pull_cmd + " >/dev/null 2>&1"), 0)

    # Verify linear rebase history (no merge commit)
    var log_output = git_out(clone2, "log --oneline")
    assert_true(log_output.find("local work") >= 0)
    assert_true(log_output.find("upstream work") >= 0)
    assert_false(log_output.find("Merge") >= 0)
    clean_scratch(d)


def test_tier1_f31_case3_stash_push_and_list_parsing() raises:
    """Verifies named stash push with untracked files and parsing stash list entries."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c3_stash")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/base.txt", str_bytes("base content\n"))
    assert_equal(git_cmd(d, "add base.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'init'"), 0)

    # Modify tracked and create untracked
    _ = write_file(d + "/base.txt", str_bytes("modified in working tree\n"))
    _ = write_file(d + "/untracked.mojo", str_bytes("var untracked = True\n"))

    var push_cmd = stash_push_script(d, "wip: authentication flow", True)
    assert_equal(run_system(push_cmd + " >/dev/null 2>&1"), 0)

    # Working tree should now be clean
    assert_equal(git_out(d, "status --porcelain"), "")

    var list_raw = git_out(d, "stash list")
    var entries = parse_stash_list(list_raw)
    assert_equal(len(entries), 1)
    assert_equal(entries[0].index, 0)
    assert_equal(entries[0].stash_ref, "stash@{0}")
    assert_true(entries[0].message.find("wip: authentication flow") >= 0)
    clean_scratch(d)


def test_tier1_f31_case4_stash_preview_and_apply() raises:
    """Verifies stash diff preview and applying stash without dropping it."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c4_apply")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/app.mojo", str_bytes("fn start(): pass\n"))
    assert_equal(git_cmd(d, "add app.mojo"), 0)
    assert_equal(git_cmd(d, "commit -m 'base app'"), 0)

    _ = write_file(d + "/app.mojo", str_bytes("def start():\n    print('applied')\n"))
    assert_equal(run_system(stash_push_script(d, "experiment: print update") + " >/dev/null 2>&1"), 0)

    # Preview diff of stash
    var preview = stash_preview(d, 0)
    assert_true(preview.find("+    print('applied')") >= 0)

    # Apply stash without dropping
    assert_equal(run_system(stash_apply_script(d, 0) + " >/dev/null 2>&1"), 0)

    var modified_content = bytes_to_str(read_file(d + "/app.mojo"))
    assert_true(modified_content.find("print('applied')") >= 0)

    # Stash entry still exists in stash list
    var entries = parse_stash_list(git_out(d, "stash list"))
    assert_equal(len(entries), 1)
    clean_scratch(d)


def test_tier1_f31_case5_stash_pop_and_drop() raises:
    """Verifies popping a stash entry and dropping a stash entry cleanly."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t1_c5_popdrop")
    assert_equal(git_cmd(d, "init"), 0)

    _ = write_file(d + "/file1.txt", str_bytes("one\n"))
    _ = write_file(d + "/file2.txt", str_bytes("two\n"))
    assert_equal(git_cmd(d, "add -A"), 0)
    assert_equal(git_cmd(d, "commit -m 'base'"), 0)

    # Push stash 1
    _ = write_file(d + "/file1.txt", str_bytes("one modified\n"))
    assert_equal(run_system(stash_push_script(d, "stash number one") + " >/dev/null 2>&1"), 0)

    # Push stash 2
    _ = write_file(d + "/file2.txt", str_bytes("two modified\n"))
    assert_equal(run_system(stash_push_script(d, "stash number two") + " >/dev/null 2>&1"), 0)

    var entries_before = parse_stash_list(git_out(d, "stash list"))
    assert_equal(len(entries_before), 2)

    # Pop latest stash (stash@{0})
    assert_equal(run_system(stash_pop_script(d, 0) + " >/dev/null 2>&1"), 0)
    assert_equal(bytes_to_str(read_file(d + "/file2.txt")), "two modified\n")

    var entries_after_pop = parse_stash_list(git_out(d, "stash list"))
    assert_equal(len(entries_after_pop), 1)

    # Drop remaining stash
    assert_equal(run_system(stash_drop_script(d, 0) + " >/dev/null 2>&1"), 0)
    var entries_after_drop = parse_stash_list(git_out(d, "stash list"))
    assert_equal(len(entries_after_drop), 0)
    clean_scratch(d)


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f31_bound1_empty_stash_list_operations() raises:
    """Verifies that operations on empty stash list handle gracefully without crash."""
    var empty_list = parse_stash_list("")
    assert_equal(len(empty_list), 0)

    var whitespace_list = parse_stash_list("\n   \n\t\n")
    assert_equal(len(whitespace_list), 0)


def test_tier2_f31_bound2_push_rejected_non_fast_forward() raises:
    """Verifies non-zero exit code when push is rejected due to divergent remote history."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b2_pushreject")
    var remote_dir = d + "/upstream.git"
    var clone1 = d + "/c1"
    var clone2 = d + "/c2"
    _ = run_system("mkdir -p " + shell_quote(remote_dir) + " " + shell_quote(clone1))

    assert_equal(run_system("git init --bare -b main " + shell_quote(remote_dir) + " >/dev/null 2>&1"), 0)
    assert_equal(git_cmd(clone1, "init"), 0)
    assert_equal(git_cmd(clone1, "remote add origin " + shell_quote(remote_dir)), 0)

    _ = write_file(clone1 + "/base.txt", str_bytes("base\n"))
    assert_equal(git_cmd(clone1, "add base.txt"), 0)
    assert_equal(git_cmd(clone1, "commit -m 'base'"), 0)
    assert_equal(git_cmd(clone1, "push -u origin main"), 0)

    assert_equal(run_system("git clone " + shell_quote(remote_dir) + " " + shell_quote(clone2) + " >/dev/null 2>&1"), 0)
    _ = git_cmd(clone2, "config user.name 'SyncTester'")
    _ = git_cmd(clone2, "config user.email 'sync@turbomojo.org'")

    # Both clones make divergent commits
    _ = write_file(clone1 + "/a.txt", str_bytes("a\n"))
    assert_equal(git_cmd(clone1, "add a.txt"), 0)
    assert_equal(git_cmd(clone1, "commit -m 'divergent a'"), 0)
    assert_equal(git_cmd(clone1, "push origin main"), 0)

    _ = write_file(clone2 + "/b.txt", str_bytes("b\n"))
    assert_equal(git_cmd(clone2, "add b.txt"), 0)
    assert_equal(git_cmd(clone2, "commit -m 'divergent b'"), 0)

    # Clone2 push should fail without force
    var res = run_system(remote_sync_script(clone2, "P", "origin", "main") + " >/dev/null 2>&1")
    assert_true(res != 0, "Non-fast-forward push must return non-zero exit code")
    clean_scratch(d)


def test_tier2_f31_bound3_pull_rebase_conflict() raises:
    """Verifies non-zero exit code and conflict detection during pull --rebase."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b3_pullconflict")
    var remote_dir = d + "/upstream.git"
    var clone1 = d + "/c1"
    var clone2 = d + "/c2"
    _ = run_system("mkdir -p " + shell_quote(remote_dir) + " " + shell_quote(clone1))

    assert_equal(run_system("git init --bare -b main " + shell_quote(remote_dir) + " >/dev/null 2>&1"), 0)
    assert_equal(git_cmd(clone1, "init"), 0)
    assert_equal(git_cmd(clone1, "remote add origin " + shell_quote(remote_dir)), 0)

    _ = write_file(clone1 + "/shared.txt", str_bytes("line 1\nline 2\n"))
    assert_equal(git_cmd(clone1, "add shared.txt"), 0)
    assert_equal(git_cmd(clone1, "commit -m 'shared base'"), 0)
    assert_equal(git_cmd(clone1, "push -u origin main"), 0)

    assert_equal(run_system("git clone " + shell_quote(remote_dir) + " " + shell_quote(clone2) + " >/dev/null 2>&1"), 0)
    _ = git_cmd(clone2, "config user.name 'SyncTester'")
    _ = git_cmd(clone2, "config user.email 'sync@turbomojo.org'")

    # Conflicting edits to line 2
    _ = write_file(clone1 + "/shared.txt", str_bytes("line 1\nline 2 from clone1\n"))
    assert_equal(git_cmd(clone1, "commit -am 'clone1 edit'"), 0)
    assert_equal(git_cmd(clone1, "push origin main"), 0)

    _ = write_file(clone2 + "/shared.txt", str_bytes("line 1\nline 2 from clone2\n"))
    assert_equal(git_cmd(clone2, "commit -am 'clone2 edit'"), 0)

    # Pull rebase fails due to conflict
    var pull_res = run_system(remote_sync_script(clone2, "p", "origin", "main") + " >/dev/null 2>&1")
    assert_true(pull_res != 0, "Pull rebase on conflicting changes must fail")

    # Abort rebase cleanly
    _ = run_system("git -C " + shell_quote(clone2) + " rebase --abort >/dev/null 2>&1")
    clean_scratch(d)


def test_tier2_f31_bound4_stash_on_clean_working_tree() raises:
    """Verifies stash push on clean working tree gracefully saves no stash."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b4_cleanstash")
    assert_equal(git_cmd(d, "init"), 0)
    _ = write_file(d + "/init.txt", str_bytes("clean\n"))
    assert_equal(git_cmd(d, "add init.txt"), 0)
    assert_equal(git_cmd(d, "commit -m 'init'"), 0)

    # Stash on completely clean working tree
    var cap = run_capture(stash_push_script(d, "nothing to stash") + " 2>&1")
    var out_text = bytes_to_str(cap.out)
    assert_true(out_text.find("No local changes to save") >= 0 or len(parse_stash_list(git_out(d, "stash list"))) == 0)
    clean_scratch(d)


def test_tier2_f31_bound5_stash_named_messages_with_quotes_and_symbols() raises:
    """Verifies stash push message preservation with quotes, emojis, and meta-chars."""
    if which("git").byte_length() == 0:
        return
    var d = scratch("t2_b5_symbols")
    assert_equal(git_cmd(d, "init"), 0)
    _ = write_file(d + "/app.mojo", str_bytes("var x = 1\n"))
    assert_equal(git_cmd(d, "add app.mojo"), 0)
    assert_equal(git_cmd(d, "commit -m 'init'"), 0)

    _ = write_file(d + "/app.mojo", str_bytes("var x = 99\n"))
    var complex_msg = "feat(ui): 🎨 add 'dark mode' & test"
    assert_equal(run_system(stash_push_script(d, complex_msg) + " >/dev/null 2>&1"), 0)

    var entries = parse_stash_list(git_out(d, "stash list"))
    assert_equal(len(entries), 1)
    assert_true(entries[0].message.find("dark mode") >= 0)
    assert_true(entries[0].message.find("🎨") >= 0)
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
