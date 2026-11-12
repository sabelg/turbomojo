"""Menu bar navigation."""
from dap import DS_STOPPED, DS_RUNNING
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
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, ACT_OTHER, ACT_TYPE
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
            self.key_echo(cmd)
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
                    self.key_echo(cmd)
                    return
        else:
            var cmd = self.shortcut(k)
            if cmd != CM_NONE:
                self.mode = M_NORMAL
                self.macro_note_cmd(cmd)
                self.key_used(cmd)
                self.exec(cmd)

    def cmd_unavailable(self, cmd: Int) -> Bool:
        """Commands that can do nothing now - shown dimmed in the menus, the command
        palette and the status line. Chosen anyway, each says why (as before)."""
        if cmd == CM_STEP_INTO or cmd == CM_STEP_OVER or cmd == CM_STEP_OUT:
            return self.dbg.state != DS_STOPPED
        if cmd == CM_PAUSE:
            return self.dbg.state != DS_RUNNING
        if cmd == CM_RESET:
            return not self.dbg.active()
        if cmd == CM_CANCEL:
            return not self.job.active and not self.fsearch.active and not self.dbg.active()
        if cmd == CM_NEXTERR or cmd == CM_PREVERR:
            return len(self.errs) == 0
        if cmd == CM_MACRO_PLAY:
            return len(self.macro) == 0 and not self.macro_rec
        var te = self.top_editor()
        if cmd == CM_UNDO:
            return te < 0 or len(self.wins[te].buf.undos) == 0
        if cmd == CM_REDO:
            return te < 0 or len(self.wins[te].buf.redos) == 0
        if cmd == CM_SAVE or cmd == CM_SAVEAS or cmd == CM_FORMAT or cmd == CM_GOTO or cmd == CM_COMMENT or cmd == CM_BP_TOGGLE:
            return te < 0
        return False

    def unavailable_cmds(self) -> List[Int]:
        """cmd_unavailable for every command of the menus (for drawing them)."""
        var out = List[Int]()
        for m in self.menus:
            for it in m.items:
                if it.cmd != CM_NONE and self.cmd_unavailable(it.cmd) and not (it.cmd in out):
                    out.append(it.cmd)
        return out^

    def toggle_cmds(self) -> List[Int]:
        """The commands that switch something on or off (checked() has those on)."""
        return [CM_LINENUM, CM_SCREEN_READER, CM_AUTOINDENT, CM_HLLINE, CM_CLOCK, CM_SHOWWS, CM_WRAP, CM_TILED, CM_SEMANTIC, CM_HINTS, CM_USETABS, CM_CRLF]

    def checked(self) -> List[Int]:
        var out = List[Int]()
        if self.line_numbers:
            out.append(CM_LINENUM)
        if self.reader:
            out.append(CM_SCREEN_READER)
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
        if self.tiled:
            out.append(CM_TILED)
        if self.semantic_on:
            out.append(CM_SEMANTIC)
        if self.hints_on:
            out.append(CM_HINTS)
        var ti = self.top_editor()
        if ti >= 0 and self.wins[ti].buf.use_tabs:
            out.append(CM_USETABS)
        if ti >= 0 and self.wins[ti].buf.crlf:
            out.append(CM_CRLF)
        if self.theme_idx < THEME_COUNT and self.theme_id != "auto":
            out.append(CM_THEME0 + self.theme_idx)
        out.append(CM_KEYMAP0 + self.keymap)
        return out^
