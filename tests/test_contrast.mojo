"""Tests for the contrast gate (P10-04): the two measures agree with their published
reference values; every built-in theme whose colours are RGB reaches the floors for
each pair (text 4.5:1 and Lc 45, secondary text 3:1 and Lc 30, disabled Lc 15); High
Contrast reaches the stricter AAA level for its text (7:1 and Lc 60); a theme made
worse is caught, and the problem says which pair and by how much."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from contrast import wcag_ratio, apca_lc, theme_contrast, contrast_problems, ROLE_TEXT, one_decimal
from themes import ThemeSet
from palette import Palette, is_rgb


def test_reference_values() raises:
    # WCAG: black on white is 21:1, a colour on itself 1:1, #767676 on white about 4.54:1
    assert_true(abs(wcag_ratio(0x000000, 0xFFFFFF) - 21.0) < 0.01)
    assert_true(abs(wcag_ratio(0x777777, 0x777777) - 1.0) < 0.001)
    assert_true(abs(wcag_ratio(0x767676, 0xFFFFFF) - 4.54) < 0.01)
    assert_equal(wcag_ratio(0x112233, 0xEEDDCC), wcag_ratio(0xEEDDCC, 0x112233))
    # APCA 0.0.98G: black on white Lc 106.04, white on black Lc -107.88,
    # #888888 on white Lc 63.06 (the values of the reference implementation)
    assert_true(abs(apca_lc(0x000000, 0xFFFFFF) - 106.04) < 0.1)
    assert_true(abs(apca_lc(0xFFFFFF, 0x000000) + 107.88) < 0.1)
    assert_true(abs(apca_lc(0x888888, 0xFFFFFF) - 63.06) < 0.1)
    assert_equal(apca_lc(0x777777, 0x777777), 0.0)
    assert_equal(one_decimal(4.46), "4.5")


def test_every_built_in_theme_passes() raises:
    var t = ThemeSet()
    var measured = 0
    for k in range(t.count()):
        var problems = contrast_problems(t.pals[k])
        assert_equal(len(problems), 0, t.ids[k] + ":\n" + "\n".join(problems))
        for c in theme_contrast(t.pals[k]):
            if is_rgb(c.fg) and is_rgb(c.bg):
                measured += 1
    assert_true(measured > 7 * 30, "too few pairs measured: " + String(measured))


def test_high_contrast_reaches_aaa() raises:
    var t = ThemeSet()
    var k = t.find("contrast")
    assert_true(k >= 0)
    var low = List[String]()
    for c in theme_contrast(t.pals[k]):
        if c.role != ROLE_TEXT:
            continue
        var w = wcag_ratio(c.fg, c.bg)
        var l = abs(apca_lc(c.fg, c.bg))
        if w < 7.0 or l < 60.0:
            low.append(c.what + ": " + one_decimal(w) + ":1, Lc " + String(Int(l)))
    assert_equal(len(low), 0, "\n".join(low))


def test_a_worse_theme_is_caught() raises:
    var p = Palette()
    p.gutter_fg = p.gutter_bg + 0x050505        # line numbers almost the colour of the gutter
    p.msg_err = 0x00AAAA                        # an error in the colour of its background
    var problems = contrast_problems(p)
    assert_equal(len(problems), 2, "\n".join(problems))
    assert_true(problems[0].startswith("msg_err on msg_bg: 1.0:1, Lc 0 (needs 4.5:1, Lc 45)"), problems[0])
    assert_true(problems[1].startswith("gutter_fg on gutter_bg:"), problems[1])
    assert_true(problems[1].find("needs 3.0:1, Lc 30") > 0, problems[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
