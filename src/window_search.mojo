"""Window search: find, replace, word start and bracket matching."""
from std.collections import List
from buffer import TextBuffer, Pos, TAB_WIDTH
from screen import Screen
from palette import Palette
from highlight import Highlighter, C_TEXT
from util import is_ident, lower, decode, cp_len, to_str, str_contains, char_width
from search import Search, make_search
from window import *


__extension Window:
    # ------------------------------------------------------------- search
    def scope_cols(self, r: Int, n: Int) -> Range:
        """Columns of row r that may be searched: (c1, c2) in a Range, c2 < 0 for none.
        The whole line unless the search is limited to a selection."""
        if not self.scope_on:
            return Range(r, 0, r, n)
        if r < self.scope.r1 or r > self.scope.r2:
            return Range(r, 0, r, -1)
        var lo = self.scope.c1 if r == self.scope.r1 else 0
        var hi = min(n, self.scope.c2) if r == self.scope.r2 else n
        return Range(r, lo, r, hi)

    def select_match(mut self, r: Int, s: Int, e: Int):
        self.sel = True
        self.ar = r
        self.ac = s
        self.cr = r
        self.cc = e
        self.sync_want()
        self.follow = True
        self.break_group()

    def search_from(mut self, s: Search, r0: Int, c0: Int) -> Bool:
        """Select the first match at or after (r0, c0), wrapping around the end of the
        text (or of the search scope). Returns False if there is none."""
        if not s.ok:
            return False
        var n = self.buf.count()
        for k in range(n + 1):
            var r = (r0 + k) % n
            if self.scope_on and (r < self.scope.r1 or r > self.scope.r2):
                continue
            var ln = self.buf.line(r)
            var cols = self.scope_cols(r, len(ln))
            var start = max(c0, cols.c1) if k == 0 else cols.c1
            var m = s.caps_in(ln, start)
            if len(m) > 0 and m[1] <= cols.c2:
                self.select_match(r, m[0], m[1])
                return True
        return False

    def search_next(mut self, s: Search) -> Bool:
        """Find the next match after the cursor (wrapping) and select it."""
        return self.search_from(s, self.cr, self.cc)

    def sel_is_match(self, s: Search) -> Bool:
        """Is the selection exactly one match?"""
        if not self.has_sel() or not s.ok:
            return False
        var q = self.sel_range()
        if q.r1 != q.r2:
            return False
        var m = s.caps_in(self.buf.line(q.r1), q.c1)
        return len(m) > 0 and m[0] == q.c1 and m[1] == q.c2

    def replace_current(mut self, s: Search, rep: List[Int]) -> Bool:
        """Replace the selected match (one undo step). The cursor ends after the new text."""
        if not self.sel_is_match(s):
            return False
        var q = self.sel_range()
        var ln = self.buf.line(q.r1)
        var m = s.caps_in(ln, q.c1)
        var text = s.replacement(rep, ln, m)
        var g = self.new_group()
        _ = self.buf.delete(q.r1, q.c1, q.r1, q.c2, self.cr, self.cc, g)
        var p = self.buf.insert(q.r1, q.c1, text, self.cr, self.cc, g)
        if self.scope_on and q.r1 <= self.scope.r2:
            # keep the end of the search scope on the same character
            if q.r1 == self.scope.r2:
                self.scope.c2 = p.c + (self.scope.c2 - q.c2)
            self.scope.r2 += p.r - q.r1
        self.sel = False
        self.cr = p.r
        self.cc = p.c
        self.sync_want()
        self.break_group()
        self.follow = True
        return True

    def replace_matches(mut self, s: Search, rep: List[Int]) -> Int:
        """Replace every match (inside the scope, if one is set) as one undo step.
        Returns how many were replaced."""
        if not s.ok:
            return 0
        var g = self.new_group()
        var count = 0
        var last = self.buf.count() - 1
        var first = 0
        if self.scope_on:
            first = self.scope.r1
            last = min(last, self.scope.r2)
        # bottom to top: a replacement that adds lines does not move the rows still to do
        var r = last
        while r >= first:
            var ln = self.buf.line(r)
            var cols = self.scope_cols(r, len(ln))
            var c = cols.c1
            var out = List[Int]()
            var from_c = -1
            var upto = -1
            var n_here = 0
            while c < cols.c2:
                var m = s.caps_in(ln, c)
                if len(m) == 0 or m[1] > cols.c2:
                    break
                if from_c < 0:
                    from_c = m[0]
                else:
                    for i in range(upto, m[0]):
                        out.append(ln[i])        # the text between two matches
                for v in s.replacement(rep, ln, m):
                    out.append(v)
                upto = m[1]
                c = m[1]
                n_here += 1
            if n_here > 0:
                _ = self.buf.delete(r, from_c, r, upto, self.cr, self.cc, g)
                _ = self.buf.insert(r, from_c, out, self.cr, self.cc, g)
                count += n_here
            r -= 1
        self.sel = False
        self.clamp()
        self.sync_want()
        self.break_group()
        self.follow = True
        return count

    def count_matches(self, s: Search, line_limit: Int) -> Range:
        """How many matches there are and which one is selected, as Range(total, index, ..):
        r1 = total, c1 = 1-based number of the selected match (0 if the selection is not a
        match), r2 = 1 if counting stopped at `line_limit` lines."""
        var total = 0
        var index = 0
        var cut = 0
        if not s.ok:
            return Range(0, 0, 0, 0)
        var q = self.sel_range()
        var has = self.has_sel() and q.r1 == q.r2
        var first = 0
        var last = self.buf.count() - 1
        if self.scope_on:
            first = self.scope.r1
            last = min(last, self.scope.r2)
        if last - first + 1 > line_limit:
            last = first + line_limit - 1
            cut = 1
        for r in range(first, last + 1):
            var ln = self.buf.line(r)
            var cols = self.scope_cols(r, len(ln))
            var ms = s.all_in(ln, cols.c1, cols.c2)
            var k = 0
            while k + 1 < len(ms):
                total += 1
                if has and r == q.r1 and ms[k] == q.c1 and ms[k + 1] == q.c2:
                    index = total
                k += 2
        return Range(total, index, cut, 0)

    def set_highlight(mut self, s: Search):
        """Show every match of `s` in the window until clear_highlight()."""
        self.hs = s.copy()
        self.hs_on = s.ok

    def clear_highlight(mut self):
        self.hs_on = False

    # The plain-text forms used before the search options existed.
    def match_at(self, r: Int, c: Int, pat: List[Int], cs: Bool) -> Bool:
        var m = make_search(pat, cs, False, False).caps_in(self.buf.line(r), c)
        return len(m) > 0 and m[0] == c

    def find_next(mut self, pat: List[Int], cs: Bool) -> Bool:
        return self.search_next(make_search(pat, cs, False, False))

    def sel_matches(self, pat: List[Int], cs: Bool) -> Bool:
        return self.sel_is_match(make_search(pat, cs, False, False))

    def replace_all(mut self, pat: List[Int], rep: List[Int], cs: Bool) -> Int:
        return self.replace_matches(make_search(pat, cs, False, False), rep)

    def word_start(self) -> Int:
        var c = self.cc
        while c > 0 and is_ident(self.buf.at(self.cr, c - 1)):
            c -= 1
        return c

    def match_bracket(self) -> Pos:
        """Position of the bracket matching the one at (or just before) the cursor, or
        Pos(-1, -1). Looks at most 2000 lines away."""
        var opens = List[Int]()
        var closes = List[Int]()
        for o in [40, 91, 123]:
            opens.append(o)
        for cl in [41, 93, 125]:
            closes.append(cl)
        var here = self.buf.line(self.cr)
        for back in range(2):
            var c = self.cc - back
            if c < 0 or c >= len(here):
                continue
            var ch = here[c]
            for k in range(3):
                if ch == opens[k]:
                    var depth = 0
                    var r = self.cr
                    var cc = c
                    var ln = here.copy()
                    while r < self.buf.count():
                        while cc < len(ln):
                            var x = ln[cc]
                            if x == opens[k]:
                                depth += 1
                            elif x == closes[k]:
                                depth -= 1
                                if depth == 0:
                                    return Pos(r, cc)
                            cc += 1
                        r += 1
                        cc = 0
                        if r - self.cr > 2000 or r >= self.buf.count():
                            break
                        ln = self.buf.line(r)
                    return Pos(-1, -1)
                if ch == closes[k]:
                    var depth = 0
                    var r = self.cr
                    var cc = c
                    var ln = here.copy()
                    while r >= 0:
                        while cc >= 0:
                            var x = ln[cc]
                            if x == closes[k]:
                                depth += 1
                            elif x == opens[k]:
                                depth -= 1
                                if depth == 0:
                                    return Pos(r, cc)
                            cc -= 1
                        r -= 1
                        if r < 0 or self.cr - r > 2000:
                            break
                        ln = self.buf.line(r)
                        cc = len(ln) - 1
                    return Pos(-1, -1)
        return Pos(-1, -1)
