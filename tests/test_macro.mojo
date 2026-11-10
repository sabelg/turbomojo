"""Tests for keyboard macros: recording keys, pastes and menu commands, and replaying."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from commands import *
from app import *
from appstate import App, M_NORMAL, M_DIALOG, M_MENU, EV_COMMAND
from dialog import D_FIND, D_REPLACE
from term import (
    Event, EV_KEY, EV_PASTE, EV_MOUSE, MB_LEFT, key_event, KEY_ESC, KEY_ENTER, KEY_UP, KEY_DOWN, KEY_END,
    KEY_HOME, KEY_TAB, KEY_RIGHT, MOD_ALT, MOD_CTRL, MOD_SHIFT, ctrl, alt, fkey,
)
from util import decode, to_str

comptime REC = fkey(5) | MOD_CTRL
comptime PLAY = fkey(6) | MOD_CTRL


def make(src: String) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode(src))
    return app^


def press(mut app: App, k: Int) raises:
    app.handle(key_event(k))


def keys(mut app: App, s: String) raises:
    for c in decode(s):
        app.handle(key_event(c))


def text(app: App) -> String:
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_EDITOR:
            return to_str(app.wins[i].buf.all_text())
    return ""


def test_record_and_play_on_each_line() raises:
    var r = build_registry()
    assert_equal(r.find_key(REC), CM_MACRO_REC)
    assert_equal(r.find_key(PLAY), CM_MACRO_PLAY)
    var app = make("one\ntwo\nthree")
    press(app, REC)
    assert_true(app.macro_rec)
    assert_true(app.status.startswith("Recording a macro"), app.status)
    press(app, KEY_HOME)
    keys(app, "- ")
    press(app, KEY_END)
    keys(app, ";")
    press(app, KEY_DOWN)
    press(app, REC)
    assert_false(app.macro_rec)
    assert_equal(len(app.macro), 6)                     # the stop key is not part of it
    assert_equal(app.status, "Macro recorded: 6 steps - Ctrl-F6 plays it")
    assert_equal(text(app), "- one;\ntwo\nthree")
    press(app, PLAY)
    press(app, PLAY)
    assert_equal(text(app), "- one;\n- two;\n- three;")
    assert_equal(app.status, "Macro played (6 steps)")
    assert_equal(len(app.macro), 6)                     # playing does not change the macro


def test_nothing_recorded_and_play_while_recording() raises:
    var app = make("x")
    press(app, PLAY)
    assert_equal(app.status, "No macro recorded")
    press(app, REC)
    keys(app, "a")
    press(app, PLAY)                                    # refused, and not recorded
    assert_equal(app.status, "Stop recording first")
    assert_true(app.macro_rec)
    keys(app, "b")
    press(app, REC)
    assert_equal(len(app.macro), 2)
    press(app, PLAY)
    assert_equal(text(app), "ababx")


def test_a_new_recording_replaces_the_old_one() raises:
    var app = make("")
    press(app, REC)
    keys(app, "1")
    press(app, REC)
    press(app, REC)
    keys(app, "22")
    press(app, REC)
    press(app, PLAY)
    assert_equal(text(app), "12222")
    # recording nothing leaves an empty macro
    press(app, REC)
    press(app, REC)
    assert_equal(app.status, "Macro recorded: 0 steps - Ctrl-F6 plays it")
    press(app, PLAY)
    assert_equal(app.status, "No macro recorded")


def test_shortcuts_dialogs_and_pastes_are_replayed() raises:
    var app = make("foo bar foo\nfoo")
    press(app, REC)
    press(app, ctrl(114))                               # Replace dialog
    assert_equal(app.dlg.kind, D_REPLACE)
    keys(app, "foo")
    press(app, KEY_TAB)
    app.handle(Event(EV_PASTE, 0, 0, 0, 0, False, False, decode("baz")))
    press(app, alt(97))                                 # Change all
    assert_equal(app.mode, M_NORMAL)
    press(app, REC)
    assert_equal(text(app), "baz bar baz\nbaz")
    var t = app.top()
    app.wins[t].buf.load(decode("a foo b"))
    app.wins[t].goto(0, 0)
    press(app, PLAY)
    assert_equal(text(app), "a baz b")
    assert_equal(app.mode, M_NORMAL)


def test_commands_from_the_menu_are_recorded_as_commands() raises:
    var app = make("b\na")
    press(app, REC)
    keys(app, "x")
    press(app, fkey(10))                                # menu bar
    assert_equal(app.mode, M_MENU)
    assert_equal(len(app.macro), 1)                     # the menu key itself is not kept
    # walk to Text > Sort lines and choose it
    var ti = -1
    for i in range(len(app.menus)):
        if app.menus[i].title.find("ext") > 0 and app.menus[i].title.find("T") >= 0:
            ti = i
    assert_true(ti > 0)
    while app.menu_idx != ti:
        press(app, KEY_RIGHT)
    var guard = 0
    while app.menus[app.menu_idx].items[app.menu_item].cmd != CM_SORT and guard < 40:
        press(app, KEY_DOWN)
        guard += 1
    press(app, KEY_ENTER)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(text(app), "a\nxb")
    assert_equal(len(app.macro), 2)
    assert_equal(app.macro[1].kind, EV_COMMAND)
    assert_equal(app.macro[1].key, CM_SORT)
    keys(app, "!")
    press(app, REC)
    assert_equal(len(app.macro), 3)
    var t = app.top()
    app.wins[t].buf.load(decode("2\n1"))
    app.wins[t].goto(0, 0)
    press(app, PLAY)
    assert_equal(text(app), "1!\nx2")                    # typed x, sorted, typed ! after the first character


def test_stopping_from_the_menu_keeps_the_last_key() raises:
    var app = make("")
    press(app, REC)
    keys(app, "ab")
    # stop through the menu command instead of the key
    press(app, fkey(10))
    press(app, KEY_ESC)
    app.macro_note_cmd(CM_MACRO_REC)                    # what the menu does before running it
    app.exec(CM_MACRO_REC)
    assert_false(app.macro_rec)
    assert_equal(len(app.macro), 2)
    press(app, PLAY)
    assert_equal(text(app), "abab")


def test_key_sequence_bindings_inside_a_macro() raises:
    var app = make("one\ntwo")
    app.keymap = 1                                      # Turbo: Ctrl-Q D = end of line
    app.rebuild_keys(False)
    press(app, REC)
    press(app, ctrl(113))
    press(app, 100)
    keys(app, ".")
    press(app, ctrl(120))                               # Ctrl-X: down
    press(app, REC)
    assert_equal(len(app.macro), 4)
    press(app, PLAY)
    assert_equal(text(app), "one.\ntwo.")
    # stopping with a two-key binding removes both of its keys
    app.reg.bind(CM_MACRO_REC, chord(ctrl(107), 109))
    press(app, ctrl(107))
    press(app, 109)
    assert_true(app.macro_rec)
    keys(app, "z")
    press(app, ctrl(107))
    press(app, 109)
    assert_false(app.macro_rec)
    assert_equal(len(app.macro), 1)


def test_mouse_is_not_recorded_and_indicator_shows() raises:
    var app = make("abc")
    press(app, REC)
    app.handle(Event(EV_MOUSE, 0, 3, 3, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, 3, 3, MB_LEFT, False, False, List[Int]()))
    assert_equal(len(app.macro), 0)
    app.status_until = 0                                # let the status text expire
    app.draw()
    var last = to_str(app.scr.row_text(app.scr.h - 1))
    assert_true(last.find("REC") > 0, last)
    press(app, REC)
    app.status_until = 0
    app.draw()
    assert_true(to_str(app.scr.row_text(app.scr.h - 1)).find("REC") < 0)


def test_macro_works_with_several_cursors_and_undo_steps_back() raises:
    var app = make("a\nb\nc")
    press(app, REC)
    press(app, KEY_END)
    keys(app, "()")
    press(app, REC)
    var t = app.top()
    app.wins[t].goto(1, 0)
    press(app, KEY_DOWN | MOD_CTRL | MOD_ALT)           # cursors on lines 2 and 3
    press(app, PLAY)
    assert_equal(text(app), "a()\nb()\nc()")
    app.exec(CM_UNDO)
    assert_equal(text(app), "a()\nb\nc")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
