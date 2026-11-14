"""Tests for the vim interface's registers (P12-04): "a to "z, "A to "Z adding to them,
"0 the last copy, "_ the black hole, "+ and "* through TurboMojo's clipboard and OSC 52,
the unnamed register and TurboMojo's clipboard following each other, registers with
counts, operators, text objects, Visual mode and . - and the reference's row."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from appstate import App
from vim import *
from commands import CM_NEW
from term import KEY_ESC, KEY_ENTER, MOD_CTRL
from util import decode, to_str


def make(text: String) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.show_clock = False
    app.exec(CM_NEW)
    app.fit_windows()
    app.wins[0].buf.load(decode(text))
    app.keymap = KEYMAP_VIM             # (as the config file sets it; exec would save it)
    app.vim_reset()
    app.rebuild_keys(False)
    app.draw()
    return app^


def keys(mut app: App, s: String) raises:
    """Types `s`; `~` stands for Esc."""
    for c in decode(s):
        if c == 126:
            app.handle_key(KEY_ESC)
        else:
            app.handle_key(c)


def text(app: App) -> String:
    var b = app.wins[0].buf.copy()
    return to_str(b.get_text(0, 0, b.count() - 1, b.llen(b.count() - 1)))


def test_named() raises:
    var app = make("one two three")
    keys(app, "\"ayiw")
    assert_equal(to_str(app.vim.regs[0]), "one")
    assert_equal(to_str(app.vim.reg), "one")                # the unnamed one follows
    keys(app, "w\"bdiw")                                    # (a text object keeps its register)
    assert_equal(to_str(app.vim.regs[1]), "two")
    assert_equal(text(app), "one  three")
    keys(app, "$\"ap")
    assert_equal(text(app), "one  threeone")
    keys(app, "0\"b2P")                                     # a count
    assert_equal(text(app), "twotwoone  threeone")
    keys(app, "yiw")                                        # no name: "a and "b stay
    assert_equal(to_str(app.vim.regs[0]), "one")
    assert_equal(to_str(app.vim.regs[1]), "two")
    keys(app, "\"Ayl")                                      # "A adds to "a
    assert_equal(to_str(app.vim.regs[0]), "onet")
    assert_equal(to_str(app.vim.reg), "onet")               # (the unnamed one: all of "a)
    keys(app, "\"ajyy")                                     # a motion between: "a is not used
    assert_equal(to_str(app.vim.regs[0]), "onet")
    keys(app, "\"\"yl")                                     # "" is the unnamed register
    assert_equal(to_str(app.vim.reg), "t")
    keys(app, "\"zp")
    assert_true(app.status.startswith("E353: Nothing in register z"), app.status)
    keys(app, "\"?")
    assert_true(app.status.startswith("Not a register: \"?"), app.status)
    keys(app, "x")                                          # (and nothing is left waiting)
    assert_equal(to_str(app.vim.regs[0]), "onet")


def test_lines_and_appending() raises:
    var app = make("a\nb\nc")
    keys(app, "\"kyy")
    assert_true(app.vim.regs_lines[10])
    keys(app, "j\"Kyy")                                     # lines added to lines
    assert_equal(to_str(app.vim.regs[10]), "a\nb\n")
    keys(app, "G\"kp")
    assert_equal(text(app), "a\nb\nc\na\nb")
    app = make("ab\ncd")
    keys(app, "\"myl")                                      # characters, then a line added
    keys(app, "j\"Myy")
    assert_true(app.vim.regs_lines[12])
    assert_equal(to_str(app.vim.regs[12]), "a\ncd\n")
    app = make("ab\ncd")
    keys(app, "\"nyy")                                      # a line, then characters added
    keys(app, "j\"Nyl")
    assert_true(app.vim.regs_lines[13])
    assert_equal(to_str(app.vim.regs[13]), "ab\nc\n")


def test_zero_black_hole_clipboard() raises:
    var app = make("keep\nline2\nline3")
    keys(app, "yiw")
    keys(app, "jdd")                                        # a delete: "0 stays the copy
    assert_equal(to_str(app.vim.reg), "line2\n")
    assert_equal(to_str(app.vim.reg0), "keep")
    keys(app, "\"cyiw")                                     # a named copy leaves "0
    assert_equal(to_str(app.vim.reg0), "keep")
    keys(app, "\"0P")
    assert_equal(text(app), "keep\nkeepline3")
    keys(app, "\"_dd")                                      # the black hole: nothing kept
    assert_equal(text(app), "keep")
    assert_equal(to_str(app.vim.reg), "line3")              # (the "c copy's; "_ took nothing)
    assert_equal(to_str(app.clipboard), "line3")            # TurboMojo's clipboard follows the unnamed
    app.clipboard = decode("from ctrl-c")
    keys(app, "\"+P")                                       # "+ is TurboMojo's clipboard
    assert_equal(text(app), "from ctrl-ckeep")
    app.clipboard = decode("whole\n")
    keys(app, "\"*p")                                       # ending in a line break: a line
    assert_equal(text(app), "from ctrl-ckeep\nwhole")
    keys(app, "gg\"+yiw")
    assert_equal(to_str(app.clipboard), "from")
    assert_equal(app.vim.clip_sent, 1)                      # and the terminal's, with OSC 52
    keys(app, "yiw")
    assert_equal(app.vim.clip_sent, 1)                      # (not without "+)
    keys(app, "\"_p")                                       # the black hole puts nothing
    assert_equal(text(app), "from ctrl-ckeep\nwhole")


def test_visual_and_repeat() raises:
    var app = make("abc def")
    keys(app, "v\"qe")
    keys(app, "y")
    assert_equal(to_str(app.vim.regs[16]), "abc")
    app = make("abc def")
    keys(app, "ve\"qy")                                     # (the name after the selection too)
    assert_equal(to_str(app.vim.regs[16]), "abc")
    app = make("a b c d")
    keys(app, "\"rdw.")                                     # . keeps the register
    assert_equal(text(app), "c d")
    assert_equal(to_str(app.vim.regs[17]), "b ")
    keys(app, "\"s")
    keys(app, "~")                                          # Esc drops a named register
    keys(app, "yl")
    assert_equal(len(app.vim.regs[18]), 0)


def test_the_reference() raises:
    var md = vim_keys_markdown()
    assert_true(md.find("| \"x | Normal, Visual |") >= 0, md)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
