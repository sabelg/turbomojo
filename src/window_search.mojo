"""Window search: find, replace, word start and bracket matching."""
from std.collections import List
from buffer import TextBuffer, Pos, TAB_WIDTH
from screen import Screen
from palette import Palette
from highlight import Highlighter, C_TEXT
from util import is_ident, lower, decode, cp_len, to_str, str_contains, char_width
from window import *


__extension Window:
    # ------------------------------------------------------------- search
    def match_in(self, ln: List[Int], c: Int, pat: List[Int], cs: Bool) -> Bool:
        """Does `pat` occur in the line `ln` at column c?"""
        if c < 0 or c + len(pat) > len(ln):
            return False
        for i in range(len(pat)):
            var a = ln[c + i]
            var b = pat[i]
            if not cs:
                a = lower(a)
                b = lower(b)
            if a != b:
                return False
        return True

    def match_at(self, r: Int, c: Int, pat: List[Int], cs: Bool) -> Bool:
        return self.match_in(self.buf.line(r), c, pat, cs)

    def find_next(mut self, pat: List[Int], cs: Bool) -> Bool:
        """Search forward from the cursor (wrapping). Selects the match."""
        if len(pat) == 0:
            return False
        var n = self.buf.count()
        var sr = self.cr
        var sc = self.cc
        if self.has_sel():
            var s = self.sel_range()
            sr = s.r1
            sc = s.c1 + 1
        for k in range(n + 1):
            var r = (sr + k) % n
            var start = sc if k == 0 else 0
            var ln = self.buf.line(r)
            var lim = len(ln) - len(pat)
            var c = start
            while c <= lim:
                if self.match_in(ln, c, pat, cs):
                    self.sel = True
                    self.ar = r
                    self.ac = c
                    self.cr = r
                    self.cc = c + len(pat)
                    self.sync_want()
                    self.follow = True
                    self.break_group()
                    return True
                c += 1
        return False

    def sel_matches(self, pat: List[Int], cs: Bool) -> Bool:
        if not self.has_sel():
            return False
        var s = self.sel_range()
        if s.r1 != s.r2 or s.c2 - s.c1 != len(pat):
            return False
        return self.match_at(s.r1, s.c1, pat, cs)

    def replace_all(mut self, pat: List[Int], rep: List[Int], cs: Bool) -> Int:
        if len(pat) == 0:
            return 0
        var g = self.new_group()
        var count = 0
        for r in range(self.buf.count()):
            var c = 0
            var ln = self.buf.line(r)
            while c + len(pat) <= len(ln):
                if self.match_in(ln, c, pat, cs):
                    _ = self.buf.delete(r, c, r, c + len(pat), self.cr, self.cc, g)
                    _ = self.buf.insert(r, c, rep, self.cr, self.cc, g)
                    c += len(rep)
                    count += 1
                    ln = self.buf.line(r)       # the line changed under us
                else:
                    c += 1
        self.sel = False
        self.clamp()
        self.break_group()
        self.follow = True
        return count

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
