"""Tests for colour themes (src/themes.mojo, the theme files in themes/, mode 2031 in
src/term.mojo, Options > Colour theme)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.math import sqrt
from themes import *
from palette import Palette, theme
from config import load_settings
from term import Terminal, key_event, KEY_ENTER, KEY_DOWN
from app import *
from app_draw import scanline_dim
from appstate import App, M_DIALOG, M_NORMAL, now_ns
from dialog import D_THEME
from commands import CM_THEME_PICK, CM_THEME1, CM_NEW
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, bytes_to_str, read_file, getcwd


def test_colours_are_read() raises:
    assert_equal(parse_color("#1A2b3C"), 0x1A2B3C)
    assert_equal(parse_color(" #fff "), 0xFFFFFF)
    assert_equal(parse_color("#123"), 0x112233)
    assert_equal(parse_color("123456"), -1)
    assert_equal(parse_color("#12345"), -1)
    assert_equal(parse_color("#12345g"), -1)


def test_every_colour_has_a_name() raises:
    var p = Palette()
    var keys = palette_keys()
    assert_equal(len(keys), 68)
    for k in range(len(keys)):
        assert_true(palette_set(p, keys[k], 1000 + k), keys[k])
    for k in range(len(keys)):
        assert_equal(palette_get(p, keys[k]), 1000 + k, keys[k])
    assert_false(palette_set(p, "nope", 1))
    assert_equal(palette_get(p, "nope"), -1)
    assert_equal(len(syntax_keys()), len(p.syn))


def test_the_built_in_files_are_the_shipped_files() raises:
    assert_equal(bytes_to_str(read_file(getcwd() + "/themes/paper-light.toml")), PAPER_LIGHT)
    assert_equal(bytes_to_str(read_file(getcwd() + "/themes/high-contrast.toml")), HIGH_CONTRAST)
    assert_equal(bytes_to_str(read_file(getcwd() + "/themes/hacker-matrix.toml")), HACKER_MATRIX)
    var t = ThemeSet()
    assert_equal(len(t.problems), 0, "\n".join(t.problems))
    assert_equal(t.ids[3], "light")
    assert_equal(t.ids[4], "contrast")
    assert_equal(t.ids[5], "matrix")
    assert_equal(t.pals[5].name, "Hacker Matrix")
    assert_equal(t.pals[5].ed_bg, 0x031A08)
    assert_equal(t.pals[5].ed_bg, t.pals[5].doc_bg)    # the editor as the agent panel
    assert_equal(t.pals[5].gutter_bg, t.pals[5].ed_bg)
    assert_false(t.pals[5].scanlines)                  # (the user did not want the lines)
    assert_false(t.pals[0].scanlines)
    assert_false(t.pals[t.find("light")].scanlines)
    # green, and four accents: blue, yellow, red, brown
    assert_equal(t.pals[5].syn[10], 0xFFE45C)          # def: yellow
    assert_equal(t.pals[5].syn[8], 0x6CB8FF)           # builtin: blue
    assert_equal(t.pals[5].syn[4], 0xD2964A)           # string: brown
    assert_equal(t.pals[5].syn[6], 0xFF4A3D)           # decorator: red
    assert_equal(t.pals[5].diag_err, 0xFF4A3D)         # red, yellow and blue beside the green
    assert_equal(t.pals[5].diag_warn, 0xFFE45C)
    assert_equal(t.pals[5].diag_note, 0x3FA9F5)
    var light = t.pals[t.find("light")].copy()
    assert_equal(light.name, "Paper Light")
    assert_false(t.dark[t.find("light")])
    assert_true(t.dark[t.find("contrast")])
    assert_equal(light.ed_bg, 0xFBFBF8)
    assert_equal(light.syn[1], 0x7A3E9D)           # keyword
    # the light theme sets every colour (nothing of its dark base shows through)
    var base = theme(1)
    var keys = palette_keys()
    for k in keys:
        assert_true(palette_get(light, k) != palette_get(base, k) or palette_get(base, k) == palette_get(t.pals[t.find("contrast")], k), "light leaves " + k + " as its base has it")


def lum(c: Int) -> Float64:
    var out = 0.0
    var w = [0.2126, 0.7152, 0.0722]
    for k in range(3):
        var v = Float64((c >> (16 - 8 * k)) & 255) / 255.0
        v = v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
        out += w[k] * v
    return out


def contrast(a: Int, b: Int) -> Float64:
    var la = lum(a)
    var lb = lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def test_contrast_of_the_new_themes() raises:
    """WCAG contrast: High Contrast 7:1 (AAA) for text and code, Paper Light 4.5:1
    (AA) for text and code."""
    var t = ThemeSet()
    var hc = t.pals[t.find("contrast")].copy()
    var pl = t.pals[t.find("light")].copy()
    for pair in [("ed", 7.0), ("msg", 7.0), ("dlg", 7.0), ("doc", 7.0), ("list", 7.0)]:
        var kf = String(pair[0]) + "_fg"
        var kb = String(pair[0]) + "_bg"
        assert_true(contrast(palette_get(hc, kf), palette_get(hc, kb)) >= pair[1], "contrast " + kf)
        assert_true(contrast(palette_get(pl, kf), palette_get(pl, kb)) >= 4.5, "light " + kf)
    for k in range(len(hc.syn)):
        assert_true(contrast(hc.syn[k], hc.ed_bg) >= 7.0, "contrast syntax " + String(k))
        assert_true(contrast(pl.syn[k], pl.ed_bg) >= 4.5, "light syntax " + String(k) + " " + String(contrast(pl.syn[k], pl.ed_bg)))
    var mx = t.pals[t.find("matrix")].copy()
    for k in range(len(mx.syn)):
        assert_true(contrast(mx.syn[k], mx.ed_bg) >= 4.5, "matrix syntax " + String(k))
    for kf in ["ed_fg", "diag_err", "diag_warn", "diag_note", "gutter_fg"]:
        assert_true(contrast(palette_get(mx, String(kf)), mx.ed_bg) >= 4.5, "matrix " + String(kf))
    assert_true(contrast(mx.sel_fg, mx.sel_bg) >= 4.5)
    assert_true(contrast(mx.btn_focus_fg, mx.btn_bg) >= 4.5)
    assert_true(contrast(hc.sel_fg, hc.sel_bg) >= 7.0)
    assert_true(contrast(pl.sel_fg, pl.sel_bg) >= 4.5)
    assert_true(contrast(hc.menu_sel_fg, hc.menu_sel_bg) >= 7.0)
    assert_true(contrast(pl.menu_sel_fg, pl.menu_sel_bg) >= 4.5)


def test_a_users_theme_file() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-themes-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/mine.toml", str_bytes("name = \"Mine\"\nbase = \"light\"\ndark = false\n[colors]\ned_bg = \"#EEDDCC\"\nnot_a_colour = \"#000000\"\ned_fg = \"red\"\n[syntax]\nstring = \"#00AA00\"\nfoo = \"#111111\"\n"))
    _ = write_file(d + "/notes.txt", str_bytes("not a theme"))
    var t = ThemeSet()
    t.add_folder(d)
    var k = t.find("mine")
    assert_true(k >= 0)
    assert_equal(t.count(), 7)
    assert_equal(t.pals[k].name, "Mine")
    assert_equal(t.pals[k].ed_bg, 0xEEDDCC)
    assert_equal(t.pals[k].ed_fg, 0x1F1F1F)         # a bad colour leaves its base's
    assert_equal(t.pals[k].syn[4], 0x00AA00)
    assert_equal(t.pals[k].syn[1], 0x7A3E9D)        # from Paper Light
    var all = "\n".join(t.problems)
    assert_true(all.find("mine.toml: there is no colour \"not_a_colour\"") >= 0, all)
    assert_true(all.find("mine.toml: colors.ed_fg is not a colour") >= 0, all)
    assert_true(all.find("there is no syntax colour \"foo\"") >= 0, all)
    # a file may replace a built-in theme of its name
    _ = write_file(d + "/classic.toml", str_bytes("name = \"My Classic\"\n"))
    var t2 = ThemeSet()
    t2.add_folder(d)
    assert_equal(t2.pals[t2.find("classic")].name, "My Classic")
    assert_equal(t2.count(), 7)
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_terminal_says_light_or_dark() raises:
    var term = Terminal()
    assert_equal(term.scheme, 0)
    var evs = term.feed(str_bytes("\x1b[?997;2n"), False)
    assert_equal(len(evs), 0)                       # not a key
    assert_equal(term.scheme, 2)
    evs = term.feed(str_bytes("\x1b[?997;1nx"), False)
    assert_equal(term.scheme, 1)
    assert_equal(len(evs), 1)                       # what follows is still read


def test_scanlines() raises:
    assert_equal(scanline_dim(0x646464), 0x4E4E4E)
    assert_equal(scanline_dim(-1), -1)
    var app = App()
    app.scr.resize(80, 20)
    app.apply_settings(load_settings("[ui]\ntheme = \"matrix\"\n", ""))
    assert_false(app.pal.scanlines)                    # Hacker Matrix has none of its own
    app.apply_settings(load_settings("[ui]\ntheme = \"matrix\"\nscanlines = true\n", ""))
    assert_true(app.pal.scanlines)
    app.exec(CM_NEW)
    app.draw()
    # inside the editor: an odd row is the even row above, darker
    var bg2 = app.scr.bg_at(40, 4)
    var bg3 = app.scr.bg_at(40, 5)
    assert_equal(bg2, app.pal.ed_bg)
    assert_equal(bg3, scanline_dim(app.pal.ed_bg))
    # ui.scanlines = false: none (a terminal's own CRT shader draws its own)
    app.apply_settings(load_settings("[ui]\ntheme = \"matrix\"\nscanlines = false\n", ""))
    assert_false(app.pal.scanlines)
    app.draw()
    assert_equal(app.scr.bg_at(40, 5), app.pal.ed_bg)
    # and true puts them on any theme
    app.apply_settings(load_settings("[ui]\ntheme = \"classic\"\nscanlines = true\n", ""))
    assert_true(app.pal.scanlines)


def test_the_desktops_light_or_dark() raises:
    assert_equal(scheme_from("15;0", ""), 1)          # COLORFGBG: white on black
    assert_equal(scheme_from("0;15", ""), 2)
    assert_equal(scheme_from("default;8", ""), 1)
    assert_equal(scheme_from("", "'prefer-dark'\n"), 1)
    assert_equal(scheme_from("", "'prefer-light'"), 2)
    assert_equal(scheme_from("", "'default'"), 2)
    assert_equal(scheme_from("", ""), 0)
    assert_equal(scheme_from("x;y", "'prefer-dark'"), 1)  # unreadable COLORFGBG: GNOME's
    # GNOME Terminal says nothing: the desktop's setting decides, the terminal's wins
    var app = App()
    app.scr.resize(100, 30)
    app.apply_settings(load_settings("[ui]\ntheme = \"auto\"\n", ""))
    app.desktop_scheme = 2
    app.desktop_checked_ns = Int(now_ns())            # (not looked up again in the test)
    app.theme_tick()
    assert_equal(app.pal.name, "Paper Light")
    app.desktop_scheme = 1
    app.theme_tick()
    assert_equal(app.pal.name, "Midnight Neon")
    app.term.scheme = 2
    app.theme_tick()
    assert_equal(app.pal.name, "Paper Light")


def test_auto_follows_the_terminal() raises:
    var app = App()
    app.scr.resize(100, 30)
    app.apply_settings(load_settings("[ui]\ntheme = \"auto\"\ntheme_light = \"contrast\"\n", ""))
    assert_equal(app.pal.name, "Midnight Neon")     # dark until the terminal says
    app.term.scheme = 2
    app.theme_tick()
    assert_equal(app.pal.name, "High Contrast")
    app.term.scheme = 1
    app.theme_tick()
    assert_equal(app.pal.name, "Midnight Neon")
    # a theme that does not exist: said, and classic used
    app.apply_settings(load_settings("[ui]\ntheme = \"nosuch\"\n", ""))
    assert_equal(app.theme_idx, 0)
    assert_true("\n".join(app.config_warnings).find("there is no theme \"nosuch\"") >= 0)


def test_the_theme_dialog() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-themedlg-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = App()
    app.scr.resize(100, 30)
    app.config_path = d + "/config.toml"
    app.exec(CM_THEME_PICK)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_THEME)
    assert_equal(app.dlg.items[0], "Follow the terminal: Midnight Neon when dark, Paper Light when light")
    assert_equal(app.dlg.items[4], "Paper Light   (light)")
    assert_equal(app.dlg.items[6], "Hacker Matrix")
    assert_equal(app.dlg.items[app.dlg.list_sel], "Turbo Classic")        # the theme in use
    # down to High Contrast, Enter: used and written to the user's config
    for _ in range(4):
        app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.pal.name, "High Contrast")
    assert_true(bytes_to_str(read_file(d + "/config.toml")).find("theme = \"contrast\"") >= 0)
    # the old menu commands still choose the first three
    app.exec(CM_THEME1)
    assert_equal(app.pal.name, "Midnight Neon")
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
