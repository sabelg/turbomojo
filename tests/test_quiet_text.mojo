"""Tests for muted and disabled text and for dimming while the terminal does not have
the focus (P10-12): the muted and disabled colours of every built-in theme stay above
their floors and below the text they go with; commands that can do nothing now are
drawn disabled in the menus, the command palette and the status line, the keys and
the file facts muted; the terminal's focus reports (mode 1004) are asked for, parsed,
dim the screen and bring it back, are not recorded in macros, and leaving or a crash
switches them off."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from contrast import *
from themes import ThemeSet
from palette import is_rgb
from term import Terminal, Event, EV_FOCUS, EV_KEY, key_event, KEY_DOWN
from crash import CRASH_RESTORE
from app import *
from appstate import App, M_MENU, M_DIALOG
from config import load_settings
from commands import CM_SAVE, CM_STEP_OVER, CM_UNDO, CM_OPEN, CM_NEXTERR, CM_MACRO_REC
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, to_str, cp_len


def lc(a: Int, b: Int) -> Float64:
    return abs(apca_lc(a, b))


def test_muted_and_disabled_colours() raises:
    var t = ThemeSet()
    var measured = 0
    for k in range(t.count()):
        var p = t.pals[k].copy()
        var surfaces: List[Tuple[Int, Int]] = [(p.menu_fg, p.menu_bg), (p.status_fg, p.status_bg), (p.list_fg, p.list_bg), (p.dlg_fg, p.dlg_bg)]
        for s in surfaces:
            var fg = s[0]
            var bg = s[1]
            if not is_rgb(fg) or not is_rgb(bg):
                continue
            var m = text_muted(fg, bg)
            var d = text_disabled(p, fg, bg)
            var who = t.ids[k] + " " + hex(fg) + " on " + hex(bg)
            assert_true(wcag_ratio(m, bg) >= 3.0 and lc(m, bg) >= 30.0, "muted below the floor: " + who)
            assert_true(lc(m, bg) <= lc(fg, bg) + 0.01, "muted brighter than the text: " + who)
            assert_true(lc(d, bg) >= 15.0, "disabled below the floor: " + who)
            assert_true(lc(d, bg) <= lc(fg, bg) + 0.01, "disabled brighter than the text: " + who)
            measured += 1
    assert_true(measured >= 20)
    # where there is room, muted is visibly quieter
    assert_true(text_muted(0xFFFFFF, 0x000000) != 0xFFFFFF)
    # colours that are not RGB stay (Terminal ANSI, Mono)
    assert_equal(text_muted(-2, 0x000000), -2)
    assert_equal(dimmed(0xFFFFFF, 0x000000), mix(0xFFFFFF, 0x000000, 55))


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-quiet-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    print(1)\n"))
    return d


def find(app: App, text: String) -> Tuple[Int, Int]:
    for y in range(app.scr.h):
        var row = to_str(app.scr.row_text(y))
        var at = row.find(text)
        if at >= 0:
            return (cp_len(String(row[byte=0:at])), y)
    return (-1, -1)


def fg_at(app: App, at: Tuple[Int, Int]) -> Int:
    return app.scr.fg[at[1] * app.scr.w + at[0]]


def test_what_cannot_be_used_now() raises:
    var d = scratch("avail")
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    assert_true(app.cmd_unavailable(CM_SAVE))           # no editor
    assert_true(app.cmd_unavailable(CM_STEP_OVER))      # nothing being debugged
    assert_true(app.cmd_unavailable(CM_NEXTERR))        # no messages
    assert_false(app.cmd_unavailable(CM_OPEN))
    app.open_path(d + "/a.mojo")
    assert_false(app.cmd_unavailable(CM_SAVE))
    assert_true(app.cmd_unavailable(CM_UNDO))           # nothing typed yet
    app.handle(key_event(120))
    assert_false(app.cmd_unavailable(CM_UNDO))
    _ = run_system("rm -rf " + shell_quote(d))


def test_menus_palette_and_status_line() raises:
    var d = scratch("draw")
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    var p = app.pal.copy()
    app.draw()
    # the status line: Save can do nothing without a file
    var save = find(app, "F2 Save")
    assert_true(save[1] == app.scr.h - 1)
    assert_equal(fg_at(app, save), text_disabled(p, p.status_fg, p.status_bg))
    var open = find(app, "F3 Open")
    assert_equal(fg_at(app, (open[0] + 3, open[1])), p.status_fg)
    # the File menu: Save disabled (no hot letter), Open's key muted
    var fm = -1
    for i in range(len(app.menus)):
        if app.menus[i].title == "~F~ile":
            fm = i
    app.open_menu(fm)
    app.draw()
    var s = find(app, "Save   ")
    assert_true(s[1] > 0, to_str(app.scr.to_text()))
    for x in range(s[0], s[0] + 4):
        assert_equal(app.scr.fg[s[1] * app.scr.w + x], p.menu_dis)
    var o = find(app, "Open...")
    var row = to_str(app.scr.row_text(o[1]))
    var key_at = cp_len(String(row[byte=0:row.find("F3")]))
    assert_equal(app.scr.fg[o[1] * app.scr.w + key_at], text_muted(p.menu_fg, p.menu_bg))
    assert_true(app.scr.fg[o[1] * app.scr.w + o[0] + 1] == p.menu_fg)
    app.handle(key_event(27))
    # the command palette: Save disabled, the keys muted
    app.quick_dialog(">")
    assert_equal(app.mode, M_DIALOG)
    app.handle(key_event(115))
    app.handle(key_event(97))
    app.handle(key_event(118))      # "sav"
    app.draw()
    var ps = find(app, "File: Save ")
    assert_true(ps[1] > 0, to_str(app.scr.to_text()))
    if app.dlg.list_sel == app.dlg.list_top + (ps[1] - app.dlg.list_y):
        app.handle(key_event(KEY_DOWN))         # (the selected row has the selection's colours)
        app.draw()
        ps = find(app, "File: Save ")
    assert_true(app.dlg.list_sel != app.dlg.list_top + (ps[1] - app.dlg.list_y))
    assert_equal(fg_at(app, ps), text_disabled(p, p.list_fg, p.list_bg))
    # an available command's keys, on a row that is not selected
    var checked = 0
    for i in range(app.dlg.list_h):
        var k = app.dlg.list_top + i
        if k >= len(app.dlg.shown) or k == app.dlg.list_sel:
            continue
        var it = app.dlg.shown[k]
        if app.dlg.off[it] or cp_len(app.dlg.items[it]) <= 41:
            continue
        var y = app.dlg.list_y + i
        var x0 = app.dlg.list_x + 1
        assert_equal(app.scr.fg[y * app.scr.w + x0], p.list_fg)
        assert_equal(app.scr.fg[y * app.scr.w + x0 + 40], text_muted(p.list_fg, p.list_bg), app.dlg.items[it])
        checked += 1
    assert_true(checked >= 1)
    app.handle(key_event(27))
    # the file facts on the status line are muted once a file is open
    app.open_path(d + "/a.mojo")
    app.status_until = 0                # (not the "Loaded" message)
    app.draw()
    var lf = find(app, "LF  Spaces")
    assert_true(lf[1] == app.scr.h - 1)
    assert_equal(fg_at(app, lf), text_muted(p.status_fg, p.status_bg))
    _ = run_system("rm -rf " + shell_quote(d))


def test_focus_reports() raises:
    var t = Terminal()
    var out = t.feed(str_bytes("\x1b[O"), False)
    assert_equal(len(out), 1)
    assert_equal(out[0].kind, EV_FOCUS)
    assert_equal(out[0].key, 0)
    var back = t.feed(str_bytes("\x1b[Ia"), False)
    assert_equal(len(back), 2)
    assert_equal(back[0].kind, EV_FOCUS)
    assert_equal(back[0].key, 1)
    assert_equal(back[1].kind, EV_KEY)
    # switched off on leaving and after a crash, before the alternate screen goes
    var r = t.restore_sequence()
    assert_true(r.find("\x1b[?1004l") > 0 and r.find("\x1b[?1004l") < r.find("\x1b[?1049l"))
    assert_true(String(CRASH_RESTORE).find("\x1b[?1004l") > 0)


def focus(on: Bool) -> Event:
    return Event(EV_FOCUS, 1 if on else 0, 0, 0, 0, False, False, List[Int]())


def test_dimmed_while_away() raises:
    var d = scratch("dim")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    app.draw()
    var at = find(app, "print(1)")
    var k = at[1] * app.scr.w + at[0]
    var fg = app.scr.fg[k]
    var bg = app.scr.bg[k]
    app.handle(focus(False))
    assert_false(app.focused)
    app.draw()
    assert_equal(app.scr.fg[k], dimmed(fg, bg))
    assert_true(app.scr.fg[k] != fg)
    app.handle(focus(True))
    app.draw()
    assert_equal(app.scr.fg[k], fg)
    # not in screen-reader mode, not when switched off
    app.apply_settings(load_settings("[ui]\ndim_unfocused = false\n", ""))
    app.handle(focus(False))
    app.draw()
    assert_equal(app.scr.fg[k], fg)
    # a macro being recorded does not get the focus changes
    app.apply_settings(load_settings("", ""))
    app.handle(focus(True))
    app.exec(CM_MACRO_REC)
    var n = len(app.macro)
    app.handle(focus(False))
    app.handle(focus(True))
    assert_equal(len(app.macro), n)
    app.exec(CM_MACRO_REC)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
