"""The diff view and the change (hunk) commands: File > Diff of this file, Stage change,
Revert change, Next / Previous change.

"Changes" compares the buffer (as edited) with git's index, the same as the gutter's
markers; "Staged" (Tab in the view) compares the index with HEAD. Staging and unstaging
work out the index's new text here (gitdiff.with_hunk / without_hunk) and give it to git
whole (`hash-object` + `update-index --cacheinfo`), so no patch has to apply; reverting
is an ordinary, undoable edit of the buffer.
"""
from std.collections import List
from appstate import *
from util import *
from window import Window, WK_EDITOR, WK_DIFF, ACT_OTHER
from term import KEY_ENTER, KEY_ESC, KEY_TAB
from buffer import TextBuffer
from git import *
from linediff import *
from gitdiff import *
from watch import file_sig
from signals import own_pid
from app_git import *
from app_jobs import *
from app_agentsvc import *
from app_agent import *
from commands import CM_GIT_STAGE


@fieldwise_init
struct ConflictBlock(Copyable, Movable):
    var start_row: Int
    var anc_row: Int
    var sep_row: Int
    var end_row: Int


def find_conflict_blocks(buf: TextBuffer) -> List[ConflictBlock]:
    """Locate Git merge-conflict blocks (`<<<<<<<` .. optional `|||||||` .. `=======` .. `>>>>>>>`)."""
    var out = List[ConflictBlock]()
    var n = buf.count()
    var s_row = -1
    var a_row = -1
    var sep_row = -1
    for r in range(n):
        var ln = buf.line(r)
        if len(ln) < 7:
            continue
        if ln[0] == 60 and ln[1] == 60 and ln[2] == 60 and ln[3] == 60 and ln[4] == 60 and ln[5] == 60 and ln[6] == 60:
            s_row = r
            a_row = -1
            sep_row = -1
        elif s_row >= 0 and sep_row < 0 and ln[0] == 124 and ln[1] == 124 and ln[2] == 124 and ln[3] == 124 and ln[4] == 124 and ln[5] == 124 and ln[6] == 124:
            a_row = r
        elif s_row >= 0 and sep_row < 0 and ln[0] == 61 and ln[1] == 61 and ln[2] == 61 and ln[3] == 61 and ln[4] == 61 and ln[5] == 61 and ln[6] == 61:
            sep_row = r
        elif s_row >= 0 and sep_row > s_row and ln[0] == 62 and ln[1] == 62 and ln[2] == 62 and ln[3] == 62 and ln[4] == 62 and ln[5] == 62 and ln[6] == 62:
            out.append(ConflictBlock(s_row, a_row, sep_row, r))
            s_row = -1
            a_row = -1
            sep_row = -1
    return out^


