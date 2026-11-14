"""Tests for the vim interface's way in (P12-05): `editor.relative_numbers` (Options >
Relative numbers: each line's distance from the cursor's line in the gutter, the
cursor's line keeping its own number), the Vim preset (Modern with vim's keys and
relative numbers) in Options > Presets and in the first run's question, and F10 and
Alt still opening the menus in vim's Normal mode."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from term import key_event, KEY_ENTER, KEY_ESC, KEY_DOWN, KEY_UP, KEY_F1, MOD_ALT
from app import *
from appstate import App, M_NORMAL, M_DIALOG, M_MENU
from dialog import D_PRESETS, D_THEME
from commands import CM_PRESETS, CM_RELNUM, CM_LINENUM, CM_NEW, build_registry
from config import load_settings, read_text
from vim import KEYMAP_VIM, VM_NORMAL, VM_INSERT
from signals import own_pid
from util import env_or, run_system, decode, to_str


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-vimstart-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/proj' && touch '" + d + "/proj/pixi.toml'")
    return d


def tool(path: String) raises:
    with open(path, "w") as f:
        f.write("#!/bin/sh\necho 'Mojo 1.2.0 (x)'\n")
    _ = run_system("chmod +x '" + path + "'")


def an_app(d: String) raises -> App:
    for t in ["mojo", "lsp", "dap", "pixi"]:
        tool(d + "/" + t)
    var app = App()
    app.scr.resize(120, 34)
    app.show_clock = False
    app.cwd = d + "/proj"
    app.compiler = d + "/mojo"
    app.lsp_server = d + "/lsp"
    app.debug_adapter = d + "/dap"
    app.pixi_cmd = d + "/pixi"
    app.config_path = d + "/config.toml"
    return app^


def gutter(app: App, line: Int) -> String:
    """The gutter of the screen row showing buffer line `line` (no scrolling here)."""
    var w = app.wins[app.top()].copy()
    var row = to_str(app.scr.row_text(w.y + 1 + line))
    var out = String("")
    var i = 0
    for c in decode(row):
        if i > w.x and i <= w.x + w.gut:
            out += chr(c)
        i += 1
    return String(out.strip())


def test_the_setting() raises:
    assert_false(load_settings("", "").relative_numbers)
    var s = load_settings("[editor]\nrelative_numbers = true\n", "")
    assert_true(s.relative_numbers)
    assert_equal(len(s.warnings), 0)
    assert_true(build_registry().index_of_name("options.relativeNumbers") >= 0)
    var app = App()
    app.apply_settings(s)
    assert_true(app.rel_numbers)                    # (the config file's setting reaches the editor)
    app.apply_settings(load_settings("", ""))
    assert_false(app.rel_numbers)


def test_relative_numbers_in_the_gutter() raises:
    var d = scratch("gutter")
    var app = an_app(d)
    app.exec(CM_NEW)
    app.fit_windows()
    app.wins[app.top()].buf.load(decode("a\nb\nc\nd\ne\nf\n"))
    app.wins[app.top()].cr = 3
    app.draw()
    assert_equal(gutter(app, 0), "1")               # off: the line's own number
    assert_equal(gutter(app, 5), "6")
    app.exec(CM_RELNUM)
    assert_true(app.rel_numbers)
    assert_true(CM_RELNUM in app.checked())
    app.draw()
    assert_equal(gutter(app, 0), "3")               # three above the cursor
    assert_equal(gutter(app, 2), "1")
    assert_equal(gutter(app, 3), "4")               # the cursor's line: its own number
    assert_equal(gutter(app, 5), "2")               # two below
    assert_true(load_settings(read_text(d + "/config.toml"), "").relative_numbers, read_text(d + "/config.toml"))
    # with the numbers off, turning it on brings them back
    app.exec(CM_RELNUM)
    assert_false(app.rel_numbers)
    assert_false(CM_RELNUM in app.checked())
    app.exec(CM_LINENUM)
    assert_false(app.line_numbers)
    app.exec(CM_RELNUM)
    assert_true(app.line_numbers and app.rel_numbers)
    var cfg = load_settings(read_text(d + "/config.toml"), "")
    assert_true(cfg.line_numbers and cfg.relative_numbers, read_text(d + "/config.toml"))
    _ = run_system("rm -rf '" + d + "'")


def test_the_vim_preset() raises:
    var d = scratch("preset")
    var app = an_app(d)
    app.exec(CM_PRESETS)
    assert_equal(app.dlg.kind, D_PRESETS)
    assert_equal(len(app.dlg.items), 3)
    assert_true(app.dlg.items[2].startswith("Vim"), app.dlg.items[2])
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.tiled)
    assert_equal(app.theme_id, "ansi")
    assert_equal(app.keymap, KEYMAP_VIM)
    assert_true(app.rel_numbers)
    assert_true(app.explorer_index() >= 0)
    assert_true(app.status.find("Preset: Vim") == 0, app.status)
    var cfg = load_settings(read_text(d + "/config.toml"), "")
    assert_true(cfg.tiled and cfg.theme == "ansi" and cfg.keymap == KEYMAP_VIM and cfg.relative_numbers, read_text(d + "/config.toml"))
    # the dialog knows it again; Modern takes vim's keys and the relative numbers away
    app.exec(CM_PRESETS)
    assert_equal(app.dlg.list_sel, 2)
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.keymap, 0)
    assert_false(app.rel_numbers)
    assert_true(app.tiled)
    var back = load_settings(read_text(d + "/config.toml"), "")
    assert_true(back.keymap == 0 and not back.relative_numbers, read_text(d + "/config.toml"))
    # Turbo leaves the keys and the numbering as they are
    app.exec(CM_PRESETS)
    assert_equal(app.dlg.list_sel, 1)
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))                # Vim again
    app.exec(CM_PRESETS)
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_ENTER))                # Turbo
    assert_false(app.tiled)
    assert_equal(app.theme_id, "classic")
    assert_equal(app.keymap, KEYMAP_VIM)
    assert_true(app.rel_numbers)
    _ = run_system("rm -rf '" + d + "'")


def test_the_first_run_offers_vim() raises:
    var d = scratch("first")
    var app = an_app(d)
    app.theme_marker = d + "/asked"
    assert_true(app.first_run_theme())
    assert_equal(app.dlg.kind, D_THEME)
    assert_true(app.dlg.items[1].startswith("Vim start"), app.dlg.items[1])
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_UP))
    app.theme_preview()
    assert_equal(app.theme_id, "ansi")              # its colours, as Modern's
    assert_false(app.tiled)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.tiled)
    assert_equal(app.keymap, KEYMAP_VIM)
    assert_true(app.rel_numbers)
    assert_equal(load_settings(read_text(d + "/config.toml"), "").keymap, KEYMAP_VIM)
    app.theme_dialog()
    assert_false(app.dlg.items[1].startswith("Vim"))
    _ = run_system("rm -rf '" + d + "'")


def test_the_menus_stay_in_vim_mode() raises:
    var d = scratch("menus")
    var app = an_app(d)
    app.keymap = KEYMAP_VIM
    app.vim_reset()
    app.rebuild_keys(False)
    app.exec(CM_NEW)
    app.draw()
    assert_equal(app.vim.mode, VM_NORMAL)
    app.handle_key(KEY_F1 + 9)                      # F10
    assert_equal(app.mode, M_MENU)
    app.handle_key(KEY_ESC)
    app.handle_key(KEY_ESC)
    assert_equal(app.mode, M_NORMAL)
    app.handle_key(MOD_ALT | ord("f"))              # Alt-F: the File menu
    assert_equal(app.mode, M_MENU)
    app.handle_key(KEY_ESC)
    app.handle_key(KEY_ESC)
    # ...and in Insert mode
    app.handle_key(ord("i"))
    assert_equal(app.vim.mode, VM_INSERT)
    app.handle_key(KEY_F1 + 9)
    assert_equal(app.mode, M_MENU)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
