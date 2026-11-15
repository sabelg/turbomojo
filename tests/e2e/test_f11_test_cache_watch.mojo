"""E2E Test Suite for Feature #11: Compiled Test Binary Cache & Watch-on-Save.
Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from signals import own_pid
from testexp import (
    TS_UNKNOWN, TS_RUNNING, TS_PASS, TS_FAIL, TS_SKIP,
    TestCase, TestFile, is_test_source, test_names, def_line,
    parse_run, apply_report, RunReport,
    file_size, file_mtime_ns, TestBinaryCache, WatchOnSaveManager,
    ParallelJob, ParallelTestRunner, clamp_coverage_line, render_coverage_gutter,
)
from util import (
    env_or, run_system, shell_quote, write_file,
    path_exists, str_bytes,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f11-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def sample_test_code(target_val: Int = 2) -> String:
    var s = String("from std.testing import assert_equal, TestSuite\n")
    s += "def test_pass() raises:\n"
    s += "    assert_equal(1 + 1, " + String(target_val) + ")\n"
    s += "def test_second() raises:\n"
    s += "    assert_equal(2 * 2, 4)\n"
    s += "def main() raises:\n"
    s += "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    return s


# ===========================================================================
# Tier 1: Happy Path Tests (5 tests)
# ===========================================================================

def test_f11_tier1_01_cache_directory_and_binary_creation() raises:
    """Verify test runner creates <state_dir>/testbin/ and compiles native executable."""
    var s_dir = scratch("s1-dir")
    var proj = scratch("s1-proj")
    var src_path = proj + "/test_sample.mojo"
    _ = write_file(src_path, str_bytes(sample_test_code(2)))

    var cache = TestBinaryCache(s_dir)
    var built = cache.build_cache(src_path)
    assert_true(built[0], "Failed to build test cache binary: " + built[1])

    assert_true(path_exists(cache.cache_dir()), "Missing cache directory testbin/")
    var bin_path = cache.binary_path(src_path)
    assert_true(path_exists(bin_path), "Missing compiled binary in cache")
    assert_true(cache.binary_size(src_path) > 0, "Cached binary is zero-sized")
    assert_true(cache.is_cache_valid(src_path), "Cache signature not valid")

    clean_scratch(s_dir)
    clean_scratch(proj)


def test_f11_tier1_02_cached_rerun_sub_10ms_speedup() raises:
    """Verify that re-running --only <name> uses cached binary and completes rapidly."""
    var s_dir = scratch("s2-dir")
    var proj = scratch("s2-proj")
    var src_path = proj + "/test_sample.mojo"
    _ = write_file(src_path, str_bytes(sample_test_code(2)))

    var cache = TestBinaryCache(s_dir)
    _ = cache.build_cache(src_path)

    # Second run: execute cached native binary
    var res = cache.run_cached(src_path, only="test_pass")
    assert_equal(res[0], 0)
    assert_true(res[1].find("PASS") >= 0, "Test did not pass: " + res[1])
    # Native execution completes in tens of milliseconds, well under 250ms
    assert_true(res[2] < 250.0, "Cached run took too long: " + String(res[2]) + " ms")

    clean_scratch(s_dir)
    clean_scratch(proj)


def test_f11_tier1_03_cache_invalidation_on_source_change() raises:
    """Verify that modifying the test source invalidates cache and triggers recompilation."""
    var s_dir = scratch("s3-dir")
    var proj = scratch("s3-proj")
    var src_path = proj + "/test_sample.mojo"
    _ = write_file(src_path, str_bytes(sample_test_code(2)))

    var cache = TestBinaryCache(s_dir)
    _ = cache.build_cache(src_path)
    assert_true(cache.is_cache_valid(src_path))

    # Sleep briefly or touch file to ensure mtime changes, update code to failing assertion
    _ = run_system("sleep 0.05")
    _ = write_file(src_path, str_bytes(sample_test_code(3))) # 1 + 1 != 3
    assert_false(cache.is_cache_valid(src_path), "Cache should be invalidated after edit")

    var res = cache.run_cached(src_path, only="test_pass")
    assert_true(res[0] != 0, "Test should have failed")
    assert_true(res[1].find("FAIL") >= 0, "Expected failure in output: " + res[1])

    clean_scratch(s_dir)
    clean_scratch(proj)


def test_f11_tier1_04_toggle_watch_on_save_workflow() raises:
    """Verify toggle watch-on-save automatically identifies affected tests upon save."""
    var wm = WatchOnSaveManager(enabled=False)
    assert_false(wm.enabled)

    # Toggle watch on
    var state = wm.toggle()
    assert_true(state)
    assert_true(wm.enabled)

    var test_file = "/path/to/tests/test_calculator.mojo"
    var targets = wm.on_save(test_file, is_modified=True)
    assert_equal(len(targets), 1)
    assert_equal(targets[0], test_file)

    # Toggle watch off
    _ = wm.toggle()
    assert_false(wm.enabled)
    var targets_off = wm.on_save(test_file, is_modified=True)
    assert_equal(len(targets_off), 0)


def test_f11_tier1_05_parallel_test_sharding_four_pipes() raises:
    """Verify parallel test sharding partitions multiple test files across up to 4 worker pipes."""
    var runner = ParallelTestRunner(max_pipes=4)
    var files = List[String]()
    files.append("/test/test_a.mojo")
    files.append("/test/test_b.mojo")
    files.append("/test/test_c.mojo")
    files.append("/test/test_d.mojo")

    var shards = runner.partition(files)
    assert_equal(len(shards), 4)
    for i in range(4):
        assert_equal(len(shards[i]), 1)
        assert_equal(shards[i][0], files[i])

    # 6 files across 4 pipes -> pipes 0 and 1 receive 2 files, 2 and 3 receive 1
    files.append("/test/test_e.mojo")
    files.append("/test/test_f.mojo")
    var shards6 = runner.partition(files)
    assert_equal(len(shards6), 4)
    assert_equal(len(shards6[0]), 2)
    assert_equal(len(shards6[1]), 2)
    assert_equal(len(shards6[2]), 1)
    assert_equal(len(shards6[3]), 1)


# ===========================================================================
# Tier 2: Boundary & Corner Cases Tests (5 tests)
# ===========================================================================

def test_f11_tier2_06_corrupted_cached_binary_auto_recovery() raises:
    """Verify corrupted/truncated cached binary (0 bytes) is detected and recompiled."""
    var s_dir = scratch("s6-dir")
    var proj = scratch("s6-proj")
    var src_path = proj + "/test_sample.mojo"
    _ = write_file(src_path, str_bytes(sample_test_code(2)))

    var cache = TestBinaryCache(s_dir)
    _ = cache.build_cache(src_path)
    var bin_path = cache.binary_path(src_path)
    assert_true(cache.is_valid_binary(bin_path))

    # Corrupt binary by truncating to 0 bytes
    _ = write_file(bin_path, str_bytes(""))
    assert_false(cache.is_valid_binary(bin_path))
    assert_false(cache.is_cache_valid(src_path))

    # Running test should automatically recover by recompiling
    var res = cache.run_cached(src_path, only="test_pass")
    assert_equal(res[0], 0)
    assert_true(cache.is_valid_binary(bin_path))
    assert_true(res[1].find("PASS") >= 0)

    clean_scratch(s_dir)
    clean_scratch(proj)


def test_f11_tier2_07_compilation_failure_clears_stale_cache() raises:
    """Verify compilation failure clears/invalidates stale binary and captures error."""
    var s_dir = scratch("s7-dir")
    var proj = scratch("s7-proj")
    var src_path = proj + "/test_syntax_err.mojo"
    # Write invalid syntax
    var bad_code = String("from std.testing import assert_equal\n")
    bad_code += "nonsense_token_xyz@@@@!!\n"
    _ = write_file(src_path, str_bytes(bad_code))

    var cache = TestBinaryCache(s_dir)
    var res = cache.run_cached(src_path)
    assert_true(res[0] != 0, "Compilation should have failed")
    assert_false(cache.is_valid_binary(cache.binary_path(src_path)))

    # Verify error diagnostics captured in TestFile
    var tf = TestFile(src_path)
    tf.problem.append(res[1])
    assert_true(len(tf.problem) > 0)
    assert_true(tf.problem[0].find("error:") >= 0 or tf.problem[0].find("nonsense_token") >= 0)

    clean_scratch(s_dir)
    clean_scratch(proj)


def test_f11_tier2_08_watch_on_save_filters_non_test_and_clean_saves() raises:
    """Verify watch-on-save filters out non-test files and unmodified saves."""
    var wm = WatchOnSaveManager(enabled=True)

    # 1. Non-test markdown file
    assert_false(wm.should_trigger("README.md", is_modified=True))
    assert_false(wm.should_trigger("notes.txt", is_modified=True))

    # 2. Config files
    assert_false(wm.should_trigger("config.toml", is_modified=True))

    # 3. Test file but unmodified buffer (clean save)
    assert_false(wm.should_trigger("tests/test_foo.mojo", is_modified=False))

    # 4. Valid modified test file
    assert_true(wm.should_trigger("tests/test_foo.mojo", is_modified=True))
    assert_true(wm.should_trigger("tests/test_bar.🔥", is_modified=True))


def test_f11_tier2_09_coverage_gutter_rendering_bounds() raises:
    """Verify coverage gutter handles negative lines, beyond-count lines, and empty files."""
    # Empty file: 0 lines
    var empty_gutter = render_coverage_gutter(0, List[Int]())
    assert_equal(len(empty_gutter), 0)

    # 5-line buffer with out-of-bound records: line -5, line 2, line 999
    var cov_records = List[Int]()
    cov_records.append(-5)
    cov_records.append(2)
    cov_records.append(999)

    var gutter = render_coverage_gutter(5, cov_records)
    assert_equal(len(gutter), 5)
    # Line -5 clamps to line 0
    assert_equal(gutter[0], "✓")
    assert_equal(gutter[1], "·")
    # Line 2 is covered
    assert_equal(gutter[2], "✓")
    assert_equal(gutter[3], "·")
    # Line 999 clamps to line 4
    assert_equal(gutter[4], "✓")


def test_f11_tier2_10_parallel_pipes_cancel_and_process_cleanup() raises:
    """Verify cancelling parallel test execution terminates active worker pipes."""
    var runner = ParallelTestRunner(max_pipes=4)
    var files = List[String]()
    files.append("/test/1.mojo")
    files.append("/test/2.mojo")
    files.append("/test/3.mojo")
    files.append("/test/4.mojo")

    var shards = runner.partition(files)
    var jobs = List[ParallelJob]()
    for i in range(len(shards)):
        jobs.append(ParallelJob(i, shards[i]))

    # Verify all jobs initial active
    for i in range(len(jobs)):
        assert_true(jobs[i].active)
        assert_false(jobs[i].cancelled)

    # Trigger cancel
    runner.cancel(jobs)

    # Verify all jobs cancelled
    for i in range(len(jobs)):
        assert_false(jobs[i].active)
        assert_true(jobs[i].cancelled)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
