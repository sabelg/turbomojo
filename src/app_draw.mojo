"""Drawing the desktop, status line, cursor and popups."""
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
from buffer import TextBuffer, Pos
from window import Window, WK_EDITOR, WK_MESSAGE, ACT_OTHER, ACT_TYPE
from window_search import *
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
from app_mouse import *


__extension App:
    # ================================================================= draw
    def draw_status(mut self, items: List[String], cmds: List[Int]):
        var y = self.scr.h - 1
        var p = self.pal.copy()
        self.scr.fill(0, y, self.scr.w, 1, 32, p.status_fg, p.status_bg)
        self.st_x0.clear()
        self.st_x1.clear()
        self.st_cmd.clear()
        var x = 1
        for i in range(len(items)):
            var x0 = x
            x = self.scr.hot_text(x, y, items[i], p.status_fg, p.status_hot, p.status_bg)
            self.st_x0.append(x0)
            self.st_x1.append(x)
            self.st_cmd.append(cmds[i])
            x += 2
        var right = String("")
        if self.status_until > now_ns():
            right = self.status
        else:
            var ti = self.top_editor()
            if ti >= 0:
                right = ("CRLF" if self.wins[ti].buf.crlf else "LF") + "  " + (("Tabs:" + String(self.wins[ti].buf.tab_width)) if self.wins[ti].buf.use_tabs else ("Spaces:" + String(self.wins[ti].buf.indent_size))) + "  "
            if self.lsp.active():
                right += "LSP  "
            right += "INS" if self.insert_mode else "OVR"
        if self.job.active:
            var sp = decode(SPINNER)
            var b = List[UInt8]()
            encode_cp(sp[(now_ns() // (SPINNER_MS * 1000000)) % len(sp)], b)
            var what = "Building " if self.job.kind == JOB_BUILD else "Formatting "
            var e = self.job_elapsed()
            right = bytes_to_str(b) + " " + what + basename(self.job.path) + " " + String(Int(e)) + "." + String(Int(e * 10) % 10) + "s  ^F2 cancel  " + right
        var rl = cp_len(right)
        var rx = self.scr.w - rl - 1
        if rx < x:
            rx = x
        if rx < self.scr.w:
            self.scr.clip(0, y, self.scr.w, 1)
            if rx > x:
                self.scr.put(rx - 2, y, 0x2502, p.status_fg, p.status_bg)
            _ = self.scr.text(rx, y, right, p.status_fg, p.status_bg)
            self.scr.no_clip()

    def draw(mut self):
        var p = self.pal.copy()
        self.scr.no_clip()
        self.scr.fill(0, 1, self.scr.w, self.scr.h - 2, p.desk_ch, p.desk_fg, p.desk_bg)
        var n = len(self.wins)
        for i in range(n):
            self.wins[i].gut = self.wins[i].gutter_for(self.line_numbers)
            if self.wins[i].follow:
                self.wins[i].ensure_visible()
                self.wins[i].follow = False
            # highlighter states for the visible rows (incremental; see Window.sync_lex)
            self.wins[i].sync_lex(self.wins[i].top + self.wins[i].rows() + 1)
        for i in range(n):
            self.draw_window(i, i == n - 1)
            if i == n - 1 and self.wins[i].w < self.scr.w:
                self.scr.shadow(self.wins[i].x, self.wins[i].y, self.wins[i].w, self.wins[i].h, p.shadow_fg, p.shadow_bg)
        draw_menubar(self.scr, p, self.menus, self.menu_idx if self.mode == M_MENU else -1, clock_hm() if self.show_clock else "")
        # status line
        var items = List[String]()
        var cmds = List[Int]()
        if self.mode == M_MENU:
            items.append(self.menus[self.menu_idx].items[self.menu_item].hint)
            cmds.append(CM_NONE)
        elif self.mode == M_DIALOG:
            items.append("~Tab~ Next control")
            cmds.append(CM_NONE)
            items.append("~Enter~ Accept")
            cmds.append(CM_NONE)
            items.append("~Esc~ Cancel")
            cmds.append(CM_NONE)
        elif self.mode == M_COMPLETE:
            items.append("~Enter~ Insert")
            cmds.append(CM_NONE)
            items.append("~Esc~ Close")
            cmds.append(CM_NONE)
        else:
            var t = self.top()
            items.append("~F1~ Help")
            cmds.append(CM_HELP)
            if t >= 0 and self.wins[t].kind == WK_MESSAGE:
                items.append("~Enter~ Go to source")
                cmds.append(CM_NONE)
                items.append("~Alt-F8~ Next msg")
                cmds.append(CM_NEXTERR)
                items.append("~F6~ Next window")
                cmds.append(CM_NEXTWIN)
            else:
                items.append("~F2~ Save")
                cmds.append(CM_SAVE)
                items.append("~F3~ Open")
                cmds.append(CM_OPEN)
                items.append("~^P~ Commands")
                cmds.append(CM_PALETTE)
                items.append("~F9~ Build")
                cmds.append(CM_BUILD)
                items.append("~^F9~ Run")
                cmds.append(CM_RUN)
            items.append("~F10~ Menu")
            cmds.append(-1)
        self.draw_status(items, cmds)
        if self.mode == M_MENU:
            draw_dropdown(self.scr, p, self.menus[self.menu_idx], self.menu_item, self.checked())
        # cursor
        self.scr.cvis = False
        var t = self.top()
        if (self.mode == M_NORMAL or self.mode == M_COMPLETE) and t >= 0 and self.wins[t].kind == WK_EDITOR:
            var cx = self.wins[t].x + 1 + self.wins[t].gut + self.wins[t].vcol(self.wins[t].cr, self.wins[t].cc) - self.wins[t].left
            var cy = self.wins[t].y + 1 + self.wins[t].cr - self.wins[t].top
            if cx > self.wins[t].x and cx < self.wins[t].x + self.wins[t].w - 1 and cy > self.wins[t].y and cy < self.wins[t].y + self.wins[t].h - 1:
                self.scr.cx = cx
                self.scr.cy = cy
                self.scr.cvis = True
                self.scr.cblock = not self.insert_mode
            if self.mode == M_COMPLETE:
                self.draw_completion(cx, cy)
        if self.mode == M_DIALOG:
            var c = self.dlg.draw(self.scr, p)
            if c[0] >= 0:
                self.scr.cx = c[0]
                self.scr.cy = c[1]
                self.scr.cvis = True
                self.scr.cblock = False

    def draw_window(mut self, i: Int, active: Bool):
        var p = self.pal.copy()
        self.wins[i].draw(self.scr, p, self.hl, active, self.hl_line, self.insert_mode, self.show_ws)

    def draw_completion(mut self, cx: Int, cy: Int):
        var p = self.pal.copy()
        var n = len(self.comp_items)
        var h = min(8, n)
        var w = 12
        for s in self.comp_items:
            w = max(w, cp_len(s) + 2)
        w = min(w, 40)
        var ai = self.top()
        var plen = self.wins[ai].cc - self.comp_start
        var x = max(0, min(cx - plen - 1, self.scr.w - w - 2))
        var y = cy + 1
        if y + h > self.scr.h - 1:
            y = cy - h
        var topi = max(0, min(self.comp_sel - h + 1, n - h))
        if self.comp_sel < topi:
            topi = self.comp_sel
        for r in range(h):
            var k = topi + r
            var sel = k == self.comp_sel
            var fg = p.list_sel_fg if sel else p.list_fg
            var bg = p.list_sel_bg if sel else p.list_bg
            self.scr.fill(x, y + r, w, 1, 32, fg, bg)
            _ = self.scr.text(x + 1, y + r, self.comp_items[k], fg, bg)
        self.scr.shadow(x, y, w, h, p.shadow_fg, p.shadow_bg)
