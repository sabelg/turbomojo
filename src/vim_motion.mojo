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


def is_code_mask(line: List[Int]) -> List[Bool]:
    var n = len(line)
    var is_code = List[Bool]()
    for _ in range(n):
        is_code.append(True)
    var in_str = 0  # 34 for ", 39 for '
    var i = 0
    while i < n:
        var ch = line[i]
        if in_str != 0:
            is_code[i] = False
            if ch == 92 and i + 1 < n:  # escape \
                i += 1
                is_code[i] = False
            elif ch == in_str:
                in_str = 0
        elif ch == 35:  # # comment
            for j in range(i, n):
                is_code[j] = False
            break
        elif ch == 34 or ch == 39:  # " or '
            in_str = ch
            is_code[i] = False
        i += 1
    return is_code^


def match_fwd(buf: TextBuffer, r0: Int, c0: Int, op: Int, cl: Int) -> Pos:
    """The `cl` that closes the `op` at (r0, c0); Pos(-1, -1) if none."""
    var depth = 0
    var r = r0
    var c = c0
    var line = buf.line(r)
    var mask = is_code_mask(line)
    while True:
        while c < len(line):
            if c < len(mask) and mask[c]:
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
        mask = is_code_mask(line)
        c = 0


def match_back(buf: TextBuffer, r0: Int, c0: Int, op: Int, cl: Int) -> Pos:
    """The `op` that opens the `cl` at (r0, c0) - or, with (r0, c0) not on a `cl`,
    the `op` that encloses it (pairs closed before it are skipped); Pos(-1, -1) if
    none."""
    var depth = 0
    var r = r0
    var line = buf.line(r)
    var mask = is_code_mask(line)
    var c = min(c0, len(line) - 1)
    if c == c0 and c >= 0 and line[c] == cl:
        c -= 1
    while True:
        while c >= 0:
            if c < len(mask) and mask[c]:
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
        mask = is_code_mask(line)
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


struct ScopeRange(Copyable, Movable):
    var r1: Int
    var r2: Int
    var indent: Int

    def __init__(out self, r1: Int, r2: Int, indent: Int):
        self.r1 = r1
        self.r2 = r2
        self.indent = indent


def active_scope_range(buf: TextBuffer, r: Int) -> ScopeRange:
    """Finds the innermost scope block (def, struct, if, etc.) enclosing line r."""
    if r < 0 or r >= buf.count():
        return ScopeRange(-1, -1, 0)
    var target_indent = indent_end(buf.line(r))
    var hdr = -1
    var hdr_indent = -1
    for up in range(r, -1, -1):
        var ln = buf.line(up)
        if len(ln) == 0:
            continue
        var ind = indent_end(ln)
        if ind < target_indent or (up < r and ind <= target_indent and len(ln) > ind):
            var has_colon = False
            for j in range(len(ln) - 1, -1, -1):
                if ln[j] == 35:
                    continue
                if ln[j] == 32 or ln[j] == 9:
                    continue
                if ln[j] == 58:
                    has_colon = True
                break
            if has_colon:
                hdr = up
                hdr_indent = ind
                break
    if hdr < 0:
        return ScopeRange(-1, -1, 0)
    var end_r = hdr
    for down in range(hdr + 1, buf.count()):
        var ln = buf.line(down)
        if len(ln) == 0:
            continue
        var ind = indent_end(ln)
        if ind <= hdr_indent:
            break
        end_r = down
    return ScopeRange(hdr, end_r, hdr_indent)


def _pos_lt(a: Pos, b: Pos) -> Bool:
    return a.r < b.r or (a.r == b.r and a.c < b.c)


def _pos_le(a: Pos, b: Pos) -> Bool:
    return a.r < b.r or (a.r == b.r and a.c <= b.c)


def _skip_arg_ws_fwd(buf: TextBuffer, p0: Pos, lim: Pos) -> Pos:
    var p = p0.copy()
    while _pos_lt(p, lim):
        var ln = buf.line(p.r)
        if p.c >= len(ln):
            p = Pos(p.r + 1, 0)
        elif ln[p.c] == 32 or ln[p.c] == 9:
            p = Pos(p.r, p.c + 1)
        elif ln[p.c] == 35:
            var end_c = lim.c if p.r == lim.r else len(ln)
            p = Pos(p.r, end_c)
        else:
            break
    return p^


