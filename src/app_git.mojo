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
from window import Window, WK_EDITOR, WK_EXPLORER, WK_GIT
from buffer import TextBuffer
from git import *
from linediff import *
from watch import file_sig, FileSig
from app_outline import *
from app_explorer import *
from app_gitdiff import *
from app_gitcmd import *

comptime GQ_NONE = 0
comptime GQ_STATUS = 1
comptime GQ_BASE = 2
comptime GQ_HEAD = 3              # the diff view's file as in HEAD
comptime GQ_WRITE = 4             # staging or unstaging (a script that changes the index)
comptime GQ_COMMIT = 5
comptime GQ_BRANCHES = 6          # the list for the branch dialog
comptime GQ_SWITCH = 7
comptime GQ_BLAME = 8
comptime GQ_STASH = 9
comptime GQ_BLAME_INLINE = 10
comptime GQ_PUSH = 11
comptime GQ_PULL = 12
comptime GQ_FETCH = 13
comptime GIT_INDEX_MS = 1000      # how often the index file is looked at
comptime GIT_STATUS_MS = 3000     # with the explorer open, status at least this often
comptime GIT_MAX_LINES = 50000    # larger files get no markers (about 10 ms a change at this size)


__extension App:
    def git_repo_root(self) -> String:
        return self.git.root

    def git_index_path(self) -> String:
        """The index file of the project's repository, resolved across standard repos,
        linked git worktrees, and submodules."""
        if self.git.root.byte_length() == 0:
            return ""
        var dirs = resolve_git_dir(self.git.root)
        var gitdir = dirs[0]
        if gitdir.byte_length() == 0:
            return ""
        var idx = join_path(gitdir, "index")
        return idx if path_exists(idx) else String("")

    def git_forget_bases(mut self):
        """Ask git again for every open file's version (the index changed)."""
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.git_state != GB_ASKED:
                self.wins[i].buf.git_state = GB_UNKNOWN
        if self.gd_head_state != GB_ASKED:
            self.gd_head_state = GB_UNKNOWN     # a commit changes HEAD too

    def git_tick(mut self, now: Int):
        if self.git_proc.running:
            _ = self.git_proc.read_available()
            for b in self.git_proc.take():
                self.git_out.append(b)
            if not self.git_proc.eof:
                return
            var st = self.git_proc.stop()
            self.git_done(st)
            if self.git_proc.running:
                return
            # and on to the next command at once (not at the next wake-up)
        if now - self.git_checked_ns > GIT_INDEX_MS * 1000000:
            self.git_checked_ns = now
            var root = find_repo(self.symidx_root())
            if root != self.git.root:
                self.git = GitStatus()
                self.git.root = root
                self.git_status_due = True
                self.git_index = FileSig()
                if root.byte_length() > 0:
                    var dirs = resolve_git_dir(root)
                    var gdir = dirs[0]
                    var cdir = dirs[1]
                    if is_dir(gdir):
                        _ = self.watch.watch_dir(gdir)
                    if is_dir(cdir) and cdir != gdir:
                        var chdir = join_path(cdir, "refs/heads")
                        if is_dir(chdir):
                            _ = self.watch.watch_dir(chdir)
                    elif is_dir(gdir):
                        var hdir = join_path(gdir, "refs/heads")
                        if is_dir(hdir):
                            _ = self.watch.watch_dir(hdir)
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
        if len(self.git_q_req) > 0:
            # what was asked for (staging, HEAD for the diff view) comes first
            var req = self.git_q_req.pop(0)
            var cmd = self.git_q_cmd.pop(0)
            var qp = self.git_q_path.pop(0)
            self.git_start(req, cmd, qp)
            return
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
        if self.git_line_blame and not self.git_inline_asking:
            var ai = self.top_editor()
            if ai >= 0 and self.wins[ai].path.byte_length() > 0 and not self.wins[ai].buf.large and self.wins[ai].buf.count() <= GIT_MAX_LINES:
                var p = self.wins[ai].path
                var ver = self.wins[ai].buf.version
                if p != self.git_inline_path or ver != self.git_inline_ver:
                    var w = self.git_where(p)
                    if w[0].byte_length() > 0 and self.wins[ai].buf.git_state == GB_KNOWN:
                        var tmp = self.git_tmp_file("iblame")
                        if write_file(tmp, self.wins[ai].buf.to_bytes()):
                            self.git_inline_asking = True
                            self.git_inline_path = p
                            self.git_inline_ver = ver
                            self.git_start(GQ_BLAME_INLINE, blame_script(w[0], w[1], tmp), p)
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

    def git_queue(mut self, req: Int, cmd: String, path: String):
        """Run a git command after the one running now (at once if none is)."""
        self.git_q_req.append(req)
        self.git_q_cmd.append(cmd)
        self.git_q_path.append(path)
        if not self.git_proc.running:
            self.git_tick(now_ns())

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
            self.git_status_refresh()
        elif req == GQ_BASE:
            if status == 0:
                self.git_base_text(path, out)
            else:
                self.git_set_base(path)
        elif req == GQ_HEAD:
            if status == 0:
                self.gd_head = out
                self.gd_head_state = GB_KNOWN
            else:
                self.gd_head = ""
                self.gd_head_state = GB_NONE    # not in HEAD: a new file
        elif req == GQ_WRITE:
            if status != 0:
                self.say("git could not change the index for " + basename(path))
            self.git_status_due = True
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].path == path and self.wins[i].buf.git_state != GB_ASKED:
                    self.wins[i].buf.git_state = GB_UNKNOWN
        elif req == GQ_BLAME_INLINE:
            self.git_inline_asking = False
            if status == 0 and path == self.git_inline_path:
                self.git_inline_rows = parse_blame(out)
            else:
                self.git_inline_rows.clear()
        elif (
            req == GQ_COMMIT
            or req == GQ_BRANCHES
            or req == GQ_SWITCH
            or req == GQ_BLAME
            or req == GQ_STASH
            or req == GQ_PUSH
            or req == GQ_PULL
            or req == GQ_FETCH
        ):
            self.git_command_done(req, status, out, path)
        self.git_stamp += 1
        self.git_diff_refresh()

    def git_base_text(mut self, path: String, text: String):
        var h = text_hashes(decode(text))
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path == path:
                self.wins[i].buf.git_base = h.copy()
                self.wins[i].buf.git_base_text = text
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
                self.wins[i].buf.git_base_text = ""
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
