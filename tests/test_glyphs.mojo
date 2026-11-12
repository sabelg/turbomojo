"""Tests for the glyph tiers and the half-block minimap (P10-11, src/glyphs.mojo):
every symbol the chrome uses has a one-cell ASCII look-alike, letters keep theirs;
with `ui.glyphs = "ascii"` the IDE - frames, menus, a dialog, the explorer, a
notification, the minimap - sends only ASCII; in unicode and nerd the chrome draws no
wide characters, emoji or variation selectors; nerd puts Nerd Font icons before
files, folders and notices; the minimap in half blocks; the settings."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from glyphs import *
from screen import Screen, CONT
from app import *
from appstate import App
from config import load_settings
from commands import CM_ABOUT, CM_EXPLORER
from notify import NL_DONE, NL_ERROR, level_mark
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, bytes_to_str, char_width, decode


def chrome_symbols() -> List[Int]:
    """Every non-ASCII character the IDE's own drawing uses (from the sources)."""
    var out = List[Int]()
    for c in range(0x2500, 0x25A0):
        out.append(c)
    for c in range(0x2800, 0x2900):
        out.append(c)
    for c in decode("▲▼◄►▸▾◂▶◀↑↓←→↕›‹…⋯·•●○◌◆◇■▪▤§✓✗≡ƒ√⟳☼‾–—"):
        out.append(c)
    return out^


def test_every_symbol_has_an_ascii_look() raises:
    assert_equal(glyphs_of("ascii"), GLYPHS_ASCII)
    assert_equal(glyphs_of("unicode"), GLYPHS_UNICODE)
    assert_equal(glyphs_of("nerd"), GLYPHS_NERD)
    assert_equal(glyphs_of("emoji"), -1)
    for c in chrome_symbols():
        assert_equal(char_width(c), 1, "a chrome symbol that is not one cell: " + String(c))
        var a = ascii_look(c)
        assert_true(a >= 32 and a < 127, "no ASCII look for " + String(c))
    assert_equal(ascii_look(0x2554), 43)       # ╔ +
    assert_equal(ascii_look(0x2550), 61)       # ═ =
    assert_equal(ascii_look(0x2502), 124)      # │ |
    assert_equal(ascii_look(0x25BC), 118)      # ▼ v
    assert_equal(ascii_look(0x2800), 32)
    assert_equal(ascii_look(0x28FF), 35)
    assert_equal(ascii_look(NF_FIRE), 42)
    # letters stay
    for c in decode("éжλ中"):
        assert_equal(ascii_look(c), c)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-glyphs-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d) + "/pkg")
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    var x = 1\n    print(x)\n\n# end\n"))
    _ = write_file(d + "/notes.md", str_bytes("hi\n"))
    return d


def busy_app(d: String, settings: String) raises -> App:
    """The IDE with much of its chrome on screen: an editor with a minimap, the
    explorer, a notification, a dialog over it all."""
    var app = App()
    app.scr.resize(120, 36)
    app.cwd = d
    app.apply_settings(load_settings("[editor]\nminimap = true\n" + settings, ""))
    app.open_path(d + "/a.mojo")
    app.exec(CM_EXPLORER)
    app.notify(NL_DONE, "Build done", "a.mojo")
    app.notify(NL_ERROR, "Build failed", "")
    app.draw()
    return app^


def sent(mut app: App) -> String:
    app.scr.force = True
    var out = List[UInt8]()
    app.scr.render(out)
    return bytes_to_str(out)


def non_ascii(s: String) -> Int:
    var n = 0
    for b in s.as_bytes():
        if Int(b) >= 128:
            n += 1
    return n


