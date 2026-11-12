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
from app_problems import *
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
from session import *
from filestate import content_hash
from app_explorer import *
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from outline import *
from symindex import *
from docs import *
from watch import file_sig
from app_input import *
from app_mouse import *
from app_draw import *


comptime SESSION_SAVE_MS = 30000


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
        var dpi = self.docpane_index()
        if dpi >= 0 and self.wins[dpi].x >= 20 and self.wins[dpi].x < w:
            w = self.wins[dpi].x
        var x0 = 0
        var xi = self.explorer_index()
        if xi >= 0 and w - self.wins[xi].w >= 20:
            x0 = self.wins[xi].w
        self.lay.place(x0, 1, w - x0, h)
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
                        self.wins[i].x = x0
                        self.wins[i].y = 1
                        self.wins[i].w = w - x0
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
        var t0 = self.top()
        if t0 >= 0 and self.wins[t0].kind != WK_EDITOR and (cmd == CM_PANE_GROW or cmd == CM_PANE_SHRINK or cmd == CM_NEXT_TAB or cmd == CM_PREV_TAB):
            self.panel_command(cmd)             # the bottom panel or the Outline window has the keyboard
            return
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
            # the shown tab in [brackets] as well as in other colours (not colour alone)
            labels.append(("[" + t + "]") if len(labels) == self.lay.active[g] else (" " + t + " "))
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

    # ============================================== the bottom panel's pages
    def panel_keep(mut self):
        """Remember what the page that is showing holds."""
        var mi = self.msg_index()
        if mi < 0:
            return
        var p = self.msg_page
        self.pg_text[p] = self.wins[mi].buf.all_text()
        self.pg_errs[p] = self.errs.copy()
        self.pg_idx[p] = self.err_idx
        self.pg_cr[p] = self.wins[mi].cr
        self.pg_search[p] = self.errs_from_search

    def panel_page(mut self, page: Int):
        """Turn the bottom panel to a page: what the present page holds is kept, the
        other page's text and places come back. (Opens the panel if it is closed.)"""
        var mi = self.ensure_msg()
        if page == self.msg_page or page < 0 or page >= PG_COUNT:
            return
        self.panel_keep()
        self.msg_page = page
        self.wins[mi].buf.load(self.pg_text[page])
        self.wins[mi].buf.modified = False
        self.errs = self.pg_errs[page].copy()
        self.err_idx = self.pg_idx[page]
        self.errs_from_search = self.pg_search[page]
        self.wins[mi].cr = max(0, min(self.pg_cr[page], self.wins[mi].buf.count() - 1))
        self.wins[mi].top = 0
        self.wins[mi].cc = 0
        self.wins[mi].follow = True

    def panel_write(mut self, page: Int):
        """A build, a search or a list of places is about to fill `page`: show it, and
        keep it showing when problems are reported meanwhile."""
        self.panel_page(page)
        self.panel_pinned = True

    def panel_show(mut self, page: Int):
        """The user asks for a page."""
        self.panel_page(page)
        self.panel_pinned = page != PG_PROBLEMS
        if page == PG_PROBLEMS:
            self.problems_show(False)       # always current: server, build and tests
            return
        var mi = self.msg_index()
        if mi >= 0 and self.wins[mi].buf.count() == 1 and self.wins[mi].buf.llen(0) == 0:
            var what = String("No compiler or program output yet")
            if page == PG_SEARCH:
                what = "No search results yet (" + self.reg.key_label(CM_FINDFILES) + " searches the project)"
            elif page == PG_PROBLEMS:
                what = "No problems reported (" + self.reg.key_label(CM_LSP) + " starts the language server)"
            self.wins[mi].buf.load(decode(what))
            self.wins[mi].buf.modified = False

    def panel_command(mut self, cmd: Int):
        """Next / previous tab and grow / shrink while the bottom panel or the Outline
        window has the keyboard."""
        var t = self.top()
        if cmd == CM_NEXT_TAB or cmd == CM_PREV_TAB:
            if self.wins[t].kind == WK_MESSAGE:
                self.panel_show((self.msg_page + (1 if cmd == CM_NEXT_TAB else PG_COUNT - 1)) % PG_COUNT)
            return
        var grow = cmd == CM_PANE_GROW
        if self.wins[t].kind == WK_EXPLORER:
            var w = self.wins[t].w + (4 if grow else -4)
            w = max(16, min(w, self.scr.w - 24))
            if w == self.wins[t].w:
                self.say("The panel cannot be made " + ("wider" if grow else "narrower"))
                return
            self.wins[t].w = w
        elif self.wins[t].kind == WK_MESSAGE:
            var h = self.wins[t].h + (2 if grow else -2)
            h = max(4, min(h, self.desk_h() - 6))
            if h == self.wins[t].h:
                self.say("The panel cannot be made " + ("higher" if grow else "lower"))
                return
            self.wins[t].y = 1 + self.desk_h() - h
            self.wins[t].h = h
        else:
            var w = self.wins[t].w + (4 if grow else -4)
            w = max(16, min(w, self.scr.w - 24))
            if w == self.wins[t].w:
                self.say("The panel cannot be made " + ("wider" if grow else "narrower"))
                return
            self.wins[t].x = self.scr.w - w
            self.wins[t].w = w
        self.layout_sync()

    def draw_pages(mut self, i: Int, active: Bool):
        """The bottom panel's pages as tabs in its top border."""
        var p = self.pal.copy()
        var fg = p.msg_frame if active else p.frame_inact
        var bg = p.msg_bg
        var y = self.wins[i].y
        var names = [String("Message"), String("Search"), problems_tab(self.prob_counts[0], self.prob_counts[1], self.prob_counts[2])]
        var x0 = self.wins[i].x + 6
        var x1 = self.wins[i].x + self.wins[i].w - 6
        var total = 0
        for nm in names:
            total += cp_len(nm) + 3
        if x1 - x0 < total:
            names[2] = "Problems"               # (narrow: the counts give way first)
            total = 0
            for nm in names:
                total += cp_len(nm) + 3
        if x1 - x0 < total:
            return                              # too narrow: the plain title stays
        for x in range(x0, x1):
            self.scr.put(x, y, 0x2550 if active else 0x2500, fg, bg)
        var x = x0 + max(0, (x1 - x0 - total) // 2)
        for k in range(len(names)):
            var a = x
            if k == self.msg_page:
                x = self.scr.text(x, y, " " + names[k] + " ", bg, fg)
            else:
                x = self.scr.text(x, y, " " + names[k] + " ", fg, bg)
            self.tab_x0.append(a)
            self.tab_x1.append(x)
            self.tab_y.append(y)
            self.tab_wid.append(-(k + 1))
            if k + 1 < len(names):
                self.scr.put(x, y, 0x2502, fg, bg)
                x += 1

    # ============================================================== sessions
    def session_path(self) -> String:
        """The session file of this project ('' if sessions are not kept)."""
        if self.session_dir.byte_length() == 0:
            return ""
        var h = content_hash(str_bytes(self.symidx_root()))
        var digits = "0123456789abcdef"
        var name = String("")
        for _ in range(16):
            name = String(digits[byte=h % 16:h % 16 + 1]) + name
            h = h // 16
        return self.session_dir + "/" + name + ".session"

    def session_capture(mut self) -> SessionData:
        """What is open now: files with a name, back to front, and the arrangement."""
        self.layout_sync()
        var d = SessionData()
        d.root = self.symidx_root()
        d.tiled = self.tiled
        var wids = List[Int]()              # wid of each saved file, by position
        for i in range(len(self.wins)):
            if self.wins[i].kind != WK_EDITOR or self.wins[i].path.byte_length() == 0:
                continue
            var f = SessionFile(self.wins[i].path)
            f.cr = self.wins[i].cr
            f.cc = self.wins[i].cc
            f.top = self.wins[i].top
            f.x = self.wins[i].x
            f.y = self.wins[i].y
            f.w = self.wins[i].w
            f.h = self.wins[i].h
            f.zoomed = self.wins[i].zoomed
            d.files.append(f^)
            wids.append(self.wins[i].wid)
        if self.tiled:
            # the tree with positions in the list instead of window ids
            var l = self.lay.copy()
            for id in l.ids():
                if not (id in wids):
                    l.remove(id)            # an unnamed window: not part of a session
            for g in l.groups():
                for k in range(len(l.tabs[g])):
                    for q in range(len(wids)):
                        if wids[q] == l.tabs[g][k]:
                            l.tabs[g][k] = q
                            break
            d.layout = l.encode()
        var xi = self.explorer_index()
        if xi >= 0:
            d.explorer = True
            d.explorer_w = self.wins[xi].w
            d.opened = self.ex.opened.copy()
        d.outline = self.outline_index() >= 0
        var mi = self.msg_index()
        if mi >= 0:
            d.panel = True
            d.panel_page = self.msg_page
            d.panel_h = self.wins[mi].h
        return d^

    def session_save(mut self):
        """Write the session if sessions are kept and something changed."""
        var path = self.session_path()
        if path.byte_length() == 0:
            return
        var text = self.session_capture().encode()
        if text == self.session_saved:
            return
        if not path_exists(self.session_dir):
            _ = run_system("mkdir -p " + shell_quote(self.session_dir))
        if write_file(path, str_bytes(text)):
            self.session_saved = text

    def session_tick(mut self, now: Int):
        """Every half minute the session is written, so that a crash or a closed
        terminal loses little."""
        if self.session_dir.byte_length() == 0 or now - self.session_checked_ns < SESSION_SAVE_MS * 1000000:
            return
        self.session_checked_ns = now
        self.session_save()

    def session_restore(mut self) raises -> Bool:
        """Open what the project's session names. True if at least one file was opened.
        Files that are gone are left out; a session of another folder, a damaged file,
        or none at all leave everything as it is."""
        var path = self.session_path()
        if path.byte_length() == 0 or not path_exists(path):
            return False
        var text = read_text(path)
        var got = session_decode(text)
        if not got[1] or got[0].root != self.symidx_root():
            return False
        var d = got[0].copy()
        var wid_of = List[Int]()            # per saved file: the window it got (0 = not opened)
        var opened = 0
        self.restoring = True
        for f in d.files:
            var wid = 0
            if path_exists(f.path) and not is_dir(f.path):
                try:
                    self.open_path(f.path)
                    var t = self.top()
                    if self.wins[t].kind == WK_EDITOR and self.wins[t].path == f.path:
                        self.wins[t].goto(f.cr, f.cc)
                        self.wins[t].top = max(0, min(f.top, self.wins[t].buf.count() - 1))
                        if not d.tiled and not self.tiled and f.w >= 16 and f.h >= 4:
                            self.wins[t].x = f.x
                            self.wins[t].y = max(1, f.y)
                            self.wins[t].w = f.w
                            self.wins[t].h = f.h
                            self.wins[t].zoomed = f.zoomed
                        wid = self.wins[t].wid
                        opened += 1
                except e:
                    wid = 0
            wid_of.append(wid)
        self.restoring = False
        if opened == 0:
            return False
        # the arrangement: only if the layout in use is the one the session was saved in
        if self.tiled and d.tiled and d.layout.byte_length() > 0:
            var l = layout_decode(d.layout)
            for id in l.ids():
                if id >= len(wid_of) or wid_of[id] == 0:
                    l.remove(id)
            for g in l.groups():
                for k in range(len(l.tabs[g])):
                    l.tabs[g][k] = wid_of[l.tabs[g][k]]
            self.lay = l^
            # the window in front is the one the current pane shows
            var front = self.win_by_wid(self.lay.shown(self.lay.cur))
            if front >= 0:
                self.focus(front)
        var keep = self.top_editor()
        var keep_path = self.wins[keep].path if keep >= 0 else String("")
        if d.panel:
            self.panel_show(max(0, min(d.panel_page, PG_COUNT - 1)))
            var mi = self.msg_index()
            if mi >= 0 and d.panel_h >= 4 and d.panel_h <= self.desk_h() - 6:
                self.wins[mi].y = 1 + self.desk_h() - d.panel_h
                self.wins[mi].h = d.panel_h
        if d.outline and self.outline_index() < 0:
            self.outline_toggle()
        if d.explorer and self.explorer_index() < 0:
            self.explorer_toggle()
            var xi = self.explorer_index()
            if xi >= 0:
                if d.explorer_w >= 16 and d.explorer_w <= self.scr.w - 24:
                    self.wins[xi].w = d.explorer_w
                for o in d.opened:
                    if is_dir(o) and not self.ex.is_open(o):
                        self.ex.opened.append(o)
                self.explorer_refresh(keep_path)
        var back = self.find_editor(keep_path)
        if back >= 0:
            self.focus(back)
        self.layout_sync()
        self.session_saved = self.session_capture().encode()
        self.say("Session restored: " + count_of(opened, "file"))
        return True
