"""Command dispatch: App.exec() and window arrangement."""
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
from app_pickers import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *


__extension App:
    # ============================================================= commands
    def shortcut(self, k: Int) -> Int:
        """Command bound to key k (bindings live in the command registry)."""
        return self.reg.find_key(k)

    def exec(mut self, cmd: Int) raises:
        self.exec_command(cmd)
        # Options are remembered across sessions
        if cmd == CM_LINENUM:
            self.persist_option("ui", "line_numbers", toml_bool(self.line_numbers))
        elif cmd == CM_HLLINE:
            self.persist_option("ui", "highlight_line", toml_bool(self.hl_line))
        elif cmd == CM_CLOCK:
            self.persist_option("ui", "clock", toml_bool(self.show_clock))
        elif cmd == CM_SHOWWS:
            self.persist_option("ui", "show_whitespace", toml_bool(self.show_ws))
        elif cmd == CM_AUTOINDENT:
            self.persist_option("editor", "auto_indent", toml_bool(self.auto_indent))
        elif cmd >= CM_THEME0 and cmd < CM_THEME0 + THEME_COUNT:
            self.persist_option("ui", "theme", toml_quote(theme_name(self.theme_idx)))

    def exec_command(mut self, cmd: Int) raises:
        var ai = self.active_editor()
        if cmd == CM_NEW:
            var name = String("NONAME")
            if self.untitled_n < 10:
                name += "0"
            name += String(self.untitled_n) + ".mojo"
            self.untitled_n += 1
            _ = self.new_editor(name, "")
        elif cmd == CM_OPEN:
            self.open_dialog(String(self.cwd))
        elif cmd == CM_SAVE:
            var i = self.top_editor()
            if i >= 0:
                _ = self.save_window(i, NEXT_NONE)
        elif cmd == CM_SAVEAS:
            var i = self.top_editor()
            if i >= 0:
                self.saveas_dialog(i, NEXT_NONE)
        elif cmd == CM_SAVEALL:
            var n = 0
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified and self.wins[i].path.byte_length() > 0:
                    _ = self.save_window(i, NEXT_NONE)
                    n += 1
            self.say(String(n) + " file(s) saved")
        elif cmd == CM_CLOSE:
            self.close_window(self.top(), NEXT_CLOSE)
        elif cmd == CM_CLOSEALL:
            var i = len(self.wins) - 1
            while i >= 0:
                if not (self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified):
                    self.remove_window(i)
                i -= 1
            if len(self.wins) > 0:
                self.say("Modified windows were kept open")
        elif cmd == CM_SHELL:
            self.term.leave()
            _ = run_system("printf '\\nType exit to return to TurboMojo...\\n\\n'; ${SHELL:-/bin/sh}")
            self.term.enter()
            self.scr.force = True
        elif cmd == CM_QUIT:
            self.quit()
        elif cmd == CM_UNDO:
            if ai >= 0:
                self.wins[ai].undo()
        elif cmd == CM_REDO:
            if ai >= 0:
                self.wins[ai].redo()
        elif cmd == CM_CUT or cmd == CM_COPY:
            var src = ai if ai >= 0 else self.top()
            if src >= 0 and self.wins[src].has_sel():
                self.clipboard = self.wins[src].selected_text()
                self.osc52(self.clipboard.copy())
                if cmd == CM_CUT and ai >= 0:
                    _ = self.wins[ai].delete_sel(self.wins[ai].new_group())
                    self.wins[ai].follow = True
                self.say(String(len(self.clipboard)) + " characters copied")
            elif src >= 0 and self.wins[src].kind == WK_MESSAGE:
                self.clipboard = self.wins[src].buf.line(self.wins[src].cr)
                self.osc52(self.clipboard.copy())
        elif cmd == CM_PASTE:
            if ai >= 0 and len(self.clipboard) > 0:
                self.wins[ai].insert_text(self.clipboard, ACT_OTHER)
                self.wins[ai].break_group()
        elif cmd == CM_CLEAR:
            if ai >= 0:
                _ = self.wins[ai].delete_sel(self.wins[ai].new_group())
        elif cmd == CM_SELALL:
            if ai >= 0:
                self.wins[ai].select_all()
        elif cmd == CM_COMMENT:
            if ai >= 0:
                self.wins[ai].toggle_comment()
        elif cmd == CM_DUPLINE:
            if ai >= 0:
                self.wins[ai].duplicate_line()
        elif cmd == CM_DELLINE:
            if ai >= 0:
                _ = self.wins[ai].delete_line()
        elif cmd == CM_COMPLETE:
            self.start_complete()
        elif cmd == CM_FIND or cmd == CM_REPLACE:
            self.open_find(cmd == CM_REPLACE)
        elif cmd == CM_AGAIN:
            self.find_again()
        elif cmd == CM_GOTO:
            if ai >= 0:
                var d = Dialog(D_GOTO, "Go to Line Number", 44, 7)
                d.fields.append(Field("Enter new line ~n~umber", ""))
                d.buttons.append("~O~K")
                d.buttons.append("~C~ancel")
                self.show(d^)
        elif cmd == CM_SYMBOL:
            self.symbol_dialog()
        elif cmd == CM_MATCH:
            if ai >= 0:
                var p = self.wins[ai].match_bracket()
                if p.r >= 0:
                    self.wins[ai].begin_move(False)
                    self.wins[ai].cr = p.r
                    self.wins[ai].cc = p.c
                    self.wins[ai].sync_want()
                else:
                    self.say("No matching bracket")
        elif cmd == CM_PALETTE:
            self.palette_dialog()
        elif cmd == CM_RUN:
            self.run_program(False)
        elif cmd == CM_TEST:
            self.run_program(True)
        elif cmd == CM_USERSCREEN:
            self.term.leave()
            self.term.raw()
            self.term.wait_byte()
            self.term.enter()
            self.scr.force = True
        elif cmd == CM_ARGS:
            var d = Dialog(D_ARGS, "Program Arguments", 56, 7)
            d.fields.append(Field("~A~rguments", self.run_args))
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
        elif cmd == CM_COMPILER:
            var d = Dialog(D_COMPILER, "Compiler", 60, 9)
            d.lines.append("Command used for build / run / format / test.")
            d.fields.append(Field("~M~ojo command", self.compiler))
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
        elif cmd == CM_BUILD:
            self.build()
        elif cmd == CM_FORMAT:
            self.format_file()
        elif cmd == CM_NEXTERR:
            self.goto_error(1)
        elif cmd == CM_PREVERR:
            self.goto_error(-1)
        elif cmd == CM_LINENUM:
            self.line_numbers = not self.line_numbers
        elif cmd == CM_AUTOINDENT:
            self.auto_indent = not self.auto_indent
        elif cmd == CM_HLLINE:
            self.hl_line = not self.hl_line
        elif cmd == CM_CLOCK:
            self.show_clock = not self.show_clock
        elif cmd == CM_SHOWWS:
            self.show_ws = not self.show_ws
        elif cmd == CM_USETABS:
            var i = self.top_editor()
            if i >= 0:
                self.wins[i].buf.use_tabs = not self.wins[i].buf.use_tabs
                self.say("Indent with " + ("tabs" if self.wins[i].buf.use_tabs else "spaces"))
        elif cmd == CM_CRLF:
            var i = self.top_editor()
            if i >= 0:
                self.wins[i].buf.crlf = not self.wins[i].buf.crlf
                self.wins[i].buf.modified = True
                self.say("Line endings: " + ("CRLF" if self.wins[i].buf.crlf else "LF"))
        elif cmd == CM_CANCEL:
            self.cancel_job()
        elif cmd == CM_LSP:
            self.lsp_command()
        elif cmd >= CM_THEME0 and cmd < CM_THEME0 + THEME_COUNT:
            self.theme_idx = cmd - CM_THEME0
            self.pal = theme(self.theme_idx)
            self.say("Theme: " + self.pal.name)
        elif cmd == CM_ZOOM:
            var t = self.top()
            if t >= 0:
                if self.wins[t].zoomed:
                    self.wins[t].zoomed = False
                    self.wins[t].x = self.wins[t].sx
                    self.wins[t].y = self.wins[t].sy
                    self.wins[t].w = self.wins[t].sw
                    self.wins[t].h = self.wins[t].sh
                else:
                    self.wins[t].sx = self.wins[t].x
                    self.wins[t].sy = self.wins[t].y
                    self.wins[t].sw = self.wins[t].w
                    self.wins[t].sh = self.wins[t].h
                    self.wins[t].zoomed = True
                self.fit_windows()
        elif cmd == CM_TILE or cmd == CM_CASCADE:
            self.arrange(cmd == CM_TILE)
        elif cmd == CM_NEXTWIN:
            if len(self.wins) > 1:
                self.focus(0)
        elif cmd == CM_PREVWIN:
            if len(self.wins) > 1:
                var w = self.wins.pop()
                self.wins.insert(0, w^)
        elif cmd == CM_MESSAGE:
            var mi = self.ensure_msg()
            self.focus(mi)
        elif cmd == CM_WINLIST:
            var d = Dialog(D_WINLIST, "Window List", 56, min(18, self.desk_h()))
            var items = List[String]()
            var data = List[Int]()
            var i = len(self.wins) - 1
            while i >= 0:
                var s = String(self.wins[i].number) + "  " + self.wins[i].title
                if self.wins[i].buf.modified and self.wins[i].kind == WK_EDITOR:
                    s += "  [modified]"
                items.append(s)
                data.append(i)
                i -= 1
            d.set_items(items^, data^)
            d.focus = 0
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
        elif cmd == CM_HELP:
            self.help_dialog()
        elif cmd == CM_ABOUT:
            var d = Dialog(D_ABOUT, "About", 52, 14)
            d.lines.append("")
            d.lines.append("        ~T U R B O   M O J O~")
            d.lines.append("")
            d.lines.append("      Version " + VERSION + "  -  written in pure Mojo")
            d.lines.append("  A tribute to Borland Turbo C++ 3.0 (1992)")
            d.lines.append("")
            d.lines.append(" Truecolor - mouse - undo - fuzzy palette")
            d.lines.append(" syntax colouring - build/run - OSC 52 copy")
            d.buttons.append("~O~K")
            d.focus = d.button_focus_index(0)
            self.show(d^)
        elif cmd == CM_REFRESH:
            self.scr.force = True

    def arrange(mut self, tile: Bool):
        var idx = List[Int]()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR:
                idx.append(i)
        var n = len(idx)
        if n == 0:
            return
        var dh = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            dh = max(6, self.wins[mi].y - 1)
        var W = self.scr.w
        if tile:
            var cols = 1
            while cols * cols < n:
                cols += 1
            var rows = (n + cols - 1) // cols
            for k in range(n):
                var c = k % cols
                var r = k // cols
                var i = idx[k]
                self.wins[i].zoomed = False
                self.wins[i].x = (W * c) // cols
                self.wins[i].w = (W * (c + 1)) // cols - self.wins[i].x
                self.wins[i].y = 1 + (dh * r) // rows
                self.wins[i].h = 1 + (dh * (r + 1)) // rows - self.wins[i].y
        else:
            for k in range(n):
                var i = idx[k]
                var off = k % 8
                self.wins[i].zoomed = False
                self.wins[i].x = off
                self.wins[i].y = 1 + off
                self.wins[i].w = W - off
                self.wins[i].h = dh - off
        self.fit_windows()

    def find_again(mut self):
        var ai = self.active_editor()
        if ai < 0 or len(self.find_text) == 0:
            return
        var s = self.current_search()
        if not s.ok:
            return
        self.wins[ai].set_highlight(s)
        if not self.wins[ai].search_next(s):
            self.info("Information", "Search string not found.")
        else:
            self.say(self.match_note(ai, s))
