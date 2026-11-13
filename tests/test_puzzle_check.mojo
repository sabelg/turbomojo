"""Tests for checking an answer to the Mojo GPU Puzzles (P11-10c): which files are your
copies of puzzles, the modes a puzzle runs in (as the course's solutions/run.sh finds
them), the command, and Help > Exercise done? with a copy in front - a fake Mojo of
the puzzles' environment stands for the real one, so no GPU is needed."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from puzzlecheck import *
from term import wait_readable
from app import *
from appstate import App
from commands import CM_EX_CHECK
from config import read_text
from signals import own_pid
from util import env_or, run_system, to_str, path_exists, decode

comptime MS = 1000000


def test_which_files_are_puzzles() raises:
    var p = "/h/.local/share/turbomojo/practice"
    assert_equal(puzzle_rel(p, p + "/mojo-gpu-puzzles/problems/p01/p01.mojo"), "problems/p01/p01.mojo")
    assert_equal(puzzle_rel(p, p + "/mojo-gpu-puzzles/problems/p04/p04_tile_tensor.mojo"), "problems/p04/p04_tile_tensor.mojo")
    assert_equal(puzzle_rel(p, p + "/mojo-gpu-puzzles/solutions/p01/p01.mojo"), "")
    assert_equal(puzzle_rel(p, p + "/mojo-gpu-puzzles/problems/p17/op/conv1d.mojo"), "")   # (a Python puzzle's package)
    assert_equal(puzzle_rel(p, p + "/mojo-gpu-puzzles/problems/p01/notes.md"), "")
    assert_equal(puzzle_rel(p, p + "/modular/examples/hello.mojo"), "")
    assert_equal(puzzle_rel(p, "/elsewhere/mojo-gpu-puzzles/problems/p01/p01.mojo"), "")
    assert_equal(puzzle_name("problems/p13/p13.mojo"), "Puzzle 13")
    assert_equal(puzzle_mojo("/r"), "/r/.pixi/envs/default/bin/mojo")
    assert_equal(puzzle_runner("/r"), "env MODULAR_HOME='/r/.pixi/envs/default/share/max' '/r/.pixi/envs/default/bin/mojo'")


def test_the_modes_and_the_command() raises:
    var src = String("def main() raises:\n    if argv()[1] == \"--simple\":\n        pass\n    elif argv()[1] == \"--block-boundary\":\n        pass\n    var mode = argv()[1]\n    if mode == \"--simple\" or mode == \"--demo-colors\":\n        pass\n")
    var f = puzzle_flags(src)
    assert_equal(len(f), 2)
    assert_equal(f[0], "--block-boundary")
    assert_equal(f[1], "--simple")
    assert_equal(len(puzzle_flags("def main():\n    assert_equal(1, 1)\n")), 0)
    assert_true(puzzle_checks_itself("assert_equal(out, expected)"))
    assert_true(puzzle_checks_itself("print(\"Puzzle 01 complete ✅\")"))
    assert_false(puzzle_checks_itself("print(\"look at the output\")"))
    var one = puzzle_command("mojo", "/r", "/c/p01.mojo", List[String](), "")
    assert_equal(one, "echo '== (no flag)' && mojo run -I '/r' '/c/p01.mojo'")
    var two = puzzle_command("mojo", "/r", "/c/p13.mojo", f, "timeout 300 ")
    assert_equal(two, "echo '== --block-boundary' && timeout 300 mojo run -I '/r' '/c/p13.mojo' '--block-boundary' && echo '== --simple' && timeout 300 mojo run -I '/r' '/c/p13.mojo' '--simple'")


def wait_job(mut app: App) raises:
    var deadline = Int(perf_counter_ns()) + 60000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active, "the check did not end")


def message_text(app: App) -> String:
    var mi = app.msg_index()
    return to_str(app.wins[mi].buf.all_text()) if mi >= 0 else String("")


def test_checking_a_copy() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-puzzle-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/docs/mojo-gpu-puzzles' '" + d + "/practice/mojo-gpu-puzzles/problems/p13'")
    var app = App()
    app.scr.resize(110, 34)
    app.cwd = d
    app.doc_home = d + "/docs"
    var copy = d + "/practice/mojo-gpu-puzzles/problems/p13/p13.mojo"
    with open(copy, "w") as f:
        f.write("from std.testing import assert_equal\ndef main() raises:\n    if argv()[1] == \"--simple\":\n        pass\n    elif argv()[1] == \"--block-boundary\":\n        pass\n    # FILL ME IN\n")
    app.open_path(copy)
    # no environment of the puzzles yet: it says how to make one, and runs nothing
    app.exec(CM_EX_CHECK)
    assert_false(app.job.active)
    assert_true(app.status.find("needs the puzzles' own environment") >= 0 and app.status.find("pixi install") > 0, app.status)
    # a fake Mojo there: `run -I ROOT FILE [FLAG]`; right when the file says SOLVED
    _ = run_system("mkdir -p '" + d + "/docs/mojo-gpu-puzzles/.pixi/envs/default/bin'")
    var fake = d + "/docs/mojo-gpu-puzzles/.pixi/envs/default/bin/mojo"
    with open(fake, "w") as f:
        f.write("#!/bin/sh\n[ \"$1\" = run ] && [ \"$2\" = -I ] || exit 9\necho \"root=$3 file=$(basename $4) flag=$5 cwd=$(basename $(pwd)) home=$MODULAR_HOME\"\ngrep -q SOLVED \"$4\" && exit 0\necho 'AssertionError: out != expected'\nexit 1\n")
    _ = run_system("chmod +x '" + fake + "'")
    app.exec(CM_EX_CHECK)
    assert_true(app.job.active)
    wait_job(app)
    var m = message_text(app)
    assert_true(m.find("== --block-boundary") >= 0, m)
    assert_true(m.find("root=" + d + "/docs/mojo-gpu-puzzles file=p13.mojo flag=--block-boundary cwd=p13 home=" + d + "/docs/mojo-gpu-puzzles/.pixi/envs/default/share/max") >= 0, m)
    assert_equal(m.find("flag=--simple"), -1, m)                # (stops at the first that fails)
    assert_true(app.status.startswith("Not yet"), app.status)
    assert_false(path_exists(d + "/practice/mojo-gpu-puzzles/done"))
    # solved: every mode runs and passes
    app.wins[app.top_editor()].buf.load(decode("from std.testing import assert_equal\ndef main() raises:\n    if argv()[1] == \"--simple\":\n        pass\n    elif argv()[1] == \"--block-boundary\":\n        pass\n    # SOLVED\n"))
    app.wins[app.top_editor()].buf.modified = True
    app.exec(CM_EX_CHECK)                                       # (saves first)
    wait_job(app)
    m = message_text(app)
    assert_true(m.find("flag=--block-boundary") >= 0 and m.find("flag=--simple") >= 0, m)
    assert_true(app.status.startswith("✓ Puzzle 13 solved"), app.status)
    assert_equal(read_text(d + "/practice/mojo-gpu-puzzles/done"), "problems/p13/p13.mojo\n")
    assert_true(read_text(copy).find("SOLVED") > 0)
    # a puzzle with no check of its own: nothing runs
    var look = d + "/practice/mojo-gpu-puzzles/problems/p13/look.mojo"
    with open(look, "w") as f:
        f.write("def main():\n    print(\"read this in the debugger\")\n")
    app.open_path(look)
    app.exec(CM_EX_CHECK)
    assert_false(app.job.active)
    assert_true(app.status.find("no check of its own") > 0, app.status)
    # another file: what to open
    with open(d + "/other.mojo", "w") as f:
        f.write("def main():\n    pass\n")
    app.open_path(d + "/other.mojo")
    app.exec(CM_EX_CHECK)
    assert_true(app.status.find("your copy of a GPU puzzle") > 0, app.status)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
