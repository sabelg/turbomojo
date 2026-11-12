"""Tests for the box of the keys that may follow a prefix key (P7-10,
src/app_keybox.mojo): nothing for a quick sequence, the box after a pause with the
keymap's real bindings, the next key still completing the sequence, Esc cancelling,
the setting, and a screen reader getting the keys on the status line."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from term import key_event, ctrl, KEY_ESC
from commands import build_registry, apply_keymap, chord, key_name, CM_NEW, CM_SAVE, CM_COPY
from config import load_settings
from app import *
from appstate import App, M_NORMAL, KEY_BOX_MS, now_ns
from util import decode, to_str

comptime MS = 1000000


def turbo_app(extra: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.apply_settings(load_settings("[ui]\nkeymap = \"turbo\"\n" + extra, ""))
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode("one\ntwo\n"))
    return app^


def screen(app: App) -> String:
    var s = String("")
    for y in range(app.scr.h):
        s += to_str(app.scr.row_text(y)) + "\n"
    return s^


def test_the_registry_lists_what_may_follow() raises:
    var reg = build_registry()
    apply_keymap(reg, 1)                            # Turbo / WordStar
    var k = reg.chord_seconds(ctrl(107))            # Ctrl-K
    assert_true(len(k) >= 10, String(len(k)))
    for s in k:
        assert_true(reg.find_key(chord(ctrl(107), s)) != 0, key_name(s))
    for i in range(1, len(k)):
        assert_true(key_name(k[i - 1]) < key_name(k[i]))      # sorted, each once
    assert_true(115 in k)                                      # S: Save
    assert_equal(len(reg.chord_seconds(ctrl(97))), 0)          # Ctrl-A starts nothing


def test_the_box_comes_after_a_pause() raises:
    var app = turbo_app("")
    app.handle(key_event(ctrl(107)))                # Ctrl-K
    app.chord_tick(now_ns())
    app.draw()
    assert_true(screen(app).find("(Esc cancels)") < 0)        # typed quickly: no box
    app.chord_tick(app.chord_since + (KEY_BOX_MS + 1) * MS)
    app.draw()
    var s = screen(app)
    assert_true(s.find("Ctrl-K ... (Esc cancels)") >= 0, s)
    var save = key_name(115) + "  Save"
    assert_true(s.find(save) >= 0, s)
    assert_true(s.find(key_name(99) + "  Copy") >= 0, s)
    assert_equal(app.mode, M_NORMAL)                           # it takes no keyboard
    # the next key completes the sequence; the box goes
    app.handle(key_event(99))                       # Ctrl-K C: copy
    assert_false(app.chord_box)
    assert_equal(app.chord, 0)
    app.draw()
    assert_true(screen(app).find("(Esc cancels)") < 0)
    # Esc cancels
    app.handle(key_event(ctrl(107)))
    app.chord_tick(app.chord_since + (KEY_BOX_MS + 1) * MS)
    assert_true(app.chord_box)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.chord, 0)
    app.draw()
    assert_true(screen(app).find("(Esc cancels)") < 0)


def test_off_and_for_a_screen_reader() raises:
    var app = turbo_app("key_hints = false\n")
    app.handle(key_event(ctrl(107)))
    app.chord_tick(app.chord_since + (KEY_BOX_MS + 1) * MS)
    assert_false(app.chord_box)
    app.handle(key_event(KEY_ESC))
    var r = turbo_app("screen_reader = true\n")
    r.handle(key_event(ctrl(107)))
    assert_true(r.status.startswith("Ctrl-K then: "), r.status)
    assert_true(r.status.find(key_name(115) + "  Save") > 0, r.status)
    r.chord_tick(r.chord_since + (KEY_BOX_MS + 1) * MS)
    assert_false(r.chord_box)                       # (no box for a screen reader)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
