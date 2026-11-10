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
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
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
from app_nav import *
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
            self.wins[i].disk_hash = 0 if big else content_hash(bytes)
            self.wins[i].disk_size = -1 if big else len(bytes)
            self.restore_history(i)
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
        var note = String("")
        if self.wins[i].buf.encoding == ENC_LATIN1 and not self.wins[i].buf.latin1_ok():
            # the text now has characters Latin-1 cannot hold
            self.wins[i].buf.encoding = ENC_UTF8
            note = " as UTF-8 (it has characters Latin-1 cannot hold)"
        var b = self.wins[i].buf.to_bytes()
        if not write_file(self.wins[i].path, b):
            raise Error("Could not write " + self.wins[i].path)
        self.wins[i].buf.modified = False
        self.wins[i].buf.mixed_eol = False      # written with one kind of line end
        self.wins[i].disk_hash = 0 if self.wins[i].buf.large else content_hash(b)
        self.wins[i].disk_size = -1 if self.wins[i].buf.large else len(b)
        self.store_history(i)
        self.lsp_note_saved(i)
        self.note_disk_state(i)
        self.drop_swap(i)
        self.say("Saved " + self.wins[i].path + note)
        return True

    # ------------------------------------------------- history between sessions
    def history_file(self, i: Int) -> String:
        return self.history_dir + "/" + state_name(self.wins[i].path)

    def store_history(mut self, i: Int):
        """Write the undo history and cursor position of window i next to nothing but the
        state directory. Only for a buffer that equals its file on disk: the history is
        tied to that exact content."""
        if self.history_dir.byte_length() == 0 or self.wins[i].kind != WK_EDITOR:
            return
        if self.wins[i].path.byte_length() == 0 or self.wins[i].buf.modified or self.wins[i].disk_size < 0:
            return
        if not path_exists(self.history_dir):
            _ = run_system("mkdir -p " + shell_quote(self.history_dir) + " && chmod 700 " + shell_quote(self.history_dir))
        var data = state_encode(
            self.wins[i].disk_hash, self.wins[i].disk_size, self.wins[i].cr, self.wins[i].cc, self.wins[i].top,
            self.wins[i].buf.undos, self.wins[i].buf.redos,
        )
        if not write_file(self.history_file(i), data):
            self.log_error("could not write history for " + self.wins[i].path)

    def restore_history(mut self, i: Int):
        """After loading a file: bring back its cursor position and undo history if the
        file still has the content they were saved for."""
        if self.history_dir.byte_length() == 0 or self.wins[i].disk_size < 0:
            return
        var data = read_file(self.history_file(i))
        if len(data) == 0:
            return
        var st = state_decode(data)
        if not st.ok or st.hash != self.wins[i].disk_hash or st.size != self.wins[i].disk_size:
            return
        var top_group = 0
        for u in st.undos:
            top_group = max(top_group, u.group)
        for u in st.redos:
            top_group = max(top_group, u.group)
        self.wins[i].buf.undos = st.undos.copy()
        self.wins[i].buf.redos = st.redos.copy()
        # new edits must not join a group from the earlier session
        self.wins[i].gseq = max(self.wins[i].gseq, top_group)
        self.wins[i].break_group()
        self.wins[i].cr = st.cr
        self.wins[i].cc = st.cc
        self.wins[i].clamp()
        self.wins[i].sync_want()
        self.wins[i].top = max(0, min(st.top, self.wins[i].buf.count() - 1))
        self.wins[i].follow = True

    def prune_history(mut self):
        """Keep the state directory from growing for ever: only the 500 most recently
        written history files stay."""
        if self.history_dir.byte_length() == 0 or not path_exists(self.history_dir):
            return
        var d = shell_quote(self.history_dir)
        _ = run_system("cd " + d + " && ls -1t | tail -n +501 | while IFS= read -r f; do rm -f -- \"$f\"; done")

    def remove_window(mut self, i: Int):
        self.store_history(i)   # remembers the cursor position (if the file is unchanged)
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
        for i in range(len(self.wins)):
            self.store_history(i)
        self.running = False
