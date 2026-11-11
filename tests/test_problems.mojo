"""Tests for the unified Problems page and the panel filters (src/problems.mojo,
src/app_problems.mojo): the model, and in the IDE problems from a real build, a failed
test and the language server's list, the filter keys, and the Message page's filter."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from problems import *
from testexp import TestFile, TestCase, TS_FAIL, TS_PASS
from term import wait_readable, key_event, KEY_ENTER, KEY_ESC
from app import *
from appstate import App, now_ns, PG_PROBLEMS, PG_MESSAGE, M_DIALOG, M_NORMAL
from dialog import D_PANEL_FILTER
from window import WK_EDITOR, WK_MESSAGE
from commands import CM_BUILD, CM_PROBLEMS, CM_MESSAGE
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, decode, to_str

comptime MS = 1000000

# what `mojo build` printed for a file with two mistakes (copied from a real run)
comptime BUILD_OUT = """/p/bad.mojo:2:5: error: use of unknown declaration 'pritn'
    pritn("hi")
    ^~~~~
/p/bad.mojo:3:9: warning: assignment to 'x' was never used; assign to '_' instead?
    var x = 1
        ^
sub/lib.mojo:7:1: note: declared here
mojo: error: failed to parse the provided Mojo source module
"""


def test_compiler_output_is_read() raises:
    var ps = parse_compiler_output(BUILD_OUT, "/p")
    assert_equal(len(ps), 3)
    assert_equal(ps[0].path, "/p/bad.mojo")
    assert_equal(ps[0].line, 2)
    assert_equal(ps[0].col, 5)
    assert_equal(ps[0].severity, SEV_ERROR)
    assert_equal(ps[0].message, "use of unknown declaration 'pritn'")
    assert_equal(ps[0].source, PS_BUILD)
    assert_equal(ps[1].severity, SEV_WARNING)
    assert_equal(ps[2].path, "/p/sub/lib.mojo")          # relative: from the base
    assert_equal(ps[2].severity, SEV_INFO)
    assert_equal(problem_row(ps[0]), "/p/bad.mojo:2:5: error: use of unknown declaration 'pritn'  [build]")


def sample() -> List[Problem]:
    var ps = List[Problem]()
    ps.append(Problem(PS_SERVER, SEV_WARNING, "/p/b.mojo", 9, 1, "unused b"))
    ps.append(Problem(PS_SERVER, SEV_ERROR, "/p/a.mojo", 5, 3, "bad a"))
    ps.append(Problem(PS_BUILD, SEV_ERROR, "/p/a.mojo", 2, 1, "early a"))
    ps.append(Problem(PS_BUILD, SEV_ERROR, "/p/a.mojo", 5, 3, "bad a"))     # the server said it too
    ps.append(Problem(PS_TEST, SEV_ERROR, "/p/t.mojo", 4, 1, "test_x failed: 4 != 5"))
    ps.append(Problem(PS_SERVER, SEV_HINT, "/p/b.mojo", 1, 1, "a hint"))
    return ps^


def test_order_and_filter() raises:
    var ps = sample()
    # the current file first, by line; repeats once; then the files as they came
    var v = view_problems(ps, ProblemFilter(), "/p/a.mojo")
    assert_equal(len(v.rows), 5)
    assert_true(v.rows[0].startswith("/p/a.mojo:2:1: error: early a"))
    assert_true(v.rows[1].startswith("/p/a.mojo:5:3: error: bad a"))
    assert_true(v.rows[2].startswith("/p/b.mojo:1:1: hint: a hint"))
    assert_true(v.rows[3].startswith("/p/b.mojo:9:1: warning: unused b"))
    assert_equal(v.rows[4], "/p/t.mojo:4:1: error: test_x failed: 4 != 5  [test]")
    assert_equal(v.errors, 3)
    assert_equal(v.warnings, 1)
    assert_equal(v.infos, 1)
    assert_equal(v.files, 3)
    var f = ProblemFilter()
    assert_false(f.active())
    f.errors = False
    v = view_problems(ps, f, "/p/a.mojo")
    assert_equal(v.shown, 2)
    assert_equal(v.errors, 3)                       # the counts are of everything
    f = ProblemFilter()
    f.this_file = True
    assert_equal(view_problems(ps, f, "/p/a.mojo").shown, 2)
    f = ProblemFilter()
    f.text = "TEST_X"
    v = view_problems(ps, f, "/p/a.mojo")
    assert_equal(v.shown, 1)
    assert_true(f.describe().find("containing \"TEST_X\"") > 0)
    # a message's further lines follow it
    ps[0].more.append("second line")
    v = view_problems(ps, ProblemFilter(), "")
    assert_equal(v.rows[0], "/p/b.mojo:1:1: hint: a hint")       # b by line: the hint first
    assert_equal(v.rows[1], "/p/b.mojo:9:1: warning: unused b")
    assert_equal(v.rows[2], "    second line")
    assert_equal(v.of[2], 0)
    assert_equal(len(filter_lines(["Ab", "b", "x"], "B")), 2)


# ------------------------------------------------------------ in the IDE
def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-problems-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def panel_lines(app: App) -> List[String]:
    var mi = app.msg_index()
    var out = List[String]()
    for r in range(app.wins[mi].buf.count()):
        out.append(to_str(app.wins[mi].buf.line(r)))
    return out^


def find_line(app: App, start: String) -> Int:
    var ls = panel_lines(app)
    for k in range(len(ls)):
        if ls[k].startswith(start):
            return k
    return -1


def wait_job(mut app: App) raises:
    var deadline = Int(perf_counter_ns()) + 240000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active, "the build did not end")


def test_build_errors_and_failed_tests_on_the_problems_page() raises:
    var d = scratch("build")
    _ = write_file(d + "/bad.mojo", str_bytes("def main():\n    pritn(\"hi\")\n"))
    _ = write_file(d + "/test_t.mojo", str_bytes("def test_x() raises:\n    pass\n"))
    var app = App()
    app.scr.resize(110, 32)
    app.cwd = d
    app.open_path(d + "/bad.mojo")
    app.exec(CM_BUILD)
    wait_job(app)
    if app.mode == M_DIALOG:
        app.handle(key_event(KEY_ENTER))            # the "Compiling" box
    # the build's own page shows the output; the Problems page has its error
    assert_equal(app.msg_page, PG_MESSAGE)
    assert_equal(len(app.prob_build), 1)
    # a failed test (as the test explorer has it after a run)
    var f = TestFile(d + "/test_t.mojo")
    var t = TestCase("test_x")
    t.state = TS_FAIL
    t.message.append("At " + d + "/test_t.mojo:2:5: AssertionError: `left == right` comparison failed:")
    t.path = d + "/test_t.mojo"
    t.line = 2
    t.col = 5
    f.tests.append(t^)
    var ok = TestCase("test_y")
    ok.state = TS_PASS
    f.tests.append(ok^)
    app.test_files.append(f^)
    app.exec(CM_PROBLEMS)
    assert_equal(app.msg_page, PG_PROBLEMS)
    var ls = panel_lines(app)
    assert_equal(ls[0], "Problems reported by the language server, the last build and the tests")
    assert_true(ls[1].startswith("Shown: errors warnings notes in all files"))
    var b = find_line(app, d + "/bad.mojo:2:5: error: ")
    assert_true(b == 2, "\n".join(ls))
    assert_true(ls[b].endswith("[build]"))
    var tl = find_line(app, d + "/test_t.mojo:2:5: error: test_x failed: AssertionError")
    assert_true(tl > b, "\n".join(ls))
    assert_true(ls[len(ls) - 1].startswith("2 problem(s) in 2 files"))
    # Enter on a row goes to the place
    var mi = app.msg_index()
    app.focus(mi)
    app.wins[app.top()].cr = tl
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.wins[app.top()].path, d + "/test_t.mojo")
    assert_equal(app.wins[app.top()].cr, 1)
    assert_equal(app.wins[app.top()].cc, 4)
    # F: only the current file's (test_t.mojo is in front now)
    app.focus(app.msg_index())
    app.handle(key_event(70))
    assert_equal(find_line(app, d + "/bad.mojo"), -1)
    assert_true(find_line(app, d + "/test_t.mojo") > 0)
    assert_true(panel_lines(app)[1].find("in this file") > 0)
    var last = panel_lines(app)[len(panel_lines(app)) - 1]
    assert_true(last.startswith("1 problem(s), 1 not shown"), last)
    # E: errors hidden; nothing left to show
    app.handle(key_event(101))
    last = panel_lines(app)[len(panel_lines(app)) - 1]
    assert_true(last.startswith("No problems shown: 2 hidden by the filter"), last)
    # C: everything again; / with a text
    app.handle(key_event(99))
    assert_true(find_line(app, d + "/bad.mojo") > 0)
    app.handle(key_event(47))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_PANEL_FILTER)
    for c in decode("PRITN"):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))
    assert_true(find_line(app, d + "/bad.mojo") > 0)
    assert_equal(find_line(app, d + "/test_t.mojo"), -1)
    # a passing build empties the build's part
    _ = write_file(d + "/bad.mojo", str_bytes("def main():\n    print(\"hi\")\n"))
    var ei = app.find_editor(d + "/bad.mojo")
    app.wins[ei].buf.load(decode("def main():\n    print(\"hi\")\n"))
    app.focus(ei)
    app.exec(CM_BUILD)
    wait_job(app)
    if app.mode == M_DIALOG:
        app.handle(key_event(KEY_ENTER))
    assert_equal(len(app.prob_build), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_message_page_filter() raises:
    var app = App()
    app.scr.resize(110, 32)
    var d = scratch("msg")
    app.cwd = d
    _ = write_file(d + "/bad.mojo", str_bytes("a\nb\nc\n"))
    app.panel_write(PG_MESSAGE)
    _ = app.fill_messages("Building bad.mojo", str_bytes(String(BUILD_OUT).replace("/p/", d + "/")), "Build failed")
    app.focus(app.msg_index())
    var all = len(panel_lines(app))
    app.handle(key_event(47))
    for c in decode("WARNING"):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))
    var ls = panel_lines(app)
    assert_equal(len(ls), 3)
    assert_equal(ls[0], "Building bad.mojo")
    assert_true(ls[1].find("warning: assignment to 'x'") > 0)
    assert_true(ls[2].startswith("(1 of " + String(all - 1) + " lines contain \"WARNING\""))
    # the place still works from the filtered line
    assert_equal(len(app.errs), 1)
    assert_equal(app.errs[0].msg_line, 1)
    app.wins[app.top()].cr = 1
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.wins[app.top()].path, d + "/bad.mojo")
    assert_equal(app.wins[app.top()].cr, 2)
    # C: everything again
    app.focus(app.msg_index())
    app.handle(key_event(99))
    assert_equal(len(panel_lines(app)), all)
    assert_equal(len(app.errs), 2)
    # new output arrives unfiltered
    app.handle(key_event(47))
    for c in decode("error"):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))
    assert_true(app.out_filtered)
    _ = app.fill_messages("Again", str_bytes("one\ntwo\n"), "done")
    assert_false(app.out_filtered)
    assert_equal(len(panel_lines(app)), 4)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
