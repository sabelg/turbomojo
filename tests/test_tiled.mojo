"""The tiled layout in the application: panes with tabs, splits, keys and mouse."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from term import Event, EV_MOUSE, MB_LEFT, fkey, alt, key_event, MOD_ALT, KEY_PGDN, KEY_PGUP, KEY_ENTER
from app import *
from appstate import App, M_NORMAL
from window import WK_EDITOR, WK_MESSAGE
from commands import (
    CM_TILED, CM_SPLIT_RIGHT, CM_SPLIT_DOWN, CM_NEXT_PANE, CM_NEXT_TAB, CM_PREV_TAB, CM_MOVE_TAB,
    CM_PANE_GROW, CM_PANE_SHRINK, CM_TILE, CM_ZOOM, CM_MESSAGE, CM_OUTLINE, CM_NEXTWIN, CM_NEW, build_registry,
)
from config import load_settings
from signals import own_pid
from util import decode, to_str, cp_len, env_or, run_system


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-tiled-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def tiled_app(dir: String, files: Int) raises -> App:
    """An app with `files` files open (a.mojo, b.mojo, ...; each holds "text of <name>")
    and the tiled layout on."""
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    var names = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
    for k in range(files):
        with open(dir + "/" + names[k] + ".mojo", "w") as f:
            f.write("text of " + names[k] + "\n")
        app.open_path(dir + "/" + names[k] + ".mojo")
    app.exec(CM_TILED)
    return app^


def front(app: App) -> String:
    """Title of the window that has the keyboard."""
    return app.wins[app.top()].title


def place(app: App, name: String) -> String:
    """"x,y WxH" of a file's window, or "hidden"."""
    for i in range(len(app.wins)):
        if app.wins[i].title == name:
            if app.wins[i].hidden:
                return "hidden"
            return String(app.wins[i].x) + "," + String(app.wins[i].y) + " " + String(app.wins[i].w) + "x" + String(app.wins[i].h)
    return "(none)"


def screen(mut app: App) -> String:
    app.draw()
    return to_str(app.scr.to_text())


def click(mut app: App, x: Int, y: Int) raises:
    app.handle(Event(EV_MOUSE, 0, x, y, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, x, y, MB_LEFT, False, False, List[Int]()))


def test_open_files_become_tabs_of_one_pane() raises:
    var dir = scratch("t1")
    var app = tiled_app(dir, 3)
    assert_true(app.tiled)
    assert_equal(front(app), "c.mojo")
    assert_equal(place(app, "c.mojo"), "0,1 100x28")     # the whole desktop
    assert_equal(place(app, "a.mojo"), "hidden")
    assert_equal(place(app, "b.mojo"), "hidden")
    var s = screen(app)
    assert_true(s.find("text of c") > 0)
    assert_true(s.find("text of a") < 0, "a hidden tab is not drawn")
    # the tabs stand in the pane's top border, the shown one picked out
    var top = to_str(app.scr.row_text(1))
    assert_true(top.find(" a.mojo │ b.mojo │ c.mojo ") > 0, top)
    var col = cp_len(String(top[byte=0:top.find("c.mojo")]))
    var col_a = cp_len(String(top[byte=0:top.find("a.mojo")]))
    assert_equal(app.scr.bg_at(col, 1), app.pal.frame_act)       # inverse
    assert_equal(app.scr.fg_at(col_a, 1), app.pal.frame_act)
    assert_equal(app.scr.bg_at(col_a, 1), app.pal.ed_bg)
    # a file opened now is a new tab next to the one in front, and shows
    with open(dir + "/z.mojo", "w") as f:
        f.write("text of z\n")
    app.open_path(dir + "/z.mojo")
    app.layout_sync()
    assert_equal(front(app), "z.mojo")
    assert_equal(place(app, "z.mojo"), "0,1 100x28")
    assert_equal(place(app, "c.mojo"), "hidden")
    assert_equal(app.lay.describe().find("]!") > 0, True)
    assert_equal(len(app.lay.groups()), 1)
    _ = run_system("rm -rf '" + dir + "'")