def _skip_arg_ws_back(buf: TextBuffer, p0: Pos, lim: Pos) -> Pos:
    var p = p0.copy()
    while _pos_lt(lim, p):
        if p.c == 0:
            var pr = p.r - 1
            p = Pos(pr, buf.llen(pr))
        else:
            var ch = buf.at(p.r, p.c - 1)
            if ch == 32 or ch == 9:
                p = Pos(p.r, p.c - 1)
            else:
                break
    return p^


def obj_arg(buf: TextBuffer, r: Int, c: Int, inner: Bool) -> VimSpan:
    """ia aa: argument/parameter text object (single-line and multi-line `(` .. `)`)."""
    if r < 0 or r >= buf.count():
        return no_span()
    var line = buf.line(r)
    var mask0 = is_code_mask(line)
    var op_pos: Pos
    if c >= 0 and c < len(line) and c < len(mask0) and mask0[c] and line[c] == 40:
        op_pos = Pos(r, c)
    else:
        op_pos = match_back(buf, r, c, 40, 41)
    if op_pos.r < 0:
        return no_span()
    var cl_pos = match_fwd(buf, op_pos.r, op_pos.c, 40, 41)
    if cl_pos.r < 0:
        return no_span()

    if op_pos.r == cl_pos.r:
        var op = op_pos.c
        var cl = cl_pos.c
        var ln_s = buf.line(op_pos.r)
        var ms_s = is_code_mask(ln_s)
        var commas = List[Int]()
        commas.append(op)
        var depth = 0
        for i in range(op + 1, cl):
            if i < len(ms_s) and ms_s[i]:
                var ch = ln_s[i]
                if ch == 40 or ch == 91 or ch == 123:
                    depth += 1
                elif ch == 41 or ch == 93 or ch == 125:
                    depth = max(0, depth - 1)
                elif ch == 44 and depth == 0:
                    commas.append(i)
        commas.append(cl)

        var seg_idx = 0
        while seg_idx + 1 < len(commas):
            if c >= commas[seg_idx] and c <= commas[seg_idx + 1]:
                break
            seg_idx += 1
        if seg_idx + 1 >= len(commas):
            return no_span()

        var s = commas[seg_idx] + 1
        var e = commas[seg_idx + 1]

        if inner:
            while s < e and (ln_s[s] == 32 or ln_s[s] == 9):
                s += 1
            while e > s and (ln_s[e - 1] == 32 or ln_s[e - 1] == 9):
                e -= 1
            if s >= e:
                return no_span()
            return VimSpan(True, r, s, r, e, False)
        else:
            if commas[seg_idx + 1] < cl:
                e = commas[seg_idx + 1] + 1
                while e < cl and (ln_s[e] == 32 or ln_s[e] == 9):
                    e += 1
                while s < e and (ln_s[s] == 32 or ln_s[s] == 9):
                    s += 1
            elif commas[seg_idx] > op:
                s = commas[seg_idx]
                while e > s and (ln_s[e - 1] == 32 or ln_s[e - 1] == 9):
                    e -= 1
            else:
                while s < e and (ln_s[s] == 32 or ln_s[s] == 9):
                    s += 1
                while e > s and (ln_s[e - 1] == 32 or ln_s[e - 1] == 9):
                    e -= 1
            if s >= e:
                return no_span()
            return VimSpan(True, r, s, r, e, False)

    # Multi-line `(` .. `)` parameter / argument list
    var delims = List[Pos]()
    delims.append(op_pos.copy())
    var mdepth = 0
    for rr in range(op_pos.r, cl_pos.r + 1):
        var rln = buf.line(rr)
        var rmask = is_code_mask(rln)
        var c0 = op_pos.c + 1 if rr == op_pos.r else 0
        var c1 = cl_pos.c if rr == cl_pos.r else len(rln)
        for cc in range(c0, c1):
            if cc < len(rmask) and rmask[cc]:
                var ch = rln[cc]
                if ch == 40 or ch == 91 or ch == 123:
                    mdepth += 1
                elif ch == 41 or ch == 93 or ch == 125:
                    mdepth = max(0, mdepth - 1)
                elif ch == 44 and mdepth == 0:
                    delims.append(Pos(rr, cc))
    delims.append(cl_pos.copy())

    var has_trailing_comma = False
    if len(delims) >= 3:
        var after_last_comma = _skip_arg_ws_fwd(buf, Pos(delims[len(delims) - 2].r, delims[len(delims) - 2].c + 1), cl_pos)
        if after_last_comma.r == cl_pos.r and after_last_comma.c == cl_pos.c:
            has_trailing_comma = True

    var cur_p = Pos(r, min(max(0, c), len(line)))
    var mseg = 0
    while mseg + 1 < len(delims):
        if _pos_le(delims[mseg], cur_p) and _pos_le(cur_p, delims[mseg + 1]):
            break
        mseg += 1
    if mseg + 1 >= len(delims):
        return no_span()
    if has_trailing_comma and mseg == len(delims) - 2:
        mseg -= 1

    var d0 = delims[mseg].copy()
    var d1 = delims[mseg + 1].copy()
    var raw_s = Pos(d0.r, d0.c + 1)
    var s_trim = _skip_arg_ws_fwd(buf, raw_s, d1)
    var e_trim = _skip_arg_ws_back(buf, d1, s_trim)
    if not _pos_lt(s_trim, e_trim):
        return no_span()

    if inner:
        return VimSpan(True, s_trim.r, s_trim.c, e_trim.r, e_trim.c, False)

    # Outer (`aa`): include comma and surrounding whitespace cleanly across rows
    if _pos_lt(d1, cl_pos):
        var after_comma = Pos(d1.r, d1.c + 1)
        var next_tok = _skip_arg_ws_fwd(buf, after_comma, cl_pos)
        if _pos_lt(next_tok, cl_pos):
            return VimSpan(True, s_trim.r, s_trim.c, next_tok.r, next_tok.c, False)
        # Trailing comma before closing ')': include the comma + same-line blanks
        var ln_d1 = buf.line(d1.r)
        var ec = after_comma.c
        var lim_c = cl_pos.c if d1.r == cl_pos.r else len(ln_d1)
        while ec < lim_c and (ln_d1[ec] == 32 or ln_d1[ec] == 9):
            ec += 1
        if mseg > 0:
            return VimSpan(True, d0.r, d0.c, d1.r, ec, False)
        return VimSpan(True, s_trim.r, s_trim.c, d1.r, ec, False)
    elif mseg > 0:
        return VimSpan(True, d0.r, d0.c, e_trim.r, e_trim.c, False)
    return VimSpan(True, s_trim.r, s_trim.c, e_trim.r, e_trim.c, False)


