"""Line operations (move, join, sort), case conversion and auto-closing pairs
(extends Window)."""
from std.collections import List
from buffer import TextBuffer, Pos
from regex import fold, unfold
from util import is_ident
from window import *


def cps_less(a: List[Int], b: List[Int]) -> Bool:
    """Order of two lines: by codepoint, a shorter line before a longer one it begins."""
    var n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return a[i] < b[i]
    return len(a) < len(b)


def closer_of(ch: Int) -> Int:
    """The character that closes `ch`, or -1 if ch opens nothing."""
    if ch == 40:
        return 41
    if ch == 91:
        return 93
    if ch == 123:
        return 125
    if ch == 34 or ch == 39:
        return ch
    return -1


__extension Window:
    # ------------------------------------------------------------ move lines
    def move_lines(mut self, d: Int) -> Bool:
        """Move the cursor line (or every line the selection touches) one line up
        (d = -1) or down (d = 1), as one undo step. False at the edge of the text."""
        var span = self.line_span()
        var a = span.r1
        var b = span.r2
        var last = self.buf.count() - 1
        if (d < 0 and a == 0) or (d > 0 and b >= last):
            return False
        # the lines a..b and their neighbour, written back in the new order
        var first = a - 1 if d < 0 else a
        var end = b if d < 0 else b + 1
        var text = List[Int]()
        if d < 0:
            for v in self.buf.get_text(a, 0, b, self.buf.llen(b)):
                text.append(v)
            text.append(10)
            for v in self.buf.line(a - 1):
                text.append(v)
        else:
            for v in self.buf.line(b + 1):
                text.append(v)
            text.append(10)
            for v in self.buf.get_text(a, 0, b, self.buf.llen(b)):
                text.append(v)
        var g = self.new_group()
        _ = self.buf.delete(first, 0, end, self.buf.llen(end), self.cr, self.cc, g)
        _ = self.buf.insert(first, 0, text, self.cr, self.cc, g)
        self.cr += d
        self.ar += d
        self.clamp()
        self.sync_want()
        self.break_group()
        self.follow = True
        return True

    # ------------------------------------------------------------ join lines
    def join_lines(mut self) -> Bool:
        """Join the cursor line with the next one (or all lines of the selection into
        one): the line break and the next line's indentation become a single blank.
        False if there is no line to join."""
        var span = self.line_span()
        var a = span.r1
        var joins = max(1, span.r2 - span.r1)
        if a + 1 >= self.buf.count():
            return False
        var g = self.new_group()
        var at = 0
        for _ in range(joins):
            if a + 1 >= self.buf.count():
                break
            var cur = self.buf.line(a)
            var next = self.buf.line(a + 1)
            # blanks at the end of this line and at the start of the next go away
            var e = len(cur)
            while e > 0 and (cur[e - 1] == 32 or cur[e - 1] == 9):
                e -= 1
            var s = 0
            while s < len(next) and (next[s] == 32 or next[s] == 9):
                s += 1
            _ = self.buf.delete(a, e, a + 1, s, self.cr, self.cc, g)
            at = e
            if e > 0 and s < len(next):
                var one = List[Int]()
                one.append(32)
                _ = self.buf.insert(a, e, one, self.cr, self.cc, g)
        self.sel = False
        self.cr = a
        self.cc = at
        self.sync_want()
        self.break_group()
        self.follow = True
        return True

    # ------------------------------------------------------------ sort lines
    def sort_lines(mut self) -> Int:
        """Sort the lines of the selection (the whole text without a selection) in
        ascending order. Returns how many lines were sorted; 0 if nothing changed."""
        var a = 0
        var b = self.buf.count() - 1
        if self.has_sel():
            var span = self.line_span()
            a = span.r1
            b = span.r2
        elif b > 0 and self.buf.llen(b) == 0:
            b -= 1                      # the empty line after the final newline stays last
        if b <= a:
            return 0
        var lines = List[List[Int]]()
        for r in range(a, b + 1):
            lines.append(self.buf.line(r))
        # merge sort on indexes (stable)
        var n = len(lines)
        var idx = List[Int]()
        var tmp = List[Int]()
        for i in range(n):
            idx.append(i)
            tmp.append(0)
        var width = 1
        while width < n:
            var lo = 0
            while lo < n:
                var mid = min(lo + width, n)
                var hi = min(lo + 2 * width, n)
                var i = lo
                var j = mid
                var k = lo
                while i < mid and j < hi:
                    if cps_less(lines[idx[j]], lines[idx[i]]):
                        tmp[k] = idx[j]
                        j += 1
                    else:
                        tmp[k] = idx[i]
                        i += 1
                    k += 1
                while i < mid:
                    tmp[k] = idx[i]
                    i += 1
                    k += 1
                while j < hi:
                    tmp[k] = idx[j]
                    j += 1
                    k += 1
                lo += 2 * width
            for q in range(n):
                idx[q] = tmp[q]
            width *= 2
        var changed = False
        for i in range(n):
            if idx[i] != i:
                changed = True
                break
        if not changed:
            return 0
        var text = List[Int]()
        for i in range(n):
            if i > 0:
                text.append(10)
            for v in lines[idx[i]]:
                text.append(v)
        var g = self.new_group()
        _ = self.buf.delete(a, 0, b, self.buf.llen(b), self.cr, self.cc, g)
        _ = self.buf.insert(a, 0, text, self.cr, self.cc, g)
        self.clamp()
        self.sync_want()
        self.break_group()
        self.follow = True
        return n

    # ------------------------------------------------------- case conversion
    def change_case(mut self, upper: Bool) -> Bool:
        """Make the selection (or, without one, the word at the cursor) upper or lower
        case. The selection is kept. False if there is nothing to change."""
        var r1 = self.cr
        var c1 = self.cc
        var r2 = self.cr
        var c2 = self.cc
        var had_sel = self.has_sel()
        if had_sel:
            var q = self.sel_range()
            r1 = q.r1
            c1 = q.c1
            r2 = q.r2
            c2 = q.c2
        else:
            var ln = self.buf.line(self.cr)
            c1 = min(self.cc, len(ln))
            c2 = c1
            while c1 > 0 and is_ident(ln[c1 - 1]):
                c1 -= 1
            while c2 < len(ln) and is_ident(ln[c2]):
                c2 += 1
            if c1 == c2:
                return False
        var old = self.buf.get_text(r1, c1, r2, c2)
        var new = List[Int]()
        var changed = False
        for v in old:
            var m = unfold(v) if upper else fold(v)
            if m != v:
                changed = True
            new.append(m)
        if not changed:
            return False
        var g = self.new_group()
        _ = self.buf.delete(r1, c1, r2, c2, self.cr, self.cc, g)
        _ = self.buf.insert(r1, c1, new, self.cr, self.cc, g)
        self.break_group()
        self.follow = True
        return True

    # ---------------------------------------------------- auto-closing pairs
    def brackets_owed(self, ln: List[Int], opener: Int, closer: Int) -> Int:
        """Openers minus closers on the line: positive means a closer is still missing."""
        var n = 0
        for v in ln:
            if v == opener:
                n += 1
            elif v == closer:
                n -= 1
        return n

    def type_smart(mut self, ch: Int):
        """Type a character with auto-closing pairs:
        - an opening bracket or a quote also inserts its partner when the cursor is at
          the end of the line or before a blank or a closing character;
        - typing the closing character that is already under the cursor steps over it
          (for brackets: only if the line is not missing one);
        - with a selection, an opening bracket or quote wraps the selection."""
        var ln = self.buf.line(self.cr)
        var nxt = ln[self.cc] if self.cc < len(ln) else -1
        var prv = ln[self.cc - 1] if self.cc > 0 and self.cc <= len(ln) else -1
        var close = closer_of(ch)
        if self.has_sel():
            if close < 0:
                self.type_char(ch, True)
                return
            var q = self.sel_range()
            var inner = self.buf.get_text(q.r1, q.c1, q.r2, q.c2)
            var text = List[Int]()
            text.append(ch)
            for v in inner:
                text.append(v)
            text.append(close)
            var g = self.new_group()
            _ = self.buf.delete(q.r1, q.c1, q.r2, q.c2, self.cr, self.cc, g)
            var p = self.buf.insert(q.r1, q.c1, text, self.cr, self.cc, g)
            # keep the wrapped text selected
            self.sel = True
            self.ar = q.r1
            self.ac = q.c1 + 1
            self.cr = p.r
            self.cc = p.c - 1
            self.sync_want()
            self.break_group()
            self.follow = True
            return
        var is_quote = ch == 34 or ch == 39
        if nxt == ch and (is_quote or ch == 41 or ch == 93 or ch == 125):
            var step = is_quote
            if not is_quote:
                var opener = 40 if ch == 41 else (91 if ch == 93 else 123)
                step = self.brackets_owed(ln, opener, ch) <= 0
            if step:
                self.cc += 1
                self.sync_want()
                self.follow = True
                return
        var room = nxt == -1 or nxt == 32 or nxt == 9 or nxt == 41 or nxt == 93 or nxt == 125 or nxt == 44 or nxt == 58
        if close >= 0 and room and (not is_quote or (not is_ident(prv) and prv != ch)):
            var pair = List[Int]()
            pair.append(ch)
            pair.append(close)
            self.insert_text(pair, ACT_TYPE)
            self.cc -= 1
            self.sync_want()
            return
        self.type_char(ch, True)

    def backspace_smart(mut self):
        """Backspace; between an empty pair such as "()" both characters go."""
        if not self.has_sel() and self.cc > 0:
            var ln = self.buf.line(self.cr)
            if self.cc < len(ln):
                var close = closer_of(ln[self.cc - 1])
                if close >= 0 and ln[self.cc] == close:
                    var g = self.group_for(ACT_BACK)
                    _ = self.buf.delete(self.cr, self.cc - 1, self.cr, self.cc + 1, self.cr, self.cc, g)
                    self.cc -= 1
                    self.sync_want()
                    self.follow = True
                    return
        self.backspace()
