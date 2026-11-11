"""Git in the editor: changed-line markers in the gutter and `git status` colours in the
file explorer.

git runs in the background, one command at a time (`git_proc`): `status` for the
project's repository, and `cat-file --filters :path` for each open file's version in the
index, which the gutter compares the buffer with (as edited, not as saved). The index
file is looked at every second; when it changes (a commit, `git add`, a checkout made in
a terminal) both are asked again.
"""
from std.collections import List, Dict
from appstate import *
from util import *
from window import Window, WK_EDITOR, WK_EXPLORER
from buffer import TextBuffer
from git import *
from linediff import *
from watch import file_sig, FileSig
from app_outline import *
from app_explorer import *

comptime GQ_NONE = 0
comptime GQ_STATUS = 1
comptime GQ_BASE = 2
comptime GIT_INDEX_MS = 1000      # how often the index file is looked at
comptime GIT_STATUS_MS = 3000     # with the explorer open, status at least this often
comptime GIT_MAX_LINES = 50000    # larger files get no markers (about 10 ms a change at this size)


__extension App:
    def git_repo_root(self) -> String:
        return self.git.root

    def git_index_path(self) -> String:
        """The index file of the project's repository ('' if it is not a plain .git
        folder, as in a linked work tree, where only the timer refreshes)."""
        if self.git.root.byte_length() == 0:
            return ""
        var g = join_path(self.git.root, ".git")
        return join_path(g, "index") if is_dir(g) else String("")

    def git_forget_bases(mut self):
        """Ask git again for every open file's version (the index changed)."""
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.git_state != GB_ASKED:
                self.wins[i].buf.git_state = GB_UNKNOWN

    def git_tick(mut self, now: Int):
        if self.git_proc.running:
            _ = self.git_proc.read_available()
            for b in self.git_proc.take():
                self.git_out.append(b)
            if self.git_proc.eof:
                var st = self.git_proc.stop()
                self.git_done(st)
            return
        if now - self.git_checked_ns > GIT_INDEX_MS * 1000000:
            self.git_checked_ns = now
            var root = find_repo(self.symidx_root())
            if root != self.git.root:
                self.git = GitStatus()
                self.git.root = root
                self.git_status_due = True
                self.git_index = FileSig()
            var ok = self.git.root.byte_length() > 0 and self.git_allowed(self.git.root)
            if ok != self.git_ok:
                # the folder was trusted (or the trust taken back): ask everything again
                self.git_ok = ok
                self.git_status_due = True
                self.git_forget_bases()
                if not ok:
                    self.git.clear()
                    self.explorer_show()
            var ip = self.git_index_path()
            if ip.byte_length() > 0:
                var sig = file_sig(ip)
                if not sig.same(self.git_index):
                    self.git_index = sig^
                    self.git_status_due = True
                    self.git_forget_bases()
        if self.git.root.byte_length() > 0 and self.explorer_index() >= 0 and now - self.git_status_ns > GIT_STATUS_MS * 1000000:
            self.git_status_due = True
        if self.git.root.byte_length() == 0 or not self.git_allowed(self.git.root):
            self.git_status_due = False     # nothing to ask (or not allowed to)
        if self.git_status_due and self.git.root.byte_length() > 0 and self.git_allowed(self.git.root):
            self.git_status_due = False
            self.git_status_ns = now
            self.git_start(GQ_STATUS, status_command(self.git.root), "")
            return
        # an open file whose version in the index is not known yet
        for i in range(len(self.wins)):
            if self.wins[i].kind != WK_EDITOR:
                continue
            var path = self.wins[i].path
            if self.wins[i].buf.git_path != path:
                self.wins[i].buf.git_state = GB_UNKNOWN
            if self.wins[i].buf.git_state != GB_UNKNOWN:
                continue
            var root = find_repo(dirname(path)) if path.byte_length() > 0 else String("")
            var rel = rel_to(root, path)
            if rel.byte_length() == 0 or not self.git_allowed(root) or self.wins[i].buf.large or self.wins[i].buf.count() > GIT_MAX_LINES:
                self.git_set_base(path)
                continue
            for j in range(len(self.wins)):
                if self.wins[j].kind == WK_EDITOR and self.wins[j].path == path:
                    self.wins[j].buf.git_state = GB_ASKED
                    self.wins[j].buf.git_path = path
            self.git_start(GQ_BASE, base_command(root, rel), path)
            return

    def git_allowed(self, root: String) -> Bool:
        """git runs what a repository's own configuration names (core.fsmonitor,
        filter drivers): only for repositories in a trusted folder. Nothing is asked;
        until then there are no markers or colours."""
        return not self.trust_enforced or self.trust.is_trusted(root)

    def git_start(mut self, req: Int, cmd: String, path: String):
        self.git_out.clear()
        self.git_req = req
        self.git_req_path = path
        if not self.git_proc.start(cmd):
            self.git_done(-1)

    def git_fd(self) -> Int:
        return self.git_proc.out_fd if self.git_proc.running else -1

    def git_done(mut self, status: Int):
        var req = self.git_req
        var path = self.git_req_path
        self.git_req = GQ_NONE
        var out = bytes_to_str(self.git_out)
        self.git_out.clear()
        if req == GQ_STATUS:
            if status == 0:
                self.git.parse(out)
            else:
                self.git.clear()
            self.explorer_show()
        elif req == GQ_BASE:
            if status == 0:
                self.git_base_text(path, out)
            else:
                self.git_set_base(path)

    def git_base_text(mut self, path: String, text: String):
        var h = text_hashes(decode(text))
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path == path:
                self.wins[i].buf.git_base = h.copy()
                self.wins[i].buf.git_state = GB_KNOWN
                self.wins[i].buf.git_path = path
                self.wins[i].buf.git_ver = -1

    def git_set_base(mut self, path: String):
        """No markers for `path` (it is not tracked, or not in a repository)."""
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path == path:
                self.wins[i].buf.git_state = GB_NONE
                self.wins[i].buf.git_path = path
                self.wins[i].buf.git_base.clear()
                self.wins[i].buf.git_marks.clear()
                self.wins[i].buf.git_ver = -1

    def git_marks_update(mut self, i: Int):
        """Work out window i's markers again if its text changed since."""
        if self.wins[i].buf.git_state != GB_KNOWN or self.wins[i].buf.git_ver == self.wins[i].buf.version:
            return
        var n = self.wins[i].buf.count()
        # (the empty line after a final line feed is not a line of the file, as in git)
        var cur = text_hashes(self.wins[i].buf.all_text())
        var base = self.wins[i].buf.git_base.copy()
        var marks = line_marks(diff_lines(base, cur), len(cur))
        while len(marks) < n:
            marks.append(UInt8(LM_NONE))
        self.wins[i].buf.git_marks = marks^
        self.wins[i].buf.git_ver = self.wins[i].buf.version

    def git_marks_all(mut self):
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR:
                self.git_marks_update(i)

    def git_saved(mut self):
        """A file was written: the explorer's colours may have changed."""
        self.git_status_due = True

    def git_counts(self, i: Int) -> Tuple[Int, Int, Int]:
        """Window i's lines added, changed and places where lines were removed."""
        var a = 0
        var c = 0
        var d = 0
        for m in self.wins[i].buf.git_marks:
            if m == LM_ADDED:
                a += 1
            elif m == LM_CHANGED:
                c += 1
            elif m != LM_NONE:
                d += 1
        return (a, c, d)