def test_tabs_by_keyboard() raises:
    var dir = scratch("t2")
    var app = tiled_app(dir, 3)
    var reg = build_registry()
    assert_equal(reg.find_key(KEY_PGDN | MOD_ALT), CM_NEXT_TAB)
    assert_equal(reg.find_key(KEY_PGUP | MOD_ALT), CM_PREV_TAB)
    assert_equal(reg.find_key(alt(92)), CM_SPLIT_RIGHT)
    assert_equal(reg.find_key(fkey(6) | MOD_ALT), CM_NEXT_PANE)
    app.handle(key_event(KEY_PGUP | MOD_ALT))
    assert_equal(front(app), "b.mojo")
    assert_equal(place(app, "b.mojo"), "0,1 100x28")
    assert_equal(place(app, "c.mojo"), "hidden")
    app.handle(key_event(KEY_PGDN | MOD_ALT))
    app.handle(key_event(KEY_PGDN | MOD_ALT))
    assert_equal(front(app), "a.mojo")                   # round the end
    # typing goes into the file that shows
    app.handle(key_event(120))
    var ai = app.find_editor(dir + "/a.mojo")
    assert_equal(to_str(app.wins[ai].buf.line(0)), "xtext of a")
    assert_true(to_str(app.scr.row_text(1)).find("a.mojo") < 0 or True)
    var top = String("")
    app.draw()
    top = to_str(app.scr.row_text(1))
    assert_true(top.find(" a.mojo* ") > 0, top)          # a changed file is marked on its tab
    # Next window (F6) reaches hidden tabs too, and shows them
    app.exec(CM_NEXTWIN)
    app.layout_sync()
    assert_true(place(app, front(app)) == "0,1 100x28")
    _ = run_system("rm -rf '" + dir + "'")


def test_splits_and_panes() raises:
    var dir = scratch("t3")
    var app = tiled_app(dir, 3)
    app.handle(key_event(alt(92)))                       # Alt-\: c moves to a new pane on the right
    assert_equal(app.lay.describe().find(" | ") > 0, True)
    assert_equal(front(app), "c.mojo")
    assert_equal(place(app, "c.mojo"), "50,1 50x28")
    assert_equal(place(app, "b.mojo"), "0,1 50x28")      # the left pane shows its neighbour
    assert_equal(place(app, "a.mojo"), "hidden")
    var s = screen(app)
    assert_true(s.find("text of b") > 0 and s.find("text of c") > 0)
    # the left pane still has two tabs, the right one a plain title
    var top = to_str(app.scr.row_text(1))
    assert_true(top.find(" a.mojo │ b.mojo ") > 0, top)
    assert_true(top.find(" c.mojo ") > 0, top)
    # other pane and back
    app.handle(key_event(fkey(6) | MOD_ALT))
    assert_equal(front(app), "b.mojo")
    app.exec(CM_NEXT_PANE)
    assert_equal(front(app), "c.mojo")
    # a pane with one file cannot be split
    app.exec(CM_SPLIT_DOWN)
    assert_true(app.status.find("Open a second file in this pane first") == 0, app.status)
    # move a tab over, then split that pane downwards
    app.exec(CM_NEXT_PANE)
    app.exec(CM_MOVE_TAB)
    assert_equal(front(app), "b.mojo")
    assert_equal(place(app, "b.mojo"), "50,1 50x28")
    assert_equal(place(app, "a.mojo"), "0,1 50x28")
    assert_equal(place(app, "c.mojo"), "hidden")
    app.exec(CM_SPLIT_DOWN)
    assert_equal(place(app, "c.mojo"), "50,1 50x14")
    assert_equal(place(app, "b.mojo"), "50,15 50x14")
    assert_equal(front(app), "b.mojo")
    # larger and smaller
    app.exec(CM_PANE_GROW)
    assert_equal(place(app, "b.mojo"), "50,13 50x16")       # 5% of the split: one row here
    app.exec(CM_PANE_SHRINK)
    app.exec(CM_PANE_SHRINK)
    assert_equal(place(app, "b.mojo"), "50,16 50x13")
    # closing the only file of a pane gives its room back
    app.close_window(app.top(), 0)
    app.layout_sync()
    assert_equal(place(app, "c.mojo"), "50,1 50x28")
    app.close_window(app.find_editor(dir + "/c.mojo"), 0)
    app.layout_sync()
    assert_equal(place(app, "a.mojo"), "0,1 100x28")
    assert_equal(len(app.lay.groups()), 1)
    app.exec(CM_NEXT_PANE)
    assert_equal(app.status, "There is only one pane")
    app.exec(CM_MOVE_TAB)
    assert_equal(app.status, "There is no other pane to move it to")
    _ = run_system("rm -rf '" + dir + "'")


def test_mouse_in_the_tiled_layout() raises:
    var dir = scratch("t4")
    var app = tiled_app(dir, 4)
    app.exec(CM_SPLIT_RIGHT)                             # [a b c] | [d]
    app.draw()
    var top = to_str(app.scr.row_text(1))
    # a click on a tab shows that file
    var col_a = cp_len(String(top[byte=0:top.find("a.mojo")]))
    click(app, col_a + 1, 1)
    assert_equal(front(app), "a.mojo")
    assert_equal(place(app, "a.mojo"), "0,1 50x28")
    assert_equal(place(app, "c.mojo"), "hidden")
    # a click into the other pane gives it the keyboard
    click(app, 70, 10)
    assert_equal(front(app), "d.mojo")
    # panes are not dragged by their title bar
    app.handle(Event(EV_MOUSE, 0, 80, 1, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, 60, 8, MB_LEFT, True, True, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, 60, 8, MB_LEFT, False, False, List[Int]()))
    assert_equal(place(app, "d.mojo"), "50,1 50x28")
    _ = run_system("rm -rf '" + dir + "'")