__extension App:
    def gd_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_DIFF:
                return i
        return -1

    def git_where(self, path: String) -> Tuple[String, String]:
        """(repository root, path in it) of a file ('' , '' when git is not for it)."""
        var root = find_repo(dirname(path)) if path.byte_length() > 0 else String("")
        var rel = rel_to(root, path)
        if rel.byte_length() == 0 or not self.git_allowed(root):
            return (String(""), String(""))
        return (root, rel)

    def git_buffer_side(self, ei: Int) -> Side:
        var s = Side.of(to_str(self.wins[ei].buf.all_text()))
        if self.wins[ei].buf.eol_at_eof and len(s.lines) > 0:
            s.eol = True                # saving adds the final line feed
        return s^

    def git_editor_target(self) -> Int:
        """The editor a change command is for: the top editor, or the diff view's file."""
        var t = self.top()
        if t >= 0 and self.wins[t].kind == WK_DIFF:
            return self.find_editor(self.gd_path)
        return self.top_editor()

    def git_known(mut self, ei: Int) -> Bool:
        if ei < 0:
            self.say("No file to compare")
            return False
        if self.wins[ei].buf.git_state == GB_KNOWN:
            return True
        var p = self.wins[ei].path
        if p.byte_length() == 0:
            self.say("The file is not saved: git does not have it")
        elif self.git_where(p)[0].byte_length() == 0:
            self.say("git is not used for this file (not in a repository, or the folder is not trusted)")
        elif self.wins[ei].buf.git_state == GB_NONE:
            self.say("git does not have this file yet (it is untracked — use Stage change to add it)")
        else:
            self.say("Still asking git about this file")
        return False

    # ---------------------------------------------------------------- the view
    def git_diff_open_path(mut self, path: String, staged: Bool):
        """Open the diff view directly for `path` without requiring an open editor window."""
        var w = self.git_where(path)
        if w[0].byte_length() == 0:
            self.say("git is not used for this file (not in a repository, or the folder is not trusted)")
            return
        if path != self.gd_path:
            self.gd_head_state = GB_UNKNOWN
        self.gd_proposal = False
        self.gd_path = path
        self.gd_staged = staged
        self.gd_stamp = -1
        var di = self.gd_index()
        var ei = self.find_editor(path)
        if ei < 0:
            ei = self.top_editor()
        if di < 0:
            var x = self.wins[ei].x if ei >= 0 else 0
            var y = self.wins[ei].y if ei >= 0 else 1
            var ww = self.wins[ei].w if ei >= 0 else self.scr.w
            var hh = self.wins[ei].h if ei >= 0 else self.desk_h()
            var win = Window(WK_DIFF, "Changes", "diff:" + path, x, y, ww, hh, self.free_number())
            self.wins.append(win^)
        else:
            self.wins[di].path = "diff:" + path
            self.wins[di].cr = 0
            self.wins[di].top = 0
            self.focus(di)
        self.git_diff_refresh()
        var t = self.top()
        for r in range(len(self.gd_rows)):
            if self.gd_rows[r].kind == DR_OLD or self.gd_rows[r].kind == DR_NEW or self.gd_rows[r].kind == DR_SPLIT_CHG:
                self.wins[t].cr = r
                self.wins[t].follow = True
                break

    def git_diff_open(mut self, staged: Bool):
        var ei = self.git_editor_target()
        if not self.git_known(ei):
            return
        var p = self.wins[ei].path
        self.git_diff_open_path(p, staged)

    def git_diff_close(mut self):
        var di = self.gd_index()
        if di >= 0:
            _ = self.wins.pop(di)
        self.gd_path = ""
        self.gd_proposal = False
        var ei = self.top_editor()
        if ei >= 0:
            self.focus(ei)

    def git_disk_side(self, path: String) -> Side:
        """Read `path` from disk for editor-free diffs (empty Side when deleted on disk)."""
        if path_exists(path) and not is_dir(path):
            return Side.of(bytes_to_str(read_file(path)))
        return Side.of("")

    def git_index_side_for(self, path: String, ei: Int) -> Side:
        if ei >= 0:
            if self.wins[ei].buf.git_state == GB_KNOWN:
                return Side.of(self.wins[ei].buf.git_base_text)
            if self.wins[ei].buf.git_state == GB_NONE:
                return Side.of("")
        var w = self.git_where(path)
        if w[0].byte_length() > 0:
            var cap = run_capture(base_command(w[0], w[1]))
            if cap.status == 0:
                return Side.of(bytes_to_str(cap.out))
        return Side.of("")

    def git_work_side_for(self, path: String, ei: Int) -> Side:
        if ei >= 0:
            return self.git_buffer_side(ei)
        return self.git_disk_side(path)

    def git_diff_sides(self, ei: Int) -> Tuple[Side, Side]:
        var index = self.git_index_side_for(self.gd_path, ei)
        if self.gd_staged:
            return (Side.of(self.gd_head), index^)
        return (index^, self.git_work_side_for(self.gd_path, ei))

    def git_diff_refresh(mut self):
        """Make the view's rows again if the file, the index or HEAD changed."""
        var di = self.gd_index()
        if di < 0 or self.gd_path.byte_length() == 0:
            return
        if self.gd_proposal:
            self.agent_proposal_rows()
            return
        var ei = self.find_editor(self.gd_path)
        var stamp = self.git_stamp * 4 + (2 if self.gd_staged else 0) + (1 if self.gd_side_by_side else 0) + self.wins[di].w * 19
        if ei >= 0:
            stamp += (self.wins[ei].buf.version + 1) * 1000003
        else:
            var dsig = file_sig(self.gd_path)
            stamp += dsig.size * 31 + dsig.mtime_s * 7 + (13 if dsig.exists else 0)
        if stamp == self.gd_stamp:
            return
        self.gd_stamp = stamp
        var rows = List[DiffRow]()
        var hunks = List[Hunk]()
        var name = basename(self.gd_path)
        if ei >= 0 and (self.wins[ei].buf.git_state == GB_UNKNOWN or self.wins[ei].buf.git_state == GB_ASKED):
            rows.append(DiffRow(DR_NOTE, "(asking git for the index's version)", -1, -1))
        elif self.gd_staged and self.gd_head_state != GB_KNOWN and self.gd_head_state != GB_NONE:
            if ei < 0:
                var w = self.git_where(self.gd_path)
                if w[0].byte_length() > 0:
                    var hcap = run_capture(head_command(w[0], w[1]) + " 2>/dev/null")
                    if hcap.status == 0:
                        self.gd_head = bytes_to_str(hcap.out)
                        self.gd_head_state = GB_KNOWN
                    else:
                        self.gd_head = ""
                        self.gd_head_state = GB_NONE
                else:
                    self.gd_head = ""
                    self.gd_head_state = GB_NONE
                var sides = self.git_diff_sides(ei)
                hunks = side_hunks(sides[0], sides[1])
                rows = side_by_side(sides[0], sides[1], hunks, self.wins[di].w) if self.gd_side_by_side else unified(sides[0], sides[1], hunks)
                if len(rows) == 0:
                    rows.append(DiffRow(DR_NOTE, "(nothing staged)", -1, -1))
            else:
                if self.gd_head_state == GB_UNKNOWN:
                    var w = self.git_where(self.gd_path)
                    if w[0].byte_length() > 0:
                        self.gd_head_state = GB_ASKED
                        var gp = self.gd_path
                        self.git_queue(GQ_HEAD, head_command(w[0], w[1]), gp)
                rows.append(DiffRow(DR_NOTE, "(asking git for the last commit's version)", -1, -1))
        else:
            var sides = self.git_diff_sides(ei)
            hunks = side_hunks(sides[0], sides[1])
            rows = side_by_side(sides[0], sides[1], hunks, self.wins[di].w) if self.gd_side_by_side else unified(sides[0], sides[1], hunks)
            if len(rows) == 0:
                rows.append(DiffRow(DR_NOTE, "(nothing staged)" if self.gd_staged else "(no changes against the index)", -1, -1))
        di = self.gd_index()
        self.wins[di].title = ("Staged: " if self.gd_staged else "Changes: ") + name + (" [split]" if self.gd_side_by_side else String(""))
        var text = List[Int]()
        for k in range(len(rows)):
            if k > 0:
                text.append(10)
            for c in decode(rows[k].text):
                text.append(c)
        var keep = self.wins[di].cr
        var keep_top = self.wins[di].top
        self.wins[di].buf.load(text)
        self.wins[di].buf.modified = False
        self.wins[di].cr = max(0, min(keep, self.wins[di].buf.count() - 1))
        self.wins[di].top = max(0, min(keep_top, self.wins[di].buf.count() - 1))
        self.gd_rows = rows^
        self.gd_hunks = hunks^

    def agent_proposal_rows(mut self):
        """The diff view for the agent's first proposed write: the file now (the
        editor's text) against what the agent wants."""
        if len(self.agent_props) == 0:
            return
        var di = self.gd_index()
        var h_old = Int(content_hash(str_bytes(self.agent_props[0].old)) & 0x7FFFFFFF)
        var h_new = Int(content_hash(str_bytes(self.agent_props[0].new)) & 0x7FFFFFFF)
        var stamp = len(self.agent_props) * 14 + (1 if self.gd_side_by_side else 0) + (self.wins[di].w * 19 if di >= 0 else 0) + (h_old ^ (h_new * 3))
        if stamp == self.gd_stamp:
            return
        self.gd_stamp = stamp
        var old = Side.of(self.agent_props[0].old)
        var new = Side.of(self.agent_props[0].new)
        var hunks = side_hunks(old, new)
        var rows = side_by_side(old, new, hunks, self.wins[di].w if di >= 0 else 80) if self.gd_side_by_side else unified(old, new, hunks)
        if len(rows) == 0:
            rows.append(DiffRow(DR_NOTE, "(the same text)", -1, -1))
        var more = len(self.agent_props) - 1
        self.wins[di].title = ("Proposed: " if self.agent_props[0].exists else "Proposed new file: ") + basename(self.agent_props[0].path) + ((" (+" + String(more) + " more)") if more > 0 else String("")) + (" [split]" if self.gd_side_by_side else String(""))
        var text = List[Int]()
        for k in range(len(rows)):
            if k > 0:
                text.append(10)
            for c in decode(rows[k].text):
                text.append(c)
        var keep = self.wins[di].cr
        var keep_top = self.wins[di].top
        self.wins[di].buf.load(text)
        self.wins[di].buf.modified = False
        self.wins[di].cr = max(0, min(keep, self.wins[di].buf.count() - 1))
        self.wins[di].top = max(0, min(keep_top, self.wins[di].buf.count() - 1))
        self.gd_rows = rows^
        self.gd_hunks = hunks^

    def agent_proposal_hunk_accept(mut self, hi: Int) raises:
        if len(self.agent_props) == 0 or hi < 0 or hi >= len(self.gd_hunks):
            return
        var p_path = self.agent_props[0].path
        var p_old = self.agent_props[0].old
        var p_exists = self.agent_props[0].exists
        var old_s = Side.of(p_old)
        var new_s = Side.of(self.agent_props[0].new)
        var applied = with_hunk(old_s, new_s, self.gd_hunks[hi]).text()
        self.agent_record_before_write(p_path, p_old, p_exists)
        if not p_exists:
            _ = run_system("mkdir -p " + shell_quote(dirname(p_path)))
            _ = write_file(p_path, str_bytes(applied))
        self.open_path(p_path)
        var ei = self.find_editor(p_path)
        if ei >= 0:
            self.replace_text_min(ei, decode(applied))
            _ = self.save_window(ei, NEXT_NONE)
        if p_path not in self.agent_changed_files:
            self.agent_changed_files.append(p_path)
        self.agent_props[0].old = applied
        self.agent_props[0].exists = True
        var di = self.gd_index()
        if di >= 0:
            self.focus(di)
        if len(side_hunks(Side.of(self.agent_props[0].old), Side.of(self.agent_props[0].new))) == 0:
            var done = self.agent_props.pop(0)
            self.agent.answer(done.request, "{}")
            self.chat.note("Accepted the change to " + self.agent_rel(done.path) + " (saved; Undo in the editor takes it back)")
            if len(self.agent_props) > 0:
                self.agent_show_proposal()
            else:
                self.git_diff_close()
                var ai = self.agent_index()
                if ai >= 0:
                    self.focus(ai)
            return
        self.gd_stamp = -1
        self.git_diff_refresh()
        self.say("Accepted hunk " + String(hi + 1) + " (" + String(len(self.gd_hunks)) + " hunk(s) remaining)")

    def agent_proposal_hunk_reject(mut self, hi: Int) raises:
        if len(self.agent_props) == 0 or hi < 0 or hi >= len(self.gd_hunks):
            return
        var old_s = Side.of(self.agent_props[0].old)
        var new_s = Side.of(self.agent_props[0].new)
        var reverted = without_hunk(old_s, new_s, self.gd_hunks[hi]).text()
        self.agent_props[0].new = reverted
        if len(side_hunks(Side.of(self.agent_props[0].old), Side.of(self.agent_props[0].new))) == 0:
            var p_path = self.agent_props[0].path
            if p_path in self.agent_changed_files:
                var done = self.agent_props.pop(0)
                self.agent.answer(done.request, "{}")
                self.chat.note("Accepted selected hunks of " + self.agent_rel(done.path))
                if len(self.agent_props) > 0:
                    self.agent_show_proposal()
                else:
                    self.git_diff_close()
                    var ai = self.agent_index()
                    if ai >= 0:
                        self.focus(ai)
            else:
                self.agent_proposal_answer(False)
            return
        self.gd_stamp = -1
        self.git_diff_refresh()
        self.say("Rejected hunk " + String(hi + 1) + " (" + String(len(self.gd_hunks)) + " hunk(s) remaining)")

    def git_diff_key(mut self, k: Int) raises -> Bool:
        """Keys of the diff view (False: not one of its keys)."""
        var t = self.top()
        var row = self.wins[t].cr
        var hi = self.gd_rows[row].hunk if row >= 0 and row < len(self.gd_rows) else -1
        if k == 118 or k == 86:                 # V: toggle unified <-> side-by-side split diff
            self.gd_side_by_side = not self.gd_side_by_side
            self.gd_stamp = -1
            self.wins[t].cr = 0
            self.wins[t].top = 0
            self.git_diff_refresh()
            self.say("Diff view: " + ("side-by-side split" if self.gd_side_by_side else "unified"))
            return True
        if self.gd_proposal:
            if k == 93:                         # ] next proposal
                if len(self.agent_props) > 1:
                    var p = self.agent_props.pop(0)
                    self.agent_props.append(p^)
                    self.gd_stamp = -1
                    self.agent_show_proposal()
                    return True
            if k == 91:                         # [ previous proposal
                if len(self.agent_props) > 1:
                    var last_idx = len(self.agent_props) - 1
                    var p = self.agent_props.pop(last_idx)
                    self.agent_props.insert(0, p^)
                    self.gd_stamp = -1
                    self.agent_show_proposal()
                    return True
            if k == 104 or k == 72 or k == KEY_ENTER:  # h / Enter: accept current hunk
                if hi >= 0:
                    self.agent_proposal_hunk_accept(hi)
                return True
            if k == 120 or k == 88 or k == 117 or k == 85:  # x / u: reject current hunk
                if hi >= 0:
                    self.agent_proposal_hunk_reject(hi)
                return True
            if k == 97 or k == 65:              # A
                self.agent_proposal_answer(True)
                return True
            if k == 115 or k == 83:             # S: this and the session's later writes
                if "edit" not in self.agent_allowed:
                    self.agent_allowed.append("edit")
                self.chat.note("Allowed for this session: edit (the agent's writes go in without asking)")
                while len(self.agent_props) > 0 and self.gd_proposal:
                    self.agent_proposal_answer(True)
                return True
            if k == 114 or k == 82:             # R
                self.agent_proposal_answer(False)
                return True
            if k == KEY_ESC:
                # it stays proposed: Enter in the agent panel's empty prompt shows it again
                var di = self.gd_index()
                if di >= 0:
                    _ = self.wins.pop(di)
                self.gd_proposal = False
                self.gd_path = ""
                var ai = self.agent_index()
                if ai >= 0:
                    self.focus(ai)
                return True
            return k == KEY_TAB
        if k == KEY_ESC:
            self.git_diff_close()
            return True
        if k == KEY_TAB:
            # (also while git is still answering: the view says so until it has)
            self.gd_staged = not self.gd_staged
            self.gd_stamp = -1
            self.wins[t].cr = 0
            self.wins[t].top = 0
            self.git_diff_refresh()
            return True
        if k == KEY_ENTER:
            if row >= len(self.gd_rows):
                return True
            var gp = self.gd_path
            var ei = self.find_editor(gp)
            if ei < 0 and path_exists(gp) and not is_dir(gp):
                self.open_path(gp)
                ei = self.find_editor(gp)
            if ei < 0:
                return True
            var line = self.gd_rows[row].new_line
            if self.gd_staged:
                line = -1               # (a line of the index: the buffer's may differ)
            self.focus(ei)
            ei = self.top()
            if line >= 0:
                self.wins[ei].cr = min(line, self.wins[ei].buf.count() - 1)
                self.wins[ei].cc = 0
                self.wins[ei].follow = True
            return True
        var has_sel = self.wins[t].has_sel()
        var r1 = min(self.wins[t].cr, self.wins[t].ar) if has_sel else row
        var r2 = max(self.wins[t].cr, self.wins[t].ar) if has_sel else row
        var is_line_row = row >= 0 and row < len(self.gd_rows) and (
            self.gd_rows[row].kind == DR_OLD
            or self.gd_rows[row].kind == DR_NEW
            or self.gd_rows[row].kind == DR_SPLIT_CHG
        )
        if k == 115 or k == 83:             # s (line/selection) / S (hunk or selection)
            if self.gd_staged:
                self.say("This side is what is staged: U unstages a change")
            elif hi >= 0 and hi < len(self.gd_hunks):
                var ei = self.find_editor(self.gd_path)
                if has_sel or (k == 115 and is_line_row):
                    var sel_rows = hunk_selected_rows(self.gd_rows, self.gd_hunks[hi], hi, r1, r2)
                    if len(sel_rows) > 0:
                        self.wins[t].sel = False
                        self.git_stage_lines(ei, hi, sel_rows)
                    else:
                        self.git_stage(ei, hi)
                else:
                    self.git_stage(ei, hi)
            return True
        if k == 117 or k == 85:             # u (line/selection) / U (hunk or selection)
            if not self.gd_staged:
                self.say("Tab shows what is staged; U unstages a change there")
            elif hi >= 0 and hi < len(self.gd_hunks):
                var ei = self.find_editor(self.gd_path)
                if has_sel or (k == 117 and is_line_row):
                    var sel_rows = hunk_selected_rows(self.gd_rows, self.gd_hunks[hi], hi, r1, r2)
                    if len(sel_rows) > 0:
                        self.wins[t].sel = False
                        self.git_unstage_lines(ei, hi, sel_rows)
                    else:
                        self.git_unstage(ei, hi)
                else:
                    self.git_unstage(ei, hi)
            return True
        if k == 114 or k == 82:             # r (line/selection) / R (hunk or selection)
            if self.gd_staged:
                self.say("Revert works on the changes not staged (Tab)")
            elif hi >= 0 and hi < len(self.gd_hunks):
                var ei = self.find_editor(self.gd_path)
                if has_sel or (k == 114 and is_line_row):
                    var sel_rows = hunk_selected_rows(self.gd_rows, self.gd_hunks[hi], hi, r1, r2)
                    if len(sel_rows) > 0:
                        self.wins[t].sel = False
                        self.git_revert_lines(ei, hi, sel_rows)
                    else:
                        self.git_revert(ei, hi)
                else:
                    self.git_revert(ei, hi)
            return True
        return False

    # ------------------------------------------------------- one change at a time
    def git_hunks_now(self, ei: Int) -> List[Hunk]:
        var index = Side.of(self.wins[ei].buf.git_base_text)
        return side_hunks(index, self.git_buffer_side(ei))

    def git_change_command(mut self, cmd: Int):
        """Stage change / Revert change from the editor: the block at the cursor."""
        var ei = self.git_editor_target()
        if ei >= 0 and cmd == CM_GIT_STAGE and self.wins[ei].buf.git_state == GB_NONE:
            var p = self.wins[ei].path
            if p.byte_length() > 0 and self.git_where(p)[0].byte_length() > 0:
                self.git_write_index(p, self.git_buffer_side(ei).text(), False)
                self.say("Staged new file " + basename(p))
                return
        if not self.git_known(ei):
            return
        var t = self.top()
        if self.wins[t].kind == WK_DIFF:
            # in the view the row says which change
            var row = self.wins[t].cr
            var hv = self.gd_rows[row].hunk if row < len(self.gd_rows) else -1
            if hv < 0 or self.gd_staged:
                self.say("Put the cursor on a change of the Changes side")
                return
            if cmd == CM_GIT_STAGE:
                self.git_stage(ei, hv)
            else:
                self.git_revert(ei, hv)
            return
        var hunks = self.git_hunks_now(ei)
        var hi = hunk_at_line(hunks, self.wins[ei].cr)
        if hi < 0:
            self.say("No change at the cursor (Alt-N goes to the next one)")
            return
        if cmd == CM_GIT_STAGE:
            self.git_stage(ei, hi)
        else:
            self.git_revert(ei, hi)

    def git_write_index(mut self, path: String, text: String, remove: Bool):
        var w = self.git_where(path)
        if w[0].byte_length() == 0:
            self.say("git is not used for this file")
            return
        self.git_tmp_n += 1
        var tmp = env_or("TMPDIR", "/tmp") + "/turbomojo-index-" + String(own_pid()) + "-" + String(self.git_tmp_n)
        if not remove and not write_file(tmp, str_bytes(text)):
            self.say("Could not write " + tmp)
            return
        self.git_queue(GQ_WRITE, "sh -c " + shell_quote(stage_script(w[0], w[1], tmp, remove)), path)

    def git_stage(mut self, ei: Int, hi: Int):
        var path = self.wins[ei].path if ei >= 0 else self.gd_path
        if path.byte_length() == 0:
            return
        if ei >= 0 and self.wins[ei].buf.git_state == GB_ASKED:
            return
        var index = self.git_index_side_for(path, ei)
        var cur = self.git_work_side_for(path, ei)
        var hunks = side_hunks(index, cur)
        if hi < 0 or hi >= len(hunks):
            return
        var h = hunks[hi].copy()
        var res = with_hunk(index, cur, h)
        var remove = ei < 0 and not path_exists(path) and len(res.lines) == 0
        self.git_write_index(path, res.text(), remove)
        self.gd_stamp = -1
        self.say("Staged lines " + String(h.b + 1) + "-" + String(max(h.b + 1, h.b + h.lb)) + " of " + basename(path))

    def git_stage_lines(mut self, ei: Int, hi: Int, selected_rows: List[Int]):
        var path = self.wins[ei].path if ei >= 0 else self.gd_path
        if path.byte_length() == 0 or len(selected_rows) == 0:
            return
        if ei >= 0 and self.wins[ei].buf.git_state == GB_ASKED:
            return
        var index = self.git_index_side_for(path, ei)
        var cur = self.git_work_side_for(path, ei)
        var hunks = side_hunks(index, cur)
        if hi < 0 or hi >= len(hunks):
            return
        var h = hunks[hi].copy()
        var res = with_hunk_lines(index, cur, h, selected_rows)
        var remove = ei < 0 and not path_exists(path) and len(res.lines) == 0
        self.git_write_index(path, res.text(), remove)
        self.gd_stamp = -1
        self.say("Staged " + String(len(selected_rows)) + " line(s) of " + basename(path))

    def git_unstage(mut self, ei: Int, hi: Int):
        var path = self.wins[ei].path if ei >= 0 else self.gd_path
        if path.byte_length() == 0:
            return
        if ei >= 0 and self.wins[ei].buf.git_state == GB_ASKED:
            return
        if self.gd_head_state != GB_KNOWN and self.gd_head_state != GB_NONE:
            return
        var head = Side.of(self.gd_head)
        var index = self.git_index_side_for(path, ei)
        var hunks = side_hunks(head, index)
        if hi < 0 or hi >= len(hunks):
            return
        var res = without_hunk(head, index, hunks[hi])
        var remove = self.gd_head_state == GB_NONE and len(res.lines) == 0
        self.git_write_index(path, res.text(), remove)
        self.gd_stamp = -1
        self.say("Unstaged a change of " + basename(path))

    def git_unstage_lines(mut self, ei: Int, hi: Int, selected_rows: List[Int]):
        var path = self.wins[ei].path if ei >= 0 else self.gd_path
        if path.byte_length() == 0 or len(selected_rows) == 0:
            return
        if ei >= 0 and self.wins[ei].buf.git_state == GB_ASKED:
            return
        if self.gd_head_state != GB_KNOWN and self.gd_head_state != GB_NONE:
            return
        var head = Side.of(self.gd_head)
        var index = self.git_index_side_for(path, ei)
        var hunks = side_hunks(head, index)
        if hi < 0 or hi >= len(hunks):
            return
        var res = without_hunk_lines(head, index, hunks[hi], selected_rows)
        var remove = self.gd_head_state == GB_NONE and len(res.lines) == 0
        self.git_write_index(path, res.text(), remove)
        self.gd_stamp = -1
        self.say("Unstaged " + String(len(selected_rows)) + " line(s) of " + basename(path))

    def git_revert(mut self, ei: Int, hi: Int):
        var path = self.wins[ei].path if ei >= 0 else self.gd_path
        if path.byte_length() == 0:
            return
        if ei >= 0 and self.wins[ei].buf.git_state != GB_KNOWN:
            return
        var index = self.git_index_side_for(path, ei)
        var cur = self.git_work_side_for(path, ei)
        var hunks = side_hunks(index, cur)
        if hi < 0 or hi >= len(hunks):
            return
        var h = hunks[hi].copy()
        var res = without_hunk(index, cur, h)
        if ei >= 0:
            self.replace_text_min(ei, decode(res.text()))
            self.wins[ei].cr = min(h.b, self.wins[ei].buf.count() - 1)
            self.wins[ei].cc = 0
            self.wins[ei].sel = False
            self.wins[ei].follow = True
            self.say("Reverted lines " + String(h.b + 1) + "-" + String(max(h.b + 1, h.b + h.lb)) + " (Undo brings them back)")
        else:
            _ = run_system("mkdir -p " + shell_quote(dirname(path)))
            _ = write_file(path, str_bytes(res.text()))
            self.git_status_due = True
            self.gd_stamp = -1
            self.git_diff_refresh()
            self.say("Reverted lines " + String(h.b + 1) + "-" + String(max(h.b + 1, h.b + h.lb)) + " of " + basename(path))

    def git_revert_lines(mut self, ei: Int, hi: Int, selected_rows: List[Int]):
        var path = self.wins[ei].path if ei >= 0 else self.gd_path
        if path.byte_length() == 0 or len(selected_rows) == 0:
            return
        if ei >= 0 and self.wins[ei].buf.git_state != GB_KNOWN:
            return
        var index = self.git_index_side_for(path, ei)
        var cur = self.git_work_side_for(path, ei)
        var hunks = side_hunks(index, cur)
        if hi < 0 or hi >= len(hunks):
            return
        var h = hunks[hi].copy()
        var res = without_hunk_lines(index, cur, h, selected_rows)
        if ei >= 0:
            self.replace_text_min(ei, decode(res.text()))
            self.wins[ei].cr = min(h.b, self.wins[ei].buf.count() - 1)
            self.wins[ei].cc = 0
            self.wins[ei].sel = False
            self.wins[ei].follow = True
            self.say("Reverted " + String(len(selected_rows)) + " line(s) (Undo brings them back)")
        else:
            _ = run_system("mkdir -p " + shell_quote(dirname(path)))
            _ = write_file(path, str_bytes(res.text()))
            self.git_status_due = True
            self.gd_stamp = -1
            self.git_diff_refresh()
            self.say("Reverted " + String(len(selected_rows)) + " line(s) of " + basename(path))

    def replace_text_min(mut self, ei: Int, new: List[Int]):
        """Make window ei's text `new` by replacing only the part that differs (one undo
        step; marks, breakpoints and folds elsewhere stay where they are)."""
        var cur = self.wins[ei].buf.all_text()
        var n = len(cur)
        var m = len(new)
        var p = 0
        while p < n and p < m and cur[p] == new[p]:
            p += 1
        var s = 0
        while s < n - p and s < m - p and cur[n - 1 - s] == new[m - 1 - s]:
            s += 1
        if p == n and p == m:
            return
        var r1 = 0
        var c1 = 0
        var r2 = 0
        var c2 = 0
        var row = 0
        var col = 0
        for k in range(n - s + 1):
            if k == p:
                r1 = row
                c1 = col
            if k == n - s:
                r2 = row
                c2 = col
                break
            if cur[k] == 10:
                row += 1
                col = 0
            else:
                col += 1
        var ins = List[Int]()
        for k in range(p, m - s):
            ins.append(new[k])
        var g = self.wins[ei].group_for(ACT_OTHER)
        var cr = self.wins[ei].cr
        var cc = self.wins[ei].cc
        if r2 > r1 or c2 > c1:
            _ = self.wins[ei].buf.delete(r1, c1, r2, c2, cr, cc, g)
        if len(ins) > 0:
            _ = self.wins[ei].buf.insert(r1, c1, ins, cr, cc, g)

    def git_next_change(mut self, forward: Bool):
        var ei = self.top_editor()
        if ei < 0 or self.top() != ei:
            return
        if not self.git_known(ei):
            return
        self.git_marks_update(ei)
        var marks = self.wins[ei].buf.git_marks.copy()
        var n = len(marks)
        var r = self.wins[ei].cr
        if forward:
            while r < n and marks[r] != LM_NONE:
                r += 1
            while r < n and marks[r] == LM_NONE:
                r += 1
            if r >= n:
                self.say("No more changes below")
                return
        else:
            while r >= 0 and r < n and marks[r] != LM_NONE:
                r -= 1
            while r >= 0 and r < n and marks[r] == LM_NONE:
                r -= 1
            if r < 0 or r >= n:
                self.say("No more changes above")
                return
            while r > 0 and marks[r - 1] != LM_NONE:
                r -= 1
        self.wins[ei].cr = r
        self.wins[ei].cc = 0
        self.wins[ei].sel = False
        self.wins[ei].follow = True

    # ------------------------------------------------------- merge conflict resolution
    def conflict_next(mut self):
        """Jump to the next Git merge-conflict block (`<<<<<<< ... ======= ... >>>>>>>`)
        in the active editor, wrapping around."""
        var ei = self.top_editor()
        if ei < 0:
            self.say("No open file")
            return
        var blocks = find_conflict_blocks(self.wins[ei].buf)
        if len(blocks) == 0:
            self.say("No merge conflicts in " + (basename(self.wins[ei].path) if self.wins[ei].path.byte_length() > 0 else self.wins[ei].title))
            return
        var pick = 0
        for i in range(len(blocks)):
            if blocks[i].start_row > self.wins[ei].cr:
                pick = i
                break
        self.focus(ei)
        ei = self.top_editor()
        self.wins[ei].goto(blocks[pick].start_row, 0)
        self.say(
            "Merge conflict "
            + String(pick + 1)
            + " of "
            + String(len(blocks))
            + " — Palette: Merge Conflict: Accept Ours / Theirs / Both"
        )

    def conflict_resolve(mut self, mode: Int):
        """Resolve the merge-conflict block containing the cursor as a single Undo step:
        `mode == 0` = Ours, `mode == 1` = Theirs, `mode == 2` = Both."""
        var ei = self.top_editor()
        if ei < 0:
            self.say("No open file")
            return
        var blocks = find_conflict_blocks(self.wins[ei].buf)
        if len(blocks) == 0:
            self.say("No merge conflicts in this file")
            return
        var hit = -1
        for i in range(len(blocks)):
            if blocks[i].start_row <= self.wins[ei].cr and self.wins[ei].cr <= blocks[i].end_row:
                hit = i
                break
        if hit < 0:
            self.say("Cursor is not inside a merge conflict (File > Next merge conflict jumps to one)")
            return
        var b = blocks[hit].copy()
        var ours_end = b.anc_row if b.anc_row >= 0 else b.sep_row
        var kept = List[List[Int]]()
        if mode == 0 or mode == 2:
            for r in range(b.start_row + 1, ours_end):
                kept.append(self.wins[ei].buf.line(r))
        if mode == 1 or mode == 2:
            for r in range(b.sep_row + 1, b.end_row):
                kept.append(self.wins[ei].buf.line(r))
        var g = self.wins[ei].new_group()
        var cr = self.wins[ei].cr
        var cc = self.wins[ei].cc
        var nlines = self.wins[ei].buf.count()
        if len(kept) == 0:
            if b.end_row + 1 < nlines:
                _ = self.wins[ei].buf.delete(b.start_row, 0, b.end_row + 1, 0, cr, cc, g)
            elif b.start_row > 0:
                _ = self.wins[ei].buf.delete(
                    b.start_row - 1,
                    self.wins[ei].buf.llen(b.start_row - 1),
                    b.end_row,
                    self.wins[ei].buf.llen(b.end_row),
                    cr,
                    cc,
                    g,
                )
            else:
                _ = self.wins[ei].buf.delete(0, 0, b.end_row, self.wins[ei].buf.llen(b.end_row), cr, cc, g)
        else:
            var repl = List[Int]()
            for i in range(len(kept)):
                if i > 0:
                    repl.append(10)
                for cp in kept[i]:
                    repl.append(cp)
            _ = self.wins[ei].buf.delete(b.start_row, 0, b.end_row, self.wins[ei].buf.llen(b.end_row), cr, cc, g)
            _ = self.wins[ei].buf.insert(b.start_row, 0, repl, cr, cc, g)
        self.wins[ei].sel = False
        self.wins[ei].cr = min(b.start_row, self.wins[ei].buf.count() - 1)
        self.wins[ei].cc = 0
        self.wins[ei].sync_want()
        self.wins[ei].break_group()
        self.wins[ei].follow = True
        self.sync_shared_buffers(ei)
        var rem = len(find_conflict_blocks(self.wins[ei].buf))
        var label = "Ours" if mode == 0 else ("Theirs" if mode == 1 else "Both")
        self.say(
            "Accepted "
            + label
            + " ("
            + (String(rem) + " conflict(s) remaining" if rem > 0 else String("all merge conflicts resolved"))
            + ")"
        )
