"""Tests for the vim interface's search and command line (P12-03): vim's patterns as
TurboMojo's regular expressions, :s replacements and flags, command lines split into
range, name, ! and argument; / ? n N * # (with counts, going round the end, after an
operator); the command line on the status row; :w :q :q! :wq :x :e :N :s :%s :'<,'>s :d
:y :noh :set; TurboMojo's commands by name; and . not repeating a : command."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from vim import *
from vim_cmd import *
from commands import CM_NEW, CM_FIND, Command
from term import KEY_ESC, KEY_ENTER, KEY_BACKSPACE, MOD_CTRL
from config import read_text
from signals import own_pid
from util import decode, to_str, env_or, run_system


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
    """Types `s`: `~` is Esc, `|` is Enter."""
    for c in decode(s):
        if c == 126:
            app.handle_key(KEY_ESC)
        elif c == 124:
            app.handle_key(KEY_ENTER)
        else:
            app.handle_key(c)


def at(app: App) -> String:
    var t = app.top()
    return String(app.wins[t].cr) + ":" + String(app.wins[t].cc)


def text(app: App) -> String:
    var t = app.top()
    var b = app.wins[t].buf.copy()
    return to_str(b.get_text(0, 0, b.count() - 1, b.llen(b.count() - 1)))


def pat(s: String) -> String:
    return to_str(vim_pattern(decode(s)).pat)


def test_patterns() raises:
    assert_equal(pat("f(a|b)"), "f\\(a\\|b\\)")             # bare ( | ) are characters
    assert_equal(pat("\\(ab\\)\\+x\\?"), "(ab)+x?")
    assert_equal(pat("a\\|b"), "a|b")
    assert_equal(pat("\\<foo\\>"), "\\bfoo\\b")
    assert_equal(pat("a\\{2,3}b{1}"), "a{2,3}b\\{1\\}")
    assert_equal(pat("[(|]x"), "[(|]x")                     # a class as it is
    assert_equal(pat("[]a]"), "[]a]")
    assert_equal(pat("[](]"), "[](]")                       # a ] first is in the class
    assert_equal(pat("a[b"), "a\\[b")                       # an unclosed [
    assert_equal(pat("x\\.y.*$"), "x\\.y.*$")
    assert_equal(pat("a\\=b"), "a?b")
    assert_equal(pat("\\d\\+"), "\\d+")
    assert_equal(pat("\\v(a|b)+<x>c="), "(a|b)+\\bx\\bc?")  # very magic
    assert_true(vim_pattern(decode("\\cFoo")).icase)
    assert_equal(pat("\\cFoo"), "Foo")
    assert_false(vim_pattern(decode("\\c\\CFoo")).icase)
    assert_equal(to_str(vim_replacement(decode("&-\\1\\9"))), "${0}-${1}${9}")
    assert_equal(to_str(vim_replacement(decode("a\\&b\\/c"))), "a&b/c")
    assert_equal(to_str(vim_replacement(decode("x\\ry\\tz"))), "x\\ny\\tz")
    assert_equal(to_str(vim_replacement(decode("$5 \\\\"))), "$$5 \\\\")
    assert_equal(to_str(vim_replacement(decode("a\\$b"))), "a$$b")


def test_parsing() raises:
    var s = parse_sub(decode("/a\\/b/c/g"))
    assert_true(s.ok and s.all and not s.icase)
    assert_equal(to_str(s.pat), "a/b")
    assert_equal(to_str(s.rep), "c")
    s = parse_sub(decode("#x#y"))                           # another delimiter, no last one
    assert_true(s.ok and not s.all)
    assert_equal(to_str(s.pat), "x")
    assert_equal(to_str(s.rep), "y")
    s = parse_sub(decode("/a\\(b\\)/\\1/iI"))
    assert_true(s.ok and s.icase and s.noic)
    assert_equal(to_str(s.pat), "a\\(b\\)")
    assert_equal(to_str(s.rep), "\\1")
    assert_false(parse_sub(decode("/a/b/q")).ok)
    assert_true(parse_sub(decode("/a/b/q")).error.startswith("E488"))
    assert_false(parse_sub(decode("")).ok)
    assert_false(parse_sub(decode("xaxbx")).ok)            # a letter
    var x = parse_ex(decode("%s/a/b/"), 3, 9, -1, -1)
    assert_true(x.ok and x.has_range and x.r1 == 0 and x.r2 == 9)
    assert_equal(x.name, "s")
    assert_equal(to_str(x.raw), "/a/b/")
    x = parse_ex(decode("3,5d"), 0, 9, -1, -1)
    assert_true(x.r1 == 2 and x.r2 == 4 and x.name == "d")
    x = parse_ex(decode(".,$y"), 3, 9, -1, -1)
    assert_true(x.r1 == 3 and x.r2 == 9 and x.name == "y")
    x = parse_ex(decode(".+2;$-1"), 3, 9, -1, -1)
    assert_true(x.r1 == 5 and x.r2 == 8, String(x.r1) + " " + String(x.r2))
    x = parse_ex(decode(".+,-"), 3, 9, -1, -1)              # + and - alone: one line
    assert_true(x.r1 == 2 and x.r2 == 4, String(x.r1) + " " + String(x.r2))
    x = parse_ex(decode("'<,'>s/x/y/"), 0, 9, 2, 6)
    assert_true(x.ok and x.r1 == 2 and x.r2 == 6 and x.name == "s")
    x = parse_ex(decode("'<,'>s/x/y/"), 0, 9, -1, -1)
    assert_false(x.ok)
    assert_true(x.error.startswith("E20"))
    x = parse_ex(decode("10"), 0, 19, -1, -1)
    assert_true(x.ok and x.has_range and x.r2 == 9 and x.name == "")
    x = parse_ex(decode("5,3d"), 0, 9, -1, -1)              # backwards: turned round
    assert_true(x.r1 == 2 and x.r2 == 4)
    x = parse_ex(decode("99"), 0, 9, -1, -1)
    assert_false(x.ok)
    assert_true(x.error.startswith("E16"))
    x = parse_ex(decode("  w!  foo bar.txt  "), 0, 9, -1, -1)
    assert_true(x.ok and x.name == "w" and x.bang and not x.has_range)
    assert_equal(x.arg, "foo bar.txt")
    x = parse_ex(decode("compile.build"), 0, 9, -1, -1)
    assert_equal(x.name, "compile.build")
    x = parse_ex(decode("go to line"), 0, 9, -1, -1)
    assert_true(x.name == "go" and x.arg == "to line")
    assert_true(ex_is("w", "write", 1) and ex_is("wri", "write", 1) and ex_is("write", "write", 1))
    assert_false(ex_is("writes", "write", 1))
    assert_false(ex_is("no", "nohlsearch", 3))
    assert_true(ex_is("noh", "nohlsearch", 3))


def test_search() raises:
    var app = make("foo bar foo\nbaz foo\nend")
    keys(app, "/foo|")
    assert_equal(at(app), "0:8")
    assert_true(app.wins[0].hs_on)                          # the matches are marked
    keys(app, "n")
    assert_equal(at(app), "1:4")
    keys(app, "n")                                          # round the end
    assert_equal(at(app), "0:0")
    assert_true(app.status.startswith("search hit BOTTOM"), app.status)
    keys(app, "N")                                          # the other way, round the start
    assert_equal(at(app), "1:4")
    assert_true(app.status.startswith("search hit TOP"), app.status)
    keys(app, "?bar|")
    assert_equal(at(app), "0:4")
    keys(app, "n")                                          # ? then n: still backwards
    assert_equal(at(app), "0:4")
    keys(app, "gg2/foo|")                                   # a count
    assert_equal(at(app), "1:4")
    keys(app, "gg/|")                                       # empty: the last pattern
    assert_equal(at(app), "0:8")
    keys(app, "/nope|")
    assert_equal(at(app), "0:8")
    assert_true(app.status.startswith("E486: Pattern not found: nope"), app.status)
    keys(app, "/a\\")                                       # vim's syntax: \| is an alternative
    app.handle_key(124)                                     # (| itself: keys() types Enter for it)
    keys(app, "e|")
    assert_equal(at(app), "1:1")
    keys(app, "/(|")
    assert_true(app.status.startswith("E486"), app.status)  # a bare ( is a character
    keys(app, "gg/\\cFOO|")
    assert_equal(at(app), "0:8")
    keys(app, ":noh|")
    assert_false(app.wins[0].hs_on)
    app = make("abc def ghi")
    keys(app, "d/gh|")                                      # an operator up to the match
    assert_equal(text(app), "ghi")
    app = make("abc def ghi jkl")
    keys(app, "c/gh|X~")
    assert_equal(text(app), "Xghi jkl")
    app = make("a1 b1 a1 b1 a1")
    keys(app, "d/b|w.")                                     # and . repeats it
    assert_equal(text(app), "b1 b1 a1")
    app = make("foo foobar foo\nx foo")
    keys(app, "*")                                          # a whole word
    assert_equal(at(app), "0:11")
    keys(app, "n")
    assert_equal(at(app), "1:2")
    keys(app, "#")
    assert_equal(at(app), "0:11")
    keys(app, "#")
    assert_equal(at(app), "0:0")
    keys(app, "0f *")                                       # on a blank: the next word (foobar, alone)
    assert_equal(at(app), "0:4")
    assert_true(app.status.startswith("search hit BOTTOM"), app.status)
    app = make("foo x foo")
    keys(app, "l*")                                         # inside the word: all of it
    assert_equal(at(app), "0:6")
    app = make("  ;;  ")
    keys(app, "*")
    assert_true(app.status.startswith("E348"), app.status)
    app = make("ab\ncd ab")
    keys(app, "v/ab|")                                      # Visual: the selection grows
    assert_equal(app.vim.mode, VM_VISUAL)
    keys(app, "y")
    assert_equal(to_str(app.vim.reg), "ab\ncd a")


def test_the_line() raises:
    var app = make("abc")
    keys(app, ":xy")
    assert_true(app.vim.cl_on)
    app.status_until = 0
    app.draw()
    var row = to_str(app.scr.row_text(24))
    assert_true(row.startswith(":xy"), row)
    assert_equal(app.scr.cx, 3)
    assert_true(app.scr.cbar and app.scr.cvis)
    assert_equal(text(app), "abc")                          # nothing typed into the text
    app.handle_key(KEY_BACKSPACE)
    keys(app, "z")
    assert_equal(to_str(app.vim.cl_text), "xz")
    app.handle_key(117 | MOD_CTRL)                          # Ctrl-U
    assert_equal(len(app.vim.cl_text), 0)
    app.handle_key(KEY_BACKSPACE)                           # on an empty line: it goes
    assert_false(app.vim.cl_on)
    keys(app, "d/q~")                                       # Esc drops it, and the operator
    assert_false(app.vim.cl_on)
    keys(app, "x")
    assert_equal(text(app), "bc")
    keys(app, "/b")
    app.handle_key(99 | MOD_CTRL)                           # Ctrl-C too
    assert_false(app.vim.cl_on)
    assert_equal(at(app), "0:0")
    keys(app, "/")
    app.handle_key(115 | MOD_CTRL)                          # other Ctrl keys: nothing, not TurboMojo's
    assert_true(app.vim.cl_on)
    keys(app, "~")
    app.status_until = 0
    app.draw()
    row = to_str(app.scr.row_text(24))
    assert_true(row.find("F10 Menu") > 0 and not row.startswith("/"), row)   # the status line is back
    keys(app, ":40|")                                       # past the end
    assert_true(app.status.startswith("E16"), app.status)
    keys(app, ":xyzzy|")
    assert_true(app.status.startswith("E492: Not an editor command: xyzzy"), app.status)
    keys(app, ":")
    for _ in range(100):
        keys(app, "y")
    keys(app, "z")
    app.draw()
    row = to_str(app.scr.row_text(24))
    assert_true(row.endswith("yz") and not row.startswith(":"), row)   # the end of a long line
    assert_equal(app.scr.cx, 79)
    keys(app, "~")
    keys(app, ":set nonu|")
    assert_false(app.line_numbers)
    keys(app, ":set nu|")
    assert_true(app.line_numbers)
    keys(app, ":set xyzzy|")
    assert_true(app.status.startswith("E518"), app.status)


def test_substitute() raises:
    var app = make("a a\na a\nb")
    keys(app, ":s/a/b/|")
    assert_equal(text(app), "b a\na a\nb")
    keys(app, ":%s/a/c/g|")
    assert_equal(text(app), "b c\nc c\nb")
    assert_true(app.status.startswith("3 substitutions on 2 lines"), app.status)
    assert_equal(at(app), "1:0")                            # on the last line changed
    keys(app, "u")                                          # one undo step
    assert_equal(text(app), "b a\na a\nb")
    keys(app, ":%s/^/# /|")                                 # an empty match: at each line's start
    assert_equal(text(app), "# b a\n# a a\n# b")
    keys(app, ":%s/# //|")
    keys(app, ":2s/\\(a\\) \\(a\\)/\\2-\\1 [&]/|")
    assert_equal(text(app), "b a\na-a [a a]\nb")
    keys(app, ":s/zz/y/|")
    assert_true(app.status.startswith("E486: Pattern not found: zz"), app.status)
    keys(app, ":s/a/b/x|")
    assert_true(app.status.startswith("E488"), app.status)
    keys(app, ":%s/B/X/gi|")
    assert_equal(text(app), "X a\na-a [a a]\nX")
    keys(app, ":%s/x/b/|")
    assert_equal(text(app), "X a\na-a [a a]\nX")              # case matters without i
    keys(app, "/X|:%s//Y/|")                                # an empty pattern: the last search
    assert_equal(text(app), "Y a\na-a [a a]\nY")
    keys(app, ":1s/\\cy/q/I|")                              # I wins over \c
    assert_equal(text(app), "Y a\na-a [a a]\nY")
    keys(app, ":1s/a/x\\ry/|")                              # \r: a line break
    assert_equal(text(app), "Y x\ny\na-a [a a]\nY")
    app = make("aaa")
    keys(app, ":s/aa/b/g|")                                 # matches do not overlap
    assert_equal(text(app), "ba")
    app = make("a\na\na\na")
    keys(app, "jVj:")
    assert_equal(to_str(app.vim.cl_text), "'<,'>")
    keys(app, "s/a/z/|")
    assert_equal(text(app), "a\nz\nz\na")
    assert_equal(app.vim.mode, VM_NORMAL)
    keys(app, "x")                                          # a change...
    keys(app, ":1s/a/q/|")
    keys(app, "j.")                                         # ...and . repeats it, not the :s
    assert_equal(text(app), "q\n\n\na", text(app))
    app = make("ab\nc\nd")
    keys(app, "x:2d|.")                                     # . after :d: the x again
    assert_equal(text(app), "b\n")


def test_lines_and_commands() raises:
    var app = make("l1\nl2\nl3\nl4\nl5")
    keys(app, ":4|")
    assert_equal(at(app), "3:0")
    keys(app, ":$|")
    assert_equal(at(app), "4:0")
    keys(app, ":2,3d|")
    assert_equal(text(app), "l1\nl4\nl5")
    assert_true(app.vim.reg_lines)
    keys(app, ":1y|")
    assert_equal(to_str(app.vim.reg), "l1\n")
    keys(app, ":gotoLine|")                                 # TurboMojo's command, by its name's end
    assert_equal(app.mode, M_DIALOG)
    app.handle_key(KEY_ESC)
    assert_equal(app.mode, M_NORMAL)
    keys(app, ":search.gotoLine|")                          # ...by its whole name
    assert_equal(app.mode, M_DIALOG)
    app.handle_key(KEY_ESC)
    keys(app, ":go to line number|")                        # ...by its menu title
    assert_equal(app.mode, M_DIALOG)
    app.handle_key(KEY_ESC)
    app.reg.cmds.append(Command(CM_FIND, "x.close", "X", "", List[Int]()))
    keys(app, ":close|")
    assert_true(app.status.startswith("Which one? :window.close, :x.close"), app.status)


def test_files() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-vimcmd-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    var a = d + "/a.txt"
    _ = run_system("printf 'one\\n' > '" + a + "'")
    _ = run_system("printf 'bee\\n' > '" + d + "/b.txt'")
    var app = App()
    app.scr.resize(80, 25)
    app.show_clock = False
    app.cwd = d
    app.keymap = KEYMAP_VIM
    app.vim_reset()
    app.rebuild_keys(False)
    app.open_path(a)
    app.draw()
    var n0 = len(app.wins)
    keys(app, "x:q|")                                       # unsaved: not closed
    assert_true(app.status.startswith("E37"), app.status)
    assert_equal(len(app.wins), n0)
    keys(app, ":w|")
    assert_equal(read_text(a), "ne\n")
    keys(app, ":w copy.txt|")                               # a copy; the window stays a.txt
    assert_equal(read_text(d + "/copy.txt"), "ne\n")
    assert_true(app.wins[app.top()].path.endswith("/a.txt"))
    keys(app, "x:w copy.txt|")
    assert_true(app.status.startswith("E13"), app.status)
    keys(app, ":w! copy.txt|")
    assert_equal(read_text(d + "/copy.txt"), "e\n")
    keys(app, ":e b.txt|")                                  # relative to the folder
    assert_true(app.wins[app.top()].path.endswith("/b.txt"))
    assert_equal(text(app), "bee\n")
    keys(app, ":e|")
    assert_true(app.status.startswith("E32"), app.status)
    keys(app, "x:q!|")                                      # gone, unsaved
    assert_equal(read_text(d + "/b.txt"), "bee\n")
    assert_true(app.wins[app.top()].path.endswith("/a.txt"))
    keys(app, "x:wq|")                                      # saved and closed
    assert_equal(read_text(a), "\n")
    var editors = 0
    for i in range(len(app.wins)):
        if app.wins[i].path.endswith("/a.txt"):
            editors += 1
    assert_equal(editors, 0)
    app.open_path(d + "/b.txt")
    _ = run_system("printf 'new\\n' > '" + d + "/b.txt'")   # (changed behind its back: a save would ask)
    keys(app, ":x|")                                        # unchanged: closed, not written
    for i in range(len(app.wins)):
        assert_false(app.wins[i].path.endswith("/b.txt"))
    assert_equal(read_text(d + "/b.txt"), "new\n")
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
