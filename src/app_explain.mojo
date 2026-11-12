"""F1 on an error: the explanation of a Mojo error message (src/errhelp.mojo) in a
window beside the code, so the code with the error stays in view.

F1 on a row of the Problems page, or in an editor on a line with a problem, opens it.
The editor makes room: it keeps the left half (or the top half, when it is narrow)
and the explanation takes the rest; Esc closes the explanation and gives the editor
its place back. In the tiled layout the explanation takes the half of the editor's
pane each time the panes are placed.
"""
from std.collections import List
from appstate import *
from util import *
from window import Window, WK_EDITOR, WK_MESSAGE, WK_EXPLAIN
from term import KEY_ESC
from markdown import md_render
from errhelp import *
from errhelp_pages import ERR_PAGE_COUNT, err_page_key
from app_docs import *
from problems import Problem
from app_jobs import *
from app_problems import *


comptime EXPLAIN_SIDE_W = 90        # an editor at least this wide gives up its right half


__extension App:
    def explain_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EXPLAIN:
                return i
        return -1

    def explain_problems_row(self) -> String:
        """The text of the problem the Problems page's cursor is on ("" if it is on no
        problem): its row and the note rows under it."""
        var t = self.top()
        if t < 0 or self.wins[t].kind != WK_MESSAGE or self.msg_page != PG_PROBLEMS:
            return ""
        var cr = self.wins[t].cr
        var first = -1
        var next = self.wins[t].buf.count()
        for e in self.errs:
            if e.msg_line <= cr:
                first = max(first, e.msg_line)
            elif e.msg_line < next:
                next = e.msg_line
        if first < 0:
            return ""
        var out = String("")
        for r in range(first, min(next, first + 8)):
            out += to_str(self.wins[t].buf.line(r)) + "\n"
        return out^

    def explain_cursor_problems(self) -> List[String]:
        """The messages of the problems on the line of the editor's cursor."""
        var out = List[String]()
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].path.byte_length() == 0:
            return out^
        var row = self.wins[ai].cr + 1
        for p in self.problems_collect():
            if p.path == self.wins[ai].path and p.line == row:
                out.append(p.message)
        return out^

    def explain_command(mut self) -> Bool:
        """F1: explain the problem at hand. True if F1 is answered (an explanation
        opened, or said that there is none for a Problems row); False lets F1 do its
        usual (the documentation of the name, or the keyboard reference)."""
        if self.mode != M_NORMAL:
            return False
        var row = self.explain_problems_row()
        if row.byte_length() > 0:
            var page = explain_for(row)
            if page < 0:
                self.say("No explanation for this message yet (Help > Error messages lists the ones there are)")
                return True
            var e = self.errs_at_cursor_path()
            self.explain_open(page, e)
            return True
        for m in self.explain_cursor_problems():
            var page = explain_for(m)
            if page >= 0:
                var path = self.wins[self.active_editor()].path
                self.explain_open(page, path)
                return True
        return False

    def errs_at_cursor_path(self) -> String:
        """The file of the problem the Problems page's cursor is on."""
        var t = self.top()
        var cr = self.wins[t].cr
        var best = -1
        var path = String("")
        for e in self.errs:
            if e.msg_line <= cr and e.msg_line > best:
                best = e.msg_line
                path = e.path
        return path^

    def explain_open(mut self, page: Int, path: String):
        """Show explanation `page` beside the editor of `path` (or the editor in front)."""
        var ei = self.find_editor(path) if path.byte_length() > 0 else -1
        if ei < 0:
            ei = self.top_editor()
        var xi = self.explain_index()
        if xi < 0:
            var win = Window(WK_EXPLAIN, "Explanation", "explain:", 0, 1, self.scr.w, self.desk_h(), 0)
            self.wins.append(win^)
            xi = len(self.wins) - 1
            self.explain_rect = List[Int]()
            self.explain_path = ""
            if ei >= 0:
                self.explain_path = self.wins[ei].path
                for v in [self.wins[ei].x, self.wins[ei].y, self.wins[ei].w, self.wins[ei].h]:
                    self.explain_rect.append(v)
                self.explain_beside(ei, xi)
        else:
            self.focus(xi)
            xi = self.top()
        self.wins[xi].title = "Explanation: " + err_title(page)
        self.wins[xi].path = "explain:" + err_page_key(page)
        var lines = md_render(err_body(page), max(20, self.wins[xi].w - 4), self.hl)
        var text = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for c in lines[k].cps:
                text.append(c)
        self.wins[xi].buf.load(text)
        self.wins[xi].buf.modified = False
        self.wins[xi].cr = 0
        self.wins[xi].top = 0
        self.say("Explanation of the error: Esc closes it, F6 goes back to the code")

    def explain_beside(mut self, ei: Int, xi: Int):
        """Give the explanation the right (or lower) half of the editor's place."""
        var x = self.wins[ei].x
        var y = self.wins[ei].y
        var w = self.wins[ei].w
        var h = self.wins[ei].h
        if w >= EXPLAIN_SIDE_W:
            var left = w - w // 2
            self.wins[ei].w = left
            self.wins[xi].x = x + left
            self.wins[xi].y = y
            self.wins[xi].w = w - left
            self.wins[xi].h = h
        elif h >= 16:
            var upper = h // 2
            self.wins[ei].h = upper
            self.wins[xi].x = x
            self.wins[xi].y = y + upper
            self.wins[xi].w = w
            self.wins[xi].h = h - upper
        else:
            self.wins[xi].x = x
            self.wins[xi].y = y
            self.wins[xi].w = w
            self.wins[xi].h = h

    def explain_fit(mut self):
        """In the tiled layout (which places the editors after every event): keep the
        explanation beside its editor."""
        if not self.tiled:
            return
        var xi = self.explain_index()
        if xi < 0:
            return
        var ei = self.find_editor(self.explain_path)
        if ei < 0 or self.wins[ei].hidden:
            return
        self.explain_beside(ei, xi)

    def explain_close(mut self):
        var xi = self.explain_index()
        if xi < 0:
            return
        _ = self.wins.pop(xi)
        var ei = self.find_editor(self.explain_path)
        if ei >= 0:
            if not self.tiled and len(self.explain_rect) == 4:
                self.wins[ei].x = self.explain_rect[0]
                self.wins[ei].y = self.explain_rect[1]
                self.wins[ei].w = self.explain_rect[2]
                self.wins[ei].h = self.explain_rect[3]
            self.focus(ei)
        self.explain_path = ""
        self.explain_rect = List[Int]()

    def explain_python(self) -> Bool:
        """Is the explanation in front about a Python habit (it has the section)?"""
        var xi = self.explain_index()
        if xi < 0:
            return False
        var key = String(self.wins[xi].path[byte=8:]) if self.wins[xi].path.startswith("explain:") else String("")
        for i in range(ERR_PAGE_COUNT):
            if err_page_key(i) == key:
                return err_body(i).find("## Coming from Python") >= 0
        return False

    def explain_key(mut self, k: Int) -> Bool:
        if k == KEY_ESC:
            self.explain_close()
            return True
        if (k == 112 or k == 80) and self.explain_python():      # P: Coming from Python
            self.help_page("coming-from-python.md")
            return True
        return False
