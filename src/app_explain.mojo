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
from markdown import md_render_rich, MdLine
from docpane import md_mojo_blocks
from commands import CM_AGENT_EXPLAIN
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
                self.say("No explanation for this message yet (A: ask agent, ?: search docs, or Help > Error messages)")
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
        self.explain_md = err_body(page)
        var w = max(20, self.wins[xi].w - 4)
        var links = List[String]()
        self.explain_lines = md_render_rich(self.explain_md, w, self.hl, links, True)
        self.explain_lines_w = w
        var text = List[Int]()
        for k in range(len(self.explain_lines)):
            if k > 0:
                text.append(10)
            for c in self.explain_lines[k].cps:
                text.append(c)
        self.wins[xi].buf.load(text)
        self.wins[xi].buf.modified = False
        self.wins[xi].cr = 0
        self.wins[xi].top = 0
        self.say("Explanation of the error: Esc closes, F6 code, C copy fix, T try fix, A ask agent")

    def explain_draw(mut self, xi: Int):
        """Draw the error explanation's Markdown with full rich styling over the window interior."""
        if xi < 0 or xi >= len(self.wins) or self.wins[xi].w < 6 or self.wins[xi].h < 4:
            return
        var w = max(20, self.wins[xi].w - 4)
        if w != self.explain_lines_w and self.explain_md.byte_length() > 0:
            var links = List[String]()
            self.explain_lines = md_render_rich(self.explain_md, w, self.hl, links, True)
            self.explain_lines_w = w
            var text = List[Int]()
            for k in range(len(self.explain_lines)):
                if k > 0:
                    text.append(10)
                for c in self.explain_lines[k].cps:
                    text.append(c)
            var keep_cr = self.wins[xi].cr
            var keep_top = self.wins[xi].top
            self.wins[xi].buf.load(text)
            self.wins[xi].buf.modified = False
            self.wins[xi].cr = max(0, min(keep_cr, self.wins[xi].buf.count() - 1))
            self.wins[xi].top = max(0, min(keep_top, self.wins[xi].buf.count() - 1))
        var lines = self.explain_lines.copy()
        self.draw_md(self.wins[xi].x + 1, self.wins[xi].y + 1, max(2, self.wins[xi].w - 2), max(1, self.wins[xi].h - 2), lines, self.wins[xi].top)

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

    def explain_fix_snippet(self) -> String:
        """The fixed 'After (builds)' code block from the open error explanation."""
        var blocks = md_mojo_blocks(self.explain_md)
        if len(blocks) > 0:
            return blocks[len(blocks) - 1]
        return ""

    def explain_key(mut self, k: Int) raises -> Bool:
        if k == KEY_ESC:
            self.explain_close()
            return True
        if (k == 112 or k == 80) and self.explain_python():      # P: Coming from Python
            self.help_page("coming-from-python.md")
            return True
        if k == 97 or k == 65:                                   # A: Ask agent about this error
            self.exec(CM_AGENT_EXPLAIN)
            return True
        if k == 63:                                              # ?: Search docs for this error
            var xi = self.explain_index()
            var q = String("")
            if xi >= 0 and self.wins[xi].title.startswith("Explanation: "):
                q = String(self.wins[xi].title[byte=13:])
            self.docs_find_dialog(q)
            return True
        if k == 99 or k == 67:                                   # C: Copy fixed code block
            var code = self.explain_fix_snippet()
            if code.byte_length() == 0:
                self.say("No code block on this explanation page")
            else:
                var cps = decode(code)
                self.clipboard = cps.copy()
                self.osc52(cps)
                self.say("Copied fixed 'After' example to the clipboard")
            return True
        if k == 116 or k == 84:                                  # T: Try fixed code in scratch buffer
            var code = self.explain_fix_snippet()
            if code.byte_length() == 0:
                self.say("No code block on this explanation page")
            else:
                self.open_scratch_snippet(code, "fixed example")
            return True
        return False
