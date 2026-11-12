"""Tests for plugin panels (P8-02, src/plugins.mojo PluginPanel and panel_lines,
src/app_plugins.mojo): the list and table layouts, and with the example plugin's
"Most used words" table: the panel beside the code, row styles, Enter telling the
plugin the row, a save refreshing it, the user closing it (the room given back) and a
plugin that dies taking its panel with it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from plugins import *
from window import WK_PANEL, WK_EDITOR, RM_OK, RM_DIM, RM_ERROR, RM_NONE
from term import key_event, wait_readable, KEY_ENTER, KEY_DOWN
from commands import CM_CLOSE, CM_SAVE
from app import *
from appstate import App, now_ns
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, getcwd, decode, to_str

comptime MS = 1000000


def test_list_and_table_lines() raises:
    var l = PluginPanel(0, "x")
    var a = List[String]()
    a.append("first")
    l.cells.append(a^)
    var b = List[String]()
    b.append("second")
    l.cells.append(b^)
    var ll = panel_lines(l)
    assert_equal(len(ll), 2)
    assert_equal(ll[1], "second")
    assert_equal(l.header_rows(), 0)
    var t = PluginPanel(0, "t")
    t.table = True
    t.columns.append("Word")
    t.columns.append("Times")
    var r1 = List[String]()
    r1.append("apple")
    r1.append("3")
    t.cells.append(r1^)
    var r2 = List[String]()
    r2.append("x" * (PANEL_COL_MAX + 5))
    r2.append("12")
    t.cells.append(r2^)
    var tl = panel_lines(t)
    assert_equal(t.header_rows(), 2)
    assert_true(tl[0].startswith("Word"), tl[0])
    assert_true(tl[1].startswith("-----"), tl[1])
    var col2 = tl[0].find("Times")
    assert_equal(tl[2].find("3"), col2)                    # the cells line up under their titles
    assert_true(tl[3].find("…") > 0)                        # a long cell is cut
    assert_equal(pad_cell("ab", 4), "ab  ")
    assert_equal(pad_cell("abcdef", 4), "abc…")
    assert_equal(style_mark("error"), RM_ERROR)
    assert_equal(style_mark("nonsense"), RM_NONE)


def pump(mut app: App, ms: Int):
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        _ = wait_readable(app.plugin_fds(), 20)
        app.plugins_tick(now_ns())


def panel_win(app: App) -> Int:
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_PANEL:
            return i
    return -1


def win_text(app: App, i: Int) -> String:
    return to_str(app.wins[i].buf.all_text())


def command_id(app: App, name: String) -> Int:
    for c in app.reg.cmds:
        if c.name == name:
            return c.id
    return -1


def test_the_example_table_panel() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-panels-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d + "/plugins"))
    _ = run_system("cp -r " + shell_quote(getcwd() + "/examples/plugins/wordcount") + " " + shell_quote(d + "/plugins/"))
    _ = write_file(d + "/a.txt", str_bytes("apple banana apple cherry apple banana\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.plugins_dir = d + "/plugins"
    app.plugins_start()
    for _ in range(200):
        pump(app, 50)
        if command_id(app, "plugin.wordcount.words") > 0:
            break
    app.open_path(d + "/a.txt")
    var ei = app.top()
    var full = app.wins[ei].w
    app.exec(command_id(app, "plugin.wordcount.words"))
    for _ in range(100):
        pump(app, 50)
        var pw = panel_win(app)
        if pw >= 0 and win_text(app, pw).find("apple") >= 0:
            break
    var pw = panel_win(app)
    assert_true(pw >= 0, "no panel")
    assert_equal(app.wins[pw].title, "Most used words")
    var lines = win_text(app, pw).split("\n")
    assert_true(String(lines[0]).startswith("Word"), win_text(app, pw))
    assert_true(String(lines[2]).startswith("apple") and String(lines[2]).find("3") > 0, win_text(app, pw))
    assert_true(String(lines[3]).startswith("banana"), win_text(app, pw))
    assert_equal(app.wins[pw].row_marks[0], RM_DIM)        # the column titles
    assert_equal(app.wins[pw].row_marks[2], RM_OK)         # used 3 times: "ok"
    assert_equal(app.wins[pw].row_marks[3], RM_NONE)
    ei = app.find_editor(d + "/a.txt")
    assert_equal(app.wins[ei].x + app.wins[ei].w, app.wins[pw].x)      # beside the code
    app.draw()
    # Enter on a row: the plugin hears which
    app.focus(pw)
    pw = app.top()
    app.wins[pw].cr = 3
    app.handle(key_event(KEY_ENTER))
    for _ in range(100):
        pump(app, 50)
        if app.status.find("banana") >= 0:
            break
    assert_equal(app.status, "\"banana\" is used 2 times")
    # a save refreshes it
    ei = app.find_editor(d + "/a.txt")
    app.focus(ei)
    ei = app.top()
    app.wins[ei].buf.load(decode("banana banana banana banana apple\n"))
    app.wins[ei].buf.modified = True
    app.exec(CM_SAVE)
    for _ in range(100):
        pump(app, 50)
        if win_text(app, panel_win(app)).find("banana  4") >= 0:
            break
    assert_true(win_text(app, panel_win(app)).find("banana  4") >= 0, win_text(app, panel_win(app)))
    # the user closes it: gone, the editor has its room back
    app.focus(panel_win(app))
    app.exec(CM_CLOSE)
    pump(app, 100)
    assert_equal(panel_win(app), -1)
    assert_equal(len(app.panels), 0)
    assert_equal(app.wins[app.find_editor(d + "/a.txt")].w, full)
    # opened again, then the plugin dies: the panel goes with it
    app.exec(command_id(app, "plugin.wordcount.words"))
    for _ in range(100):
        pump(app, 50)
        if panel_win(app) >= 0:
            break
    assert_true(panel_win(app) >= 0)
    _ = app.plugins[0].conn.stop()
    pump(app, 200)
    assert_equal(panel_win(app), -1)
    assert_equal(len(app.panels), 0)
    assert_equal(app.wins[app.find_editor(d + "/a.txt")].w, full)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
