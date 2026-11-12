"""Tests for TurboMojo's own help (src/helpbook.mojo, the help pages in help/, the
TurboMojo book of the documentation viewer, Help > Tutorial, the What's new notice)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from helpbook import *
from doclib import DocLibrary, DocIndex, DK_BOOK
from commands import build_registry, parse_key, CM_NONE, CM_HELP_GUIDE, CM_HELP_CHEAT, CM_HELP_TUTORIAL, CM_HELP_NEW
from app import *
from appstate import App, M_DOCS
from notify import NL_INFO
from signals import own_pid
from util import env_or, run_system, run_capture, shell_quote, write_file, str_bytes, bytes_to_str, read_file, getcwd, path_exists, decode, to_str, state_dir


def test_the_built_in_pages_are_the_files() raises:
    assert_equal(bytes_to_str(read_file(getcwd() + "/help/guide.md")), HELP_GUIDE)
    assert_equal(bytes_to_str(read_file(getcwd() + "/help/cheatsheet.md")), HELP_CHEATSHEET)
    assert_equal(bytes_to_str(read_file(getcwd() + "/help/whats-new.md")), HELP_WHATS_NEW)
    assert_equal(bytes_to_str(read_file(getcwd() + "/help/tutorial.mojo")), HELP_TUTORIAL)


def test_every_key_of_the_cheat_sheet_does_something() raises:
    """The keys in the cheat sheet's table are bound in the default (Modern) keymap -
    so the sheet cannot drift from the program."""
    var reg = build_registry()
    var checked = 0
    for raw in HELP_CHEATSHEET.split("\n"):
        var line = String(raw)
        if not line.startswith("| ") or line.startswith("| Keys") or line.startswith("|---"):
            continue
        var cells = line.split("|")
        var keys = String(String(cells[1]).strip())
        var what = String(cells[2])
        for part in keys.replace(" / ", ", ").split(", "):
            var k = String(String(part).strip())
            if k.find("..") >= 0 or k.endswith("-letter"):
                continue                    # Alt-1..9, Alt-letter: ranges, not one key
            if k == "F10":
                continue                    # the menu bar: the IDE's own key, not a command
            var code = parse_key(k)
            assert_true(code != 0, "the cheat sheet's key " + k + " is not a key")
            var cmd = reg.find_debug_key(code) if what.find("(debugging)") >= 0 else CM_NONE
            if cmd == CM_NONE:
                cmd = reg.find_key(code)        # (Shift-F8 is an ordinary command key)
            assert_true(cmd != CM_NONE, "the cheat sheet's key " + k + " (" + String(what.strip()) + ") does nothing")
            checked += 1
    assert_true(checked >= 30, String(checked))


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-help-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def test_the_tutorial_program_runs() raises:
    var d = scratch("tut")
    _ = write_file(d + "/tutorial.mojo", str_bytes(HELP_TUTORIAL))
    var r = run_capture("mojo run " + shell_quote(d + "/tutorial.mojo") + " 2>&1")
    assert_equal(r.status, 0, bytes_to_str(r.out))
    assert_true(bytes_to_str(r.out).find("The sum of 1 to 5 is 15 and the colour is green") >= 0, bytes_to_str(r.out))
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_book_comes_first_and_is_searched() raises:
    var d = scratch("book")
    assert_true(write_help(d + "/help", "# Keyboard reference\n\n```text\nF2 Save\n```\n"))
    var lib = DocLibrary()
    lib.help_dir = d + "/help"
    lib.load(d + "/no-docs-here")
    assert_equal(lib.pages[0].kind, DK_BOOK)
    assert_equal(lib.pages[0].title, "TurboMojo")
    assert_equal(lib.pages[1].title, "TurboMojo guide")
    assert_equal(lib.pages[2].title, "Cheat sheet")
    assert_equal(lib.pages[3].title, "Keyboard reference")
    assert_equal(lib.pages[4].title, "Mojo error messages")
    assert_equal(lib.pages[5].title, "What's new")
    assert_equal(lib.help_count, 6)
    var idx = DocIndex()
    idx.build(lib)
    var found = False
    for e in idx.entries:
        if e.low.find("coding agents") >= 0 and lib.pages[e.page].title == "TurboMojo guide":
            found = True
    assert_true(found, "the guide's headings are in the finder's index")
    found = False
    for e in idx.entries:
        if e.low.find("copying must be asked for") >= 0 and lib.pages[e.page].title == "Mojo error messages":
            found = True
    assert_true(found, "the error explanations are in the finder's index")
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_help_menu() raises:
    var d = scratch("menu")
    var app = App()
    app.scr.resize(110, 34)
    app.doc_home = d + "/docs"                      # nothing downloaded
    app.help_dir = d + "/state/help"
    app.exec(CM_HELP_CHEAT)
    assert_equal(app.mode, M_DOCS)
    assert_true(app.doc_path.endswith("/help/cheatsheet.md"), app.doc_path)
    app.draw()
    var s = to_str(app.scr.to_text())
    assert_true(s.find("Cheat sheet") >= 0 and s.find("Command palette") >= 0, s)
    # the keyboard page is made from the registry: the keys of this keymap
    var keys = bytes_to_str(read_file(d + "/state/help/keys.md"))
    assert_true(keys.find("F2") >= 0 and keys.find("Save") >= 0)
    app.exec(CM_HELP_NEW)
    assert_true(app.doc_path.endswith("/help/whats-new.md"))
    # not downloaded: the welcome page still says so (the help book alone is no download)
    app.doc_path = ""
    app.doc_width = 0
    app.docs_layout()
    var w = String("")
    for l in app.doc_lines:
        w += to_str(l.cps) + "\n"
    assert_true(w.find("has not been downloaded yet") >= 0, w)
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_tutorial_copy() raises:
    var d = scratch("tutcopy")
    var app = App()
    app.scr.resize(110, 34)
    app.help_dir = d + "/state/help"
    var path = d + "/state/tutorial/tutorial.mojo"
    app.exec(CM_HELP_TUTORIAL)
    var i = app.find_editor(path)
    assert_true(i >= 0)
    assert_equal(to_str(app.wins[i].buf.all_text()), HELP_TUTORIAL)
    # changed and asked again while it is open: your changes stay
    app.wins[i].buf.load(decode("my practice\n"))
    app.wins[i].buf.modified = True
    app.exec(CM_HELP_TUTORIAL)
    i = app.find_editor(path)
    assert_equal(to_str(app.wins[i].buf.all_text()), "my practice\n")
    _ = run_system("rm -rf " + shell_quote(d))


def test_whats_new_after_an_upgrade() raises:
    var d = scratch("seen")
    var app = App()
    # the first start ever: no notice, the version is noted
    app.whats_new_check(d + "/seen-version")
    assert_equal(len(app.notes.notices), 0)
    assert_equal(String(bytes_to_str(read_file(d + "/seen-version")).strip()), TURBOMOJO_VERSION)
    app.whats_new_check(d + "/seen-version")
    assert_equal(len(app.notes.notices), 0)
    # an older version was seen: told once
    _ = write_file(d + "/seen-version", str_bytes("1.7\n"))
    app.whats_new_check(d + "/seen-version")
    assert_equal(len(app.notes.notices), 1)
    assert_equal(app.notes.notices[0].text, "What changed: Help > What's new")
    app.whats_new_check(d + "/seen-version")
    assert_equal(len(app.notes.notices), 1)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
