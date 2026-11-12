"""Tests for externalised UI strings (src/strings.mojo): the English template, a
translation applied to the registry and the menus, the checks on a translation, the
language choice, and `tmide --strings`."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from strings import *
from commands import build_registry, plain, CM_NEW, CM_OPEN, CM_SAVE
from menu import build_menus, draw_menubar
from toml import toml_parse
from config import load_settings
from app import *
from appstate import App
from signals import own_pid
from util import env_or, run_system, run_capture, shell_quote, write_file, str_bytes, bytes_to_str, to_str, getcwd


def test_the_english_template_goes_back_unchanged() raises:
    var reg = build_registry()
    var t = strings_template(reg)
    assert_true(t.find("\"file.new\" = \"~N~ew\"") > 0)
    assert_true(t.find("file = \"~F~ile\"") > 0)
    assert_true(t.find("system = \"~≡~\"") > 0)
    var doc = toml_parse(t)
    assert_equal(len(doc.problems), 0, "\n".join(doc.problems))
    var reg2 = build_registry()
    var w = apply_strings(reg2, doc, "en.toml")
    assert_equal(len(w), 0, "\n".join(w))
    for k in range(len(reg.cmds)):
        assert_equal(reg2.cmds[k].title, reg.cmds[k].title)
        assert_equal(reg2.cmds[k].hint, reg.cmds[k].hint)
    # every command and menu is in it
    var titles = toml_parse(t).keys_in("titles")
    assert_equal(len(titles), len(reg.cmds))
    assert_equal(len(toml_parse(t).keys_in("menus")), len(reg.menu_titles))


comptime GERMAN = "[menus]\nfile = \"~D~atei\"\nedit = \"~B~earbeiten\"\n[titles]\n\"file.new\" = \"~N~eu\"\n\"file.open\" = \"Ö~f~fnen...\"\n[hints]\n\"file.new\" = \"Ein neues Bearbeitungsfenster\"\n"


def test_a_translation() raises:
    var reg = build_registry()
    var w = apply_strings(reg, toml_parse(GERMAN), "de.toml")
    assert_equal(len(w), 0, "\n".join(w))
    var ni = reg.index_of(CM_NEW)
    assert_equal(reg.cmds[ni].title, "~N~eu")
    assert_equal(reg.cmds[ni].hint, "Ein neues Bearbeitungsfenster")
    assert_equal(reg.cmds[reg.index_of(CM_SAVE)].title, "~S~ave")      # left out: English
    var menus = build_menus(reg)
    assert_equal(menus[1].title, "~D~atei")
    assert_equal(menus[1].items[0].label, "~N~eu")
    assert_equal(menus[1].items[1].label, "Ö~f~fnen...")


def test_mistakes_in_a_translation_are_said() raises:
    var bad = "[menus]\nfile = \"~E~ditieren\"\nnowhere = \"x\"\n[titles]\n\"file.new\" = \"Neu\"\n\"file.open\" = \"~S~uchen\"\n\"no.such\" = \"~x~\"\n"
    var reg = build_registry()
    var w = "\n".join(apply_strings(reg, toml_parse(bad), "de.toml"))
    assert_true(w.find("de.toml: there is no menu \"nowhere\"") >= 0, w)
    assert_true(w.find("titles: there is no command \"no.such\"") >= 0, w)
    assert_true(w.find("titles.file.new has no ~hot letter~") >= 0, w)
    assert_true(w.find("two menus have the hot letter e") >= 0, w)           # Editieren and Edit
    assert_true(w.find("in the Editieren menu two items have the hot letter s (Save)") >= 0 or w.find("two items have the hot letter s") >= 0, w)


def test_the_language() raises:
    assert_equal(language_from("", "de_DE.UTF-8"), "de")
    assert_equal(language_from("", "fr.UTF-8"), "fr")
    assert_equal(language_from("", "pt_BR"), "pt")
    assert_equal(language_from("", "C.UTF-8"), "en")
    assert_equal(language_from("", "POSIX"), "en")
    assert_equal(language_from("", ""), "en")
    assert_equal(language_from("ES", "de_DE.UTF-8"), "es")       # the setting wins


def test_the_app_speaks_the_language() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-strings-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/de.toml", str_bytes(GERMAN))
    var app = App()
    app.scr.resize(100, 30)
    app.strings_dir = d
    app.apply_settings(load_settings("[ui]\nlanguage = \"de\"\n", ""))
    assert_equal(app.language, "de")
    app.draw()
    assert_true(to_str(app.scr.row_text(0)).find("Datei") > 0, to_str(app.scr.row_text(0)))
    assert_true(to_str(app.scr.row_text(0)).find("Bearbeiten") > 0)
    # the keyboard reference uses the translated titles too
    var lines = "\n".join(app.keyboard_lines())
    assert_true(lines.find("Neu") >= 0, lines)
    # a language without a file: English, and nothing to warn about
    var app2 = App()
    app2.strings_dir = d
    app2.apply_settings(load_settings("[ui]\nlanguage = \"it\"\n", ""))
    assert_equal(len(app2.config_warnings), 0)
    assert_equal(app2.menus[1].title, "~F~ile")
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_command_line_prints_the_template() raises:
    var r = run_capture(shell_quote(getcwd() + "/build/tmide") + " --strings")
    assert_equal(r.status, 0)
    var t = bytes_to_str(r.out)
    assert_equal(t, strings_template(build_registry()))
    assert_equal(len(toml_parse(t).problems), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
