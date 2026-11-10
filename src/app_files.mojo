"""File handling: opening, saving, closing windows, quitting."""
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
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_pickers import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *


__extension App:
    # ================================================================ files
    def open_path(mut self, path: String) raises:
        var p = abs_path(self.cwd, path)
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path == p:
                self.focus(i)
                return
        if is_dir(p):
            self.open_dialog(p)
            return
        # reuse a pristine untitled window (Turbo behaviour)
        var reuse = -1
        var ti = self.top_editor()
        if ti >= 0 and self.wins[ti].path.byte_length() == 0 and not self.wins[ti].buf.modified and self.wins[ti].buf.count() == 1 and self.wins[ti].buf.llen(0) == 0:
            reuse = ti
        var i = reuse
        if i < 0:
            i = self.new_editor(basename(p), p)
        else:
            self.wins[i].title = basename(p)
            self.wins[i].path = p
            self.focus(i)
            i = self.top()
        if path_exists(p):
            var bytes = read_file(p)
            var big = len(bytes) > self.large_file_bytes
            self.wins[i].buf.load_bytes(bytes)
            self.wins[i].buf.large = big
            self.wins[i].cr = 0
            self.wins[i].cc = 0
            self.wins[i].top = 0
            if big:
                self.say("Opened in large-file mode: syntax colours, recovery snapshots and language server are off")
            else:
                self.say("Loaded " + p)
        else:
            self.say("New file: " + p)
        self.apply_editorconfig(i)
        self.note_disk_state(i)

    def apply_buffer_settings(mut self, i: Int, ec: EcProps):
        """Give a buffer its indentation and line-ending rules: user defaults first, then
        whatever .editorconfig specifies for the file."""
        self.wins[i].buf.tab_width = ec.effective_tab_width(self.tab_width)
        self.wins[i].buf.indent_size = ec.effective_indent_size(self.indent_size)
        if ec.has_indent_style:
            self.wins[i].buf.use_tabs = ec.use_tabs
        if ec.has_eol:
            self.wins[i].buf.crlf = ec.crlf
        if ec.has_final_newline:
            self.wins[i].buf.eol_at_eof = ec.final_newline
        # the user's setting, unless .editorconfig says something for this file
        self.wins[i].buf.trim_on_save = ec.trim if ec.has_trim else self.trim_trailing

    def apply_editorconfig(mut self, i: Int):
        if self.wins[i].path.byte_length() > 0:
            self.apply_buffer_settings(i, ec_for_file(self.wins[i].path))
        else:
            self.apply_buffer_settings(i, EcProps())

    def save_window(mut self, i: Int, next: Int) raises -> Bool:
        if self.wins[i].path.byte_length() == 0:
            self.saveas_dialog(i, next)
            return False
        if self.disk_changed(i) and file_sig(self.wins[i].path).exists and not self.wins[i].overwrite_ok:
            # the file changed behind our back and nobody has decided yet: ask first
            self.ask_changed(i)
            return False
        self.wins[i].overwrite_ok = False
        if self.wins[i].buf.trim_on_save:
            _ = self.wins[i].trim_trailing_whitespace()
        var b = self.wins[i].buf.to_bytes()
        with open(self.wins[i].path, "w") as f:
            f.write(bytes_to_str(b))
        self.wins[i].buf.modified = False
        self.note_disk_state(i)
        self.drop_swap(i)
        self.say("Saved " + self.wins[i].path)
        return True

    def remove_window(mut self, i: Int):
        self.drop_swap(i)       # closing is a decision: nothing left to recover
        _ = self.wins.pop(i)

    def close_window(mut self, i: Int, next: Int):
        if i < 0:
            return
        if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified:
            self.focus(i)
            var d = Dialog(D_CONFIRM_CLOSE if next != NEXT_QUIT else D_CONFIRM_QUIT, "Information", 50, 9)
            d.lines.append(self.wins[self.top()].title + " has been modified.")
            d.lines.append("Save?")
            d.buttons.append("~Y~es")
            d.buttons.append("~N~o")
            d.buttons.append("~C~ancel")
            d.payload = self.top()
            d.next = next
            d.focus = d.button_focus_index(0)
            self.show(d^)
            return
        self.remove_window(i)

    def quit(mut self):
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified:
                self.close_window(i, NEXT_QUIT)
                return
        self.running = False
