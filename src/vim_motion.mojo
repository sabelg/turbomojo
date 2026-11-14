"""The vim interface's motions and text objects (P12-02), worked out on the text alone:
where w b e W B E, f t F T, %, { } and the rest go from a position, and what iw aw i" a"
i( a( i{ ip and their kin cover. app_vim.mojo moves the cursor there, or hands the span
to an operator (d c y > <).

A motion is exclusive (the character it lands on is not part of an operator's span),
inclusive (it is) or linewise (whole lines), as vim's `:help exclusive` has it."""
from std.collections import List
from buffer import TextBuffer, Pos

comptime VK_EXCL = 0
comptime VK_INCL = 1
comptime VK_LINE = 2


struct VimMove(Copyable, Movable):
    var ok: Bool
    var r: Int
    var c: Int
    var kind: Int

    def __init__(out self, ok: Bool, r: Int, c: Int, kind: Int):
        self.ok = ok
        self.r = r
        self.c = c
        self.kind = kind


struct VimSpan(Copyable, Movable):
    """What an operator works on: (r1, c1) up to (r2, c2), the end not included; for
    `lines`, rows r1 to r2 whole."""
    var ok: Bool
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int
    var lines: Bool

    def __init__(out self, ok: Bool, r1: Int, c1: Int, r2: Int, c2: Int, lines: Bool):
        self.ok = ok
        self.r1 = r1
        self.c1 = c1
        self.r2 = r2
        self.c2 = c2
        self.lines = lines


def no_span() -> VimSpan:
    return VimSpan(False, 0, 0, 0, 0, False)


def is_blank(ch: Int) -> Bool:
    return ch == 32 or ch == 9


