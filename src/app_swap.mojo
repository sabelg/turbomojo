"""Swap files in the running IDE: periodic writing, clean-up and recovery at startup."""
from std.collections import List
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from dialog import *
from util import *
from swap import *
from appstate import *
from app_lsp import *
from lsp import *
from app_watch import *
from watch import *
from app_files import *
from app_dialogs import *
from app_watch import *
from watch import *


__extension App:
    def swap_file_for(self, i: Int) -> String:
        return self.recovery_dir + "/" + swap_name(self.wins[i].path, self.wins[i].title, own_pid(), self.wins[i].number * 1000 + i)

    def write_swap(mut self, i: Int) -> Bool:
        """Write (or rewrite) the swap file of window i."""
        if not path_exists(self.recovery_dir):
            _ = run_system("mkdir -p " + shell_quote(self.recovery_dir))
        var target = self.swap_file_for(i)
        if self.wins[i].path.byte_length() == 0 and self.wins[i].swap_file.byte_length() > 0:
            target = self.wins[i].swap_file     # an untitled buffer keeps its swap file
        if self.wins[i].swap_file.byte_length() > 0 and self.wins[i].swap_file != target:
            delete_file(self.wins[i].swap_file)     # the buffer was renamed (Save As)
        var data = swap_encode(self.wins[i].path, self.wins[i].title, own_pid(), timestamp(), self.wins[i].buf.to_bytes())
        if not write_bytes_atomic(target, data):
            return False
        self.wins[i].swap_file = target
        self.wins[i].swap_version = self.wins[i].buf.version
        return True

    def drop_swap(mut self, i: Int):
        """Forget the swap file of window i (the buffer was saved or deliberately closed)."""
        if self.wins[i].swap_file.byte_length() > 0:
            delete_file(self.wins[i].swap_file)
            self.wins[i].swap_file = ""
        self.wins[i].swap_version = -1

    def swap_tick(mut self, now: Int):
        """Called on every pass of the event loop. Unsaved changes are written to swap
        files SWAP_INTERVAL_MS after the first change that is not yet on disk; swap files
        of buffers that have been saved are removed."""
        if not self.swap_enabled:
            return
        var pending = False
        for i in range(len(self.wins)):
            if self.wins[i].kind != WK_EDITOR:
                continue
            if not self.wins[i].buf.modified:
                if self.wins[i].swap_file.byte_length() > 0:
                    self.drop_swap(i)
                continue
            if self.wins[i].buf.large:
                continue        # rewriting a huge snapshot every few seconds would stall typing
            if self.wins[i].swap_version != self.wins[i].buf.version:
                pending = True
        if not pending:
            self.swap_due = 0
            return
        if self.swap_due == 0:
            self.swap_due = now + SWAP_INTERVAL_MS * 1000000
            return
        if now < self.swap_due:
            return
        self.swap_due = 0
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified and not self.wins[i].buf.large and self.wins[i].swap_version != self.wins[i].buf.version:
                if not self.write_swap(i):
                    self.log_error("could not write swap file for " + self.wins[i].title)

    def write_all_swaps(mut self) -> Int:
        """Write swap files for every modified buffer right now. Returns how many."""
        var n = 0
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified:
                if self.write_swap(i):
                    n += 1
        return n

    def clean_swaps_on_exit(mut self):
        """After a normal quit nothing is unsaved by accident: remove our swap files."""
        for i in range(len(self.wins)):
            if self.wins[i].swap_file.byte_length() > 0:
                self.drop_swap(i)

    # ------------------------------------------------------------- recovery
    def find_orphan_swaps(self) -> List[String]:
        """Swap files left by an IDE process that is no longer running."""
        var out = List[String]()
        for f in list_swap_files(self.recovery_dir):
            var info = swap_decode(read_bytes(f))
            if info.ok and not pid_alive(info.pid):
                out.append(f)
        return out^

    def offer_recovery(mut self):
        """At startup: if a previous session left unsaved work, ask what to do with it."""
        self.pending_swaps = self.find_orphan_swaps()
        var n = len(self.pending_swaps)
        if n == 0:
            return
        var dw = max(62, min(self.scr.w - 4, 96))
        var d = Dialog(D_RECOVER, "Recover unsaved work", dw, min(9 + min(n, 6), 16))
        d.lines.append("TurboMojo did not exit normally last time.")
        d.lines.append("Unsaved changes were kept for:")
        for k in range(min(n, 6)):
            var info = swap_decode(read_bytes(self.pending_swaps[k]))
            var what = info.path if info.path.byte_length() > 0 else info.title + " (never saved)"
            if what.startswith(self.cwd + "/"):
                var rel = String(what[byte=self.cwd.byte_length() + 1:])
                what = rel                  # (where the IDE runs: shorter)
            # a long path keeps its end - the file's name - and loses its start
            var room = dw - 6 - cp_len(info.time) - 3
            var cps = decode(what)
            if len(cps) > room and room > 8:
                what = "…" + slice_str(cps, len(cps) - room + 1, len(cps))
            d.lines.append("  " + what + "   " + info.time)
        if n > 6:
            d.lines.append("  ... and " + String(n - 6) + " more")
        d.buttons.append("~R~ecover")
        d.buttons.append("~D~iscard")
        d.buttons.append("~L~ater")
        d.focus = d.button_focus_index(0)
        self.show(d^)

    def recover_swaps(mut self) -> Int:
        """Open every pending swap as a modified buffer. The old swap files are removed;
        new ones are written by the normal swap cycle because the buffers are modified."""
        var count = 0
        for f in self.pending_swaps:
            var info = swap_decode(read_bytes(f))
            if not info.ok:
                continue
            var i = -1
            if info.path.byte_length() > 0:
                i = self.find_editor(info.path)
            if i < 0:
                i = self.pristine_untitled()
                if i >= 0:
                    # reuse the empty window the IDE opened at startup
                    self.wins[i].path = info.path
                    self.wins[i].title = info.title if info.title.byte_length() > 0 else basename(info.path)
            if i < 0:
                i = self.new_editor(info.title if info.title.byte_length() > 0 else basename(info.path), info.path)
            self.wins[i].buf.load_bytes(info.content)
            self.apply_editorconfig(i)
            self.note_disk_state(i)
            self.wins[i].buf.modified = True
            self.wins[i].cr = 0
            self.wins[i].cc = 0
            self.wins[i].top = 0
            self.wins[i].sel = False
            delete_file(f)
            count += 1
        self.pending_swaps.clear()
        if count > 0:
            self.say("Recovered " + String(count) + " unsaved buffer(s): review, then save or close them")
        return count

    def pristine_untitled(self) -> Int:
        """Index of an empty, unmodified, never-saved editor window, or -1."""
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path.byte_length() == 0 and not self.wins[i].buf.modified and self.wins[i].buf.count() == 1 and self.wins[i].buf.llen(0) == 0:
                return i
        return -1

    def discard_swaps(mut self):
        for f in self.pending_swaps:
            delete_file(f)
        self.pending_swaps.clear()
