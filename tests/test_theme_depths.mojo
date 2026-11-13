"""Tests for semantic colour roles and colours designed for 256 and 16 colours
(P10-18b): a theme's [roles] set every colour of a role; [colors256] / [syntax256]
and [colors16] / [syntax16] change only the palette for that depth and carry over to
themes based on it; "256:N" names an xterm-256 colour, sent as such (or as its
nearest of 16); every built-in theme, as a 256- and a 16-colour terminal shows it,
reaches the contrast floors - which the automatic nearest colours do not; the IDE
uses the palette for the terminal's depth."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from contrast import depth_problems, depth_rgb, theme_contrast
from themes import ThemeSet, parse_color, role_keys, role_fields, role_color
from palette import ansi, is_rgb
from caps import COLOR_TRUE, COLOR_256, COLOR_16, x256_rgb
from screen import Screen
from app import *
from appstate import App
from util import to_str, bytes_to_str


def test_the_256_colour_form() raises:
    assert_equal(parse_color("256:17"), ansi(17))
    assert_equal(parse_color("256:255"), ansi(255))
    assert_equal(parse_color("256:256"), -1)
    assert_equal(parse_color("ansi:17"), -1)            # (ansi: is the 16 slots)
    assert_equal(x256_rgb(16), 0x000000)
    assert_equal(x256_rgb(196), 0xFF0000)
    assert_equal(x256_rgb(24), 0x005F87)
    assert_equal(x256_rgb(244), 0x808080)
    var s = Screen(10, 2)
    var out = List[UInt8]()
    s.color_mode = COLOR_256
    s.emit_color(out, ansi(124), False)
    assert_equal(bytes_to_str(out), "\x1b[38;5;124m")
    out.clear()
    s.color_mode = COLOR_TRUE
    s.emit_color(out, ansi(24), True)
    assert_equal(bytes_to_str(out), "\x1b[48;5;24m")
    out.clear()
    s.color_mode = COLOR_16
    s.emit_color(out, ansi(196), False)                  # pure red: the nearest of 16 (VGA red)
    assert_equal(bytes_to_str(out), "\x1b[31m")


def test_roles() raises:
    var keys = role_keys()
    assert_true(len(keys) >= 10)
    for r in keys:
        assert_true(len(role_fields(r)) > 0, r)
    assert_equal(len(role_fields("cursor_blurred")), 0)  # (derived: the cursor, muted)
    var t = ThemeSet()
    var p = t.pals[t.find("midnight")].copy()
    assert_equal(role_color(p, "surface"), p.ed_bg)
    assert_equal(role_color(p, "diag_error"), p.diag_err)
    assert_equal(role_color(p, "nothing"), -1)


def test_a_theme_file_with_roles_and_depths() raises:
    var t = ThemeSet()
    var text = String("name = \"Mine\"\nbase = \"amber\"\n[roles]\nsurface = \"#102030\"\ndiag_error = \"#FF4040\"\nsparkle = \"#FFFFFF\"\n")
    text += "[colors]\ngutter_bg = \"#000000\"\n[colors256]\ndiag_error = \"256:203\"\n[colors16]\ned_fg = \"ansi:15\"\n[syntax16]\nkeyword = \"ansi:13\"\n"
    t.add_text("mine", text, "mine.toml")
    var k = t.find("mine")
    var all = "\n".join(t.problems)
    assert_equal(len(t.problems), 1, all)
    assert_true(all.find("mine.toml: there is no role \"sparkle\"") >= 0, all)
    var p = t.pals[k].copy()
    for f in ["ed_bg", "doc_bg", "msg_bg", "list_bg"]:
        assert_equal(role_color(p, "surface"), 0x102030, String(f))
    assert_equal(p.msg_bg, 0x102030)
    assert_equal(p.gutter_bg, 0x000000)                  # [colors] after [roles]
    assert_equal(p.diag_err, 0xFF4040)
    assert_equal(p.msg_err, 0xFF4040)
    # 256: its own error colour, the rest as in truecolor
    var p256 = t.for_depth(k, COLOR_256)
    assert_equal(p256.diag_err, ansi(203))
    assert_equal(p256.msg_err, ansi(203))
    assert_equal(p256.ed_bg, 0x102030)
    # 16: its own text and keyword colours, and Amber's 16-colour design underneath
    var p16 = t.for_depth(k, COLOR_16)
    assert_equal(p16.ed_fg, ansi(15))
    assert_equal(p16.syn[1], ansi(13))
    assert_equal(p16.menu_bg, ansi(11))                  # (from amber's [colors16])
    assert_equal(p16.diag_err, 0xFF4040)
    assert_true(p.syn[1] != ansi(13) and p256.syn[1] != ansi(13))
    assert_true(t.for_depth(k, COLOR_TRUE).menu_bg != ansi(11))


def test_every_theme_at_every_depth() raises:
    var t = ThemeSet()
    assert_equal(len(t.problems), 0, "\n".join(t.problems))
    var measured = 0
    for k in range(t.count()):
        for mode in [COLOR_256, COLOR_16]:
            var p = t.for_depth(k, mode)
            var bad = depth_problems(p, mode)
            assert_equal(len(bad), 0, t.ids[k] + (" 256" if mode == COLOR_256 else " 16") + ":\n" + "\n".join(bad))
            for c in theme_contrast(p):
                if depth_rgb(c.fg, mode) >= 0 and depth_rgb(c.bg, mode) >= 0:
                    measured += 1
    assert_true(measured > 500, String(measured))


def test_the_nearest_colours_alone_fall_short() raises:
    var t = ThemeSet()
    var amber = t.pals[t.find("amber")].copy()           # (truecolor, sent as the nearest of 16)
    var bad = depth_problems(amber, COLOR_16)
    assert_true(len(bad) >= 10, "\n".join(bad))
    assert_true("\n".join(bad).find("ed_fg on ed_bg: 4.0:1 (needs 4.5:1)") >= 0, "\n".join(bad))
    var all_short = 0
    for k in range(t.count()):
        all_short += len(depth_problems(t.pals[k], COLOR_256)) + len(depth_problems(t.pals[k], COLOR_16))
    assert_true(all_short >= 30, String(all_short))
    # the same colour as its background: said so
    var p = t.pals[t.find("okabe")].copy()
    p.ed_fg = 0x0A0A0A
    var same = depth_problems(p, COLOR_16)
    assert_true("\n".join(same).find("ed_fg on ed_bg: the same colour as its background") >= 0, "\n".join(same))


def test_the_ide_uses_the_palette_for_its_depth() raises:
    var app = App()
    app.scr.resize(80, 24)
    app.theme_id = "amber"
    app.scr.color_mode = COLOR_16
    app.theme_apply()
    assert_equal(app.pal.menu_bg, ansi(11))
    assert_equal(app.pal.ed_fg, ansi(11))
    app.scr.color_mode = COLOR_TRUE
    app.theme_apply()
    assert_true(is_rgb(app.pal.menu_bg))
    app.theme_id = "midnight"
    app.scr.color_mode = COLOR_256
    app.theme_apply()
    assert_equal(app.pal.sel_bg, ansi(24))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
