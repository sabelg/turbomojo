"""Tests for the TOML subset (src/toml.mojo), settings (src/config.mojo) and key names."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from toml import toml_parse, toml_set, toml_quote, toml_bool, TomlDoc, T_STR, T_INT, T_BOOL, T_LIST
from config import (
    Settings, load_settings, theme_from_name, theme_name, find_project_config, read_text,
    PROJECT_CONFIG_NAME,
)
from commands import parse_key, key_name, build_registry, CM_SAVE, CM_DUPLINE, CM_NONE, CM_LINENUM, CM_THEME1
from term import (
    KEY_ENTER, KEY_DELETE, KEY_BACKSPACE, KEY_PGDN, KEY_ESC, MOD_CTRL, MOD_ALT, MOD_SHIFT,
    fkey, ctrl, alt,
)
from app import *
from appstate import App
from signals import own_pid
from util import env_or, run_system, path_exists


# ------------------------------------------------------------------- parser
def test_scalars() raises:
    var d = toml_parse("name = \"turbo\"\ncount = 42\nneg = -7\nbig = 1_000\non = true\noff = false\nlit = 'C:\\path'\n")
    assert_equal(len(d.problems), 0)
    assert_equal(d.get_str("name", ""), "turbo")
    assert_equal(d.get_int("count", 0), 42)
    assert_equal(d.get_int("neg", 0), -7)
    assert_equal(d.get_int("big", 0), 1000)
    assert_true(d.get_bool("on", False))
    assert_false(d.get_bool("off", True))
    assert_equal(d.get_str("lit", ""), "C:\\path")   # literal strings keep backslashes


def test_string_escapes() raises:
    var d = toml_parse("a = \"say \\\"hi\\\"\"\nb = \"x\\\\y\"\nc = \"l1\\nl2\\tend\"\n")
    assert_equal(len(d.problems), 0)
    assert_equal(d.get_str("a", ""), "say \"hi\"")
    assert_equal(d.get_str("b", ""), "x\\y")
    assert_equal(d.get_str("c", ""), "l1\nl2\tend")


def test_tables_comments_and_whitespace() raises:
    var d = toml_parse("# top comment\n\n[ui]\n  theme = \"amber\"   # trailing comment\n\n[editor]\nauto_indent=false\n")
    assert_equal(len(d.problems), 0)
    assert_equal(d.get_str("ui.theme", ""), "amber")
    assert_false(d.get_bool("editor.auto_indent", True))
    assert_false(d.has("theme"))


def test_hash_inside_a_string_is_not_a_comment() raises:
    var d = toml_parse("s = \"a # b\"  # real comment\n")
    assert_equal(len(d.problems), 0)
    assert_equal(d.get_str("s", ""), "a # b")


def test_arrays_and_quoted_keys() raises:
    var d = toml_parse("[keys]\n\"file.save\" = [\"F2\", \"Ctrl-S\"]\n\"edit.cut\" = \"Ctrl-X\"\nnums = [1, 2, 3,]\nempty = []\n")
    assert_equal(len(d.problems), 0)
    var k = d.get_list("keys.file.save")
    assert_equal(len(k), 2)
    assert_equal(k[0], "F2")
    assert_equal(k[1], "Ctrl-S")
    assert_equal(len(d.get_list("keys.edit.cut")), 1)   # a single string reads as a list
    assert_equal(len(d.get_list("keys.nums")), 3)
    assert_equal(d.get_list("keys.nums")[2], "3")
    assert_equal(len(d.get_list("keys.empty")), 0)
    assert_equal(len(d.get_list("keys.missing")), 0)
    var names = d.keys_in("keys")
    assert_equal(len(names), 4)
    assert_equal(names[0], "file.save")


def test_defaults_and_wrong_types() raises:
    var d = toml_parse("n = 5\ns = \"x\"\n")
    assert_equal(d.get_str("missing", "dflt"), "dflt")
    assert_equal(d.get_int("missing", 9), 9)
    assert_true(d.get_bool("missing", True))
    assert_equal(d.get_str("n", "dflt"), "dflt")     # wrong type -> default
    assert_equal(d.get_int("s", 9), 9)


def test_bad_lines_are_reported_with_line_numbers_and_skipped() raises:
    var d = toml_parse("good = 1\nthis is not toml\nx = \"open\ny = 1.5\nz = \"\"\"multi\n[bad\nlast = 2\n")
    assert_equal(d.get_int("good", 0), 1)
    assert_equal(len(d.problems), 5)
    assert_true(d.problems[0].startswith("line 2:"))
    assert_true(d.problems[1].startswith("line 3:"))
    assert_true(d.problems[2].startswith("line 4:"))
    assert_true(d.problems[3].startswith("line 5:"))
    assert_true(d.problems[4].startswith("line 6:"))
    # keys after a malformed header are not attributed to the previous table
    assert_false(d.has("last"))


def test_later_values_override_and_merge_layers() raises:
    var a = toml_parse("[ui]\ntheme = \"classic\"\nclock = true\n")
    var b = toml_parse("[ui]\ntheme = \"amber\"\n")
    a.merge(b)
    assert_equal(a.get_str("ui.theme", ""), "amber")
    assert_true(a.get_bool("ui.clock", False))


# ------------------------------------------------------------------- writer
def test_quote_roundtrip() raises:
    for s in ["plain", "with \"quotes\"", "back\\slash", "tab\there", "line\nbreak", "日本 🔥"]:
        var d = toml_parse("k = " + toml_quote(String(s)) + "\n")
        assert_equal(len(d.problems), 0)
        assert_equal(d.get_str("k", "?"), String(s))
    assert_equal(toml_bool(True), "true")
    assert_equal(toml_bool(False), "false")


def test_set_replaces_existing_value_and_keeps_everything_else() raises:
    var text = String("# my settings\n[ui]\n# I like amber\ntheme = \"amber\"\nclock = true\n\n[tools]\ncompiler = \"mojo\"\n")
    var out = toml_set(text, "ui", "theme", "\"midnight\"")
    assert_equal(out, "# my settings\n[ui]\n# I like amber\ntheme = \"midnight\"\nclock = true\n\n[tools]\ncompiler = \"mojo\"\n")


def test_set_adds_key_at_the_end_of_its_table() raises:
    var text = String("[ui]\ntheme = \"amber\"\n\n[tools]\ncompiler = \"mojo\"\n")
    var out = toml_set(text, "ui", "clock", "false")
    assert_equal(out, "[ui]\ntheme = \"amber\"\nclock = false\n\n[tools]\ncompiler = \"mojo\"\n")


def test_set_appends_missing_table() raises:
    assert_equal(toml_set("", "ui", "clock", "true"), "[ui]\nclock = true\n")
    var out = toml_set("[tools]\ncompiler = \"mojo\"\n", "ui", "clock", "true")
    assert_equal(out, "[tools]\ncompiler = \"mojo\"\n\n[ui]\nclock = true\n")


def test_set_only_touches_the_right_table() raises:
    var text = String("[a]\nx = 1\n[b]\nx = 2\n")
    assert_equal(toml_set(text, "b", "x", "9"), "[a]\nx = 1\n[b]\nx = 9\n")
    assert_equal(toml_set(text, "a", "x", "9"), "[a]\nx = 9\n[b]\nx = 2\n")


def test_set_result_parses_back() raises:
    var text = String("")
    text = toml_set(text, "ui", "theme", toml_quote("amber"))
    text = toml_set(text, "ui", "clock", "false")
    text = toml_set(text, "editor", "auto_indent", "true")
    text = toml_set(text, "ui", "theme", toml_quote("classic"))
    var d = toml_parse(text)
    assert_equal(len(d.problems), 0)
    assert_equal(d.get_str("ui.theme", ""), "classic")
    assert_false(d.get_bool("ui.clock", True))
    assert_true(d.get_bool("editor.auto_indent", False))
    assert_equal(len(d.keys), 3)   # no duplicates were created


# ----------------------------------------------------------------- settings
def test_defaults() raises:
    var s = load_settings("", "")
    assert_equal(s.theme, "classic")
    assert_equal(s.theme_dark, "midnight")
    assert_equal(s.theme_light, "light")
    assert_true(s.line_numbers)
    assert_true(s.auto_indent)
    assert_true(s.highlight_line)
    assert_true(s.clock)
    assert_false(s.show_whitespace)
    assert_equal(s.compiler, "mojo")
    assert_equal(len(s.warnings), 0)


def test_user_then_project_layering() raises:
    var user = String("[ui]\ntheme = \"midnight\"\nclock = false\n[tools]\ncompiler = \"/opt/mojo\"\n")
    var project = String("[ui]\ntheme = \"amber\"\n[editor]\nauto_indent = false\n")
    var s = load_settings(user, project)
    assert_equal(s.theme, "amber")           # project wins
    assert_false(s.clock)                    # from user
    assert_false(s.auto_indent)              # from project
    assert_equal(s.compiler, "/opt/mojo")
    assert_equal(len(s.warnings), 0)


def test_invalid_values_warn_and_keep_defaults() raises:
    # (a theme's name is checked once the theme files are known: test_themes)
    var s = load_settings("[ui]\ntheme = 3\nclock = \"yes\"\nline_numbers = 1\n[tools]\ncompiler = \"\"\n", "")
    assert_equal(s.theme, "classic")
    assert_true(s.clock)
    assert_true(s.line_numbers)
    assert_equal(s.compiler, "mojo")
    assert_equal(len(s.warnings), 4)


def test_unknown_settings_and_syntax_errors_are_reported() raises:
    var s = load_settings("[ui]\nthme = \"amber\"\nnot toml here\n", "")
    assert_equal(len(s.warnings), 2)
    assert_true("unknown setting ui.thme" in s.warnings)


def test_theme_names() raises:
    assert_equal(theme_from_name("classic"), 0)
    assert_equal(theme_from_name("midnight"), 1)
    assert_equal(theme_from_name("amber"), 2)
    assert_equal(theme_from_name("Classic"), -1)
    for i in range(3):
        assert_equal(theme_from_name(theme_name(i)), i)


# ---------------------------------------------------------------- key names
def test_parse_key_names() raises:
    assert_equal(parse_key("F2"), fkey(2))
    assert_equal(parse_key("Ctrl-S"), ctrl(115))
    assert_equal(parse_key("ctrl-s"), ctrl(115))
    assert_equal(parse_key("Alt-X"), alt(120))
    assert_equal(parse_key("Ctrl-F9"), fkey(9) | MOD_CTRL)
    assert_equal(parse_key("Ctrl-Shift-F5"), fkey(5) | MOD_CTRL | MOD_SHIFT)
    assert_equal(parse_key("Shift-Del"), KEY_DELETE | MOD_SHIFT)
    assert_equal(parse_key("Alt-Bksp"), KEY_BACKSPACE | MOD_ALT)
    assert_equal(parse_key("Alt-Backspace"), KEY_BACKSPACE | MOD_ALT)
    assert_equal(parse_key("PageDown"), KEY_PGDN)
    assert_equal(parse_key("Enter"), KEY_ENTER)
    assert_equal(parse_key("Ctrl-Space"), ctrl(32))
    assert_equal(parse_key("Ctrl-/"), ctrl(47))
    assert_equal(parse_key("Ctrl--"), ctrl(45))      # the minus key itself
    assert_equal(parse_key("Alt-0"), alt(48))


def test_parse_key_rejects_nonsense() raises:
    assert_equal(parse_key(""), 0)
    assert_equal(parse_key("Ctrl-"), 0)
    assert_equal(parse_key("F13"), 0)
    assert_equal(parse_key("F0"), 0)
    assert_equal(parse_key("Hyper-X"), 0)
    assert_equal(parse_key("Ctrl-Banana"), 0)


def test_every_default_binding_survives_name_roundtrip() raises:
    var r = build_registry()
    for c in r.cmds:
        for k in c.keys:
            assert_equal(parse_key(key_name(k)), k, "roundtrip failed for " + key_name(k))


# ------------------------------------------------------- applying to the app
def test_app_reads_no_config_unless_asked() raises:
    var app = App()
    assert_equal(app.config_path, "")
    app.persist_option("ui", "clock", "false")   # must be a no-op
    assert_equal(app.config_path, "")


def test_apply_settings_with_key_rebinding() raises:
    var app = App()
    var s = load_settings("[ui]\ntheme = \"amber\"\nline_numbers = false\n[keys]\n\"file.save\" = [\"F4\", \"Ctrl-S\"]\n\"edit.duplicateLine\" = \"Alt-D\"\n", "")
    app.apply_settings(s)
    assert_equal(app.theme_idx, 2)
    assert_equal(app.pal.name, "Amber CRT")
    assert_false(app.line_numbers)
    assert_equal(app.shortcut(fkey(4)), CM_SAVE)
    assert_equal(app.shortcut(ctrl(115)), CM_SAVE)
    assert_equal(app.shortcut(fkey(2)), CM_NONE)         # old default binding is gone
    assert_equal(app.shortcut(alt(100)), CM_DUPLINE)
    assert_equal(app.menus[1].items[3].key, "F4")        # menu shows the new key
    assert_equal(len(app.config_warnings), 0)


def test_bad_key_bindings_are_reported_and_ignored() raises:
    var app = App()
    var s = load_settings("[keys]\n\"file.save\" = \"Ctrl-Banana\"\n\"no.such\" = \"F4\"\n", "")
    app.apply_settings(s)
    assert_equal(app.shortcut(fkey(2)), CM_SAVE)         # default kept
    assert_equal(len(app.config_warnings), 2)


def scratch(tag: String) -> String:
    return env_or("TMPDIR", "/tmp") + "/turbomojo-cfgtest-" + String(own_pid()) + "-" + tag


def test_options_persist_and_preserve_user_comments() raises:
    var dir = scratch("persist")
    _ = run_system("mkdir -p '" + dir + "'")
    var path = dir + "/config.toml"
    with open(path, "w") as f:
        f.write("# hand-written\n[ui]\ntheme = \"classic\"   # default look\n\n[keys]\n\"file.save\" = \"F4\"\n")
    var app = App()
    app.scr.resize(80, 25)
    app.config_path = path
    app.exec(CM_THEME1)                      # switch to Midnight through the menu command
    app.exec(CM_LINENUM)                     # turn line numbers off
    var text = read_text(path)
    assert_true(text.startswith("# hand-written\n[ui]\ntheme = \"midnight\"\n"))
    assert_true(text.find("\"file.save\" = \"F4\"") > 0, "unrelated keys must survive")
    var s = load_settings(text, "")
    assert_equal(len(s.warnings), 0)
    assert_equal(s.theme, "midnight")
    assert_false(s.line_numbers)
    assert_true(s.clock)
    assert_equal(len(s.key_commands), 1)
    _ = run_system("rm -rf '" + dir + "'")


def test_only_the_changed_option_is_written() raises:
    # values that came from defaults or a project file must not leak into the user file
    var dir = scratch("single")
    var app = App()
    app.scr.resize(80, 25)
    app.config_path = dir + "/config.toml"
    app.line_numbers = False                 # as if a project file had set it
    app.exec(CM_THEME1)
    assert_equal(read_text(app.config_path), "[ui]\ntheme = \"midnight\"\n")
    _ = run_system("rm -rf '" + dir + "'")


def test_persist_creates_the_file_and_directory() raises:
    var dir = scratch("create")
    var app = App()
    app.scr.resize(80, 25)
    app.config_path = dir + "/sub/config.toml"
    app.exec(CM_LINENUM)
    assert_true(path_exists(app.config_path))
    assert_false(load_settings(read_text(app.config_path), "").line_numbers)
    _ = run_system("rm -rf '" + dir + "'")


def test_find_project_config_walks_up() raises:
    var dir = scratch("proj")
    _ = run_system("mkdir -p '" + dir + "/a/b/c'")
    assert_equal(find_project_config(dir + "/a/b/c"), "")
    with open(dir + "/a/" + PROJECT_CONFIG_NAME, "w") as f:
        f.write("[ui]\ntheme = \"amber\"\n")
    assert_equal(find_project_config(dir + "/a/b/c"), dir + "/a/" + PROJECT_CONFIG_NAME)
    assert_equal(find_project_config(dir + "/a"), dir + "/a/" + PROJECT_CONFIG_NAME)
    assert_equal(find_project_config(dir), "")
    assert_equal(read_text(dir + "/missing.toml"), "")
    _ = run_system("rm -rf '" + dir + "'")



def test_large_file_limit_setting() raises:
    assert_equal(load_settings("", "").large_file_mb, 50)
    var s = load_settings("[editor]\nlarge_file_mb = 200\n", "")
    assert_equal(s.large_file_mb, 200)
    assert_equal(len(s.warnings), 0)
    var bad = load_settings("[editor]\nlarge_file_mb = 0\n", "")
    assert_equal(bad.large_file_mb, 50)
    assert_equal(len(bad.warnings), 1)
    var word = load_settings("[editor]\nlarge_file_mb = \"big\"\n", "")
    assert_equal(word.large_file_mb, 50)
    assert_equal(len(word.warnings), 1)


def test_mcp_server_settings() raises:
    var toml = "[mcp.turbomojo]\ncommand = \"tmide-mcp\"\nargs = [\"--stdio\"]\n[mcp.turbomojo.env]\nFOO = \"bar\"\n"
    var s = load_settings(toml, "")
    assert_equal(len(s.mcp_names), 1)
    assert_equal(s.mcp_names[0], "turbomojo")
    assert_equal(s.mcp_cmds[0], "tmide-mcp")
    assert_equal(len(s.mcp_args[0]), 1)
    assert_equal(s.mcp_args[0][0], "--stdio")
    assert_equal(len(s.mcp_env_keys[0]), 1)
    assert_equal(s.mcp_env_keys[0][0], "FOO")
    assert_equal(s.mcp_env_vals[0][0], "bar")
    assert_equal(len(s.warnings), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