def obj_func(buf: TextBuffer, r: Int, c: Int, inner: Bool) -> VimSpan:
    """if af: enclosing function object."""
    var def_r = -1
    var def_ind = -1
    for up in range(r, -1, -1):
        var ln = buf.line(up)
        var s = 0
        while s < len(ln) and (ln[s] == 32 or ln[s] == 9):
            s += 1
        if s + 4 <= len(ln):
            if (ln[s] == 100 and ln[s+1] == 101 and ln[s+2] == 102 and ln[s+3] == 32) or (ln[s] == 102 and ln[s+1] == 110 and ln[s+2] == 32):
                def_r = up
                def_ind = s
                break
    if def_r < 0:
        return no_span()
    var end_r = def_r
    for down in range(def_r + 1, buf.count()):
        var ln = buf.line(down)
        if len(ln) == 0:
            continue
        var ind = indent_end(ln)
        if ind <= def_ind:
            break
        end_r = down
    if inner:
        if def_r + 1 > end_r:
            return no_span()
        return VimSpan(True, def_r + 1, 0, end_r, 0, True)
    else:
        return VimSpan(True, def_r, 0, end_r, 0, True)


def obj_indent(buf: TextBuffer, r: Int, inner: Bool) -> VimSpan:
    """ii ai: indentation block text object."""
    if r < 0 or r >= buf.count():
        return no_span()
    var target_indent = indent_end(buf.line(r))
    var a = r
    while a > 0 and (buf.llen(a - 1) == 0 or indent_end(buf.line(a - 1)) >= target_indent):
        a -= 1
    var b = r
    var last = buf.count() - 1
    while b < last and (buf.llen(b + 1) == 0 or indent_end(buf.line(b + 1)) >= target_indent):
        b += 1
    if not inner and a > 0:
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
    if ch == 97:                                    # a (argument)
        return obj_arg(buf, r, c, inner)
    if ch == 102:                                   # f (function)
        return obj_func(buf, r, c, inner)
    if ch == 105:                                   # i (indentation)
        return obj_indent(buf, r, inner)
    return no_span()
