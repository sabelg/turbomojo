"""Tests for the exact command at the top of each Message page run (P10-08): the
command as shown leaves out only the IDE's plumbing; a build's page has it under the
header from the start to the end, the error places still point at the error lines,
the output filter keeps both first lines; and the command shown, run in a shell,
does what the build did."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from term import wait_readable, key_event
from app import *
from app_jobs import shown_command
from appstate import App, M_DIALOG
from commands import CM_BUILD
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, to_str, read_file, bytes_to_str

comptime MS = 1000000


def test_the_command_as_shown() raises:
    assert_equal(
        shown_command("cd '/p' && mkdir -p build && exec mojo build -I src '/p/a.mojo' -o '/p/build/a' 2>&1"),
        "cd '/p' && mkdir -p build && mojo build -I src '/p/a.mojo' -o '/p/build/a'",
    )
    assert_equal(shown_command("cd '/p' && exec pixi run 'test' 2>&1 </dev/null"), "cd '/p' && pixi run 'test'")
    assert_equal(shown_command("exec mojo format 'a.mojo' 2>&1"), "mojo format 'a.mojo'")
    assert_equal(shown_command(""), "")


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-cmdline-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def wait_job(mut app: App) raises:
    var deadline = Int(perf_counter_ns()) + 240000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active, "the build did not end")


def msg_line(app: App, r: Int) -> String:
    var mi = app.msg_index()
    return to_str(app.wins[mi].buf.line(r))


def test_a_build_shows_its_command() raises:
    var d = scratch("build")
    _ = write_file(d + "/bad.mojo", str_bytes("def main():\n    pritn(\"hi\")\n"))
    var app = App()
    app.scr.resize(140, 34)
    app.cwd = d
    app.open_path(d + "/bad.mojo")
    app.exec(CM_BUILD)
    assert_true(msg_line(app, 0).startswith("Building "), msg_line(app, 0))
    var cmd = msg_line(app, 1)
    assert_true(cmd.startswith("$ cd " + shell_quote(d) + " && "), cmd)
    assert_true(cmd.find(" build") > 0 and cmd.find(shell_quote(d + "/bad.mojo")) > 0, cmd)
    assert_true(cmd.find("2>&1") < 0 and cmd.find("exec ") < 0, cmd)
    wait_job(app)
    if app.mode == M_DIALOG:
        app.handle(key_event(13))                   # the "Compiling" box
    assert_equal(msg_line(app, 1), cmd)             # still there at the end
    assert_true(len(app.errs) >= 1)
    assert_true(msg_line(app, app.errs[0].msg_line).find("error:") > 0, msg_line(app, app.errs[0].msg_line))
    # the filter keeps the header and the command, and the places still match
    app.output_filter("pritn")
    assert_true(msg_line(app, 0).startswith("Building "))
    assert_equal(msg_line(app, 1), cmd)
    assert_true(len(app.errs) >= 1)
    assert_true(msg_line(app, app.errs[0].msg_line).find("error:") > 0)
    app.output_filter("")
    # pasted into a shell, the command does the same
    var shell = String(cmd[byte=2:]) + " > " + shell_quote(d + "/again.txt") + " 2>&1"
    var status = run_system("cd / && " + shell)
    assert_true(status != 0)
    var again = bytes_to_str(read_file(d + "/again.txt"))
    assert_true(again.find("pritn") > 0 and again.find("error") > 0, again)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
