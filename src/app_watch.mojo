"""Reacting to files that were changed by another program while open in the IDE."""
from std.collections import List
from window import Window, WK_EDITOR, WK_MESSAGE
from window_search import *
from window_multi import *
from window_draw import *
from dialog import *
from util import *
from swap import read_bytes
from watch import *
from appstate import *
from app_lsp import *
from lsp import *
from app_files import *
from app_dialogs import *


__extension App:
    def note_disk_state(mut self, i: Int):
        """Remember what the file looks like on disk right now (after loading or saving
        it) and make sure its directory is watched."""
        if self.wins[i].path.byte_length() == 0:
            self.wins[i].disk_sig = FileSig()
            return
        self.wins[i].disk_sig = file_sig(self.wins[i].path)
        _ = self.watch.watch_dir(dirname(self.wins[i].path))

    def disk_changed(self, i: Int) -> Bool:
        if self.wins[i].kind != WK_EDITOR or self.wins[i].path.byte_length() == 0:
            return False
        return not file_sig(self.wins[i].path).same(self.wins[i].disk_sig)

    def reload_from_disk(mut self, i: Int) raises:
        """Replace the buffer with the file's content as one undo step, keeping the
        cursor line where possible."""
        var cr = self.wins[i].cr
        var cc = self.wins[i].cc
        var tmp = TextBuffer()
        tmp.load(decode_list(read_bytes(self.wins[i].path)))
        self.wins[i].replace_all_text(tmp.all_text())
        self.wins[i].buf.crlf = tmp.crlf
        self.wins[i].cr = cr
        self.wins[i].cc = cc
        self.wins[i].clamp()
        self.wins[i].sync_want()
        self.wins[i].buf.modified = False
        self.note_disk_state(i)

    def ask_changed(mut self, i: Int):
        var d = Dialog(D_CHANGED, "File changed on disk", 60, 10)
        d.lines.append(self.wins[i].title + " was changed by another program,")
        d.lines.append("and you have unsaved changes in the editor.")
        d.buttons.append("~R~eload from disk")
        d.buttons.append("~K~eep my version")
        d.payload = i
        d.focus = d.button_focus_index(1)      # the safe choice is the default
        self.show(d^)

    def check_external_changes(mut self) raises:
        """Compare every open file with the disk. Unmodified buffers are reloaded quietly;
        for a buffer with unsaved changes the user is asked. While another dialog or menu
        is open the question waits (`watch_recheck`)."""
        self.watch_recheck = False
        for i in range(len(self.wins)):
            if not self.disk_changed(i):
                continue
            var now = file_sig(self.wins[i].path)
            if not now.exists:
                # deleted or moved away: keep the text and make sure a save restores it
                self.wins[i].disk_sig = now.copy()
                self.wins[i].buf.modified = True
                self.say(self.wins[i].title + " was deleted on disk; the buffer is kept as unsaved")
                continue
            # same bytes (touched, or rewritten identically): nothing to do
            var disk = read_bytes(self.wins[i].path)
            var mine = self.wins[i].buf.to_bytes()
            var identical = len(disk) == len(mine)
            if identical:
                for k in range(len(disk)):
                    if disk[k] != mine[k]:
                        identical = False
                        break
            if identical:
                self.wins[i].disk_sig = now.copy()
                continue
            if not self.wins[i].buf.modified:
                self.reload_from_disk(i)
                self.say("Reloaded " + self.wins[i].title + " (changed on disk)")
                continue
            if self.mode != M_NORMAL:
                self.watch_recheck = True       # ask once the current dialog or menu is gone
                return
            self.ask_changed(i)
            return                              # one question at a time; the rest follow

    def watch_tick(mut self, now: Int, woke: Bool) raises:
        """Called on every pass of the event loop."""
        var due = woke or self.watch_recheck
        if not self.watch.active() and self.watch_enabled and now >= self.watch_due:
            due = True
            self.watch_due = now + WATCH_POLL_MS * 1000000
        if due and (self.mode == M_NORMAL or woke):
            self.check_external_changes()
