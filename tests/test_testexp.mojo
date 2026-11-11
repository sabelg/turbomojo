"""Tests for the test explorer (src/testexp.mojo, src/app_tests.mojo). The parser is fed
the output TestSuite programs print (copied from real runs); the explorer runs real test
programs with the installed mojo."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from testexp import *
from term import wait_readable, key_event, KEY_ENTER, KEY_LEFT, KEY_RIGHT
from app import *
from appstate import App, M_NORMAL
from window import WK_TESTS, WK_EDITOR
from commands import CM_TESTEXP, CM_CANCEL
from signals import own_pid
from util import to_str, env_or, run_system

comptime MS = 1000000

comptime OUT = """stack trace was not collected. Enable stack trace collection with environment variable `MODULAR_DEBUG=stack-trace-on-error`
Unhandled exception caught during execution: 
Running 3 tests for /p/test_bad.mojo 
    PASS [ 0.001 ] test_good
    FAIL [ 0.016 ] test_bad
      At /p/test_bad.mojo:9:17: AssertionError: `left == right` comparison failed:
         left: 4
        right: 5
        reason: arithmetic
    FAIL [ 0.001 ] test_raises
      boom
    SKIP [ 0.001 ] test_later
--------
Summary [ 0.017 ] 3 tests run: 1 passed , 2 failed , 1 skipped 
Test suite' /p/test_bad.mojo 'failed! 

