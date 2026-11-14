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
from symindex import *
from outline import scan_outline
from app_lsp import *
from app_problems import *
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
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from app_git import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *
from app_plugins import *


__extension App:
    # ================================================================ files
    def open_path(mut self, path: String) raises:
        var p = abs_path(self.cwd, path)
        if path_exists(p) and not is_dir(p) and not self.restoring:
            self.frec_note(p)
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
        self.wins[i].sync_ver = self.wins[i].buf.version
        self.tests_sync_lens()
        self.plugins_event("open", p)
        if self.lsp_auto_start and self.lsp_auto_checked and not self.wins[i].buf.large and self.log_path.byte_length() > 0 and not self.trust_held and self.trust_ok() and is_mojo_file(p) and not self.lsp.active():
            self.lsp_track(i, now_ns())

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
        self.typed_ns = 0                       # a save is a pause: held toasts come now
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
        if self.symidx.built and is_mojo_file(self.wins[i].path):
            self.symidx.replace_file(self.wins[i].path, scan_outline(self.wins[i].buf))
        self.note_disk_state(i)
        self.drop_swap(i)
        self.wins[i].sync_ver = self.wins[i].buf.version
        self.sync_shared_buffers(i)
        self.git_saved()
        self.tests_sync_lens()
        self.say("Saved " + self.wins[i].path + note)
        var saved = String(self.wins[i].path)
        self.plugins_event("save", saved)
        self.export_ide_state()
        if self.format_on_save and next == NEXT_NONE and is_mojo_file(saved) and not self.wins[i].buf.large and not self.trust_held and self.trust_ok() and not self.aux_job.active:
            var inner = "cd " + shell_quote(dirname(saved)) + " && exec " + self.mojo_for(saved) + " format -q " + shell_quote(saved)
            var cmd = self.with_env(saved, inner) + " 2>&1"
            _ = self.start_aux_job(JOB_FORMAT, cmd, saved, "")
        return True

    # ------------------------------------------------- history between sessions
    def history_file(self, i: Int) -> String:
        return self.history_dir + "/" + state_name(self.wins[i].path)

    def store_history(mut self, i: Int):
        """Write the undo history, cursor position, scroll and folds of window i next to nothing but the
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
            self.wins[i].buf.undos, self.wins[i].buf.redos, self.wins[i].buf.folds,
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
        self.restore_folds(i, st.folds)
        self.wins[i].follow = True

    def restore_folds(mut self, i: Int, folds: List[Int]):
        """Fold again the blocks that were folded (a row that starts no block now is
        passed over); a fold that would hide the cursor stays open."""
        for r in folds:
            if r >= 0 and r < self.wins[i].buf.count():
                _ = self.wins[i].buf.set_fold(r, True)
        self.wins[i].reveal_cursor()

    def prune_history(mut self):
        """Keep the state directory from growing for ever: only the 500 most recently
        written history files stay."""
        if self.history_dir.byte_length() == 0 or not path_exists(self.history_dir):
            return
        var d = shell_quote(self.history_dir)
        _ = run_system("cd " + d + " && ls -1t | tail -n +501 | while IFS= read -r f; do rm -f -- \"$f\"; done")

    # ------------------------------------------------- shared split views
    def same_shared_buffer(self, i: Int, j: Int) -> Bool:
        if i == j or i < 0 or j < 0 or i >= len(self.wins) or j >= len(self.wins):
            return False
        if self.wins[i].kind != WK_EDITOR or self.wins[j].kind != WK_EDITOR:
            return False
        if self.wins[i].path.byte_length() > 0 and self.wins[i].path == self.wins[j].path:
            return True
        return self.wins[i].clone_group > 0 and self.wins[i].clone_group == self.wins[j].clone_group

    def has_shared_sibling(self, i: Int) -> Bool:
        for j in range(len(self.wins)):
            if self.same_shared_buffer(i, j):
                return True
        return False

    def sync_shared_buffers(mut self, preferred: Int = -1):
        """Propagate edits, undo/redo stacks, marks and disk state across split views
        editing the same file or untitled clone group while preserving each view's own
        cursor, scroll offset and code folds."""
        var done = List[Int]()
        var n = len(self.wins)
        var pass_idx = -1
        while pass_idx < n:
            var src = preferred if pass_idx < 0 else pass_idx
            pass_idx += 1
            if src < 0 or src >= n or self.wins[src].kind != WK_EDITOR or (src in done):
                continue
            if preferred != src and self.wins[src].buf.version == self.wins[src].sync_ver:
                continue
            var has_sib = False
            for j in range(n):
                if self.same_shared_buffer(src, j):
                    has_sib = True
                    break
            self.wins[src].sync_ver = self.wins[src].buf.version
            done.append(src)
            if not has_sib:
                continue
            for dst in range(n):
                if not self.same_shared_buffer(src, dst):
                    continue
                var d_cr = self.wins[dst].cr
                var d_cc = self.wins[dst].cc
                var d_want = self.wins[dst].want
                var d_top = self.wins[dst].top
                var d_top_seg = self.wins[dst].top_seg
                var d_left = self.wins[dst].left
                var d_folds = self.wins[dst].buf.folds.copy()
                var cb = self.wins[src].buf.copy()
                self.wins[dst].buf = cb^
                self.wins[dst].buf.folds.clear()
                self.wins[dst].buf.fold_ends.clear()
                self.wins[dst].buf.fold_version = -1
                self.wins[dst].cr = d_cr
                self.wins[dst].cc = d_cc
                self.wins[dst].clamp()
                self.wins[dst].want = d_want
                self.wins[dst].top = max(0, min(d_top, self.wins[dst].buf.count() - 1))
                self.wins[dst].top_seg = d_top_seg
                self.wins[dst].left = d_left
                if len(d_folds) > 0:
                    self.restore_folds(dst, d_folds)
                self.wins[dst].gseq = max(self.wins[dst].gseq, self.wins[src].gseq)
                self.wins[dst].disk_hash = self.wins[src].disk_hash
                self.wins[dst].disk_size = self.wins[src].disk_size
                self.wins[dst].disk_sig = self.wins[src].disk_sig.copy()
                self.wins[dst].gut = self.wins[dst].gutter_for(self.line_numbers)
                self.wins[dst].sync_ver = self.wins[dst].buf.version
                done.append(dst)

    def clone_editor_view(mut self, right: Bool = True):
        """Open a second synchronized view of the active editor in a split pane."""
        var ti = self.top_editor()
        if ti < 0:
            self.say("Open a file first")
            return
        if self.wins[ti].clone_group == 0:
            self.wins[ti].clone_group = self.next_clone_group
            self.next_clone_group += 1
        var cg = self.wins[ti].clone_group
        var title = String(self.wins[ti].title)
        var path = String(self.wins[ti].path)
        var cr = self.wins[ti].cr
        var cc = self.wins[ti].cc
        var want = self.wins[ti].want
        var top = self.wins[ti].top
        var top_seg = self.wins[ti].top_seg
        var left = self.wins[ti].left
        var cb = self.wins[ti].buf.copy()
        var gseq = self.wins[ti].gseq
        var dhash = self.wins[ti].disk_hash
        var dsize = self.wins[ti].disk_size
        var dsig = self.wins[ti].disk_sig.copy()
        var lsent = self.wins[ti].lsp_sent_version
        var lseen = self.wins[ti].lsp_seen_version
        var sver = self.wins[ti].sem_version
        self.wins[ti].sync_ver = self.wins[ti].buf.version
        var ci = self.new_editor(title, path)
        self.wins[ci].clone_group = cg
        self.wins[ci].buf = cb^
        self.wins[ci].cr = cr
        self.wins[ci].cc = cc
        self.wins[ci].want = want
        self.wins[ci].top = top
        self.wins[ci].top_seg = top_seg
        self.wins[ci].left = left
        self.wins[ci].gseq = gseq
        self.wins[ci].disk_hash = dhash
        self.wins[ci].disk_size = dsize
        self.wins[ci].disk_sig = dsig^
        self.wins[ci].lsp_sent_version = lsent
        self.wins[ci].lsp_seen_version = lseen
        self.wins[ci].sem_version = sver
        self.wins[ci].gut = self.wins[ci].gutter_for(self.line_numbers)
        self.wins[ci].sync_ver = self.wins[ci].buf.version
        if self.tiled:
            self.layout_sync()
            var why = self.lay.split(right)
            if why.byte_length() > 0:
                self.say(why)
            else:
                self.layout_focus_shown()
                self.say("Split view: " + (basename(path) if path.byte_length() > 0 else title))
        else:
            var rx = self.wins[ti].x
            var ry = self.wins[ti].y
            var rw = self.wins[ti].w
            var rh = self.wins[ti].h
            self.wins[ti].zoomed = False
            self.wins[ti].half = False
            self.wins[ci].zoomed = False
            self.wins[ci].half = False
            if right and rw >= 32:
                var hw = rw // 2
                self.wins[ti].w = rw - hw
                self.wins[ci].x = rx + rw - hw
                self.wins[ci].y = ry
                self.wins[ci].w = hw
                self.wins[ci].h = rh
            elif not right and rh >= 8:
                var hh = rh // 2
                self.wins[ti].h = rh - hh
                self.wins[ci].x = rx
                self.wins[ci].y = ry + rh - hh
                self.wins[ci].w = rw
                self.wins[ci].h = hh
            self.fit_windows()
            self.say("Split view: " + (basename(path) if path.byte_length() > 0 else title))

    def remove_window(mut self, i: Int):
        if self.wins[i].kind == WK_MESSAGE:
            self.panel_keep()       # the panel's page is there again when it is reopened
        self.store_history(i)   # remembers the cursor position (if the file is unchanged)
        if not self.has_shared_sibling(i):
            self.drop_swap(i)   # closing the last view is a decision: nothing left to recover
        _ = self.wins.pop(i)

    def close_window(mut self, i: Int, next: Int):
        if i < 0:
            return
        if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified and (next == NEXT_QUIT or not self.has_shared_sibling(i)):
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
        self.session_save()
        self.running = False
