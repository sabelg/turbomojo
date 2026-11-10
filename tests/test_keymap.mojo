"""Tests for two-key bindings (chords) and the Modern / Turbo-WordStar / Emacs keymaps."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from commands import *
from config import load_settings
from app import *
from appstate import App, M_NORMAL, M_DIALOG, M_MENU
from dialog import D_FIND, D_OPEN, D_GOTO
from term import (
    key_event, KEY_ESC, KEY_ENTER, KEY_UP, KEY_DOWN, KEY_BACKSPACE, MOD_ALT, MOD_CTRL, MOD_SHIFT, ctrl, alt, fkey,
)
from util import decode, to_str


def make(src: String, keymap: Int) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.keymap = keymap
    app.rebuild_keys(False)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode(src))
    return app^


def press(mut app: App, k: Int) raises:
    app.handle(key_event(k))


def pos(app: App) -> String:
    var t = app.top()
    return String(app.wins[t].cr) + ":" + String(app.wins[t].cc)


def text(app: App) -> String:
    return to_str(app.wins[app.top()].buf.all_text())


# ------------------------------------------------------------------- chords
def test_chord_names_round_trip() raises:
    var c = chord(ctrl(107), 115)
    assert_equal(key_name(c), "Ctrl-K S")
    assert_equal(parse_key("Ctrl-K S"), c)
    assert_equal(parse_key("ctrl-k s"), c)
    assert_equal(parse_key("Ctrl-X Ctrl-S"), chord(ctrl(120), ctrl(115)))
    assert_equal(key_name(chord(ctrl(120), ctrl(115))), "Ctrl-X Ctrl-S")
    assert_equal(parse_key("Ctrl-Q ["), chord(ctrl(113), 91))
    assert_equal(parse_key("F2 F3"), chord(fkey(2), fkey(3)))
    assert_equal(chord_first(c), ctrl(107))
    assert_equal(chord_first(ctrl(107)), 0)
    assert_equal(parse_key("Ctrl-K"), ctrl(107))
    assert_equal(parse_key("Ctrl-K S T"), 0)            # three keys are not supported
    assert_equal(parse_key("Ctrl-K nonsense"), 0)
    assert_equal(parse_key("Ctrl-K "), 0)


def test_registry_chords_and_bind() raises:
    var r = build_registry()
    assert_false(r.is_prefix(ctrl(107)))
    assert_equal(r.find_key(ctrl(107)), CM_DELLINE)
    r.bind(CM_SAVE, chord(ctrl(107), 115))
    assert_true(r.is_prefix(ctrl(107)))
    assert_equal(r.find_key(ctrl(107)), CM_NONE)         # the prefix no longer does anything alone
    assert_equal(r.find_chord(ctrl(107), 115), CM_SAVE)
    assert_equal(r.find_chord(ctrl(107), ctrl(115)), CM_SAVE)   # Ctrl held for the second key
    assert_equal(r.find_chord(ctrl(107), 83), CM_SAVE)          # capital letter
    assert_equal(r.find_chord(ctrl(107), 122), CM_NONE)
    assert_equal(r.find_key(fkey(2)), CM_SAVE)            # other bindings of the command stay
    # binding a single key that was a prefix removes the sequences under it
    r.bind(CM_DELLINE, ctrl(107))
    assert_false(r.is_prefix(ctrl(107)))
    assert_equal(r.find_key(ctrl(107)), CM_DELLINE)
    # a key moves from one command to another
    r.bind(CM_QUIT, fkey(2))
    assert_equal(r.find_key(fkey(2)), CM_QUIT)


def test_exact_chord_wins_over_the_relaxed_form() raises:
    var r = build_registry()
    r.bind(CM_SAVE, chord(ctrl(120), ctrl(115)))
    r.bind(CM_SAVEALL, chord(ctrl(120), 115))
    assert_equal(r.find_chord(ctrl(120), ctrl(115)), CM_SAVE)
    assert_equal(r.find_chord(ctrl(120), 115), CM_SAVEALL)


def test_no_key_or_chord_is_bound_twice_in_any_keymap() raises:
    for km in range(KEYMAP_COUNT):
        var r = build_registry()
        apply_keymap(r, km)
        var seen = List[Int]()
        for c in r.cmds:
            for k in c.keys:
                for s in seen:
                    assert_true(s != k, keymap_name(km) + ": " + key_name(k) + " is bound twice")
                seen.append(k)
        # a prefix key must not also be a complete binding
        for k in seen:
            if chord_first(k) != 0:
                assert_equal(r.find_key(chord_first(k)), CM_NONE, keymap_name(km) + ": " + key_name(chord_first(k)) + " is a prefix and a key")


def test_essential_commands_keep_a_key_in_every_keymap() raises:
    var must: List[Int] = [CM_SAVE, CM_OPEN, CM_QUIT, CM_CLOSE, CM_UNDO, CM_CUT, CM_COPY, CM_PASTE, CM_FIND, CM_REPLACE, CM_BUILD, CM_RUN, CM_PALETTE, CM_HELP]
    for km in range(KEYMAP_COUNT):
        var r = build_registry()
        apply_keymap(r, km)
        for id in must:
            assert_true(r.key_label(id).byte_length() > 0, keymap_name(km) + ": no key for " + r.cmds[r.index_of(id)].name)


def test_modern_keymap_is_unchanged() raises:
    var a = build_registry()
    var b = build_registry()
    apply_keymap(b, 0)
    for i in range(len(a.cmds)):
        assert_equal(a.all_keys_label(a.cmds[i].id), b.all_keys_label(b.cmds[i].id))
    assert_equal(a.find_key(ctrl(115)), CM_SAVE)
    assert_equal(a.key_label(CM_CUR_LEFT), "")            # cursor commands have no key by default


def test_keymap_names() raises:
    assert_equal(keymap_from_name("modern"), 0)
    assert_equal(keymap_from_name("turbo"), 1)
    assert_equal(keymap_from_name("wordstar"), 1)
    assert_equal(keymap_from_name("emacs"), 2)
    assert_equal(keymap_from_name("vim"), -1)
    for i in range(KEYMAP_COUNT):
        assert_equal(keymap_from_name(keymap_name(i)), i)


# ---------------------------------------------------------------- in the app
def test_chord_in_the_app_and_its_feedback() raises:
    var app = make("one\ntwo", 1)
    press(app, ctrl(113))                                 # Ctrl-Q ...
    assert_equal(app.status, "Ctrl-Q ...")
    assert_equal(app.chord, ctrl(113))
    press(app, 102)                                       # F: find
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_FIND)
    assert_equal(app.chord, 0)
    press(app, KEY_ESC)
    press(app, ctrl(113))
    press(app, 122)                                       # Ctrl-Q Z: nothing
    assert_equal(app.status, "Ctrl-Q Z is not a command")
    assert_equal(app.mode, M_NORMAL)
    assert_equal(text(app), "one\ntwo")                   # and the "z" was not typed
    press(app, ctrl(113))
    press(app, KEY_ESC)                                   # Esc gives up the sequence
    assert_equal(app.chord, 0)
    press(app, 120)
    assert_equal(text(app), "xone\ntwo")


def test_turbo_cursor_diamond_and_sequences() raises:
    var app = make("alpha beta\ngamma delta\nlast", 1)
    press(app, ctrl(100))                                 # Ctrl-D: right
    press(app, ctrl(100))
    assert_equal(pos(app), "0:2")
    press(app, ctrl(120))                                 # Ctrl-X: down
    assert_equal(pos(app), "1:2")
    press(app, ctrl(115))                                 # Ctrl-S: left
    assert_equal(pos(app), "1:1")
    press(app, ctrl(101))                                 # Ctrl-E: up
    assert_equal(pos(app), "0:1")
    press(app, ctrl(102))                                 # Ctrl-F: word right
    assert_equal(pos(app), "0:6")
    press(app, ctrl(97))                                  # Ctrl-A: word left
    assert_equal(pos(app), "0:0")
    press(app, ctrl(113))
    press(app, 100)                                       # Ctrl-Q D: end of line
    assert_equal(pos(app), "0:10")
    press(app, ctrl(113))
    press(app, ctrl(115))                                 # Ctrl-Q Ctrl-S: start of line
    assert_equal(pos(app), "0:0")
    press(app, ctrl(113))
    press(app, 99)                                        # Ctrl-Q C: end of text
    assert_equal(pos(app), "2:4")
    press(app, ctrl(113))
    press(app, 114)                                       # Ctrl-Q R: top
    assert_equal(pos(app), "0:0")
    press(app, ctrl(103))                                 # Ctrl-G: delete character
    assert_equal(to_str(app.wins[app.top()].buf.line(0)), "lpha beta")
    press(app, ctrl(116))                                 # Ctrl-T: delete word
    assert_equal(to_str(app.wins[app.top()].buf.line(0)), "beta")
    press(app, ctrl(121))                                 # Ctrl-Y: delete line
    assert_equal(text(app), "gamma delta\nlast")
    press(app, ctrl(102))
    press(app, ctrl(113))
    press(app, 121)                                       # Ctrl-Q Y: cut to end of line
    assert_equal(text(app), "gamma \nlast")
    assert_equal(to_str(app.clipboard), "delta")
    press(app, ctrl(107))
    press(app, 118)                                       # Ctrl-K V: paste
    assert_equal(text(app), "gamma delta\nlast")
    # function keys and Alt-X still work as in every keymap
    assert_equal(app.reg.find_key(fkey(2)), CM_SAVE)
    assert_equal(app.reg.find_key(alt(120)), CM_QUIT)
    assert_equal(app.reg.find_key(fkey(3)), CM_OPEN)


def test_turbo_insert_toggle_and_block_keys() raises:
    var app = make("    x\ny", 1)
    assert_true(app.insert_mode)
    press(app, ctrl(118))                                 # Ctrl-V
    assert_false(app.insert_mode)
    press(app, ctrl(118))
    press(app, ctrl(107))
    press(app, 117)                                       # Ctrl-K U: unindent
    assert_equal(text(app), "x\ny")
    press(app, ctrl(107))
    press(app, 105)                                       # Ctrl-K I: indent
    assert_equal(text(app), "    x\ny")
    press(app, ctrl(107))
    press(app, 114)                                       # Ctrl-K R: open
    assert_equal(app.dlg.kind, D_OPEN)


def test_emacs_keys() raises:
    var app = make("alpha beta\ngamma", 2)
    press(app, ctrl(101))                                 # C-e
    assert_equal(pos(app), "0:10")
    press(app, ctrl(97))                                  # C-a
    assert_equal(pos(app), "0:0")
    press(app, ctrl(102))                                 # C-f
    press(app, ctrl(102))
    press(app, ctrl(98))                                  # C-b
    assert_equal(pos(app), "0:1")
    press(app, ctrl(110))                                 # C-n
    assert_equal(pos(app), "1:1")
    press(app, ctrl(112))                                 # C-p
    assert_equal(pos(app), "0:1")
    press(app, ctrl(100))                                 # C-d
    assert_equal(to_str(app.wins[app.top()].buf.line(0)), "apha beta")
    press(app, ctrl(107))                                 # C-k: kill to end of line
    assert_equal(text(app), "a\ngamma")
    press(app, ctrl(107))                                 # at the end: the line break
    assert_equal(text(app), "agamma")
    press(app, ctrl(101))
    press(app, ctrl(121))                                 # C-y: yank
    assert_equal(text(app), "agamma\n")
    press(app, ctrl(120))
    press(app, 117)                                       # C-x u: undo
    assert_equal(text(app), "agamma")
    press(app, ctrl(120))
    press(app, 104)                                       # C-x h: select all
    assert_equal(to_str(app.wins[app.top()].selected_text()), "agamma")
    press(app, ctrl(119))                                 # C-w: cut
    assert_equal(text(app), "")
    press(app, ctrl(115))                                 # C-s: search
    assert_equal(app.dlg.kind, D_FIND)
    press(app, KEY_ESC)
    press(app, ctrl(120))
    press(app, ctrl(102))                                 # C-x C-f: open
    assert_equal(app.dlg.kind, D_OPEN)
    press(app, KEY_ESC)
    assert_equal(app.reg.find_chord(ctrl(120), ctrl(115)), CM_SAVE)
    assert_equal(app.reg.find_chord(ctrl(120), ctrl(99)), CM_QUIT)
    assert_equal(app.reg.find_key(alt(120)), CM_PALETTE)  # M-x


def test_cursor_commands_work_with_several_cursors() raises:
    var app = make("ab\ncd", 2)
    press(app, KEY_DOWN | MOD_CTRL | MOD_ALT)             # a second cursor below
    assert_equal(app.wins[app.top()].cursor_count(), 2)
    press(app, ctrl(102))                                 # C-f moves both
    press(app, 45)
    assert_equal(text(app), "a-b\nc-d")
    press(app, ctrl(97))
    press(app, 62)
    assert_equal(text(app), ">a-b\n>c-d")


def test_switching_keymaps_from_the_menu_commands() raises:
    var app = make("x", 0)
    assert_equal(app.reg.find_key(ctrl(115)), CM_SAVE)
    app.exec(CM_KEYMAP1)
    assert_equal(app.keymap, 1)
    assert_equal(app.status, "Keys: turbo")
    assert_equal(app.reg.find_key(ctrl(115)), CM_CUR_LEFT)
    # the menus show the keys of the active map
    var found = False
    for m in app.menus:
        for it in m.items:
            if it.cmd == CM_FIND:
                assert_equal(it.key, "Ctrl-Q F")
                found = True
    assert_true(found)
    var checks = app.checked()
    var has = False
    for c in checks:
        if c == CM_KEYMAP1:
            has = True
    assert_true(has, "the active keymap is ticked in the Options menu")
    app.exec(CM_KEYMAP0)
    assert_equal(app.reg.find_key(ctrl(115)), CM_SAVE)
    assert_equal(app.reg.find_key(ctrl(107)), CM_DELLINE)


def test_keymap_setting_and_user_keys_on_top() raises:
    var s = load_settings("[ui]\nkeymap = \"turbo\"\n[keys]\n\"file.save\" = [\"F2\", \"Ctrl-K Z\"]\n\"search.gotoLine\" = \"Ctrl-Q L\"\n", "")
    assert_equal(s.keymap, 1)
    assert_equal(len(s.warnings), 0)
    var app = App()
    app.scr.resize(80, 25)
    app.apply_settings(s)
    assert_equal(app.keymap, 1)
    assert_equal(len(app.config_warnings), 0)
    assert_equal(app.reg.find_chord(ctrl(107), 122), CM_SAVE)
    assert_equal(app.reg.find_chord(ctrl(107), 115), CM_NONE)    # the user's list replaced the map's
    assert_equal(app.reg.find_chord(ctrl(113), 108), CM_GOTO)
    assert_equal(app.reg.find_key(ctrl(100)), CM_CUR_RIGHT)       # the rest of the map is there
    # the user's keys survive a change of keymap
    app.exec(CM_KEYMAP2)
    assert_equal(app.reg.find_chord(ctrl(107), 122), CM_SAVE)
    var bad = load_settings("[ui]\nkeymap = \"vim\"\n", "")
    assert_equal(bad.keymap, 0)
    assert_equal(len(bad.warnings), 1)
    var bad2 = load_settings("[keys]\n\"file.save\" = \"Ctrl-K S T\"\n", "")
    var app2 = App()
    app2.apply_settings(bad2)
    assert_equal(len(app2.config_warnings), 1)


def test_chord_prefix_only_in_the_editor_not_in_dialogs() raises:
    var app = make("x", 1)
    app.exec(CM_FIND)
    press(app, ctrl(107))                                 # inside a dialog it is not a prefix
    assert_equal(app.chord, 0)
    press(app, KEY_ESC)
    assert_equal(app.mode, M_NORMAL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