mojo: error: execution exited with a non-zero result: 1
"""

comptime BAD = "from std.testing import assert_equal, TestSuite\n\n\ndef test_good() raises:\n    assert_equal(1 + 1, 2)\n\n\ndef test_bad() raises:\n    assert_equal(2 * 2, 5, \"arithmetic\")\n\n\ndef test_raises() raises:\n    raise Error(\"boom\")\n\n\ndef helper():\n    pass\n\n\ndef main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run()\n"


def test_sources_and_output_are_read() raises:
    assert_true(is_test_source(BAD))
    assert_false(is_test_source("def main():\n    print(1)\n"))
    assert_equal(", ".join(test_names(BAD)), "test_good, test_bad, test_raises")
    assert_equal(def_line(BAD, "test_raises"), 12)
    assert_equal(def_line(BAD, "nope"), 0)
    var loc = parse_location("      At /p/test_bad.mojo:9:17: AssertionError: x")
    assert_equal(loc[0], "/p/test_bad.mojo")
    assert_equal(loc[1], 9)
    assert_equal(loc[2], 17)
    assert_equal(parse_location("boom")[0], "")
    var r = parse_run(OUT)
    assert_equal(len(r), 1)
    assert_equal(r[0].path, "/p/test_bad.mojo")
    assert_equal(", ".join(r[0].names), "test_good, test_bad, test_raises, test_later")
    assert_equal(r[0].states[0], TS_PASS)
    assert_equal(r[0].states[1], TS_FAIL)
    assert_equal(r[0].states[3], TS_SKIP)
    assert_equal(r[0].times[1], "0.016")
    assert_equal(" | ".join(r[0].messages[1]), "At /p/test_bad.mojo:9:17: AssertionError: `left == right` comparison failed: |    left: 4 |   right: 5 |   reason: arithmetic")
    assert_equal(" | ".join(r[0].messages[2]), "boom")
    assert_true(r[0].summary.startswith("Summary [ 0.017 ] 3 tests run"))
    var f = TestFile("/p/test_bad.mojo")
    for n in test_names(BAD):
        f.tests.append(TestCase(n))
    apply_report(f, r[0])
    assert_equal(len(f.tests), 4, "a test the program ran is added")
    assert_equal(f.tests[1].line, 9)
    assert_equal(f.tests[1].col, 17)
    assert_equal(f.tests[2].path, "", "a raised error has no place")
    var c = f.counts()
    assert_equal(c[0], 1)
    assert_equal(c[1], 2)
    assert_equal(c[2], 1)
    assert_equal(state_mark(TS_FAIL) + state_mark(TS_PASS) + state_mark(TS_UNKNOWN), "✗✓·")
    # a run of one test (--only): the skipped ones keep their results
    var one = RunReport("/p/test_bad.mojo")
    one.names.append("test_bad")
    one.states.append(TS_SKIP)
    one.times.append("0.001")
    one.messages.append(List[String]())
    apply_report(f, one, True)
    assert_equal(f.tests[1].state, TS_FAIL)
    apply_report(f, one, False)
    assert_equal(f.tests[1].state, TS_SKIP)


def project(tag: String) raises -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-tx-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/sub' '" + d + "/build' '" + d + "/.pixi'")
    with open(d + "/test_bad.mojo", "w") as f:
        f.write(BAD)
    with open(d + "/sub/test_ok.mojo", "w") as f:
        f.write("from std.testing import assert_true, TestSuite\n\n\ndef test_one() raises:\n    assert_true(True)\n\n\ndef main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run()\n")
    with open(d + "/test_broken.mojo", "w") as f:
        f.write("from std.testing import TestSuite\n\n\ndef test_x() raises:\n    nonsense_here()\n\n\ndef main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run()\n")
    with open(d + "/plain.mojo", "w") as f:
        f.write("def main():\n    print(1)\n")
    with open(d + "/build/test_copy.mojo", "w") as f:
        f.write(BAD)                            # under build/: not the project's
    with open(d + "/.pixi/test_env.mojo", "w") as f:
        f.write(BAD)
    with open(d + "/.turbomojo.toml", "w") as f:
        f.write("")
    return d


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    return app^


def window_text(app: App) -> String:
    var i = app.tests_index()
    var s = String("")
    for r in range(app.wins[i].buf.count()):
        s += to_str(app.wins[i].buf.line(r)) + "\n"
    return s


def row_of(app: App, text: String) -> Int:
    var i = app.tests_index()
    for r in range(app.wins[i].buf.count()):
        if to_str(app.wins[i].buf.line(r)).find(text) >= 0:
            return r
    return -1


def press_on(mut app: App, text: String, k: Int) raises:
    app.focus(app.tests_index())
    var i = app.tests_index()
    var r = row_of(app, text)
    assert_true(r >= 0, "no \"" + text + "\":\n" + window_text(app))
    app.wins[i].cr = r
    app.handle(key_event(k))


def wait_job(mut app: App, timeout_s: Int = 240) raises:
    var deadline = Int(perf_counter_ns()) + timeout_s * 1000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active, "the test run did not end")


def test_the_explorer_finds_runs_and_shows_failures() raises:
    var d = project("a")
    var app = ide(d)
    app.open_path(d + "/plain.mojo")
    app.exec(CM_TESTEXP)
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_TESTS)
    # the test files (not build/ or .pixi/, not a program without a TestSuite), their tests
    assert_equal(window_text(app), "▾ sub/test_ok.mojo\n  · test_one\n▾ test_bad.mojo\n  · test_good\n  · test_bad\n  · test_raises\n▾ test_broken.mojo\n  · test_x\n")
    # A runs every file; the results come into the tree
    press_on(app, "test_bad.mojo", 97)
    assert_true(app.job.active)
    assert_true(window_text(app).find("… test_good") >= 0, "marked as running")
    wait_job(app)
    var text = window_text(app)
    assert_true(text.find("▾ sub/test_ok.mojo   ✓1\n  ✓ test_one") >= 0, text)
    assert_true(text.find("▾ test_bad.mojo   ✓1 ✗2\n  ✓ test_good") >= 0, text)
    assert_true(text.find("  ✗ test_bad   ") >= 0 and text.find("/test_bad.mojo:9:17: AssertionError") >= 0, text)
    assert_true(text.find("  ✗ test_raises") >= 0 and text.find("      boom") >= 0, text)
    assert_true(text.find("▾ test_broken.mojo   (did not run)") >= 0, text)
    assert_true(text.find("nonsense_here") >= 0, "the compiler's message is shown:\n" + text)
    assert_true(app.status.startswith("Tests: 2 passed, 2 failed"), app.status)
    # Enter on a failure: the editor at its place; on a raised error: the test's def
    press_on(app, "✗ test_bad", KEY_ENTER)
    var e = app.top_editor()
    assert_equal(app.wins[e].path, d + "/test_bad.mojo")
    assert_equal(app.wins[e].cr, 8)
    assert_equal(app.wins[e].cc, 16)
    assert_equal(app.wins[app.top()].kind, WK_TESTS, "the keyboard stays in the explorer")
    press_on(app, "✗ test_raises", KEY_ENTER)
    assert_equal(app.wins[app.top_editor()].cr, 11)
    # R on one test runs only that one (the others keep their results)
    press_on(app, "✓ test_good", 114)
    wait_job(app)
    text = window_text(app)
    assert_true(text.find("✓ test_good") >= 0 and text.find("✗ test_bad") >= 0 and text.find("✗ test_raises") >= 0, "the others keep their results\n" + text)
    var log = to_str(app.wins[app.msg_index()].buf.all_text())
    assert_true(log.find("Running 3 tests for") >= 0 and log.find("SKIP") >= 0, "--only: the others are skipped\n" + log)
    # Left folds a file, Right opens it
    press_on(app, "▾ test_bad.mojo", KEY_LEFT)
    assert_true(window_text(app).find("▸ test_bad.mojo") >= 0 and window_text(app).find("test_good") < 0)
    press_on(app, "▸ test_bad.mojo", KEY_RIGHT)
    # L asks the program for its tests
    press_on(app, "test_ok.mojo", 108)
    wait_job(app)
    assert_true(app.test_files[0].listed)
    assert_equal(app.status.startswith("Listed"), True, app.status)
    # a test added to a file shows after T (look again)
    with open(d + "/sub/test_ok.mojo", "w") as f:
        f.write("from std.testing import assert_true, TestSuite\n\n\ndef test_one() raises:\n    assert_true(True)\n\n\ndef test_two() raises:\n    assert_true(True)\n\n\ndef main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run()\n")
    press_on(app, "test_ok.mojo", 116)
    assert_true(window_text(app).find("· test_two") >= 0, window_text(app))
    assert_true(window_text(app).find("✓ test_one") >= 0, "earlier results are kept")
    # closing
    app.exec(CM_TESTEXP)
    assert_equal(app.tests_index(), -1)
    _ = run_system("rm -rf '" + d + "'")


def test_a_project_without_tests() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-tx-" + String(own_pid()) + "-none"
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && touch '" + d + "/.turbomojo.toml'")
    var app = ide(d)
    app.exec(CM_TESTEXP)
    assert_equal(window_text(app), "(no test files: programs that run a TestSuite)\n")
    app.handle(key_event(97))
    assert_equal(app.status, "No test files")
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
