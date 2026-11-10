"""Mouse handling tests: synthetic mouse events sent through App.handle()."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import App, M_NORMAL, M_MENU, M_DIALOG
from term import Event, EV_MOUSE, MB_LEFT, MB_RIGHT, MB_WHEEL_UP, MB_WHEEL_DOWN
from menu import CM_NEW, CM_FIND, CM_PALETTE, CM_MESSAGE, dropdown_rect_x
from dialog import D_CONFIRM_CLOSE, D_FIND, D_HELP, D_PALETTE
from window import WK_EDITOR, WK_MESSAGE
from util import decode, to_str

comptime W = 80
comptime H = 25


def make(text: String) raises -> App:
    """An 80x25 app with one editor window holding `text`."""
    var app = App()
    app.scr.resize(W, H)
    app.show_clock = False
    app.exec(CM_NEW)
    app.fit_windows()
    app.wins[0].buf.load(decode(text))
    app.draw()
    return app^


def press(mut app: App, x: Int, y: Int) raises:
    app.handle(Event(EV_MOUSE, 0, x, y, MB_LEFT, True, False, List[Int]()))
    app.draw()


def drag_to(mut app: App, x: Int, y: Int) raises:
    app.handle(Event(EV_MOUSE, 0, x, y, MB_LEFT, True, True, List[Int]()))
    app.draw()


def release(mut app: App, x: Int, y: Int) raises:
    app.handle(Event(EV_MOUSE, 0, x, y, MB_LEFT, False, False, List[Int]()))
    app.draw()


def click(mut app: App, x: Int, y: Int) raises:
    press(app, x, y)
    release(app, x, y)


def wheel(mut app: App, x: Int, y: Int, down: Bool) raises:
    app.handle(Event(EV_MOUSE, 0, x, y, MB_WHEEL_DOWN if down else MB_WHEEL_UP, True, False, List[Int]()))
    app.draw()


def lines(n: Int) -> String:
    var s = String("")
    for i in range(n):
        s += "line " + String(i) + "\n"
    return s


# text origin of the full-size first window: frame at (0,1), gutter of 4
comptime TX = 5
comptime TY = 2


# ------------------------------------------------------------------ editor
def test_initial_layout() raises:
    var app = make("hello")
    assert_equal(len(app.wins), 1)
    assert_equal(app.wins[0].x, 0)
    assert_equal(app.wins[0].y, 1)
    assert_equal(app.wins[0].w, W)
    assert_equal(app.wins[0].h, H - 2)
    assert_equal(app.wins[0].gut, 4)


def test_click_places_cursor() raises:
    var app = make("hello\nworld")
    click(app, TX + 3, TY + 1)
    assert_equal(app.wins[0].cr, 1)
    assert_equal(app.wins[0].cc, 3)
    click(app, TX + 30, TY)        # past the end of the line
    assert_equal(app.wins[0].cr, 0)
    assert_equal(app.wins[0].cc, 5)
    click(app, TX, TY + 10)        # below the last line
    assert_equal(app.wins[0].cr, 1)
    assert_equal(app.wins[0].cc, 0)


def test_click_respects_tabs_and_wide_chars() raises:
    var app = make("\tab\n日本x")
    click(app, TX + 5, TY)         # tab is 4 columns, so column 5 is after 'a'
    assert_equal(app.wins[0].cc, 2)
    click(app, TX + 4, TY + 1)     # after the two wide characters
    assert_equal(app.wins[0].cc, 2)
    click(app, TX + 2, TY + 1)     # between 日 and 本
    assert_equal(app.wins[0].cc, 1)


def test_click_accounts_for_scrolling() raises:
    var app = make(lines(100))
    wheel(app, TX, TY, True)
    wheel(app, TX, TY, True)
    assert_equal(app.wins[0].top, 6)
    click(app, TX + 2, TY + 1)
    assert_equal(app.wins[0].cr, 7)
    assert_equal(app.wins[0].cc, 2)


def test_drag_selects_text() raises:
    var app = make("hello world\nsecond")
    press(app, TX, TY)
    drag_to(app, TX + 5, TY)
    assert_true(app.wins[0].has_sel())
    assert_equal(to_str(app.wins[0].selected_text()), "hello")
    drag_to(app, TX + 3, TY + 1)
    assert_equal(to_str(app.wins[0].selected_text()), "hello world\nsec")
    release(app, TX + 3, TY + 1)
    assert_equal(app.drag, 0)
    assert_true(app.wins[0].has_sel())
    # a plain click afterwards clears the selection
    click(app, TX + 1, TY)
    assert_false(app.wins[0].has_sel())


def test_drag_backwards_selects() raises:
    var app = make("hello")
    press(app, TX + 4, TY)
    drag_to(app, TX + 1, TY)
    assert_equal(to_str(app.wins[0].selected_text()), "ell")


def test_motion_without_press_does_not_select() raises:
    var app = make("hello")
    click(app, TX + 1, TY)
    drag_to(app, TX + 4, TY)       # drag report after release must be ignored
    assert_false(app.wins[0].has_sel())
    assert_equal(app.wins[0].cc, 1)


def test_wheel_scrolls_view_without_moving_cursor() raises:
    var app = make(lines(100))
    wheel(app, TX, TY, True)
    assert_equal(app.wins[0].top, 3)
    assert_equal(app.wins[0].cr, 0)
    wheel(app, TX, TY, False)
    wheel(app, TX, TY, False)      # cannot scroll above the top
    assert_equal(app.wins[0].top, 0)


def test_wheel_cannot_scroll_past_end() raises:
    var app = make("a\nb\nc")
    for _ in range(10):
        wheel(app, TX, TY, True)
    assert_true(app.wins[0].top <= 3)


def test_right_click_does_nothing() raises:
    var app = make("hello")
    click(app, TX + 2, TY)
    app.handle(Event(EV_MOUSE, 0, TX + 4, TY, MB_RIGHT, True, False, List[Int]()))
    assert_equal(app.wins[0].cc, 2)
    assert_equal(app.mode, M_NORMAL)


def test_scrollbar_arrows() raises:
    var app = make(lines(100))
    var wy = app.wins[0].y
    var wh = app.wins[0].h
    click(app, W - 1, wy + wh - 2)       # down arrow
    assert_equal(app.wins[0].top, 1)
    click(app, W - 1, wy + 1)            # up arrow
    assert_equal(app.wins[0].top, 0)
    click(app, W - 1, wy + wh - 4)       # track below the middle: page down
    assert_equal(app.wins[0].top, app.wins[0].rows())


# ----------------------------------------------------------------- windows
def test_corner_drag_resizes_and_title_drag_moves() raises:
    var app = make("hello")
    var t = app.top()
    press(app, W - 1, app.wins[t].y + app.wins[t].h - 1)
    drag_to(app, 59, 15)
    release(app, 59, 15)
    assert_equal(app.wins[t].w, 60)
    assert_equal(app.wins[t].h, 15)
    assert_equal(app.wins[t].x, 0)
    assert_equal(app.wins[t].y, 1)
    press(app, 30, 1)                    # title bar
    drag_to(app, 35, 4)
    release(app, 35, 4)
    assert_equal(app.wins[t].x, 5)
    assert_equal(app.wins[t].y, 4)
    assert_equal(app.wins[t].w, 60)      # size unchanged by moving
    # the text must not have been touched
    assert_equal(to_str(app.wins[t].buf.all_text()), "hello")
    assert_false(app.wins[t].has_sel())


def test_window_cannot_leave_the_desktop() raises:
    var app = make("hello")
    press(app, W - 1, H - 2)
    drag_to(app, 39, 10)
    release(app, 39, 10)
    press(app, 20, 1)
    drag_to(app, 200, 200)
    release(app, 200, 200)
    assert_true(app.wins[0].x + app.wins[0].w <= W)
    assert_true(app.wins[0].y + app.wins[0].h <= H - 1)
    press(app, app.wins[0].x + 20, app.wins[0].y)
    drag_to(app, -50, -50)
    release(app, 0, 0)
    assert_equal(app.wins[0].x, 0)
    assert_equal(app.wins[0].y, 1)


def test_window_has_minimum_size() raises:
    var app = make("hello")
    press(app, W - 1, H - 2)
    drag_to(app, 2, 2)
    release(app, 2, 2)
    assert_true(app.wins[0].w >= 16)
    assert_true(app.wins[0].h >= 4)


def test_zoom_box_toggles() raises:
    var app = make("hello")
    press(app, W - 1, H - 2)
    drag_to(app, 49, 12)
    release(app, 49, 12)
    assert_equal(app.wins[0].w, 50)
    click(app, app.wins[0].x + app.wins[0].w - 4, app.wins[0].y)
    assert_true(app.wins[0].zoomed)
    assert_equal(app.wins[0].w, W)
    assert_equal(app.wins[0].h, H - 2)
    click(app, W - 4, 1)
    assert_false(app.wins[0].zoomed)
    assert_equal(app.wins[0].w, 50)
    assert_equal(app.wins[0].h, 12)


def test_close_box_closes_unmodified_window() raises:
    var app = make("hello")
    click(app, 3, 1)
    assert_equal(len(app.wins), 0)
    assert_equal(app.mode, M_NORMAL)


def test_close_box_on_modified_window_asks_first() raises:
    var app = make("hello")
    app.wins[0].type_char(120, True)
    app.draw()
    click(app, 3, 1)
    assert_equal(len(app.wins), 1)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_CONFIRM_CLOSE)
    # Cancel keeps the window
    click(app, app.dlg.btn_x[2] + 2, app.dlg.btn_y)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(len(app.wins), 1)
    # No discards it
    click(app, 3, 1)
    click(app, app.dlg.btn_x[1] + 2, app.dlg.btn_y)
    assert_equal(len(app.wins), 0)


def test_clicking_a_background_window_brings_it_forward() raises:
    var app = make("first")
    app.exec(CM_NEW)                     # second window, cascaded one cell down-right
    app.draw()
    assert_equal(len(app.wins), 2)
    assert_equal(app.wins[1].x, 1)
    assert_equal(app.wins[1].y, 2)
    var first_number = app.wins[0].number
    click(app, 0, 6)                     # left border of the first window is still visible
    assert_equal(app.wins[app.top()].number, first_number)
    assert_equal(to_str(app.wins[app.top()].buf.all_text()), "first")


def test_click_in_background_window_text_places_cursor_there() raises:
    var app = make("first line here")
    app.exec(CM_NEW)
    # shrink the new top window so the first one shows through on the right
    press(app, W - 1, H - 2)
    drag_to(app, 40, 12)
    release(app, 40, 12)
    click(app, 60, 2)                    # in the first window's text row 0
    var t = app.top()
    assert_equal(to_str(app.wins[t].buf.all_text()), "first line here")
    assert_equal(app.wins[t].cr, 0)
    assert_equal(app.wins[t].cc, 15)     # clicked past the end of the 15-char line


# -------------------------------------------------------------------- menus
def test_menu_bar_click_opens_and_closes() raises:
    var app = make("hello")
    var fx = app.menus[1].x + 1
    click(app, fx, 0)
    assert_equal(app.mode, M_MENU)
    assert_equal(app.menu_idx, 1)
    click(app, app.menus[2].x + 1, 0)    # another title switches menus
    assert_equal(app.menu_idx, 2)
    click(app, app.menus[2].x + 1, 0)    # same title closes
    assert_equal(app.mode, M_NORMAL)
    click(app, fx, 0)
    click(app, 70, 20)                   # clicking elsewhere closes
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.wins[0].cr, 0)      # ...and is not treated as a text click


def test_menu_item_click_runs_command() raises:
    var app = make("hello")
    click(app, app.menus[1].x + 1, 0)    # File
    var dx = dropdown_rect_x(W, app.menus[1])
    click(app, dx + 3, 2)                # first item: New
    assert_equal(app.mode, M_NORMAL)
    assert_equal(len(app.wins), 2)


def test_menu_separator_click_is_ignored() raises:
    var app = make("hello")
    click(app, app.menus[1].x + 1, 0)
    var dx = dropdown_rect_x(W, app.menus[1])
    var sep = -1
    for i in range(len(app.menus[1].items)):
        if app.menus[1].items[i].label == "-":
            sep = i
            break
    assert_true(sep >= 0)
    click(app, dx + 3, 2 + sep)
    assert_equal(app.mode, M_MENU)
    assert_equal(len(app.wins), 1)


def test_status_bar_click_runs_command() raises:
    var app = make("hello")
    assert_true(len(app.st_cmd) > 0)
    click(app, app.st_x0[0] + 1, H - 1)  # "F1 Help"
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_HELP)


# ------------------------------------------------------------------ dialogs
def test_dialog_checkbox_field_and_buttons() raises:
    var app = make("hello fib")
    app.exec(CM_FIND)
    app.draw()
    assert_equal(app.dlg.kind, D_FIND)
    assert_false(app.dlg.check_vals[0])
    click(app, app.dlg.dx + 5, app.dlg.check_y[0])
    assert_true(app.dlg.check_vals[0])
    assert_equal(app.dlg.focus, 1)                    # the click moved focus to the box
    # clicking the input line focuses it; typing then goes into the field
    click(app, app.dlg.field_x + 1, app.dlg.field_y[0])
    assert_equal(app.dlg.focus, 0)
    for c in decode("abcdef"):
        app.handle_key(c)
    app.draw()
    assert_equal(to_str(app.dlg.fields[0].text), "abcdef")
    click(app, app.dlg.field_x + 1 + 2, app.dlg.field_y[0])
    assert_equal(app.dlg.fields[0].cur, 2)
    click(app, app.dlg.btn_x[1] + 2, app.dlg.btn_y)   # Cancel
    assert_equal(app.mode, M_NORMAL)
    assert_false(app.wins[0].has_sel())


def test_dialog_ok_button_runs_search() raises:
    var app = make("hello fib")
    app.exec(CM_FIND)
    for c in decode("fib"):
        app.handle_key(c)
    app.draw()
    click(app, app.dlg.btn_x[0] + 2, app.dlg.btn_y)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[0].selected_text()), "fib")


def test_clicks_outside_a_dialog_do_not_reach_the_editor() raises:
    var app = make("hello\nworld")
    app.exec(CM_FIND)
    app.draw()
    click(app, TX + 3, TY + 1)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.wins[0].cr, 0)
    assert_equal(app.wins[0].cc, 0)


def test_dialog_close_box() raises:
    var app = make("hello")
    app.exec(CM_FIND)
    app.draw()
    click(app, app.dlg.dx + 3, app.dlg.dy)
    assert_equal(app.mode, M_NORMAL)


def test_list_click_selects_and_second_click_accepts() raises:
    var app = make("hello")
    assert_false(app.wins[0].zoomed)
    app.exec(CM_PALETTE)
    for c in decode("zoom"):
        app.handle_key(c)
    app.draw()
    assert_equal(app.dlg.kind, D_PALETTE)
    assert_true(len(app.dlg.shown) >= 1)
    click(app, app.dlg.list_x + 2, app.dlg.list_y)    # first row (already selected)
    assert_equal(app.mode, M_DIALOG)                  # first click only selects
    click(app, app.dlg.list_x + 2, app.dlg.list_y)    # second click runs it
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.wins[0].zoomed)


def test_wheel_scrolls_dialog_list() raises:
    var app = make("hello")
    app.exec(CM_PALETTE)
    app.draw()
    assert_equal(app.dlg.list_sel, 0)
    wheel(app, 40, 12, True)
    assert_equal(app.dlg.list_sel, 3)
    wheel(app, 40, 12, False)
    assert_equal(app.dlg.list_sel, 0)
    assert_equal(app.wins[0].top, 0)


# ----------------------------------------------------------- message window
def test_message_window_click_selects_row() raises:
    var app = make("hello")
    app.exec(CM_MESSAGE)
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_MESSAGE)
    app.wins[t].buf.load(decode("one\ntwo\nthree"))
    app.draw()
    click(app, 10, app.wins[t].y + 1 + 2)
    assert_equal(app.wins[app.top()].cr, 2)
    assert_equal(app.wins[app.top()].kind, WK_MESSAGE)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
