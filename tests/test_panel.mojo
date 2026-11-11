"""The bottom panel: its pages (Message, Search, Problems) keep their own content, are
switched by keys, commands and mouse, and the panel can be made higher and lower."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from term import Event, EV_MOUSE, MB_LEFT, wait_readable, alt, fkey, key_event, MOD_ALT, KEY_LEFT, KEY_RIGHT, KEY_ENTER, KEY_PGDN, KEY_DOWN
from app import *
from appstate import App, now_ns, M_NORMAL, PG_MESSAGE, PG_SEARCH, PG_PROBLEMS
from lsp import *
from search import make_search
from window import WK_EDITOR, WK_MESSAGE
from commands import (
    CM_MESSAGE, CM_SEARCHRES, CM_PROBLEMS, CM_LSP, CM_NEXTERR, CM_PANE_GROW, CM_PANE_SHRINK, CM_NEXT_TAB,
    CM_PREV_TAB, CM_TILED, CM_OUTLINE, CM_CLOSE,
)
from signals import own_pid
from util import decode, to_str, cp_len, env_or, run_system

comptime FAKE = "python3 tests/helpers/fake_rpc_server.py"
comptime MS = 1000000


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-panel-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def panel_app(dir: String) raises -> App:
    with open(dir + "/a.mojo", "w") as f:
        f.write("first needle\nx = BUG\nlast needle\n")
    with open(dir + "/b.mojo", "w") as f:
        f.write("needle in b\n")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(dir + "/a.mojo")
    return app^


def panel(app: App) -> String:
    """The panel's lines joined with " | "."""
    var mi = app.msg_index()
    if mi < 0:
        return "(closed)"
    var s = String("")
    for r in range(app.wins[mi].buf.count()):
        if r > 0:
            s += " | "
        s += to_str(app.wins[mi].buf.line(r))
    return s


def search_for(mut app: App, word: String):
    app.start_file_search(make_search(decode(word), True, False, False))
    var guard = 0
    while app.fsearch.active and guard < 1000:
        guard += 1
        app.fsearch_tick(now_ns() + guard * 1000000000)


def lsp_ticks(mut app: App, ms: Int):
    var deadline = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        if app.lsp.fd() >= 0:
            fds.append(app.lsp.fd())
        _ = wait_readable(fds, 20)
        app.lsp_tick(now_ns())


def at(app: App) -> String:
    var t = app.top()
    return app.wins[t].title + ":" + String(app.wins[t].cr) + ":" + String(app.wins[t].cc)


def test_pages_keep_their_own_content() raises:
    var dir = scratch("p1")
    var app = panel_app(dir)
    search_for(app, "needle")
    assert_equal(app.msg_page, PG_SEARCH)
    var found = panel(app)
    assert_true(found.find("a.mojo:1:7: first needle | a.mojo:3:6: last needle | b.mojo:1:1: needle in b") > 0, found)
    assert_equal(len(app.errs), 3)
    # problems are reported while the search results show: they stay in front,
    # the Problems page is filled behind them
    app.focus(app.find_editor(dir + "/a.mojo"))
    app.lsp_server = FAKE
    app.exec(CM_LSP)
    lsp_ticks(app, 1500)
    assert_equal(app.msg_page, PG_SEARCH)
    assert_equal(panel(app), found)
    assert_equal(len(app.errs), 3)
    # Right in the panel: the next page
    app.focus(app.msg_index())
    app.handle(key_event(KEY_RIGHT))
    assert_equal(app.msg_page, PG_PROBLEMS)
    assert_true(panel(app).find("a.mojo:2:5: error: found BUG") > 0, panel(app))
    assert_equal(len(app.errs), 1)
    # Enter there goes to the problem (row 0 says what the page is, row 1 its filter)
    app.wins[app.top()].cr = 2
    app.handle(key_event(KEY_ENTER))
    assert_equal(at(app), "a.mojo:1:4")
    # back to the search results: untouched, and their places work
    app.exec(CM_SEARCHRES)
    assert_equal(app.wins[app.top()].kind, WK_MESSAGE)
    assert_equal(panel(app), found)
    assert_equal(len(app.errs), 3)
    app.wins[app.top()].cr = 3
    app.handle(key_event(KEY_ENTER))
    assert_equal(at(app), "b.mojo:0:6")                  # the hit is selected: the cursor is at its end
    # Next message steps through the list of the page that shows
    app.exec(CM_NEXTERR)
    assert_equal(at(app), "a.mojo:0:12")                 # round to the first hit
    app.exec(CM_PROBLEMS)
    app.exec(CM_NEXTERR)
    assert_equal(at(app), "a.mojo:1:4")
    # the Message page has had nothing yet, and says so
    app.exec(CM_MESSAGE)
    assert_equal(app.msg_page, PG_MESSAGE)
    assert_equal(panel(app), "No compiler or program output yet")
    assert_equal(len(app.errs), 0)
    app.handle(key_event(KEY_LEFT))                      # round to the last page
    assert_equal(app.msg_page, PG_PROBLEMS)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_problems_come_to_the_front_unless_another_page_was_chosen() raises:
    var dir = scratch("p2")
    var app = panel_app(dir)
    app.lsp_server = FAKE
    app.exec(CM_LSP)
    lsp_ticks(app, 1500)
    assert_equal(app.msg_page, PG_PROBLEMS)              # nothing else was asked for: they show
    assert_true(panel(app).find("found BUG") > 0)
    # the user turns to another page: a new report does not take the panel back
    app.exec(CM_MESSAGE)
    var i = app.find_editor(dir + "/a.mojo")
    app.focus(i)
    i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(0, 0)
    for c in decode("WARN "):
        app.handle(key_event(c))
    lsp_ticks(app, 1500)
    assert_equal(app.msg_page, PG_MESSAGE)
    app.exec(CM_PROBLEMS)
    assert_true(panel(app).find("warning: found WARN") > 0, panel(app))      # but it was taken in
    assert_equal(len(app.errs), 2)
    # with the Problems page showing, reports keep it up to date
    app.focus(app.find_editor(dir + "/a.mojo"))
    i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(0, 0)
    for _ in range(5):
        app.exec(CM_DEL_CHAR)
    lsp_ticks(app, 1500)
    assert_equal(app.msg_page, PG_PROBLEMS)
    assert_true(panel(app).find("found WARN") < 0, panel(app))
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_tabs_in_the_border_mouse_and_keys() raises:
    var dir = scratch("p3")
    var app = panel_app(dir)
    search_for(app, "needle")
    app.draw()
    var mi = app.msg_index()
    var y = app.wins[mi].y
    var top = to_str(app.scr.row_text(y))
    assert_true(top.find(" Message │ Search │ Problems ") > 0, top)
    var col_s = cp_len(String(top[byte=0:top.find("Search")]))
    var col_p = cp_len(String(top[byte=0:top.find("Problems")]))
    assert_true(app.scr.bg_at(col_s, y) != app.pal.msg_bg, "the page that shows is picked out")
    assert_equal(app.scr.bg_at(col_p, y), app.pal.msg_bg)
    # a click on a tab turns to that page and gives the panel the keyboard
    app.handle(Event(EV_MOUSE, 0, col_p + 2, y, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, col_p + 2, y, MB_LEFT, False, False, List[Int]()))
    assert_equal(app.msg_page, PG_PROBLEMS)
    assert_equal(app.wins[app.top()].kind, WK_MESSAGE)
    assert_true(panel(app).find("No problems reported (F7 starts the language server)") > 0, panel(app))
    app.draw()
    assert_true(app.scr.bg_at(col_p, y) != app.pal.msg_bg)
    # the tab keys work in the panel too
    app.handle(key_event(KEY_PGDN | MOD_ALT))
    assert_equal(app.msg_page, PG_MESSAGE)
    app.exec(CM_PREV_TAB)
    app.exec(CM_PREV_TAB)
    assert_equal(app.msg_page, PG_SEARCH)
    assert_true(panel(app).find("needle") > 0)
    _ = run_system("rm -rf '" + dir + "'")


