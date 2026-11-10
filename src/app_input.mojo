"""Keyboard and paste input routing."""
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
from app_mouse import *
from app_draw import *


__extension App:
    # ================================================================ input
    def handle(mut self, e: Event) raises:
        self.handle_event(e)
        if self.mode == M_DIALOG and (self.dlg.kind == D_FIND or self.dlg.kind == D_REPLACE):
            self.find_refresh()

    def handle_event(mut self, e: Event) raises:
        if e.kind == EV_MOUSE:
            self.handle_mouse(e)
            return
        if e.kind == EV_PASTE:
            if self.mode == M_DIALOG:
                var fi = self.dlg.focus_field()
                if fi >= 0:
                    self.dlg.field_key_insert(fi, e.text)
                return
            self.mode = M_NORMAL
            var ai = self.active_editor()
            if ai >= 0:
                self.wins[ai].paste_multi(e.text)
            return
        self.handle_key(e.key)

    def handle_key(mut self, k: Int) raises:
        if self.mode == M_DIALOG:
            self.dialog_key(k)
            return
        if self.mode == M_MENU:
            self.menu_key(k)
            return
        if self.mode == M_COMPLETE:
            if self.complete_key(k):
                return
        if k == fkey(10):
            self.open_menu(1)
            return
        var cmd = self.shortcut(k)
        if cmd != CM_NONE:
            self.exec(cmd)
            return
        if (k & MOD_ALT) != 0 and (k & (MOD_CTRL | MOD_SHIFT)) == 0:
            var c = k & KEY_MASK
            if c >= 49 and c <= 57:
                for i in range(len(self.wins)):
                    if self.wins[i].number == c - 48:
                        self.focus(i)
                        return
                return
            var m = self.menu_for_letter(lower(c))
            if c == 32:
                m = 0
            if m >= 0:
                self.open_menu(m)
            return
        var t = self.top()
        if t < 0:
            return
        if self.wins[t].kind == WK_MESSAGE:
            self.message_key(k)
            return
        self.editor_key(k)

    def message_key(mut self, k: Int) raises:
        var t = self.top()
        var n = self.wins[t].buf.count()
        if k == KEY_UP:
            self.wins[t].cr = max(0, self.wins[t].cr - 1)
        elif k == KEY_DOWN:
            self.wins[t].cr = min(n - 1, self.wins[t].cr + 1)
        elif k == KEY_PGUP:
            self.wins[t].cr = max(0, self.wins[t].cr - self.wins[t].rows())
        elif k == KEY_PGDN:
            self.wins[t].cr = min(n - 1, self.wins[t].cr + self.wins[t].rows())
        elif k == KEY_HOME or k == (KEY_HOME | MOD_CTRL):
            self.wins[t].cr = 0
        elif k == KEY_END or k == (KEY_END | MOD_CTRL):
            self.wins[t].cr = n - 1
        elif k == KEY_ENTER or k == 32:
            var row = self.wins[t].cr
            var best = -1
            for j in range(len(self.errs)):
                if self.errs[j].msg_line <= row:
                    best = j
            if best >= 0 and row - self.errs[best].msg_line < 6:
                self.err_idx = best
                self.jump_to_error(best)
            return
        elif k == KEY_ESC:
            if len(self.wins) > 1:
                self.focus(0)
        self.wins[t].cc = 0
        self.wins[t].follow = True

    def editor_key(mut self, k: Int) raises:
        var t = self.top()
        var shift = (k & MOD_SHIFT) != 0
        var ctl = (k & MOD_CTRL) != 0
        var base = k & ~MOD_SHIFT
        var none = List[Int]()
        var word = ctl or (k & MOD_ALT) != 0
        if base == KEY_LEFT or base == (KEY_LEFT | MOD_CTRL) or base == (KEY_LEFT | MOD_ALT):
            self.wins[t].multi(OP_LEFT, 0, shift, word, none)
        elif base == KEY_RIGHT or base == (KEY_RIGHT | MOD_CTRL) or base == (KEY_RIGHT | MOD_ALT):
            self.wins[t].multi(OP_RIGHT, 0, shift, word, none)
        elif base == KEY_UP:
            self.wins[t].multi(OP_VERT, -1, shift, False, none)
        elif base == KEY_DOWN:
            self.wins[t].multi(OP_VERT, 1, shift, False, none)
        elif base == (KEY_UP | MOD_CTRL):
            self.wins[t].scroll(-1)
            return
        elif base == (KEY_DOWN | MOD_CTRL):
            self.wins[t].scroll(1)
            return
        elif base == KEY_PGUP:
            self.wins[t].collapse()
            self.wins[t].page(-1, shift)
        elif base == KEY_PGDN:
            self.wins[t].collapse()
            self.wins[t].page(1, shift)
        elif base == KEY_HOME:
            self.wins[t].multi(OP_HOME, 0, shift, False, none)
        elif base == KEY_END:
            self.wins[t].multi(OP_END, 0, shift, False, none)
        elif base == (KEY_HOME | MOD_CTRL):
            self.wins[t].collapse()
            self.wins[t].home(shift, True)
        elif base == (KEY_END | MOD_CTRL):
            self.wins[t].collapse()
            self.wins[t].end(shift, True)
        elif k == KEY_ENTER:
            self.wins[t].multi(OP_NEWLINE, 0, self.auto_indent, False, none)
        elif k == KEY_BACKSPACE:
            self.wins[t].multi(OP_BACK, 0, False, False, none)
        elif k == KEY_DELETE:
            self.wins[t].multi(OP_DEL, 0, False, False, none)
        elif k == KEY_TAB:
            self.wins[t].collapse()
            self.wins[t].tab(False)
        elif k == (KEY_TAB | MOD_SHIFT):
            self.wins[t].collapse()
            self.wins[t].tab(True)
        elif k == KEY_INSERT:
            self.insert_mode = not self.insert_mode
        elif k == KEY_ESC:
            if self.wins[t].has_multi():
                self.wins[t].collapse()         # first Esc: back to one cursor
            else:
                self.wins[t].sel = False
                self.wins[t].clear_highlight()
        elif k < K_BASE and k >= 32:
            self.wins[t].multi(OP_TYPE, k, self.insert_mode, False, none)
        self.wins[t].follow = True

    def window_at(self, x: Int, y: Int) -> Int:
        var i = len(self.wins) - 1
        while i >= 0:
            if self.wins[i].contains(x, y):
                return i
            i -= 1
        return -1
