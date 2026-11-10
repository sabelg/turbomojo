"""Tests for .editorconfig support and per-buffer indentation settings."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from editorconfig import (
    EcProps, EcFile, ec_parse, ec_resolve, ec_for_file, glob_match, expand_braces, to_int,
)
from window import Window, WK_EDITOR
from window_search import *
from window_draw import *
from app import *
from appstate import App
from config import load_settings
from signals import own_pid
from util import decode, to_str, env_or, run_system, bytes_to_str, run_capture


def one(dir: String, text: String, path: String) -> EcProps:
    var dirs = List[String]()
    dirs.append(dir)
    var texts = List[String]()
    texts.append(text)
    return ec_resolve(dirs, texts, path)


# -------------------------------------------------------------------- globs
def test_star_matches_within_a_path_segment() raises:
    assert_true(glob_match("*.mojo", "main.mojo"))
    assert_true(glob_match("*.mojo", "src/deep/main.mojo"))    # no slash: any depth
    assert_false(glob_match("*.mojo", "main.mojo.bak"))
    assert_false(glob_match("*.mojo", "main.py"))
    assert_true(glob_match("*", "anything"))
    assert_true(glob_match("*", "a/b/c.txt"))
    assert_true(glob_match("Makefile", "sub/Makefile"))
    assert_false(glob_match("Makefile", "sub/Makefile.am"))


def test_patterns_with_a_slash_are_relative_to_the_config_dir() raises:
    assert_true(glob_match("src/*.mojo", "src/a.mojo"))
    assert_false(glob_match("src/*.mojo", "src/sub/a.mojo"))   # * does not cross '/'
    assert_false(glob_match("src/*.mojo", "other/src/a.mojo"))
    assert_true(glob_match("/top.txt", "top.txt"))
    assert_false(glob_match("/top.txt", "sub/top.txt"))
    assert_true(glob_match("src/**.mojo", "src/sub/deep/a.mojo"))
    assert_true(glob_match("src/**/a.mojo", "src/a.mojo"))     # **/ may match nothing
    assert_true(glob_match("src/**/a.mojo", "src/x/y/a.mojo"))
    assert_true(glob_match("**/tests/*.mojo", "tests/t.mojo"))
    assert_true(glob_match("**/tests/*.mojo", "pkg/tests/t.mojo"))


def test_question_mark_and_classes() raises:
    assert_true(glob_match("file?.txt", "file1.txt"))
    assert_false(glob_match("file?.txt", "file12.txt"))
    assert_false(glob_match("a?b", "a/b"))
    assert_true(glob_match("[abc].txt", "b.txt"))
    assert_false(glob_match("[abc].txt", "d.txt"))
    assert_true(glob_match("[!abc].txt", "d.txt"))
    assert_false(glob_match("[!abc].txt", "a.txt"))
    assert_true(glob_match("[a-f]1", "c1"))
    assert_false(glob_match("[a-f]1", "g1"))
    assert_true(glob_match("x\\*y", "x*y"))                    # escaped star is literal
    assert_false(glob_match("x\\*y", "xzy"))


def test_braces() raises:
    assert_true(glob_match("*.{mojo,py}", "a.mojo"))
    assert_true(glob_match("*.{mojo,py}", "dir/a.py"))
    assert_false(glob_match("*.{mojo,py}", "a.rs"))
    assert_true(glob_match("{Makefile,*.mk}", "rules.mk"))
    assert_true(glob_match("{Makefile,*.mk}", "Makefile"))
    assert_true(glob_match("file{1..3}.txt", "file2.txt"))
    assert_false(glob_match("file{1..3}.txt", "file4.txt"))
    assert_true(glob_match("*.{a,{b,c}}", "x.c"))              # nested
    assert_true(glob_match("{single}", "{single}"))            # no comma: literal braces
    assert_equal(len(expand_braces(decode("a{b,c}d{e,f}"))), 4)


# ------------------------------------------------------------------- parser
def test_parse_sections_and_root() raises:
    var f = ec_parse("# comment\n; also comment\nroot = TRUE\n\n[*]\nIndent_Style = Space\nindent_size=2\n\n[*.{mojo,py}]\nindent_size : 4\n")
    assert_true(f.root)
    assert_equal(len(f.patterns), 2)
    assert_equal(f.patterns[0], "*")
    assert_equal(f.patterns[1], "*.{mojo,py}")
    assert_equal(f.keys[0][0], "indent_style")     # keys and values are lower-cased
    assert_equal(f.values[0][0], "space")
    assert_equal(f.values[1][0], "4")              # ':' separator is accepted


def test_root_is_only_read_from_the_preamble() raises:
    var f = ec_parse("[*]\nroot = true\n")
    assert_false(f.root)


def test_to_int() raises:
    assert_equal(to_int("8"), 8)
    assert_equal(to_int("12"), 12)
    assert_equal(to_int(""), -1)
    assert_equal(to_int("4x"), -1)
    assert_equal(to_int("-2"), -1)


# ---------------------------------------------------------------- resolving
def test_properties_for_a_matching_file() raises:
    var p = one("/proj", "[*.mojo]\nindent_style = tab\ntab_width = 8\nend_of_line = crlf\ninsert_final_newline = false\ntrim_trailing_whitespace = true\ncharset = utf-8\n", "/proj/src/a.mojo")
    assert_true(p.has_indent_style)
    assert_true(p.use_tabs)
    assert_equal(p.effective_tab_width(4), 8)
    assert_true(p.has_eol)
    assert_true(p.crlf)
    assert_true(p.has_final_newline)
    assert_false(p.final_newline)
    assert_true(p.has_trim)
    assert_true(p.trim)


def test_nothing_set_for_a_non_matching_file() raises:
    var p = one("/proj", "[*.py]\nindent_size = 2\n", "/proj/a.mojo")
    assert_false(p.has_indent_size)
    assert_false(p.has_indent_style)
    assert_equal(p.effective_indent_size(4), 4)
    assert_equal(p.effective_tab_width(4), 4)


def test_later_sections_override_earlier_ones() raises:
    var p = one("/proj", "[*]\nindent_size = 2\nindent_style = space\n[*.mojo]\nindent_size = 4\n", "/proj/a.mojo")
    assert_equal(p.effective_indent_size(8), 4)
    assert_false(p.use_tabs)
    var q = one("/proj", "[*]\nindent_size = 2\n[*.mojo]\nindent_size = 4\n", "/proj/a.txt")
    assert_equal(q.effective_indent_size(8), 2)


def test_indent_size_and_tab_width_interplay() raises:
    var a = one("/p", "[*]\nindent_size = 2\n", "/p/f")
    assert_equal(a.effective_indent_size(4), 2)
    assert_equal(a.effective_tab_width(4), 2)       # tab_width defaults to indent_size
    var b = one("/p", "[*]\nindent_size = tab\ntab_width = 8\n", "/p/f")
    assert_equal(b.effective_indent_size(4), 8)     # "tab" means one tab stop
    var c = one("/p", "[*]\nindent_size = 2\ntab_width = 8\n", "/p/f")
    assert_equal(c.effective_indent_size(4), 2)
    assert_equal(c.effective_tab_width(4), 8)


def test_unset_and_invalid_values() raises:
    var p = one("/p", "[*]\nindent_size = 2\nindent_style = tab\n[*.mojo]\nindent_size = unset\nindent_style = sideways\nend_of_line = cr\ntab_width = 0\n", "/p/a.mojo")
    assert_false(p.has_indent_size)
    assert_false(p.has_indent_style)
    assert_false(p.has_eol)                         # bare CR line endings are not supported
    assert_false(p.has_tab_width)


def test_nearer_file_overrides_farther_and_root_stops_lookup() raises:
    var dirs = List[String]()
    var texts = List[String]()
    dirs.append("/a/b/c")
    texts.append("[*.mojo]\nindent_size = 3\n")
    dirs.append("/a/b")
    texts.append("root = true\n[*]\nindent_size = 5\nindent_style = tab\n")
    dirs.append("/a")
    texts.append("[*]\ntrim_trailing_whitespace = true\nindent_size = 9\n")
    var p = ec_resolve(dirs, texts, "/a/b/c/x.mojo")
    assert_equal(p.effective_indent_size(4), 3)     # nearest wins
    assert_true(p.use_tabs)                         # inherited from /a/b
    assert_false(p.has_trim)                        # /a is above the root file: ignored


def test_section_paths_are_relative_to_their_own_file() raises:
    var dirs = List[String]()
    var texts = List[String]()
    dirs.append("/a/b")
    texts.append("[src/*.mojo]\nindent_size = 2\n")
    dirs.append("/a")
    texts.append("[b/src/*.mojo]\ntab_width = 8\n[src/*.mojo]\nend_of_line = crlf\n")
    var p = ec_resolve(dirs, texts, "/a/b/src/x.mojo")
    assert_equal(p.effective_indent_size(4), 2)
    assert_equal(p.effective_tab_width(4), 8)
    assert_false(p.has_eol)                         # /a's "src/*.mojo" means /a/src


# ------------------------------------------------- buffer-level behaviour
def win(text: String) -> Window:
    var w = Window(WK_EDITOR, "t", "", 0, 0, 60, 10, 1)
    w.buf.load(decode(text))
    return w^


def text(w: Window) -> String:
    return to_str(w.buf.all_text())


def test_tab_width_changes_visual_columns() raises:
    var w = win("\tx")
    assert_equal(w.vcol(0, 1), 4)
    w.buf.tab_width = 8
    assert_equal(w.vcol(0, 1), 8)
    assert_equal(w.col_at_vcol(0, 8), 1)
    w.buf.tab_width = 2
    assert_equal(w.vcol(0, 1), 2)


def test_indent_size_drives_tab_key_newline_and_backspace() raises:
    var w = win("if a:")
    w.buf.indent_size = 2
    w.cc = 5
    w.newline(True)
    assert_equal(text(w), "if a:\n  ")            # one level = 2 spaces
    w.tab(False)
    assert_equal(text(w), "if a:\n    ")
    w.backspace()
    assert_equal(text(w), "if a:\n  ")            # back one level
    w.backspace()
    assert_equal(text(w), "if a:\n")


def test_block_indent_uses_indent_size() raises:
    var w = win("a\nb")
    w.buf.indent_size = 3
    w.select_all()
    w.tab(False)
    assert_equal(text(w), "   a\n   b")
    w.tab(True)
    assert_equal(text(w), "a\nb")


def test_trim_trailing_whitespace_is_one_undo_step() raises:
    var w = win("a  \n\tb\t \n\nc\n   ")
    w.cr = 0
    w.cc = 3
    assert_equal(w.trim_trailing_whitespace(), 3)
    assert_equal(text(w), "a\n\tb\n\nc\n")
    assert_equal(w.cc, 1)                           # cursor pulled back onto the line
    assert_equal(w.trim_trailing_whitespace(), 0)   # nothing left to do
    w.undo()
    assert_equal(text(w), "a  \n\tb\t \n\nc\n   ")


# ------------------------------------------------------------- in the app
def scratch(tag: String) -> String:
    return env_or("TMPDIR", "/tmp") + "/turbomojo-ectest-" + String(own_pid()) + "-" + tag


def put(path: String, content: String) raises:
    with open(path, "w") as f:
        f.write(content)


def test_opening_a_file_applies_editorconfig() raises:
    var dir = scratch("open")
    _ = run_system("mkdir -p '" + dir + "/src'")
    put(dir + "/.editorconfig", "root = true\n[*.mojo]\nindent_style = tab\ntab_width = 8\ntrim_trailing_whitespace = true\n[*.txt]\nindent_size = 2\n")
    put(dir + "/src/a.mojo", "def f():\n    pass\n")       # space-indented on disk
    put(dir + "/notes.txt", "hello\n")
    var app = App()
    app.scr.resize(80, 25)
    app.open_path(dir + "/src/a.mojo")
    var t = app.top()
    assert_true(app.wins[t].buf.use_tabs, "editorconfig overrides detection")
    assert_equal(app.wins[t].buf.tab_width, 8)
    assert_equal(app.wins[t].buf.indent_size, 8)
    assert_true(app.wins[t].buf.trim_on_save)
    app.open_path(dir + "/notes.txt")
    t = app.top()
    assert_equal(app.wins[t].buf.indent_size, 2)
    assert_equal(app.wins[t].buf.tab_width, 2)
    assert_false(app.wins[t].buf.trim_on_save)
    assert_false(app.wins[t].buf.use_tabs)
    _ = run_system("rm -rf '" + dir + "'")


def test_saving_trims_and_converts_line_endings() raises:
    var dir = scratch("save")
    _ = run_system("mkdir -p '" + dir + "'")
    put(dir + "/.editorconfig", "root = true\n[*]\ntrim_trailing_whitespace = true\nend_of_line = crlf\ninsert_final_newline = true\n")
    put(dir + "/a.mojo", "x = 1   \ny = 2")                # LF, trailing spaces, no final newline
    var app = App()
    app.scr.resize(80, 25)
    app.open_path(dir + "/a.mojo")
    var t = app.top()
    app.wins[t].type_char(35, True)                        # make it modified
    assert_true(app.save_window(t, 0))
    var r = run_capture("od -An -c '" + dir + "/a.mojo' | tr -s ' ' | tr -d '\\n'")
    assert_equal(bytes_to_str(r.out), " # x = 1 \\r \\n y = 2 \\r \\n")
    # the buffer was trimmed too, so buffer and file agree, and it can be undone
    assert_equal(to_str(app.wins[t].buf.all_text()), "#x = 1\ny = 2")
    assert_false(app.wins[t].buf.modified)
    _ = run_system("rm -rf '" + dir + "'")


def test_without_editorconfig_user_defaults_apply_and_nothing_is_trimmed() raises:
    var dir = scratch("none")
    _ = run_system("mkdir -p '" + dir + "'")
    put(dir + "/.editorconfig", "root = true\n")           # shields the test from parent dirs
    put(dir + "/a.mojo", "\tx = 1   \n")
    var app = App()
    app.scr.resize(80, 25)
    app.apply_settings(load_settings("[editor]\ntab_width = 8\nindent_size = 2\n", ""))
    app.open_path(dir + "/a.mojo")
    var t = app.top()
    assert_equal(app.wins[t].buf.tab_width, 8)
    assert_equal(app.wins[t].buf.indent_size, 2)
    assert_true(app.wins[t].buf.use_tabs)                  # detected from the file
    assert_false(app.wins[t].buf.trim_on_save)
    app.wins[t].type_char(35, True)
    _ = app.save_window(t, 0)
    var r = run_capture("cat '" + dir + "/a.mojo'")
    assert_equal(bytes_to_str(r.out), "#\tx = 1   \n")     # trailing spaces kept
    _ = run_system("rm -rf '" + dir + "'")


def test_settings_reject_silly_sizes() raises:
    var s = load_settings("[editor]\ntab_width = 0\nindent_size = \"wide\"\n", "")
    assert_equal(s.tab_width, 4)
    assert_equal(s.indent_size, 4)
    assert_equal(len(s.warnings), 2)


def test_ec_for_file_reads_real_files() raises:
    var dir = scratch("real")
    _ = run_system("mkdir -p '" + dir + "/a/b'")
    put(dir + "/.editorconfig", "root = true\n[*]\nindent_size = 2\n")
    put(dir + "/a/.editorconfig", "[b/*.mojo]\nindent_size = 6\n")
    assert_equal(ec_for_file(dir + "/a/b/x.mojo").effective_indent_size(4), 6)
    assert_equal(ec_for_file(dir + "/a/b/x.txt").effective_indent_size(4), 2)
    assert_equal(ec_for_file(dir + "/a/x.mojo").effective_indent_size(4), 2)
    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
