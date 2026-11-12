"""Tests for the Terminal ANSI and Terminal Mono themes and NO_COLOR (P10-03): colours
that name the terminal's palette slots or its default are parsed and sent as such at
every colour depth; the themes load without problems and are the files; the whole IDE
drawn with them sends no 24-bit or 256-colour code at all; NO_COLOR picks Mono unless
the config file names a theme."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from palette import ansi, COLOR_DEFAULT, is_rgb, mix
from themes import parse_color, ThemeSet, TERMINAL_ANSI, TERMINAL_MONO
from screen import Screen, COLOR_TRUE, COLOR_256, COLOR_16
from config import load_settings
from commands import CM_NEW, CM_MESSAGE
from app import *
from appstate import App
from util import decode, bytes_to_str, read_file, getcwd


def test_palette_slots_and_the_default() raises:
    assert_equal(parse_color("ansi:4"), ansi(4))
    assert_equal(parse_color("ansi:15"), ansi(15))
    assert_equal(parse_color("ansi:16"), -1)
    assert_equal(parse_color("default"), COLOR_DEFAULT)
    assert_equal(parse_color("#102030"), 0x102030)
    assert_false(is_rgb(ansi(3)))
    assert_equal(mix(ansi(4), 0x000000, 40), ansi(8))         # slots are not blended
    for mode in [COLOR_TRUE, COLOR_256, COLOR_16]:
        var s = Screen(4, 1)
        s.color_mode = mode
        var out = List[UInt8]()
        s.emit_color(out, ansi(4), False)
        s.emit_color(out, ansi(12), True)
        s.emit_color(out, COLOR_DEFAULT, False)
        s.emit_color(out, COLOR_DEFAULT, True)
        assert_equal(bytes_to_str(out), "\x1b[34m\x1b[104m\x1b[39m\x1b[49m")


def test_the_themes_load_and_are_the_files() raises:
    var ts = ThemeSet()
    assert_true(ts.find("ansi") >= 0 and ts.find("mono") >= 0)
    assert_equal(len(ts.problems), 0, "\n".join(ts.problems))
    assert_equal(bytes_to_str(read_file(getcwd() + "/themes/terminal-ansi.toml")), String(TERMINAL_ANSI))
    assert_equal(bytes_to_str(read_file(getcwd() + "/themes/terminal-mono.toml")), String(TERMINAL_MONO))


def drawn_with(theme_name: String) raises -> String:
    var app = App()
    app.scr.resize(100, 30)
    app.scr.color_mode = COLOR_TRUE
    app.apply_settings(load_settings("[ui]\ntheme = \"" + theme_name + "\"\n", ""))
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode("def main():\n    var x = 1  # a comment\n    print(\"text\", x)\n"))
    app.exec(CM_MESSAGE)
    app.open_menu(1)
    app.draw()
    var out = List[UInt8]()
    app.scr.render(out)
    return bytes_to_str(out)


def test_only_the_terminals_colours_are_sent() raises:
    for name in ["ansi", "mono"]:
        var esc = drawn_with(String(name))
        assert_true(esc.find(";2;") < 0, String(name) + ": a 24-bit colour was sent")
        assert_true(esc.find("38;5;") < 0 and esc.find("48;5;") < 0, String(name) + ": a 256-colour code was sent")
        assert_true(esc.find("\x1b[39m") >= 0 or esc.find("\x1b[49m") >= 0)
    # (the other themes do send 24-bit colours: the test would see it)
    assert_true(drawn_with("classic").find(";2;") >= 0)


def test_no_color() raises:
    _ = external_call["setenv", Int32]("NO_COLOR".as_c_string_span(), "1".as_c_string_span(), Int32(1))
    var a = App()
    a.apply_settings(load_settings("", ""))
    assert_equal(a.theme_id, "mono")
    var b = App()
    b.apply_settings(load_settings("[ui]\ntheme = \"matrix\"\n", ""))
    assert_equal(b.theme_id, "matrix")                       # the user's own choice wins
    _ = external_call["unsetenv", Int32]("NO_COLOR".as_c_string_span())
    var c = App()
    c.apply_settings(load_settings("", ""))
    assert_true(c.theme_id != "mono")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
