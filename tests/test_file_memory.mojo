"""Tests for navigation memory, second part (P10-17b): a file's cursor, scroll and folds
come back when it is opened again after being closed and after a restart (history
files, format 2; format 1 files still read); the session keeps each open file's
folds (and reads sessions written before it did); a tab moved to another pane keeps
its cursor, scroll and folds."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from filestate import state_encode, state_decode, STATE_MAGIC, STATE_MAGIC_1
from buffer import UndoRec
from session import SessionData, SessionFile, session_decode
from app import *
from appstate import App
from commands import CM_CLOSE, CM_TILED, CM_SPLIT_RIGHT, CM_MOVE_TAB
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, bytes_to_str


def test_the_history_format() raises:
    var folds: List[Int] = [5, 12]
    var data = state_encode(77, 120, 11, 2, 3, List[UndoRec](), List[UndoRec](), folds)
    var st = state_decode(data)
    assert_true(st.ok)
    assert_equal(st.cr, 11)
    assert_equal(st.top, 3)
    assert_equal(len(st.folds), 2)
    assert_equal(st.folds[1], 12)
    # a version 1 file (no folds) is still read
    var text = bytes_to_str(data)
    var lines = text.split("\n")
    assert_true(String(lines[2]).startswith("folds "), text)
    var v1 = String(STATE_MAGIC_1) + "\n" + String(lines[1]) + "\n"
    for k in range(3, len(lines)):
        v1 += String(lines[k]) + ("\n" if k + 1 < len(lines) else "")
    var old = state_decode(str_bytes(v1))
    assert_true(old.ok, v1)
    assert_equal(old.cr, 11)
    assert_equal(len(old.folds), 0)
    # damaged folds: the file is not used
    var bad = state_decode(str_bytes(text.replace("folds 2", "folds 9")))
    assert_false(bad.ok)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-fmem-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var src = String("struct A:\n    var n: Int\n\n\n")
    src += "def f():\n    var a = 1\n    var b = 2\n    print(a + b)\n\n"
    for k in range(30):
        src += "def g" + String(k) + "():\n    pass\n"
    _ = write_file(d + "/a.mojo", str_bytes(src))
    _ = write_file(d + "/b.mojo", str_bytes("def h():\n    pass\n"))
    return d


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.history_dir = d + "/state/history"
    return app^


def test_closed_and_opened_again() raises:
    var d = scratch("close")
    var app = ide(d)
    app.open_path(d + "/a.mojo")
    var t = app.top_editor()
    assert_true(app.wins[t].buf.set_fold(4, True))      # def f
    app.wins[t].goto(20, 4)
    app.wins[t].top = 9
    app.draw()
    var top = app.wins[t].top
    app.exec(CM_CLOSE)
    assert_equal(app.top_editor(), -1)
    app.open_path(d + "/a.mojo")
    t = app.top_editor()
    assert_equal(app.wins[t].cr, 20)
    assert_equal(app.wins[t].cc, 4)
    assert_equal(app.wins[t].top, top)
    assert_equal(len(app.wins[t].buf.folds), 1)
    assert_equal(app.wins[t].buf.folds[0], 4)
    # after a restart, too
    app.exec(CM_CLOSE)
    var again = ide(d)
    again.open_path(d + "/a.mojo")
    t = again.top_editor()
    assert_equal(again.wins[t].cr, 20)
    assert_equal(again.wins[t].buf.folds[0], 4)
    # changed on disk meanwhile: nothing is applied
    again.exec(CM_CLOSE)
    _ = write_file(d + "/a.mojo", str_bytes("def other():\n    pass\n"))
    var third = ide(d)
    third.open_path(d + "/a.mojo")
    t = third.top_editor()
    assert_equal(third.wins[t].cr, 0)
    assert_equal(len(third.wins[t].buf.folds), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_session_keeps_folds() raises:
    var s = SessionData()
    s.root = "/p"
    var f = SessionFile("/p/a.mojo")
    f.cr = 20
    f.folds = [4, 30]
    s.files.append(f^)
    s.files.append(SessionFile("/p/b.mojo"))
    var text = s.encode()
    var back = session_decode(text)
    assert_true(back[1], text)
    assert_equal(len(back[0].files), 2)
    assert_equal(len(back[0].files[0].folds), 2)
    assert_equal(back[0].files[0].folds[1], 30)
    assert_equal(len(back[0].files[1].folds), 0)
    # a session written before: eight numbers
    var old = session_decode(text.replace(" 2 4 30\t", "\t"))
    assert_true(old[1])
    assert_equal(len(old[0].files), 2)
    assert_equal(old[0].files[0].cr, 20)
    # a count that does not fit: that file is passed over
    var bad = session_decode(text.replace(" 2 4 30\t", " 3 4 30\t"))
    assert_equal(len(bad[0].files), 1)


def test_a_restored_session_has_the_folds() raises:
    var d = scratch("sess")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.session_dir = d + "/state/sessions"       # (no history files: only the session keeps them)
    app.open_path(d + "/a.mojo")
    var t = app.top_editor()
    _ = app.wins[t].buf.set_fold(4, True)
    _ = app.wins[t].buf.set_fold(0, True)
    app.session_save()
    var again = App()
    again.scr.resize(100, 30)
    again.cwd = d
    again.session_dir = d + "/state/sessions"
    assert_true(again.session_restore())
    t = again.top_editor()
    assert_equal(len(again.wins[t].buf.folds), 2)
    assert_true(4 in again.wins[t].buf.folds and 0 in again.wins[t].buf.folds)
    _ = run_system("rm -rf " + shell_quote(d))


def test_a_moved_tab_keeps_its_place() raises:
    var d = scratch("move")
    var app = ide(d)
    app.open_path(d + "/b.mojo")
    app.open_path(d + "/a.mojo")
    app.exec(CM_TILED)
    app.exec(CM_SPLIT_RIGHT)                    # [b] | [a]
    var t = app.top_editor()
    assert_equal(app.wins[t].title, "a.mojo")
    _ = app.wins[t].buf.set_fold(4, True)
    app.wins[t].goto(25, 1)
    app.draw()
    var top = app.wins[t].top
    var x = app.wins[t].x
    app.exec(CM_MOVE_TAB)                       # into the other pane
    app.draw()
    t = app.top_editor()
    assert_equal(app.wins[t].title, "a.mojo")
    assert_true(app.wins[t].x != x)             # (it did move)
    assert_equal(app.wins[t].cr, 25)
    assert_equal(app.wins[t].cc, 1)
    assert_equal(app.wins[t].top, top)
    assert_equal(app.wins[t].buf.folds[0], 4)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
