"""Tests for the "Coming from" pages (P7-16, help/coming-from-python.md and the
editors page made in src/helpbook.mojo): the built-in page is the file and every Mojo
example on it builds with the real compiler; the keys table comes from the keymaps;
explanations of Python habits point to the page and P opens it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from helpbook import HELP_PYTHON, editors_markdown, help_pages
from commands import build_registry, apply_keymap, CM_SAVE, CM_FIND
from window import WK_EXPLAIN
from term import key_event, KEY_ESC
from app import *
from appstate import App, M_DOCS, M_NORMAL
from signals import own_pid
from util import env_or, run_system, run_capture, shell_quote, write_file, read_file, str_bytes, bytes_to_str, getcwd, which, to_str


def test_the_python_page() raises:
    assert_equal(bytes_to_str(read_file(getcwd() + "/help/coming-from-python.md")), HELP_PYTHON)
    assert_true("coming-from-python.md" in help_pages() and "coming-from-editors.md" in help_pages())
    var page = String(HELP_PYTHON)
    for part in ["`main`", "`raises`", "`var`", "`mut`", "`a.copy()`", "`struct`", "f-strings", "`std.`", "`Optional`", "`comptime`"]:
        assert_true(page.find(String(part)) > 0, String(part))
    if which("mojo").byte_length() == 0:
        return
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-python-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var parts = page.split("```mojo\n")
    assert_true(len(parts) >= 11, String(len(parts)))
    for k in range(1, len(parts)):
        var p = String(parts[k])
        var code = String(p[byte=0:p.find("```")])
        _ = write_file(d + "/ex.mojo", str_bytes(code))
        var r = run_capture("cd " + shell_quote(d) + " && timeout 60 mojo build ex.mojo -o ex 2>&1")
        assert_equal(r.status, 0, "example " + String(k) + " does not build:\n" + code + "\n" + bytes_to_str(r.out))
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_keys_table() raises:
    var md = editors_markdown()
    assert_true(md.startswith("# Coming from other editors\n"))
    assert_true(md.find("| | VS Code | Modern | Turbo | Emacs |") > 0)
    # each column is the keymap's own key
    var names = ["modern", "turbo", "emacs"]
    for m in range(3):
        var r = build_registry()
        apply_keymap(r, m)
        assert_true(r.key_label(CM_FIND).byte_length() > 0, String(names[m]))
    var turbo = build_registry()
    apply_keymap(turbo, 1)
    assert_true(md.find("| Find... | Ctrl-F | Ctrl-F | " + turbo.key_label(CM_FIND) + " |") > 0, md)
    assert_true(md.find("| Command palette... | Ctrl-Shift-P | Ctrl-P |") > 0, md)
    assert_true(md.find("| Duplicate line | Ctrl-Shift-Alt-Down | Ctrl-D | - | - |") > 0, md)    # no key: a dash


def test_python_habits_point_to_the_page() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-python-app-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = App()
    app.scr.resize(120, 34)
    app.help_dir = d + "/help"
    app.doc_home = d + "/docs"
    app.open_path("/nowhere/x.mojo")
    app.explain_open(1, "")                          # (an explanation; which one is found below)
    var i = -1
    var j = -1
    for k in range(20):
        app.explain_open(k, "")
        if app.wins[app.top()].path == "explain:fn-removed":
            i = k
        if app.wins[app.top()].path == "explain:aliasing":
            j = k
    assert_true(i >= 0 and j >= 0)
    # not a Python habit: P does nothing
    app.explain_open(j, "")
    assert_false(app.explain_python())
    app.handle(key_event(112))
    assert_equal(app.mode, M_NORMAL)
    # a Python habit: the hint, and P opens the page
    app.explain_open(i, "")
    assert_true(app.explain_python())
    app.draw()
    assert_true(to_str(app.scr.row_text(app.scr.h - 1)).find("Coming from Python") >= 0)
    app.handle(key_event(112))
    assert_equal(app.mode, M_DOCS)
    assert_true(app.doc_path.endswith("/coming-from-python.md"), app.doc_path)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
