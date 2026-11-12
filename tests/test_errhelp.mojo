"""Tests for the explanations of Mojo error messages (src/errhelp.mojo, help/errors/,
src/app_explain.mojo): the built-in pages are the files; every page's "before" program
really fails with a message the page explains (and no earlier page claims), and its
"after" program builds - with the compiler in use, so a changed message is noticed;
F1 on a Problems row and on the line in the editor opens the explanation beside the
code, and Esc gives the code its place back."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from errhelp import *
from errhelp_pages import ERR_PAGE_COUNT, err_page_key, err_page_text
from helpbook import help_pages
from problems import Problem, PS_BUILD, SEV_ERROR
from window import WK_EXPLAIN, WK_EDITOR
from term import key_event, fkey, wait_readable, KEY_ENTER, KEY_ESC
from commands import CM_BUILD, CM_PROBLEMS, CM_HELP_ERRORS, CM_TILE
from app import *
from appstate import App, M_NORMAL, M_DIALOG, M_DOCS, PG_PROBLEMS
from signals import own_pid
from util import env_or, run_system, run_capture, shell_quote, write_file, str_bytes, bytes_to_str, read_file, to_str, getcwd

comptime MS = 1000000


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-errhelp-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def test_the_built_in_pages_are_the_files() raises:
    var order = bytes_to_str(read_file(getcwd() + "/help/errors/ORDER")).split()
    assert_equal(len(order), ERR_PAGE_COUNT)
    for i in range(ERR_PAGE_COUNT):
        assert_equal(err_page_key(i), String(order[i]))
        assert_equal(bytes_to_str(read_file(getcwd() + "/help/errors/" + err_page_key(i) + ".md")), err_page_text(i), err_page_key(i))
        assert_true(len(err_matches(i)) > 0, err_page_key(i))
        for m in err_matches(i):
            assert_true(m.byte_length() > 5, err_page_key(i))
        assert_true(err_body(i).startswith("# "), err_page_key(i))
        for part in ["## What it means", "## How to fix it", "## Before (does not build)", "## After (builds)"]:
            assert_true(err_body(i).find(part) > 0, err_page_key(i) + ": " + part)


def code_blocks(text: String) -> List[String]:
    var out = List[String]()
    var parts = text.split("```mojo\n")
    for k in range(1, len(parts)):
        var p = String(parts[k])
        out.append(String(p[byte=0:p.find("```")]))
    return out^


def first_error(output: String) -> String:
    for l in output.split("\n"):
        var s = String(l)
        var k = s.find(" error: ")
        if k >= 0:
            return String(s[byte=k + 8:])
    return ""


def test_the_examples_say_what_the_pages_say() raises:
    var d = scratch("examples")
    for i in range(ERR_PAGE_COUNT):
        var key = err_page_key(i)
        var blocks = code_blocks(err_page_text(i))
        assert_equal(len(blocks), 2, key)
        _ = write_file(d + "/before.mojo", str_bytes(blocks[0]))
        _ = write_file(d + "/after.mojo", str_bytes(blocks[1]))
        var b = run_capture("cd " + shell_quote(d) + " && mojo build before.mojo -o before 2>&1")
        assert_true(b.status != 0, key + ": the 'before' program built")
        var msg = first_error(bytes_to_str(b.out))
        assert_equal(explain_for(msg), i, key + ": the compiler said: " + msg)    # (and no earlier page takes it)
        var a = run_capture("cd " + shell_quote(d) + " && mojo build after.mojo -o after 2>&1")
        assert_equal(a.status, 0, key + ": the 'after' program: " + bytes_to_str(a.out))
    _ = run_system("rm -rf " + shell_quote(d))


def test_unknown_messages_and_the_book() raises:
    assert_equal(explain_for("something nobody has seen"), -1)
    assert_equal(explain_for(""), -1)
    var book = errors_book()
    assert_true(book.startswith("# Mojo error messages\n"))
    for i in range(ERR_PAGE_COUNT):
        assert_true(book.find("\n## " + err_title(i) + "\n") >= 0, err_title(i))
    assert_true(book.find("\n### How to fix it\n") > 0)
    assert_true(book.find("<!-- match") < 0)
    assert_true("errors.md" in help_pages())


def wait_job(mut app: App) raises:
    var deadline = Int(perf_counter_ns()) + 240000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active, "the build did not end")


def test_f1_explains_a_build_error_beside_the_code() raises:
    var d = scratch("f1")
    _ = write_file(d + "/bad.mojo", str_bytes("def main():\n    var a = List[Int]()\n    var b = a\n    print(len(b), len(a))\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.open_path(d + "/bad.mojo")
    var ei = app.top()
    var before_w = app.wins[ei].w
    var before_x = app.wins[ei].x
    app.exec(CM_BUILD)
    wait_job(app)
    if app.mode == M_DIALOG:
        app.handle(key_event(KEY_ENTER))            # the "Compiling" box
    assert_true(len(app.prob_build) >= 1)
    app.exec(CM_PROBLEMS)
    assert_equal(app.msg_page, PG_PROBLEMS)
    var mi = app.msg_index()
    app.focus(mi)
    mi = app.top()
    app.wins[mi].cr = 2                             # the problem's row
    app.handle(key_event(fkey(1)))
    assert_equal(app.mode, M_NORMAL)                # (not the keyboard reference)
    var xi = app.top()
    assert_equal(app.wins[xi].kind, WK_EXPLAIN)
    assert_equal(app.wins[xi].path, "explain:implicit-copy")
    assert_true(app.wins[xi].title.find("Copying must be asked for") > 0, app.wins[xi].title)
    # beside the code: the editor keeps the left half, still in view
    ei = app.find_editor(d + "/bad.mojo")
    assert_equal(app.wins[ei].x, before_x)
    assert_true(app.wins[ei].w < before_w and app.wins[ei].w >= before_w // 2, String(app.wins[ei].w))
    assert_equal(app.wins[xi].x, app.wins[ei].x + app.wins[ei].w)
    app.draw()
    var shown = String("")
    for y in range(app.wins[xi].y, app.wins[xi].y + app.wins[xi].h):
        shown += to_str(app.scr.row_text(y)) + "\n"
    assert_true(shown.find("a.copy()") > 0, shown)
    assert_true(to_str(app.scr.row_text(app.wins[ei].y + 3)).find("var b = a") > 0)       # the code too
    assert_true(to_str(app.scr.row_text(app.scr.h - 1)).find("Esc") >= 0)
    # Esc: gone, and the editor has its place back
    app.handle(key_event(KEY_ESC))
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    assert_equal(app.wins[app.top()].w, before_w)
    for w in app.wins:
        assert_true(w.kind != WK_EXPLAIN)
    # F1 in the editor on the line with the problem
    app.wins[app.top()].cr = 2
    app.handle(key_event(fkey(1)))
    assert_equal(app.wins[app.top()].kind, WK_EXPLAIN)
    app.handle(key_event(KEY_ESC))
    # ... and on a line without one: F1 does what it did before (the keyboard reference)
    app.wins[app.top()].cr = 0
    app.wins[app.top()].cc = 0
    app.handle(key_event(fkey(1)))
    assert_equal(app.mode, M_DIALOG)
    app.handle(key_event(KEY_ESC))
    for w in app.wins:
        assert_true(w.kind != WK_EXPLAIN)
    _ = run_system("rm -rf " + shell_quote(d))


def test_a_problem_without_an_explanation() raises:
    var app = App()
    app.scr.resize(100, 30)
    app.open_path("/nowhere/x.mojo")
    app.prob_build.append(Problem(PS_BUILD, SEV_ERROR, "/nowhere/x.mojo", 1, 1, "a message nobody explained"))
    app.exec(CM_PROBLEMS)
    var mi = app.msg_index()
    app.focus(mi)
    app.wins[app.top()].cr = 2
    app.handle(key_event(fkey(1)))
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.status.find("No explanation for this message yet") >= 0, app.status)
    for w in app.wins:
        assert_true(w.kind != WK_EXPLAIN)


def test_beside_the_code_in_the_tiled_layout() raises:
    var app = App()
    app.scr.resize(120, 34)
    app.exec(CM_TILE)
    app.open_path("/nowhere/x.mojo")
    app.draw()
    var ei = app.top()
    var full = app.wins[ei].w
    app.prob_build.append(Problem(PS_BUILD, SEV_ERROR, "/nowhere/x.mojo", 1, 1, "use of unknown declaration 'totl'"))
    app.handle(key_event(fkey(1)))                  # in the editor, on line 1
    assert_equal(app.wins[app.top()].kind, WK_EXPLAIN)
    app.draw()                                      # (the panes are placed again)
    ei = app.find_editor("/nowhere/x.mojo")
    var xi = app.top()
    assert_true(app.wins[ei].w < full, String(app.wins[ei].w))
    assert_equal(app.wins[xi].x, app.wins[ei].x + app.wins[ei].w)
    assert_equal(app.wins[ei].w + app.wins[xi].w, full)
    app.handle(key_event(KEY_ESC))
    app.draw()
    assert_equal(app.wins[app.find_editor("/nowhere/x.mojo")].w, full)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
