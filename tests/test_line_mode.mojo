"""Tests for the line mode (P10-14b, src/linemode.mojo): commands read as lines and
answered in lines; editing keeps the typed text as it is (indentation too), undo takes
a change back, save writes the file; quit asks about unsaved files; a dialog is read
out and the next line answers it; a build says its messages and its result, and next
goes to the error's line; `tmide --lines` and TERM=dumb answer piped commands with no
escape sequences at all."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from linemode import *
from appstate import App, M_DIALOG, M_NORMAL
from commands import CM_NEW
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, read_file, str_bytes, to_str, bytes_to_str, path_exists


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-lines-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    var x = 1\n    print(x)\n"))
    _ = write_file(d + "/bad.mojo", str_bytes("def main():\n    pritn(1)\n"))
    return d


def line_app(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.reader = True
    return app^


def said(lines: List[String]) -> String:
    return "\n".join(lines)


def test_the_helpers() raises:
    assert_equal(line_range("", 20, 3)[0], 3)
    assert_equal(line_range("", 20, 3)[1], 12)
    assert_equal(line_range("", 5, 3)[1], 4)
    assert_equal(line_range("2-4", 20, 0)[0], 1)
    assert_equal(line_range("2-4", 20, 0)[1], 3)
    assert_equal(line_range("7", 5, 0)[0], 4)          # (clamped to the file)
    assert_equal(line_range("4-2", 20, 0)[0], -1)
    assert_equal(line_range("x", 20, 0)[0], -1)
    assert_equal(text_after("set 2     print(2)", 2), "    print(2)")
    assert_equal(text_after("  set   2 x  y", 2), "x  y")
    assert_equal(text_after("append", 1), "")
    assert_true(is_number("12") and not is_number("1a") and not is_number(""))


def test_editing_and_saving() raises:
    var d = scratch("edit")
    var app = line_app(d)
    var o = app.line_command("open " + d + "/a.mojo")
    assert_equal(o[0], "opened " + d + "/a.mojo, 4 lines")
    assert_equal(said(app.line_command("print 1-3")), "1: def main():\n2:     var x = 1\n3:     print(x)")
    assert_equal(said(app.line_command("2")), "2:     var x = 1")
    assert_equal(said(app.line_command("find print")), "3:     print(x)")
    assert_equal(said(app.line_command("find nothing_like_it")), "not found: nothing_like_it")
    assert_equal(said(app.line_command("set 2     var x = 41")), "2:     var x = 41")
    assert_equal(said(app.line_command("insert 3     x += 1")), "3:     x += 1")
    _ = app.line_command("append # end")
    assert_equal(said(app.line_command("print 1-6")), "1: def main():\n2:     var x = 41\n3:     x += 1\n4:     print(x)\n5: \n6: # end")
    assert_equal(said(app.line_command("delete 5-6")), "deleted 2 lines; the file has 4")
    assert_equal(said(app.line_command("print 3-9")), "3:     x += 1\n4:     print(x)")
    # undo takes the last change back: the deleted lines return
    assert_true(said(app.line_command("undo")).startswith("undone"))
    assert_equal(said(app.line_command("print 5-6")), "5: \n6: # end")
    _ = app.line_command("undo")      # (the append)
    # quit asks while there are unsaved changes
    var q = said(app.line_command("quit"))
    assert_true(q.startswith("unsaved: a.mojo"), q)
    assert_true(said(app.line_command("save")).startswith("saved " + d + "/a.mojo"))
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")), "def main():\n    var x = 41\n    x += 1\n    print(x)\n")
    app.running = True
    assert_equal(said(app.line_command("quit")), "bye")
    assert_false(app.running)
    # quit! leaves with unsaved changes
    var b = line_app(d)
    _ = b.line_command("open " + d + "/a.mojo")
    _ = b.line_command("set 1 x")
    b.running = True
    assert_equal(said(b.line_command("quit!")), "bye")
    assert_false(b.running)
    assert_true(said(b.line_command("bogus")).startswith("unknown command: bogus"))
    _ = run_system("rm -rf " + shell_quote(d))


def test_a_dialog_is_read_out_and_answered() raises:
    var d = scratch("dlg")
    var app = line_app(d)
    app.exec(CM_NEW)
    _ = app.line_command("set 1 hello")
    var s = said(app.line_command("save"))
    assert_equal(app.mode, M_DIALOG)
    assert_true(s.find("dialog: ") >= 0 and s.find("buttons: 1 ") >= 0, s)
    assert_true(s.find("field ") >= 0, s)
    # the next line answers it: the name, then Enter
    _ = app.line_command(d + "/new.txt")
    assert_equal(app.mode, M_NORMAL)
    assert_true(path_exists(d + "/new.txt"))
    assert_equal(bytes_to_str(read_file(d + "/new.txt")).find("hello"), 0)
    # an empty line cancels
    app.exec(CM_NEW)
    _ = app.line_command("save")
    assert_equal(app.mode, M_DIALOG)
    assert_equal(said(app.line_command("")), "cancelled")
    assert_equal(app.mode, M_NORMAL)
    _ = run_system("rm -rf " + shell_quote(d))


def test_a_build_and_its_errors() raises:
    var d = scratch("build")
    var app = line_app(d)
    _ = app.line_command("open " + d + "/bad.mojo")
    var b = said(app.line_command("build"))
    assert_true(b.find("error: use of unknown declaration 'pritn'") >= 0, b)
    assert_true(b.find("build: error: Build failed") >= 0, b)
    assert_equal(app.mode, M_NORMAL, b)
    var e = said(app.line_command("errors"))
    assert_true(e.startswith("1. ") and e.find("pritn") >= 0, e)
    _ = app.line_command("open " + d + "/a.mojo")
    var n = app.line_command("next")
    assert_true(n[0].startswith("1/"), said(n))
    assert_equal(n[1], "bad.mojo 2:     pritn(1)")
    _ = run_system("rm -rf " + shell_quote(d))


def tmide() -> String:
    return env_or("PWD", ".") + "/build/tmide"


def piped(d: String, env: String, args: String, script: String) -> String:
    """`tmide` run with `script` as its input, in a home of its own."""
    _ = write_file(d + "/in.txt", str_bytes(script))
    var home = d + "/home"
    var cmd = (
        "cd " + shell_quote(d) + " && HOME=" + shell_quote(home) + " XDG_CONFIG_HOME=" + shell_quote(home + "/config")
        + " XDG_STATE_HOME=" + shell_quote(home + "/state") + " " + env + " " + shell_quote(tmide()) + " " + args
        + " < in.txt > out.txt 2>&1"
    )
    _ = run_system(cmd)
    return bytes_to_str(read_file(d + "/out.txt"))


def test_the_program_answers_in_lines() raises:
    var d = scratch("pipe")
    if not path_exists(tmide()):
        print("(no build/tmide - skipped)")
        return
    var out = piped(d, "TERM=xterm-256color", "--lines a.mojo", "print 2\nset 2     var x = 2\nsave\nquit\n")
    assert_true(out.find("tm> 2:     var x = 1") >= 0, out)
    assert_true(out.find("saved ") >= 0 and out.find("bye") >= 0, out)
    assert_equal(out.find("\x1b"), -1)              # no escape sequences at all
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")).find("    var x = 2"), 12)
    # TERM=dumb chooses the line mode by itself; the end of the input leaves
    var dumb = piped(d, "TERM=dumb", "a.mojo", "3\n")
    assert_true(dumb.find("tm> 3:     print(x)") >= 0, dumb)
    assert_equal(dumb.find("\x1b"), -1)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
