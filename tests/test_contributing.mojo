"""Tests for the contributor documents (P11-09): CONTRIBUTING.md and the issue templates
name only things that exist - pixi tasks, scripts, files, the IDE's options and menu
commands - and the problem template asks for `tmide --caps` and points to Help > Report a
problem."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from config import read_text
from util import path_exists, run_capture, bytes_to_str
from commands import build_registry


def test_what_contributing_names_exists() raises:
    var c = read_text("CONTRIBUTING.md")
    assert_true(c.byte_length() > 1000)
    var pixi = read_text("pixi.toml")
    for task in ["build", "check", "canary", "macos-link"]:
        assert_true(c.find("pixi run " + String(task)) >= 0, String(task))
        assert_true(pixi.find("\n" + String(task) + " = ") >= 0, "pixi task " + String(task))
    for f in ["docs/SOURCE.md", "docs/JOURNAL.md", "docs/BACKLOG.md", "docs/ROADMAP.md", "docs/USER_GUIDE.md", "docs/KEYMAP.md", "help/whats-new.md", "src/helpbook.mojo", "tests/test_help.mojo", "tests/test_docs_files.mojo", "scripts/gen_docs.py", "scripts/smoke.sh", "scripts/perf.sh", "scripts/check.sh", "LICENSE", "tests/test_window.mojo"]:
        assert_true(c.find(String(f)) >= 0, "named: " + String(f))
        assert_true(path_exists(String(f)), "exists: " + String(f))
    for v in ["SKIP_SMOKE", "SKIP_PERF", "SKIP_SOAK", "TM_JOBS"]:
        assert_true(c.find(String(v)) >= 0 and read_text("scripts/check.sh").find(String(v)) >= 0, String(v))
    assert_true(c.find("Help > Report a problem") >= 0)


def test_the_issue_templates() raises:
    var bug = read_text(".github/ISSUE_TEMPLATE/bug_report.yml")
    assert_true(bug.find("tmide --caps") >= 0 and bug.find("tmide --version") >= 0)
    assert_true(bug.find("Help > Report a problem") >= 0)
    assert_true(path_exists(".github/ISSUE_TEMPLATE/feature_request.yml"))
    assert_true(read_text(".github/ISSUE_TEMPLATE/config.yml").find("docs/USER_GUIDE.md") >= 0)
    # the options and commands they mention are real
    var usage = bytes_to_str(run_capture("build/tmide --help 2>&1").out)
    assert_true(usage.find("--caps") >= 0 and usage.find("--version") >= 0, usage)
    var r = build_registry()
    assert_true(r.index_of_name("help.reportProblem") >= 0)
    assert_true(r.index_of_name("help.guide") >= 0)
    # CI runs the same gate
    assert_true(read_text(".github/workflows/ci.yml").find("run: pixi run check") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
