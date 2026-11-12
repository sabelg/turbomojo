"""Tests for counts and filters in titles (P10-13): the Problems tab says how many
errors and warnings there are and, when its filter hides some, how many it shows;
the explorer has a filter (/ sets it, C clears it) that keeps the matching names and
the folders above them, and its title shows it, count first ("2/5 /test"); a long
title is cut short instead of running under the frame's icons and number; the palette's
title says how many items the typing leaves, "12/340"."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from app_problems import problems_tab
from problems import parse_compiler_output
from app_explorer import explorer_title
from appstate import App, M_DIALOG, M_NORMAL, PG_PROBLEMS
from term import key_event, KEY_ENTER
from commands import CM_EXPLORER
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, to_str


def test_the_problems_tab_text() raises:
    assert_equal(problems_tab(0, 0, -1), "Problems")
    assert_equal(problems_tab(3, 7, -1), "Problems (3 E, 7 W)")
    assert_equal(problems_tab(0, 2, -1), "Problems (2 W)")
    assert_equal(problems_tab(3, 7, 4), "Problems (3 E, 7 W; 4 shown)")
    assert_equal(problems_tab(0, 0, 0), "Problems (0 shown)")
    assert_equal(explorer_title("", "", 3, 0), "Files")
    assert_equal(explorer_title("main", "", 3, 0), "Files (main)")
    assert_equal(explorer_title("main", "test", 2, 3), "2/5 /test")


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-titles-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d) + "/sub")
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    pritn(1)\n    var unused = 2\n"))
    _ = write_file(d + "/b.py", str_bytes("x\n"))
    _ = write_file(d + "/sub/test_x.mojo", str_bytes("x\n"))
    _ = write_file(d + "/sub/other.txt", str_bytes("x\n"))
    return d


def screen_has(app: App, text: String) -> Bool:
    return to_str(app.scr.to_text()).find(text) >= 0


def test_the_problems_tab() raises:
    var d = scratch("probs")
    var app = App()
    app.scr.resize(140, 40)
    app.cwd = d
    app.draw()
    assert_equal(problems_tab(app.prob_counts[0], app.prob_counts[1], app.prob_counts[2]), "Problems")   # (nothing yet)
    var out = d + "/a.mojo:2:5: error: use of unknown declaration 'pritn'\n" + d + "/a.mojo:3:9: warning: 'unused' was never used\n"
    _ = app.fill_messages("Building a.mojo", str_bytes(out), "Build failed")
    app.prob_build = parse_compiler_output(out, d)     # (what a build that ends does)
    app.problems_show(False)
    app.draw()
    assert_true(screen_has(app, " Problems (1 E, 1 W) "), to_str(app.scr.to_text()))
    # the filter hides the errors: the tab says how many it shows
    app.panel_page(PG_PROBLEMS)
    assert_true(app.panel_filter_key(101))      # E
    app.draw()
    assert_true(screen_has(app, " Problems (1 E, 1 W; 1 shown) "), to_str(app.scr.to_text()))
    assert_true(app.panel_filter_key(99))       # C: all again
    app.draw()
    assert_true(screen_has(app, " Problems (1 E, 1 W) "))
    # a narrow panel: the counts give way, the tabs stay
    app.scr.resize(52, 30)
    app.layout_sync()
    app.draw()
    var narrow = to_str(app.scr.to_text())
    if narrow.find(" Message ") >= 0:
        assert_true(narrow.find(" Problems ") >= 0 and narrow.find("1 E") < 0, narrow)
    _ = run_system("rm -rf " + shell_quote(d))


def explorer_rows(app: App) -> List[String]:
    var out = List[String]()
    var xi = app.explorer_index()
    for r in range(app.wins[xi].buf.count()):
        out.append(String(to_str(app.wins[xi].buf.line(r)).strip()))
    return out^


def test_the_explorer_filter() raises:
    var d = scratch("ex")
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.exec(CM_EXPLORER)
    var xi = app.explorer_index()
    assert_true(xi >= 0)
    app.focus(xi)
    # open sub
    var sub = app.ex.row_of(d + "/sub")
    assert_true(sub >= 0)
    app.ex.toggle(sub)
    app.explorer_show()
    assert_equal(len(app.ex.rows), 5)
    # "/" asks for the text; Enter applies it
    app.handle(key_event(47))
    assert_equal(app.mode, M_DIALOG)
    for c in "test".codepoints():
        app.handle(key_event(Int(c)))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    var rows = explorer_rows(app)
    assert_equal(len(rows), 2, " | ".join(rows) + " / filter " + app.ex.filter + " / mode " + String(app.mode))
    assert_true(rows[0].endswith("sub") and rows[1].endswith("test_x.mojo"), " | ".join(rows))
    assert_equal(app.wins[xi].title, "2/5 /test")
    app.draw()
    assert_true(screen_has(app, "2/5 /test"), to_str(app.scr.to_text()))
    # a folder's name: what is listed in it stays
    app.explorer_filter("SUB")
    rows = explorer_rows(app)
    assert_equal(len(rows), 3, " | ".join(rows))
    # nothing matches
    app.explorer_filter("zzz")
    assert_equal(explorer_rows(app)[0], "(no names contain \"zzz\" - C shows all)")
    # C shows all again
    app.focus(xi)
    app.handle(key_event(99))
    assert_equal(len(app.ex.rows), 5)
    assert_equal(app.wins[xi].title, "Files")
    _ = run_system("rm -rf " + shell_quote(d))


def test_a_long_title_is_cut() raises:
    var d = scratch("long")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    var t = app.top_editor()
    app.wins[t].w = 30
    app.wins[t].title = "a_very_long_name_of_a_file_indeed.mojo"
    app.wins[t].number = 3
    app.draw()
    var y = app.wins[t].y
    var row = to_str(app.scr.row_text(y))
    assert_true(row.find("…") > 0, row)
    var x = app.wins[t].x
    assert_equal(app.scr.ch[y * app.scr.w + x + app.wins[t].w - 7], 51)   # the number, "3"
    assert_equal(app.scr.ch[y * app.scr.w + x + app.wins[t].w - 8], 32)      # the title's end before it
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_palette_count() raises:
    var d = scratch("pal")
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.quick_dialog(">")
    app.draw()
    var all = len(app.dlg.items)
    assert_true(all > 50)
    assert_true(screen_has(app, " Go to  " + String(all) + "/" + String(all) + " "), to_str(app.scr.to_text()))
    for c in "save".codepoints():
        app.handle(key_event(Int(c)))
    app.draw()
    var n = len(app.dlg.shown)
    assert_true(n > 0 and n < all)
    assert_true(screen_has(app, " Go to  " + String(n) + "/" + String(all) + " "), to_str(app.scr.to_text()))
    # a line number: no count
    app.handle(key_event(27))
    app.quick_dialog(":")
    app.draw()
    assert_false(screen_has(app, "Go to  1/1"))
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
