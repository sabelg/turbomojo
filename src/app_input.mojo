"""Keyboard and paste input routing."""
from responsive import too_small
from std.collections import List, Dict
from std.time import perf_counter_ns
from std.ffi import external_call
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, EV_FOCUS, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from palette import Palette, theme, THEME_COUNT
from highlight import Highlighter
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_HEX, WK_MDPREVIEW, WK_GITLOG, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, WK_DIFF, WK_BLAME, WK_EXPLAIN, WK_DOCPANE, WK_PANEL, WK_GIT, WK_GPU, WK_CODEGEN, ACT_OTHER, ACT_TYPE
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
from app_agent import *
from app_problems import *
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
from app_gitdiff import *
from app_gitcmd import *
from app_explain import *
from app_docpane import *
from app_keybox import *
from app_tips import *
from app_plugins import *
from app_jobs import *
from app_mouse import *
from app_draw import *
from app_vim import *
from app_gpu import *
from app_codegen import *


__extension App:
    # ================================================================ input
    def handle(mut self, e: Event) raises:
        var recording = self.macro_rec and not self.macro_playing and e.kind != EV_MOUSE and e.kind != EV_FOCUS and self.mode != M_MENU
        var at = len(self.macro)
        if recording:
            if self.chord == 0:
                self.macro_cmd_start = at       # a new key, or the first key of a sequence
            self.macro.append(e.copy())
        self.macro_key_live = recording
        var prev_until = self.status_until
        self.event_seq += 1
        self.handle_event(e)
        self.macro_key_live = False
        self.sync_shared_buffers()
        self.sig_follow()
        self.layout_sync()
        self.explain_fit()
        if self.reader and self.mode == M_NORMAL and self.status_until == prev_until:
            _ = self.announce_reader_context()
        if recording and self.mode == M_MENU and len(self.macro) > at:
            # the key opened a menu: what is chosen there is recorded as a command instead
            while len(self.macro) > at:
                _ = self.macro.pop()
        if self.macro_rec and len(self.macro) >= MACRO_MAX:
            self.macro_rec = False
            self.say("Macro recording stopped: too long")
        self.theme_preview()
        if self.mode == M_DIALOG and self.dlg.kind == D_PALETTE:
            self.quick_refresh()
        if self.mode == M_DIALOG and self.dlg.kind == D_DOCFIND:
            self.docs_find_refresh()
        if self.mode == M_DIALOG and (self.dlg.kind == D_FIND or self.dlg.kind == D_REPLACE):
            self.find_refresh()

    def handle_event(mut self, e: Event) raises:
        if e.kind == EV_FOCUS:
            self.focused = e.key == 1           # (the next frame is drawn dimmed or not)
            if self.focused:
                self.background_recheck(True)   # (its colours may have changed meanwhile)
            return
        if too_small(self.scr.w, self.scr.h):
            # nothing to see: nothing is typed or clicked anywhere; only quitting works
            if e.kind == EV_KEY and self.reg.find_key(e.key) == CM_QUIT:
                self.exec(CM_QUIT)
            return
        if e.kind == EV_MOUSE:
            self.handle_mouse(e)
            return
        if e.kind == EV_PASTE:
            if self.mode == M_DIALOG:
                var fi = self.dlg.focus_field()
                if fi >= 0:
                    self.dlg.field_key_insert(fi, e.text)
                return
            if self.mode == M_NORMAL and self.term_paste(e.text):
                return
            if self.mode == M_NORMAL and self.agent_paste(e.text):
                return
            self.mode = M_NORMAL
            var t_paste = self.top()
            if t_paste >= 0 and (self.wins[t_paste].read_only or self.wins[t_paste].kind == WK_HEX):
                self.say("Buffer is read-only")
                return
            var ai = self.active_editor()
            if ai >= 0:
                self.wins[ai].paste_multi(e.text)
            return
        self.handle_key(e.key)

    def handle_key(mut self, k: Int) raises:
        if self.mode == M_DOCS:
            self.docs_key(k)
            return
        if self.mode == M_DIALOG:
            self.dialog_key(k)
            return
        if self.mode == M_MENU:
            self.menu_key(k)
            return
        if self.mode == M_COMPLETE:
            if self.complete_key(k):
                return
        if self.mode == M_HOVER:
            if self.hover_key(k):
                return
        if self.mode == M_PEEK:
            if self.peek_key(k):
                return
        if self.mode == M_NORMAL and self.chord == 0 and self.term_key(k):
            return                              # a terminal in front has the keyboard
        if self.mode == M_NORMAL and self.chord == 0 and self.agent_key(k):
            return                              # so has the agent panel's prompt
        if self.mode == M_NORMAL and self.sig_on and k == KEY_ESC and self.chord == 0:
            self.sig_close()                    # Esc takes the parameter tip away first
            return
        if self.mode == M_NORMAL and self.sig_on and self.chord == 0 and (k == (KEY_UP | MOD_ALT) or k == (KEY_DOWN | MOD_ALT)):
            if self.sig_cycle(-1 if k == (KEY_UP | MOD_ALT) else 1):
                return
        if self.chord != 0:
            # the second key of a sequence such as Ctrl-K S
            var first = self.chord
            self.chord = 0
            self.chord_box = False
            if k == KEY_ESC:
                self.say("")
                return
            var ccmd = self.reg.find_chord(first, k)
            if ccmd != CM_NONE:
                self.say("")
                self.key_used(ccmd)
                self.exec(ccmd)
            else:
                self.say(key_name(first) + " " + key_name(k) + " is not a command")
            return
        if self.reg.is_prefix(k):
            self.chord = k
            self.chord_since = now_ns()
            self.chord_box = False
            self.say(key_name(k) + " ...")
            if self.reader and self.key_hints:
                self.say(self.chord_line(k))     # (a screen reader: the keys on the status line at once)
            return
        if k == fkey(10):
            self.open_menu(1)
            return
        if self.vim_key(k):
            return                              # vim's Normal and Visual keys (Phase 12)
        var cmd = self.shortcut(k)
        if cmd != CM_NONE:
            self.key_used(cmd)
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
            var m = self.menu_for_letter(hot_key(c))
            if c == 32:
                m = 0
            if m >= 0:
                self.open_menu(m)
            return
        var t = self.top()
        if t < 0:
            return
        if self.wins[t].kind != WK_EDITOR:
            self.message_key(k)             # the Message and Outline windows: lists
            return
        self.editor_key(k)

    def message_key(mut self, k: Int) raises:
        var t = self.top()
        if self.wins[t].kind == WK_GITLOG and self.git_log_key(k):
            return
        if self.wins[t].kind == WK_TESTS and self.tests_key(k):
            return
        if self.wins[t].kind == WK_DIFF and self.git_diff_key(k):
            return
        if self.wins[t].kind == WK_BLAME and self.git_blame_key(k):
            return
        if self.wins[t].kind == WK_GIT and self.git_status_key(k):
            return
        if self.wins[t].kind == WK_GPU and self.gpuwin_key(k):
            return
        if self.wins[t].kind == WK_CODEGEN and self.codegen_key(k):
            return
        if self.wins[t].kind == WK_EXPLAIN and self.explain_key(k):
            return
        if self.wins[t].kind == WK_DOCPANE and self.docpane_key_event(k):
            return
        if self.wins[t].kind == WK_PANEL and self.panel_key(k):
            return
        if self.wins[t].kind == WK_EXPLORER and self.explorer_key(k):
            return
        if self.wins[t].kind == WK_MESSAGE and self.panel_filter_key(k):
            return
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
        elif (k == KEY_LEFT or k == KEY_RIGHT) and self.wins[t].kind == WK_MESSAGE:
            self.panel_show((self.msg_page + (1 if k == KEY_RIGHT else PG_COUNT - 1)) % PG_COUNT)
            return
        elif self.wins[t].kind == WK_CPU and (k == 103 or k == 71 or k == 118 or k == 86 or k == 43 or k == 45 or k == 91 or k == 93 or k == 98 or k == 66 or k == KEY_ENTER):
            self.cpuwin_key(k)
            return
        elif self.wins[t].kind == WK_DEBUG and (k == KEY_ENTER or k == 32 or k == KEY_RIGHT or k == KEY_LEFT or k == 61 or k == KEY_DELETE or k == 119 or k == 87):
            self.debugwin_key(k, self.wins[t].cr)
            return
        elif (k == KEY_ENTER or k == 32) and self.wins[t].kind == WK_OUTLINE:
            self.outline_go(self.wins[t].cr)
            return
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
        self.typed_ns = now_ns()                # (toasts wait while the editor has the keys)
        self.tip_feed(self.tip_kind_of_key(k))
        var t = self.top()
        if self.wins[t].read_only and (
            k == KEY_ENTER
            or k == KEY_BACKSPACE
            or k == (KEY_BACKSPACE | MOD_CTRL)
            or k == KEY_DELETE
            or k == KEY_TAB
            or k == (KEY_TAB | MOD_SHIFT)
            or (k < K_BASE and k >= 32 and (k & (MOD_CTRL | MOD_ALT)) == 0)
        ):
            self.say("Buffer is read-only")
            return
        var shift = (k & MOD_SHIFT) != 0
        var ctl = (k & MOD_CTRL) != 0
        var base = k & ~MOD_SHIFT
        var none = List[Int]()
        var word = ctl or (k & MOD_ALT) != 0
        if shift and ctl and (k & MOD_ALT) != 0:
            # Ctrl+Shift+Alt+arrows: column (box) selection
            var arrow = k & ~(MOD_SHIFT | MOD_CTRL | MOD_ALT)
            if arrow == KEY_UP or arrow == KEY_DOWN or arrow == KEY_LEFT or arrow == KEY_RIGHT:
                var dr = -1 if arrow == KEY_UP else (1 if arrow == KEY_DOWN else 0)
                var dv = -1 if arrow == KEY_LEFT else (1 if arrow == KEY_RIGHT else 0)
                self.wins[t].box_extend(dr, dv)
                if self.wins[t].has_multi():
                    self.say(String(self.wins[t].cursor_count()) + " lines in the column selection")
                return
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
        elif k == (KEY_BACKSPACE | MOD_CTRL):
            # delete the word to the left (terminals with the kitty protocol report this key)
            self.wins[t].multi(OP_DEL_WORD_LEFT, 0, False, False, none)
        elif k == KEY_DELETE:
            self.wins[t].multi(OP_DEL, 0, False, False, none)
        elif k == KEY_TAB:
            if self.snip_jump(t, False):
                return
            self.wins[t].tab_multi(False)
        elif k == (KEY_TAB | MOD_SHIFT):
            if self.snip_jump(t, True):
                return
            self.wins[t].tab_multi(True)
        elif k == KEY_INSERT:
            self.insert_mode = not self.insert_mode
        elif k == KEY_ESC:
            self.snip_clear()
            if self.wins[t].has_multi():
                self.wins[t].collapse()         # first Esc: back to one cursor
            else:
                self.wins[t].sel = False
                self.wins[t].clear_highlight()
        elif k < K_BASE and k >= 32:
            self.wins[t].multi(OP_TYPE, k, self.insert_mode, False, none)
            self.maybe_trigger_completion(k)
            self.maybe_trigger_signature(k)
        self.wins[t].follow = True

    def window_at(self, x: Int, y: Int) -> Int:
        var i = len(self.wins) - 1
        while i >= 0:
            if self.wins[i].contains(x, y) and not self.wins[i].hidden:
                return i
            i -= 1
        return -1
