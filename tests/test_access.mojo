"""Tests for accessibility (P7-04): screen-reader mode (a plain screen, the cursor on
what has the focus, notices on the status line) and reduced motion."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from screen import Screen
from themes import animations_off
from config import load_settings
from term import key_event, KEY_DOWN, KEY_TAB, KEY_ESC, fkey
from app import *
from appstate import App, M_MENU, M_DIALOG, M_NORMAL, JOB_BUILD
from dialog import D_THEME
from commands import CM_NEW, CM_THEME_PICK, CM_SCREEN_READER, CM_MESSAGE
from notify import NL_DONE
from signals import own_pid
from util import to_str, decode, env_or, run_system, shell_quote, read_file, bytes_to_str


def decorations(s: String) -> Int:
    """How many frame, line and shading characters a screen's text has."""
    var n = 0
    for c in decode(s):
        if c >= 0x2500 and c <= 0x259F:
            n += 1
    return n


def test_a_plain_screen() raises:
    var scr = Screen(20, 5)
    scr.frame(0, 0, 20, 5, True, 0xFFFFFF, 0)
    _ = scr.text(2, 2, "hello", 0xFFFFFF, 0)
    assert_true(decorations(to_str(scr.to_text())) > 0)
    scr.plain = True
    scr.frame(0, 0, 20, 5, True, 0xFFFFFF, 0)
    _ = scr.text(2, 2, "hello", 0xFFFFFF, 0)
    var t = to_str(scr.to_text())
    assert_equal(decorations(t), 0)
    assert_true(t.find("hello") >= 0)


def reader_app() raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.apply_settings(load_settings("[ui]\nscreen_reader = true\nclock = true\n", ""))
    assert_true(app.reader)
    assert_true(app.reduce_motion)                  # a screen reader: no animation either
    return app^


def test_the_screen_reader_sees_text_only() raises:
    var app = reader_app()
    app.exec(CM_NEW)
    var ei = app.top()
    app.wins[ei].buf.load(decode("def main():\n    print(1)\n"))
    app.draw()
    var t = to_str(app.scr.to_text())
    assert_equal(decorations(t), 0, t)
    assert_true(t.find("print(1)") > 0)
    assert_true(t.find(clock_hm()) < 0)             # no clock changing under the reader
    assert_true(t.find("[■]") < 0 and t.find("▲") < 0)  # no window icons or scrollbars
    # the same app without the mode draws its frames
    app.apply_settings(load_settings("[ui]\nscreen_reader = false\n", ""))
    app.draw()
    assert_true(decorations(to_str(app.scr.to_text())) > 0)


def test_the_cursor_is_on_the_focus() raises:
    var app = reader_app()
    app.exec(CM_NEW)
    # the menu: on the marked item
    app.handle(key_event(fkey(10)))
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_DOWN))
    assert_equal(app.mode, M_MENU)
    app.draw()
    assert_true(app.scr.cvis)
    var row = to_str(app.scr.row_text(app.scr.cy))
    var label = String(app.menus[app.menu_idx].items[app.menu_item].label).replace("~", "")
    assert_true(row.find(label) >= 0, row + " / " + label)
    app.handle(key_event(KEY_ESC))
    # a dialog's list: on its marked row; a button: on the button
    app.exec(CM_THEME_PICK)
    assert_equal(app.mode, M_DIALOG)
    app.draw()
    assert_true(app.scr.cvis)
    var lrow = to_str(app.scr.row_text(app.scr.cy))
    assert_true(lrow.find(app.dlg.items[app.dlg.selected_item()]) >= 0, lrow)
    app.handle(key_event(KEY_TAB))                  # to the OK button
    app.draw()
    assert_true(to_str(app.scr.row_text(app.scr.cy)).find("OK") >= 0)
    app.handle(key_event(KEY_ESC))
    # a list window: on its row
    app.exec(CM_MESSAGE)
    var mi = app.msg_index()
    app.focus(mi)
    assert_equal(app.mode, M_NORMAL)
    app.draw()
    mi = app.msg_index()
    assert_true(app.scr.cvis)
    assert_equal(app.scr.cy, app.wins[mi].y + 1 + app.wins[mi].cr - app.wins[mi].top)


def test_notices_go_to_the_status_line() raises:
    var app = reader_app()
    app.notify(NL_DONE, "Build succeeded", "hello.mojo in 2.0 s")
    app.draw()
    var t = to_str(app.scr.to_text())
    var last = to_str(app.scr.row_text(app.scr.h - 1))
    assert_true(last.find("Build succeeded: hello.mojo") >= 0, last)
    assert_true(t.find("✓ Build succeeded") < 0)     # no toast box
    assert_equal(len(app.notes.notices), 1)          # kept in the centre all the same


def test_reduced_motion() raises:
    assert_true(animations_off("false\n"))
    assert_false(animations_off("true"))
    assert_false(animations_off(""))
    var app = App()
    app.scr.resize(100, 30)
    app.apply_settings(load_settings("[ui]\nreduced_motion = true\n", ""))
    assert_true(app.reduce_motion)
    assert_false(app.reader)
    app.exec(CM_NEW)
    app.job.active = True                            # (a build, as the status line sees it)
    app.job.kind = JOB_BUILD
    app.job.path = "/p/x.mojo"
    app.job.t0 = Int(now_ns())
    var seen = List[String]()
    for _ in range(3):
        app.draw()
        seen.append(to_str(app.scr.row_text(app.scr.h - 1)))
        _ = run_system("sleep 0.12")
    assert_true(seen[0].find("⠋ Building x.mojo") >= 0, seen[0])
    assert_true(seen[1].find("⠋ Building") >= 0 and seen[2].find("⠋ Building") >= 0)   # it stands still
    app.job.active = False
    app.apply_settings(load_settings("[ui]\nreduced_motion = false\n", ""))
    assert_false(app.reduce_motion)
    # a wrong value is said
    var s = load_settings("[ui]\nreduced_motion = \"sometimes\"\n", "")
    assert_equal(len(s.warnings), 1)


def test_the_options_toggle() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-access-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = App()
    app.scr.resize(100, 30)
    app.config_path = d + "/config.toml"
    app.exec(CM_SCREEN_READER)
    assert_true(app.reader)
    assert_true(app.scr.plain)
    assert_true(CM_SCREEN_READER in app.checked())
    assert_true(bytes_to_str(read_file(d + "/config.toml")).find("screen_reader = true") >= 0)
    app.exec(CM_SCREEN_READER)
    assert_false(app.reader)
    assert_false(app.scr.plain)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
