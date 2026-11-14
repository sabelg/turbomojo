"""Drawing the desktop, status line, cursor and popups."""
from std.collections import List, Dict
from std.time import perf_counter_ns
from vim import vim_mode_name, KEYMAP_VIM, VM_INSERT
from app_vimcmd import *
from std.ffi import external_call
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from palette import Palette, theme, THEME_COUNT
from contrast import text_muted, text_disabled, dimmed
from highlight import Highlighter
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, WK_DIFF, WK_BLAME, WK_AGENT, WK_EXPLAIN, WK_DOCPANE, WK_GIT, WK_GPU, WK_CODEGEN, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from responsive import too_small, too_small_lines, MINIMAP_MIN_W, CRUMBS_MIN_W, GUTTER_MIN_W
from outline import scan_outline, scope_path, breadcrumbs, sticky_rows
from app_gpu import *
from app_notify import *
from app_progress import *
from app_links import *
from app_agent import *
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
from app_plugins import *
from app_lspextra import *
from app_git import *
from app_jobs import *
from app_input import *
from app_mouse import *


def scanline_dim(rgb: Int) -> Int:
    """A background colour 22% darker (the dark line of a scanline)."""
    if rgb < 0 or rgb > 0xFFFFFF:
        return rgb                  # (a palette slot or the terminal's default: left alone)
    var r = ((rgb >> 16) & 255) * 78 // 100
    var g = ((rgb >> 8) & 255) * 78 // 100
    var b = (rgb & 255) * 78 // 100
    return (r << 16) | (g << 8) | b


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
                if self.cmd_unavailable(cmds[i]):
                    var dis = text_disabled(p, p.status_fg, p.status_bg)
                    x = self.scr.hot_text(x, y, items[i], dis, dis, p.status_bg)
                else:
                    x = self.scr.hot_text(x, y, items[i], p.status_fg, p.status_hot, p.status_bg)
                self.st_x0.append(x0)
                self.st_x1.append(x)
                self.st_cmd.append(cmds[i])
                x += 2
        var right = String("")
        var facts = False               # the file's facts and the modes: muted
        var running = len(self.running_tasks())
        var busy = ("⟳" + String(running) + "  ") if running > 0 else String("")   # Shift-F10 lists them
        if self.status_until > now_ns():
            right = busy + self.status
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
            if self.git.branch.byte_length() > 0 and self.scr.w >= 96:
                var gb = "git:" + self.git.branch
                if self.git.ahead > 0:
                    gb += "↑" + String(self.git.ahead)
                if self.git.behind > 0:
                    gb += "↓" + String(self.git.behind)
                right += gb + "  "
            if self.pixi_env.byte_length() > 0 and self.pixi_env != "default" and self.scr.w >= 96:
                right += "env:" + self.pixi_env + "  "
            if self.lsp.active() or self.extra_active():
                right += "LSP  "
            if self.dbg.active():
                right += self.debug_badge() + "  "
            right += self.plugins_status()       # the plugins' status items
            right += self.gpu_status_text()
            if self.keymap == KEYMAP_VIM:
                right += vim_mode_name(self.vim.mode)      # (Phase 12)
            else:
                right += "INS" if self.insert_mode else "OVR"
            right = busy + right
            facts = True

        if self.macro_rec:
            right = "● REC  " + right
        var prog = self.progress_status()           # (nothing in the first second)
        right = prog + right
        var rl = cp_len(right)
        var rx = self.scr.w - rl - 1
        if rx < x and prog.byte_length() > 0:
            # work in progress and its cancel key come before the key hints: the hints
            # it would cover give way (and are no longer clickable)
            rx = max(2, rx)
            while len(self.st_x1) > 0 and self.st_x1[len(self.st_x1) - 1] > rx - 3:
                _ = self.st_x0.pop()
                _ = self.st_x1.pop()
                _ = self.st_cmd.pop()
            var cut = self.st_x1[len(self.st_x1) - 1] if len(self.st_x1) > 0 else 0
            self.scr.fill(cut, y, self.scr.w - cut, 1, 32, p.status_fg, p.status_bg)
            x = cut
        if rx < x:
            rx = x
        if rx < self.scr.w:
            self.scr.clip(0, y, self.scr.w, 1)
            if rx > x:
                self.scr.put(rx - 2, y, 0x2502, p.status_fg, p.status_bg)
            if facts:
                # what is in progress and the macro mark stand out; the facts are muted
                var lead = cp_len(prog) + cp_len(busy) + (cp_len("● REC  ") if self.macro_rec else 0)
                var rc = decode(right)
                var xx = self.scr.text(rx, y, slice_str(rc, 0, lead), p.status_fg, p.status_bg)
                _ = self.scr.text(xx, y, slice_str(rc, lead, len(rc)), text_muted(p.status_fg, p.status_bg), p.status_bg)
            else:
                _ = self.scr.text(rx, y, right, p.status_fg, p.status_bg)
            self.scr.no_clip()

    def draw(mut self):
        var p = self.pal.copy()
        # the cursor: where this frame puts it (a terminal window's program, the
        # editor's caret, a dialog's field, else the focused row - reader_cursor)
        self.scr.cvis = False
        self.scr.fx = -1
        self.scr.fy = -1
        if too_small(self.scr.w, self.scr.h):
            self.draw_too_small()
            return
        self.layout_sync()
        self.explain_fit()
        self.bp_sync()              # files opened since show their breakpoints
        self.scr.no_clip()
        self.scr.fill(0, 1, self.scr.w, self.scr.h - 2, p.desk_ch, p.desk_fg, p.desk_bg)
        self.git_diff_refresh()
        self.scopes_stale = False
        var n = len(self.wins)
        for i in range(n):
            if self.wins[i].kind == WK_EDITOR:
                self.git_marks_update(i)
                self.scopes_update(i)
                if self.git_line_blame and i == self.top_editor() and self.wins[i].path.byte_length() > 0 and self.wins[i].path == self.git_inline_path and self.wins[i].cr < len(self.git_inline_rows):
                    ref br = self.git_inline_rows[self.wins[i].cr]
                    if is_uncommitted(br.sha):
                        self.wins[i].inline_blame = "You, uncommitted"
                    else:
                        var sum = br.summary
                        if cp_len(sum) > 40:
                            sum = slice_str(decode(sum), 0, 39) + "…"
                        self.wins[i].inline_blame = br.author + ", " + ymd(br.time) + (" • " + sum if sum.byte_length() > 0 else String(""))
                    self.wins[i].inline_blame_row = self.wins[i].cr
                else:
                    self.wins[i].inline_blame = ""
                    self.wins[i].inline_blame_row = -1
            if self.wins[i].kind == WK_AGENT:
                self.wins[i].title = self.agent_title()     # (before the frame is drawn)
            self.wins[i].gut = self.wins[i].gutter_for(self.line_numbers and self.wins[i].w >= GUTTER_MIN_W)
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
            if self.wins[i].kind == WK_TERM:
                self.term_draw(i)
            if self.wins[i].kind == WK_AGENT:
                self.agent_draw(i, i == n - 1)
                self.link_rows(i)               # file:line as hyperlinks (OSC 8)
            if self.wins[i].kind == WK_MESSAGE:
                self.draw_pages(i, i == n - 1)
                self.link_rows(i)
            if self.wins[i].kind == WK_DOCPANE and not self.reader:
                self.docpane_draw(i)
            if self.wins[i].kind == WK_EXPLAIN and not self.reader:
                self.explain_draw(i)
            if self.tiled and self.wins[i].kind == WK_EDITOR:
                self.draw_tabs(i, i == n - 1)
                continue                        # panes lie side by side: no shadow
            if i == n - 1 and self.wins[i].w < self.scr.w:
                self.scr.shadow(self.wins[i].x, self.wins[i].y, self.wins[i].w, self.wins[i].h, p.shadow_fg, p.shadow_bg)
        if not self.reader:
            self.draw_progress_box()            # beyond ten seconds (never takes the keys)
            self.draw_toasts()                  # (a screen reader gets them on the status line)
            self.draw_chord_box()
        draw_menubar(self.scr, p, self.menus, self.menu_idx if self.mode == M_MENU else -1, (self.clock_fixed if self.clock_fixed.byte_length() > 0 else clock_hm()) if self.show_clock and not self.reader else "")
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
                for h in ["~Enter~ Open", "~/~ Filter", "~N~ New file", "~F~ Folder", "~R~ Rename", "~M~ Move", "~Del~ Trash"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_CPU:
                for h in ["~F7~/~F8~ Step instruction", "~G~ Memory at", "~+~/~-~ Next/prev memory"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_MESSAGE and self.msg_page == PG_PROBLEMS:
                for h in ["~E~/~W~/~N~ Errors/warnings/notes", "~F~ This file", "~/~ Filter", "~C~ All", "~A~ Ask agent", "~?~ Docs"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_MESSAGE and self.msg_page == PG_MESSAGE:
                items.append("~/~ Filter")
                cmds.append(CM_NONE)
                if self.out_filtered:
                    items.append("~C~ All")
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_AGENT:
                for h in ["~Enter~ Send", "~Esc~ Stop / editor", "~PgUp~ Back", "@file:1-9 Mention"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_DOCPANE:
                for h in ["~Enter~ Open page", "~C~/~T~ Copy/Try", "~Esc~ Back to code", "~PgDn~ Read on"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_EXPLAIN:
                for h in ["~Esc~ Close", "~F6~ Code", "~C~/~T~ Copy/Try fix", "~A~ Ask agent", "~?~ Docs"]:
                    items.append(h)
                    cmds.append(CM_NONE)
                if self.explain_python():
                    items.append("~P~ Coming from Python")
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_BLAME:
                for h in ["~Enter~ Go to", "~Esc~ Close", self.git_blame_summary()]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_GIT:
                for h in ["~Enter~ Open", "~Space~ Stage/unstage", "~D~ Diff", "~C~ Commit", "~A~ Amend", "~B~ Branch", "~Z~ Stash", "~Esc~ Close"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_DIFF:
                var dh: List[String]
                if self.gd_proposal:
                    dh = ["~A~ Accept", "~S~ Accept all (session)", "~R~ Reject", "~V~ Split/Unified", "~Esc~ Later"]
                elif self.gd_staged:
                    dh = ["~U~ Unstage", "~V~ Split/Unified", "~Tab~ Changes", "~Esc~ Close"]
                else:
                    dh = ["~Enter~ Go to", "~S~ Stage", "~R~ Revert", "~V~ Split/Unified", "~Tab~ Staged", "~Esc~ Close"]
                for h in dh:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_TESTS:
                for h in ["~Enter~ Go to", "~R~ Run", "~A~ Run all", "~L~ List", "~T~ Find files"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_TERM:
                for h in ["~F6~ Back to the editor", "~Shift-PgUp~ Scroll back", "~Alt-F11~ Close", "drag: copy"]:
                    items.append(h)
                    cmds.append(CM_NONE)
            if t >= 0 and self.wins[t].kind == WK_DEBUG:
                for h in ["~Enter~ Open / go to frame", "~←~ Close", "~=~ Set value", "~Del~ Remove watch"]:
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
            draw_dropdown(self.scr, p, self.menus[self.menu_idx], self.menu_item, self.checked(), self.unavailable_cmds(), self.reader)
        # cursor
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
                self.scr.cbar = False
                if self.keymap == KEYMAP_VIM:
                    self.scr.cblock = self.vim.mode != VM_INSERT
                    self.scr.cbar = self.vim.mode == VM_INSERT
            if self.sig_on and self.mode != M_HOVER and self.wins[t].path == self.sig_path:
                self.draw_signature(cx, cy)
            if self.mode == M_COMPLETE:
                self.draw_completion(cx, cy)
            if self.mode == M_HOVER:
                self.draw_hover(cx, cy)
        if self.keymap == KEYMAP_VIM and self.vim.cl_on and self.mode == M_NORMAL:
            self.vim_draw_cmdline()                 # vim's command line over the status row
        if self.mode == M_NORMAL and t >= 0 and self.wins[t].kind == WK_AGENT:
            self.agent_cursor(t)
        if self.mode == M_DIALOG:
            self.dlg.numbered = self.reader
            var c = self.dlg.draw(self.scr, p)
            if c[0] >= 0:
                self.scr.cx = c[0]
                self.scr.cy = c[1]
                self.scr.cvis = True
                self.scr.cblock = False
        if p.scanlines and not self.reader:
            self.draw_scanlines()
        if not self.focused and self.dim_unfocused and not self.reader:
            self.draw_unfocused()
        self.reader_cursor()

    def draw_unfocused(mut self):
        """The terminal does not have the focus (mode 1004): every cell's text half way
        to its background, so it is plain that keys go elsewhere (ui.dim_unfocused)."""
        for k in range(self.scr.w * self.scr.h):
            self.scr.fg[k] = dimmed(self.scr.fg[k], self.scr.bg[k])

    def scopes_update(mut self, i: Int):
        """Window i's breadcrumbs, pinned scope headers and minimap, as the settings and
        the cursor have them (the file's scopes are scanned again only after an edit)."""
        self.wins[i].minimap = self.minimap_on and not self.reader and self.wins[i].w >= MINIMAP_MIN_W
        self.wins[i].minimap_blocks = self.minimap_blocks
        if (not self.breadcrumbs and not self.sticky_scroll) or self.wins[i].buf.large:
            self.wins[i].crumbs = ""
            self.wins[i].sticky.clear()
            return
        if self.wins[i].scopes_ver != self.wins[i].buf.version:
            # a long file (scanning 20,000 lines takes about 30 ms) at most every half second
            var now = Int(now_ns())
            if self.wins[i].buf.count() <= 5000 or now - self.wins[i].scopes_ns > 500 * 1000000:
                self.wins[i].scope_items = scan_outline(self.wins[i].buf)
                self.wins[i].scopes_ver = self.wins[i].buf.version
                self.wins[i].scopes_ns = now
            else:
                self.scopes_stale = True
        var items = self.wins[i].scope_items.copy()
        self.wins[i].crumbs = breadcrumbs(items, scope_path(items, self.wins[i].cr)) if self.breadcrumbs and self.wins[i].w >= CRUMBS_MIN_W else String("")
        self.wins[i].sticky.clear()
        if self.sticky_scroll and not self.wins[i].wrap and len(self.wins[i].buf.folds) == 0:
            var top = self.wins[i].top
            self.wins[i].sticky = sticky_rows(items, scope_path(items, top), top, self.wins[i].cr, 3)

    def draw_too_small(mut self):
        """Below MIN_COLS x MIN_ROWS: only a notice, in the middle (src/responsive.mojo)."""
        var p = self.pal.copy()
        self.scr.no_clip()
        self.scr.fill(0, 0, self.scr.w, self.scr.h, 32, p.dlg_fg, p.dlg_bg)
        var lines = too_small_lines(self.scr.w, self.scr.h, self.reg.key_label(CM_QUIT))
        var y0 = max(0, (self.scr.h - len(lines)) // 2)
        for k in range(len(lines)):
            if y0 + k >= self.scr.h:
                break
            var x = max(0, (self.scr.w - lines[k].byte_length()) // 2)
            _ = self.scr.text(x, y0 + k, lines[k], p.dlg_fg, p.dlg_bg)
        self.focus_at(0, y0)

    def focus_at(mut self, x: Int, y: Int):
        """The terminal's cursor goes to (x, y), what has the focus: shown in
        screen-reader mode (screen readers follow it), else hidden there (magnifiers
        follow it, and it is not left where the last changed cell was written)."""
        if self.reader:
            self.scr.cx = x
            self.scr.cy = y
            self.scr.cvis = True
        else:
            self.scr.fx = x
            self.scr.fy = y

    def reader_cursor(mut self):
        """The cursor on what has the focus when no caret shows - the menu item, the
        dialog's control, the list row (see focus_at)."""
        if self.mode == M_MENU and self.menu_idx >= 0 and self.menu_idx < len(self.menus):
            ref m = self.menus[self.menu_idx]
            var w = m.width(self.reader)
            var x = max(0, min(m.x - 1, self.scr.w - w - 2))
            var top = dropdown_top(self.scr.h, m, self.menu_item)
            self.focus_at(x + 2, 2 + self.menu_item - top)
            return
        if self.mode == M_DIALOG:
            if self.scr.cvis:
                return                          # a field: the dialog put it there
            var c = self.dlg.focus_cell()
            if c[0] >= 0:
                self.focus_at(c[0], c[1])
            return
        var t = self.top()
        if self.mode == M_NORMAL and t >= 0 and not self.scr.cvis and self.wins[t].kind != WK_EDITOR and self.wins[t].kind != WK_TERM and self.wins[t].kind != WK_AGENT:
            # a list window: its marked row
            self.focus_at(self.wins[t].x + 1, self.wins[t].y + 1 + max(0, self.wins[t].cr - self.wins[t].top))

    def draw_scanlines(mut self):
        """A CRT look: the background of every other row a little darker (the theme's
        `scanlines`, or ui.scanlines)."""
        self.scr.no_clip()
        var y = 1
        while y < self.scr.h:
            for x in range(self.scr.w):
                self.scr.set_bg(x, y, scanline_dim(self.scr.bg_at(x, y)))
            y += 2

    def draw_window(mut self, i: Int, active: Bool):
        var p = self.pal.copy()
        self.wins[i].rel_nums = self.rel_numbers
        self.wins[i].indent_guides = self.indent_guides
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
