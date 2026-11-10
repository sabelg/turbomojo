"""Moving between places: go to definition, lists of places, the back/forward jump list."""
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
from app_lsp import *
from lsp import *
from markdown import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_jobs import *
from app_pickers import *
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
from app_input import *
from app_mouse import *
from app_draw import *


comptime JUMPS_MAX = 100


struct PlanEdit(Copyable, Movable):
    """A text edit checked against the file: character columns, and its new text."""
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int
    var text: List[Int]

    def __init__(out self, r1: Int, c1: Int, r2: Int, c2: Int, text: List[Int]):
        self.r1 = r1
        self.c1 = c1
        self.r2 = r2
        self.c2 = c2
        self.text = text.copy()


def plan_edits(lines: List[List[Int]], edits: List[LspEdit]) raises -> List[PlanEdit]:
    """Check a file's edits against its lines and return them with character columns,
    last one first (so that applying one does not move those still to do). Raises if an
    edit lies outside the text or two of them overlap."""
    var plan = List[PlanEdit]()
    var n = len(lines)
    for e in edits:
        var r1 = e.r1
        var r2 = e.r2
        if r1 > n or r2 > n or (r1 == n and e.c1 > 0) or (r2 == n and e.c2 > 0):
            raise Error("an edit lies beyond the end of the text")
        var c1 = 0
        var c2 = 0
        if r1 == n:
            # "line after the last one, column 0" is the very end of the text
            r1 = n - 1
            c1 = len(lines[r1])
        else:
            c1 = utf16_to_col(lines[r1], e.c1)
        if r2 == n:
            r2 = n - 1
            c2 = len(lines[r2])
        else:
            c2 = utf16_to_col(lines[r2], e.c2)
        var text = List[Int]()
        for c in decode(e.text):
            if c != 13:
                text.append(c)
        plan.append(PlanEdit(r1, c1, r2, c2, text))
    for a in range(1, len(plan)):
        var b = a
        while b > 0 and (plan[b].r1 > plan[b - 1].r1 or (plan[b].r1 == plan[b - 1].r1 and plan[b].c1 > plan[b - 1].c1)):
            var tmp = plan[b].copy()
            plan[b] = plan[b - 1].copy()
            plan[b - 1] = tmp^
            b -= 1
    for k in range(1, len(plan)):
        # plan[k] starts before plan[k - 1]; it must also end before that one starts
        if plan[k].r2 > plan[k - 1].r1 or (plan[k].r2 == plan[k - 1].r1 and plan[k].c2 > plan[k - 1].c1):
            raise Error("two edits overlap")
    return plan^


