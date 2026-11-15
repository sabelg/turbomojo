"""Tests for the vim interface's motions and operators (P12-02): w b e W B E 0 ^ $ gg G
f t F T ; , % { } with counts; d c y > < with motions, text objects and counts (dd, 3dw,
cw, yy, di(, ci", dap); x X D C s S Y r J p P; `.`; u and Ctrl-R; the operators on a
Visual selection; and the motion engine on a text alone."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from appstate import App
from vim import *
from vim_motion import *
from buffer import TextBuffer
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


def at(app: App) -> String:
    return String(app.wins[0].cr) + ":" + String(app.wins[0].cc)


def text(app: App) -> String:
    var b = app.wins[0].buf.copy()
    return to_str(b.get_text(0, 0, b.count() - 1, b.llen(b.count() - 1)))


def test_word_motions() raises:
    var app = make("foo.bar  baz\n\n  qux(1, 2)\nend")
    var w = ["0:3", "0:4", "0:9", "1:0", "2:2", "2:5", "2:6", "2:7", "2:9", "2:10", "3:0"]
    for i in range(len(w)):
        keys(app, "w")
        assert_equal(at(app), String(w[i]))
    keys(app, "w")                                      # the text's end: the last character
    assert_equal(at(app), "3:2")
    var b = ["3:0", "2:10", "2:9", "2:7", "2:6", "2:5", "2:2", "1:0", "0:9", "0:4", "0:3", "0:0"]
    for i in range(len(b)):
        keys(app, "b")
        assert_equal(at(app), String(b[i]))
    var e = ["0:2", "0:3", "0:6", "0:11", "2:4", "2:5"]
    for i in range(len(e)):
        keys(app, "e")
        assert_equal(at(app), String(e[i]))
    keys(app, "gg3w")
    assert_equal(at(app), "0:9")
    keys(app, "ggW")                                    # W: words between blanks
    assert_equal(at(app), "0:9")
    keys(app, "WW")
    assert_equal(at(app), "2:2")
    keys(app, "W")
    assert_equal(at(app), "2:9")
    keys(app, "E")
    assert_equal(at(app), "2:10")
    keys(app, "B")
    assert_equal(at(app), "2:9")
    keys(app, "B")
    assert_equal(at(app), "2:2")


def test_line_motions() raises:
    var app = make("  if (a[1] == b) {\n    x = 1\n  }\n\npara two\nline\n\nend")
    keys(app, "^")
    assert_equal(at(app), "0:2")
    keys(app, "$")
    assert_equal(at(app), "0:17")
    keys(app, "0f(")
    assert_equal(at(app), "0:5")
    keys(app, "%")
    assert_equal(at(app), "0:15")
    keys(app, "%")
    assert_equal(at(app), "0:5")
    keys(app, ";")                                      # no other ( to the right
    assert_equal(at(app), "0:5")
    keys(app, "f=")
    assert_equal(at(app), "0:11")
    keys(app, ";")
    assert_equal(at(app), "0:12")
    keys(app, ",")
    assert_equal(at(app), "0:11")
    keys(app, "0t]")
    assert_equal(at(app), "0:8")
    keys(app, ";")                                      # t again: not stuck in front of it
    assert_equal(at(app), "0:8")
    keys(app, "F(")
    assert_equal(at(app), "0:5")
    keys(app, "$T(")
    assert_equal(at(app), "0:6")
    keys(app, "2f=")
    assert_equal(at(app), "0:12")
    keys(app, "$%")                                     # the block's closing brace
    assert_equal(at(app), "2:2")
    keys(app, "gg")
    assert_equal(at(app), "0:2")
    keys(app, "G")
    assert_equal(at(app), "7:0")
    keys(app, "2G")
    assert_equal(at(app), "1:4")
    keys(app, "-")
    assert_equal(at(app), "0:2")
    keys(app, "+")
    assert_equal(at(app), "1:4")
    keys(app, "3gg")
    assert_equal(at(app), "2:2")
    keys(app, "gg}")
    assert_equal(at(app), "3:0")
    keys(app, "}")
    assert_equal(at(app), "6:0")
    keys(app, "}")
    assert_equal(at(app), "7:2")
    keys(app, "{")
    assert_equal(at(app), "6:0")
    keys(app, "2{")
    assert_equal(at(app), "0:0")
    keys(app, "fz")                                     # not on the line: the cursor stays
    assert_equal(at(app), "0:0")
    keys(app, "gx")
    assert_true(app.status.startswith("Not a vim command: gx"), app.status)


def test_delete_change_yank() raises:
    var app = make("one two three four")
    keys(app, "dw")
    assert_equal(text(app), "two three four")
    assert_equal(to_str(app.vim.reg), "one ")
    keys(app, "d2w")
    assert_equal(text(app), "four")
    app = make("one two three four five six seven")
    keys(app, "2d2w")                                   # the counts multiply
    assert_equal(text(app), "five six seven")
    app = make("ab cd\nef")
    keys(app, "wdw")                                    # the line's last word: the line break stays
    assert_equal(text(app), "ab \nef")
    app = make("ab cd\n  ef")
    keys(app, "wdw")                                    # (the next line indented too)
    assert_equal(text(app), "ab \n  ef")
    app = make("one two")
    keys(app, "de")
    assert_equal(text(app), " two")
    app = make("one two")
    keys(app, "cwONE~")                                 # cw: the blank after the word stays
    assert_equal(text(app), "ONE two")
    assert_equal(at(app), "0:2")
    assert_equal(app.vim.mode, VM_NORMAL)
    keys(app, "$cwx~")                                  # on the word's last character: just it
    assert_equal(text(app), "ONE twx")
    app = make("ab cd")
    keys(app, "lcwx~")                                  # (with a word after it)
    assert_equal(text(app), "ax cd")
    app = make("hello world")
    keys(app, "wCthere~")
    assert_equal(text(app), "hello there")
    app = make("hello world")
    keys(app, "wD")
    assert_equal(text(app), "hello ")
    assert_equal(at(app), "0:5")
    app = make("abcdef")
    keys(app, "3lX")
    assert_equal(text(app), "abdef")
    assert_equal(at(app), "0:2")
    keys(app, "sZ~")
    assert_equal(text(app), "abZef")
    keys(app, "0d$")
    assert_equal(text(app), "")
    app = make("one two")
    keys(app, "ywP")
    assert_equal(text(app), "one one two")
    keys(app, "0y$")
    assert_equal(to_str(app.vim.reg), "one one two")
    assert_equal(text(app), "one one two")
    app = make("say(a, b) + c")
    keys(app, "ytc")
    assert_equal(to_str(app.vim.reg), "say(a, b) + ")
    keys(app, "dfa")                                    # f is inclusive
    assert_equal(text(app), "y(a, b) + c")
    keys(app, "dFy")                                    # F is not: nothing to the left
    assert_equal(text(app), "y(a, b) + c")
    keys(app, "f)d%")
    assert_equal(text(app), "y + c")


def test_lines() raises:
    var app = make("a\nb\nc\nd")
    keys(app, "jdd")
    assert_equal(text(app), "a\nc\nd")
    assert_equal(at(app), "1:0")
    assert_true(app.vim.reg_lines)
    assert_equal(to_str(app.vim.reg), "b\n")
    keys(app, "p")
    assert_equal(text(app), "a\nc\nb\nd")
    assert_equal(at(app), "2:0")
    keys(app, "ggP")
    assert_equal(text(app), "b\na\nc\nb\nd")
    keys(app, "G")
    keys(app, "p")                                      # below the last line
    assert_equal(text(app), "b\na\nc\nb\nd\nb")
    keys(app, "dd")                                     # the last line
    assert_equal(text(app), "b\na\nc\nb\nd")
    assert_equal(at(app), "4:0")
    keys(app, "gg2dd")
    assert_equal(text(app), "c\nb\nd")
    keys(app, "dj")
    assert_equal(text(app), "d")
    app = make("a\nb\nc\nd")
    keys(app, "jdG")
    assert_equal(text(app), "a")
    app = make("a\nb\nc\nd")
    keys(app, "jyyjp")
    assert_equal(text(app), "a\nb\nc\nb\nd")
    keys(app, "gg3Yjjj")
    assert_equal(to_str(app.vim.reg), "a\nb\nc\n")
    keys(app, "ggdk")                                   # nothing above: nothing happens
    assert_equal(text(app), "a\nb\nc\nb\nd")
    app = make("    x = 1\ny")
    keys(app, "ccz = 2~")                               # cc keeps the indentation
    assert_equal(text(app), "    z = 2\ny")
    keys(app, "jSw~")
    assert_equal(text(app), "    z = 2\nw")
    app = make("x\n\ny")
    keys(app, ">>")
    assert_equal(text(app), "    x\n\ny")
    keys(app, ">G")                                     # (empty lines stay empty)
    assert_equal(text(app), "        x\n\n    y")
    keys(app, "<j")
    assert_equal(text(app), "    x\n\n    y")
    keys(app, "G<<")
    assert_equal(text(app), "    x\n\ny")
    app = make("a\n    b\nc\nd")
    keys(app, "J")
    assert_equal(text(app), "a b\nc\nd")
    assert_equal(at(app), "0:1")
    keys(app, "3J")
    assert_equal(text(app), "a b c d")
    keys(app, "J")                                      # no line to join
    assert_equal(text(app), "a b c d")


def test_text_objects() raises:
    var app = make("foo bar baz")
    keys(app, "wdiw")
    assert_equal(text(app), "foo  baz")
    app = make("foo bar baz")
    keys(app, "wdaw")
    assert_equal(text(app), "foo baz")
    app = make("foo bar")
    keys(app, "$daw")                                   # the last word: the blanks before it
    assert_equal(text(app), "foo")
    app = make("f(a, (b), c) + g")
    keys(app, "fadi(")
    assert_equal(text(app), "f() + g")
    app = make("f(a, (b), c) + g")
    keys(app, "fbda(")                                  # the innermost pair
    assert_equal(text(app), "f(a, , c) + g")
    app = make("f(a, (b), c) + g")
    keys(app, "$F)di)")                                 # on the closing bracket
    assert_equal(text(app), "f() + g")
    app = make("f(a, b) + g")
    keys(app, "$di(")                                   # outside any: nothing
    assert_equal(text(app), "f(a, b) + g")
    app = make("x = \"hel\\\"lo\" + y")
    keys(app, "ci\"bye~")
    assert_equal(text(app), "x = \"bye\" + y")
    app = make("x = 'a' + 'b'")
    keys(app, "da'")                                    # the first pair after the cursor, with its blank
    assert_equal(text(app), "x = + 'b'")
    app = make("v = a[1][2]")
    keys(app, "f2di[")
    assert_equal(text(app), "v = a[1][]")
    app = make("fn {\n  a\n  b\n}\nz")
    keys(app, "jdi{")                                   # a block: the lines inside
    assert_equal(text(app), "fn {\n}\nz")
    app = make("fn {\n  a\n  b\n}\nz")
    keys(app, "jjci{q~")                                # (the indentation stays)
    assert_equal(text(app), "fn {\n  q\n}\nz")
    app = make("fn {\n  a\n}\nz")
    keys(app, "jda{")
    assert_equal(text(app), "fn \nz")
    app = make("p1\np1b\n\np2\n\np3")
    keys(app, "dip")
    assert_equal(text(app), "\np2\n\np3")
    app = make("p1\np1b\n\np2\n\np3")
    keys(app, "dap")
    assert_equal(text(app), "p2\n\np3")
    app = make("p1\n\np2")
    keys(app, "Gdap")                                   # the last paragraph: the empty lines before it
    assert_equal(text(app), "p1")
    app = make("p1\np1b\n\np2")
    keys(app, "d}")                                     # from a paragraph's start: whole lines
    assert_equal(text(app), "\np2")
    app = make("p1\np1b\n\np2")
    keys(app, "ld}")                                    # from inside a line: up to its end
    assert_equal(text(app), "p\n\np2")
    app = make("a b")
    keys(app, "dix")                                    # not a text object
    assert_equal(text(app), "a b")
    keys(app, "x")                                      # and nothing is left waiting
    assert_equal(text(app), " b")


def test_put_replace_count() raises:
    var app = make("ab")
    keys(app, "x")
    assert_equal(text(app), "b")
    keys(app, "p")
    assert_equal(text(app), "ba")
    assert_equal(at(app), "0:1")
    keys(app, "3P")
    assert_equal(text(app), "baaaa")
    assert_equal(at(app), "0:3")
    app = make("abc")
    keys(app, "rx")
    assert_equal(text(app), "xbc")
    keys(app, "2ry")
    assert_equal(text(app), "yyc")
    assert_equal(at(app), "0:1")
    keys(app, "5rz")                                    # not enough characters: nothing
    assert_equal(text(app), "yyc")
    keys(app, "r~x")                                    # Esc cancels r
    assert_equal(text(app), "yc")
    app = make("ab\ncd")
    keys(app, "lvjy")                                   # characters over two lines, the last one in
    assert_equal(to_str(app.vim.reg), "b\ncd")
    keys(app, "P")                                      # several lines: the cursor at the start
    assert_equal(text(app), "ab\ncdb\ncd")
    assert_equal(at(app), "0:1")
    app = make("abc")
    keys(app, "p")
    assert_true(app.status.startswith("Nothing to put"), app.status)
    keys(app, "d~x")                                    # Esc cancels a waiting operator
    assert_equal(text(app), "bc")


def test_repeat_undo_redo() raises:
    var app = make("a b c d e f")
    keys(app, "dw")
    keys(app, ".")
    assert_equal(text(app), "c d e f")
    keys(app, "2.")
    assert_equal(text(app), "e f")
    keys(app, "w")                                      # a motion is not a change
    keys(app, ".")
    assert_equal(text(app), "e ")
    app = make("one two three")
    keys(app, "cwX~w.")
    assert_equal(text(app), "X X three")
    keys(app, "u")                                      # the change and its typing: one step
    assert_equal(text(app), "X two three")
    app.handle_key(114 | MOD_CTRL)                      # Ctrl-R
    assert_equal(text(app), "X X three")
    keys(app, "uu")
    assert_equal(text(app), "one two three")
    keys(app, "2")
    app.handle_key(114 | MOD_CTRL)
    assert_equal(text(app), "X X three")
    app = make("a\nb\nc")
    keys(app, "A!~j.j.")
    assert_equal(text(app), "a!\nb!\nc!")
    keys(app, "u")
    assert_equal(text(app), "a!\nb!\nc")
    app = make("a\nb")
    keys(app, "ox~")
    app.handle_key(KEY_ENTER)                           # (Enter: the next line)
    keys(app, ".")
    assert_equal(text(app), "a\nx\nb\nx")
    app = make("abc")
    keys(app, "x.")
    assert_equal(text(app), "c")
    app = make("ab\ncd\nef")
    keys(app, "Vd.")                                    # a Visual change, repeated
    assert_equal(text(app), "ef")


def test_visual_operators() raises:
    var app = make("abc def")
    keys(app, "vey")
    assert_equal(to_str(app.vim.reg), "abc")
    assert_equal(app.vim.mode, VM_NORMAL)
    keys(app, "wvecX~")
    assert_equal(text(app), "abc X")
    app = make("a\nb\nc")
    keys(app, "Vj>")
    assert_equal(text(app), "    a\n    b\nc")
    keys(app, "Vj<")
    assert_equal(text(app), "a\nb\nc")
    keys(app, "VjJ")
    assert_equal(text(app), "a b\nc")
    app = make("a\nb\nc")
    keys(app, "jVjc")
    assert_equal(app.vim.mode, VM_INSERT)
    keys(app, "z~")
    assert_equal(text(app), "a\nz")
    app = make("abcd")
    keys(app, "lvlx")
    assert_equal(text(app), "ad")
    keys(app, "vG")                                     # motions of this part work in Visual mode
    assert_equal(app.vim.mode, VM_VISUAL)
    keys(app, "q")
    assert_true(app.status.startswith("Not a vim command in Visual mode"), app.status)


def test_the_engine() raises:
    var b = TextBuffer()
    b.load(decode("x\n\n  (a [b\n c] {)\n\nw"))
    var p = word_back(b, 2, 2, False)                  # back over an empty line: it is a word
    assert_equal(String(p.r) + ":" + String(p.c), "1:0")
    var m = match_pair(b, 2, 0)                         # the first bracket on the line
    assert_equal(String(m.r) + ":" + String(m.c), "3:5")
    m = match_pair(b, 2, 5)
    assert_equal(String(m.r) + ":" + String(m.c), "3:2")
    var lt = TextBuffer()
    lt.load(decode("if a < b (c)"))
    m = match_pair(lt, 0, 0)                            # < is not a bracket for %
    assert_equal(String(m.r) + ":" + String(m.c), "0:11")
    m = match_pair(b, 3, 4)                             # a { with no partner
    assert_equal(m.r, -1)
    assert_equal(find_in_line(decode("a.b.c"), 0, 116, 46, 1, False), 0)
    assert_equal(find_in_line(decode("a.b.c"), 0, 116, 46, 1, True), 2)
    assert_equal(find_in_line(decode("a.b.c"), 4, 84, 46, 1, True), 2)
    assert_equal(find_in_line(decode("a.b.c"), 4, 70, 46, 2, False), 1)
    var s = motion_span(b, 0, 0, VimMove(True, 2, 0, VK_EXCL))
    assert_true(s.lines and s.r1 == 0 and s.r2 == 1)
    s = motion_span(b, 2, 3, VimMove(True, 2, 1, VK_INCL))   # backwards, inclusive
    assert_true(not s.lines and s.c1 == 1 and s.c2 == 4)
    var o = vim_object(b, 2, 3, True, 40)
    assert_true(o.ok and o.r1 == 2 and o.c1 == 3 and o.r2 == 3 and o.c2 == 5)
    o = vim_object(b, 2, 7, True, 91)                   # inside [ ] over a line break
    assert_true(o.ok and o.r1 == 2 and o.c1 == 6 and o.r2 == 3 and o.c2 == 2, String(o.r1) + ":" + String(o.c1) + "-" + String(o.r2) + ":" + String(o.c2))
    assert_equal(vcls(0xE9, False), 2)                  # é is a word's letter
    assert_equal(vcls(46, True), 1)
    assert_equal(vcls(9, False), 0)


def test_vim_polyglot_comment_toggle() raises:
    var app = make("const x = 5;\n")
    app.wins[0].path = "main.zig"
    keys(app, "gcc")
    assert_equal(text(app), "// const x = 5;\n")
    keys(app, "gcc")
    assert_equal(text(app), "const x = 5;\n")

    var app_mojo = make("var x = 5\n")
    app_mojo.wins[0].path = "main.mojo"
    keys(app_mojo, "gcc")
    assert_equal(text(app_mojo), "# var x = 5\n")


def test_the_reference() raises:
    var md = vim_keys_markdown()
    for row in ["| w b e | Normal, Visual |", "| d c y | Normal |", "| ip ap | after d c y |", "| . | Normal | Repeat the last change |", "| u Ctrl-R | Normal | Undo / redo |"]:
        assert_true(md.find(String(row)) >= 0, String(row))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
