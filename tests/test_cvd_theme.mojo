"""Tests for the Okabe-Ito theme and the colour-vision check (P10-18a,
src/contrast.mojo): the simulation agrees with what is known of it (grey stays grey,
a red and a green fall together without green cones, blue and green without blue ones);
the Okabe-Ito theme keeps its problem severities, success and failure, git markers and
main syntax classes apart with normal vision and protanopia, deuteranopia and
tritanopia, and reaches the contrast floors; a theme that breaks this is caught, and
the problem names the pair and the deficiency. Every built-in theme passes it too
(P10-18c): signal colours apart unless the theme is of one hue by design
(monochrome), syntax classes alike on purpose left alone."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from contrast import *
from themes import ThemeSet, OKABE_ITO
from palette import Palette
from util import read_file, bytes_to_str, getcwd


def test_the_simulation() raises:
    # a grey is seen as itself: each matrix row sums to one
    for kind in range(4):
        var c = cvd_linear(0x808080, kind)
        assert_true(abs(c[0] - c[1]) < 0.01 and abs(c[1] - c[2]) < 0.01, cvd_name(kind))
    assert_true(cvd_distance(0x808080, 0x808080, CVD_DEUTAN) < 0.001)
    # red and green: far apart normally, close without green or red cones
    var red = 0xC04020
    var green = 0x708000
    assert_true(cvd_distance(red, green, CVD_NONE) > 60.0)
    assert_true(cvd_distance(red, green, CVD_DEUTAN) < 5.0, one_decimal(cvd_distance(red, green, CVD_DEUTAN)))
    assert_true(cvd_distance(red, green, CVD_PROTAN) < cvd_distance(red, green, CVD_NONE) / 2.0)
    # ... but they stay apart without blue cones; blue against green does not
    assert_true(cvd_distance(red, green, CVD_TRITAN) > 30.0)
    assert_true(cvd_distance(0x3399CC, 0x33AA99, CVD_TRITAN) < cvd_distance(0x3399CC, 0x33AA99, CVD_NONE) / 2.0)
    # L* of white is 100, of black 0
    assert_true(abs(cvd_lab(0xFFFFFF, CVD_NONE)[0] - 100.0) < 0.1)
    assert_true(abs(cvd_lab(0x000000, CVD_NONE)[0]) < 0.1)


def test_okabe_ito_keeps_things_apart() raises:
    var t = ThemeSet()
    var k = t.find("okabe")
    assert_true(k >= 0)
    assert_equal(t.pals[k].name, "Okabe-Ito")
    assert_true(t.dark[k])
    assert_equal(len(t.problems), 0, "\n".join(t.problems))
    var problems = cvd_problems(t.pals[k])
    assert_equal(len(problems), 0, "\n".join(problems))
    assert_true(len(cvd_pairs(t.pals[k])) >= 25)
    var low = contrast_problems(t.pals[k])
    assert_equal(len(low), 0, "\n".join(low))
    # the file in themes/ is the one built in
    assert_equal(bytes_to_str(read_file(getcwd() + "/themes/okabe-ito.toml")), String(OKABE_ITO))


def test_a_theme_that_breaks_it_is_caught() raises:
    var t = ThemeSet()
    var p = t.pals[t.find("okabe")].copy()
    p.git_add = 0x5FA000                # a green addition beside the vermillion deletion
    p.git_del = 0xD04040
    var problems = cvd_problems(p)
    var names = List[String]()
    for s in problems:
        names.append(String(s[byte=0:s.find(":")]))
    assert_true("git_add / git_del" in names, "\n".join(problems))
    var one = String("")
    for s in problems:
        if s.startswith("git_add / git_del") and s.find("deuteranopia") > 0:
            one = s
    assert_true(one.byte_length() > 0, "\n".join(problems))
    assert_true(one.endswith("(needs 20)"), one)
    # with normal vision they are apart: only the deficiencies are named for this pair
    for s in problems:
        if s.startswith("git_add / git_del"):
            assert_true(s.find("normal vision") < 0, s)


def test_every_theme_passes() raises:
    var t = ThemeSet()
    var checked = 0
    for k in range(t.count()):
        var problems = cvd_problems(t.pals[k])
        assert_equal(len(problems), 0, t.ids[k] + ":\n" + "\n".join(problems))
        if not t.pals[k].monochrome:
            checked += 1
    assert_true(checked >= 6)
    # one hue by design: Amber CRT and Terminal Mono
    assert_true(t.pals[t.find("amber")].monochrome)
    assert_true(t.pals[t.find("mono")].monochrome)
    assert_false(t.pals[t.find("classic")].monochrome)


def test_what_the_rule_leaves_alone() raises:
    var t = ThemeSet()
    # Amber's git markers are all one colour: fine for it, caught in another theme
    var amber = t.pals[t.find("amber")].copy()
    assert_equal(amber.git_add, amber.git_del)
    assert_equal(len(cvd_problems(amber)), 0)
    amber.monochrome = False
    var named = "\n".join(cvd_problems(amber))
    assert_true(named.find("git_add / git_del: 0.0 with normal vision") >= 0, named)
    # syntax classes alike on purpose (Turbo Classic: keywords and definitions white)
    var c = t.pals[t.find("classic")].copy()
    assert_equal(c.syn[1], c.syn[10])
    assert_equal(len(cvd_problems(c)), 0)
    # ... but alike only with a deficiency is caught: keywords blue, definitions purple
    c.syn[1] = 0x7AA2F7
    c.syn[10] = 0xBB9AF7
    c.ed_bg = 0x1A1B26
    var syn = "\n".join(cvd_problems(c))
    assert_true(syn.find("syntax keyword / def:") >= 0 and syn.find("protanopia") >= 0, syn)
    assert_true(syn.find("keyword / def: 0.0 with normal") < 0, syn)
    # signal colours alike: always caught, even with normal vision
    var o = t.pals[t.find("okabe")].copy()
    o.diag_warn = o.diag_err
    assert_true("\n".join(cvd_problems(o)).find("diag_err / diag_warn: 0.0 with normal vision") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
