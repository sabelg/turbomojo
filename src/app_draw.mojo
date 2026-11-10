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
from app_pickers import *
from app_nav import *
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
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
        # the problem on the cursor line, if the language server reported one, takes the
        # place of the key hints: it needs the room and matters more just then
        var problem = String("")
        var pe = self.top_editor()
        if pe >= 0 and pe == self.top() and self.mode == M_NORMAL and len(self.wins[pe].buf.marks) > 0:
            problem = self.wins[pe].buf.mark_text(self.wins[pe].cr)
        if problem.byte_length() > 0:
            var pc = decode(problem)
            var room = max(8, self.scr.w - 30)
            if len(pc) > room:
                problem = slice_str(pc, 0, room - 1) + "…"
            x = self.scr.text(x, y, problem, p.status_hot, p.status_bg) + 2
        else:
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
                if self.wins[ti].buf.encoding == ENC_LATIN1:
                    right += "Latin-1  "
                elif self.wins[ti].buf.bom:
                    right += "UTF-8 BOM  "
                if self.wins[ti].buf.mixed_eol:
                    right += "Mixed>"          # both kinds in the file; saving writes this one
                right += ("CRLF" if self.wins[ti].buf.crlf else "LF") + "  " + (("Tabs:" + String(self.wins[ti].buf.tab_width)) if self.wins[ti].buf.use_tabs else ("Spaces:" + String(self.wins[ti].buf.indent_size))) + "  "
            if self.lsp.active():
                right += "LSP  "
            right += "INS" if self.insert_mode else "OVR"
        if self.macro_rec:
            right = "● REC  " + right
        if self.job.active:
            var sp = decode(SPINNER)
            var b = List[UInt8]()
            encode_cp(sp[(now_ns() // (SPINNER_MS * 1000000)) % len(sp)], b)
            var what = "Building " if self.job.kind == JOB_BUILD else "Formatting "
            var subject = basename(self.job.path)
            if self.job.kind == JOB_TASK:
                what = "Task "
                subject = self.job.exe
            if self.job.kind == JOB_DOCS:
                what = "Downloading "
                subject = "documentation"
            var e = self.job_elapsed()
            right = bytes_to_str(b) + " " + what + subject + " " + String(Int(e)) + "." + String(Int(e * 10) % 10) + "s  ^F2 cancel  " + right
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
        self.layout_sync()
        self.scr.no_clip()
        self.scr.fill(0, 1, self.scr.w, self.scr.h - 2, p.desk_ch, p.desk_fg, p.desk_bg)
        var n = len(self.wins)
        for i in range(n):
            self.wins[i].gut = self.wins[i].gutter_for(self.line_numbers)
            self.wins[i].clustered = self.scr.clustered
            self.wins[i].auto_pairs = self.auto_pairs
            if len(self.wins[i].rulers) != len(self.rulers):
                self.wins[i].rulers = self.rulers.copy()
            if self.wins[i].follow:
                self.wins[i].ensure_visible()
                self.wins[i].follow = False
            # highlighter states for the visible rows (incremental; see Window.sync_lex)
            self.wins[i].buf.sync_folds()
            var last_shown = self.wins[i].top + self.wins[i].rows() + 1
            if len(self.wins[i].buf.folds) > 0:
                # folded blocks push later lines into view
                last_shown = self.wins[i].pos_at_screen_row(self.wins[i].rows()).r + 1
            self.wins[i].sync_lex(last_shown)
        self.tab_wid.clear()
        self.tab_x0.clear()
        self.tab_x1.clear()
        self.tab_y.clear()
        for i in range(n):
            if self.wins[i].hidden:
                continue
            self.draw_window(i, i == n - 1)
            if self.wins[i].kind == WK_MESSAGE:
                self.draw_pages(i, i == n - 1)
            if self.tiled and self.wins[i].kind == WK_EDITOR:
                self.draw_tabs(i, i == n - 1)
                continue                        # panes lie side by side: no shadow
            if i == n - 1 and self.wins[i].w < self.scr.w:
                self.scr.shadow(self.wins[i].x, self.wins[i].y, self.wins[i].w, self.wins[i].h, p.shadow_fg, p.shadow_bg)
        draw_menubar(self.scr, p, self.menus, self.menu_idx if self.mode == M_MENU else -1, clock_hm() if self.show_clock else "")
        # status line
        var items = List[String]()
        var cmds = List[Int]()
        if self.mode == M_DOCS:
            self.draw_docs()
            for h in self.docs_hints():
                items.append(h)
                cmds.append(CM_NONE)
        elif self.mode == M_MENU:
            items.append(self.menus[self.menu_idx].items[self.menu_item].hint)
            cmds.append(CM_NONE)
        elif self.mode == M_DIALOG:
            items.append("~Tab~ Next control")
            cmds.append(CM_NONE)
            items.append("~Enter~ Accept")
            cmds.append(CM_NONE)
            items.append("~Esc~ Cancel")
            cmds.append(CM_NONE)
        elif self.mode == M_HOVER:
            items.append("~↑↓~ Scroll")
            cmds.append(CM_NONE)
            items.append("~Esc~ Close")
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
            if t >= 0 and self.wins[t].kind == WK_EXPLORER:
                for h in ["~Enter~ Open", "~N~ New file", "~F~ Folder", "~R~ Rename", "~M~ Move", "~Del~ Trash"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_OUTLINE:
                items.append("~Enter~ Go to symbol")
                cmds.append(CM_NONE)
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
        if (self.mode == M_NORMAL or self.mode == M_COMPLETE or self.mode == M_HOVER) and t >= 0 and self.wins[t].kind == WK_EDITOR:
            var cell = self.wins[t].cursor_cell()
            var cx = cell.c
            var cy = cell.r
            if cx > self.wins[t].x and cx < self.wins[t].x + self.wins[t].w - 1 and cy > self.wins[t].y and cy < self.wins[t].y + self.wins[t].h - 1:
                self.scr.cx = cx
                self.scr.cy = cy
                self.scr.cvis = True
                self.scr.cblock = not self.insert_mode
            if self.sig_on and self.mode != M_HOVER and self.wins[t].path == self.sig_path:
                self.draw_signature(cx, cy)
            if self.mode == M_COMPLETE:
                self.draw_completion(cx, cy)
            if self.mode == M_HOVER:
                self.draw_hover(cx, cy)
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
        """The completion popup under (or above) the cursor: a tag for the kind of each
        item, its name and, dimmed, its signature or type; beside it a panel with the
        selected item's details and documentation when there are any."""
        var p = self.pal.copy()
        var n = len(self.comp_items)
        if n == 0:
            return
        var h = min(8, n)
        var topi = max(0, min(self.comp_sel - h + 1, n - h))
        if self.comp_sel < topi:
            topi = self.comp_sel
        var tags = False
        var label_w = 10
        var detail_w = 0
        for k in range(n):
            if self.comp_kind[k] >= 0:
                tags = True
            label_w = max(label_w, cp_len(self.comp_items[k]))
        for k in range(topi, topi + h):
            detail_w = max(detail_w, cp_len(self.comp_detail[k]))
        label_w = min(label_w, 36)
        detail_w = min(detail_w, max(0, 58 - label_w))
        var tag_w = 4 if tags else 0
        var w = 1 + tag_w + label_w + (2 + detail_w if detail_w > 0 else 0) + 1
        w = min(w, self.scr.w - 2)
        var ai = self.top()
        var plen = self.wins[ai].cc - self.comp_start
        var x = max(0, min(cx - plen - 1 - tag_w, self.scr.w - w - 2))
        var y = cy + 1
        if y + h > self.scr.h - 1:
            y = cy - h
        for r in range(h):
            var k = topi + r
            var sel = k == self.comp_sel
            var fg = p.list_sel_fg if sel else p.list_fg
            var bg = p.list_sel_bg if sel else p.list_bg
            self.scr.fill(x, y + r, w, 1, 32, fg, bg)
            self.scr.clip(x, y + r, w, 1)
            if tags:
                var tag = kind_tag(self.comp_kind[k]) if self.comp_kind[k] >= 0 else String("abc")
                _ = self.scr.text(x + 1, y + r, tag, fg if sel else p.gutter_fg, bg)
            _ = self.scr.text(x + 1 + tag_w, y + r, self.comp_items[k], fg, bg)
            if detail_w > 0 and self.comp_detail[k].byte_length() > 0:
                _ = self.scr.text(x + 1 + tag_w + label_w + 2, y + r, self.comp_detail[k], fg if sel else p.gutter_fg, bg)
            self.scr.no_clip()
        self.scr.shadow(x, y, w, h, p.shadow_fg, p.shadow_bg)
        # ---- details of the selected item
        var k = self.comp_sel
        var info = String(self.comp_detail[k])
        if self.comp_doc[k].byte_length() > 0:
            info += ("\n\n" if info.byte_length() > 0 else "") + self.comp_doc[k]
        if info.byte_length() == 0 or (self.comp_doc[k].byte_length() == 0 and cp_len(self.comp_detail[k]) <= detail_w):
            return                          # nothing the list row does not already show
        var pw = min(44, self.scr.w - (x + w) - 3)
        var px = x + w + 1
        if pw < 20:
            # no room on the right: try the left side
            pw = min(44, x - 2)
            px = x - pw - 1
        if pw < 20:
            return
        # the signature as code, the documentation as the Markdown it usually is
        var source = String("")
        if self.comp_detail[k].byte_length() > 0:
            source = "```mojo\n" + self.comp_detail[k] + "\n```\n"
        source += self.comp_doc[k]
        var lines = md_render(source, pw - 2, self.hl)
        var ph = min(len(lines), 10)
        var py = y
        if py + ph > self.scr.h - 1:
            py = max(1, self.scr.h - 1 - ph)
        self.draw_md(px, py, pw, ph, lines, 0)
        self.scr.shadow(px, py, pw, ph, p.shadow_fg, p.shadow_bg)

    def draw_md(mut self, x: Int, y: Int, w: Int, h: Int, lines: List[MdLine], first: Int):
        """Rendered Markdown in a box: lines `first`.. of `lines`, one column of margin
        on each side. Code block lines are shown on the editor's background with its
        syntax colours; links are underlined."""
        var p = self.pal.copy()
        self.scr.fill(x, y, w, h, 32, p.doc_fg, p.doc_bg)
        self.scr.clip(x, y, w, h)
        for r in range(h):
            var k = first + r
            if k >= len(lines):
                break
            var block = len(lines[k].st) > 0 and lines[k].st[0] >= MD_BLOCK
            if block:
                self.scr.fill(x + 1, y + r, w - 2, 1, 32, p.ed_fg, p.ed_bg)
            var xx = x + 1
            for q in range(len(lines[k].cps)):
                if xx >= x + w - 1:
                    break
                var st = lines[k].st[q]
                var fg = p.doc_fg
                var bg = p.doc_bg
                if st >= MD_BLOCK:
                    fg = p.syn[st - MD_BLOCK]
                    bg = p.ed_bg
                elif st == MD_BOLD or st == MD_HEAD:
                    fg = p.doc_bold
                elif st == MD_CODE:
                    fg = p.doc_code
                elif st == MD_ITALIC or st == MD_DIM:
                    fg = p.doc_dim
                var at = xx
                xx = self.scr.draw_cp(xx, y + r, lines[k].cps[q], fg, bg)
                if (st == MD_LINK or st < 0) and xx > at:
                    self.scr.underline(at, y + r, False, p.doc_fg)
        self.scr.no_clip()

    def draw_signature(mut self, cx: Int, cy: Int):
        """The parameter tip: the signature of the call being typed on the row above the
        cursor (below if there is none), the parameter being typed picked out. With
        several signatures "1/3" stands in front. Documentation of the parameter, if
        the server sent any, follows on up to three more lines."""
        var p = self.pal.copy()
        var head = List[Int]()
        if self.sigtip.count > 1:
            head = decode(String(self.sigtip.index + 1) + "/" + String(self.sigtip.count) + " ")
        var n = len(self.sigtip.label)
        var room = max(8, self.scr.w - 4 - len(head))        # cells for the signature
        # a signature too long for the screen is shown around the parameter being typed
        var first = 0
        var cols = 0
        for c in self.sigtip.label:
            cols += char_width(c)
        if cols > room and self.sigtip.b > room - 1:
            first = max(0, min(self.sigtip.a - 4, n - room))
            if self.sigtip.b - first > room:
                first = max(0, self.sigtip.a - 4)
        var docs = List[MdLine]()
        if self.sigtip.doc.byte_length() > 0:
            docs = md_render(self.sigtip.doc, max(20, min(60, self.scr.w - 6)), self.hl)
        var dh = min(3, len(docs))
        var w = min(cols, room) + len(head) + 2
        for k in range(dh):
            var dc = 0
            for c in docs[k].cps:
                dc += char_width(c)
            w = max(w, dc + 2)
        w = min(w, self.scr.w - 2)
        var h = 1 + dh
        var x = max(1, min(cx - 1, self.scr.w - w - 1))
        var y = cy - h
        if y < 1:
            y = cy + 1
        if dh > 0:
            self.draw_md(x, y + 1, w, dh, docs, 0)
        self.scr.fill(x, y, w, 1, 32, p.doc_fg, p.doc_bg)
        self.scr.clip(x, y, w, 1)
        var xx = x + 1
        for c in head:
            xx = self.scr.draw_cp(xx, y, c, p.doc_dim, p.doc_bg)
        if first > 0:
            xx = self.scr.draw_cp(xx, y, 0x2026, p.doc_dim, p.doc_bg)
            first += 1
        var q = first
        while q < n and xx < x + w - 1:
            var active = q >= self.sigtip.a and q < self.sigtip.b
            if xx == x + w - 2 and q < n - 1:
                _ = self.scr.draw_cp(xx, y, 0x2026, p.doc_dim, p.doc_bg)     # more to the right
                break
            var at = xx
            xx = self.scr.draw_cp(xx, y, self.sigtip.label[q], p.doc_bold if active else p.doc_fg, p.doc_bg)
            if active and xx > at:
                self.scr.underline(at, y, False, p.doc_bold)
            q += 1
        self.scr.no_clip()
        self.scr.shadow(x, y, w, h, p.shadow_fg, p.shadow_bg)

    def draw_hover(mut self, cx: Int, cy: Int):
        """The hover window: below the cursor line if there is room, else above."""
        var p = self.pal.copy()
        var n = len(self.hover_lines)
        if n == 0:
            return
        var w = 12
        for l in self.hover_lines:
            var cols = 0
            for c in l.cps:
                cols += char_width(c)
            w = max(w, cols + 2)
        w = min(w, self.scr.w - 4)
        var h = min(n, self.hover_page())
        var x = max(1, min(cx - 1, self.scr.w - w - 2))
        var y = cy + 1
        if y + h > self.scr.h - 1:
            y = max(1, cy - h)
        self.hover_scroll = max(0, min(self.hover_scroll, n - h))
        var shown = self.hover_lines.copy()
        self.draw_md(x, y, w, h, shown, self.hover_scroll)
        if self.hover_scroll + h < n:
            # there is more below
            self.scr.put(x + w - 2, y + h - 1, 0x25BC, p.doc_bold, p.doc_bg)
        if self.hover_scroll > 0:
            self.scr.put(x + w - 2, y, 0x25B2, p.doc_bold, p.doc_bg)
        self.scr.shadow(x, y, w, h, p.shadow_fg, p.shadow_bg)
