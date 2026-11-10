"""Headless rendering tests: draw UI pieces into a Screen and compare with golden text.

Golden files live in tests/golden/. To regenerate after an intended visual change:
    UPDATE_GOLDEN=1 pixi run mojo run -I src tests/test_screen.mojo
and review the diff before committing."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from screen import Screen, CONT
from palette import Palette, theme
from highlight import Highlighter
from menu import build_menus, draw_menubar, draw_dropdown
from commands import build_registry, CM_LINENUM
from dialog import Dialog, Field, D_FIND, D_INFO
from window import Window, WK_EDITOR, WK_MESSAGE
from window_search import *
from window_draw import *
from util import decode, to_str, env_or, path_exists, bytes_to_str, str_bytes, cp_len


def check_golden(name: String, scr: Screen) raises:
    var path = "tests/golden/" + name + ".txt"
    var got = to_str(scr.to_text())
    if env_or("UPDATE_GOLDEN", "") == "1":
        with open(path, "w") as f:
            f.write(got)
        return
    assert_true(path_exists(path), "missing golden file " + path)
    var want: String
    with open(path, "r") as f:
        want = f.read()
    assert_equal(got, want)


def row(scr: Screen, y: Int) -> String:
    return to_str(scr.row_text(y))


# --------------------------------------------------------------- primitives
def test_text_and_fill() raises:
    var s = Screen(10, 2)
    s.fill(0, 0, 10, 2, 46, 1, 2)
    _ = s.text(2, 0, "hi", 7, 8)
    assert_equal(row(s, 0), "..hi......")
    assert_equal(s.fg_at(2, 0), 7)
    assert_equal(s.bg_at(3, 0), 8)
    assert_equal(s.fg_at(4, 0), 1)


def test_clip_limits_drawing() raises:
    var s = Screen(10, 1)
    s.clip(2, 0, 3, 1)
    _ = s.text(0, 0, "abcdefgh", 1, 2)
    s.no_clip()
    assert_equal(row(s, 0), "  cde")


def test_out_of_bounds_put_is_ignored() raises:
    var s = Screen(4, 2)
    s.put(-1, 0, 65, 1, 2)
    s.put(4, 0, 65, 1, 2)
    s.put(0, 2, 65, 1, 2)
    s.put(0, -1, 65, 1, 2)
    assert_equal(row(s, 0), "")
    assert_equal(row(s, 1), "")


def test_wide_char_takes_two_cells() raises:
    var s = Screen(8, 1)
    var x = s.text(0, 0, "a日b", 1, 2)
    assert_equal(x, 4)
    assert_equal(s.ch[1], 0x65E5)
    assert_equal(s.ch[2], CONT)
    assert_equal(s.ch[3], 98)
    assert_equal(row(s, 0), "a日b")


def test_overwriting_half_of_wide_char_clears_the_other_half() raises:
    var s = Screen(8, 1)
    _ = s.text(0, 0, "日本", 1, 2)
    s.put(1, 0, 88, 1, 2)       # write on the right half of 日
    assert_equal(s.ch[0], 32)   # left half must not remain as a broken wide char
    assert_equal(s.ch[1], 88)
    s.put(2, 0, 89, 1, 2)       # write on the left half of 本
    assert_equal(s.ch[3], 32)
    assert_equal(row(s, 0), " XY")


def test_wide_char_at_clip_edge_becomes_ellipsis() raises:
    var s = Screen(4, 1)
    s.clip(0, 0, 3, 1)
    _ = s.text(0, 0, "ab日", 1, 2)
    s.no_clip()
    assert_equal(s.ch[2], 0x2026)
    assert_equal(s.ch[3], 32)   # nothing leaked past the clip


def test_combining_mark_attaches_to_previous_cell() raises:
    var s = Screen(8, 1)
    var x = s.text(0, 0, "café!", 1, 2)
    assert_equal(x, 5)          # the accent takes no column
    assert_equal(s.cmb[3], 0x301)
    assert_equal(s.ch[4], 33)
    assert_equal(row(s, 0), "café!")


def test_hot_text_toggles_colour_and_skips_tildes() raises:
    var s = Screen(10, 1)
    var x = s.hot_text(0, 0, "~F~ile", 1, 9, 2)
    assert_equal(x, 4)
    assert_equal(row(s, 0), "File")
    assert_equal(s.fg_at(0, 0), 9)
    assert_equal(s.fg_at(1, 0), 1)


def test_frame_corners() raises:
    var s = Screen(6, 3)
    s.frame(0, 0, 6, 3, True, 1, 2)
    assert_equal(row(s, 0), "╔════╗")
    assert_equal(row(s, 1), "║    ║")
    assert_equal(row(s, 2), "╚════╝")
    s.frame(0, 0, 6, 3, False, 1, 2)
    assert_equal(row(s, 0), "┌────┐")


def test_shadow_recolours_without_changing_text() raises:
    var s = Screen(8, 4)
    s.fill(0, 0, 8, 4, 35, 5, 6)
    s.shadow(1, 0, 3, 2, 0x555555, 0)
    # two columns to the right of the box, one row down
    assert_equal(s.bg_at(4, 1), 0)
    assert_equal(s.bg_at(5, 2), 0)
    # one row below, shifted two columns
    assert_equal(s.bg_at(3, 2), 0)
    assert_equal(s.bg_at(1, 2), 6)   # not under the left edge
    assert_equal(s.bg_at(4, 0), 6)   # not beside the top row
    assert_equal(row(s, 1), "########")


def test_render_emits_only_changes_second_time() raises:
    var s = Screen(20, 3)
    _ = s.text(0, 0, "hello", 0xFFFFFF, 0)
    var a = List[UInt8]()
    s.render(a)
    var b = List[UInt8]()
    s.render(b)
    assert_true(len(b) < len(a) // 4, "second render should be nearly empty")
    s.put(0, 0, 72, 0xFFFFFF, 0)
    var c = List[UInt8]()
    s.render(c)
    assert_true(str_contains_bytes(c, "H"))
    assert_false(str_contains_bytes(c, "ello"))


def str_contains_bytes(b: List[UInt8], needle: String) -> Bool:
    return bytes_to_str(b).find(needle) >= 0


# ---------------------------------------------------------------- UI pieces
def test_menubar_golden() raises:
    var s = Screen(80, 3)
    var p = theme(0)
    s.fill(0, 0, 80, 3, 32, 0, 0)
    draw_menubar(s, p, build_menus(build_registry()), 2, "12:34")
    assert_true(row(s, 0).startswith("  ≡  File  Edit  Text  Search  Run  Compile  Options  Window  Help"), row(s, 0))
    assert_true(row(s, 0).endswith("12:34"))
    # the open menu (Edit, index 2) is highlighted, its neighbours are not
    var menus = build_menus(build_registry())
    assert_equal(s.bg_at(menus[2].x + 1, 0), p.menu_sel_bg)
    assert_equal(s.bg_at(menus[1].x + 1, 0), p.menu_bg)
    assert_equal(s.fg_at(menus[1].x + 1, 0), p.menu_hot)   # hot letter of File
    check_golden("menubar", s)


def test_clock_is_hidden_when_it_would_cover_a_menu() raises:
    var p = theme(0)
    var narrow = Screen(70, 1)
    narrow.fill(0, 0, 70, 1, 32, 0, 0)
    draw_menubar(narrow, p, build_menus(build_registry()), -1, "12:34")
    assert_true(row(narrow, 0).endswith("Help"), "Help must stay visible")
    var wide = Screen(76, 1)
    wide.fill(0, 0, 76, 1, 32, 0, 0)
    draw_menubar(wide, p, build_menus(build_registry()), -1, "12:34")
    assert_true(row(wide, 0).endswith("12:34"))
    assert_true(row(wide, 0).find("Help") > 0)


def test_dropdown_golden() raises:
    var s = Screen(60, 20)
    var p = theme(0)
    s.fill(0, 0, 60, 20, 32, 0, 0)
    var menus = build_menus(build_registry())
    var checks = List[Int]()
    checks.append(CM_LINENUM)
    draw_menubar(s, p, menus, 7, "")
    draw_dropdown(s, p, menus[7], 0, checks)
    # the check mark sits before the checked item
    var found = False
    for y in range(16):
        if row(s, y).find("│√Line numbers") >= 0:
            found = True
    assert_true(found, "checked option should show a check mark")
    check_golden("dropdown_options", s)


def test_dialog_golden() raises:
    var s = Screen(70, 16)
    var p = theme(0)
    s.fill(0, 0, 70, 16, 32, 0, 0)
    var d = Dialog(D_FIND, "Find", 56, 11)
    d.fields.append(Field("~T~ext to find", "日本 fib"))
    d.checks.append("~C~ase sensitive")
    d.check_vals.append(True)
    d.buttons.append("~O~K")
    d.buttons.append("~C~ancel")
    var cur = d.draw(s, p)
    # cursor sits after the text: field x + 1 + width("日本 fib") = 8 columns
    assert_equal(cur[0], d.field_x + 1 + 8)
    assert_equal(cur[1], d.field_y[0])
    assert_equal(d.button_at(d.btn_x[1] + 1, d.btn_y), 1)
    assert_equal(d.button_at(d.btn_x[0] - 1, d.btn_y), -1)
    check_golden("dialog_find", s)


def test_editor_window_golden() raises:
    var s = Screen(50, 10)
    var p = theme(0)
    s.fill(0, 0, 50, 10, 32, 0, 0)
    var w = Window(WK_EDITOR, "demo.mojo", "/x/demo.mojo", 0, 0, 50, 10, 1)
    w.buf.load(decode("def main():\n\tvar s = \"日本語 🔥 café\"\n    print(s)  # done\n"))
    w.gut = w.gutter_for(True)
    w.cr = 1
    w.cc = 1
    var h = Highlighter()
    w.draw(s, p, h, True, True, True, False)
    # every row must be exactly as wide as the window: the right border stays aligned
    for y in range(10):
        assert_equal(cp_len(row(s, y)), 50)
    assert_true(row(s, 0).find(" demo.mojo ") > 0)
    assert_true(row(s, 2).find("    var s = \"日本語 🔥 café\"") > 0, "tab shown as 4 columns")
    # cursor is at visual column 5 (after the tab), shown 1-based in the frame
    assert_true(row(s, 9).find(" 2:5 ") > 0)
    # syntax colours: `def` keyword vs the function name
    assert_equal(s.fg_at(1 + w.gut, 1), p.syn[1])
    assert_equal(s.bg_at(1 + w.gut, 2), p.curline_bg)   # current line highlight
    check_golden("editor_window", s)


def test_inactive_window_and_message_window_golden() raises:
    var s = Screen(50, 12)
    var p = theme(0)
    s.fill(0, 0, 50, 12, 32, 0, 0)
    var w = Window(WK_EDITOR, "a.mojo", "", 0, 0, 50, 6, 1)
    w.buf.load(decode("x = 1\n"))
    w.gut = w.gutter_for(False)
    var m = Window(WK_MESSAGE, "Message", "", 0, 6, 50, 6, 2)
    m.buf.load(decode("Building a.mojo ...\na.mojo:1:1: error: something is wrong\nnote: a hint"))
    m.cr = 1
    var h = Highlighter()
    w.draw(s, p, h, False, True, True, False)
    m.draw(s, p, h, True, True, True, False)
    assert_true(row(s, 0).startswith("┌"), "inactive window uses a single-line frame")
    assert_true(row(s, 6).startswith("╔"), "active window uses a double-line frame")
    assert_equal(s.bg_at(1, 8), p.msg_sel_bg)            # selected message row
    assert_equal(s.fg_at(1, 9), p.msg_note)              # note: line colour
    check_golden("two_windows", s)



def test_large_file_mode_draws_without_syntax_colours() raises:
    var p = theme(0)
    var h = Highlighter()
    var s = Screen(50, 5)
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 50, 5, 1)
    w.buf.load(decode("def f():\n    return 1\n"))
    w.sync_lex(5)
    w.draw(s, p, h, False, False, True, False)
    var coloured = s.fg_at(1, 1)
    assert_true(coloured != p.ed_fg, "keyword should be coloured normally")
    assert_true(len(w.buf.lstate) > 1)
    var s2 = Screen(50, 5)
    var w2 = Window(WK_EDITOR, "t.mojo", "", 0, 0, 50, 5, 1)
    w2.buf.load(decode("def f():\n    return 1\n"))
    w2.buf.large = True
    w2.sync_lex(5)
    w2.draw(s2, p, h, False, False, True, False)
    assert_equal(s2.fg_at(1, 1), p.ed_fg)
    assert_equal(len(w2.buf.lstate), 1)                       # no lexer work at all
    assert_equal(row(s2, 1), row(s, 1))                       # same text either way
    assert_true(row(s2, 0).find(" t.mojo (large file) ") > 0, "the frame says why colours are missing")
    assert_true(row(s, 0).find("large") < 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
