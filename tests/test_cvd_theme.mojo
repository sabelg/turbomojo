"""Tests for the Okabe-Ito theme and the colour-vision check (P10-18a,
src/contrast.mojo): the simulation agrees with what is known of it (grey stays grey,
a red and a green fall together without green cones, blue and green without blue ones);
the Okabe-Ito theme keeps its problem severities, success and failure, git markers and
main syntax classes apart with normal vision and protanopia, deuteranopia and
tritanopia, and reaches the contrast floors; a theme that breaks this is caught, and
the problem names the pair and the deficiency."""
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
