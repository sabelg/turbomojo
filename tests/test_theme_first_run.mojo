"""Tests for choosing a theme with a preview (P10-20b): in Options > Colour theme the
theme marked in the list shows at once, behind the box, and nothing is written; OK
keeps it (and writes it), Esc or Cancel goes back to the one before; on the very
first run - no config file, never asked - the box opens by itself with a welcome
line, once."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from appstate import App, M_DIALOG, M_NORMAL
from dialog import D_THEME
from commands import CM_THEME_PICK
from config import read_text
from term import key_event, KEY_DOWN, KEY_UP, KEY_ENTER, KEY_ESC, KEY_TAB
from signals import own_pid
from util import env_or, run_system, shell_quote, path_exists, write_file, str_bytes


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-firstrun-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.config_path = d + "/config/config.toml"
    app.theme_marker = d + "/state/theme-asked"
    app.theme_id = "classic"
    app.theme_apply()
    return app^


def test_the_preview() raises:
    var d = scratch("preview")
    var app = ide(d)
    app.exec(CM_THEME_PICK)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.pal.name, "Turbo Classic")
    app.handle(key_event(KEY_DOWN))                 # Midnight Neon, shown at once
    assert_equal(app.pal.name, "Midnight Neon")
    app.handle(key_event(KEY_DOWN))
    assert_equal(app.pal.name, "Amber CRT")
    app.draw()
    assert_equal(app.scr.bg_at(2, app.scr.h - 1), app.pal.status_bg)   # (the screen too)
    assert_false(path_exists(app.config_path))      # nothing written while looking
    app.handle(key_event(KEY_ESC))                  # Esc: back as it was
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.pal.name, "Turbo Classic")
    assert_equal(app.theme_id, "classic")
    assert_false(path_exists(app.config_path))
    # OK keeps the one marked, and writes it
    app.exec(CM_THEME_PICK)
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.theme_id, "midnight")
    assert_equal(app.pal.name, "Midnight Neon")
    assert_true(read_text(app.config_path).find("theme = \"midnight\"") >= 0, read_text(app.config_path))
    # following the terminal, marked first in the list, previews too
    app.exec(CM_THEME_PICK)
    for _ in range(5):
        app.handle(key_event(KEY_UP))
    assert_equal(app.theme_id, "auto")
    for _ in range(6):                              # Tab to Cancel, Enter
        if app.dlg.focus_button() == 1:
            break
        app.handle(key_event(KEY_TAB))
    assert_equal(app.dlg.focus_button(), 1)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.theme_id, "midnight")
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_first_run_asks_once() raises:
    var d = scratch("first")
    var app = ide(d)
    assert_true(app.first_run_theme())
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_THEME)
    assert_true(app.dlg.title.find("Welcome") >= 0, app.dlg.title)
    assert_true(path_exists(app.theme_marker))
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ESC))                  # no answer: the default stays
    assert_equal(app.theme_id, "classic")
    # the next start: not again
    var again = ide(d)
    assert_false(again.first_run_theme())
    assert_equal(again.mode, M_NORMAL)
    # someone with a config file already is not asked either
    var d2 = scratch("configured")
    _ = run_system("mkdir -p " + shell_quote(d2 + "/config"))
    _ = write_file(d2 + "/config/config.toml", str_bytes("[ui]\n"))
    var old = ide(d2)
    assert_false(old.first_run_theme())
    assert_false(path_exists(old.theme_marker))
    # nor without a marker file to remember it (tests, line mode)
    var none = App()
    assert_false(none.first_run_theme())
    _ = run_system("rm -rf " + shell_quote(d) + " " + shell_quote(d2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
