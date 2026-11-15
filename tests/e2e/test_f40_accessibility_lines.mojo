"""E2E Test Suite for Feature #40:
Screen-Reader Cues & `tmide --lines` Extended.
- Structural screen-reader context cues (linemode command driver).
- Line mode operations: open, print, goto, set, insert, append, save.
- Extended commands: undo, redo, replace, find, cell navigation, fix (quickfix), git status, doc lookup.
- Screen plain mode suppressing unicode box-drawing characters.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List

from linemode import *
from appstate import App
from screen import Screen
from buffer import Mark
from docs import DocEntry
from doclib import IndexEntry, DocPage, IK_API
from symindex import IndexedSymbol
from outline import SK_FUNCTION
from watch import file_sig
from util import decode, to_str, run_system, shell_quote
from harness import ScratchDir, make_test_app, count_decorations


# =========================================================================
# Tier 1 Tests (Happy Path)
# =========================================================================

def test_f40_t1_01_linemode_open_print_and_goto() raises:
    """Verifies linemode open, print with range, and direct line number jump."""
    var s = ScratchDir.create("f40_open")
    var content = """def first():
    var a = 1
    var b = 2
    return a + b
"""
    s.write("sample.mojo", content)
    var app = make_test_app(s, reader=True)

    var res1 = app.line_command("open " + s.path + "/sample.mojo")
    assert_true(len(res1) > 0)
    assert_true(res1[0].find("opened") >= 0)

    var res2 = app.line_command("print 1-2")
    assert_true(len(res2) >= 2)
    assert_true(res2[0].find("def first():") >= 0)
    assert_true(res2[1].find("var a = 1") >= 0)

    var res3 = app.line_command("3")
    assert_true(len(res3) > 0)
    assert_true(res3[0].find("var b = 2") >= 0)
    s.cleanup()


def test_f40_t1_02_linemode_set_insert_append_and_save() raises:
    """Verifies mutating file via set, insert, append, and saving to disk."""
    var s = ScratchDir.create("f40_edit")
    s.write("edit.mojo", "line 1\nline 2\nline 3\n")
    var app = make_test_app(s, reader=True)

    _ = app.line_command("open " + s.path + "/edit.mojo")

    var res_set = app.line_command("set 2 line 2 mutated")
    assert_true(len(res_set) > 0)
    assert_true(res_set[0].find("line 2 mutated") >= 0)

    var res_ins = app.line_command("insert 3 inserted line")
    assert_true(len(res_ins) > 0)
    assert_true(res_ins[0].find("inserted line") >= 0)

    var res_app = app.line_command("append appended line")
    assert_true(len(res_app) > 0)
    assert_true(res_app[0].find("appended line") >= 0)

    var res_save = app.line_command("save")
    assert_true(len(res_save) > 0)
    assert_true(res_save[0].find("saved") >= 0)

    var disk_content = s.read("edit.mojo")
    assert_true(disk_content.find("line 2 mutated") >= 0)
    assert_true(disk_content.find("inserted line") >= 0)
    assert_true(disk_content.find("appended line") >= 0)
    s.cleanup()


def test_f40_t1_03_linemode_undo_and_redo_cycle() raises:
    """Verifies undo and redo commands revert and re-apply buffer modifications."""
    var s = ScratchDir.create("f40_undo")
    s.write("undo.mojo", "def original():\n    return 0\n")
    var app = make_test_app(s, reader=True)

    _ = app.line_command("open " + s.path + "/undo.mojo")
    _ = app.line_command("set 1 def modified():")

    var res_u = app.line_command("undo")
    assert_true(len(res_u) > 0)
    assert_true(res_u[0].find("undone") >= 0)

    var res_p = app.line_command("print 1")
    assert_true(res_p[0].find("def original():") >= 0)

    var res_r = app.line_command("redo")
    assert_true(len(res_r) > 0)
    assert_true(res_r[0].find("redone") >= 0)

    var res_p2 = app.line_command("print 1")
    assert_true(res_p2[0].find("def modified():") >= 0)

    var res_r2 = app.line_command("redo")
    assert_equal(res_r2[0], "nothing to redo")
    s.cleanup()


def test_f40_t1_04_linemode_replace_in_line() raises:
    """Verifies replace command substitutes substring on current or specified line."""
    var s = ScratchDir.create("f40_replace")
    s.write("replace.mojo", "var old_var = old_var + 1\n")
    var app = make_test_app(s, reader=True)

    _ = app.line_command("open " + s.path + "/replace.mojo")

    # Replace on current line (line 1)
    var res1 = app.line_command("replace old_var new_var")
    assert_true(len(res1) > 0)
    assert_true(res1[0].find("var new_var = old_var + 1") >= 0)

    # Explicit line number replace
    var res2 = app.line_command("replace 1 old_var new_var")
    assert_true(len(res2) > 0)
    assert_true(res2[0].find("var new_var = new_var + 1") >= 0)

    # Missing substring reports error
    var res_fail = app.line_command("replace missing repl")
    assert_true(len(res_fail) > 0)
    assert_true(res_fail[0].find("not found") >= 0)
    s.cleanup()


def test_f40_t1_05_linemode_find_forward_and_wrap() raises:
    """Verifies find command searches forward across lines and wraps around buffer."""
    var s = ScratchDir.create("f40_find")
    s.write("find.mojo", "line 1\nneedle alpha\nline 3\nneedle beta\nline 5\n")
    var app = make_test_app(s, reader=True)

    _ = app.line_command("open " + s.path + "/find.mojo")

    var res1 = app.line_command("find needle")
    assert_true(len(res1) > 0)
    assert_true(res1[0].find("needle alpha") >= 0)

    var res2 = app.line_command("find needle")
    assert_true(len(res2) > 0)
    assert_true(res2[0].find("needle beta") >= 0)

    var res_miss = app.line_command("find nonexistent")
    assert_true(len(res_miss) > 0)
    assert_true(res_miss[0].find("not found: nonexistent") >= 0)
    s.cleanup()


# =========================================================================
# Tier 2 Tests (Boundary Values & Corner Cases)
# =========================================================================

def test_f40_t2_01_linemode_code_cell_navigation() raises:
    """Verifies linemode cell listing, cell next, and cell prev navigation."""
    var s = ScratchDir.create("f40_cells")
    var content = """# %% [Cell 1: Setup]
