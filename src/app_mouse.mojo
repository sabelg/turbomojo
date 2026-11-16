"""Mouse handling."""
from std.collections import List, Dict
from std.time import perf_counter_ns
from std.ffi import external_call
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_MIDDLE, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from palette import Palette, theme, THEME_COUNT
from highlight import Highlighter
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_HEX, WK_MDPREVIEW, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, MINIMAP_W, ACT_OTHER, ACT_TYPE
from layout import L_ROW, L_COL, RATIO_MIN, RATIO_MAX
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_keyecho import *
from app_notify import *
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
from app_nav import *
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from app_jobs import *
from app_input import *
from app_draw import *
from cells import parse_cells, cell_at_row


__extension App:
    def handle_mouse(mut self, e: Event) raises:
        var x = e.mx
        var y = e.my
        if self.mode == M_DOCS:
            self.docs_mouse(e)
            return
        if self.mode == M_NORMAL and e.pressed and e.button == MB_LEFT and not e.drag and self.toast_click(x, y):
            return                              # a click on a toast takes it away
        if self.mode == M_NORMAL:
            # inside a terminal window: its own wheel and selection
            var ti = self.window_at(x, y) if e.pressed or e.button == MB_WHEEL_UP or e.button == MB_WHEEL_DOWN else self.top()
            if e.drag or not e.pressed:
                ti = self.top()
            if ti >= 0 and self.wins[ti].kind == WK_TERM and (ti == self.top() or e.pressed) and self.term_mouse(ti, e):
                return
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
            if self.mode == M_PEEK:
                self.peek_scroll = max(0, min(max(0, len(self.peek_lines) - 1), self.peek_scroll + d))
                return
            if self.mode != M_NORMAL:
                return
            var i = self.window_at(x, y)
            if i >= 0:
                if self.wins[i].kind != WK_EDITOR and self.wins[i].kind != WK_MDPREVIEW:
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
            if self.mode == M_NORMAL and self.drag == 6 and self.tiled:
                var sn = self.drag_split_node
                if sn >= 0 and sn < len(self.lay.kind) and self.lay.alive[sn]:
                    var r: Int
                    if self.drag_split_col:
                        r = ((y - self.lay.gy[sn] + 1) * 1000) // max(1, self.lay.gh[sn])
                    else:
                        r = ((x - self.lay.gx[sn]) * 1000) // max(1, self.lay.gw[sn])
                    self.lay.ratio[sn] = max(RATIO_MIN, min(RATIO_MAX, r))
                    self.layout_sync()
                return
            if self.mode == M_NORMAL and (self.drag == 5 or self.drag == 7):
                var swi = self.drag_scroll_wi if self.drag == 5 else self.drag_minimap_wi
                if swi >= 0 and swi < len(self.wins):
                    var sy0 = self.wins[swi].y + 1
                    var sy1 = self.wins[swi].y + self.wins[swi].h - 2
                    var span = max(1, sy1 - sy0)
                    var clamped_y = max(sy0, min(sy1, y))
                    var tot = max(0, self.wins[swi].buf.count() - max(1, self.wins[swi].rows()))
                    self.wins[swi].top = ((clamped_y - sy0) * tot) // span
                    self.wins[swi].top_seg = 0
                    self.wins[swi].follow = False
                return
            var t = self.top()
            if t < 0 or self.mode != M_NORMAL:
                return
            if self.drag == 1:
                self.wins[t].x = x - self.drag_dx
                self.wins[t].y = y - self.drag_dy
                self.wins[t].zoomed = False
                self.wins[t].half = False
                self.fit_windows()
            elif self.drag == 2:
                self.wins[t].w = max(16, x - self.wins[t].x + 1)
                self.wins[t].h = max(4, y - self.wins[t].y + 1)
                self.wins[t].zoomed = False
                self.wins[t].half = False
                self.fit_windows()
            elif self.drag == 3:
                var p = self.wins[t].screen_to_pos(x, y)
                if not self.wins[t].sel:
                    self.wins[t].sel = True
                    self.wins[t].ar = self.wins[t].cr
                    self.wins[t].ac = self.wins[t].cc
                self.wins[t].cr = p.r
                self.wins[t].cc = p.c
                if self.keymap == 3 and (p.r != self.wins[t].ar or p.c != self.wins[t].ac):
                    self.vim.mode = 2
                    self.vim.ar = self.wins[t].ar
                    self.vim.ac = self.wins[t].ac
                    self.wins[t].vsel = 1
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
        if e.button == MB_MIDDLE:
            if self.mode == M_NORMAL:
                for k in range(len(self.tab_wid)):
                    if y == self.tab_y[k] and x >= self.tab_x0[k] and x < self.tab_x1[k] and self.tab_wid[k] > 0:
                        var ti = self.win_by_wid(self.tab_wid[k])
                        if ti >= 0:
                            self.close_window(ti, NEXT_CLOSE)
                            self.layout_sync()
                        return
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
        # ---- completion popup, hover or peek window: any click closes it
        if self.mode == M_COMPLETE or self.mode == M_HOVER or self.mode == M_PEEK:
            self.mode = M_NORMAL
        # ---- menu bar / dropdown
        if self.mode == M_MENU:
            var m = self.menus[self.menu_idx].copy()
            var mx = dropdown_rect_x(self.scr.w, m)
            var mw = m.width()
            if x > mx and x < mx + mw - 1 and y >= 2 and y < 2 + dropdown_rows(self.scr.h, m):
                var it = y - 2 + dropdown_top(self.scr.h, m, self.menu_item)
                if m.items[it].cmd != CM_NONE:
                    self.mode = M_NORMAL
                    self.macro_note_cmd(m.items[it].cmd)
                    var mc = m.items[it].cmd
                    self.exec(mc)
                    self.key_echo(mc)
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
                        var sc = self.st_cmd[i]
                        self.exec(sc)
                        self.key_echo(sc)
                    return
            return
        # ---- windows
        for k in range(len(self.tab_wid)):
            if y == self.tab_y[k] and x >= self.tab_x0[k] and x < self.tab_x1[k]:
                if self.tab_wid[k] < 0:
                    self.panel_show(-self.tab_wid[k] - 1)   # a page of the bottom panel
                    self.focus(self.msg_index())
                    return
                var ti = self.win_by_wid(self.tab_wid[k])
                if ti >= 0:
                    self.focus(ti)              # a tab of a pane: show that file
                    self.layout_sync()
                    return
        if self.tiled:
            for sn in range(len(self.lay.kind)):
                if not self.lay.alive[sn]:
                    continue
                if self.lay.kind[sn] == L_ROW:
                    var sx = self.lay.gx[self.lay.second[sn]]
                    if x == sx and y > self.lay.gy[sn] and y < self.lay.gy[sn] + self.lay.gh[sn] - 1:
                        self.drag = 6
                        self.drag_split_node = sn
                        self.drag_split_col = False
                        return
                elif self.lay.kind[sn] == L_COL:
                    var sy = self.lay.gy[self.lay.second[sn]]
                    if y == sy - 1 and x > self.lay.gx[sn] + 2 and x < self.lay.gx[sn] + self.lay.gw[sn] - 3:
                        self.drag = 6
                        self.drag_split_node = sn
                        self.drag_split_col = True
                        return
        var i = self.window_at(x, y)
        if i < 0:
            return
        self.focus(i)
        var t = self.top()
        var wx = self.wins[t].x
        var wy = self.wins[t].y
        var ww = self.wins[t].w
        var wh = self.wins[t].h
        var pd = self.wins[t].pad()
        if not self.wins[t].chromeless and y == wy:
            if x >= wx + 2 and x <= wx + 4:
                self.close_window(t, NEXT_CLOSE)
                return
            if x >= wx + ww - 5 and x <= wx + ww - 3:
                self.zoom_toggle()                  # (the box: maximize or restore)
                return
            if self.tiled and self.is_pane_win(self.wins[t].kind):
                return                          # panes are not dragged about
            self.drag = 1
            self.drag_dx = x - wx
            self.drag_dy = y - wy
            return
        if not self.wins[t].chromeless and x >= wx + ww - 2 and y >= wy + wh - 1:
            if not (self.tiled and self.is_pane_win(self.wins[t].kind)):
                self.drag = 2
            return
        if not self.wins[t].chromeless and x == wx + ww - 1:
            # vertical scrollbar
            if y == wy + 1:
                self.wins[t].scroll(-1)
            elif y == wy + wh - 2:
                self.wins[t].scroll(1)
            elif y < wy + wh // 2:
                self.wins[t].scroll(-self.wins[t].rows())
                self.drag = 5
                self.drag_scroll_wi = t
            else:
                self.wins[t].scroll(self.wins[t].rows())
                self.drag = 5
                self.drag_scroll_wi = t
            return
        if not self.wins[t].chromeless and (y == wy + wh - 1 or x == wx):
            return
        if self.wins[t].chromeless and self.wins[t].split_sep and x == wx + ww - 1:
            return
        if self.wins[t].kind == WK_EDITOR and self.wins[t].minimap and not self.scr.plain and x >= wx + ww - pd - MINIMAP_W and x < wx + ww - pd:
            var sy0 = wy + pd
            var sy1 = wy + wh - pd - 1
            var span = max(1, sy1 - sy0)
            var clamped_y = max(sy0, min(sy1, y))
            var tot = max(0, self.wins[t].buf.count() - max(1, self.wins[t].rows()))
            self.wins[t].top = ((clamped_y - sy0) * tot) // span
            self.wins[t].top_seg = 0
            self.wins[t].follow = False
            self.drag = 7
            self.drag_minimap_wi = t
            return
        if self.wins[t].kind != WK_EDITOR:
            var r = self.wins[t].top + (y - wy - pd)
            if r < self.wins[t].buf.count():
                if self.wins[t].cr == r:
                    self.message_key(KEY_ENTER)
                else:
                    self.wins[t].cr = r
            return
        var scr_pos = self.wins[t].pos_at_screen_row(max(0, y - wy - pd))
        var br_click = scr_pos.r
        if scr_pos.c == 0 and br_click < self.wins[t].buf.count() and self.wins[t].buf.is_cell_header(br_click):
            var gut_end = wx + pd + self.wins[t].gut
            var hdr_text_end = gut_end + self.wins[t].buf.llen(br_click)
            if (x >= wx + pd and x < gut_end) or x >= hdr_text_end + 1:
                var cells = parse_cells(self.wins[t].buf)
                var ci = cell_at_row(cells, br_click)
                if ci >= 0:
                    self.wins[t].cr = br_click
                    self.wins[t].cc = 0
                    self.run_code_cell_by_index(t, ci, False)
                    return
        if self.wins[t].gut > 0 and x >= wx + pd and x < wx + pd + self.wins[t].gut - 1 and self.wins[t].path.byte_length() > 0:
            var br = br_click
            if br < self.wins[t].buf.count():
                # A click on column wx + pd at a test-lens row executes that test
                if x == wx + pd and len(self.wins[t].test_lens_rows) > 0:
                    var is_lens = False
                    for k in range(len(self.wins[t].test_lens_rows)):
                        if self.wins[t].test_lens_rows[k] == br:
                            is_lens = True
                            break
                    if is_lens:
                        self.test_run_single(t, br)
                        return
                # Otherwise a click on the line number sets or removes a breakpoint
                self.bp_toggle_at(t, br)
            return
        if self.wins[t].gut > 0 and x == wx + pd + self.wins[t].gut - 1:
            # the fold marker in the gutter
            var fr = br_click
            if fr < self.wins[t].buf.count() and (self.wins[t].buf.fold_index(fr) >= 0 or self.wins[t].buf.foldable(fr)):
                _ = self.wins[t].toggle_fold(fr)
                return
        self.wins[t].nb_cmd_mode = False
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
        if self.keymap == 3 and (self.vim.mode == 2 or self.vim.mode == 3 or self.vim.mode == 4):
            self.vim.mode = 0
            self.wins[t].vsel = 0
            self.wins[t].sel = False
        self.wins[t].cr = p.r
        self.wins[t].cc = p.c
        self.wins[t].sync_want()
        self.drag = 3
