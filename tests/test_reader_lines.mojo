"""Tests for screen-reader mode, first part (P10-14a): notices on the status line say
what they are about and whether they are errors; a build, the tests, a task and the
agent ring the bell, other notices and the mode off do not; menus number their items
(and say "(on)" and "(not now)") and a digit picks one; dialog buttons are numbered,
a digit presses one, y and n answer a question, while digits typed into a field stay
text; TERM=dumb turns the mode on."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from std.time import perf_counter_ns
from app import *
from app_notify import spoken_notice
from appstate import App, M_DIALOG, M_NORMAL, M_MENU
from config import load_settings
from notify import NL_ERROR, NL_DONE, NL_WARN, NL_INFO
from menu import item_number, item_of_number
from term import key_event, wait_readable, KEY_DELETE
from commands import CM_BUILD, CM_EXPLORER, CM_OPEN
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, to_str, bytes_to_str, path_exists

comptime MS = 1000000


def test_the_spoken_notice() raises:
    assert_equal(spoken_notice("build", NL_ERROR, "Build failed", "a.mojo: 2 error(s)"), "build: error: Build failed: a.mojo: 2 error(s)")
    assert_equal(spoken_notice("agent", NL_DONE, "Claude", "finished"), "agent: Claude: finished")
    assert_equal(spoken_notice("git", NL_WARN, "Committed", ""), "git: warning: Committed")
    assert_equal(spoken_notice("", NL_INFO, "Tip", ""), "Tip")


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-reader-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/bad.mojo", str_bytes("def main():\n    pritn(1)\n"))
    return d


def reader_app(d: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.apply_settings(load_settings("[ui]\nscreen_reader = true\n", ""))
    assert_true(app.reader)
    return app^


def test_notices_and_the_bell() raises:
    var d = scratch("bell")
    var app = reader_app(d)
    app.notify_as("git", NL_DONE, "Committed", "first", True)
    assert_equal(app.status, "git: Committed: first")
    assert_equal(app.bells, 0)                          # (git: no bell)
    app.notify_as("agent", NL_DONE, "The agent", "finished", True)
    assert_equal(app.bells, 1)
    assert_true(bytes_to_str(app.term.out).endswith("\x07"))
    # a real build that fails
    app.open_path(d + "/bad.mojo")
    app.exec(CM_BUILD)
    var deadline = Int(perf_counter_ns()) + 240000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active)
    assert_true(app.status.startswith("build: error: Build failed"), app.status)
    assert_equal(app.bells, 2)
    # not in screen-reader mode: no bell (and the notice is a toast)
    var plain = App()
    plain.scr.resize(120, 34)
    plain.notify_as("build", NL_ERROR, "Build failed", "x", True)
    assert_equal(plain.bells, 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_numbered_menus() raises:
    var d = scratch("menu")
    var app = reader_app(d)
    var fm = -1
    var om = -1
    for i in range(len(app.menus)):
        if app.menus[i].title == "~F~ile":
            fm = i
        if app.menus[i].title == "~O~ptions":
            om = i
    var m = app.menus[fm].copy()
    # numbers skip the separators
    var seen = 0
    for i in range(len(m.items)):
        if m.items[i].label == "-":
            assert_equal(item_number(m, i), 0)
        elif seen < 9:
            seen += 1
            assert_equal(item_number(m, i), seen)
            assert_equal(item_of_number(m, seen), i)
    app.open_menu(fm)
    app.draw()
    var text = to_str(app.scr.to_text())
    assert_true(text.find("1 New") >= 0, text)
    assert_true(text.find("Save (not now)") >= 0 or text.find("Save  (not now)") >= 0 or text.find("Save (not now") >= 0, text)
    # the cursor is on the number of the marked item
    assert_true(app.scr.cvis)
    var row = to_str(app.scr.row_text(app.scr.cy))
    assert_true(row.find("1 New") >= 0, row)
    # a digit picks the item: Open asks for a file
    var open_n = -1
    for i in range(len(m.items)):
        if m.items[i].cmd == CM_OPEN:
            open_n = item_number(m, i)
    assert_true(open_n > 0)
    app.handle(key_event(48 + open_n))
    assert_equal(app.mode, M_DIALOG)
    app.handle(key_event(27))
    # Options: a switch that is on says so
    app.open_menu(om)
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("(on)") >= 0)
    app.handle(key_event(27))
    _ = run_system("rm -rf " + shell_quote(d))


def test_numbered_buttons_and_y_n() raises:
    var d = scratch("dlg")
    _ = write_file(d + "/keep.txt", str_bytes("x\n"))
    var app = reader_app(d)
    app.trash_dir = d + "/.trash"
    app.exec(CM_EXPLORER)
    var xi = app.explorer_index()
    app.focus(xi)
    var row = app.ex.row_of(d + "/keep.txt")
    app.wins[xi].cr = row
    app.handle(key_event(KEY_DELETE))
    assert_equal(app.mode, M_DIALOG)
    app.draw()
    var text = to_str(app.scr.to_text())
    assert_true(text.find("1 Move to trash") >= 0 and text.find("2 Cancel") >= 0, text)
    app.handle(key_event(110))                      # n: the last button, Cancel
    assert_equal(app.mode, M_NORMAL)
    assert_true(path_exists(d + "/keep.txt"))
    app.handle(key_event(KEY_DELETE))
    app.handle(key_event(50))                       # 2: Cancel
    assert_equal(app.mode, M_NORMAL)
    assert_true(path_exists(d + "/keep.txt"))
    app.handle(key_event(KEY_DELETE))
    app.handle(key_event(121))                      # y: Move to trash
    assert_equal(app.mode, M_NORMAL)
    assert_false(path_exists(d + "/keep.txt"))
    # digits typed into a field are text
    app.handle(key_event(110))                      # n: New file (asks for a name)
    assert_equal(app.mode, M_DIALOG)
    app.handle(key_event(49))
    app.handle(key_event(50))
    assert_equal(app.dlg.field_text(0), "12")
    app.handle(key_event(27))
    # without screen-reader mode a dialog's buttons are not numbered and n does nothing
    var plain = App()
    plain.scr.resize(120, 34)
    plain.cwd = d
    plain.exec(CM_EXPLORER)
    plain.focus(plain.explorer_index())
    plain.wins[plain.explorer_index()].cr = 0
    plain.handle(key_event(KEY_DELETE))
    if plain.mode == M_DIALOG:
        plain.draw()
        assert_true(to_str(plain.scr.to_text()).find("1 Move to trash") < 0)
        plain.handle(key_event(110))
        assert_equal(plain.mode, M_DIALOG)
    _ = run_system("rm -rf " + shell_quote(d))


def test_term_dumb_turns_it_on() raises:
    var old = env_or("TERM", "")
    _ = external_call["setenv", Int32]("TERM".as_c_string_span(), "dumb".as_c_string_span(), Int32(1))
    var app = App()
    app.apply_settings(load_settings("", ""))
    var on = app.reader
    _ = external_call["setenv", Int32]("TERM".as_c_string_span(), old.as_c_string_span(), Int32(1))
    assert_true(on)
    var other = App()
    other.apply_settings(load_settings("", ""))
    assert_equal(other.reader, env_or("TURBOMOJO_SCREEN_READER", "") == "1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
