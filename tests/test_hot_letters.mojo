"""Tests for grapheme-width discipline, second part (P10-21b): hot letters beyond ASCII.
A translated "~Ф~айл" or "~Ö~ffnen" is pressed with the letter, small or capital, in
the menu bar (Alt), in an open menu and on dialog buttons; a strings file whose hot
letter cannot be typed (a letter with a separate combining accent, an empty one) is
warned about."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from commands import build_registry, hot_char, hot_key, hot_letter_problem, CM_NEW, CM_CLOSE
from strings import apply_strings
from toml import toml_parse
from config import load_settings
from app import *
from appstate import App, M_NORMAL, M_MENU, M_DIALOG
from term import key_event, alt, KEY_ESC
from signals import own_pid
from util import fold_letter, env_or, run_system, shell_quote, write_file, str_bytes


def test_small_letters_in_any_script() raises:
    assert_equal(fold_letter(0x41), 0x61)          # A
    assert_equal(fold_letter(0xD6), 0xF6)          # Ö
    assert_equal(fold_letter(0xD7), 0xD7)          # ×: not a letter
    assert_equal(fold_letter(0xDF), 0xDF)          # ß: small already
    assert_equal(fold_letter(0x100), 0x101)        # Ā
    assert_equal(fold_letter(0x141), 0x142)        # Ł (odd capitals there)
    assert_equal(fold_letter(0x142), 0x142)
    assert_equal(fold_letter(0x178), 0xFF)         # Ÿ
    assert_equal(fold_letter(0x17D), 0x17E)        # Ž
    assert_equal(fold_letter(0x3A3), 0x3C3)        # Σ
    assert_equal(fold_letter(0x388), 0x3AD)        # Έ
    assert_equal(fold_letter(0x424), 0x444)        # Ф
    assert_equal(fold_letter(0x401), 0x451)        # Ё
    assert_equal(fold_letter(0x531), 0x561)        # Armenian Ա
    assert_equal(fold_letter(0xFF26), 0xFF46)      # fullwidth Ｆ
    assert_equal(fold_letter(0x4E2D), 0x4E2D)      # CJK: no case
    assert_equal(fold_letter(0x37), 0x37)
    assert_equal(hot_char("~Ö~ffnen"), 0xF6)
    assert_equal(hot_char("~Ф~айл"), 0x444)
    assert_equal(hot_char("ファイル(~F~)"), 0x66)
    assert_equal(hot_key(alt(0x424)), 0x444)
    assert_equal(hot_key(0xF6), 0xF6)


def test_hot_letters_that_cannot_be_typed_are_said() raises:
    assert_equal(hot_letter_problem("~Ö~ffnen"), "")
    assert_true(hot_letter_problem("Offnen").find("no ~hot letter~") >= 0)
    assert_true(hot_letter_problem("~Ö~ffnen").find("one character") >= 0)
    assert_true(hot_letter_problem("~~Offnen").find("empty") >= 0)
    var reg = build_registry()
    var w = "\n".join(apply_strings(reg, toml_parse("[menus]\nfile = \"~D̂~atei\"\n[titles]\n\"file.new\" = \"~ ~Neu\"\n"), "de.toml"))
    assert_true(w.find("menus.file has a hot letter with a separate accent") >= 0, w)
    assert_true(w.find("titles.file.new has an empty ~hot letter~") >= 0, w)


comptime RUSSIAN = "[menus]\nfile = \"~Ф~айл\"\n[titles]\n\"file.new\" = \"~Н~овый\"\n\"file.open\" = \"~Ö~ffnen...\"\n"


def russian(d: String) raises -> App:
    _ = write_file(d + "/ru.toml", str_bytes(RUSSIAN))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.strings_dir = d
    app.apply_settings(load_settings("[ui]\nlanguage = \"ru\"\n", ""))
    assert_equal(app.menus[1].title, "~Ф~айл")
    assert_equal(len(app.config_warnings), 0, "\n".join(app.config_warnings))
    return app^


def test_the_menus_take_the_letters() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-hot-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = russian(d)
    app.draw()
    # Alt + the capital (as a terminal sends it with Shift or Caps Lock) and the small one
    app.handle(key_event(alt(0x424)))
    assert_equal(app.mode, M_MENU)
    assert_equal(app.menu_idx, 1)
    app.handle(key_event(KEY_ESC))
    app.handle(key_event(alt(0x444)))
    assert_equal(app.menu_idx, 1)
    # in the open menu: the item's letter
    var before = len(app.wins)
    app.handle(key_event(0x43D))                    # н
    assert_equal(app.mode, M_NORMAL)
    assert_equal(len(app.wins), before + 1)         # File > New
    app.handle(key_event(alt(0x444)))
    app.handle(key_event(0xD6))                     # Ö (with Shift)
    assert_equal(app.mode, M_DIALOG)                # File > Open
    for _ in range(3):
        if app.mode != M_NORMAL:
            app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL, app.dlg.title + " | " + " ".join(app.dlg.lines))
    # a dialog's buttons with Cyrillic letters: closing the new, changed window asks
    app.handle(key_event(120))                      # (typed into the new window)
    app.exec(CM_CLOSE)
    assert_equal(app.mode, M_DIALOG)
    app.dlg.buttons[2] = "~О~тмена"
    app.handle(key_event(0x445))                    # х: no button has it
    assert_equal(app.mode, M_DIALOG)
    app.handle(key_event(0x41E))                    # О: Cancel
    assert_equal(app.mode, M_NORMAL)
    assert_equal(len(app.wins), before + 1)         # (kept)
    app.exec(CM_CLOSE)
    app.dlg.buttons[1] = "~Н~ет"
    app.handle(key_event(alt(0x41D)))               # Alt + Н: No (Alt works there too)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(len(app.wins), before)             # closed without saving
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