def is_word_cp(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128


def count_of(n: Int, what: String) -> String:
    return String(n) + " " + what + ("" if n == 1 else "s")


def place_before(a: LspLocation, b: LspLocation, first_path: String) -> Bool:
    """Order of places in a list: `first_path` before other files, files by name, then
    by position."""
    if a.path != b.path:
        if a.path == first_path:
            return True
        if b.path == first_path:
            return False
        return a.path < b.path
    if a.row != b.row:
        return a.row < b.row
    return a.col16 < b.col16


__extension App:
    # ============================================================== jump list
    def here(self) -> JumpLoc:
        """Where the cursor is, if that is a file with a name (row < 0 otherwise)."""
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].path.byte_length() == 0:
            return JumpLoc("", -1, 0)
        return JumpLoc(self.wins[ai].path, self.wins[ai].cr, self.wins[ai].cc)

    def jump_mark(mut self):
        """Call before the cursor is taken somewhere else by a command: remembers the
        place it leaves, so that Back returns to it. Places ahead (after going back)
        are forgotten, as in a browser."""
        var h = self.here()
        if h.row < 0:
            return
        while len(self.jumps) > self.jump_at:
            _ = self.jumps.pop()
        var n = len(self.jumps)
        if n > 0 and self.jumps[n - 1].path == h.path and self.jumps[n - 1].row == h.row:
            self.jumps[n - 1].col = h.col        # same line: one entry is enough
        else:
            self.jumps.append(h^)
            if len(self.jumps) > JUMPS_MAX:
                var rest = List[JumpLoc]()
                for k in range(1, len(self.jumps)):
                    rest.append(self.jumps[k].copy())
                self.jumps = rest^
        self.jump_at = len(self.jumps)

    def jump_show(mut self, j: JumpLoc) raises -> Bool:
        if not (self.find_editor(j.path) >= 0 or path_exists(j.path)):
            return False
        self.open_path(j.path)
        var t = self.top()
        if self.wins[t].kind != WK_EDITOR or self.wins[t].path != j.path:
            return False
        self.wins[t].goto(j.row, j.col)
        return True

    def jump_back(mut self) raises:
        if self.jump_at <= 0 or len(self.jumps) == 0:
            self.say("No earlier place to go back to")
            return
        if self.jump_at >= len(self.jumps):
            # leaving the newest place: remember it so that Forward can return
            var h = self.here()
            if h.row >= 0:
                self.jumps.append(h^)
        self.jump_at -= 1
        while not self.jump_show(self.jumps[self.jump_at].copy()):
            # a file that is gone: skip it
            if self.jump_at == 0:
                self.say("No earlier place to go back to")
                return
            self.jump_at -= 1
        self.say("Back (" + String(self.jump_at + 1) + " of " + String(len(self.jumps)) + ")")

    def jump_forward(mut self) raises:
        if self.jump_at + 1 >= len(self.jumps):
            self.say("No later place to go forward to")
            return
        self.jump_at += 1
        while not self.jump_show(self.jumps[self.jump_at].copy()):
            if self.jump_at + 1 >= len(self.jumps):
                self.say("No later place to go forward to")
                return
            self.jump_at += 1
        self.say("Forward (" + String(self.jump_at + 1) + " of " + String(len(self.jumps)) + ")")
        if self.jump_at == len(self.jumps) - 1:
            # back at the newest place: it is "here" again, not history
            _ = self.jumps.pop()
            self.jump_at = len(self.jumps)

    # ======================================================= lists of places
    def place_line(self, path: String, row: Int) -> List[Int]:
        """The text of a line of a file: from its window if it is open, else from disk."""
        var wi = self.find_editor(path)
        if wi >= 0:
            if row < self.wins[wi].buf.count():
                return self.wins[wi].buf.line(row)
            return List[Int]()
        if not path_exists(path):
            return List[Int]()
        var cps = decode_list(read_file(path))
        var r = 0
        var cur = List[Int]()
        for c in cps:
            if c == 10:
                if r == row:
                    return cur^
                r += 1
                cur = List[Int]()
            elif c != 13:
                cur.append(c)
        if r == row:
            return cur^
        return List[Int]()

    def file_lines(self, path: String) -> List[List[Int]]:
        """Every line of a file on disk (empty if it cannot be read)."""
        var lines = List[List[Int]]()
        if not path_exists(path):
            return lines^
        var cur = List[Int]()
        for c in decode_list(read_file(path)):
            if c == 10:
                lines.append(cur^)
                cur = List[Int]()
            elif c != 13:
                cur.append(c)
        lines.append(cur^)
        return lines^

    def show_places(mut self, title: String, locs: List[LspLocation]):
        """List places in the Message window, one per line as path:line:column: text;
        Enter there, Next message and Previous message go to them."""
        self.panel_write(PG_SEARCH)
        var mi = self.ensure_msg()
        var text = decode(title)
        text.append(10)
        self.errs.clear()
        self.errs_from_search = False
        self.err_idx = -1
        var prefix = self.cwd + "/"
        var row = 1
        var files = 0
        var last_path = String("")
        var disk_path = String("")          # the file read last, so each is read once
        var disk = List[List[Int]]()
        for l in locs:
            if l.path != last_path:
                files += 1
                last_path = l.path
            var line = List[Int]()
            if self.find_editor(l.path) >= 0:
                line = self.place_line(l.path, l.row)
            else:
                if l.path != disk_path:
                    disk = self.file_lines(l.path)
                    disk_path = l.path
                if l.row < len(disk):
                    line = disk[l.row].copy()
            var col = utf16_to_col(line, l.col16)
            var shown = l.path
            if shown.startswith(prefix):
                shown = slice_str(decode(shown), cp_len(prefix), cp_len(shown))
            var first = 0
            while first < len(line) and (line[first] == 32 or line[first] == 9):
                first += 1
            for c in decode(shown + ":" + String(l.row + 1) + ":" + String(col + 1) + ": "):
                text.append(c)
            for q in range(first, len(line)):
                text.append(line[q])
            text.append(10)
            self.errs.append(ErrLoc(l.path, l.row + 1, col + 1, row))
            row += 1
        for c in decode(count_of(len(locs), "place") + " in " + count_of(files, "file")):
            text.append(c)
        self.wins[mi].buf.load(text)
        self.wins[mi].cr = 0
        self.wins[mi].top = 0

    # ======================================================= find references
    def word_under(self, ai: Int) -> String:
        """The identifier the cursor is on or right after ('' if none)."""
        var line = self.wins[ai].buf.line(self.wins[ai].cr)
        var a = min(self.wins[ai].cc, len(line))
        var b = a
        while a > 0 and is_word_cp(line[a - 1]):
            a -= 1
        while b < len(line) and is_word_cp(line[b]):
            b += 1
        var cps = List[Int]()
        for q in range(a, b):
            cps.append(line[q])
        return to_str(cps)

    def references_command(mut self):
        """Search > Find references: ask the language server for every use of the
        symbol at the cursor; they are listed in the Message window."""
        var ai = self.active_editor()
        if ai < 0:
            return
        self.ref_retries = 0
        if not self.references_request(ai):
            if self.lsp.state == LSP_READY and not self.lsp.table.references:
                self.say("This language server does not find references")
            else:
                self.say("Start the language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        self.say("Asking the language server...")

    def references_request(mut self, ai: Int) -> Bool:
        var path = self.wins[ai].path
        if path.byte_length() == 0 or self.lsp.state != LSP_READY or not self.lsp.table.references:
            return False
        var uri = path_to_uri(path)
        if self.lsp.find_doc(uri) < 0:
            return False
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)
        var id = self.lsp.request_references(uri, self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc), now)
        if id < 0:
            return False
        self.ref_req_id = id
        self.ref_req_path = path
        self.ref_req_row = self.wins[ai].cr
        self.ref_req_col = self.wins[ai].cc
        self.ref_retry_due = 0
        return True

    def references_still_wanted(self) -> Bool:
        var ai = self.active_editor()
        return ai >= 0 and self.mode == M_NORMAL and self.wins[ai].path == self.ref_req_path and self.wins[ai].cr == self.ref_req_row and self.wins[ai].cc == self.ref_req_col

    def references_arrived(mut self, m: RpcMessage):
        self.ref_req_id = -1
        if not self.references_still_wanted():
            return
        if m.kind == RPC_ERROR:
            if retry_later(m) and self.ref_retries < COMP_MAX_RETRIES:
                self.ref_retries += 1
                self.ref_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                return
            self.say("Language server: " + m.error_message())
            return
        var locs = parse_locations(m.doc, m.result())
        if len(locs) == 0:
            self.say("No references found for this place")
            return
        # by file (the file being edited first), then by position
        var here = self.ref_req_path
        var n = len(locs)
        for a in range(1, n):
            var b = a
            while b > 0 and place_before(locs[b], locs[b - 1], here):
                var tmp = locs[b].copy()
                locs[b] = locs[b - 1].copy()
                locs[b - 1] = tmp^
                b -= 1
        var ai = self.active_editor()
        var word = self.word_under(ai)
        self.show_places("References to " + word if word.byte_length() > 0 else String("References"), locs)
        # Next message continues from the use the cursor is on
        var cc16 = self.wins[ai].buf.utf16_col(self.ref_req_row, self.ref_req_col)
        for k in range(n):
            if locs[k].path == here and locs[k].row == self.ref_req_row and locs[k].col16 <= cc16:
                self.err_idx = k
        var mi = self.msg_index()
        if mi >= 0 and self.err_idx >= 0:
            self.wins[mi].cr = self.err_idx + 1
            self.wins[mi].follow = True
        var summary = to_str(self.wins[mi].buf.line(n + 1)) if mi >= 0 else String("")
        self.say(summary + " - " + self.reg.key_label(CM_NEXTERR) + " / " + self.reg.key_label(CM_PREVERR) + " step through them")

    # ================================================================ rename
    def rename_command(mut self):
        """Rename symbol: ask the language server whether the symbol at the cursor can
        be renamed, ask the user for the new name, then for the edits (rename_reply)."""
        var ai = self.active_editor()
        if ai < 0:
            return
        var path = self.wins[ai].path
        if self.lsp.state != LSP_READY or path.byte_length() == 0 or self.lsp.find_doc(path_to_uri(path)) < 0:
            self.say("Start the language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        if not self.lsp.table.rename:
            self.say("This language server does not rename symbols")
            return
        self.wins[ai].collapse()
        self.ren_path = path
        self.ren_row = self.wins[ai].cr
        self.ren_col = self.wins[ai].cc
        self.ren_retries = 0
        self.ren_stage = 0
        if self.lsp.table.prepare_rename:
            self.ren_stage = 1
            self.rename_resend()
            if self.ren_stage == 1:
                self.say("Asking the language server...")
            return
        self.rename_ask(self.word_under(ai))

    def rename_resend(mut self):
        """Send (again) the question of the current stage."""
        var ai = self.active_editor()
        if ai < 0 or self.ren_stage == 0 or self.wins[ai].path != self.ren_path or self.wins[ai].cr != self.ren_row or self.wins[ai].cc != self.ren_col:
            self.ren_stage = 0
            self.ren_req_id = -1
            return
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)
        var uri = path_to_uri(self.ren_path)
        var c16 = self.wins[ai].buf.utf16_col(self.ren_row, self.ren_col)
        if self.ren_stage == 1:
            self.ren_req_id = self.lsp.request_prepare_rename(uri, self.ren_row, c16, now)
        else:
            self.snapshot_versions()
            self.ren_req_id = self.lsp.request_rename(uri, self.ren_row, c16, self.ren_new, now)
        if self.ren_req_id < 0:
            self.ren_stage = 0
            self.say("The language server cannot be asked now")

    def rename_ask(mut self, name: String):
        self.ren_stage = 0
        if name.byte_length() == 0:
            self.say("There is no name at the cursor to rename")
            return
        self.ren_old = name
        var d = Dialog(D_RENAME, "Rename Symbol", max(44, min(self.scr.w - 4, cp_len(name) + 24)), 8)
        d.lines.append("Rename " + name + " everywhere it is used")
        d.fields.append(Field("~N~ew name", name))
        d.fields[0].fresh = True
        d.buttons.append("~O~K")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def rename_accept(mut self, typed: String):
        """The new name was entered."""
        var name = String(typed.strip())
        if name.byte_length() == 0 or name == self.ren_old:
            self.say("The name was not changed")
            return
        self.ren_new = name
        self.ren_stage = 2
        self.ren_retries = 0
        self.rename_resend()
        if self.ren_stage == 2:
            self.say("Asking the language server...")

    def rename_reply(mut self, m: RpcMessage):
        self.ren_req_id = -1
        var stage = self.ren_stage
        var ai = self.active_editor()
        if stage == 0 or ai < 0 or self.mode != M_NORMAL or self.wins[ai].path != self.ren_path or self.wins[ai].cr != self.ren_row or self.wins[ai].cc != self.ren_col:
            self.ren_stage = 0
            return
        if m.kind == RPC_ERROR:
            if retry_later(m) and self.ren_retries < COMP_MAX_RETRIES:
                self.ren_retries += 1
                self.ren_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                return
            self.ren_stage = 0
            self.say("Language server: " + m.error_message())
            return
        if stage == 1:
            var rs = parse_prepare_rename(m.doc, m.result())
            if not rs.ok:
                self.ren_stage = 0
                self.say("This cannot be renamed")
                return
            var name = rs.placeholder
            if name.byte_length() == 0 and rs.known and rs.row < self.wins[ai].buf.count():
                var line = self.wins[ai].buf.line(rs.row)
                var cps = List[Int]()
                for q in range(utf16_to_col(line, rs.c1), utf16_to_col(line, rs.c2)):
                    cps.append(line[q])
                name = to_str(cps)
            if name.byte_length() == 0:
                name = self.word_under(ai)
            self.rename_ask(name)
            return
        # ---- the edits
        self.ren_stage = 0
        var we = parse_workspace_edit(m.doc, m.result())
        if we.count() == 0 and we.problem.byte_length() == 0:
            self.say("The server found nothing to rename")
            return
        self.offer_edit(we^, "Rename", "Rename Symbol", "Rename " + self.ren_old + " to " + self.ren_new, "Renamed " + self.ren_old + " to " + self.ren_new)

    def snapshot_versions(mut self):
        """Remember the state of every open file, to notice edits made while the server
        works on an answer."""
        self.ren_vpaths.clear()
        self.ren_versions.clear()
        for k in range(len(self.wins)):
            if self.wins[k].kind == WK_EDITOR and self.wins[k].path.byte_length() > 0:
                self.ren_vpaths.append(self.wins[k].path)
                self.ren_versions.append(self.wins[k].buf.version)

    def versions_changed(self) -> Bool:
        for k in range(len(self.ren_vpaths)):
            var wi = self.find_editor(self.ren_vpaths[k])
            if wi < 0 or self.wins[wi].buf.version != self.ren_versions[k]:
                return True
        return False

    def offer_edit(mut self, var we: WorkspaceEdit, noun: String, title: String, what: String, done: String):
        """Changes a server asks for (a rename, a quick fix): check them, list the
        places in the Message window, and apply them - at once if only the file being
        edited changes, after a question otherwise. `noun` names the operation in
        messages, `title` the dialog, `what` the list, `done` the final message."""
        self.edit_noun = noun
        self.edit_done = done
        if we.problem.byte_length() > 0:
            self.info(noun, "The server's answer cannot be applied: " + we.problem)
            return
        if we.count() == 0:
            self.say(noun + ": the server sent no changes")
            return
        if self.versions_changed():
            self.say("The text changed while the server was working - try again")
            return
        try:
            for f in we.files:
                _ = plan_edits(self.lines_of(f.path), f.edits)
        except e:
            self.info(noun, "The server's answer cannot be applied: " + String(e))
            return
        var ai = self.active_editor()
        var here = self.wins[ai].path if ai >= 0 else String("")
        # ---- preview: every place in the Message window
        var locs = List[LspLocation]()
        for f in we.files:
            for ed in f.edits:
                locs.append(LspLocation(f.path, ed.r1, ed.c1))
        for a in range(1, len(locs)):
            var b = a
            while b > 0 and place_before(locs[b], locs[b - 1], here):
                var tmp = locs[b].copy()
                locs[b] = locs[b - 1].copy()
                locs[b - 1] = tmp^
                b -= 1
        var others = 0
        var unopened = 0
        for f in we.files:
            if f.path != here:
                others += 1
            if self.find_editor(f.path) < 0:
                unopened += 1
        if others > 0 or len(locs) > 1:
            self.show_places(what, locs)
        self.ren_edit = we^
        if others == 0:
            self.edit_apply()               # this file only: one undo step takes it back
            return
        var d = Dialog(D_RENAME_APPLY, title, min(self.scr.w - 4, 64), 9)
        d.lines.append(what + ":")
        d.lines.append(count_of(self.ren_edit.count(), "change") + " in " + count_of(len(self.ren_edit.files), "file") + " (listed in the Message window)")
        if unopened > 0:
            d.lines.append(count_of(unopened, "file") + " will be opened; nothing is saved until you save")
        d.buttons.append("~A~pply")
        d.buttons.append("~C~ancel")
        d.focus = d.button_focus_index(0)
        self.show(d^)

    def lines_of(self, path: String) raises -> List[List[Int]]:
        """The lines of a file as they are now: from its window, else from disk."""
        var wi = self.find_editor(path)
        if wi >= 0:
            var lines = List[List[Int]]()
            for r in range(self.wins[wi].buf.count()):
                lines.append(self.wins[wi].buf.line(r))
            return lines^
        if not path_exists(path):
            raise Error(basename(path) + " does not exist")
        return self.file_lines(path)

    def edit_apply(mut self):
        var n = self.ren_edit.count()
        var files = len(self.ren_edit.files)
        var problem = self.apply_workspace_edit()
        self.ren_edit = WorkspaceEdit()
        if problem.byte_length() > 0:
            var noun = self.edit_noun
            self.info(noun, "Nothing was changed: " + problem)
            return
        self.say(self.edit_done + ": " + count_of(n, "change") + " in " + count_of(files, "file") + (" - not saved yet" if files > 1 else ""))
        self.action_after_edit()

    def apply_workspace_edit(mut self) -> String:
        """Apply self.ren_edit: every file is checked first, then each is changed in one
        undo step (files that are not open are opened, and left unsaved). Returns ''
        or why nothing was changed."""
        var plans = List[List[PlanEdit]]()
        try:
            for f in self.ren_edit.files:
                plans.append(plan_edits(self.lines_of(f.path), f.edits))
        except e:
            return String(e)
        var back = self.active_editor()
        var back_path = self.wins[back].path if back >= 0 else String("")
        for k in range(len(plans)):
            var path = self.ren_edit.files[k].path
            if self.find_editor(path) < 0:
                try:
                    self.open_path(path)
                except e:
                    return "cannot open " + basename(path) + " (the files before it were changed; use Undo there)"
            var wi = self.find_editor(path)
            if wi < 0:
                return "cannot open " + basename(path) + " (the files before it were changed; use Undo there)"
            self.wins[wi].collapse()
            self.wins[wi].sel = False
            var cr = self.wins[wi].cr
            var cc = self.wins[wi].cc
            var g = self.wins[wi].new_group()
            # where the cursor ends up: edits before it on its line move it
            var shift = 0
            for p in plans[k]:
                if p.r1 == cr and p.r2 == cr and not (10 in p.text):
                    if p.c2 <= cc:
                        shift += len(p.text) - (p.c2 - p.c1)
                    elif p.c1 < cc:
                        shift += min(cc - p.c1, len(p.text)) - (cc - p.c1)
            for p in plans[k]:
                if p.r1 != p.r2 or p.c1 != p.c2:
                    _ = self.wins[wi].buf.delete(p.r1, p.c1, p.r2, p.c2, cr, cc, g)
                if len(p.text) > 0:
                    _ = self.wins[wi].buf.insert(p.r1, p.c1, p.text, cr, cc, g)
            self.wins[wi].cc = max(0, cc + shift)
            self.wins[wi].clamp()
            self.wins[wi].sync_want()
            self.wins[wi].break_group()
        if back_path.byte_length() > 0:
            var bi = self.find_editor(back_path)
            if bi >= 0:
                self.focus(bi)
        return ""

    # ========================================================== code actions
    def actions_command(mut self):
        """Quick fix: ask the language server what it can do about the problems on the
        cursor's line (or the selection); the offers open in a list (actions_arrived)."""
        var ai = self.active_editor()
        if ai < 0:
            return
        var path = self.wins[ai].path
        if self.lsp.state != LSP_READY or path.byte_length() == 0 or self.lsp.find_doc(path_to_uri(path)) < 0:
            self.say("Start the language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        if not self.lsp.table.code_action:
            self.say("This language server offers no quick fixes")
            return
        self.act_retries = 0
        self.act_stage = 1
        self.act_path = path
        self.act_row = self.wins[ai].cr
        self.act_col = self.wins[ai].cc
        self.actions_resend()
        if self.act_req_id >= 0:
            self.say("Asking the language server...")

    def actions_resend(mut self):
        var ai = self.active_editor()
        if ai < 0 or self.act_stage == 0 or self.wins[ai].path != self.act_path or self.wins[ai].cr != self.act_row or self.wins[ai].cc != self.act_col:
            self.act_stage = 0
            self.act_req_id = -1
            return
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)
        self.snapshot_versions()
        if self.act_stage == 2:
            self.act_req_id = self.lsp.request_action_resolve(self.act_chosen.raw, now)
        else:
            var r1 = self.wins[ai].cr
            var c1 = self.wins[ai].cc
            var r2 = r1
            var c2 = c1
            if self.wins[ai].sel:
                var ar = self.wins[ai].ar
                var ac = self.wins[ai].ac
                if ar < r1 or (ar == r1 and ac < c1):
                    r1 = ar
                    c1 = ac
                else:
                    r2 = ar
                    c2 = ac
            self.act_req_id = self.lsp.request_code_actions(path_to_uri(self.act_path), r1, self.wins[ai].buf.utf16_col(r1, c1), r2, self.wins[ai].buf.utf16_col(r2, c2), now)
        if self.act_req_id < 0:
            self.act_stage = 0
            self.say("The language server cannot be asked now")

    def actions_reply(mut self, m: RpcMessage):
        self.act_req_id = -1
        var stage = self.act_stage
        var ai = self.active_editor()
        if stage == 0 or ai < 0 or self.mode != M_NORMAL or self.wins[ai].path != self.act_path or self.wins[ai].cr != self.act_row or self.wins[ai].cc != self.act_col:
            self.act_stage = 0
            return
        if m.kind == RPC_ERROR:
            if retry_later(m) and self.act_retries < COMP_MAX_RETRIES:
                self.act_retries += 1
                self.act_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                return
            self.act_stage = 0
            self.say("Language server: " + m.error_message())
            return
        self.act_stage = 0
        if stage == 2:
            # the chosen action, now with its edit
            var full = parse_code_action(m.doc, m.result())
            if full.edit_json.byte_length() == 0 and full.command.byte_length() == 0:
                self.say("Quick fix: the server sent no changes")
                return
            self.act_chosen = full^
            self.action_run()
            return
        self.actions = parse_code_actions(m.doc, m.result())
        if len(self.actions) == 0:
            self.say("No quick fixes or actions here")
            return
        var items = List[String]()
        var data = List[Int]()
        var widest = 20
        for k in range(len(self.actions)):
            var t = self.actions[k].title
            if self.actions[k].disabled.byte_length() > 0:
                t += "  (" + self.actions[k].disabled + ")"
            widest = max(widest, cp_len(t))
            items.append(t)
            data.append(k)
        var d = Dialog(D_ACTIONS, "Quick Fix", max(40, min(self.scr.w - 4, widest + 8)), max(8, min(len(items) + 6, min(20, self.desk_h()))))
        d.set_items(items^, data^)
        d.buttons.append("~A~pply")
        d.buttons.append("~C~ancel")
        self.say(count_of(len(self.actions), "action") + " offered")
        self.show(d^)

    def action_chosen(mut self, k: Int):
        if k < 0 or k >= len(self.actions):
            return
        self.act_chosen = self.actions[k].copy()
        if self.act_chosen.disabled.byte_length() > 0:
            self.say("Not available: " + self.act_chosen.disabled)
            return
        if self.act_chosen.edit_json.byte_length() == 0 and self.act_chosen.command.byte_length() == 0:
            if not self.lsp.table.code_action_resolve:
                self.say("Quick fix: the server sent no changes")
                return
            self.act_stage = 2
            self.act_retries = 0
            self.actions_resend()
            return
        self.action_run()

    def action_run(mut self):
        """Carry out self.act_chosen: its edit first, then its command."""
        if self.act_chosen.edit_json.byte_length() > 0:
            self.act_command_due = self.act_chosen.command.byte_length() > 0
            try:
                var doc = json_parse(self.act_chosen.edit_json)
                var title = self.act_chosen.title
                self.offer_edit(parse_workspace_edit(doc, 0), "Quick fix", "Quick Fix", title, "Applied: " + title)
            except e:
                self.say("Quick fix: the server's answer cannot be read")
            return
        self.act_command_due = True
        self.say("Running: " + self.act_chosen.title)
        self.action_after_edit()

    def action_after_edit(mut self):
        """Called when an edit has been applied (and by action_run when there is none):
        run the command of the chosen action, if it has one waiting."""
        if not self.act_command_due:
            return
        self.act_command_due = False
        self.snapshot_versions()
        if self.lsp.request_execute(self.act_chosen.command, self.act_chosen.args_json, now_ns()) < 0:
            self.say("The language server cannot be asked now")

    def server_edits(mut self):
        """Edits the server asked us to make (workspace/applyEdit), usually the result
        of a command of an action."""
        var pending = self.lsp.take_asked_edits()
        var labels = self.lsp.asked_labels.copy()
        self.lsp.asked_labels.clear()
        for k in range(len(pending)):
            if self.mode != M_NORMAL:
                self.say("An edit from the language server was dropped (a dialog was open)")
                continue
            var label = labels[k] if k < len(labels) and labels[k].byte_length() > 0 else (self.act_chosen.title if self.act_chosen.title.byte_length() > 0 else String("Edit from the language server"))
            try:
                var doc = json_parse(pending[k])
                self.offer_edit(parse_workspace_edit(doc, 0), "Quick fix", "Quick Fix", label, "Applied: " + label)
            except e:
                self.say("Quick fix: the server's edit cannot be read")

    # ====================================================== go to definition
    def definition_command(mut self):
        """Search > Go to definition: ask the language server where the symbol at the
        cursor is defined and go there (definition_arrived)."""
        var ai = self.active_editor()
        if ai < 0:
            return
        self.def_retries = 0
        if not self.definition_request(ai):
            if self.lsp.state == LSP_READY and not self.lsp.table.definition:
                self.say("This language server does not find definitions")
            else:
                self.say("Start the language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        self.say("Asking the language server...")

    def definition_request(mut self, ai: Int) -> Bool:
        var path = self.wins[ai].path
        if path.byte_length() == 0 or self.lsp.state != LSP_READY or not self.lsp.table.definition:
            return False
        var uri = path_to_uri(path)
        if self.lsp.find_doc(uri) < 0:
            return False
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)
        var id = self.lsp.request_definition(uri, self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc), now)
        if id < 0:
            return False
        self.def_req_id = id
        self.def_req_path = path
        self.def_req_row = self.wins[ai].cr
        self.def_req_col = self.wins[ai].cc
        self.def_retry_due = 0
        return True

    def definition_still_wanted(self) -> Bool:
        var ai = self.active_editor()
        return ai >= 0 and self.mode == M_NORMAL and self.wins[ai].path == self.def_req_path and self.wins[ai].cr == self.def_req_row and self.wins[ai].cc == self.def_req_col

    def definition_arrived(mut self, m: RpcMessage) raises:
        self.def_req_id = -1
        if not self.definition_still_wanted():
            return
        if m.kind == RPC_ERROR:
            if retry_later(m) and self.def_retries < COMP_MAX_RETRIES:
                self.def_retries += 1
                self.def_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                return
            self.say("Language server: " + m.error_message())
            return
        var all_locs = parse_locations(m.doc, m.result())
        var locs = List[LspLocation]()
        for l in all_locs:
            if self.find_editor(l.path) >= 0 or path_exists(l.path):
                locs.append(l.copy())
        if len(locs) == 0:
            self.say("No definition found for this place" if len(all_locs) == 0 else "The definition is in a file that cannot be opened")
            return
        var from_path = self.def_req_path
        var from_row = self.def_req_row
        self.jump_mark()
        if len(locs) > 1:
            self.show_places("Definitions", locs)
            self.err_idx = 0
        self.open_path(locs[0].path)
        var t = self.top()
        if self.wins[t].kind != WK_EDITOR or self.wins[t].path != locs[0].path:
            return
        var col = utf16_to_col(self.place_line(locs[0].path, locs[0].row), locs[0].col16)
        var same = locs[0].path == from_path and locs[0].row == from_row
        self.wins[t].goto(locs[0].row, col)
        if len(locs) > 1:
            self.say("Definition 1 of " + String(len(locs)) + " - " + self.reg.key_label(CM_NEXTERR) + " shows the next")
        elif same:
            self.say("This is the definition")
        else:
            self.say(basename(locs[0].path) + ":" + String(locs[0].row + 1))
