"""Mouse handling."""
from std.collections import List, Dict
from std.time import perf_counter_ns
from std.ffi import external_call
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from palette import Palette, theme, THEME_COUNT
from highlight import Highlighter
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_lsp import *
from lsp import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_pickers import *
from app_jobs import *
from app_input import *
from app_draw import *


__extension App:
    def handle_mouse(mut self, e: Event) raises:
        var x = e.mx
        var y = e.my
        # ---- wheel
        if e.button == MB_WHEEL_UP or e.button == MB_WHEEL_DOWN:
            var d = -3 if e.button == MB_WHEEL_UP else 3
            if self.mode == M_DIALOG and self.dlg.has_list:
                self.dlg.list_move(d)
                return
            if self.mode == M_COMPLETE:
                self.comp_sel = max(0, min(len(self.comp_items) - 1, self.comp_sel + d))
                return
            if self.mode == M_HOVER:
                self.hover_scroll = max(0, min(max(0, len(self.hover_lines) - self.hover_page()), self.hover_scroll + d))
                return
            if self.mode != M_NORMAL:
                return
            var i = self.window_at(x, y)
            if i >= 0:
                if self.wins[i].kind == WK_MESSAGE:
                    self.wins[i].cr = max(0, min(self.wins[i].buf.count() - 1, self.wins[i].cr + d))
                    self.wins[i].follow = True
                else:
                    self.wins[i].scroll(d)
            return
        # ---- release
        if not e.pressed:
            self.drag = 0
            return
        # ---- drag
        if e.drag:
            var t = self.top()
            if t < 0 or self.mode != M_NORMAL:
                return
            if self.drag == 1:
                self.wins[t].x = x - self.drag_dx
                self.wins[t].y = y - self.drag_dy
                self.wins[t].zoomed = False
                self.fit_windows()
            elif self.drag == 2:
                self.wins[t].w = max(16, x - self.wins[t].x + 1)
                self.wins[t].h = max(4, y - self.wins[t].y + 1)
                self.wins[t].zoomed = False
                self.fit_windows()
            elif self.drag == 3:
                var p = self.wins[t].screen_to_pos(x, y)
                if not self.wins[t].sel:
                    self.wins[t].sel = True
                    self.wins[t].ar = self.wins[t].cr
                    self.wins[t].ac = self.wins[t].cc
                self.wins[t].cr = p.r
                self.wins[t].cc = p.c
                self.wins[t].sync_want()
                self.wins[t].follow = True
            elif self.drag == 4:
                # Alt+drag: a column selection from where the button went down
                var bp = self.wins[t].screen_to_pos(x, y)
                var br = bp.r
                var bv = max(0, self.wins[t].left + (x - self.wins[t].x - 1 - self.wins[t].gut))
                if self.wins[t].wrap:
                    bv = self.wins[t].vcol(bp.r, bp.c)
                self.wins[t].box_select(self.drag_dy, self.drag_dx, br, bv)
            return
        if e.button != MB_LEFT:
            return
        # ---- dialogs
        if self.mode == M_DIALOG:
            if self.dlg.kind == D_RESULT:
                self.mode = M_NORMAL
                return
            var b = self.dlg.button_at(x, y)
            if b >= 0:
                self.dlg.focus = self.dlg.button_focus_index(b)
                self.dialog_button(b)
                return
            if x == self.dlg.dx + 3 and y == self.dlg.dy:
                self.dismiss_dialog()
                return
            for i in range(len(self.dlg.field_y)):
                if y == self.dlg.field_y[i] and x >= self.dlg.field_x:
                    self.dlg.focus = i
                    self.dlg.fields[i].fresh = False
                    self.dlg.fields[i].cur = max(0, min(len(self.dlg.fields[i].text), x - self.dlg.field_x - 1 + self.dlg.fields[i].scroll))
                    return
            for i in range(len(self.dlg.check_y)):
                if y == self.dlg.check_y[i] and x >= self.dlg.check_x[i] and x < self.dlg.check_x[i] + self.dlg.check_w:
                    self.dlg.focus = len(self.dlg.fields) + i
                    self.dlg.check_vals[i] = not self.dlg.check_vals[i]
                    return
            if self.dlg.has_list and x >= self.dlg.list_x and x < self.dlg.list_x + self.dlg.list_w and y >= self.dlg.list_y and y < self.dlg.list_y + self.dlg.list_h:
                var k = self.dlg.list_top + (y - self.dlg.list_y)
                if k < len(self.dlg.shown):
                    if not self.dlg.list_filter:
                        self.dlg.focus = len(self.dlg.fields) + len(self.dlg.checks)
                    if k == self.dlg.list_sel and self.last_click_item == k:
                        self.last_click_item = -1
                        self.dialog_button(0)
                        return
                    self.dlg.list_move(k - self.dlg.list_sel)
                    self.last_click_item = k
            return
        # ---- completion popup or hover window: any click closes it
        if self.mode == M_COMPLETE or self.mode == M_HOVER:
            self.mode = M_NORMAL
        # ---- menu bar / dropdown
        if self.mode == M_MENU:
            var m = self.menus[self.menu_idx].copy()
            var mx = dropdown_rect_x(self.scr.w, m)
            var mw = m.width()
            if x > mx and x < mx + mw - 1 and y >= 2 and y < 2 + len(m.items):
                var it = y - 2
                if m.items[it].cmd != CM_NONE:
                    self.mode = M_NORMAL
                    self.macro_note_cmd(m.items[it].cmd)
                    self.exec(m.items[it].cmd)
                return
            if y != 0:
                self.mode = M_NORMAL
                return
        if y == 0:
            for i in range(len(self.menus)):
                var w = cp_len(self.menus[i].title)
                if x >= self.menus[i].x and x < self.menus[i].x + w:
                    if self.mode == M_MENU and self.menu_idx == i:
                        self.mode = M_NORMAL
                    else:
                        self.open_menu(i)
                    return
            self.mode = M_NORMAL
            return
        if y == self.scr.h - 1:
            for i in range(len(self.st_cmd)):
                if x >= self.st_x0[i] and x < self.st_x1[i]:
                    if self.st_cmd[i] == -1:
                        self.open_menu(1)
                    else:
                        self.macro_note_cmd(self.st_cmd[i])
                        self.exec(self.st_cmd[i])
                    return
            return
        # ---- windows
        var i = self.window_at(x, y)
        if i < 0:
            return
        self.focus(i)
        var t = self.top()
        var wx = self.wins[t].x
        var wy = self.wins[t].y
        var ww = self.wins[t].w
        var wh = self.wins[t].h
        if y == wy:
            if x >= wx + 2 and x <= wx + 4:
                self.close_window(t, NEXT_CLOSE)
                return
            if x >= wx + ww - 5 and x <= wx + ww - 3:
                self.exec(CM_ZOOM)
                return
            self.drag = 1
            self.drag_dx = x - wx
            self.drag_dy = y - wy
            return
        if x >= wx + ww - 2 and y >= wy + wh - 1:
            self.drag = 2
            return
        if x == wx + ww - 1:
            # vertical scrollbar
            if y == wy + 1:
                self.wins[t].scroll(-1)
            elif y == wy + wh - 2:
                self.wins[t].scroll(1)
            elif y < wy + wh // 2:
                self.wins[t].scroll(-self.wins[t].rows())
            else:
                self.wins[t].scroll(self.wins[t].rows())
            return
        if y == wy + wh - 1 or x == wx:
            return
        if self.wins[t].kind == WK_MESSAGE:
            var r = self.wins[t].top + (y - wy - 1)
            if r < self.wins[t].buf.count():
                if self.wins[t].cr == r:
                    self.message_key(KEY_ENTER)
                else:
                    self.wins[t].cr = r
            return
        if self.wins[t].gut > 0 and x == wx + self.wins[t].gut:
            # the fold marker in the gutter
            var fr = self.wins[t].pos_at_screen_row(y - wy - 1).r
            if fr < self.wins[t].buf.count() and (self.wins[t].buf.fold_index(fr) >= 0 or self.wins[t].buf.foldable(fr)):
                _ = self.wins[t].toggle_fold(fr)
                return
        var p = self.wins[t].screen_to_pos(x, y)
        if e.key & MOD_ALT != 0:
            self.wins[t].toggle_cursor_at(p.r, p.c)     # Alt-click: one more cursor
            self.drag = 4                               # ...and Alt+drag makes a box from here
            self.drag_dy = p.r
            self.drag_dx = max(0, self.wins[t].left + (x - self.wins[t].x - 1 - self.wins[t].gut))
            if self.wins[t].wrap:
                self.drag_dx = self.wins[t].vcol(p.r, p.c)
            return
        self.wins[t].collapse()
        self.wins[t].begin_move(False)
        self.wins[t].cr = p.r
        self.wins[t].cc = p.c
        self.wins[t].sync_want()
        self.drag = 3
