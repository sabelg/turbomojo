"""Tests for presets (P11-06): Modern (the terminal's colours, panes with tabs, the
explorer open now and at each start, the Modern keys) and Turbo (Turbo Classic,
overlapping windows, no explorer at start, the keymap left alone), from Options >
Presets and from the first run's theme question; each saved in the config file."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from term import key_event, KEY_ENTER, KEY_ESC, KEY_DOWN, KEY_UP
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_PRESETS, D_THEME
from commands import CM_PRESETS, CM_KEYMAP0, CM_NEW, build_registry
from window import WK_EDITOR
from config import load_settings, read_text
from signals import own_pid
from util import env_or, run_system


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-presets-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/proj' && touch '" + d + "/proj/pixi.toml'")
    return d


def tool(path: String) raises:
    with open(path, "w") as f:
        f.write("#!/bin/sh\necho 'Mojo 1.2.0 (x)'\n")
    _ = run_system("chmod +x '" + path + "'")


def an_app(d: String) raises -> App:
    """An app in a project, with every tool there (so the first run asks only the theme)."""
    for t in ["mojo", "lsp", "dap", "pixi"]:
        tool(d + "/" + t)
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d + "/proj"
    app.compiler = d + "/mojo"
    app.lsp_server = d + "/lsp"
    app.debug_adapter = d + "/dap"
    app.pixi_cmd = d + "/pixi"
    app.config_path = d + "/config.toml"
    return app^


def test_the_explorer_setting() raises:
    assert_false(load_settings("", "").explorer)
    assert_true(load_settings("[ui]\nexplorer = true\n", "").explorer)
    assert_equal(len(load_settings("[ui]\nexplorer = true\n", "").warnings), 0)
    var app = an_app(scratch("start"))
    app.exec(CM_NEW)
    app.explorer_start()
    assert_true(app.explorer_index() >= 0)
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)     # the file keeps the keyboard
    app.explorer_start()                            # (once is enough)
    var n = 0
    for w in app.wins:
        if w.title == "Files":
            n += 1
    assert_equal(n, 1)


def test_modern_and_back_to_turbo() raises:
    var d = scratch("menu")
    var app = an_app(d)
    app.exec(CM_KEYMAP0 + 1)                        # someone on the Turbo keys
    assert_equal(app.keymap, 1)
    assert_true(build_registry().index_of_name("options.presets") >= 0)
    app.exec(CM_PRESETS)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_PRESETS)
    assert_equal(app.dlg.list_sel, 0)               # the settings now are Turbo's
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.tiled)
    assert_equal(app.theme_id, "ansi")
    assert_equal(app.keymap, 0)
    assert_true(app.explorer_index() >= 0)
    assert_true(app.status.find("Preset: Modern") == 0, app.status)
    var cfg = load_settings(read_text(d + "/config.toml"), "")
    assert_true(cfg.tiled and cfg.explorer and cfg.theme == "ansi" and cfg.keymap == 0, read_text(d + "/config.toml"))
    # again: the dialog starts on Modern; Turbo undoes it, leaving the keys
    app.exec(CM_PRESETS)
    assert_equal(app.dlg.list_sel, 1)
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_ENTER))
    assert_false(app.tiled)
    assert_equal(app.theme_id, "classic")
    assert_equal(app.explorer_index(), -1)
    assert_equal(app.keymap, 0)
    var back = load_settings(read_text(d + "/config.toml"), "")
    assert_true(not back.tiled and not back.explorer and back.theme == "classic", read_text(d + "/config.toml"))
    # Cancel changes nothing
    app.exec(CM_PRESETS)
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ESC))
    assert_false(app.tiled)
    _ = run_system("rm -rf '" + d + "'")


def test_the_first_run_offers_modern() raises:
    var d = scratch("first")
    var app = an_app(d)
    app.theme_marker = d + "/asked"
    assert_true(app.first_run_theme())
    assert_equal(app.dlg.kind, D_THEME)
    assert_true(app.dlg.items[0].startswith("Modern start"), app.dlg.items[0])
    assert_equal(app.dlg.list_sel, 3)               # (on the theme in use: Turbo Classic)
    # moving onto it shows its colours, as the themes do
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_UP))
    app.theme_preview()
    assert_equal(app.theme_id, "ansi")
    assert_false(app.tiled)                         # (only looked at so far)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.tiled)
    assert_true(app.explorer_index() >= 0)
    assert_true(load_settings(read_text(d + "/config.toml"), "").explorer)
    # Options > Colour theme (not the first run) has no Modern line
    app.theme_dialog()
    assert_false(app.dlg.items[0].startswith("Modern"))
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
