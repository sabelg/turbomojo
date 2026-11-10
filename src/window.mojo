"""Editor / message windows: cursor, selection, editing commands and drawing."""
from std.collections import List
from buffer import TextBuffer, Pos, TAB_WIDTH
from screen import Screen
from palette import Palette
from highlight import Highlighter, C_TEXT
from util import is_ident, lower, decode, cp_len, to_str, str_contains, char_width

comptime WK_EDITOR = 0
comptime WK_MESSAGE = 1

comptime ACT_NONE = 0
comptime ACT_TYPE = 1
comptime ACT_BACK = 2
comptime ACT_DEL = 3
comptime ACT_OTHER = 4


@fieldwise_init
struct Range(Copyable, Movable):
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int


struct Window(Copyable, Movable):
    var kind: Int
    var title: String
    var path: String
    var buf: TextBuffer
    var cr: Int
    var cc: Int
    var want: Int
    var top: Int
    var left: Int
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var sx: Int
    var sy: Int
    var sw: Int
    var sh: Int
    var zoomed: Bool
    var sel: Bool
    var ar: Int
    var ac: Int
    var number: Int
    var gseq: Int
    var cur_group: Int
    var last_act: Int
    var follow: Bool
    var gut: Int

    def __init__(out self, kind: Int, title: String, path: String, x: Int, y: Int, w: Int, h: Int, number: Int):
        self.kind = kind
        self.title = title
        self.path = path
        self.buf = TextBuffer()
        self.cr = 0
        self.cc = 0
        self.want = 0
        self.top = 0
        self.left = 0
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.sx = x
        self.sy = y
        self.sw = w
        self.sh = h
        self.zoomed = False
        self.sel = False
        self.ar = 0
        self.ac = 0
        self.number = number
        self.gseq = 0
        self.cur_group = 0
        self.last_act = ACT_NONE
        self.follow = True
        self.gut = 0

    # ------------------------------------------------------------ geometry
    def contains(self, px: Int, py: Int) -> Bool:
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h

    def rows(self) -> Int:
        return max(1, self.h - 2)

    def cols(self) -> Int:
        return max(1, self.w - 2 - self.gut)

    def gutter_for(self, line_numbers: Bool) -> Int:
        if not line_numbers or self.kind != WK_EDITOR:
            return 0
        var n = self.buf.count()
        var d = 1
        while n >= 10:
            n //= 10
            d += 1
        return max(d, 3) + 1

    # ------------------------------------------------------ visual columns
    def adv(self, ch: Int, v: Int) -> Int:
        """Display columns taken by `ch` when it starts at visual column v."""
        if ch == 9:
            return TAB_WIDTH - v % TAB_WIDTH
        return char_width(ch)

    def vcol(self, r: Int, c: Int) -> Int:
        """Visual (screen) column of character index c on row r."""
        var v = 0
        var n = min(c, self.buf.llen(r))
        for i in range(n):
            v += self.adv(self.buf.lines[r].c[i], v)
        return v

    def col_at_vcol(self, r: Int, target: Int) -> Int:
        """Character index whose cell covers visual column `target`."""
        var v = 0
        var n = self.buf.llen(r)
        var i = 0
        while i < n:
            var a = self.adv(self.buf.lines[r].c[i], v)
            if a > 0 and v + a > target:
                # closer to the right edge of a tab/wide char -> place after it
                if target - v >= (a + 1) // 2 and a > 1:
                    i += 1
                    while i < n and char_width(self.buf.lines[r].c[i]) == 0:
                        i += 1
                return i
            v += a
            i += 1
        return n

    def sync_want(mut self):
        self.want = self.vcol(self.cr, self.cc)

    def ensure_visible(mut self):
        var rws = self.rows()
        var cls = self.cols()
        if self.cr < self.top:
            self.top = self.cr
        if self.cr >= self.top + rws:
            self.top = self.cr - rws + 1
        var vc = self.vcol(self.cr, self.cc)
        if vc < self.left:
            self.left = max(0, vc - 4)
        if vc >= self.left + cls - 1:
            self.left = vc - cls + 2
        if self.top < 0:
            self.top = 0

    def scroll(mut self, d: Int):
        var maxtop = max(0, self.buf.count() - 1)
        self.top = max(0, min(maxtop, self.top + d))
        self.follow = False

    def screen_to_pos(self, px: Int, py: Int) -> Pos:
        var r = self.top + (py - self.y - 1)
        var v = self.left + (px - self.x - 1 - self.gut)
        r = max(0, min(r, self.buf.count() - 1))
        var c = self.col_at_vcol(r, max(0, v))
        return Pos(r, c)

    # ------------------------------------------------------------ groups
    def new_group(mut self) -> Int:
        self.gseq += 1
        self.cur_group = self.gseq
        return self.cur_group

    def group_for(mut self, act: Int) -> Int:
        if act != self.last_act or act == ACT_OTHER or self.cur_group == 0:
            _ = self.new_group()
        self.last_act = act
        return self.cur_group

    def break_group(mut self):
        self.last_act = ACT_NONE

    # --------------------------------------------------------- selection
    def has_sel(self) -> Bool:
        return self.sel and (self.ar != self.cr or self.ac != self.cc)

    def sel_range(self) -> Range:
        if self.ar < self.cr or (self.ar == self.cr and self.ac < self.cc):
            return Range(self.ar, self.ac, self.cr, self.cc)
        return Range(self.cr, self.cc, self.ar, self.ac)

    def in_sel(self, r: Int, c: Int) -> Bool:
        if not self.has_sel():
            return False
        var s = self.sel_range()
        if r < s.r1 or r > s.r2:
            return False
        if r == s.r1 and c < s.c1:
            return False
        if r == s.r2 and c >= s.c2:
            return False
        return True

    def selected_text(self) -> List[Int]:
        if not self.has_sel():
            return List[Int]()
        var s = self.sel_range()
        return self.buf.get_text(s.r1, s.c1, s.r2, s.c2)

    def begin_move(mut self, shift: Bool):
        if shift:
            if not self.sel:
                self.sel = True
                self.ar = self.cr
                self.ac = self.cc
        else:
            self.sel = False
        self.break_group()
        self.follow = True

    def select_all(mut self):
        self.sel = True
        self.ar = 0
        self.ac = 0
        self.cr = self.buf.count() - 1
        self.cc = self.buf.llen(self.cr)
        self.follow = True

    def clamp(mut self):
        self.cr = max(0, min(self.cr, self.buf.count() - 1))
        self.cc = max(0, min(self.cc, self.buf.llen(self.cr)))

    def goto(mut self, r: Int, c: Int):
        self.sel = False
        self.cr = r
        self.cc = c
        self.clamp()
        self.sync_want()
        self.follow = True
        # center the target line
        self.top = max(0, self.cr - self.rows() // 2)
        self.break_group()

    # ----------------------------------------------------------- movement
    def move_left(mut self, shift: Bool, word: Bool):
        if not shift and self.has_sel():
            var s = self.sel_range()
            self.begin_move(False)
            self.cr = s.r1
            self.cc = s.c1
            self.sync_want()
            return
        self.begin_move(shift)
        if self.cc > 0:
            if word:
                var c = self.cc
                while c > 0 and not is_ident(self.buf.at(self.cr, c - 1)):
                    c -= 1
                while c > 0 and is_ident(self.buf.at(self.cr, c - 1)):
                    c -= 1
                self.cc = c
            else:
                self.cc -= 1
                while self.cc > 0 and char_width(self.buf.at(self.cr, self.cc)) == 0:
                    self.cc -= 1
        elif self.cr > 0:
            self.cr -= 1
            self.cc = self.buf.llen(self.cr)
        self.sync_want()

    def move_right(mut self, shift: Bool, word: Bool):
        if not shift and self.has_sel():
            var s = self.sel_range()
            self.begin_move(False)
            self.cr = s.r2
            self.cc = s.c2
            self.sync_want()
            return
        self.begin_move(shift)
        var n = self.buf.llen(self.cr)
        if self.cc < n:
            if word:
                var c = self.cc
                while c < n and is_ident(self.buf.at(self.cr, c)):
                    c += 1
                while c < n and not is_ident(self.buf.at(self.cr, c)):
                    c += 1
                self.cc = c
            else:
                self.cc += 1
                while self.cc < n and char_width(self.buf.at(self.cr, self.cc)) == 0:
                    self.cc += 1
        elif self.cr + 1 < self.buf.count():
            self.cr += 1
            self.cc = 0
        self.sync_want()

    def move_vert(mut self, d: Int, shift: Bool):
        self.begin_move(shift)
        self.cr = max(0, min(self.buf.count() - 1, self.cr + d))
        self.cc = self.col_at_vcol(self.cr, self.want)

    def page(mut self, d: Int, shift: Bool):
        var n = self.rows() - 1
        self.top = max(0, min(self.buf.count() - 1, self.top + d * n))
        self.move_vert(d * n, shift)

    def home(mut self, shift: Bool, doc: Bool):
        self.begin_move(shift)
        if doc:
            self.cr = 0
            self.cc = 0
        else:
            var ind = 0
            var n = self.buf.llen(self.cr)
            while ind < n and self.buf.at(self.cr, ind) == 32:
                ind += 1
            self.cc = 0 if self.cc == ind else ind
        self.sync_want()

    def end(mut self, shift: Bool, doc: Bool):
        self.begin_move(shift)
        if doc:
            self.cr = self.buf.count() - 1
        self.cc = self.buf.llen(self.cr)
        self.sync_want()

    # ------------------------------------------------------------ editing
    def delete_sel(mut self, g: Int) -> Bool:
        if not self.has_sel():
            self.sel = False
            return False
        var s = self.sel_range()
        _ = self.buf.delete(s.r1, s.c1, s.r2, s.c2, self.cr, self.cc, g)
        self.cr = s.r1
        self.cc = s.c1
        self.sel = False
        return True

    def insert_text(mut self, text: List[Int], act: Int):
        var g = self.group_for(act)
        _ = self.delete_sel(g)
        var p = self.buf.insert(self.cr, self.cc, text, self.cr, self.cc, g)
        self.cr = p.r
        self.cc = p.c
        self.sync_want()
        self.follow = True

    def type_char(mut self, ch: Int, insert_mode: Bool):
        if not insert_mode and not self.has_sel() and self.cc < self.buf.llen(self.cr):
            var g = self.group_for(ACT_TYPE)
            _ = self.buf.delete(self.cr, self.cc, self.cr, self.cc + 1, self.cr, self.cc, g)
        var t = List[Int]()
        t.append(ch)
        self.insert_text(t, ACT_TYPE)

    def indent_of(self, r: Int) -> Int:
        """Number of leading whitespace characters (spaces or tabs)."""
        var i = 0
        var n = self.buf.llen(r)
        while i < n and (self.buf.at(r, i) == 32 or self.buf.at(r, i) == 9):
            i += 1
        return i

    def indent_unit(self) -> List[Int]:
        var t = List[Int]()
        if self.buf.use_tabs:
            t.append(9)
        else:
            for _ in range(TAB_WIDTH):
                t.append(32)
        return t^

    def newline(mut self, auto_indent: Bool):
        var t = List[Int]()
        t.append(10)
        if auto_indent:
            var ind = min(self.indent_of(self.cr), self.cc)
            for i in range(ind):
                t.append(self.buf.lines[self.cr].c[i])
            var k = self.cc - 1
            while k >= 0 and (self.buf.at(self.cr, k) == 32 or self.buf.at(self.cr, k) == 9):
                k -= 1
            if k >= 0 and self.buf.at(self.cr, k) == 58:
                for u in self.indent_unit():
                    t.append(u)
        self.insert_text(t, ACT_OTHER)
        self.break_group()

    def backspace(mut self):
        var g = self.group_for(ACT_BACK)
        if self.delete_sel(g):
            self.follow = True
            return
        if self.cc > 0:
            var n = 1
            var all_spaces = True
            for i in range(self.cc):
                if self.buf.at(self.cr, i) != 32:
                    all_spaces = False
                    break
            if all_spaces:
                n = self.cc - ((self.cc - 1) // TAB_WIDTH) * TAB_WIDTH
            _ = self.buf.delete(self.cr, self.cc - n, self.cr, self.cc, self.cr, self.cc, g)
            self.cc -= n
        elif self.cr > 0:
            var pl = self.buf.llen(self.cr - 1)
            _ = self.buf.delete(self.cr - 1, pl, self.cr, 0, self.cr, self.cc, g)
            self.cr -= 1
            self.cc = pl
        self.sync_want()
        self.follow = True

    def delete_fwd(mut self):
        var g = self.group_for(ACT_DEL)
        if self.delete_sel(g):
            self.follow = True
            return
        if self.cc < self.buf.llen(self.cr):
            _ = self.buf.delete(self.cr, self.cc, self.cr, self.cc + 1, self.cr, self.cc, g)
        elif self.cr + 1 < self.buf.count():
            _ = self.buf.delete(self.cr, self.cc, self.cr + 1, 0, self.cr, self.cc, g)
        self.follow = True

    def line_span(self) -> Range:
        """Rows covered by the selection (or the cursor line)."""
        if not self.has_sel():
            return Range(self.cr, 0, self.cr, 0)
        var s = self.sel_range()
        var r2 = s.r2
        if s.c2 == 0 and r2 > s.r1:
            r2 -= 1
        return Range(s.r1, 0, r2, 0)

    def indent_lines(mut self, dir: Int):
        var span = self.line_span()
        var g = self.new_group()
        for r in range(span.r1, span.r2 + 1):
            if dir > 0:
                if self.buf.llen(r) == 0:
                    continue
                var sp = self.indent_unit()
                _ = self.buf.insert(r, 0, sp, self.cr, self.cc, g)
                if r == self.cr:
                    self.cc += len(sp)
                if self.sel and r == self.ar and self.ac > 0:
                    self.ac += len(sp)
            else:
                var n = 0
                if self.buf.at(r, 0) == 9:
                    n = 1
                else:
                    while n < TAB_WIDTH and self.buf.at(r, n) == 32:
                        n += 1
                if n == 0:
                    continue
                _ = self.buf.delete(r, 0, r, n, self.cr, self.cc, g)
                if r == self.cr:
                    self.cc = max(0, self.cc - n)
                if self.sel and r == self.ar:
                    self.ac = max(0, self.ac - n)
        self.break_group()
        self.clamp()
        self.follow = True

    def tab(mut self, shift: Bool):
        if shift or (self.has_sel() and self.sel_range().r1 != self.sel_range().r2):
            self.indent_lines(-1 if shift else 1)
            return
        var t = List[Int]()
        if self.buf.use_tabs:
            t.append(9)
        else:
            var n = TAB_WIDTH - (self.vcol(self.cr, self.cc) % TAB_WIDTH)
            for _ in range(n):
                t.append(32)
        self.insert_text(t, ACT_TYPE)

    def toggle_comment(mut self):
        var span = self.line_span()
        var all_commented = True
        var min_ind = 1 << 30
        for r in range(span.r1, span.r2 + 1):
            if self.buf.llen(r) == 0:
                continue
            var ind = self.indent_of(r)
            min_ind = min(min_ind, ind)
            if self.buf.at(r, ind) != 35:
                all_commented = False
        if min_ind == 1 << 30:
            return
        var g = self.new_group()
        for r in range(span.r1, span.r2 + 1):
            if self.buf.llen(r) == 0:
                continue
            if all_commented:
                var ind = self.indent_of(r)
                var n = 2 if self.buf.at(r, ind + 1) == 32 else 1
                _ = self.buf.delete(r, ind, r, ind + n, self.cr, self.cc, g)
                if r == self.cr and self.cc > ind:
                    self.cc = max(ind, self.cc - n)
            else:
                var t = List[Int]()
                t.append(35)
                t.append(32)
                _ = self.buf.insert(r, min_ind, t, self.cr, self.cc, g)
                if r == self.cr and self.cc >= min_ind:
                    self.cc += 2
        self.sel = False
        self.break_group()
        self.clamp()
        self.follow = True

    def duplicate_line(mut self):
        var g = self.new_group()
        var t = List[Int]()
        t.append(10)
        for c in self.buf.lines[self.cr].c:
            t.append(c)
        _ = self.buf.insert(self.cr, self.buf.llen(self.cr), t, self.cr, self.cc, g)
        self.cr += 1
        self.sel = False
        self.break_group()
        self.follow = True

    def delete_line(mut self) -> List[Int]:
        var g = self.new_group()
        var out: List[Int]
        if self.cr + 1 < self.buf.count():
            out = self.buf.delete(self.cr, 0, self.cr + 1, 0, self.cr, self.cc, g)
        elif self.cr > 0:
            out = self.buf.delete(self.cr - 1, self.buf.llen(self.cr - 1), self.cr, self.buf.llen(self.cr), self.cr, self.cc, g)
            self.cr -= 1
        else:
            out = self.buf.delete(0, 0, 0, self.buf.llen(0), self.cr, self.cc, g)
        self.sel = False
        self.clamp()
        self.break_group()
        self.follow = True
        return out^

    def undo(mut self):
        var p = self.buf.undo()
        if p.r >= 0:
            self.sel = False
            self.cr = p.r
            self.cc = p.c
            self.clamp()
            self.sync_want()
        self.break_group()
        self.follow = True

    def redo(mut self):
        var p = self.buf.redo()
        if p.r >= 0:
            self.sel = False
            self.cr = p.r
            self.cc = p.c
            self.clamp()
            self.sync_want()
        self.break_group()
        self.follow = True

    def replace_all_text(mut self, cps: List[Int]):
        """Replace the whole buffer as one undo step (used by the formatter)."""
        var g = self.new_group()
        var last = self.buf.count() - 1
        _ = self.buf.delete(0, 0, last, self.buf.llen(last), self.cr, self.cc, g)
        _ = self.buf.insert(0, 0, cps, self.cr, self.cc, g)
        self.sel = False
        self.clamp()
        self.break_group()
        self.follow = True

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

    # --------------------------------------------------------------- draw
    def draw(
        self, mut scr: Screen, pal: Palette, hl: Highlighter, active: Bool, hl_line: Bool, insert_mode: Bool, show_ws: Bool
    ):
        var is_msg = self.kind == WK_MESSAGE
        var bg = pal.msg_bg if is_msg else pal.ed_bg
        var fg = pal.msg_fg if is_msg else pal.ed_fg
        var ffg = (pal.msg_frame if is_msg else pal.frame_act) if active else pal.frame_inact
        scr.fill(self.x, self.y, self.w, self.h, 32, fg, bg)
        scr.frame(self.x, self.y, self.w, self.h, active, ffg, bg)
        # title
        var t = " " + self.title + " "
        var tl = cp_len(t)
        var tx = self.x + max(1, (self.w - tl) // 2)
        scr.clip(self.x + 1, self.y, self.w - 2, 1)
        _ = scr.text(tx, self.y, t, pal.title_fg if active else ffg, bg)
        scr.no_clip()
        if active and self.w > 12:
            _ = scr.text(self.x + 2, self.y, "[", ffg, bg)
            scr.put(self.x + 3, self.y, 0x25A0, pal.icon_fg, bg)
            _ = scr.text(self.x + 4, self.y, "]", ffg, bg)
            _ = scr.text(self.x + self.w - 5, self.y, "[", ffg, bg)
            scr.put(self.x + self.w - 4, self.y, 0x2195 if self.zoomed else 0x2191, pal.icon_fg, bg)
            _ = scr.text(self.x + self.w - 3, self.y, "]", ffg, bg)
        if self.number > 0 and self.number < 10 and self.w > 12:
            _ = scr.text(self.x + self.w - 7, self.y, String(self.number), ffg, bg)

        var rws = self.rows()
        var cls = self.cols()
        var cx0 = self.x + 1 + self.gut
        var brk = Pos(-1, -1)
        if active and not is_msg:
            brk = self.match_bracket()
        var bc = -1
        if brk.r >= 0:
            bc = self.cc if self.is_bracket(self.buf.at(self.cr, self.cc)) else self.cc - 1
        var has_sel = self.has_sel()
        var sr = self.sel_range()
        # find highlighter state at the first visible line
        var st = 0
        var tmp = List[Int]()
        if not is_msg:
            for r in range(0, min(self.top, self.buf.count())):
                st = hl.line(self.buf.lines[r].c, st, tmp)
        scr.clip(self.x + 1, self.y + 1, self.w - 2, self.h - 2)
        var classes = List[Int]()
        for i in range(rws):
            var r = self.top + i
            var yy = self.y + 1 + i
            if r >= self.buf.count():
                break
            var rowbg = bg
            var rowfg = fg
            if is_msg:
                var lt = to_str(self.buf.lines[r].c)
                if str_contains(lt, "error:"):
                    rowfg = pal.msg_err
                elif str_contains(lt, "warning:"):
                    rowfg = pal.msg_warn
                elif str_contains(lt, "note:"):
                    rowfg = pal.msg_note
                if r == self.cr:
                    rowbg = pal.msg_sel_bg
                    rowfg = pal.msg_sel_fg
                    scr.fill(self.x + 1, yy, self.w - 2, 1, 32, rowfg, rowbg)
            elif hl_line and active and r == self.cr:
                rowbg = pal.curline_bg
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            if self.gut > 0:
                var num = String(r + 1)
                var pad = self.gut - 1 - cp_len(num)
                var s = String("")
                for _ in range(pad):
                    s += " "
                s += num + " "
                _ = scr.text(self.x + 1, yy, s, pal.frame_act if r == self.cr and active else pal.gutter_fg, pal.gutter_bg)
            if not is_msg:
                st = hl.line(self.buf.lines[r].c, st, classes)
            var n = self.buf.llen(r)
            scr.clip(cx0, self.y + 1, cls, self.h - 2)
            var v = 0
            var lastx = -1
            var lim = self.left + cls
            for c in range(n):
                if v >= lim:
                    break
                var ch = self.buf.lines[r].c[c]
                var a = self.adv(ch, v)
                if a == 0:
                    if lastx >= 0:
                        scr.combine(lastx, yy, ch)
                    continue
                if v + a <= self.left:
                    v += a
                    lastx = -1
                    continue
                var cfg = rowfg
                var cbg = rowbg
                if not is_msg:
                    cfg = pal.syn[classes[c]]
                if self.in_sel(r, c):
                    cfg = pal.sel_fg
                    cbg = pal.sel_bg
                if (r == brk.r and c == brk.c) or (r == self.cr and c == bc):
                    cfg = pal.bracket_fg
                    cbg = pal.bracket_bg
                var sx = cx0 + v - self.left
                if ch == 9 or v < self.left:
                    # tab (or a wide char cut by the left edge): blank cells
                    for k in range(max(v, self.left), v + a):
                        scr.put(cx0 + k - self.left, yy, 32, cfg, cbg)
                    if ch == 9 and show_ws:
                        scr.put(max(sx, cx0), yy, 0x2192, pal.gutter_fg, cbg)
                    lastx = -1
                else:
                    scr.put(sx, yy, ch, cfg, cbg)
                    lastx = sx
                v += a
            # selection past end of line shows the newline
            if has_sel and sr.r1 <= r and r < sr.r2 and v >= self.left and v < lim:
                scr.put(cx0 + v - self.left, yy, 32, pal.sel_fg, pal.sel_bg)
            scr.clip(self.x + 1, self.y + 1, self.w - 2, self.h - 2)
        scr.no_clip()

        # bottom: position + modified marker
        if not is_msg:
            var pos = " " + String(self.cr + 1) + ":" + String(self.vcol(self.cr, self.cc) + 1) + " "
            var px = self.x + 2
            if self.buf.modified:
                scr.put(px, self.y + self.h - 1, 0x263C, pal.icon_fg, bg)
                px += 1
            _ = scr.text(px, self.y + self.h - 1, pos, ffg, bg)
        if active and self.h > 4:
            # vertical scrollbar
            var sx = self.x + self.w - 1
            var y0 = self.y + 1
            var y1 = self.y + self.h - 2
            scr.put(sx, y0, 0x25B2, pal.scroll_fg, pal.scroll_bg)
            scr.put(sx, y1, 0x25BC, pal.scroll_fg, pal.scroll_bg)
            for yy in range(y0 + 1, y1):
                scr.put(sx, yy, 0x2592, pal.scroll_fg, pal.scroll_bg)
            var span = y1 - y0 - 1
            if span > 0:
                var tot = max(1, self.buf.count() - 1)
                var ty = y0 + 1 + (min(self.cr, tot) * (span - 1)) // tot
                scr.put(sx, ty, 0x25A0, pal.scroll_fg, pal.scroll_bg)
            if not is_msg and self.w > 30:
                # horizontal scrollbar
                var hx0 = self.x + 18
                var hx1 = self.x + self.w - 2
                var by = self.y + self.h - 1
                scr.put(hx0, by, 0x25C4, pal.scroll_fg, pal.scroll_bg)
                scr.put(hx1, by, 0x25BA, pal.scroll_fg, pal.scroll_bg)
                for xx in range(hx0 + 1, hx1):
                    scr.put(xx, by, 0x2592, pal.scroll_fg, pal.scroll_bg)
                var hs = hx1 - hx0 - 1
                if hs > 0:
                    var maxw = 1
                    for r in range(self.top, min(self.buf.count(), self.top + rws)):
                        maxw = max(maxw, self.buf.llen(r))
                    var tx2 = hx0 + 1 + (min(self.vcol(self.cr, self.cc), maxw) * (hs - 1)) // maxw
                    scr.put(tx2, by, 0x25A0, pal.scroll_fg, pal.scroll_bg)

    def is_bracket(self, ch: Int) -> Bool:
        return ch == 40 or ch == 41 or ch == 91 or ch == 93 or ch == 123 or ch == 125