def vcls(ch: Int, big: Bool) -> Int:
    """A character's class for the word motions: 0 blank, 1 punctuation, 2 a word's
    letter (letters, digits, _ and everything past ASCII). For W B E (`big`) every
    character that is not a blank is of one class."""
    if is_blank(ch) or ch < 0:
        return 0
    if big:
        return 1
    if (ch >= 48 and ch <= 57) or (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95 or ch >= 128:
        return 2
    return 1


def first_nonblank(line: List[Int]) -> Int:
    """The column of the line's first character that is not a blank (its last one if
    the line is all blanks)."""
    var c = 0
    while c < len(line) and is_blank(line[c]):
        c += 1
    if c < len(line):
        return c
    return max(0, len(line) - 1)


def indent_end(line: List[Int]) -> Int:
    """Where the line's leading blanks end (its length if it is all blanks)."""
    var c = 0
    while c < len(line) and is_blank(line[c]):
        c += 1
    return c


# ------------------------------------------------------------------- words
def word_fwd(buf: TextBuffer, r0: Int, c0: Int, big: Bool) -> Pos:
    """w / W: the start of the next word; an empty line is a word too. At the text's
    end: the end of the last line."""
    var r = r0
    var c = c0
    var line = buf.line(r)
    var n = len(line)
    if c < n:
        var k = vcls(line[c], big)
        if k != 0:
            while c < n and vcls(line[c], big) == k:
                c += 1
    while True:
        if c >= n:
            if r + 1 >= buf.count():
                return Pos(r, n)
            r += 1
            line = buf.line(r)
            n = len(line)
            c = 0
            if n == 0:
                return Pos(r, 0)
            continue
        if is_blank(line[c]):
            c += 1
            continue
        return Pos(r, c)


def word_end(buf: TextBuffer, r0: Int, c0: Int, big: Bool) -> Pos:
    """e / E: the end of the word (the next one when already at an end)."""
    var r = r0
    var c = c0 + 1
    var line = buf.line(r)
    while True:
        if c >= len(line):
            if r + 1 >= buf.count():
                return Pos(r0, c0)
            r += 1
            line = buf.line(r)
            c = 0
            continue
        if is_blank(line[c]):
            c += 1
            continue
        break
    var k = vcls(line[c], big)
    while c + 1 < len(line) and vcls(line[c + 1], big) == k:
        c += 1
    return Pos(r, c)


def word_back(buf: TextBuffer, r0: Int, c0: Int, big: Bool) -> Pos:
    """b / B: the start of the word (the one before when already at a start); an
    empty line is a word too."""
    var r = r0
    var line = buf.line(r)
    var c = min(c0, len(line)) - 1
    while True:
        if c < 0:
            if r == 0:
                return Pos(0, 0)
            r -= 1
            line = buf.line(r)
            c = len(line) - 1
            if len(line) == 0:
                return Pos(r, 0)
            continue
        if is_blank(line[c]):
            c -= 1
            continue
        break
    var k = vcls(line[c], big)
    while c > 0 and vcls(line[c - 1], big) == k:
        c -= 1
    return Pos(r, c)


def at_word_end(line: List[Int], c: Int, big: Bool) -> Bool:
    """Is (c) the last character of its word (cw changes just up to there)?"""
    if c >= len(line):
        return True
    var k = vcls(line[c], big)
    return c + 1 >= len(line) or vcls(line[c + 1], big) != k


# --------------------------------------------------------- in-line finding
def find_in_line(line: List[Int], c: Int, kind: Int, ch: Int, n: Int, again: Bool) -> Int:
    """f t F T (`kind` the letter) for `ch`, the n-th time; -1 when it is not there.
    `again`: for ; and , - t and T then do not stop in front of the character they
    stopped in front of last time."""
    if kind == 102 or kind == 116:          # f t: to the right
        var i = c + 1 + (1 if kind == 116 and again else 0)
        var left = n
        while i < len(line):
            if line[i] == ch:
                left -= 1
                if left == 0:
                    return i if kind == 102 else i - 1
            i += 1
        return -1
    var j = c - 1 - (1 if kind == 84 and again else 0)
    var left2 = n
    while j >= 0:
        if line[j] == ch:
            left2 -= 1
            if left2 == 0:
                return j if kind == 70 else j + 1
        j -= 1
    return -1


# ----------------------------------------------------------------- brackets
def bracket_kind(ch: Int) -> Int:
    """0 ( ), 1 [ ], 2 { }, 3 < > for an opening bracket; 10 + that for a closing one;
    -1 for anything else."""
    if ch == 40:
        return 0
    if ch == 91:
        return 1
    if ch == 123:
        return 2
    if ch == 41:
        return 10
    if ch == 93:
        return 11
    if ch == 125:
        return 12
    return -1


def open_of(k: Int) -> Int:
    if k == 0:
        return 40
    if k == 1:
        return 91
    if k == 2:
        return 123
    return 60


def close_of(k: Int) -> Int:
    if k == 0:
        return 41
    if k == 1:
        return 93
    if k == 2:
        return 125
    return 62


def match_fwd(buf: TextBuffer, r0: Int, c0: Int, op: Int, cl: Int) -> Pos:
    """The `cl` that closes the `op` at (r0, c0); Pos(-1, -1) if none."""
    var depth = 0
    var r = r0
    var c = c0
    var line = buf.line(r)
    while True:
        while c < len(line):
            if line[c] == op:
                depth += 1
            elif line[c] == cl:
                depth -= 1
                if depth == 0:
                    return Pos(r, c)
            c += 1
        r += 1
        if r >= buf.count():
            return Pos(-1, -1)
        line = buf.line(r)
        c = 0


def match_back(buf: TextBuffer, r0: Int, c0: Int, op: Int, cl: Int) -> Pos:
    """The `op` that opens the `cl` at (r0, c0) - or, with (r0, c0) not on a `cl`,
    the `op` that encloses it (pairs closed before it are skipped); Pos(-1, -1) if
    none."""
    var depth = 0
    var r = r0
    var line = buf.line(r)
    var c = min(c0, len(line) - 1)
    if c == c0 and c >= 0 and line[c] == cl:
        c -= 1
    while True:
        while c >= 0:
            if line[c] == cl:
                depth += 1
            elif line[c] == op:
                depth -= 1
                if depth < 0:
                    return Pos(r, c)
            c -= 1
        r -= 1
        if r < 0:
            return Pos(-1, -1)
        line = buf.line(r)
        c = len(line) - 1


def match_pair(buf: TextBuffer, r: Int, c: Int) -> Pos:
    """%: the bracket matching the first one at or after the cursor on its line."""
    var line = buf.line(r)
    var i = c
    while i < len(line) and bracket_kind(line[i]) < 0:      # (not < >: they are comparisons too)
        i += 1
    if i >= len(line):
        return Pos(-1, -1)
    var k = bracket_kind(line[i])
    if k < 10:
        return match_fwd(buf, r, i, open_of(k), close_of(k))
    return match_back(buf, r, i, open_of(k - 10), close_of(k - 10))


# --------------------------------------------------------------- paragraphs
def para_fwd(buf: TextBuffer, r0: Int) -> Pos:
    """}: the next empty line after the paragraph (the end of the text if none)."""
    var last = buf.count() - 1
    var r = r0
    while r < last and buf.llen(r) == 0:
        r += 1
    while r < last and buf.llen(r) != 0:
        r += 1
    if buf.llen(r) != 0:
        return Pos(r, buf.llen(r))
    return Pos(r, 0)


def para_back(buf: TextBuffer, r0: Int) -> Pos:
    """{: the empty line before the paragraph (the start of the text if none)."""
    var r = r0
    while r > 0 and buf.llen(r) == 0:
        r -= 1
    while r > 0 and buf.llen(r) != 0:
        r -= 1
    return Pos(r, 0)


# ------------------------------------------------------------------ motions
def vim_move(buf: TextBuffer, r: Int, c: Int, ch: Int, n: Int, counted: Bool, arg: Int, again: Bool, for_op: Bool) -> VimMove:
    """Where motion `ch` goes from (r, c), `n` times; `counted` whether a count was
    typed (G), `arg` the character for f t F T, `for_op` when an operator is waiting
    (w then stops at the end of the line its last word is on, as in vim). gg is `ch`
    103 (g)."""
    var last = buf.count() - 1
    var line = buf.line(r)
    if ch == 104:                                   # h
        if c == 0:
            return VimMove(False, r, c, VK_EXCL)
        return VimMove(True, r, max(0, c - n), VK_EXCL)
    if ch == 108:                                   # l
        var lim = len(line) if for_op else max(0, len(line) - 1)
        if c >= lim:
            return VimMove(False, r, c, VK_EXCL)
        return VimMove(True, r, min(c + n, lim), VK_EXCL)
    if ch == 48:                                    # 0
        return VimMove(True, r, 0, VK_EXCL)
    if ch == 94:                                    # ^
        return VimMove(True, r, first_nonblank(line), VK_EXCL)
    if ch == 36:                                    # $
        var rr = min(r + n - 1, last)
        return VimMove(True, rr, max(0, buf.llen(rr) - 1), VK_INCL)
    if ch == 106 or ch == 107 or ch == 43 or ch == 45 or ch == 95:    # j k + - _
        var to = r + n if (ch == 106 or ch == 43) else (r - n if ch != 95 else r + n - 1)
        if (ch == 106 or ch == 43) and r >= last:
            return VimMove(False, r, c, VK_LINE)
        if (ch == 107 or ch == 45) and r <= 0:
            return VimMove(False, r, c, VK_LINE)
        to = max(0, min(to, last))
        return VimMove(True, to, first_nonblank(buf.line(to)), VK_LINE)
    if ch == 71 or ch == 103:                       # G gg
        var to2 = (n - 1) if counted else (last if ch == 71 else 0)
        to2 = max(0, min(to2, last))
        return VimMove(True, to2, first_nonblank(buf.line(to2)), VK_LINE)
    if ch == 119 or ch == 87:                       # w W
        var big = ch == 87
        var p = Pos(r, c)
        for _ in range(n):
            var prev = p.copy()
            p = word_fwd(buf, prev.r, prev.c, big)
            if for_op and p.r > prev.r and buf.llen(prev.r) > 0:
                # the last word moved over ends its line: so does the span
                p = Pos(prev.r, buf.llen(prev.r))
                break
        if p.r == r and p.c == c:
            return VimMove(False, r, c, VK_EXCL)
        return VimMove(True, p.r, p.c, VK_EXCL)
    if ch == 101 or ch == 69:                       # e E
        var q = Pos(r, c)
        for _ in range(n):
            q = word_end(buf, q.r, q.c, ch == 69)
        return VimMove(q.r != r or q.c != c, q.r, q.c, VK_INCL)
    if ch == 98 or ch == 66:                        # b B
        var b = Pos(r, c)
        for _ in range(n):
            b = word_back(buf, b.r, b.c, ch == 66)
        return VimMove(b.r != r or b.c != c, b.r, b.c, VK_EXCL)
    if ch == 102 or ch == 116 or ch == 70 or ch == 84:    # f t F T
        var at = find_in_line(line, c, ch, arg, n, again)
        if at < 0:
            return VimMove(False, r, c, VK_EXCL)
        return VimMove(True, r, at, VK_INCL if (ch == 102 or ch == 116) else VK_EXCL)
    if ch == 37:                                    # %
        var m = match_pair(buf, r, c)
        return VimMove(m.r >= 0, m.r if m.r >= 0 else r, m.c if m.r >= 0 else c, VK_INCL)
    if ch == 125 or ch == 123:                      # } {
        var g = Pos(r, c)
        for _ in range(n):
            g = para_fwd(buf, g.r) if ch == 125 else para_back(buf, g.r)
            if ch == 125 and g.r == last and buf.llen(last) != 0:
                break
        return VimMove(g.r != r or g.c != c, g.r, g.c, VK_EXCL)
    return VimMove(False, r, c, VK_EXCL)


def is_motion(ch: Int) -> Bool:
    """A key that is a motion by itself (f t F T and g want one more key)."""
    for m in [104, 108, 106, 107, 43, 45, 95, 48, 94, 36, 71, 119, 87, 101, 69, 98, 66, 37, 125, 123]:
        if ch == m:
            return True
    return False


def motion_span(buf: TextBuffer, r: Int, c: Int, m: VimMove) -> VimSpan:
    """The span an operator works on for a motion from (r, c) to `m`, with vim's rule
    for an exclusive motion that ends at the start of a later line: the span then ends
    at the end of the line before, and it is whole lines when it also started at or
    before the first line's indentation (d} at a paragraph's first line, dw on an
    empty line)."""
    if not m.ok:
        return no_span()
    if m.kind == VK_LINE:
        return VimSpan(True, min(r, m.r), 0, max(r, m.r), 0, True)
    var r1 = r
    var c1 = c
    var r2 = m.r
    var c2 = m.c
    if r2 < r1 or (r2 == r1 and c2 < c1):
        r1 = m.r
        c1 = m.c
        r2 = r
        c2 = c
    if m.kind == VK_INCL:
        c2 = min(c2 + 1, buf.llen(r2))
    elif c2 == 0 and r2 > r1:
        if c1 <= indent_end(buf.line(r1)):
            return VimSpan(True, r1, 0, r2 - 1, 0, True)
        r2 -= 1
        c2 = buf.llen(r2)
    return VimSpan(True, r1, c1, r2, c2, False)


# ------------------------------------------------------------- text objects
def obj_word(line: List[Int], r: Int, c: Int, inner: Bool, big: Bool) -> VimSpan:
    var n = len(line)
    if n == 0:
        return no_span()
    var at = min(c, n - 1)
    var k = vcls(line[at], big)
    var s = at
    var e = at + 1
    while s > 0 and vcls(line[s - 1], big) == k:
        s -= 1
    while e < n and vcls(line[e], big) == k:
        e += 1
    if not inner:
        if k == 0:
            # on blanks: they and the word after them
            if e < n:
                var k2 = vcls(line[e], big)
                while e < n and vcls(line[e], big) == k2:
                    e += 1
        else:
            var e2 = e
            while e2 < n and is_blank(line[e2]):
                e2 += 1
            if e2 > e:
                e = e2
            else:
                while s > 0 and is_blank(line[s - 1]):
                    s -= 1
    return VimSpan(True, r, s, r, e, False)


def obj_quote(line: List[Int], r: Int, c: Int, inner: Bool, q: Int) -> VimSpan:
    """i" a" (and ' `): the quoted text around the cursor, or the next on the line."""
    var qs = List[Int]()
    var i = 0
    while i < len(line):
        if line[i] == 92:
            i += 2
            continue
        if line[i] == q:
            qs.append(i)
        i += 1
    var k = 0
    while k + 1 < len(qs):
        var a = qs[k]
        var b = qs[k + 1]
        if (a <= c and c <= b) or a > c:
            if inner:
                return VimSpan(True, r, a + 1, r, b, False)
            var e = b + 1
            var s = a
            var e2 = e
            while e2 < len(line) and is_blank(line[e2]):
                e2 += 1
            if e2 > e:
                e = e2
            else:
                while s > 0 and is_blank(line[s - 1]):
                    s -= 1
            return VimSpan(True, r, s, r, e, False)
        k += 2
    return no_span()


def obj_bracket(buf: TextBuffer, r: Int, c: Int, inner: Bool, kind: Int) -> VimSpan:
    """i( a( i{ a{ i[ a[ i< a<: inside the brackets around the cursor (with them for
    a). A block whose brackets end and start their lines is whole lines inside."""
    var op = open_of(kind)
    var cl = close_of(kind)
    var line = buf.line(r)
    var o: Pos
    if c < len(line) and line[c] == op:
        o = Pos(r, c)
    else:
        o = match_back(buf, r, c, op, cl)      # (on the closing one too)
    if o.r < 0:
        return no_span()
    var e = match_fwd(buf, o.r, o.c, op, cl)
    if e.r < 0:
        return no_span()
    if not inner:
        return VimSpan(True, o.r, o.c, e.r, e.c + 1, False)
    var ol = buf.line(o.r)
    var el = buf.line(e.r)
    if e.r > o.r + 1 and o.c == len(ol) - 1 and indent_end(el) == e.c:
        return VimSpan(True, o.r + 1, 0, e.r - 1, 0, True)
    var s1r = o.r
    var s1c = o.c + 1
    if s1c >= len(ol) and e.r > o.r:
        s1r = o.r + 1
        s1c = 0
    return VimSpan(True, s1r, s1c, e.r, e.c, False)


def obj_para(buf: TextBuffer, r: Int, inner: Bool) -> VimSpan:
    """ip ap: the lines around the cursor that are all empty or all not; ap takes the
    empty lines after them too (before them when there are none after)."""
    var last = buf.count() - 1
    var empty = buf.llen(r) == 0
    var a = r
    var b = r
    while a > 0 and (buf.llen(a - 1) == 0) == empty:
        a -= 1
    while b < last and (buf.llen(b + 1) == 0) == empty:
        b += 1
    if not inner:
        if b < last:
            var b2 = b + 1
            var e2 = buf.llen(b2) == 0
            while b2 < last and (buf.llen(b2 + 1) == 0) == e2:
                b2 += 1
            b = b2
        else:
            while a > 0 and buf.llen(a - 1) == 0:
                a -= 1
    return VimSpan(True, a, 0, b, 0, True)


def vim_object(buf: TextBuffer, r: Int, c: Int, inner: Bool, ch: Int) -> VimSpan:
    """The text object `i`/`a` + `ch` at (r, c)."""
    var line = buf.line(r)
    if ch == 119 or ch == 87:                       # w W
        return obj_word(line, r, c, inner, ch == 87)
    if ch == 34 or ch == 39 or ch == 96:            # " ' `
        return obj_quote(line, r, c, inner, ch)
    if ch == 40 or ch == 41 or ch == 98:            # ( ) b
        return obj_bracket(buf, r, c, inner, 0)
    if ch == 91 or ch == 93:                        # [ ]
        return obj_bracket(buf, r, c, inner, 1)
    if ch == 123 or ch == 125 or ch == 66:          # { } B
        return obj_bracket(buf, r, c, inner, 2)
    if ch == 60 or ch == 62:                        # < >
        return obj_bracket(buf, r, c, inner, 3)
    if ch == 112:                                   # p
        return obj_para(buf, r, inner)
    return no_span()
