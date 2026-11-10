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
from app_input import *
from app_mouse import *
from app_draw import *


comptime JUMPS_MAX = 100


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
