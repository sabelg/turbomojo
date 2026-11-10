"""Menu bar navigation."""
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
from app_exec import *
from app_pickers import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *


__extension App:
    # ================================================================= menus
    def open_menu(mut self, idx: Int):
        self.mode = M_MENU
        self.menu_idx = idx
        self.menu_item = 0
        while self.menu_item < len(self.menus[idx].items) and self.menus[idx].items[self.menu_item].cmd == CM_NONE:
            self.menu_item += 1

    def menu_step(mut self, d: Int):
        var n = len(self.menus[self.menu_idx].items)
        var i = self.menu_item
        for _ in range(n):
            i = (i + d + n) % n
            if self.menus[self.menu_idx].items[i].cmd != CM_NONE:
                break
        self.menu_item = i

    def menu_for_letter(self, c: Int) -> Int:
        for i in range(len(self.menus)):
            if hot_char(self.menus[i].title) == c:
                return i
        return -1

    def menu_key(mut self, k: Int) raises:
        var n = len(self.menus)
        if k == KEY_ESC or k == fkey(10):
            self.mode = M_NORMAL
        elif k == KEY_LEFT:
            self.open_menu((self.menu_idx - 1 + n) % n)
        elif k == KEY_RIGHT:
            self.open_menu((self.menu_idx + 1) % n)
        elif k == KEY_UP:
            self.menu_step(-1)
        elif k == KEY_DOWN:
            self.menu_step(1)
        elif k == KEY_HOME:
            self.open_menu(self.menu_idx)
        elif k == KEY_ENTER:
            var cmd = self.menus[self.menu_idx].items[self.menu_item].cmd
            self.mode = M_NORMAL
            self.macro_note_cmd(cmd)
            self.exec(cmd)
        elif (k & MOD_ALT) != 0:
            var m = self.menu_for_letter(lower(k & KEY_MASK))
            if m >= 0:
                self.open_menu(m)
            else:
                self.mode = M_NORMAL
                self.handle_key(k)
        elif k < K_BASE and k > 32:
            var lk = lower(k)
            for i in range(len(self.menus[self.menu_idx].items)):
                if hot_char(self.menus[self.menu_idx].items[i].label) == lk:
                    var cmd = self.menus[self.menu_idx].items[i].cmd
                    self.mode = M_NORMAL
                    self.macro_note_cmd(cmd)
                    self.exec(cmd)
                    return
        else:
            var cmd = self.shortcut(k)
            if cmd != CM_NONE:
                self.mode = M_NORMAL
                self.macro_note_cmd(cmd)
                self.exec(cmd)

    def checked(self) -> List[Int]:
        var out = List[Int]()
        if self.line_numbers:
            out.append(CM_LINENUM)
        if self.auto_indent:
            out.append(CM_AUTOINDENT)
        if self.hl_line:
            out.append(CM_HLLINE)
        if self.show_clock:
            out.append(CM_CLOCK)
        if self.show_ws:
            out.append(CM_SHOWWS)
        if self.soft_wrap:
            out.append(CM_WRAP)
        var ti = self.top_editor()
        if ti >= 0 and self.wins[ti].buf.use_tabs:
            out.append(CM_USETABS)
        if ti >= 0 and self.wins[ti].buf.crlf:
            out.append(CM_CRLF)
        out.append(CM_THEME0 + self.theme_idx)
        out.append(CM_KEYMAP0 + self.keymap)
        return out^
