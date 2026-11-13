"""Tests for following the terminal live and Turbo Muted (P10-20a): a terminal that
reports its background colour (OSC 11) but not its light or dark (mode 2031) is asked
again when it gets the focus back and at most every half minute, and its answer
changes the theme; a terminal that reports 2031, or a theme that is not "auto", is not
asked; Turbo Muted is Turbo Classic's parts in less saturated colours, within every
check."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.math import sqrt
from contrast import *
from themes import ThemeSet, palette_keys, palette_get, TURBO_MUTED
from palette import is_rgb, ansi, Palette
from caps import COLOR_256, COLOR_16, OSC11_QUERY
from term import Event, EV_FOCUS
from app import *
from appstate import App
from util import str_bytes, bytes_to_str, read_file, getcwd


def focus(gained: Bool) -> Event:
    return Event(EV_FOCUS, 1 if gained else 0, 0, 0, 0, False, False, List[Int]())


def asked(app: App) -> Int:
    var out = bytes_to_str(app.term.out)
    var n = 0
    var at = out.find(OSC11_QUERY)
    while at >= 0:
        n += 1
        at = out.find(OSC11_QUERY, at + 1)
    return n


def test_asked_again_on_focus() raises:
    var app = App()
    app.scr.resize(80, 24)
    app.theme_id = "auto"
    app.theme_dark_id = "midnight"
    app.theme_light_id = "light"
    # the start: the terminal said its background was dark, and nothing of 2031
    _ = app.term.feed(str_bytes("\x1b]11;rgb:1a1a/1b1b/2626\x1b\\"), False)
    assert_equal(app.term.bg_scheme, 1)
    app.theme_tick()
    assert_equal(app.pal.name, "Midnight Neon")
    app.term.out.clear()
    # away, its scheme switched to light; back: asked at once
    app.handle(focus(False))
    assert_equal(asked(app), 0)
    app.handle(focus(True))
    assert_equal(asked(app), 1)
    _ = app.term.feed(str_bytes("\x1b]11;rgb:fbfb/fbfb/f8f8\x1b\\"), False)
    assert_equal(app.term.bg_scheme, 2)
    app.theme_tick()
    assert_equal(app.pal.name, "Paper Light")
    # in use: not again within half a minute, then again
    app.term.out.clear()
    app.theme_tick()
    assert_equal(asked(app), 0)
    app.bg_asked_ns -= 31 * 1000000000
    app.theme_tick()
    assert_equal(asked(app), 1)


def test_not_asked() raises:
    # a terminal that reports light / dark itself
    var app = App()
    app.theme_id = "auto"
    _ = app.term.feed(str_bytes("\x1b]11;rgb:0000/0000/0000\x1b\\\x1b[?997;1n"), False)
    app.term.out.clear()
    app.handle(focus(True))
    assert_equal(asked(app), 0)
    # one that never answered OSC 11
    var b = App()
    b.theme_id = "auto"
    b.handle(focus(True))
    assert_equal(asked(b), 0)
    # a theme of its own
    var c = App()
    c.theme_id = "classic"
    _ = c.term.feed(str_bytes("\x1b]11;rgb:0000/0000/0000\x1b\\"), False)
    c.term.out.clear()
    c.handle(focus(True))
    assert_equal(asked(c), 0)


def chroma(c: Int) -> Float64:
    var l = cvd_lab(c, CVD_NONE)
    return sqrt(l[1] * l[1] + l[2] * l[2])


def mean_chroma(p: Palette) -> Float64:
    var s = 0.0
    var n = 0
    for k in palette_keys():
        var c = palette_get(p, k)
        if is_rgb(c):
            s += chroma(c)
            n += 1
    for c in p.syn:
        if is_rgb(c):
            s += chroma(c)
            n += 1
    return s / Float64(n)


def test_turbo_muted() raises:
    var t = ThemeSet()
    var k = t.find("muted")
    assert_true(k >= 0)
    assert_equal(len(t.problems), 0, "\n".join(t.problems))
    var p = t.pals[k].copy()
    assert_equal(p.name, "Turbo Muted")
    assert_equal(bytes_to_str(read_file(getcwd() + "/themes/turbo-muted.toml")), String(TURBO_MUTED))
    # less saturated than Turbo Classic: on average less than half its chroma
    var classic = t.pals[t.find("classic")].copy()
    assert_true(mean_chroma(p) < mean_chroma(classic) * 0.5, String(mean_chroma(p)) + " vs " + String(mean_chroma(classic)))
    # ... its parts where Classic has them: a blue editor, grey bars, dark text on them
    var e = cvd_lab(p.ed_bg, CVD_NONE)
    assert_true(e[2] < -10.0 and e[0] < 30.0)               # dark and bluish
    var m = cvd_lab(p.menu_bg, CVD_NONE)
    assert_true(m[0] > 60.0 and chroma(p.menu_bg) < 10.0)   # light grey
    assert_equal(p.menu_fg, 0x000000)
    # every check
    assert_equal(len(contrast_problems(p)), 0, "\n".join(contrast_problems(p)))
    assert_equal(len(cvd_problems(p)), 0, "\n".join(cvd_problems(p)))
    for mode in [COLOR_256, COLOR_16]:
        var d = depth_problems(t.for_depth(k, mode), mode)
        assert_equal(len(d), 0, "\n".join(d))
    # with 16 colours it is Turbo Classic's look
    assert_equal(t.for_depth(k, COLOR_16).ed_bg, ansi(4))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
