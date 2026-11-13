"""Tests for navigation memory, first part (P10-17a): the commands chosen last - in
the command palette or a menu - come first in the palette, also after a restart; F6
goes to the window used last and, pressed again in a row, further back (the order as
it was when the presses began), Shift-F6 back along it; Shift-F6 on its own goes to
the window used least lately."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import *
from appstate import App, M_DIALOG, M_NORMAL
from commands import CM_ABOUT, CM_ZOOM, CM_NEW
from frecency import Frecency
from config import read_text
from term import key_event, fkey, KEY_ENTER, KEY_RIGHT, MOD_SHIFT
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-nav-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    for name in ["a", "b", "c"]:
        _ = write_file(d + "/" + name + ".mojo", str_bytes("text of " + name + "\n"))
    return d


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.cmd_rec_path = d + "/state/commands-used"
    return app^


def first_commands(mut app: App, n: Int) raises -> List[Int]:
    """The commands the palette lists first when nothing is typed."""
    app.quick_dialog(">")
    var out = List[Int]()
    for k in range(min(n, len(app.dlg.shown))):
        out.append(app.dlg.item_data[app.dlg.shown[k]])
    app.handle(key_event(27))
    return out^


def test_recent_commands_first() raises:
    var d = scratch("pal")
    var app = ide(d)
    var before = first_commands(app, 3)
    assert_true(before[0] != CM_ZOOM)
    # Zoom chosen in the palette
    app.quick_dialog(">")
    for c in "zoom".codepoints():
        app.handle(key_event(Int(c)))
    assert_equal(app.dlg.item_data[app.dlg.shown[app.dlg.list_sel]], CM_ZOOM)
    app.handle(key_event(KEY_ENTER))
    assert_equal(first_commands(app, 1)[0], CM_ZOOM)
    # New from the File menu: it comes first now, Zoom second
    var fm = -1
    for i in range(len(app.menus)):
        if app.menus[i].title == "~F~ile":
            fm = i
    app.open_menu(fm)
    assert_equal(app.menus[fm].items[app.menu_item].cmd, CM_NEW)
    app.handle(key_event(KEY_ENTER))
    var now = first_commands(app, 2)
    assert_equal(now[0], CM_NEW)
    assert_equal(now[1], CM_ZOOM)
    # a key does not count (only choosing by name)
    app.handle(key_event(fkey(5)))
    assert_equal(first_commands(app, 1)[0], CM_NEW)
    # kept across a restart
    var saved = read_text(d + "/state/commands-used")
    assert_true(saved.find("file.new") >= 0 and saved.find("window.zoom") > saved.find("file.new"), saved)
    var again = ide(d)
    again.cmd_rec.decode_text(saved, False)
    var after = first_commands(again, 2)
    assert_equal(after[0], CM_NEW)
    assert_equal(after[1], CM_ZOOM)
    # typing still decides: a command that does not match is not listed
    again.quick_dialog(">about")
    var listed = List[Int]()
    for k in again.dlg.shown:
        listed.append(again.dlg.item_data[k])
    assert_true(CM_ABOUT in listed and not (CM_NEW in listed))
    again.handle(key_event(27))
    _ = run_system("rm -rf " + shell_quote(d))


def front(app: App) -> String:
    return app.wins[app.top()].title


def test_f6_goes_to_the_window_used_last() raises:
    var d = scratch("f6")
    var app = ide(d)
    app.open_path(d + "/a.mojo")
    app.open_path(d + "/b.mojo")
    app.open_path(d + "/c.mojo")
    assert_equal(front(app), "c.mojo")
    var f6 = key_event(fkey(6))
    var sf6 = key_event(fkey(6) | MOD_SHIFT)
    app.handle(f6)
    assert_equal(front(app), "b.mojo")              # the one used last
    app.handle(f6)
    assert_equal(front(app), "a.mojo")              # pressed again: further back
    app.handle(sf6)
    assert_equal(front(app), "b.mojo")              # Shift-F6 back along the chain
    app.handle(f6)
    app.handle(f6)
    assert_equal(front(app), "c.mojo")              # round
    # another key ends the chain; F6 then toggles between the two used last
    app.handle(f6)                                  # (b, from c)
    app.handle(key_event(KEY_RIGHT))
    app.handle(f6)
    assert_equal(front(app), "c.mojo")
    app.handle(key_event(KEY_RIGHT))
    app.handle(f6)
    assert_equal(front(app), "b.mojo")
    # Shift-F6 on its own: the window used least lately
    app.handle(key_event(KEY_RIGHT))
    app.handle(sf6)
    assert_equal(front(app), "a.mojo")
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