def test_closing_and_reopening_keeps_the_page() raises:
    var dir = scratch("p4")
    var app = panel_app(dir)
    search_for(app, "needle")
    var found = panel(app)
    app.focus(app.msg_index())
    app.wins[app.top()].cr = 2
    app.exec(CM_CLOSE)
    assert_equal(app.msg_index(), -1)
    app.exec(CM_SEARCHRES)
    assert_equal(panel(app), found)
    assert_equal(app.wins[app.msg_index()].cr, 2)
    assert_equal(len(app.errs), 3)
    app.handle(key_event(KEY_ENTER))
    assert_equal(at(app), "a.mojo:2:11")                 # the second hit, where the mark was
    _ = run_system("rm -rf '" + dir + "'")


def test_the_panels_can_be_resized() raises:
    var dir = scratch("p5")
    var app = panel_app(dir)
    app.exec(CM_TILED)
    app.exec(CM_MESSAGE)
    var mi = app.msg_index()
    var h0 = app.wins[mi].h
    assert_equal(app.wins[mi].y + h0, 29)                # down to the status line
    app.exec(CM_PANE_GROW)
    app.layout_sync()
    mi = app.msg_index()
    assert_equal(app.wins[mi].h, h0 + 2)
    assert_equal(app.wins[mi].y + app.wins[mi].h, 29)
    # the panes above give the room
    var ei = app.find_editor(dir + "/a.mojo")
    assert_equal(app.wins[ei].y + app.wins[ei].h, app.wins[mi].y)
    for _ in range(40):
        app.exec(CM_PANE_GROW)
    mi = app.msg_index()
    assert_equal(app.wins[mi].h, 22)                     # six rows are left for the files
    assert_equal(app.status, "The panel cannot be made higher")
    for _ in range(40):
        app.exec(CM_PANE_SHRINK)
    mi = app.msg_index()
    assert_equal(app.wins[mi].h, 4)
    assert_equal(app.wins[mi].y + app.wins[mi].h, 29)
    # the Outline window: wider and narrower
    app.focus(app.find_editor(dir + "/a.mojo"))
    app.exec(CM_OUTLINE)
    var oi = app.outline_index()
    var w0 = app.wins[oi].w
    app.focus(oi)
    app.exec(CM_PANE_GROW)
    app.layout_sync()
    oi = app.outline_index()
    assert_equal(app.wins[oi].w, w0 + 4)
    assert_equal(app.wins[oi].x + app.wins[oi].w, 100)
    ei = app.find_editor(dir + "/a.mojo")
    assert_equal(app.wins[ei].x + app.wins[ei].w, app.wins[oi].x)
    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
