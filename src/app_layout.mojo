"""The tiled layout in the application: panes with tabs that share the screen."""
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
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, ACT_OTHER, ACT_TYPE
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
from markdown import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_jobs import *
from app_pickers import *
from app_nav import *
from app_outline import *
from layout import *
from outline import *
from symindex import *
from docs import *
from watch import file_sig
from app_input import *
from app_mouse import *
from app_draw import *


__extension App:
    def win_by_wid(self, wid: Int) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].wid == wid and wid != 0:
                return i
        return -1

    def layout_sync(mut self):
        """Bring the layout tree and the windows into step (tiled layout only): windows
        that went leave the tree, new ones become tabs of the current pane, the editor
        in front is the tab its pane shows, and every window gets its pane's place.
        Called after every event and before drawing, so no other code has to know."""
        if not self.tiled:
            return
        var ids = List[Int]()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR:
                if self.wins[i].wid == 0:
                    self.wins[i].wid = self.next_wid
                    self.next_wid += 1
                ids.append(self.wins[i].wid)
        for id in self.lay.ids():
            if not (id in ids):
                self.lay.remove(id)
        for id in ids:
            if self.lay.group_of(id) < 0:
                self.lay.add(id)
        var te = self.top_editor()
        if te >= 0:
            self.lay.activate(self.wins[te].wid)
        # the room the panes share: the desktop less the Message and Outline windows
        var w = self.scr.w
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0 and self.wins[mi].y - 1 >= 6:
            h = self.wins[mi].y - 1
        var oi = self.outline_index()
        if oi >= 0 and self.wins[oi].x >= 20:
            w = self.wins[oi].x
        self.lay.place(0, 1, w, h)
        var zoomed = te >= 0 and self.wins[te].zoomed
        for g in self.lay.groups():
            var show = self.lay.shown(g)
            for id in self.lay.tabs[g]:
                var i = self.win_by_wid(id)
                if i < 0:
                    continue
                if zoomed:
                    self.wins[i].hidden = i != te
                    if i == te:
                        self.wins[i].x = 0
                        self.wins[i].y = 1
                        self.wins[i].w = w
                        self.wins[i].h = h
                    continue
                self.wins[i].hidden = id != show
                self.wins[i].x = self.lay.gx[g]
                self.wins[i].y = self.lay.gy[g]
                self.wins[i].w = self.lay.gw[g]
                self.wins[i].h = self.lay.gh[g]

    def layout_focus_shown(mut self):
        """Give the keyboard to the window the current pane shows."""
        var i = self.win_by_wid(self.lay.shown(self.lay.cur))
        if i >= 0:
            self.focus(i)
        self.layout_sync()

    def layout_command(mut self, cmd: Int):
        if cmd == CM_TILED:
            self.tiled = not self.tiled
            self.lay = Layout()
            for i in range(len(self.wins)):
                self.wins[i].hidden = False
                if self.wins[i].kind == WK_EDITOR:
                    self.wins[i].zoomed = False
            if self.tiled:
                self.layout_sync()
                self.say("Tiled layout: " + self.reg.key_label(CM_SPLIT_RIGHT) + " splits, " + self.reg.key_label(CM_NEXT_TAB) + " next tab, " + self.reg.key_label(CM_NEXT_PANE) + " next pane")
            else:
                self.arrange(False)
                self.say("Classic layout: overlapping windows")
            return
        if not self.tiled:
            self.say("This needs the tiled layout (Window > Tiled layout)")
            return
        self.layout_sync()
        if self.top_editor() < 0:
            return
        if self.top() != self.top_editor():
            self.focus(self.top_editor())       # from the Message or Outline window: back to the panes
        if cmd == CM_SPLIT_RIGHT or cmd == CM_SPLIT_DOWN:
            var why = self.lay.split(cmd == CM_SPLIT_RIGHT)
            if why.byte_length() > 0:
                self.say(why)
                return
            self.layout_focus_shown()
        elif cmd == CM_NEXT_PANE:
            if len(self.lay.groups()) < 2:
                self.say("There is only one pane")
                return
            self.lay.next_group(1)
            self.layout_focus_shown()
        elif cmd == CM_NEXT_TAB or cmd == CM_PREV_TAB:
            self.lay.next_tab(1 if cmd == CM_NEXT_TAB else -1)
            self.layout_focus_shown()
        elif cmd == CM_MOVE_TAB:
            if not self.lay.move_tab():
                self.say("There is no other pane to move it to")
                return
            self.layout_focus_shown()
        elif cmd == CM_PANE_GROW or cmd == CM_PANE_SHRINK:
            if not self.lay.resize(50 if cmd == CM_PANE_GROW else -50):
                self.say("The pane cannot be made " + ("larger" if cmd == CM_PANE_GROW else "smaller"))
            self.layout_sync()

    def draw_tabs(mut self, i: Int, active: Bool):
        """A pane with several files: their names in its top border, the shown one
        picked out. Where they stand is remembered for the mouse."""
        var g = self.lay.group_of(self.wins[i].wid)
        if g < 0 or len(self.lay.tabs[g]) < 2:
            return
        var p = self.pal.copy()
        var fg = p.frame_act if active else p.frame_inact
        var bg = p.ed_bg
        var y = self.wins[i].y
        var x0 = self.wins[i].x + 6                 # after the close box
        var x1 = self.wins[i].x + self.wins[i].w - 6    # before the zoom box
        if x1 - x0 < 8:
            return
        var labels = List[String]()
        for id in self.lay.tabs[g]:
            var wi = self.win_by_wid(id)
            var t = self.wins[wi].title if wi >= 0 else String("?")
            if wi >= 0 and self.wins[wi].buf.modified:
                t += "*"
            labels.append(" " + t + " ")
        var act = self.lay.active[g]
        # the first tab drawn: as far left as still lets the shown one fit
        var first = 0
        while first < act:
            var need = 0
            for k in range(first, act + 1):
                need += cp_len(labels[k]) + 1
            if need + (1 if first > 0 else 0) <= x1 - x0:
                break
            first += 1
        for x in range(x0, x1):
            self.scr.put(x, y, 0x2550 if active else 0x2500, fg, bg)
        var x = x0
        if first > 0:
            self.scr.put(x, y, 0x2039, fg, bg)      # more to the left
            x += 1
        for k in range(first, len(labels)):
            var wlen = cp_len(labels[k])
            if x + wlen > x1 - 1:
                if k == act:
                    # the shown tab alone is too long: cut it
                    var room = x1 - 1 - x
                    if room >= 4:
                        var a = x
                        x = self.scr.text(x, y, slice_str(decode(labels[k]), 0, room - 1) + "…", bg, fg)
                        self.tab_x0.append(a)
                        self.tab_x1.append(x)
                        self.tab_y.append(y)
                        self.tab_wid.append(self.lay.tabs[g][k])
                self.scr.put(x1 - 1, y, 0x203A, fg, bg)     # more to the right
                break
            var a = x
            if k == act:
                x = self.scr.text(x, y, labels[k], bg, fg)
            else:
                x = self.scr.text(x, y, labels[k], fg, bg)
            self.tab_x0.append(a)
            self.tab_x1.append(x)
            self.tab_y.append(y)
            self.tab_wid.append(self.lay.tabs[g][k])
            if k + 1 < len(labels) and x < x1 - 1:
                self.scr.put(x, y, 0x2502, fg, bg)
                x += 1