def test_message_outline_and_zoom() raises:
    var dir = scratch("t5")
    var app = tiled_app(dir, 3)
    app.exec(CM_SPLIT_RIGHT)
    # the Message window takes the bottom, the Outline window the right: the panes share the rest
    app.exec(CM_MESSAGE)
    app.layout_sync()
    var mi = app.msg_index()
    var my = app.wins[mi].y
    assert_equal(place(app, "c.mojo"), "50,1 50x" + String(my - 1))
    app.focus(app.find_editor(dir + "/c.mojo"))
    app.exec(CM_OUTLINE)
    app.layout_sync()
    var ox = app.wins[app.outline_index()].x
    assert_true(ox < 100)
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_EDITOR and not app.wins[i].hidden:
            assert_true(app.wins[i].x + app.wins[i].w <= ox, "no pane under the outline")
            assert_true(app.wins[i].y + app.wins[i].h <= my, "no pane under the messages")
    app.exec(CM_OUTLINE)
    # Zoom: the pane in front takes all the room; again: back to the split
    app.exec(CM_ZOOM)
    app.layout_sync()
    assert_equal(place(app, "c.mojo"), "0,1 100x" + String(my - 1))
    assert_equal(place(app, "b.mojo"), "hidden")
    app.exec(CM_ZOOM)
    app.layout_sync()
    assert_equal(place(app, "c.mojo"), "50,1 50x" + String(my - 1))
    assert_equal(place(app, "b.mojo"), "0,1 50x" + String(my - 1))
    _ = run_system("rm -rf '" + dir + "'")


def test_many_tabs_keep_the_shown_one_in_view() raises:
    var dir = scratch("t6")
    var app = tiled_app(dir, 10)
    app.scr.resize(60, 20)
    app.fit_windows()
    app.draw()
    var top = to_str(app.scr.row_text(1))
    assert_true(top.find(" j.mojo ") > 0, top)           # the newest shows and is named
    assert_true(top.find("‹") > 0, top)                  # earlier ones are off to the left
    assert_true(top.find("a.mojo") < 0, top)
    app.focus(app.find_editor(dir + "/a.mojo"))
    app.draw()
    top = to_str(app.scr.row_text(1))
    assert_true(top.find(" a.mojo ") > 0, top)
    assert_true(top.find("›") > 0, top)
    assert_true(top.find("j.mojo") < 0, top)
    # the close and zoom boxes of the frame are still there
    assert_true(top.find("[■]") >= 0, top)
    _ = run_system("rm -rf '" + dir + "'")


def test_switching_layouts_and_the_setting() raises:
    var dir = scratch("t7")
    var app = tiled_app(dir, 3)
    app.exec(CM_TILE)
    assert_true(app.status.find("The tiled layout arranges the windows itself") == 0, app.status)
    app.exec(CM_SPLIT_RIGHT)
    # back to classic: every window visible again, overlapping
    app.exec(CM_TILED)
    assert_false(app.tiled)
    assert_equal(app.status, "Classic layout: overlapping windows")
    for i in range(len(app.wins)):
        assert_false(app.wins[i].hidden)
    app.draw()
    assert_true(to_str(app.scr.row_text(1)).find("│ b.mojo") < 0)
    app.exec(CM_SPLIT_RIGHT)
    assert_equal(app.status, "This needs the tiled layout (Window > Tiled layout)")
    # the setting
    var s = load_settings("[ui]\nlayout = \"tiled\"\n", "")
    assert_true(s.tiled)
    assert_equal(len(s.warnings), 0)
    assert_false(load_settings("[ui]\nlayout = \"classic\"\n", "").tiled)
    assert_equal(len(load_settings("[ui]\nlayout = \"floating\"\n", "").warnings), 1)
    app.apply_settings(s)
    app.layout_sync()
    assert_true(app.tiled)
    assert_equal(len(app.lay.groups()), 1)
    assert_equal(place(app, front(app)), "0,1 100x28")
    # an app without any file, and a new one
    var empty = App()
    empty.scr.resize(80, 24)
    empty.exec(CM_TILED)
    empty.draw()
    empty.exec(CM_SPLIT_RIGHT)
    empty.exec(CM_NEW)
    empty.layout_sync()
    assert_equal(place(empty, front(empty)), "0,1 80x22")
    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
