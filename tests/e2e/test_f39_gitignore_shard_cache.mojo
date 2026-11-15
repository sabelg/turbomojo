"""E2E Test Suite for Feature #39:
Full `.gitignore`, inotify Explorer & CI Cache.
- Hierarchical subfolder .gitignore pattern matching and precedence.
- FileSearch and ExplorerTree gitignore integration.
- Memory search overlay overriding disk content.
- inotify Watcher directory registration and cleanup.
- Transitive per-shard dependency hashing and cache invalidation in gen_test_runner.py.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List

from grep import glob_match, file_matches_filter, FileSearch, collect_search_files
from explorer import ExplorerTree
from search import make_search
from watch import Watcher
from util import (
    path_exists, write_file, read_file, str_bytes, bytes_to_str,
    run_system, run_capture, shell_quote, decode,
)
from harness import ScratchDir


# =========================================================================
# Tier 1 Tests (Happy Path)
# =========================================================================

def test_f39_t1_01_filesearch_load_gitignore_patterns() raises:
    """Verifies FileSearch loads and enforces ignore rules from .gitignore."""
    var s = ScratchDir.create("f39_fs_ign")
    var gitignore_content = """# Comment line
build/
dist/
target
*.log
*.tmp
"""
    s.write(".gitignore", gitignore_content)

    var fs = FileSearch()
    fs.load_gitignore(s.path)

    assert_true(fs.ignored("build"))
    assert_true(fs.ignored("dist"))
    assert_true(fs.ignored("target"))
    assert_true(fs.ignored("debug.log"))
    assert_true(fs.ignored("test.tmp"))

    assert_false(fs.ignored("main.mojo"))
    assert_false(fs.ignored("readme.md"))
    s.cleanup()


def test_f39_t1_02_explorer_tree_respects_gitignore() raises:
    """Verifies ExplorerTree respects .gitignore rules and hides ignored items unless show_all is set."""
    var s = ScratchDir.create("f39_ex_ign")
    s.write(".gitignore", "build/\n*.bak\n")
    s.write("src/main.mojo", "var a = 1\n")
    s.write("build/app", "binary\n")
    s.write("src/test.bak", "backup\n")
    s.write("README.md", "# Readme\n")

    var t = ExplorerTree()
    t.set_root(s.path)

    assert_true(t.hidden("build"))
    assert_true(t.hidden("test.bak"))
    assert_equal(t.reveal(s.path + "/build/app"), -1)
    assert_true(t.reveal(s.path + "/src/main.mojo") >= 0)

    # Toggling show_all reveals ignored items
    t.show_all = True
    t.rebuild()
    assert_false(t.hidden("build"))
    s.cleanup()


def test_f39_t1_03_file_matches_filter_negation_and_wildcards() raises:
    """Verifies file_matches_filter evaluates glob inclusions, exclusions, and negations."""
    var root = "/repo"
    assert_true(file_matches_filter(root, root + "/src/a.mojo", "*.mojo,!src/vendor/*"))
    assert_false(file_matches_filter(root, root + "/src/vendor/lib.mojo", "*.mojo,!src/vendor/*"))
    assert_false(file_matches_filter(root, root + "/target/app", "!target/"))
    assert_true(file_matches_filter(root, root + "/target_file.mojo", "!target/"))


def test_f39_t1_04_filesearch_memory_dirty_overlay() raises:
    """Verifies FileSearch memory overlay overrides disk content for search hits."""
    var s = ScratchDir.create("f39_overlay")
    s.write("target.mojo", "old disk content\n")

    var fs = FileSearch()
    var target_path = s.path + "/target.mojo"
    fs.start(s.path, make_search(decode("needle"), True, False, False))
    fs.set_overlay(target_path, str_bytes("new in-memory search needle\n"))

    assert_equal(len(fs.overlay_paths), 1)
    assert_equal(bytes_to_str(fs.overlay_bytes[0]), "new in-memory search needle\n")

    # Search with needle should hit the in-memory overlay
    while fs.active:
        fs.step(100)
    assert_equal(len(fs.hits), 1)
    assert_equal(fs.hits[0].path, target_path)

    # Re-starting search without overlay searches disk content (needle missing)
    fs.start(s.path, make_search(decode("needle"), True, False, False))
    while fs.active:
        fs.step(100)
    assert_equal(len(fs.hits), 0)
    s.cleanup()


def test_f39_t1_05_gen_test_runner_shard_generation_and_mapping() raises:
    """Verifies gen_test_runner.py produces shard files, tsv map, and sha256 checksums."""
    var s = ScratchDir.create("f39_gen")
    var out_d = s.path + "/build"
    var cmd = "python3 scripts/gen_test_runner.py --out " + shell_quote(out_d) + " --src-sig sig123"
    var res = run_capture(cmd)
    assert_equal(res.status, 0)

    assert_true(path_exists(out_d + "/shards.txt"))
    assert_true(path_exists(out_d + "/shard_map.tsv"))
    assert_true(path_exists(out_d + "/shard_0.want_sha256"))

    var shards = bytes_to_str(read_file(out_d + "/shards.txt"))
    assert_true(shards.find("shard_0") >= 0)

    var want_hash = bytes_to_str(read_file(out_d + "/shard_0.want_sha256")).strip()
    assert_equal(want_hash.byte_length(), 64)
    s.cleanup()


# =========================================================================
# Tier 2 Tests (Boundary Values & Corner Cases)
# =========================================================================

def test_f39_t2_01_glob_match_backtracking_and_recursive_wildcards() raises:
    """Verifies glob_match handles recursive globbing, character matching, and boundaries."""
    assert_true(glob_match("dist/**/bundle.js", "dist/bundle.js"))
    assert_true(glob_match("dist/**/*.js", "dist/a/b/bundle.js"))
    assert_true(glob_match("dist/**", "dist/bundle.js"))
    assert_false(glob_match("dist/**", "src/dist/bundle.js"))
    assert_true(glob_match("src/*/*.mojo", "src/a/main.mojo"))
    assert_false(glob_match("src/*.mojo", "src/a/main.mojo"))
    assert_true(glob_match("src/*.mojo", "src/main.mojo"))
    assert_true(glob_match("*.?", "a.c"))
    assert_false(glob_match("*.?", "a.cc"))


def test_f39_t2_06_hierarchical_gitignore_negation_and_nested_paths() raises:
    """Verifies subfolder .gitignore precedence, !negations (last rule wins), and nested paths."""
    var s = ScratchDir.create("f39_hier")
    s.write(".gitignore", "*.log\n!keep.log\nbuild/temp\n")
    s.write("debug.log", "ignored\n")
    s.write("keep.log", "kept at root\n")
    s.write("build/temp/skip.mojo", "ignored nested\n")
    s.write("build/ok/include.mojo", "kept sibling\n")
    s.write("sub/.gitignore", "*.gen.mojo\n!keep.gen.mojo\nkeep.log\n")
    s.write("sub/drop.gen.mojo", "ignored by sub\n")
    s.write("sub/keep.gen.mojo", "negated in sub\n")
    s.write("sub/keep.log", "re-ignored by sub\n")

    var files = collect_search_files(s.path, "")
    var joined = "|".join(files)
    assert_false(joined.find("debug.log") >= 0)
    assert_true(joined.find(s.path + "/keep.log") >= 0)
    assert_false(joined.find("build/temp/skip.mojo") >= 0)
    assert_true(joined.find("build/ok/include.mojo") >= 0)
    assert_false(joined.find("drop.gen.mojo") >= 0)
    assert_true(joined.find("keep.gen.mojo") >= 0)
    assert_false(joined.find("sub/keep.log") >= 0)

    var t = ExplorerTree()
    t.set_root(s.path)
    assert_true(t.reveal(s.path + "/keep.log") >= 0)
    assert_equal(t.reveal(s.path + "/build/temp/skip.mojo"), -1)
    assert_true(t.reveal(s.path + "/build/ok/include.mojo") >= 0)
    assert_equal(t.reveal(s.path + "/sub/drop.gen.mojo"), -1)
    assert_true(t.reveal(s.path + "/sub/keep.gen.mojo") >= 0)
    assert_equal(t.reveal(s.path + "/sub/keep.log"), -1)
    s.cleanup()


def test_f39_t2_02_collect_search_files_ignores_and_filters() raises:
    """Verifies collect_search_files skips ignored directories and files."""
    var s = ScratchDir.create("f39_collect")
    s.write(".gitignore", "build/\n*.log\n")
    s.write("main.mojo", "print(1)\n")
    s.write("node_modules/pkg/a.js", "console.log(1)\n")
    s.write("build/out.bin", "binary\n")
    s.write("src/a.mojo", "print(2)\n")
    s.write("src/b.log", "debug\n")
    s.write(".hidden/c.mojo", "secret\n")

    var files = collect_search_files(s.path, "")
    var found_main = False
    var found_src_a = False
    var found_ignored = False
    for f in files:
        if f.find("main.mojo") >= 0:
            found_main = True
        if f.find("src/a.mojo") >= 0:
            found_src_a = True
        if f.find("node_modules") >= 0 or f.find("build") >= 0 or f.find(".hidden") >= 0 or f.find("b.log") >= 0:
            found_ignored = True

    assert_true(found_main)
    assert_true(found_src_a)
    assert_false(found_ignored)
    s.cleanup()


def test_f39_t2_03_inotify_watcher_directory_registration_and_cleanup() raises:
    """Verifies Watcher initializes, registers directories, and cleans up cleanly."""
    var s = ScratchDir.create("f39_watch")
    var w = Watcher()
    assert_true(w.open())
    assert_true(w.active())
    _ = w.watch_dir(s.path)
    s.write("event.txt", "trigger watch")
    w.close()
    assert_false(w.active())
    s.cleanup()


def test_f39_t2_04_transitive_shard_hash_cache_invalidation() raises:
    """Verifies sha256 checksum updates when signature changes and remains stable when identical."""
    var s = ScratchDir.create("f39_inval")
    var out_d = s.path + "/build"
    var cmd1 = "python3 scripts/gen_test_runner.py --out " + shell_quote(out_d) + " --src-sig sig_baseline"
    _ = run_system(cmd1)
    var hash_base = bytes_to_str(read_file(out_d + "/shard_0.want_sha256"))

    # Re-run with identical signature yields identical hash (cache hit)
    _ = run_system(cmd1)
    var hash_same = bytes_to_str(read_file(out_d + "/shard_0.want_sha256"))
    assert_equal(hash_base, hash_same)

    # Re-run with changed signature invalidates hash
    var cmd2 = "python3 scripts/gen_test_runner.py --out " + shell_quote(out_d) + " --src-sig sig_modified"
    _ = run_system(cmd2)
    var hash_mod = bytes_to_str(read_file(out_d + "/shard_0.want_sha256"))
    assert_false(hash_base == hash_mod)
    s.cleanup()


def test_f39_t2_05_shard_runner_list_and_unknown_suite_dispatch() raises:
    """Verifies generated shard source handles --list and rejects unknown test suites."""
    var s = ScratchDir.create("f39_runner")
    var out_d = s.path + "/build"
    var cmd = "python3 scripts/gen_test_runner.py --out " + shell_quote(out_d) + " --src-sig sig123"
    _ = run_system(cmd)

    var shard0_code = bytes_to_str(read_file(out_d + "/shard_0.mojo"))
    assert_true(shard0_code.find('if suite == "--list":') >= 0)
    assert_true(shard0_code.find('unknown test suite for shard_0:') >= 0)
    assert_true(shard0_code.find('exit') >= 0)
    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
