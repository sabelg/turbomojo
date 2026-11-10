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
    def match_at(self, r: Int, c: Int, pat: List[Int], cs: Bool) -> Bool:
        if c + len(pat) > self.buf.llen(r):
            return False
        for i in range(len(pat)):
            var a = self.buf.lines[r].c[c + i]
            var b = pat[i]
            if not cs:
                a = lower(a)
                b = lower(b)
            if a != b:
                return False
        return True

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
            var lim = self.buf.llen(r) - len(pat)
            var c = start
            while c <= lim:
                if self.match_at(r, c, pat, cs):
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
            while c + len(pat) <= self.buf.llen(r):
                if self.match_at(r, c, pat, cs):
                    _ = self.buf.delete(r, c, r, c + len(pat), self.cr, self.cc, g)
                    _ = self.buf.insert(r, c, rep, self.cr, self.cc, g)
                    c += len(rep)
                    count += 1
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
        var opens = List[Int]()
        opens.append(40)
        opens.append(91)
        opens.append(123)
        var closes = List[Int]()
        closes.append(41)
        closes.append(93)
        closes.append(125)
        for back in range(2):
            var c = self.cc - back
            var ch = self.buf.at(self.cr, c)
            for k in range(3):
                if ch == opens[k]:
                    var depth = 0
                    var r = self.cr
                    var cc = c
                    while r < self.buf.count():
                        while cc < self.buf.llen(r):
                            var x = self.buf.at(r, cc)
                            if x == opens[k]:
                                depth += 1
                            elif x == closes[k]:
                                depth -= 1
                                if depth == 0:
                                    return Pos(r, cc)
                            cc += 1
                        r += 1
                        cc = 0
                        if r - self.cr > 2000:
                            break
                    return Pos(-1, -1)
                if ch == closes[k]:
                    var depth = 0
                    var r = self.cr
                    var cc = c
                    while r >= 0:
                        while cc >= 0:
                            var x = self.buf.at(r, cc)
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
                        cc = self.buf.llen(r) - 1
                    return Pos(-1, -1)
        return Pos(-1, -1)
