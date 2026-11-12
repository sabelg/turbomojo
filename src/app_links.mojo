"""Hyperlinks (OSC 8) on the file:line references the IDE shows: every row of the
Message window's pages (Message, Search, Problems) and of the agent panel. A row the
page knows the place of (App.errs: a build error, a search hit, a problem) links to
that place, on the reference as written or else on the whole row; other references
are linked when their file exists, relative ones looked up in the folder the IDE
works in and the project. Links are made after a window is drawn, so a menu or a
dialog drawn over it later takes them away (Screen.place clears them).

In a terminal that has mouse reporting on, a link is followed with the terminal's
own modifier - Ctrl-Shift-click in kitty, Shift-click in most others.
"""
from std.collections import List
from appstate import *
from util import *
from links import *
from screen import CONT


__extension App:
    def link_place(mut self, path: String, line: Int, col: Int) -> String:
        if not self.scr.hyperlinks:
            return ""
        if self.link_host.byte_length() == 0:
            self.link_host = host_name()
        var abs = path if path.startswith("/") else String(self.cwd) + "/" + path
        return link_uri(self.link_format, self.link_host, abs, line, col)

    def link_resolve(self, path: String) -> String:
        """The file a reference names ('' if there is none)."""
        if path.startswith("/"):
            return path if path_exists(path) else String("")
        if path.startswith("~/"):
            var home = env_or("HOME", "")
            var p = home + path[byte=1:]
            return p if home.byte_length() > 0 and path_exists(p) else String("")
        for base in [String(self.cwd), self.project_dir, self.msg_base]:
            if base.byte_length() > 0 and path_exists(base + "/" + path):
                return base + "/" + path
        return ""

    def row_cells(self, x0: Int, x1: Int, y: Int) -> Tuple[List[Int], List[Int]]:
        """The characters shown in cells [x0, x1) of row y, and the cell each starts in."""
        var cps = List[Int]()
        var xs = List[Int]()
        for x in range(x0, x1):
            var c = self.scr.ch[y * self.scr.w + x]
            if c == CONT:
                continue
            cps.append(c if c >= 32 else 32)
            xs.append(x)
        return (cps^, xs^)

    def link_span(mut self, y: Int, xs: List[Int], s: Int, e: Int, x1: Int, uri: String):
        """Link the characters [s, e) of a row (with the second cell of a wide last one)."""
        if uri.byte_length() == 0 or s >= e:
            return
        var end = xs[e] if e < len(xs) else x1
        self.scr.link(xs[s], y, end - xs[s], uri)

    def link_rows(mut self, i: Int):
        """Links on the visible rows of window i (the Message window or the agent panel)."""
        if not self.scr.hyperlinks:
            return
        var x0 = self.wins[i].x + 1
        var x1 = min(self.scr.w, self.wins[i].x + self.wins[i].w - 1)
        var y0 = self.wins[i].y + 1
        var y1 = min(self.scr.h - 1, self.wins[i].y + self.wins[i].h - 1)
        if x1 - x0 < 4 or y0 < 0:
            return
        var known = self.wins[i].kind == WK_MESSAGE and not self.wins[i].wrap
        for y in range(y0, y1):
            var got = self.row_cells(x0, x1, y)
            var cps = got[0].copy()
            var xs = got[1].copy()
            var refs = find_refs(cps)
            if known:
                var r = self.wins[i].top + (y - y0)
                var at = -1
                for k in range(len(self.errs)):
                    if self.errs[k].msg_line == r:
                        at = k
                        break
                if at >= 0:
                    var loc = self.errs[at].copy()
                    var uri = self.link_place(loc.path, loc.row, loc.col)
                    if len(refs) > 0:
                        self.link_span(y, xs, refs[0].start, refs[0].end, x1, uri)
                    else:
                        # (the reference is not written out: the whole row)
                        var s = 0
                        while s < len(cps) and cps[s] == 32:
                            s += 1
                        var e = len(cps)
                        while e > s and cps[e - 1] == 32:
                            e -= 1
                        self.link_span(y, xs, s, e, x1, uri)
                    continue
            for f in refs:
                var p = self.link_resolve(f.path)
                if p.byte_length() > 0:
                    self.link_span(y, xs, f.start, f.end, x1, self.link_place(p, f.line, f.col))