var x = 10

# %% [Cell 2: Compute]
var y = x * 2
"""
    s.write("cells.mojo", content)
    var app = make_test_app(s, reader=True)

    _ = app.line_command("open " + s.path + "/cells.mojo")

    var res_list = app.line_command("cell")
    assert_true(len(res_list) >= 2)
    assert_true(res_list[0].find("cell 1") >= 0)
    assert_true(res_list[1].find("cell 2") >= 0)

    var res_next = app.line_command("cell next")
    assert_true(len(res_next) > 0)
    assert_true(res_next[0].find("cell 2") >= 0)

    var res_prev = app.line_command("cell prev")
    assert_true(len(res_prev) > 0)
    assert_true(res_prev[0].find("cell 1") >= 0)
    s.cleanup()


def test_f40_t2_02_linemode_quickfix_application() raises:
    """Verifies linemode fix command applies Mojo 1.2 quickfix (e.g. fn -> def)."""
    var s = ScratchDir.create("f40_fix")
    s.write("fix.mojo", "fn legacy_function():\n    return 42\n")
    var app = make_test_app(s, reader=True)

    _ = app.line_command("open " + s.path + "/fix.mojo")

    var res_fix = app.line_command("fix")
    assert_true(len(res_fix) > 0)
    assert_true(res_fix[0].find("fixed: Replace removed 'fn' with 'def'") >= 0)

    var res_p = app.line_command("print 1")
    assert_true(res_p[0].find("def legacy_function():") >= 0)
    s.cleanup()


def test_f40_t2_03_linemode_git_status_and_clean_output() raises:
    """Verifies linemode git status executes genuine git command and produces clean output without ANSI escapes."""
    var s = ScratchDir.create("f40_git")
    _ = run_system(
        "cd "
        + shell_quote(s.path)
        + " && git init && git config user.name 'Test' && git config user.email 'test@test.com' && touch init.mojo && git add init.mojo && git commit -m 'init' 2>/dev/null"
    )
    s.write("init.mojo", "var modified = True\n")
    s.write("untracked.mojo", "var untracked = True\n")

    var app = make_test_app(s, reader=True)
    _ = app.line_command("open " + s.path + "/init.mojo")

    var res_git = app.line_command("git status")
    var found_init = False
    var found_untracked = False
    var has_ansi = False
    for line in res_git:
        if line.find("init.mojo") >= 0:
            found_init = True
        if line.find("untracked.mojo") >= 0:
            found_untracked = True
        if line.find("\x1b") >= 0:
            has_ansi = True

    assert_true(found_init)
    assert_true(found_untracked)
    assert_false(has_ansi)
    s.cleanup()


def test_f40_t2_04_linemode_doc_symbol_lookup() raises:
    """Verifies linemode doc command retrieves documentation or reports unknown symbol."""
    var s = ScratchDir.create("f40_doc")
    s.write("doc_test.mojo", "def my_helper():\n    pass\n")
    var app = make_test_app(s, reader=True)
    _ = app.line_command("open " + s.path + "/doc_test.mojo")

    # Populate doc cache for the opened file
    var sig = file_sig(s.path + "/doc_test.mojo")
    var stamp = sig.mtime_s * 1000000000 + sig.mtime_ns
    var entries = List[DocEntry]()
    entries.append(DocEntry("my_helper", "function", "", "doc_test", "Documentation for my_helper function."))
    app.doc_files.append(s.path + "/doc_test.mojo")
    app.doc_sizes.append(sig.size)
    app.doc_times.append(stamp)
    app.doc_entries.append(entries^)

    var res_doc = app.line_command("doc my_helper")
    assert_true(len(res_doc) > 0)
    assert_true(res_doc[0].find("Documentation for my_helper") >= 0)

    var res_miss = app.line_command("doc UnknownSymbol")
    assert_true(len(res_miss) > 0)
    assert_true(res_miss[0].find("no documentation found for UnknownSymbol") >= 0)

    var res_empty = app.line_command("doc")
    assert_equal(res_empty[0], "doc SYMBOL")
    s.cleanup()


def test_f40_t2_05_screen_reader_plain_box_drawing_suppression() raises:
    """Verifies Screen.plain = True suppresses unicode box-drawing characters (U+2500..U+259F)."""
    var scr = Screen(40, 5)
    scr.plain = True
    scr.put(0, 0, 0x250C, 7, 0)
    scr.put(1, 0, 0x2500, 7, 0)
    scr.put(2, 0, 0x2510, 7, 0)

    var row_txt = to_str(scr.row_text(0))
    assert_equal(count_decorations(row_txt), 0)

    # With plain disabled, box-drawing characters are preserved
    scr.plain = False
    scr.put(0, 0, 0x250C, 7, 0)
    var row_decor = to_str(scr.row_text(0))
    assert_equal(count_decorations(row_decor), 1)


def test_f40_t2_06_utf8_replace_doc_fallbacks_and_reader_cues() raises:
    """Verifies UTF-8 codepoint replace, doc_index/symidx fallbacks, and announce_reader_context."""
    var s = ScratchDir.create("f40_utf8_cues")
    s.write("utf8.mojo", "def compute():\n    var café = αβγ + 1\n    return café\n")
    s.write("lib.mojo", "def project_sym(x: Int) -> Int:\n    return x + 1\n")
    var app = make_test_app(s, reader=True)
    _ = app.line_command("open " + s.path + "/utf8.mojo")

    # UTF-8 multi-byte prefix + multi-byte target replacement
    var rep = app.line_command("replace 2 αβγ δε")
    assert_true(rep[0].find("var café = δε + 1") >= 0, rep[0])

    # Fallback 1: doc_index lookup
    app.doc_lib.pages.append(DocPage("Stdlib", "", 0, 2))
    app.doc_index.entries.append(IndexEntry(IK_API, 0, "struct List", 0, ""))
    app.doc_index.built = True
    var d_idx = app.line_command("doc List")
    assert_true(len(d_idx) > 0 and d_idx[0].find("List") >= 0)

    # Fallback 2: symidx lookup
    app.symidx.syms.append(IndexedSymbol("project_sym", SK_FUNCTION, s.path + "/lib.mojo", 0, 0, ""))
    var d_sym = app.line_command("doc project_sym")
    assert_true(len(d_sym) > 0 and d_sym[0].find("project_sym") >= 0)

    # Reader context announcements: window + scope, then fold + diagnostic
    var ei = app.top_editor()
    app.wins[ei].goto(1, 0)
    var cue1 = announce_reader_context(app)
    assert_true(cue1.find("window: utf8.mojo") >= 0, cue1)
    assert_true(cue1.find("in compute") >= 0, cue1)
    assert_equal(announce_reader_context(app), "")

    app.wins[ei].buf.folds.append(1)
    app.wins[ei].buf.fold_ends.append(2)
    app.wins[ei].buf.marks.append(Mark(1, 0, 1, 5, 1, "bad operand"))
    var cue2 = announce_reader_context(app)
    assert_true(cue2.find("folded") >= 0, cue2)
    assert_true(cue2.find("error: bad operand") >= 0, cue2)
    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
