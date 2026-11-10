"""Editor / message windows: state, cursor, selection and editing commands.

Search and bracket matching are in window_search.mojo, drawing in window_draw.mojo
(both extend Window; import them with `from ... import *`)."""
from std.collections import List
from buffer import TextBuffer, Pos, TAB_WIDTH
from watch import FileSig
from screen import Screen
from palette import Palette
from highlight import Highlighter, C_TEXT, line_state, scan_states
from util import is_ident, lower, decode, cp_len, to_str, str_contains, char_width
from grapheme import cluster_end, cluster_start, cluster_width, ends_with_plain_mark

comptime WK_EDITOR = 0
comptime LEX_BUDGET = 4000     # lines re-scanned after an edit before giving up on rejoining
comptime LEX_BLOCK = 20000     # lines scanned per block when extending the cache
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
    var clustered: Bool   # the terminal draws a grapheme cluster as one glyph (mode 2027)
    var swap_file: String    # path of this buffer's swap file ('' if none written)
    var overwrite_ok: Bool   # the user chose to keep their version over a changed file
    var disk_sig: FileSig    # size/mtime of the file when it was last loaded or saved
    var swap_version: Int    # buffer version the swap file holds (-1 if none)

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
        self.clustered = False
        self.swap_file = ""
        self.swap_version = -1
        self.disk_sig = FileSig()
        self.overwrite_ok = False

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
            return self.buf.tab_width - v % self.buf.tab_width
        return char_width(ch)

    def span(self, ln: List[Int], i: Int, e: Int, v: Int) -> Int:
        """Display columns taken by the grapheme cluster ln[i:e] starting at column v."""
        if e - i == 1:
            return self.adv(ln[i], v)
        return cluster_width(ln, i, e, self.clustered)

    def vcol(self, r: Int, c: Int) -> Int:
        """Visual (screen) column of character index c on row r."""
        var v = 0
        var ln = self.buf.line(r)
        var n = min(c, len(ln))
        var i = 0
        while i < n:
            var e = cluster_end(ln, i)
            if e > n:
                break          # c is inside a cluster: it shares the cluster's column
            v += self.span(ln, i, e, v)
            i = e
        return v

    def col_at_vcol(self, r: Int, target: Int) -> Int:
        """Character index of the grapheme cluster that covers visual column `target`."""
        var v = 0
        var ln = self.buf.line(r)
        var n = len(ln)
        var i = 0
        while i < n:
            var e = cluster_end(ln, i)
            var a = self.span(ln, i, e, v)
            if a > 0 and v + a > target:
                # closer to the right edge of a tab/wide char -> place after it
                if target - v >= (a + 1) // 2 and a > 1:
                    return e
                return i
            v += a
            i = e
        return n

    def sync_want(mut self):
        self.want = self.vcol(self.cr, self.cc)

    # ------------------------------------------------- highlighter state cache
    def sync_lex(mut self, upto: Int):
        """Bring the per-line lexer state cache up to date: re-scan the lines touched by
        edits until the state rejoins what was cached, then extend the cache so that it
        covers rows 0..upto. Call before drawing."""
        if self.kind != WK_EDITOR:
            return
        var count = self.buf.count()
        if self.buf.ldirty_from >= 0:
            var row = self.buf.ldirty_from
            var last = self.buf.ldirty_to
            self.buf.ldirty_from = -1
            self.buf.ldirty_to = -1
            if row < len(self.buf.lstate):
                var st = Int(self.buf.lstate[row])
                var budget = LEX_BUDGET
                while row < count:
                    var bytes = self.buf.line_bytes(row)
                    st = line_state(bytes, 0, len(bytes), st)
                    self.buf.lex_work += 1
                    if row + 1 >= len(self.buf.lstate):
                        self.buf.lstate.append(UInt8(st))
                    elif row >= last and Int(self.buf.lstate[row + 1]) == st:
                        break                       # rejoined the cached states
                    else:
                        self.buf.lstate[row + 1] = UInt8(st)
                    row += 1
                    budget -= 1
                    if budget <= 0 and row >= last:
                        # the change keeps propagating (e.g. a new open string): stop
                        # here and let the rest be rebuilt lazily when it is shown
                        while len(self.buf.lstate) > row + 1:
                            _ = self.buf.lstate.pop()
                        break
        # extend: scan whole lines in blocks straight from the stored bytes
        var want = min(upto, count - 1)
        while len(self.buf.lstate) - 1 < want:
            var known = len(self.buf.lstate) - 1
            var stop = min(count - 1, max(want, known + 1))
            stop = min(stop, known + LEX_BLOCK)
            var a = self.buf.rope.line_start(known)
            var b = self.buf.rope.line_start(stop)      # rows known..stop-1 end with a newline
            var block = self.buf.rope.slice_bytes(a, b)
            _ = scan_states(block, Int(self.buf.lstate[known]), self.buf.lstate)
            self.buf.lex_work += stop - known
            if len(self.buf.lstate) - 1 != stop:
                break                               # defensive: never loop forever

    def lex_state_at(self, row: Int) -> Int:
        """Lexer state at the start of `row`: from the cache when it covers the row,
        otherwise computed by scanning from the last cached line (slow path)."""
        if self.kind != WK_EDITOR:
            return 0
        var known = len(self.buf.lstate) - 1
        var clean = self.buf.ldirty_from < 0 or self.buf.ldirty_from >= row
        if row <= known and clean:
            return Int(self.buf.lstate[row])
        var from_row = min(known, row) if clean else min(self.buf.ldirty_from, min(known, row))
        var st = Int(self.buf.lstate[from_row])
        for r in range(from_row, min(row, self.buf.count())):
            var bytes = self.buf.line_bytes(r)
            st = line_state(bytes, 0, len(bytes), st)
        return st

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
                self.cc = cluster_start(self.buf.line(self.cr), self.cc)
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
                self.cc = cluster_end(self.buf.line(self.cr), self.cc)
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
        var ln = self.buf.line(r)
        var n = len(ln)
        while i < n and (ln[i] == 32 or ln[i] == 9):
            i += 1
        return i

    def indent_unit(self) -> List[Int]:
        var t = List[Int]()
        if self.buf.use_tabs:
            t.append(9)
        else:
            for _ in range(self.buf.indent_size):
                t.append(32)
        return t^

    def newline(mut self, auto_indent: Bool):
        var t = List[Int]()
        t.append(10)
        if auto_indent:
            var ind = min(self.indent_of(self.cr), self.cc)
            var cur_line = self.buf.line(self.cr)
            for i in range(ind):
                t.append(cur_line[i])
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
            var ln = self.buf.line(self.cr)
            for i in range(min(self.cc, len(ln))):
                if ln[i] != 32:
                    all_spaces = False
                    break
            if all_spaces:
                n = self.cc - ((self.cc - 1) // self.buf.indent_size) * self.buf.indent_size
            else:
                # a whole cluster (emoji sequence, flag, syllable) goes at once; a letter
                # with accents loses only its last accent
                var cs = cluster_start(ln, self.cc)
                if not ends_with_plain_mark(ln, cs, min(self.cc, len(ln))):
                    n = max(1, self.cc - cs)
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
            var ce = cluster_end(self.buf.line(self.cr), self.cc)
            _ = self.buf.delete(self.cr, self.cc, self.cr, ce, self.cr, self.cc, g)
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
                    while n < self.buf.indent_size and self.buf.at(r, n) == 32:
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
            var n = self.buf.indent_size - (self.vcol(self.cr, self.cc) % self.buf.indent_size)
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
        for c in self.buf.line(self.cr):
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

    def trim_trailing_whitespace(mut self) -> Int:
        """Remove spaces and tabs at line ends as one undo step. Returns lines changed."""
        var g = 0
        var changed = 0
        for r in range(self.buf.count()):
            var ln = self.buf.line(r)
            var n = len(ln)
            var e = n
            while e > 0 and (ln[e - 1] == 32 or ln[e - 1] == 9):
                e -= 1
            if e < n:
                if g == 0:
                    g = self.new_group()
                _ = self.buf.delete(r, e, r, n, self.cr, self.cc, g)
                changed += 1
        if changed > 0:
            self.clamp()
            if self.sel:
                self.ar = max(0, min(self.ar, self.buf.count() - 1))
                self.ac = max(0, min(self.ac, self.buf.llen(self.ar)))
            self.sync_want()
            self.break_group()
        return changed

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
