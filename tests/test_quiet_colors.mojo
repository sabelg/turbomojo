"""Tests for quiet code colours (P10-19, contrast.quiet_syntax, Options > Quiet code
colours): every theme's syntax colours fold into four - text, comments, strings and
numbers, definitions - strings and definitions quieter than the error colour and
comments fainter than the text, still readable, apart for
colour-blind eyes and, at every depth, within the floors; in every theme search hits
stand out more than the current line and the other uses of the word, and the current
line shows; the option switches the palette at once and is written to the config."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from contrast import *
from themes import ThemeSet
from palette import is_rgb
from caps import COLOR_TRUE, COLOR_256, COLOR_16
from app import *
from appstate import App
from commands import CM_QUIET
from config import read_text
from signals import own_pid
from util import env_or, run_system, shell_quote


def distinct(l: List[Int]) -> List[Int]:
    var out = List[Int]()
    for c in l:
        if not (c in out):
            out.append(c)
    return out^


def test_four_colours_in_every_theme() raises:
    var t = ThemeSet()
    for k in range(t.count()):
        for mode in [COLOR_TRUE, COLOR_256, COLOR_16]:
            var p = t.for_depth(k, mode)
            var rich = len(distinct(p.syn))
            p.syn = quiet_syntax(p)
            var what = t.ids[k] + " at " + String(mode)
            var n = len(distinct(p.syn))
            assert_true(n <= 4 and n <= rich, what + ": " + String(n))
            assert_equal(p.syn[1], p.syn[0], what)          # keywords as text
            assert_equal(p.syn[2], p.syn[0], what)          # types too
            assert_equal(p.syn[5], p.syn[4], what)          # numbers as strings
            var probs = contrast_problems(p) if mode == COLOR_TRUE else depth_problems(p, mode)
            assert_equal(len(probs), 0, what + ":\n" + "\n".join(probs))
            if mode != COLOR_TRUE:
                continue
            var cv = cvd_problems(p)
            assert_equal(len(cv), 0, what + ":\n" + "\n".join(cv))
            if not is_rgb(p.syn[0]) or not is_rgb(p.diag_err):
                continue
            # quieter than the errors, yet strings and definitions still to be seen
            var err = cvd_distance(p.diag_err, p.syn[0], CVD_NONE)
            for k2 in [4, 10]:
                assert_true(cvd_distance(p.syn[k2], p.syn[0], CVD_NONE) < err * 0.8 + 0.001, what + ": " + hex(p.syn[k2]))
            # comments are quiet by being fainter than the text
            assert_true(wcag_ratio(p.syn[3], p.ed_bg) <= wcag_ratio(p.syn[0], p.ed_bg) + 0.001, what)
            if t.pals[k].syn[4] != t.pals[k].syn[0]:
                assert_true(cvd_distance(p.syn[4], p.syn[0], CVD_NONE) >= CVD_SYNTAX_MIN, what)
    # quieter than the rich colours: in Midnight the strings come nearer the text
    var m = t.pals[t.find("midnight")].copy()
    var q = quiet_syntax(m)
    assert_true(cvd_distance(q[4], m.syn[0], CVD_NONE) < cvd_distance(m.syn[4], m.syn[0], CVD_NONE))


def test_search_hits_and_the_current_line() raises:
    var t = ThemeSet()
    for k in range(t.count()):
        var p = t.pals[k].copy()
        if not is_rgb(p.match_bg) or not is_rgb(p.ed_bg):
            continue
        var hit = cvd_distance(p.match_bg, p.ed_bg, CVD_NONE)
        if is_rgb(p.word_bg):
            assert_true(hit > cvd_distance(p.word_bg, p.ed_bg, CVD_NONE), t.ids[k])
        if is_rgb(p.curline_bg):
            var cur = cvd_distance(p.curline_bg, p.ed_bg, CVD_NONE)
            assert_true(hit > cur, t.ids[k])
            assert_true(cur >= 3.0, t.ids[k] + ": the current line hardly shows (" + one_decimal(cur) + ")")


def test_the_option() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-quiet-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = App()
    app.scr.resize(80, 24)
    app.config_path = d + "/config.toml"
    app.theme_id = "midnight"
    app.theme_apply()
    var rich = app.pal.syn.copy()
    app.exec(CM_QUIET)
    assert_true(app.quiet_on)
    assert_equal(app.pal.syn[1], app.pal.syn[0])
    assert_true(app.pal.syn[1] != rich[1])
    assert_true(app.status.find("Quiet code colours on") >= 0, app.status)
    assert_true(read_text(app.config_path).find("quiet_colors = true") >= 0, read_text(app.config_path))
    # it stays when the theme changes
    app.theme_id = "light"
    app.theme_apply()
    assert_equal(app.pal.syn[1], app.pal.syn[0])
    app.exec(CM_QUIET)
    assert_false(app.quiet_on)
    assert_true(app.pal.syn[1] != app.pal.syn[0])
    assert_true(read_text(app.config_path).find("quiet_colors = false") >= 0)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
