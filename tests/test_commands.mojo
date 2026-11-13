"""Tests for the command registry (src/commands.mojo) and the menus generated from it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from commands import *
from menu import build_menus
from term import (
    KEY_BACKSPACE, KEY_DELETE, KEY_INSERT, KEY_ENTER, KEY_TAB, KEY_ESC, KEY_UP, KEY_PGDN,
    MOD_SHIFT, MOD_ALT, MOD_CTRL, fkey, ctrl, alt,
)


def test_key_names() raises:
    assert_equal(key_name(fkey(1)), "F1")
    assert_equal(key_name(fkey(12)), "F12")
    assert_equal(key_name(fkey(9) | MOD_CTRL), "Ctrl-F9")
    assert_equal(key_name(fkey(3) | MOD_ALT), "Alt-F3")
    assert_equal(key_name(fkey(6) | MOD_SHIFT), "Shift-F6")
    assert_equal(key_name(ctrl(115)), "Ctrl-S")
    assert_equal(key_name(alt(120)), "Alt-X")
    assert_equal(key_name(alt(48)), "Alt-0")
    assert_equal(key_name(ctrl(32)), "Ctrl-Space")
    assert_equal(key_name(ctrl(47)), "Ctrl-/")
    assert_equal(key_name(ctrl(93)), "Ctrl-]")
    assert_equal(key_name(KEY_DELETE | MOD_CTRL), "Ctrl-Del")
    assert_equal(key_name(KEY_INSERT | MOD_SHIFT), "Shift-Ins")
    assert_equal(key_name(KEY_BACKSPACE | MOD_ALT), "Alt-Bksp")
    assert_equal(key_name(KEY_ENTER), "Enter")
    assert_equal(key_name(KEY_TAB | MOD_SHIFT), "Shift-Tab")
    assert_equal(key_name(KEY_ESC), "Esc")
    assert_equal(key_name(KEY_UP | MOD_CTRL | MOD_SHIFT), "Ctrl-Shift-Up")
    assert_equal(key_name(KEY_PGDN), "PgDn")


def test_plain_and_hot_char() raises:
    assert_equal(plain("Save ~a~s..."), "Save as...")
    assert_equal(plain("no marks"), "no marks")
    assert_equal(hot_char("Save ~a~s..."), 97)
    assert_equal(hot_char("~F~ile"), 102)   # lower-cased
    assert_equal(hot_char("none"), -1)


def test_ids_and_names_are_unique() raises:
    var r = build_registry()
    for i in range(len(r.cmds)):
        assert_true(r.cmds[i].id != CM_NONE)
        assert_true(r.cmds[i].name.byte_length() > 0)
        assert_true(r.cmds[i].hint.byte_length() > 0, "missing hint: " + r.cmds[i].name)
        # a hot letter is for picking the command in its menu; hidden ones have no menu
        assert_true(hot_char(r.cmds[i].title) >= 0 or r.is_hidden(r.cmds[i].id), "missing hot letter: " + r.cmds[i].name)
        for j in range(i + 1, len(r.cmds)):
            assert_true(r.cmds[i].id != r.cmds[j].id, "duplicate id: " + r.cmds[j].name)
            assert_true(r.cmds[i].name != r.cmds[j].name, "duplicate name: " + r.cmds[j].name)


def test_no_key_is_bound_twice() raises:
    var r = build_registry()
    var seen = List[Int]()
    for c in r.cmds:
        for k in c.keys:
            assert_false(k in seen, "key bound twice: " + key_name(k) + " (" + c.name + ")")
            seen.append(k)


def test_every_command_is_in_a_menu_and_every_menu_item_exists() raises:
    var r = build_registry()
    for c in r.cmds:
        var placed = False
        for p in r.layout:
            if p.cmd == c.id:
                placed = True
        # cursor commands are bound by keymaps and found in the palette; they have no menu
        assert_true(placed != r.is_hidden(c.id), "command must be in a menu or hidden, not both: " + c.name)
    for p in r.layout:
        assert_true(p.menu >= 0 and p.menu < len(r.menu_titles))
        if p.cmd != CM_NONE:
            assert_true(r.index_of(p.cmd) >= 0, "menu item without a command")


def test_hot_letters_are_unique_within_each_menu() raises:
    var r = build_registry()
    var menus = build_menus(r)
    var titles = List[Int]()
    for m in menus:
        var h = hot_char(m.title)
        assert_false(h in titles, "two menus share a hot letter: " + plain(m.title))
        titles.append(h)
        var letters = List[Int]()
        for it in m.items:
            if it.cmd == CM_NONE:
                continue
            var c = hot_char(it.label)
            assert_false(c in letters, "duplicate hot letter in " + plain(m.title) + ": " + plain(it.label))
            letters.append(c)


def expect(r: Registry, k: Int, cmd: Int) raises:
    assert_equal(r.find_key(k), cmd, "wrong command for " + key_name(k))


def test_v1_key_bindings_are_all_preserved() raises:
    var r = build_registry()
    expect(r, fkey(1), CM_HELP)
    expect(r, fkey(2), CM_SAVE)
    expect(r, ctrl(115), CM_SAVE)
    expect(r, fkey(3), CM_OPEN)
    expect(r, ctrl(111), CM_OPEN)
    expect(r, fkey(5), CM_ZOOM)
    expect(r, fkey(6), CM_NEXTWIN)
    expect(r, fkey(6) | MOD_SHIFT, CM_PREVWIN)
    expect(r, fkey(9), CM_BUILD)
    expect(r, ctrl(98), CM_BUILD)
    expect(r, fkey(9) | MOD_CTRL, CM_RUN)
    expect(r, fkey(8), CM_RUN)
    expect(r, fkey(9) | MOD_ALT, CM_FORMAT)
    expect(r, alt(120), CM_QUIT)
    expect(r, ctrl(113), CM_QUIT)
    expect(r, fkey(3) | MOD_ALT, CM_CLOSE)
    expect(r, ctrl(119), CM_CLOSE)
    expect(r, fkey(5) | MOD_ALT, CM_USERSCREEN)
    expect(r, fkey(7) | MOD_ALT, CM_PREVERR)
    expect(r, fkey(8) | MOD_ALT, CM_NEXTERR)
    expect(r, alt(48), CM_WINLIST)
    expect(r, KEY_BACKSPACE | MOD_ALT, CM_UNDO)
    expect(r, ctrl(122), CM_UNDO)
    expect(r, ctrl(121), CM_REDO)
    expect(r, ctrl(120), CM_CUT)
    expect(r, KEY_DELETE | MOD_SHIFT, CM_CUT)
    expect(r, ctrl(99), CM_COPY)
    expect(r, KEY_INSERT | MOD_CTRL, CM_COPY)
    expect(r, ctrl(118), CM_PASTE)
    expect(r, KEY_INSERT | MOD_SHIFT, CM_PASTE)
    expect(r, KEY_DELETE | MOD_CTRL, CM_CLEAR)
    expect(r, ctrl(97), CM_SELALL)
    expect(r, ctrl(47), CM_COMMENT)
    expect(r, ctrl(100), CM_DUPLINE)
    expect(r, ctrl(107), CM_DELLINE)
    expect(r, ctrl(32), CM_COMPLETE)
    expect(r, ctrl(102), CM_FIND)
    expect(r, ctrl(114), CM_REPLACE)
    expect(r, ctrl(108), CM_AGAIN)
    expect(r, ctrl(103), CM_GOTO)
    expect(r, ctrl(116), CM_SYMBOL)
    expect(r, ctrl(93), CM_MATCH)
    expect(r, ctrl(112), CM_PALETTE)
    expect(r, ctrl(110), CM_NEW)
    expect(r, fkey(2) | MOD_CTRL, CM_CANCEL)


def test_unbound_keys_map_to_nothing() raises:
    var r = build_registry()
    assert_equal(r.find_key(97), CM_NONE)              # plain letters are text
    assert_equal(r.find_key(KEY_ENTER), CM_NONE)
    assert_equal(r.find_key(KEY_DELETE), CM_NONE)      # plain Delete is an editing key
    assert_equal(r.find_key(fkey(10)), CM_NONE)        # F10 opens the menu bar, handled apart
    assert_equal(r.find_key(alt(102)), CM_NONE)        # Alt-F opens a menu, not a command


def test_menu_labels_show_the_primary_key() raises:
    var r = build_registry()
    assert_equal(r.key_label(CM_SAVE), "F2")
    assert_equal(r.key_label(CM_OPEN), "F3")
    assert_equal(r.key_label(CM_RUN), "Ctrl-F9")
    assert_equal(r.key_label(CM_UNDO), "Ctrl-Z")
    assert_equal(r.key_label(CM_QUIT), "Alt-X")
    assert_equal(r.key_label(CM_SAVEAS), "")
    assert_equal(r.all_keys_label(CM_SAVE), "F2, Ctrl-S")
    assert_equal(r.all_keys_label(CM_SAVEAS), "")
    assert_equal(r.key_label(9999), "")


def test_generated_menus() raises:
    var r = build_registry()
    var menus = build_menus(r)
    assert_equal(len(menus), 10)
    assert_equal(plain(menus[1].title), "File")
    assert_equal(menus[1].items[0].label, "~N~ew")
    assert_equal(menus[1].items[0].key, "Ctrl-N")
    assert_equal(menus[1].items[0].cmd, CM_NEW)
    assert_equal(menus[1].items[1].label, "Ne~w~ project...")
    assert_equal(menus[1].items[6].label, "-")
    assert_equal(plain(menus[9].title), "Help")
    # menu x positions are increasing and leave room for " Title "
    for i in range(1, len(menus)):
        assert_true(menus[i].x > menus[i - 1].x)
    # the same command can sit in two menus (Close is in File and Window)
    var n = 0
    for m in menus:
        for it in m.items:
            if it.cmd == CM_CLOSE:
                n += 1
    assert_equal(n, 2)


def test_rebind() raises:
    var r = build_registry()
    var keys = List[Int]()
    keys.append(fkey(4))
    assert_true(r.rebind("file.save", keys^))
    assert_equal(r.find_key(fkey(4)), CM_SAVE)
    assert_equal(r.find_key(fkey(2)), CM_NONE)
    assert_equal(build_menus(r)[1].items[3].key, "F4")
    assert_false(r.rebind("no.such.command", List[Int]()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
