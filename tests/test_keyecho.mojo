"""Tests for the calm key echo (P7-07, src/app_keyecho.mojo)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app_keyecho import parse_key_uses, KEY_ECHO_ENOUGH
from term import key_event, ctrl, fkey, KEY_ENTER
from app import *
from appstate import App, M_MENU, M_NORMAL
from config import load_settings
from commands import CM_NEW, CM_DUPLINE
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, bytes_to_str, read_file, decode, to_str


def editor_app() raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode("one\ntwo\n"))
    return app^


def edit_menu(app: App) -> Int:
    for k in range(len(app.menus)):
        if app.menus[k].title == "~E~dit":
            return k
    return -1


def duplicate_from_the_menu(mut app: App) raises:
    app.open_menu(edit_menu(app))
    assert_equal(app.mode, M_MENU)
    app.handle(key_event(100))                      # d: Duplicate line


def test_a_menu_pick_names_the_key() raises:
    var app = editor_app()
    duplicate_from_the_menu(app)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[app.top()].buf.all_text()), "one\none\ntwo\n")    # it ran
    assert_equal(app.status, "Next time: Ctrl-D")
    app.draw()
    assert_true(to_str(app.scr.row_text(app.scr.h - 1)).find("Next time: Ctrl-D") > 0)
    # the key used often enough: no more echo for it
    for _ in range(KEY_ECHO_ENOUGH):
        app.handle(key_event(ctrl(100)))
    app.say("")
    duplicate_from_the_menu(app)
    assert_true(app.status.find("Next time") < 0, app.status)


def test_the_palette_names_the_key_too() raises:
    var app = editor_app()
    app.handle(key_event(ctrl(112)))                # Ctrl-P
    for c in decode("duplicate line"):           # (Ctrl-P starts with ">")
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "Next time: Ctrl-D")


def test_a_commands_own_message_stays() raises:
    var app = editor_app()
    app.say("Saved /p/x.mojo")
    app.key_echo(CM_DUPLINE)
    assert_equal(app.status, "Saved /p/x.mojo   (Next time: Ctrl-D)")
    # off
    app.apply_settings(load_settings("[ui]\nkey_hints = false\n", ""))
    app.say("")
    app.key_echo(CM_DUPLINE)
    assert_equal(app.status, "")


def test_the_hint_is_in_the_keymap_in_use() raises:
    var app = editor_app()
    app.apply_settings(load_settings("[ui]\nkeymap = \"turbo\"\n", ""))
    app.say("")
    app.key_echo(CM_DUPLINE)
    var label = app.reg.key_label(CM_DUPLINE)
    if label.byte_length() > 0:
        assert_equal(app.status, "Next time: " + label)
    else:
        assert_equal(app.status, "")                # no key in that keymap: nothing to say


def test_the_counts_are_kept() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-keyecho-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = editor_app()
    app.key_uses_load(d + "/key-uses")
    for _ in range(KEY_ECHO_ENOUGH + 2):
        app.handle(key_event(ctrl(100)))
    var kept = parse_key_uses(bytes_to_str(read_file(d + "/key-uses")))
    assert_equal(kept.get("edit.duplicateLine", 0), KEY_ECHO_ENOUGH)   # (written until it is enough)
    var app2 = editor_app()
    app2.key_uses_load(d + "/key-uses")
    duplicate_from_the_menu(app2)
    assert_true(app2.status.find("Next time") < 0, app2.status)
    assert_equal(len(parse_key_uses("a.b 2\nbroken\nc.d x\n\n")), 1)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
