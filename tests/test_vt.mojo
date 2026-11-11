"""Tests for terminal emulation (src/vt.mojo on libghostty-vt): what programs write turns
into the screen the integrated terminal will show. The last tests run real programs on
a pty (src/pty.mojo) through it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from vt import *
from pty import Pty
from term import wait_readable
from util import bytes_to_str

comptime MS = 1000000
comptime ESC = "\x1b"


def term(cols: Int, rows: Int) raises -> VtTerm:
    var t = VtTerm()
    assert_true(t.open(cols, rows))
    return t^


def shown(mut t: VtTerm, text: String) -> String:
    t.write_text(text)
    t.update()
    return t.text()


def at(t: VtTerm, x: Int, y: Int) -> Int:
    return y * t.cols + x


def test_text_lines_and_the_cursor() raises:
    var t = term(20, 4)
    assert_equal(shown(t, "hello\r\nworld"), "hello\nworld\n\n\n")
    assert_equal(t.cursor_x, 5)
    assert_equal(t.cursor_y, 1)
    assert_true(t.cursor_shown)
    # CUP, EL, ED
    assert_equal(shown(t, ESC + "[1;3HXY" + ESC + "[2;1H" + ESC + "[K"), "heXYo\n\n\n\n")
    assert_equal(shown(t, ESC + "[2J" + ESC + "[H"), "\n\n\n\n")
    assert_equal(t.cursor_x, 0)
    # a long line wraps; the screen scrolls when it is full
    assert_equal(shown(t, "abcdefghijklmnopqrstuvwxyz"), "abcdefghijklmnopqrst\nuvwxyz\n\n\n")
    assert_equal(shown(t, "\r\n1\r\n2\r\n3"), "uvwxyz\n1\n2\n3\n")
    assert_true(t.scrollback >= 1, "the line that left the screen is in the scrollback")
    # the cursor can be hidden
    _ = shown(t, ESC + "[?25l")
    assert_false(t.cursor_shown)
    _ = shown(t, ESC + "[?25h")
    assert_true(t.cursor_shown)


def test_colours_and_attributes() raises:
    var t = term(30, 3)
    _ = shown(t, "a" + ESC + "[31mb" + ESC + "[1;4mc" + ESC + "[0m" + ESC + "[38;5;208md" + ESC + "[38;2;1;2;3me" + ESC + "[48;2;250;10;0mf" + ESC + "[7mg" + ESC + "[0mh")
    assert_equal(t.row_text(0), "abcdefgh")
    assert_equal(t.fg[at(t, 0, 0)], -1, "no colour of its own")
    assert_equal(t.fg[at(t, 1, 0)], -2 - 1, "palette colour 1 (red) is kept as an index")
    assert_equal(t.fg[at(t, 2, 0)], -2 - 1)
    assert_true(t.flags[at(t, 2, 0)] & VF_BOLD != 0 and t.flags[at(t, 2, 0)] & VF_UNDERLINE != 0)
    assert_equal(t.flags[at(t, 3, 0)], 0)
    assert_equal(t.fg[at(t, 3, 0)], -2 - 208, "256-colour index")
    assert_equal(t.fg[at(t, 4, 0)], 0x010203, "truecolor")
    assert_equal(t.bg[at(t, 5, 0)], 0xFA0A00)
    assert_true(t.flags[at(t, 6, 0)] & VF_INVERSE != 0)
    assert_equal(t.bg[at(t, 7, 0)], -1)
    # erasing with a background colour colours the erased cells
    _ = shown(t, "\r\n" + ESC + "[44m" + ESC + "[K" + ESC + "[0m")
    assert_equal(t.bg[at(t, 10, 1)], -2 - 4)


def test_wide_and_combined_characters() raises:
    var t = term(10, 2)
    _ = shown(t, "a漢b e\u0301")
    assert_equal(t.row_text(0), "a漢b e\u0301", "the mark stays with its letter")
    assert_equal(t.cp[at(t, 1, 0)], 0x6F22)
    assert_equal(t.cp[at(t, 2, 0)], -1, "the right half of the wide character")
    assert_equal(t.cp[at(t, 3, 0)], 98)
    assert_equal(len(t.extra), 1, "e + combining acute in one cell")


def test_scroll_regions_and_line_editing() raises:
    var t = term(10, 5)
    _ = shown(t, "1\r\n2\r\n3\r\n4\r\n5")
    # region rows 2..4; a line feed at its bottom scrolls only the region
    assert_equal(shown(t, ESC + "[2;4r" + ESC + "[4;1H\nX"), "1\n3\n4\nX\n5\n")
    # insert and delete lines inside the region
    assert_equal(shown(t, ESC + "[2;1H" + ESC + "[L"), "1\n\n3\n4\n5\n")
    assert_equal(shown(t, ESC + "[2;1H" + ESC + "[2M"), "1\n4\n\n\n5\n")
    # insert and delete characters
    assert_equal(shown(t, ESC + "[r" + ESC + "[1;1Habcdef" + ESC + "[1;2H" + ESC + "[2@"), "a  bcdef\n4\n\n\n5\n")
    assert_equal(shown(t, ESC + "[1;2H" + ESC + "[3P"), "acdef\n4\n\n\n5\n")


def test_the_alternate_screen() raises:
    var t = term(12, 3)
    _ = shown(t, "shell$ ls")
    assert_false(t.alt_screen)
    assert_equal(shown(t, ESC + "[?1049h" + ESC + "[H" + ESC + "[2Jfull-screen"), "full-screen\n\n\n")
    assert_true(t.alt_screen)
    # leaving it brings the shell's screen and cursor back
    assert_equal(shown(t, ESC + "[?1049l"), "shell$ ls\n\n\n")
    assert_false(t.alt_screen)
    assert_equal(t.cursor_x, 9)


def test_questions_are_answered() raises:
    _ = vt_take_replies()               # nothing left over from other tests
    var t = term(20, 5)
    _ = shown(t, ESC + "[3;7H" + ESC + "[6n")            # where is the cursor?
    _ = shown(t, ESC + "[?1h" + ESC + "[?1$p")            # application cursor keys on? (DECRQM)
    _ = shown(t, ESC + "[c")                              # device attributes
    var got = vt_take_replies()
    assert_equal(len(got), 3)
    assert_equal(got[0].term, t.term)
    assert_equal(bytes_to_str(got[0].data), ESC + "[3;7R")
    assert_equal(bytes_to_str(got[1].data), ESC + "[?1;1$y")
    assert_true(bytes_to_str(got[2].data).startswith(ESC + "[?"), bytes_to_str(got[2].data))
    assert_equal(len(vt_take_replies()), 0)
    # two terminals: each answer says whose it is
    var u = term(5, 2)
    _ = shown(u, ESC + "[6n")
    _ = shown(t, ESC + "[6n")
    var both = vt_take_replies()
    assert_equal(len(both), 2)
    assert_equal(both[0].term, u.term)
    assert_equal(bytes_to_str(both[0].data), ESC + "[1;1R")
    assert_equal(both[1].term, t.term)


def test_resizing_reflows_the_text() raises:
    var t = term(10, 3)
    _ = shown(t, "abcdefghijkl")
    assert_equal(t.text(), "abcdefghij\nkl\n\n")
    t.resize(20, 3)
    t.update()
    assert_equal(t.row_text(0), "abcdefghijkl", "a wrapped line joins again when there is room")
    assert_equal(t.cols, 20)
    assert_equal(len(t.cp), 60)
    var closed = VtTerm()
    assert_false(closed.open(0, 5))
    closed.write_text("ignored")       # not open: nothing happens
    closed.update()


def run_on_pty(script: String, cols: Int, rows: Int, until: String) raises -> VtTerm:
    """A real program on a pty, its output through the emulator, answers sent back."""
    var p = Pty()
    var argv = List[String]()
    argv.append("sh")
    argv.append("-c")
    argv.append(script)
    assert_true(p.start(argv, "", List[String](), rows, cols))
    var t = term(cols, rows)
    var deadline = Int(perf_counter_ns()) + 5000 * MS
    while Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(p.master)
        _ = wait_readable(fds, 20)
        _ = p.read_available()
        t.write(p.take())
        for r in vt_take_replies():
            if r.term == t.term:
                p.write(r.data)
        t.update()
        if t.text().find(until) >= 0 or p.eof:
            break
    _ = p.stop()
    return t^


def test_real_programs_through_a_pty() raises:
    _ = vt_take_replies()
    # colours from a real program, and its own line ends
    var t = run_on_pty("printf 'plain \\033[32mgreen\\033[0m\\n'; printf 'next line\\n'; echo done", 40, 6, "done")
    assert_equal(t.row_text(0), "plain green")
    assert_equal(t.fg[at(t, 6, 0)], -2 - 2)
    assert_equal(t.row_text(1), "next line")
    # a program that asks where the cursor is, and reads the answer from its terminal
    var q = run_on_pty("stty raw -echo; printf 'ab\\033[6n'; ans=$(dd bs=1 count=6 2>/dev/null | tr -d '\\033'); stty sane; printf '\\r\\nanswer=%s.\\r\\n' \"$ans\"", 30, 4, "answer=")
    assert_true(q.text().find("answer=[1;3R.") >= 0, q.text())
    # a full-screen program: alternate screen, cursor placed, then back
    var f = run_on_pty("printf '\\033[?1049h\\033[2;5HTOP'; sleep 0.3; printf '\\033[?1049lback'; sleep 0.2", 20, 4, "back")
    assert_true(f.text().startswith("back"), f.text())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
