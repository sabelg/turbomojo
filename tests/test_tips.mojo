"""Tests for tips that answer what was just done (P7-14, src/tips.mojo, src/app_tips.mojo):
the rules, a tip coming at the pause (not while typing), each tip only once - also in
a later run - and Help > No more tips stopping them for good."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from tips import *
from notify import TYPING_PAUSE_MS
from term import key_event, KEY_RIGHT, KEY_LEFT, KEY_PGDN, KEY_BACKSPACE, KEY_ESC, ctrl
from commands import CM_NEW, CM_FIND, CM_TIPS_OFF
from config import load_settings
from app import *
from appstate import App, now_ns
from signals import own_pid
from util import env_or, run_system, shell_quote, decode, read_file, bytes_to_str, path_exists

comptime MS = 1000000


def test_the_rules() raises:
    var r = TipRules()
    var t = 1000 * MS
    for k in range(PAGES_FOR_TIP - 1):
        assert_equal(r.feed(TK_PAGE, t + k * 100 * MS), -1)
    assert_equal(r.feed(TK_PAGE, t + 600 * MS), TIP_PAGE)
    # spread over a long time: no tip
    var slow = TipRules()
    for k in range(PAGES_FOR_TIP * 2):
        assert_equal(slow.feed(TK_PAGE, t + k * 3000 * MS), -1)
    # a run of Left / Right, broken by another key
    var lr = TipRules()
    for k in range(LR_FOR_TIP - 1):
        assert_equal(lr.feed(TK_LR, t), -1)
    assert_equal(lr.feed(TK_OTHER, t), -1)
    for k in range(LR_FOR_TIP - 1):
        assert_equal(lr.feed(TK_LR, t), -1)
    assert_equal(lr.feed(TK_LR, t), TIP_WORDS)
    var bs = TipRules()
    for k in range(BS_FOR_TIP - 1):
        assert_equal(bs.feed(TK_BS, t), -1)
    assert_equal(bs.feed(TK_BS, t), TIP_BACKSPACE)
    var f = TipRules()
    assert_equal(f.feed(TK_FIND, t), -1)
    assert_equal(f.feed(TK_FIND, t + 20000 * MS), -1)
    assert_equal(f.feed(TK_FIND, t + 40000 * MS), TIP_AGAIN)
    assert_equal(len(parse_shown("word-moves\n\nword-moves\ngoto-symbol\n")), 2)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-tips-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def editor_app(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.tips_load(d + "/tips-shown")
    app.exec(CM_NEW)
    var text = String("")
    for k in range(200):
        text += "a line with some words on it, number " + String(k) + "\n"
    app.wins[app.top()].buf.load(decode(text))
    return app^


def tip_toasts(app: App) -> String:
    var s = String("")
    for k in app.notes.toasts(now_ns()):
        if app.notes.notices[k].title == "Tip":
            s += app.notes.notices[k].text + "|"
    return s^


def test_a_tip_comes_at_the_pause_and_only_once() raises:
    var d = scratch("once")
    var app = editor_app(d)
    for _ in range(LR_FOR_TIP):
        app.handle(key_event(KEY_RIGHT))
    assert_equal(tip_toasts(app), "")                              # not while typing
    app.notes_tick(app.typed_ns + (TYPING_PAUSE_MS + 1) * MS)
    var t = tip_toasts(app)
    assert_true(t.startswith("Ctrl-Left / Ctrl-Right move a word at a time"), t)
    assert_true(t.find("Help > No more tips") > 0, t)
    # the same slow way again: no second tip
    app.notes.dismiss_all()
    for _ in range(LR_FOR_TIP * 2):
        app.handle(key_event(KEY_LEFT))
    app.notes_tick(app.typed_ns + (TYPING_PAUSE_MS + 1) * MS)
    assert_equal(tip_toasts(app), "")
    # paging: Go to symbol, with the key of this keymap
    for _ in range(PAGES_FOR_TIP):
        app.handle(key_event(KEY_PGDN))
    app.notes_tick(app.typed_ns + (TYPING_PAUSE_MS + 1) * MS)
    assert_true(tip_toasts(app).startswith("Ctrl-T goes to a function by its name"), tip_toasts(app))
    # kept: a later run does not give them again
    assert_equal(bytes_to_str(read_file(d + "/tips-shown")), "word-moves\ngoto-symbol\n")
    var again = editor_app(d)
    for _ in range(LR_FOR_TIP):
        again.handle(key_event(KEY_RIGHT))
    again.notes_tick(again.typed_ns + (TYPING_PAUSE_MS + 1) * MS)
    assert_equal(tip_toasts(again), "")
    _ = run_system("rm -rf " + shell_quote(d))


def test_backspaces_and_find() raises:
    var d = scratch("bs")
    var app = editor_app(d)
    app.wins[app.top()].goto(5, 30)
    for _ in range(BS_FOR_TIP):
        app.handle(key_event(KEY_BACKSPACE))
    app.notes_tick(app.typed_ns + (TYPING_PAUSE_MS + 1) * MS)
    assert_true(tip_toasts(app).startswith("Ctrl-Backspace deletes the word to the left"), tip_toasts(app))
    app.notes.dismiss_all()
    for _ in range(FINDS_FOR_TIP):
        app.exec(CM_FIND)
        app.handle(key_event(KEY_ESC))
    app.notes_tick(now_ns() + (TYPING_PAUSE_MS + 1) * MS)
    assert_true(tip_toasts(app).startswith("Ctrl-L finds the next match again"), tip_toasts(app))
    _ = run_system("rm -rf " + shell_quote(d))


def test_no_more_tips() raises:
    var d = scratch("off")
    var app = editor_app(d)
    app.config_path = d + "/config.toml"
    app.exec(CM_TIPS_OFF)
    assert_false(app.tips_on)
    assert_true(bytes_to_str(read_file(d + "/config.toml")).find("tips = false") >= 0)
    for _ in range(LR_FOR_TIP):
        app.handle(key_event(KEY_RIGHT))
    app.notes_tick(app.typed_ns + (TYPING_PAUSE_MS + 1) * MS)
    assert_equal(tip_toasts(app), "")
    assert_false(path_exists(d + "/tips-shown"))                    # nothing was given
    # and the setting is read back
    var b = App()
    b.apply_settings(load_settings("[ui]\ntips = false\n", ""))
    assert_false(b.tips_on)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
