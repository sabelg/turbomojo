"""Tests for grapheme-width discipline, first part (P10-21a): at start-up a few glyphs
whose width terminals disagree about are measured (written concealed, then a
cursor-position report); the answers are read without being taken for keys; what they
say decides the layout (a terminal that joins emoji sequences by itself gets the
clustered layout, emoji it draws narrow are padded); and after any doubtful glyph the
next cell is placed explicitly, so a wrong guess cannot shift the rest of the row."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from caps import (
    width_probe, width_verdict, width_summary, width_sample, WIDTH_SAMPLE_COUNT,
    EMOJI_NARROW_NONE, EMOJI_NARROW_NEW, EMOJI_NARROW_ALL,
)
from term import Terminal, fkey, MOD_SHIFT
from screen import Screen
from app import *
from appstate import App
from util import str_bytes, bytes_to_str


def test_the_answers_are_not_keys() raises:
    var t = Terminal()
    t.cpr_pending = WIDTH_SAMPLE_COUNT
    var evs = t.feed(str_bytes("\x1b[1;3R\x1b[1;3Rx\x1b[1;5R\x1b[1;2R"), False)
    assert_equal(len(evs), 1)                       # only the x typed meanwhile
    assert_equal(evs[0].key, 120)
    assert_equal(len(t.caps.widths), 4)
    assert_equal(t.caps.widths[0], 2)
    assert_equal(t.caps.widths[2], 4)
    assert_equal(t.caps.widths[3], 1)
    assert_equal(t.cpr_pending, 0)
    # once they are all in, the same bytes are Shift-F3 again
    var later = t.feed(str_bytes("\x1b[1;2R"), False)
    assert_equal(len(later), 1)
    assert_equal(later[0].key, fkey(3) | MOD_SHIFT)
    assert_equal(len(t.caps.widths), 4)


def test_the_probe() raises:
    var p = width_probe()
    assert_equal(len(p.split("\x1b[6n")) - 1, WIDTH_SAMPLE_COUNT)
    assert_true(p.startswith("\x1b[8m"))            # concealed
    assert_true(p.endswith("\r\x1b[2K\x1b[0m"))     # and wiped
    for k in range(WIDTH_SAMPLE_COUNT):
        var s = String("")
        for c in width_sample(k):
            s += chr(c)
        assert_true(p.find("\r" + s + "\x1b[6n") >= 0, String(k))
    assert_true(0x200D in width_sample(2))          # the joined pair
    assert_true(0xFE0F in width_sample(3))          # the emoji selector


def test_what_the_answers_mean() raises:
    # one by one, with an up-to-date table: nothing changes
    var a = width_verdict([2, 2, 4, 1])
    assert_true(a.measured)
    assert_false(a.clusters)
    assert_equal(a.emoji_narrow, EMOJI_NARROW_NONE)
    assert_false(a.vs16_wide)
    # joins the pair into one glyph
    var b = width_verdict([2, 2, 2, 2])
    assert_true(b.clusters)
    assert_true(b.vs16_wide)
    # a table older than Unicode 15
    var c = width_verdict([2, 1, 4, 1])
    assert_equal(c.emoji_narrow, EMOJI_NARROW_NEW)
    assert_false(c.clusters)
    # older than Unicode 9: every emoji narrow, and a pair of 2 means nothing then
    var d = width_verdict([1, 1, 2, 1])
    assert_equal(d.emoji_narrow, EMOJI_NARROW_ALL)
    assert_false(d.clusters)
    # incomplete or implausible answers are not used
    assert_false(width_verdict([2, 2]).measured)
    assert_false(width_verdict([0, 2, 4, 1]).measured)
    assert_false(width_verdict([2, 2, 4, 40]).measured)
    assert_equal(width_summary(List[Int]()), "not measured")
    assert_true(width_summary([2, 2, 2, 2]).find("joins") >= 0)


def frame(mut s: Screen) -> String:
    var out = List[UInt8]()
    s.render(out)
    return bytes_to_str(out)


def test_narrow_emoji_are_padded() raises:
    var s = Screen(10, 1)
    s.sync = False
    var x = s.draw_cp(0, 0, 0x1FAE8, 7, 0)
    assert_equal(x, 2)
    _ = s.draw_cp(x, 0, 97, 7, 0)
    var wide = frame(s)
    # measured wide (the default): placed again after it, no padding
    assert_true(wide.find(chr(0x1FAE8) + "\x1b[1;3Ha") >= 0, wide)
    s.force = True
    s.emoji_narrow = EMOJI_NARROW_NEW
    var narrow = frame(s)
    assert_true(narrow.find(chr(0x1FAE8) + " a") >= 0, narrow)
    # an older emoji is not padded at that level, only when every emoji is narrow
    var t = Screen(10, 1)
    t.sync = False
    t.emoji_narrow = EMOJI_NARROW_NEW
    _ = t.draw_cp(t.draw_cp(0, 0, 0x1F600, 7, 0), 0, 97, 7, 0)
    assert_true(frame(t).find(chr(0x1F600) + "\x1b[1;3Ha") >= 0)
    t.force = True
    t.emoji_narrow = EMOJI_NARROW_ALL
    assert_true(frame(t).find(chr(0x1F600) + " a") >= 0)


def test_after_a_doubtful_glyph_the_next_cell_is_placed() raises:
    var s = Screen(20, 1)
    s.sync = False
    var x = s.text(0, 0, "ab", 7, 0)
    x = s.draw_cp(x, 0, 0x4E2D, 7, 0)         # CJK: the table is reliable
    x = s.text(x, 0, "c", 7, 0)
    x = s.draw_cp(x, 0, 0x1F600, 7, 0)        # an emoji
    x = s.text(x, 0, "d", 7, 0)
    x = s.text(x, 0, "é", 7, 0)          # a combining accent
    x = s.text(x, 0, "f", 7, 0)
    var f = frame(s)
    assert_true(f.find("ab" + chr(0x4E2D) + "c") >= 0, f)
    assert_true(f.find(chr(0x1F600) + "\x1b[1;8Hd") >= 0, f)
    assert_true(f.find("é\x1b[1;10Hf") >= 0, f)


def test_the_app_draws_by_the_measurement() raises:
    var app = App()
    app.apply_widths([2, 2, 2, 2])
    assert_true(app.scr.clustered)
    var b = App()
    b.apply_widths([2, 1, 4, 1])
    assert_false(b.scr.clustered)
    assert_equal(b.scr.emoji_narrow, EMOJI_NARROW_NEW)
    var c = App()
    c.apply_widths([2, 1])                    # not all answered: left as it was
    assert_false(c.scr.clustered)
    assert_equal(c.scr.emoji_narrow, EMOJI_NARROW_NONE)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
