"""git commands with dialogs and views: File > Commit, Branch, Blame.

All run in the background through the git queue (app_git), only for repositories in a
trusted folder. What git prints (also its errors, and hooks' output) is shown when a
command fails.
"""
from std.collections import List
from std.ffi import external_call
from appstate import *
from app_notify import *
from util import *
from dialog import *
from window import Window, WK_EDITOR, WK_MESSAGE, WK_BLAME, WK_GIT, WK_GITLOG
from term import KEY_ENTER, KEY_ESC
from git import *
from project import find_up, ProjectMRU, parse_mru_toml
from symindex import SymbolIndex, FileIndex
from signals import own_pid
from app_git import *
from app_gitdiff import *
from app_jobs import *


__extension App:
    def git_repo_ready(mut self) -> Bool:
        """The project's repository may be used now (else it says why)."""
        if self.git.root.byte_length() == 0:
            self.git_checked_ns = 0
            self.git_tick(now_ns())
        if self.git.root.byte_length() == 0:
            self.say("This folder is not in a git repository")
            return False
        if not self.git_allowed(self.git.root):
            self.say("git is only used in trusted folders (Options > Folder trust)")
            return False
        return True

    def git_tmp_file(mut self, tag: String) -> String:
        self.git_tmp_n += 1
        return env_or("TMPDIR", "/tmp") + "/turbomojo-" + tag + "-" + String(own_pid()) + "-" + String(self.git_tmp_n)

    # ----------------------------------------------------------------- commit
    def git_commit_dialog(mut self, amend_now: Bool = False):
        if not self.git_repo_ready():
            return
        var d = Dialog(D_GIT_COMMIT, "Commit" + ((" on " + self.git.branch) if self.git.branch.byte_length() > 0 else String("")), min(72, self.scr.w - 4), 16)
        var n = len(self.git.staged)
        var nu = self.git.untracked_count()
        if n == 0:
            d.lines.append("Nothing is staged (tick the second box to commit every change")
            d.lines.append("to tracked files, or stage changes in File > Diff of this file).")
        else:
            var names = String("")
            for k in range(min(4, n)):
                names += (", " if k > 0 else "") + basename(self.git.staged[k])
            if n > 4:
                names += ", ..."
            d.lines.append(count_of(n, "file") + " staged: " + names)
        var unsaved = 0
        for w in self.wins:
            if w.kind == WK_EDITOR and w.buf.modified and w.path.byte_length() > 0:
                unsaved += 1
        if unsaved > 0:
            d.lines.append(count_of(unsaved, "file") + " not saved: what is in the editor is not committed")
        var init_sum = String("")
        var init_det = String("")
        if amend_now:
            init_sum = String(bytes_to_str(run_capture("git -C " + shell_quote(self.git.root) + " log -1 --format=%s 2>/dev/null").out).strip())
            init_det = String(bytes_to_str(run_capture("git -C " + shell_quote(self.git.root) + " log -1 --format=%b 2>/dev/null").out).strip())
        d.fields.append(Field("~S~ummary", init_sum))
        d.fields.append(Field("~D~etails", init_det))
        d.checks.append("~A~mend the last commit")
        d.check_vals.append(amend_now)
        d.checks.append("Include all changes to ~t~racked files")
        d.check_vals.append(n == 0)
        d.checks.append("Include ~u~ntracked files" + ((" (" + String(nu) + ")") if nu > 0 else String("")))
        d.check_vals.append(False)
        d.buttons.append("~C~ommit")
        d.buttons.append("Cancel")
        self.show(d^)

    def git_commit(mut self, summary: String, details: String, amend: Bool, all: Bool, add_untracked: Bool = False):
        if not self.git_repo_ready():
            return
        var s = String(summary.strip())
        var msg = String("")
        if s.byte_length() == 0:
            if not amend:
                self.say("A commit needs a summary")
                return
        else:
            msg = self.git_tmp_file("commit")
            if not write_file(msg, str_bytes(commit_message(s, details))):
                self.say("Could not write " + msg)
                return
        self.git_queue(GQ_COMMIT, commit_script(self.git.root, msg, amend, all, add_untracked), "")
        self.say("Committing...")

    # --------------------------------------------------------------- branches
    def git_branch_dialog(mut self):
        if not self.git_repo_ready():
            return
        self.git_queue(GQ_BRANCHES, branches_command(self.git.root), "")

    def git_branch_list(mut self, output: String):
        var got = parse_branches(output)
        var names = got[0].copy()
        var current = got[1]
        self.git_branches = names.copy()
        var items = List[String]()
        var data = List[Int]()
        for k in range(len(names)):
            items.append(("* " if names[k] == current else "  ") + names[k])
            data.append(k)
        var d = Dialog(D_GIT_BRANCH, "Branch", min(60, self.scr.w - 4), min(20, max(14, len(items) + 9)))
        d.fields.append(Field("~B~ranch", ""))
        d.list_filter = True
        d.keys = names^
        d.set_items(items^, data^)
        d.lines.append("Enter: switch to it. New branch: make the name typed.")
        d.buttons.append("~S~witch")
        d.buttons.append("~N~ew branch")
        d.buttons.append("Cancel")
        self.show(d^)

    def git_branch_button(mut self, b: Int, sel: Int, typed: String):
        var name = String(typed.strip())
        if b == 0:
            if sel >= 0 and sel < len(self.git_branches):
                name = self.git_branches[sel]
                if name == self.git.branch:
                    self.say("Already on " + name)
                    return
                self.git_queue(GQ_SWITCH, switch_script(self.git.root, name, False), name)
                return
            if name.byte_length() == 0:
                return
            # nothing matches what was typed: make it
        elif b != 1:
            return
        var problem = branch_name_problem(name)
        if problem.byte_length() > 0:
            self.say(problem)
            return
        self.git_queue(GQ_SWITCH, switch_script(self.git.root, name, True), name)

    # ------------------------------------------------------------------ blame
    def blame_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_BLAME:
                return i
        return -1

    def git_blame_open(mut self):
        var ei = self.git_editor_target()
        if ei < 0:
            self.say("No file to blame")
            return
        var path = self.wins[ei].path
        var w = self.git_where(path)
        if w[0].byte_length() == 0:
            _ = self.git_known(ei)          # says why
            return
        var tmp = self.git_tmp_file("blame")
        if not write_file(tmp, self.wins[ei].buf.to_bytes()):
            self.say("Could not write " + tmp)
            return
        self.git_queue(GQ_BLAME, blame_script(w[0], w[1], tmp), path)
        self.say("Asking git who changed what...")

    def git_blame_show(mut self, path: String, output: String):
        var ei = self.find_editor(path)
        if ei < 0:
            return
        self.blame_path = path
        self.blame_rows = parse_blame(output)
        var width = 0
        for r in self.blame_rows:
            width = max(width, min(16, cp_len(r.author)))
        var text = List[Int]()
        for k in range(len(self.blame_rows)):
            ref r = self.blame_rows[k]
            var head: String
            if is_uncommitted(r.sha):
                head = pad_right("(not committed)", 19 + width)
            else:
                var who = r.author
                if cp_len(who) > width:
                    who = slice_str(decode(who), 0, width)
                head = String(r.sha[byte=0:7]) + " " + ymd(r.time) + " " + pad_right(who, width)
            if k > 0:
                text.append(10)
            for c in decode(head + " │ " + r.line):
                text.append(c)
        var bi = self.blame_index()
        if bi < 0:
            var win = Window(WK_BLAME, "Blame", "blame:" + path, self.wins[ei].x, self.wins[ei].y, self.wins[ei].w, self.wins[ei].h, self.free_number())
            self.wins.append(win^)
            bi = len(self.wins) - 1
        else:
            self.focus(bi)
            bi = self.top()
        self.wins[bi].title = "Blame: " + basename(path)
        self.wins[bi].path = "blame:" + path
        self.wins[bi].buf.load(text)
        self.wins[bi].buf.modified = False
        ei = self.find_editor(path)
        self.wins[bi].cr = min(self.wins[ei].cr, self.wins[bi].buf.count() - 1)
        self.wins[bi].follow = True
        self.say("Blame of " + basename(path) + ": Enter goes to the line")

    def git_blame_summary(self) -> String:
        """The commit of the blame window's current line, for the status line."""
        var bi = self.blame_index()
        if bi < 0:
            return ""
        var r = self.wins[bi].cr
        if r >= len(self.blame_rows):
            return ""
        if is_uncommitted(self.blame_rows[r].sha):
            return "Not committed yet"
        # (a ~ would mark a hot key in the status line)
        return String(self.blame_rows[r].sha[byte=0:7]) + " " + self.blame_rows[r].summary.replace("~", "-")

    def git_blame_key(mut self, k: Int) raises -> Bool:
        var t = self.top()
        if k == KEY_ESC:
            _ = self.wins.pop(t)
            var ei = self.find_editor(self.blame_path)
            if ei >= 0:
                self.focus(ei)
            return True
        if k == KEY_ENTER:
            var row = self.wins[t].cr
            var ei = self.find_editor(self.blame_path)
            if ei < 0:
                return True
            self.focus(ei)
            ei = self.top()
            self.wins[ei].cr = min(row, self.wins[ei].buf.count() - 1)
            self.wins[ei].cc = 0
            self.wins[ei].follow = True
            return True
        return False

    def git_info(mut self, title: String, head: String, text: String):
        """A message box with what git said (its last lines, wrapped)."""
        var w = min(76, self.scr.w - 4)
        var lines = List[String]()
        for l in text.split("\n"):
            for p in wrap_plain(String(l), w - 6):
                lines.append(p)
        var keep = min(len(lines), max(1, self.scr.h - 12))
        var d = Dialog(D_INFO, title, w, keep + 7)
        d.lines.append(head)
        for k in range(len(lines) - keep, len(lines)):
            d.lines.append(lines[k])
        d.buttons.append("~O~K")
        d.focus = d.button_focus_index(0)
        self.show(d^)

    # ------------------------------------------------------------ results
    def git_command_done(mut self, req: Int, status: Int, output: String, path: String):
        var text = String(output.strip())
        if req == GQ_BRANCHES:
            if status == 0:
                self.git_branch_list(output)
            else:
                self.git_info("Branch", "git could not list the branches:", text)
            return
        if req == GQ_BLAME:
            if status == 0:
                self.git_blame_show(path, output)
            else:
                self.git_info("Blame", "git blame failed:", text)
            return
        # commit and switch change HEAD, the index and maybe the files
        self.git_status_due = True
        self.git_forget_bases()
        if req == GQ_COMMIT:
            if status == 0:
                self.say(String(text.split("\n")[0]))
                self.notify_as("git", NL_DONE, "Committed", String(text.split("\n")[0]), True)
            else:
                self.git_info("Commit", "git did not commit:", text)
                self.notify_as("git", NL_ERROR, "git did not commit", String(text.split("\n")[len(text.split("\n")) - 1]), True)
        elif req == GQ_SWITCH:
            if status == 0:
                var shown = String(path[byte=7:]) if path.startswith("origin/") else path
                self.say("On branch " + shown + " now")
                self.notify_as("git", NL_DONE, "Branch", "On " + shown + " now", True)
                self.watch_recheck = True       # files git changed on disk are reloaded (or asked about)
            else:
                self.git_info("Branch", "git did not switch to " + path + ":", text)
        elif req == GQ_STASH:
            if status == 0:
                var first_line = String(text.split("\n")[0]) if text.byte_length() > 0 else String("Stash updated")
                self.say(first_line)
                self.notify_as("git", NL_DONE, "Stash", first_line, True)
                self.watch_recheck = True
            else:
                self.git_info("Stash", "git stash failed:", text)
        elif req == GQ_PUSH or req == GQ_PULL or req == GQ_FETCH:
            var label = "Push" if req == GQ_PUSH else ("Pull (--rebase)" if req == GQ_PULL else "Fetch (--prune)")
            self.watch_recheck = True
            if status == 0:
                var done_msg = String(text.split("\n")[0]) if text.byte_length() > 0 else (label + " complete")
                self.say("Git " + label + ": " + done_msg)
                self.notify_as("git", NL_DONE, "Git " + label, done_msg, True)
            else:
                var err_line = String(text.split("\n")[len(text.split("\n")) - 1]) if text.byte_length() > 0 else (label + " failed")
                self.git_info("Git " + label, "git " + label.lower() + " failed:", text)
                self.notify_as("git", NL_ERROR, "Git " + label + " failed", err_line, True)

    # ------------------------------------------------- commit graph & history (F29)
    def git_log_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_GITLOG:
                return i
        return -1

    def git_log_open(mut self, file_path: String = ""):
        if not self.git_repo_ready():
            return
        var cap = run_capture(graph_log_command(self.git.root, file_path) + " 2>/dev/null")
        var nodes = parse_graph_log(bytes_to_str(cap.out))
        self.git_log_shas.clear()
        self.git_log_file = file_path
        var lines = List[String]()
        var first_commit_row = 0
        var found_first = False
        for k in range(len(nodes)):
            ref n = nodes[k]
            if n.sha.byte_length() == 0:
                lines.append(n.lane)
                self.git_log_shas.append("")
                continue
            if not found_first:
                first_commit_row = k
                found_first = True
            var dt = ymd(n.timestamp) if n.timestamp > 0 else String("          ")
            var who = n.author
            if cp_len(who) > 14:
                who = slice_str(decode(who), 0, 14)
            else:
                who = pad_right(who, 14)
            var deco = (" " + n.decoration) if n.decoration.byte_length() > 0 else String("")
            var lane_part = (n.lane + " ") if n.lane.byte_length() > 0 else String("* ")
            lines.append(lane_part + n.sha + "  " + dt + "  " + who + "  " + n.summary + deco)
            self.git_log_shas.append(n.sha)
        if len(lines) == 0:
            lines.append("(no commits in repository)")
            self.git_log_shas.append("")
        var text = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for c in decode(lines[k]):
                text.append(c)
        var li = self.git_log_index()
        var ei = self.top_editor()
        if li < 0:
            var x = self.wins[ei].x if ei >= 0 else 0
            var y = self.wins[ei].y if ei >= 0 else 1
            var w = self.wins[ei].w if ei >= 0 else self.scr.w
            var h = self.wins[ei].h if ei >= 0 else self.desk_h()
            var win = Window(WK_GITLOG, "Git Log", "gitlog:" + file_path, x, y, w, h, self.free_number())
            self.wins.append(win^)
            li = len(self.wins) - 1
        else:
            self.focus(li)
            li = self.top()
        var scope_label = basename(file_path) if file_path.byte_length() > 0 else (self.git.branch if self.git.branch.byte_length() > 0 else String("HEAD"))
        self.wins[li].title = "Git Log: " + scope_label
        self.wins[li].path = "gitlog:" + file_path
        self.wins[li].buf.load(text)
        self.wins[li].buf.modified = False
        self.wins[li].cr = min(first_commit_row, self.wins[li].buf.count() - 1)
        self.wins[li].top = 0
        self.wins[li].follow = True
        self.say("Git Log: Enter/d diff, y copy SHA, C cherry-pick, R revert, f file filter, q/Esc close")

    def git_log_key(mut self, k: Int) raises -> Bool:
        var t = self.top()
        var row = self.wins[t].cr
        var sha = self.git_log_shas[row] if row >= 0 and row < len(self.git_log_shas) else String("")
        if k == KEY_ESC or k == 113:  # Esc / q
            _ = self.wins.pop(t)
            var gi = self.git_status_index()
            if gi >= 0:
                self.focus(gi)
            else:
                var ei = self.top_editor()
                if ei >= 0:
                    self.focus(ei)
            return True
        if k == KEY_ENTER or k == 100:  # Enter / d: view commit diff
            if sha.byte_length() == 0:
                self.say("Move cursor onto a commit row")
                return True
            var diff_text = commit_diff(self.git.root, sha)
            self.panel_write(PG_MESSAGE)
            var mi = self.ensure_msg()
            self.wins[mi].buf.load(decode(diff_text if diff_text.byte_length() > 0 else ("Commit " + sha)))
            self.wins[mi].buf.modified = False
            self.wins[mi].cr = 0
            self.wins[mi].top = 0
            self.say("Commit " + sha + " diff opened in Message panel")
            return True
        if k == 121:  # y: copy SHA to clipboard via OSC 52
            if sha.byte_length() == 0:
                self.say("No commit SHA on this row")
                return True
            self.clipboard = decode(sha)
            self.osc52(self.clipboard.copy())
            self.say("Copied commit SHA " + sha)
            return True
        if k == 67:  # C: cherry-pick
            if sha.byte_length() == 0:
                return True
            var rc = cherry_pick(self.git.root, sha)
            self.git_status_due = True
            self.git_forget_bases()
            self.watch_recheck = True
            if rc == 0:
                var keep_file = self.git_log_file
                self.git_log_open(keep_file)
                self.say("Cherry-picked " + sha)
            else:
                self.say("Cherry-pick conflict on " + sha + " — resolve conflicts or abort")
            return True
        if k == 82:  # R: revert commit
            if sha.byte_length() == 0:
                return True
            var rc = revert_commit(self.git.root, sha)
            self.git_status_due = True
            self.git_forget_bases()
            self.watch_recheck = True
            if rc == 0:
                var keep_file = self.git_log_file
                self.git_log_open(keep_file)
                self.say("Reverted commit " + sha)
            else:
                self.say("Revert failed or conflicted on " + sha)
            return True
        if k == 102:  # f: toggle file-scoped log
            if self.git_log_file.byte_length() > 0:
                self.git_log_open("")
            else:
                var ei = self.top_editor()
                if ei >= 0 and self.wins[ei].path.byte_length() > 0:
                    var fp = String(self.wins[ei].path)
                    self.git_log_open(fp)
                else:
                    self.say("No open editor file to filter history")
            return True
        return False

    # ----------------------------------------------- remote sync & stash picker (F31)
    def git_remote_sync(mut self, op: String):
        if not self.git_repo_ready():
            return
        var req = GQ_FETCH
        var verb = String("Fetching (--prune)...")
        if op == "P" or op == "push":
            req = GQ_PUSH
            verb = "Pushing to origin..."
        elif op == "p" or op == "pull" or op == "pull_rebase":
            req = GQ_PULL
            verb = "Pulling (--rebase) from origin..."
        var branch = String("")
        if (req == GQ_PUSH or req == GQ_PULL) and self.git.branch.byte_length() > 0 and not self.git.branch.startswith("("):
            branch = self.git.branch
        var script = remote_sync_script(self.git.root, op, "origin", branch)
        self.git_queue(req, sh_script(script + " </dev/null 2>&1"), "")
        self.say(verb)

    def git_stash_list_open(mut self):
        if not self.git_repo_ready():
            return
        var cap = run_capture("git -C " + shell_quote(self.git.root) + " --no-optional-locks stash list 2>/dev/null")
        var entries = parse_stash_list(bytes_to_str(cap.out))
        self.git_stash_refs.clear()
        var items = List[String]()
        var data = List[Int]()
        var keys = List[String]()
        for k in range(len(entries)):
            ref e = entries[k]
            self.git_stash_refs.append(e.index)
            var label = e.stash_ref + ": " + e.message
            items.append(label)
            keys.append(label)
            data.append(k)
        var d = Dialog(D_GIT_STASH, "Git Stashes", min(74, self.scr.w - 4), min(20, max(14, len(items) + 9)))
        d.fields.append(Field("~M~essage", ""))
        d.list_filter = True
        d.keys = keys^
        d.set_items(items^, data^)
        d.lines.append("Select a stash to Apply/Pop/Drop/View, or enter a message to Push new.")
        d.buttons.append("~A~pply")
        d.buttons.append("~P~op")
        d.buttons.append("~D~rop")
        d.buttons.append("P~u~sh new")
        d.buttons.append("~V~iew diff")
        d.buttons.append("Cancel")
        self.show(d^)

    def git_stash_action(mut self, action: String, sel: Int = 0, msg: String = ""):
        if not self.git_repo_ready():
            return
        var act = action.lower()
        if act == "push" or act == "new":
            var script = stash_push_script(self.git.root, String(msg.strip()), True)
            self.git_queue(GQ_STASH, sh_script(script + " </dev/null 2>&1"), "")
            self.say("Stashing changes...")
            return
        if len(self.git_stash_refs) == 0:
            self.say("No stashes in repository")
            return
        var idx_pos = max(0, min(sel, len(self.git_stash_refs) - 1))
        var stash_idx = self.git_stash_refs[idx_pos]
        if act == "apply":
            self.git_queue(GQ_STASH, sh_script(stash_apply_script(self.git.root, stash_idx) + " </dev/null 2>&1"), "")
            self.say("Applying stash@{" + String(stash_idx) + "}...")
        elif act == "pop":
            self.git_queue(GQ_STASH, sh_script(stash_pop_script(self.git.root, stash_idx) + " </dev/null 2>&1"), "")
            self.say("Popping stash@{" + String(stash_idx) + "}...")
        elif act == "drop":
            self.git_queue(GQ_STASH, sh_script(stash_drop_script(self.git.root, stash_idx) + " </dev/null 2>&1"), "")
            self.say("Dropping stash@{" + String(stash_idx) + "}...")
        elif act == "preview" or act == "view":
            var diff_out = stash_preview(self.git.root, stash_idx)
            self.panel_write(PG_MESSAGE)
            var mi = self.ensure_msg()
            self.wins[mi].buf.load(decode(diff_out if diff_out.byte_length() > 0 else ("(stash@{" + String(stash_idx) + "} is empty)")))
            self.wins[mi].buf.modified = False
            self.wins[mi].cr = 0
            self.wins[mi].top = 0
            self.say("Showing stash@{" + String(stash_idx) + "} in Message panel")

    def git_stash_button(mut self, b: Int, sel: Int, msg: String):
        if b == 0:
            self.git_stash_action("apply", sel, msg)
        elif b == 1:
            self.git_stash_action("pop", sel, msg)
        elif b == 2:
            self.git_stash_action("drop", sel, msg)
        elif b == 3:
            self.git_stash_action("push", sel, msg)
        elif b == 4:
            self.git_stash_action("preview", sel, msg)

    # ------------------------------------ project switcher & worktrees (F32)
    def mru_projects_path(self) -> String:
        var sd = state_dir()
        if sd.byte_length() == 0:
            return ""
        return sd + "/projects.toml"

    def mru_sync_load(mut self):
        var p = self.mru_projects_path()
        var mru = ProjectMRU(12)
        var existing = List[String]()
        if p.byte_length() > 0 and path_exists(p):
            existing = parse_mru_toml(read_text(p))
        var i = len(existing) - 1
        while i >= 0:
            mru.record_visit(existing[i])
            i -= 1
        var j = len(self.mru_paths) - 1
        while j >= 0:
            mru.record_visit(self.mru_paths[j])
            j -= 1
        if self.cwd.byte_length() > 0:
            mru.record_visit(self.cwd)
        self.mru_paths = mru.entries.copy()

    def mru_record_project(mut self, target: String):
        self.mru_sync_load()
        var mru = ProjectMRU(12)
        var i = len(self.mru_paths) - 1
        while i >= 0:
            mru.record_visit(self.mru_paths[i])
            i -= 1
        mru.record_visit(target)
        self.mru_paths = mru.entries.copy()
        var p = self.mru_projects_path()
        if p.byte_length() > 0:
            var dir = dirname(p)
            if not path_exists(dir):
                _ = run_system("mkdir -p " + shell_quote(dir))
            _ = write_file(p, str_bytes(mru.to_toml()))

    def switch_project_open(mut self):
        self.mru_sync_load()
        var items = List[String]()
        var data = List[Int]()
        var keys = List[String]()
        for k in range(len(self.mru_paths)):
            var p = self.mru_paths[k]
            var mark = "* " if p == self.cwd else "  "
            items.append(mark + p)
            keys.append(p)
            data.append(k)
        var d = Dialog(D_SWITCH_PROJECT, "Switch Project", min(76, self.scr.w - 4), min(20, max(13, len(items) + 8)))
        d.fields.append(Field("~P~roject path", ""))
        d.list_filter = True
        d.keys = keys^
        d.set_items(items^, data^)
        d.lines.append("Choose a recent project or type a folder path.")
        d.buttons.append("~S~witch")
        d.buttons.append("Cancel")
        self.show(d^)

    def switch_project_to(mut self, dir: String) raises:
        var raw = String(dir.strip())
        if raw.byte_length() == 0:
            self.say("Project path is empty")
            return
        var target = normalize_path(abs_path(self.cwd, raw))
        if not path_exists(target) or not is_dir(target):
            self.say("Project folder does not exist: " + target)
            return
        self.session_save()
        var cpath = target.copy()
        _ = external_call["chdir", Int32](cpath.as_c_string_span())
        self.cwd = target
        var proj_cfg = find_up(target, ".turbomojo.toml")
        self.project_dir = proj_cfg
        if self.config_path.byte_length() > 0:
            self.load_config()
        if self.project_dir.byte_length() == 0:
            self.project_dir = find_up(target, "pixi.toml")
        self.pixi_for = "\x01"
        self.pixi_found = ""
        self.tasks.clear()
        self.ex.set_root(target)
        self.explorer_show()
        self.fidx = FileIndex()
        self.symidx = SymbolIndex()
        self.git = GitStatus()
        self.git_checked_ns = 0
        self.git_status_due = True
        self.git_forget_bases()
        self.git_tick(now_ns())
        self.mru_record_project(target)
        self.say("Switched project to " + target)

    def switch_project_button(mut self, b: Int, sel: Int, typed: String) raises:
        if b != 0:
            return
        var chosen = String(typed.strip())
        if chosen.byte_length() == 0 and sel >= 0 and sel < len(self.mru_paths):
            chosen = self.mru_paths[sel]
        if chosen.byte_length() > 0:
            self.switch_project_to(chosen)

    def git_worktree_open(mut self):
        if not self.git_repo_ready():
            return
        var cap = run_capture("git -C " + shell_quote(self.git.root) + " --no-optional-locks worktree list --porcelain 2>/dev/null")
        var records = parse_worktree_list(bytes_to_str(cap.out))
        self.git_wt_paths.clear()
        var items = List[String]()
        var data = List[Int]()
        var keys = List[String]()
        for k in range(len(records)):
            ref r = records[k]
            self.git_wt_paths.append(r.path)
            var mark = "* " if r.path == self.git.root or r.path == self.cwd else "  "
            var tag = ("[" + r.branch + "]") if r.branch.byte_length() > 0 else ("(bare)" if r.bare else "(detached)")
            var label = mark + r.path + "  " + tag
            items.append(label)
            keys.append(r.path + " " + r.branch)
            data.append(k)
        var d = Dialog(D_GIT_WORKTREE, "Git Worktrees", min(78, self.scr.w - 4), min(20, max(14, len(items) + 9)))
        d.fields.append(Field("~P~ath [branch]", ""))
        d.list_filter = True
        d.keys = keys^
        d.set_items(items^, data^)
        d.lines.append("Switch to a worktree, Add (<path> [branch]), or Prune stale metadata.")
        d.buttons.append("~S~witch")
        d.buttons.append("~A~dd")
        d.buttons.append("~P~rune")
        d.buttons.append("Cancel")
        self.show(d^)

    def git_worktree_button(mut self, b: Int, sel: Int, typed: String) raises:
        if b == 0:  # Switch
            var target = String("")
            if sel >= 0 and sel < len(self.git_wt_paths):
                target = self.git_wt_paths[sel]
            elif String(typed.strip()).byte_length() > 0:
                target = String(typed.strip())
            if target.byte_length() > 0:
                self.switch_project_to(target)
        elif b == 1:  # Add
            if not self.git_repo_ready():
                return
            var spec = String(typed.strip())
            if spec.byte_length() == 0:
                self.say("Specify a worktree folder path (and optional branch)")
                return
            var wt_path = spec
            var br = String("")
            var sp = spec.find(" ")
            if sp > 0:
                wt_path = String(spec[byte=0:sp].strip())
                br = String(spec[byte=sp + 1:].strip())
            wt_path = normalize_path(abs_path(self.cwd, wt_path))
            var new_br = False
            if br.byte_length() > 0:
                var check_rc = run_system("git -C " + shell_quote(self.git.root) + " show-ref --verify --quiet " + shell_quote("refs/heads/" + br))
                new_br = check_rc != 0
            if worktree_add(self.git.root, wt_path, br, new_br) == 0:
                self.switch_project_to(wt_path)
            else:
                self.say("git worktree add failed for " + wt_path)
        elif b == 2:  # Prune
            if not self.git_repo_ready():
                return
            if worktree_prune(self.git.root) == 0:
                self.say("Pruned stale git worktrees")
            else:
                self.say("git worktree prune failed")

    # ----------------------------------------------------------- stash & status
    def git_stash(mut self, pop: Bool):
        if not self.git_repo_ready():
            return
        self.git_queue(GQ_STASH, stash_script(self.git.root, pop), "")
        self.say("Applying stash..." if pop else "Stashing changes...")

    def git_status_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_GIT:
                return i
        return -1

    def git_status_open(mut self):
        if not self.git_repo_ready():
            return
        var gi = self.git_status_index()
        if gi >= 0:
            if self.top() == gi:
                var x = self.wins[gi].x
                _ = self.wins.pop(gi)
                for i in range(len(self.wins)):
                    if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                        self.wins[i].w = self.scr.w - self.wins[i].x
                return
            self.focus(gi)
            self.git_status_due = True
            self.git_tick(now_ns())
            self.git_status_refresh()
            return
        var w = max(32, min(52, self.scr.w * 2 // 5))
        var x = self.scr.w - w
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            h = max(6, self.wins[mi].y - 1)
        var win = Window(WK_GIT, "Git Status", "", x, 1, w, h, self.free_number())
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w > x and x - self.wins[i].x >= 20:
                self.wins[i].w = x - self.wins[i].x
        self.wins.append(win^)
        self.git_status_due = True
        self.git_tick(now_ns())
        self.git_status_refresh()
        self.say("Git Status: Space stages/unstages, Enter opens, D diffs, C commits, B branches, Z stashes")

    def git_status_refresh(mut self):
        var gi = self.git_status_index()
        if gi < 0:
            return
        var lines = List[String]()
        var colors = List[Int]()
        var paths = List[String]()
        var staged_flags = List[Bool]()
        var head = "Branch: " + (self.git.branch if self.git.branch.byte_length() > 0 else String("(detached)"))
        if self.git.ahead > 0:
            head += " ↑" + String(self.git.ahead)
        if self.git.behind > 0:
            head += " ↓" + String(self.git.behind)
        lines.append(head)
        colors.append(GS_NONE)
        paths.append("")
        staged_flags.append(False)
        lines.append("")
        colors.append(GS_NONE)
        paths.append("")
        staged_flags.append(False)
        if len(self.git.staged) > 0:
            lines.append("Staged (" + String(len(self.git.staged)) + "):")
            colors.append(GS_ADDED)
            paths.append("")
            staged_flags.append(False)
            for p in self.git.staged:
                var rel = rel_to(self.git.root, p)
                var code = self.git.files.get(p, GS_MODIFIED)
                lines.append("  [" + status_letter(code) + "] " + (rel if rel.byte_length() > 0 else basename(p)))
                colors.append(GS_ADDED)
                paths.append(p)
                staged_flags.append(True)
            lines.append("")
            colors.append(GS_NONE)
            paths.append("")
            staged_flags.append(False)
        var unstaged = List[String]()
        var untracked = List[String]()
        var conflicts = List[String]()
        for entry in self.git.files.items():
            var p = entry.key
            var c = entry.value
            if c == GS_CONFLICT:
                conflicts.append(p)
            elif c == GS_UNTRACKED:
                untracked.append(p)
            elif not (p in self.git.staged) or c == GS_MODIFIED or c == GS_DELETED:
                if not (p in self.git.staged):
                    unstaged.append(p)
        for d in self.git.untracked_dirs:
            untracked.append(d)
        if len(conflicts) > 0:
            lines.append("Conflicts (" + String(len(conflicts)) + "):")
            colors.append(GS_CONFLICT)
            paths.append("")
            staged_flags.append(False)
            for p in conflicts:
                var rel = rel_to(self.git.root, p)
                lines.append("  [C] " + (rel if rel.byte_length() > 0 else basename(p)))
                colors.append(GS_CONFLICT)
                paths.append(p)
                staged_flags.append(False)
            lines.append("")
            colors.append(GS_NONE)
            paths.append("")
            staged_flags.append(False)
        if len(unstaged) > 0:
            lines.append("Changes (" + String(len(unstaged)) + "):")
            colors.append(GS_MODIFIED)
            paths.append("")
            staged_flags.append(False)
            for p in unstaged:
                var rel = rel_to(self.git.root, p)
                var code = self.git.files.get(p, GS_MODIFIED)
                lines.append("  [" + status_letter(code) + "] " + (rel if rel.byte_length() > 0 else basename(p)))
                colors.append(code)
                paths.append(p)
                staged_flags.append(False)
            lines.append("")
            colors.append(GS_NONE)
            paths.append("")
            staged_flags.append(False)
        if len(untracked) > 0:
            lines.append("Untracked (" + String(len(untracked)) + "):")
            colors.append(GS_UNTRACKED)
            paths.append("")
            staged_flags.append(False)
            for p in untracked:
                var rel = rel_to(self.git.root, p)
                var suffix = "/" if is_dir(p) else ""
                lines.append("  [U] " + (rel if rel.byte_length() > 0 else basename(p)) + suffix)
                colors.append(GS_UNTRACKED)
                paths.append(p)
                staged_flags.append(False)
        if len(self.git.staged) == 0 and len(conflicts) == 0 and len(unstaged) == 0 and len(untracked) == 0:
            lines.append("Working tree clean.")
            colors.append(GS_NONE)
            paths.append("")
            staged_flags.append(False)
        var text = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for ch in decode(lines[k]):
                text.append(ch)
        var keep = self.wins[gi].cr
        var keep_top = self.wins[gi].top
        self.wins[gi].title = "Git: " + (self.git.branch if self.git.branch.byte_length() > 0 else String("status"))
        self.wins[gi].buf.load(text)
        self.wins[gi].buf.modified = False
        self.wins[gi].git_rows = colors^
        self.wins[gi].cr = max(0, min(keep, self.wins[gi].buf.count() - 1))
        self.wins[gi].top = max(0, min(keep_top, self.wins[gi].buf.count() - 1))
        self.git_status_paths = paths^
        self.git_status_staged = staged_flags^

    def git_status_key(mut self, k: Int) raises -> Bool:
        var gi = self.top()
        var row = self.wins[gi].cr
        var sel_path = self.git_status_paths[row] if row >= 0 and row < len(self.git_status_paths) else String("")
        var sel_staged = self.git_status_staged[row] if row >= 0 and row < len(self.git_status_staged) else False
        if k == KEY_ESC:
            var x = self.wins[gi].x
            _ = self.wins.pop(gi)
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                    self.wins[i].w = self.scr.w - self.wins[i].x
            var ei = self.top_editor()
            if ei >= 0:
                self.focus(ei)
            return True
        if k == KEY_ENTER:
            if sel_path.byte_length() > 0 and not is_dir(sel_path):
                self.open_path(sel_path)
            return True
        if k == 100 or k == 68:  # d / D: diff of selected file (editor-free)
            if sel_path.byte_length() > 0 and not is_dir(sel_path):
                self.git_diff_open_path(sel_path, sel_staged)
            return True
        if k == 32 or k == 115 or k == 117 or k == 85:  # Space / s / u / U: stage or unstage file
            if sel_path.byte_length() > 0 and self.git.root.byte_length() > 0:
                var rel = rel_to(self.git.root, sel_path)
                if rel.byte_length() > 0:
                    var unstage = sel_staged or k == 117 or k == 85
                    self.git_queue(GQ_WRITE, stage_file_script(self.git.root, rel, unstage), sel_path)
                    self.say(("Unstaging " if unstage else "Staging ") + basename(sel_path) + "...")
            return True
        if k == 83:              # S: stash list picker
            self.git_stash_list_open()
            return True
        if k == 76:              # L: commit graph & history browser
            self.git_log_open()
            return True
        if k == 80:              # P: push
            self.git_remote_sync("P")
            return True
        if k == 112:             # p: pull --rebase
            self.git_remote_sync("p")
            return True
        if k == 70:              # F: fetch --prune
            self.git_remote_sync("F")
            return True
        if k == 99 or k == 67:   # c: commit
            self.git_commit_dialog(False)
            return True
        if k == 97 or k == 65:   # a: amend commit (pre-filled)
            self.git_commit_dialog(True)
            return True
        if k == 98 or k == 66:   # b: branches
            self.git_branch_dialog()
            return True
        if k == 122:             # z: stash push
            self.git_stash(False)
            return True
        if k == 90:              # Z: stash pop
            self.git_stash(True)
            return True
        if k == 114 or k == 82:  # r: refresh
            self.git_status_due = True
            self.git_tick(now_ns())
            return True
        return False
