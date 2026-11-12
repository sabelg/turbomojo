"""Tests for the hardened terminal probe (P10-10, src/caps.mojo, src/term.mojo): what is
asked (the colour scheme, the background, truecolor and styled underlines - DA1 last,
no DCS under GNU screen); the replies, also late and split across reads, are taken in
and never become keys, while Alt-] and Alt-Shift-P stay keys; the background decides
light or dark when the terminal does not say; what the answers add to the
environment's guess, the user's overrides still winning (tmux's answers trusted); and
leaving - normally or after a crash - ends synchronized output and pops the kitty
keyboard flags before the alternate screen."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from caps import *
from term import Terminal, Event, EV_KEY, alt, KEY_ESC
from crash import CRASH_RESTORE
from util import str_bytes


def test_what_is_asked() raises:
    var q = caps_query(True)
    assert_true(q.endswith("\x1b[c"))                               # DA1 last
    assert_true(q.find("\x1b]11;?\x1b\\") >= 0)
    assert_true(q.find("\x1bP$qm\x1b\\") >= 0 and q.find("\x1bP+q536d756c78;536574756c63\x1b\\") >= 0)
    assert_true(q.find("\x1b[48;2;1;2;3m") < q.find("\x1bP$qm") and q.find("\x1b[0m") > q.find("\x1bP$qm"))
    var s = caps_query(False)
    assert_true(s.find("\x1bP") < 0 and s.endswith("\x1b[c") and s.find("]11;?") >= 0)
    assert_true(under_gnu_screen("screen.xterm-256color", "", ""))
    assert_true(under_gnu_screen("xterm-256color", "1234.pts-0.host", ""))
    assert_false(under_gnu_screen("screen-256color", "", "/tmp/tmux-1000/default,1,0"))   # tmux
    assert_false(under_gnu_screen("xterm-kitty", "", ""))


def test_the_background() raises:
    assert_equal(osc11_rgb("11;rgb:1a1a/1b1b/2626"), 0x1A1B26)
    assert_equal(osc11_rgb("11;rgb:ff/ff/ff"), 0xFFFFFF)
    assert_equal(osc11_rgb("11;rgb:f/0/8"), 0xFF0088)
    assert_equal(osc11_rgb("11;rgb:zz/00/00"), -1)
    assert_equal(osc11_rgb("10;rgb:ff/ff/ff"), -1)                  # (the foreground)
    assert_equal(scheme_of_background(0x1A1B26), 1)
    assert_equal(scheme_of_background(0xFDF6E3), 2)                 # Solarized light
    assert_equal(scheme_of_background(0x002B36), 1)                 # Solarized dark
    assert_equal(scheme_of_background(0x808080), 2)
    assert_equal(scheme_of_background(0x606060), 1)


def keys_of(evs: List[Event]) -> List[Int]:
    var out = List[Int]()
    for e in evs:
        if e.kind == EV_KEY:
            out.append(e.key)
    return out^


def test_replies_are_taken_in_never_typed() raises:
    var t = Terminal()
    # a late OSC 11 reply between two keys, the ST split across reads
    var a = t.feed(str_bytes("a\x1b]11;rgb:fdfd/f6f6/e3e3\x1b"), False)
    var b = t.feed(str_bytes("\\b"), False)
    var k = keys_of(a)
    for e in keys_of(b):
        k.append(e)
    assert_equal(len(k), 2)
    assert_equal(k[0], 97)
    assert_equal(k[1], 98)
    assert_equal(t.caps.background, 0xFDF6E3)
    assert_equal(t.bg_scheme, 2)
    # with BEL instead of ST
    _ = t.feed(str_bytes("\x1b]11;rgb:0000/2b2b/3636\x07"), False)
    assert_equal(t.bg_scheme, 1)
    # DECRQSS: the RGB colour came back (either separator), or it did not
    var u = Terminal()
    assert_equal(len(u.feed(str_bytes("\x1bP1$r0;48:2::1:2:3m\x1b\\"), False)), 0)
    assert_equal(u.caps.truecolor_said, 1)
    var v = Terminal()
    _ = v.feed(str_bytes("\x1bP1$r0;48;5;16m\x1b\\"), False)
    assert_equal(v.caps.truecolor_said, 2)
    _ = v.feed(str_bytes("\x1bP0$r\x1b\\"), False)
    assert_equal(v.caps.truecolor_said, 2)
    # XTGETTCAP: Smulx is there; a "not found" answer adds nothing
    var w = Terminal()
    _ = w.feed(str_bytes("\x1bP0+r536d756c78\x1b\\"), False)
    assert_equal(w.caps.underline_said, 0)
    _ = w.feed(str_bytes("\x1bP1+r536d756c78=1b5b343a25703125646d\x1b\\"), False)
    assert_equal(w.caps.underline_said, 1)
    # XTVERSION-style DCS ">|..." is a reply too
    assert_equal(len(w.feed(str_bytes("\x1bP>|kitty(0.40)\x1b\\x"), False)), 1)


def test_alt_keys_stay_keys() raises:
    var t = Terminal()
    var a = keys_of(t.feed(str_bytes("\x1b]"), True))               # Alt-] alone
    assert_equal(len(a), 1)
    assert_equal(a[0], alt(93))
    var b = keys_of(t.feed(str_bytes("\x1bPx"), False))             # Alt-Shift-P, then x
    assert_equal(len(b), 2)
    assert_equal(b[1], 120)
    # an unfinished reply waits for its end, then (if none comes) is keys
    var c = Terminal()
    assert_equal(len(c.feed(str_bytes("\x1b]11;rgb:00"), False)), 0)
    assert_true(len(c.feed(List[UInt8](), True)) > 0)


def test_what_answers_add() raises:
    var c = Caps()
    c.color = COLOR_256
    c.truecolor_said = 1
    c.settle("", "")
    assert_equal(c.color, COLOR_TRUE)
    var d = Caps()
    d.color = COLOR_16
    d.truecolor_said = 1
    d.settle("16", "")
    assert_equal(d.color, COLOR_16)                                 # the user's override
    var e = Caps()
    e.color = COLOR_TRUE
    e.truecolor_said = 2
    e.settle("", "")
    assert_equal(e.color, COLOR_TRUE)                               # answers only add
    # inside tmux the name says no; tmux's own answer says yes
    var f = Caps()
    f.styled_underline = detect_styled_underline("tmux-256color", "tmux", "", "")
    assert_false(f.styled_underline)
    f.underline_said = 1
    f.settle("", "")
    assert_true(f.styled_underline)
    var g = Caps()
    g.underline_said = 1
    g.settle("", "plain")
    assert_false(g.styled_underline)


def test_leaving_restores_in_order() raises:
    var t = Terminal()
    t.kitty_on = True
    t.grapheme_on = True
    var s = t.restore_sequence()
    assert_true(s.startswith("\x1b[?2026l"))
    assert_true(s.find("\x1b[<u") > 0 and s.find("\x1b[<u") < s.find("\x1b[?1049l"))
    assert_true(s.endswith("\x1b[?1049l"))
    var off = Terminal()
    assert_true(off.restore_sequence().find("\x1b[<u") < 0)       # nothing was pushed
    assert_true(String(CRASH_RESTORE).startswith("\x1b[?2026l\x1b[<u"))
    assert_true(String(CRASH_RESTORE).endswith("\x1b[?1049l"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