def test_ascii_sends_only_ascii() raises:
    var d = scratch("ascii")
    var u = busy_app(d, "")
    assert_true(non_ascii(sent(u)) > 100)                 # (unicode draws frames and the rest)
    var app = busy_app(d, "[ui]\nglyphs = \"ascii\"\n")
    assert_equal(app.scr.glyphs, GLYPHS_ASCII)
    var s = sent(app)
    assert_equal(non_ascii(s), 0)
    assert_true(s.find("+=") >= 0 or s.find("=+") >= 0)   # a double frame's corner and line
    app.exec(CM_ABOUT)
    app.draw()
    assert_equal(non_ascii(sent(app)), 0)
    app.open_menu(0)
    app.draw()
    assert_equal(non_ascii(sent(app)), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def no_wide_chrome(app: App) raises:
    for k in range(app.scr.w * app.scr.h):
        var c = app.scr.ch[k]
        assert_true(c != CONT, "a wide character at cell " + String(k))
        assert_true(char_width(c) == 1, "not one cell: " + String(c))
        var m = app.scr.cmb[k]
        assert_true(m == 0, "a cell with a combining character or selector at " + String(k))


def test_the_chrome_is_one_cell_wide() raises:
    var d = scratch("wide")
    for tier in ["unicode", "nerd"]:
        var app = busy_app(d, "[ui]\nglyphs = \"" + tier + "\"\n")
        no_wide_chrome(app)
        app.exec(CM_ABOUT)
        app.draw()
        no_wide_chrome(app)
        app.open_menu(0)
        app.draw()
        no_wide_chrome(app)
    _ = run_system("rm -rf " + shell_quote(d))


def test_nerd_icons() raises:
    var d = scratch("nerd")
    var app = busy_app(d, "[ui]\nglyphs = \"nerd\"\n")
    var xi = app.explorer_index()
    assert_true(xi >= 0)
    var found_mojo = False
    var found_dir = False
    var found_md = False
    for r in range(app.wins[xi].buf.count()):
        var ln = app.wins[xi].buf.line(r)
        for c in ln:
            if c == NF_FIRE:
                found_mojo = True
            if c == NF_FOLDER:
                found_dir = True
            if c == NF_MARKDOWN:
                found_md = True
    assert_true(found_mojo and found_dir and found_md)
    assert_equal(level_mark(NL_DONE, True), chr(NF_CHECK))
    assert_equal(level_mark(NL_DONE), "✓")
    assert_equal(nerd_file_icon("x.py", False, False), NF_PYTHON)
    assert_equal(nerd_file_icon("pkg", True, True), NF_FOLDER_OPEN)
    assert_equal(nerd_file_icon("README", False, False), NF_FILE)
    # unicode: no icons
    var u = busy_app(d, "")
    var ui = u.explorer_index()
    for r in range(u.wins[ui].buf.count()):
        for c in u.wins[ui].buf.line(r):
            assert_true(c < 0xE000 or c > 0xF8FF)
    _ = run_system("rm -rf " + shell_quote(d))


def minimap_cells(app: App) -> List[Int]:
    """The first column of the minimap of the front editor, top to bottom."""
    var out = List[Int]()
    var i = app.top_editor()
    var x0 = app.wins[i].x + app.wins[i].w - 1 - 10
    for y in range(app.wins[i].y + 1, app.wins[i].y + 4):
        out.append(app.scr.ch[y * app.scr.w + x0])
    return out^


def editor_app(d: String, settings: String) raises -> App:
    var app = App()
    app.scr.resize(120, 36)
    app.cwd = d
    app.apply_settings(load_settings("[editor]\nminimap = true\n" + settings, ""))
    app.open_path(d + "/a.mojo")
    app.draw()
    return app^


def test_the_half_block_minimap() raises:
    var d = scratch("mini")
    # lines 1-2 have text, 3 is blank, 4: the upper half; the next cell's rows (5): lower empty
    _ = write_file(d + "/a.mojo", str_bytes("abc\nabc\n\nabc\nabc\n"))
    var app = editor_app(d, "minimap_style = \"blocks\"\n")
    assert_true(app.minimap_blocks)
    var cells = minimap_cells(app)
    assert_equal(cells[0], 0x2588)                 # rows 1-2 and 3-4 have text: a full block
    assert_equal(cells[1], 0x2580)                 # row 5 only: the upper half
    _ = write_file(d + "/a.mojo", str_bytes("\n\nabc\n"))
    var b = editor_app(d, "minimap_style = \"blocks\"\n")
    assert_equal(minimap_cells(b)[0], 0x2584)      # only the lower rows
    # braille by default
    var c = editor_app(d, "")
    assert_false(c.minimap_blocks)
    var m = minimap_cells(c)[0]
    assert_true(m >= 0x2800 and m <= 0x28FF)
    # ascii: the blocks would lose their halves - dots instead
    var a = editor_app(d, "minimap_style = \"blocks\"\n[ui]\nglyphs = \"ascii\"\n")
    var s = sent(a)
    assert_equal(non_ascii(s), 0)
    var am = minimap_cells(a)[0]
    assert_true(am >= 0x2800 and am <= 0x28FF)
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_settings() raises:
    var s = load_settings("", "")
    assert_equal(s.glyphs, "unicode")
    assert_equal(s.minimap_style, "auto")
    var bad = load_settings("[ui]\nglyphs = \"emoji\"\n[editor]\nminimap_style = \"dots\"\n", "")
    assert_equal(" | ".join(bad.warnings), "ui.glyphs must be unicode, ascii or nerd | editor.minimap_style must be auto, braille or blocks")
    assert_equal(bad.glyphs, "unicode")
    assert_equal(bad.minimap_style, "auto")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
