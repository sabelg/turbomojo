"""Tests for the vim interface, first part (P12-01): `ui.keymap = "vim"`; Normal, Insert
and Visual (characters and lines) modes; h j k l 0 $ + with counts; i a I A o O; x; v V
with d x y and o; the mode on the status line and the cursor's shape; and what stays
TurboMojo's (Ctrl and Alt keys, F-keys) - in every mode - and the other keymaps."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from appstate import App, M_NORMAL
from vim import *
from commands import CM_NEW, keymap_name, keymap_from_name, KEYMAP_COUNT, CM_KEYMAP3
from helpbook import keymap_markdown
from term import KEY_ESC, KEY_ENTER, KEY_BACKSPACE, KEY_LEFT, KEY_DOWN, KEY_END, KEY_HOME, MOD_CTRL, MOD_SHIFT
from util import decode, to_str


def make(text: String, vim: Bool = True) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.show_clock = False
    app.exec(CM_NEW)
    app.fit_windows()
    app.wins[0].buf.load(decode(text))
    if vim:
        app.keymap = KEYMAP_VIM         # (as the config file sets it; exec would save it)
        app.vim_reset()
        app.rebuild_keys(False)
    app.draw()
    return app^


def keys(mut app: App, s: String) raises:
    for c in decode(s):
        app.handle_key(c)


def at(app: App) -> String:
    return String(app.wins[0].cr) + ":" + String(app.wins[0].cc)


def test_the_keymap() raises:
    assert_equal(KEYMAP_COUNT, 4)
    assert_equal(keymap_name(KEYMAP_VIM), "vim")
    assert_equal(keymap_from_name("vim"), KEYMAP_VIM)
    assert_equal(vim_mode_name(VM_NORMAL), "NORMAL")
    assert_equal(vim_mode_name(VM_INSERT), "INSERT")
    assert_equal(vim_mode_name(VM_VISUAL), "VISUAL")
    assert_equal(vim_mode_name(VM_VLINE), "V-LINE")
    var md = keymap_markdown()
    assert_true(md.find("## Vim (Options > Keys: Vim)") > 0 and md.find("| o O | Normal | Open a line below / above and insert |") > 0, md)


def test_normal_moves() raises:
    var app = make("abcdef\nxy\n\n    indented line\nlast")
    keys(app, "l")
    assert_equal(at(app), "0:1")
    keys(app, "3l")
    assert_equal(at(app), "0:4")
    keys(app, "9l")                                     # not past the last character
    assert_equal(at(app), "0:5")
    keys(app, "j")                                      # a shorter line: its last character
    assert_equal(at(app), "1:1")
    keys(app, "h0")
    assert_equal(at(app), "1:0")
    keys(app, "$")
    assert_equal(at(app), "1:1")
    keys(app, "j")                                      # an empty line
    assert_equal(at(app), "2:0")
    keys(app, "+")                                      # down, to the first non-blank
    assert_equal(at(app), "3:4")
    keys(app, "k2k")                                    # (the column is kept, as in vim)
    assert_equal(at(app), "0:4")
    keys(app, "0")
    keys(app, "12j")
    assert_equal(at(app), "4:0")
    app.handle_key(KEY_HOME)
    app.handle_key(KEY_END)
    assert_equal(at(app), "4:3")
    app.handle_key(KEY_LEFT)
    app.handle_key(KEY_BACKSPACE)
    assert_equal(at(app), "4:1")
    keys(app, "kk")
    app.handle_key(KEY_ENTER)                            # +: the next line's first character
    assert_equal(at(app), "3:4")
    # letters do not go into the text in Normal mode
    var before = to_str(app.wins[0].buf.get_text(0, 0, 4, 4))
    keys(app, "qQ;")
    assert_equal(to_str(app.wins[0].buf.get_text(0, 0, 4, 4)), before)
    assert_true(app.status.startswith("Not a vim command: ;"), app.status)
    assert_equal(app.vim.mode, VM_NORMAL)


def test_insert() raises:
    var app = make("    abc\nend")
    keys(app, "lli")                                     # i: before the cursor
    assert_equal(app.vim.mode, VM_INSERT)
    keys(app, "XY")                                      # typing goes in
    assert_equal(to_str(app.wins[0].buf.line(0)), "  XY  abc")
    app.handle_key(KEY_ESC)                              # back, on the last character typed
    assert_equal(app.vim.mode, VM_NORMAL)
    assert_equal(at(app), "0:3")
    keys(app, "a!")                                      # a: after it
    app.handle_key(KEY_ESC)
    assert_equal(to_str(app.wins[0].buf.line(0)), "  XY!  abc")
    keys(app, "A;")                                      # A: at the end
    app.handle_key(KEY_ESC)
    assert_equal(to_str(app.wins[0].buf.line(0)), "  XY!  abc;")
    keys(app, "I#")                                      # I: at the first non-blank
    app.handle_key(KEY_ESC)
    assert_equal(to_str(app.wins[0].buf.line(0)), "  #XY!  abc;")
    keys(app, "ob")                                      # o: a line below, indented as this one
    app.handle_key(KEY_ESC)
    assert_equal(to_str(app.wins[0].buf.line(1)), "  b")
    keys(app, "jOa")                                     # O: a line above "end"
    app.handle_key(KEY_ESC)
    assert_equal(to_str(app.wins[0].buf.line(2)), "a")
    assert_equal(to_str(app.wins[0].buf.line(3)), "end")
    assert_equal(app.wins[0].buf.count(), 4)
    # in Insert mode Ctrl keys and Enter are TurboMojo's as ever
    keys(app, "A")
    app.handle_key(KEY_ENTER)
    keys(app, "z")
    assert_equal(to_str(app.wins[0].buf.line(3)), "z")
    app.handle_key(KEY_ESC)
    # with TurboMojo's Overwrite on, i still inserts
    app.insert_mode = False
    keys(app, "0iy")
    assert_equal(to_str(app.wins[0].buf.line(3)), "yz")
    app.handle_key(KEY_ESC)


def test_x_and_undo() raises:
    var app = make("hello world")
    keys(app, "x")
    assert_equal(to_str(app.wins[0].buf.line(0)), "ello world")
    keys(app, "3x")
    assert_equal(to_str(app.wins[0].buf.line(0)), "o world")
    assert_equal(to_str(app.vim.reg), "ell")
    keys(app, "$20x")                                    # not past the line's end
    assert_equal(to_str(app.wins[0].buf.line(0)), "o worl")
    assert_equal(at(app), "0:5")
    app.handle_key(ord("z") | MOD_CTRL)                  # Ctrl-Z: TurboMojo's undo, in Normal mode
    assert_equal(to_str(app.wins[0].buf.line(0)), "o world")


def test_visual() raises:
    var app = make("one two\nthree\nfour\nfive")
    keys(app, "lv")
    assert_equal(app.vim.mode, VM_VISUAL)
    assert_equal(to_str(app.wins[0].selected_text()), "n")        # the cursor's character is in it
    keys(app, "ll")
    assert_equal(to_str(app.wins[0].selected_text()), "ne ")
    keys(app, "o")                                                  # the other end
    assert_equal(at(app), "0:1")
    assert_equal(to_str(app.wins[0].selected_text()), "ne ")
    keys(app, "y")                                                  # copied; Normal again
    assert_equal(app.vim.mode, VM_NORMAL)
    assert_equal(to_str(app.vim.reg), "ne ")
    assert_equal(to_str(app.clipboard), "ne ")
    assert_false(app.wins[0].has_sel())
    keys(app, "vld")
    assert_equal(to_str(app.wins[0].buf.line(0)), "o two")
    # whole lines
    keys(app, "jVj")
    assert_equal(app.vim.mode, VM_VLINE)
    assert_equal(to_str(app.wins[0].selected_text()), "three\nfour\n")
    keys(app, "v")                                                  # V -> v: characters
    assert_equal(app.vim.mode, VM_VISUAL)
    keys(app, "V")
    keys(app, "d")
    assert_equal(app.wins[0].buf.count(), 2)
    assert_equal(to_str(app.wins[0].buf.line(1)), "five")
    assert_true(app.vim.reg_lines)
    assert_equal(to_str(app.vim.reg), "three\nfour\n")
    # the last line: the line break before it goes too, no empty line is left
    keys(app, "Vx")
    assert_equal(app.wins[0].buf.count(), 1)
    assert_equal(to_str(app.wins[0].buf.line(0)), "o two")
    # Esc leaves Visual mode and the selection
    keys(app, "v")
    app.handle_key(KEY_ESC)
    assert_equal(app.vim.mode, VM_NORMAL)
    assert_false(app.wins[0].has_sel())
    assert_equal(app.wins[0].vsel, 0)


def test_the_screen() raises:
    var app = make("abc")
    app.scr.resize(110, 25)
    app.fit_windows()
    app.draw()
    assert_true(app.scr.cblock and not app.scr.cbar)                # Normal: a block
    app.status_until = 0
    app.draw()
    var status = to_str(app.scr.row_text(24))
    assert_true(status.find("NORMAL") > 0, status)
    keys(app, "i")
    app.status_until = 0
    app.draw()
    assert_true(app.scr.cbar)                                         # Insert: a bar
    status = to_str(app.scr.row_text(24))
    assert_true(status.find("INSERT") > 0, status)
    # the terminal is asked for a bar: CSI 5 SP q
    var out = List[UInt8]()
    app.scr.render(out)
    var sent = String("")
    for b in out:
        sent += chr(Int(b))
    assert_true(sent.find("\x1b[5 q") >= 0)


def test_other_keymaps_and_shift_arrows() raises:
    var app = make("abc", False)
    keys(app, "jx")                                                   # Modern: letters are typed
    assert_equal(to_str(app.wins[0].buf.line(0)), "jxabc")
    var v = make("abcd")
    v.handle_key(KEY_LEFT | MOD_SHIFT)                                # Shift-arrows: TurboMojo's selection
    keys(v, "ll")
    v.handle_key(KEY_LEFT | MOD_SHIFT)
    assert_true(v.wins[0].has_sel())
    assert_equal(v.vim.mode, VM_NORMAL)
    # leaving vim: Normal mode's selection marks go
    keys(v, "v")
    v.keymap = 0
    v.vim_reset()
    assert_equal(v.wins[0].vsel, 0)
    v.wins[0].sel = False
    v.handle_key(KEY_END)
    keys(v, "q")                                                      # Modern again: typed
    assert_equal(to_str(v.wins[0].buf.line(0)), "abcdq")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
