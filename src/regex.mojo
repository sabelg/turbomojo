"""Regular expressions: a parser, a compiler to a small instruction set, and a Pike VM
(Thompson NFA simulation that also tracks capture groups).

Matching time is proportional to pattern size times text length; there is no
backtracking, so no pattern can make the editor hang. The result is the same match a
backtracking engine (Perl, Python) would report: leftmost, then by the usual preference
rules (greedy quantifiers take more, lazy ones less, earlier alternatives win).

Supported syntax:
    literals, escapes \\t \\n \\r \\f \\v \\0 \\xHH \\uHHHH \\U00HHHHHH and \\<punctuation>
    .            any character except a newline
    [abc] [a-z] [^...]    classes, with \\d \\w \\s \\D \\W \\S and escapes inside
    \\d \\w \\s \\D \\W \\S    digit, word character, whitespace, and their opposites
    ( ) (?: ) (?<name> ) (?P<name> )    groups (named groups are numbered like the others)
    |            alternation
    * + ? {n} {n,} {n,m}  and the lazy forms *? +? ?? {n,m}?
    ^ $          start / end of the text (the editor matches one line at a time)
    \\b \\B        word boundary / not a word boundary
    (?i)         at the very start: ignore case

Not supported (reported as errors): backreferences (\\1), lookahead and lookbehind,
possessive quantifiers, Unicode properties (\\p{..}).

Known difference from backtracking engines: a group that can match the empty string
inside a repetition, as in "(a*)*", may be reported as not having taken part."""
from std.collections import List
from util import is_ident, to_str

# instructions
comptime I_CHAR = 0      # a = codepoint
comptime I_ANY = 1
comptime I_CLASS = 2     # a = class index
comptime I_SPLIT = 3     # a = preferred target, b = other target
comptime I_JMP = 4       # a = target
comptime I_SAVE = 5      # a = capture slot
comptime I_BOL = 6
comptime I_EOL = 7
comptime I_WORDB = 8
comptime I_NWORDB = 9
comptime I_MATCH = 10

# syntax tree nodes
comptime N_EMPTY = 0
comptime N_CHAR = 1
comptime N_ANY = 2
comptime N_CLASS = 3
comptime N_CAT = 4
comptime N_ALT = 5
comptime N_REPEAT = 6    # a = child, lo/hi = counts (hi -1 = unlimited), greedy
comptime N_GROUP = 7     # a = child, val = group number (0 = not capturing)
comptime N_BOL = 8
comptime N_EOL = 9
comptime N_WORDB = 10
comptime N_NWORDB = 11

comptime MAX_REPEAT = 1000
comptime MAX_PROGRAM = 50000
comptime MAX_CP = 0x10FFFF


def fold(c: Int) -> Int:
    """Simple case folding: ASCII, Latin-1, Greek and Cyrillic capitals to lower case."""
    if c < 65:
        return c
    if c <= 90:
        return c + 32
    if c < 0xC0:
        return c
    if c <= 0xDE:
        return c + 32 if c != 0xD7 else c
    if c >= 0x391 and c <= 0x3A9 and c != 0x3A2:
        return c + 32
    if c >= 0x410 and c <= 0x42F:
        return c + 32
    if c >= 0x400 and c <= 0x40F:
        return c + 80
    return c


def unfold(c: Int) -> Int:
    """The capital for a lower-case letter that fold() produces (c itself otherwise)."""
    if c >= 97 and c <= 122:
        return c - 32
    if c >= 0xE0 and c <= 0xFE and c != 0xF7:
        return c - 32
    if c >= 0x3B1 and c <= 0x3C9 and c != 0x3C2:
        return c - 32
    if c >= 0x430 and c <= 0x44F:
        return c - 32
    if c >= 0x450 and c <= 0x45F:
        return c - 80
    return c


def is_space(c: Int) -> Bool:
    return c == 32 or (c >= 9 and c <= 13)


def normalize(r: List[Int]) -> List[Int]:
    """Sort a flat list of [lo, hi] pairs and merge the ones that touch or overlap."""
    var n = len(r) // 2
    var lo = List[Int]()
    var hi = List[Int]()
    for i in range(n):
        # insertion sort by lower bound
        var k = len(lo)
        lo.append(r[2 * i])
        hi.append(r[2 * i + 1])
        while k > 0 and lo[k - 1] > lo[k]:
            var t = lo[k - 1]
            lo[k - 1] = lo[k]
            lo[k] = t
            t = hi[k - 1]
            hi[k - 1] = hi[k]
            hi[k] = t
            k -= 1
    var out = List[Int]()
    for i in range(n):
        var m = len(out)
        if m > 0 and lo[i] <= out[m - 1] + 1:
            if hi[i] > out[m - 1]:
                out[m - 1] = hi[i]
        else:
            out.append(lo[i])
            out.append(hi[i])
    return out^


def complement(r: List[Int]) -> List[Int]:
    """Everything not in the (normalized) ranges."""
    var out = List[Int]()
    var next = 0
    var i = 0
    while i + 1 < len(r):
        if r[i] > next:
            out.append(next)
            out.append(r[i] - 1)
        next = r[i + 1] + 1
        i += 2
    if next <= MAX_CP:
        out.append(next)
        out.append(MAX_CP)
    return out^


def shorthand(c: Int) -> List[Int]:
    """Ranges for \\d \\w \\s (lower case letter) or their complements (upper case)."""
    var r = List[Int]()
    var k = c | 32
    if k == 100:        # d
        r = [48, 57]
    elif k == 119:      # w: the same idea of a word character as the rest of the editor
        r = [48, 57, 65, 90, 95, 95, 97, 122, 0xC0, MAX_CP]
    else:               # s
        r = [9, 13, 32, 32]
    if c < 97:
        return complement(r)
    return r^


def in_ranges_bs(c: Int, r: List[Int]) -> Bool:
    """Binary search in a normalized range list."""
    var lo = 0
    var hi = len(r) // 2 - 1
    while lo <= hi:
        var mid = (lo + hi) // 2
        if c < r[2 * mid]:
            hi = mid - 1
        elif c > r[2 * mid + 1]:
            lo = mid + 1
        else:
            return True
    return False


def cp_str(c: Int) -> String:
    var one: List[Int] = [c]
    return to_str(one)


def hex_val(c: Int) -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    var k = c | 32
    if k >= 97 and k <= 102:
        return k - 87
    return -1


struct Regex(Copyable, Movable):
    var ok: Bool
    var error: String          # why the pattern was rejected
    var error_at: Int          # index in the pattern where the problem is
    var groups: Int            # number of capture groups (not counting the whole match)
    var ignore_case: Bool
    var op: List[Int]
    var a: List[Int]
    var b: List[Int]
    var classes: List[List[Int]]
    var first: Int             # codepoint every match must start with (-1 if not known)
    var anchored: Bool         # pattern can only match at the start of the text
    # parser state
    var pat: List[Int]
    var pos: Int
    var nk: List[Int]
    var na: List[Int]
    var nb: List[Int]
    var nval: List[Int]
    var nlo: List[Int]
    var nhi: List[Int]
    var ngreedy: List[Bool]

    def __init__(out self):
        self.ok = False
        self.error = ""
        self.error_at = 0
        self.groups = 0
        self.ignore_case = False
        self.op = List[Int]()
        self.a = List[Int]()
        self.b = List[Int]()
        self.classes = List[List[Int]]()
        self.first = -1
        self.anchored = False
        self.pat = List[Int]()
        self.pos = 0
        self.nk = List[Int]()
        self.na = List[Int]()
        self.nb = List[Int]()
        self.nval = List[Int]()
        self.nlo = List[Int]()
        self.nhi = List[Int]()
        self.ngreedy = List[Bool]()

    # ------------------------------------------------------------------ parser
    def fail(mut self, msg: String, at: Int):
        if self.error.byte_length() == 0:
            self.error = msg
            self.error_at = at

    def failed(self) -> Bool:
        return self.error.byte_length() > 0

    def node(mut self, kind: Int, a: Int, b: Int, val: Int) -> Int:
        self.nk.append(kind)
        self.na.append(a)
        self.nb.append(b)
        self.nval.append(val)
        self.nlo.append(0)
        self.nhi.append(0)
        self.ngreedy.append(True)
        return len(self.nk) - 1

    def peek(self) -> Int:
        return self.pat[self.pos] if self.pos < len(self.pat) else -1

    def parse_alt(mut self, depth: Int) -> Int:
        var left = self.parse_cat(depth)
        while self.peek() == 124 and not self.failed():
            self.pos += 1
            var right = self.parse_cat(depth)
            left = self.node(N_ALT, left, right, 0)
        return left

    def parse_cat(mut self, depth: Int) -> Int:
        var left = -1
        while self.pos < len(self.pat) and not self.failed():
            var c = self.peek()
            if c == 124 or c == 41:
                break
            var item = self.parse_repeat(depth)
            left = item if left < 0 else self.node(N_CAT, left, item, 0)
        if left < 0:
            return self.node(N_EMPTY, 0, 0, 0)
        return left

    def parse_count(mut self) -> Int:
        """Digits at the cursor as a number, -1 if there are none."""
        var start = self.pos
        var v = 0
        while self.pos < len(self.pat) and self.pat[self.pos] >= 48 and self.pat[self.pos] <= 57:
            v = v * 10 + self.pat[self.pos] - 48
            if v > MAX_REPEAT:
                v = MAX_REPEAT + 1
            self.pos += 1
        return v if self.pos > start else -1

    def parse_repeat(mut self, depth: Int) -> Int:
        var atom = self.parse_atom(depth)
        while not self.failed():
            var c = self.peek()
            var lo = 0
            var hi = -1
            var qpos = self.pos
            if c == 42:
                self.pos += 1
            elif c == 43:
                lo = 1
                self.pos += 1
            elif c == 63:
                hi = 1
                self.pos += 1
            elif c == 123:
                # {n} {n,} {n,m}; anything else is an ordinary "{"
                var save = self.pos
                self.pos += 1
                lo = self.parse_count()
                var good = lo >= 0
                if good:
                    hi = lo
                    if self.peek() == 44:
                        self.pos += 1
                        hi = self.parse_count()      # -1: no upper limit
                    good = self.peek() == 125
                if not good:
                    self.pos = save
                    break
                self.pos += 1
                if lo > MAX_REPEAT or hi > MAX_REPEAT:
                    self.fail("repeat count is too large (limit " + String(MAX_REPEAT) + ")", qpos)
                    break
                if hi >= 0 and hi < lo:
                    self.fail("repeat range is backwards", qpos)
                    break
            else:
                break
            var k = self.nk[atom]
            if k == N_BOL or k == N_EOL or k == N_WORDB or k == N_NWORDB:
                self.fail("nothing to repeat", qpos)
                break
            var greedy = True
            if self.peek() == 63:
                greedy = False
                self.pos += 1
            elif self.peek() == 43:
                self.fail("possessive quantifiers are not supported", self.pos)
                break
            atom = self.node(N_REPEAT, atom, 0, 0)
            self.nlo[atom] = lo
            self.nhi[atom] = hi
            self.ngreedy[atom] = greedy
        return atom

    def parse_escape_value(mut self, c: Int, at: Int) -> Int:
        """The codepoint for a character escape whose letter `c` was just consumed
        (-1 if c is not a character escape)."""
        if c == 116:
            return 9
        if c == 110:
            return 10
        if c == 114:
            return 13
        if c == 102:
            return 12
        if c == 118:
            return 11
        if c == 48:
            return 0
        if c == 97:
            return 7
        if c == 101:
            return 27
        if c == 120 or c == 117 or c == 85:
            var want = 2 if c == 120 else (4 if c == 117 else 8)
            var v = 0
            for _ in range(want):
                var h = hex_val(self.peek())
                if h < 0:
                    self.fail("\\" + cp_str(c) + " needs " + String(want) + " hex digits", at)
                    return 0
                v = v * 16 + h
                self.pos += 1
            if v > MAX_CP:
                self.fail("character code is beyond Unicode", at)
                return 0
            return v
        return -1

    def add_class(mut self, ranges: List[Int], negate: Bool) -> Int:
        var r = normalize(ranges)
        if self.ignore_case:
            # add the other case of every letter in the set
            var extra = r.copy()
            var i = 0
            while i + 1 < len(r):
                var lo = r[i]
                var hi = min(r[i + 1], 0x45F)      # no case pairs are known above this
                for c in range(lo, hi + 1):
                    var f = fold(c)
                    if f != c:
                        extra.append(f)
                        extra.append(f)
                    var u = unfold(c)
                    if u != c:
                        extra.append(u)
                        extra.append(u)
                i += 2
            r = normalize(extra)
        if negate:
            r = complement(r)
        self.classes.append(r^)
        return len(self.classes) - 1

    def parse_class(mut self) -> Int:
        """After "[": the set up to the closing "]"."""
        var open_at = self.pos - 1
        var negate = False
        if self.peek() == 94:
            negate = True
            self.pos += 1
        var ranges = List[Int]()
        var first = True
        while True:
            if self.pos >= len(self.pat):
                self.fail("missing ] to close the set", open_at)
                return self.node(N_EMPTY, 0, 0, 0)
            var c = self.pat[self.pos]
            if c == 93 and not first:
                self.pos += 1
                break
            first = False
            var lo = c
            var at = self.pos
            self.pos += 1
            var is_set = False
            if c == 92:
                if self.pos >= len(self.pat):
                    self.fail("pattern ends with a backslash", at)
                    return self.node(N_EMPTY, 0, 0, 0)
                var e = self.pat[self.pos]
                self.pos += 1
                if e == 100 or e == 119 or e == 115 or e == 68 or e == 87 or e == 83:
                    for v in shorthand(e):
                        ranges.append(v)
                    is_set = True
                elif e == 98:
                    lo = 8                      # inside a set \b is a backspace
                else:
                    var v = self.parse_escape_value(e, at)
                    if self.failed():
                        return self.node(N_EMPTY, 0, 0, 0)
                    lo = v if v >= 0 else e
            if is_set:
                continue
            var hi = lo
            # a range like a-z ("-" just before "]" is a plain dash)
            if self.pos + 1 < len(self.pat) and self.pat[self.pos] == 45 and self.pat[self.pos + 1] != 93:
                self.pos += 1
                var h = self.pat[self.pos]
                var hat = self.pos
                self.pos += 1
                if h == 92:
                    if self.pos >= len(self.pat):
                        self.fail("pattern ends with a backslash", hat)
                        return self.node(N_EMPTY, 0, 0, 0)
                    var e = self.pat[self.pos]
                    self.pos += 1
                    if e == 100 or e == 119 or e == 115 or e == 68 or e == 87 or e == 83:
                        self.fail("a set like \\" + cp_str(e) + " cannot end a range", hat)
                        return self.node(N_EMPTY, 0, 0, 0)
                    var v = self.parse_escape_value(e, hat)
                    if self.failed():
                        return self.node(N_EMPTY, 0, 0, 0)
                    h = v if v >= 0 else e
                hi = h
                if hi < lo:
                    self.fail("range is backwards", at)
                    return self.node(N_EMPTY, 0, 0, 0)
            ranges.append(lo)
            ranges.append(hi)
        return self.node(N_CLASS, 0, 0, self.add_class(ranges, negate))

    def parse_atom(mut self, depth: Int) -> Int:
        var at = self.pos
        var c = self.pat[self.pos]
        self.pos += 1
        if c == 40:
            if depth > 200:
                self.fail("groups are nested too deeply", at)
                return self.node(N_EMPTY, 0, 0, 0)
            var number = 0
            if self.peek() == 63:
                self.pos += 1
                var k = self.peek()
                if k == 58:
                    self.pos += 1
                elif k == 80 or k == 60:
                    # (?P<name>...) or (?<name>...); (?<= and (?<! are lookbehind
                    if k == 80:
                        self.pos += 1
                        if self.peek() != 60:
                            self.fail("unknown group syntax", at)
                            return self.node(N_EMPTY, 0, 0, 0)
                    self.pos += 1
                    if self.peek() == 61 or self.peek() == 33:
                        self.fail("lookbehind is not supported", at)
                        return self.node(N_EMPTY, 0, 0, 0)
                    var name_len = 0
                    while self.pos < len(self.pat) and self.pat[self.pos] != 62:
                        if not is_ident(self.pat[self.pos]):
                            self.fail("bad character in group name", self.pos)
                            return self.node(N_EMPTY, 0, 0, 0)
                        self.pos += 1
                        name_len += 1
                    if self.pos >= len(self.pat) or name_len == 0:
                        self.fail("group name is not finished", at)
                        return self.node(N_EMPTY, 0, 0, 0)
                    self.pos += 1
                    self.groups += 1
                    number = self.groups
                elif k == 61 or k == 33:
                    self.fail("lookahead is not supported", at)
                    return self.node(N_EMPTY, 0, 0, 0)
                elif k == 105:
                    self.fail("(?i) is only allowed at the start of the pattern", at)
                    return self.node(N_EMPTY, 0, 0, 0)
                else:
                    self.fail("unknown group syntax", at)
                    return self.node(N_EMPTY, 0, 0, 0)
            else:
                self.groups += 1
                number = self.groups
            var inner = self.parse_alt(depth + 1)
            if self.failed():
                return inner
            if self.peek() != 41:
                self.fail("missing ) to close the group", at)
                return inner
            self.pos += 1
            return self.node(N_GROUP, inner, 0, number)
        if c == 41:
            self.fail("unmatched )", at)
            return self.node(N_EMPTY, 0, 0, 0)
        if c == 91:
            return self.parse_class()
        if c == 46:
            return self.node(N_ANY, 0, 0, 0)
        if c == 94:
            return self.node(N_BOL, 0, 0, 0)
        if c == 36:
            return self.node(N_EOL, 0, 0, 0)
        if c == 42 or c == 43 or c == 63:
            self.fail("nothing to repeat", at)
            return self.node(N_EMPTY, 0, 0, 0)
        if c == 92:
            if self.pos >= len(self.pat):
                self.fail("pattern ends with a backslash", at)
                return self.node(N_EMPTY, 0, 0, 0)
            var e = self.pat[self.pos]
            self.pos += 1
            if e == 100 or e == 119 or e == 115 or e == 68 or e == 87 or e == 83:
                return self.node(N_CLASS, 0, 0, self.add_class(shorthand(e), False))
            if e == 98:
                return self.node(N_WORDB, 0, 0, 0)
            if e == 66:
                return self.node(N_NWORDB, 0, 0, 0)
            if e >= 49 and e <= 57:
                self.fail("backreferences are not supported", at)
                return self.node(N_EMPTY, 0, 0, 0)
            if e == 112 or e == 80:
                self.fail("Unicode properties (\\p) are not supported", at)
                return self.node(N_EMPTY, 0, 0, 0)
            var v = self.parse_escape_value(e, at)
            if self.failed():
                return self.node(N_EMPTY, 0, 0, 0)
            if v < 0:
                if (e >= 65 and e <= 90) or (e >= 97 and e <= 122):
                    self.fail("unknown escape \\" + cp_str(e), at)
                    return self.node(N_EMPTY, 0, 0, 0)
                v = e
            return self.node(N_CHAR, 0, 0, v)
        return self.node(N_CHAR, 0, 0, c)

    # ---------------------------------------------------------------- compiler
    def emit(mut self, op: Int, a: Int, b: Int) -> Int:
        self.op.append(op)
        self.a.append(a)
        self.b.append(b)
        return len(self.op) - 1

    def gen(mut self, n: Int):
        if len(self.op) > MAX_PROGRAM:
            self.fail("pattern is too large", 0)
            return
        var k = self.nk[n]
        if k == N_EMPTY:
            return
        if k == N_CHAR:
            var c = self.nval[n]
            _ = self.emit(I_CHAR, fold(c) if self.ignore_case else c, 0)
        elif k == N_ANY:
            _ = self.emit(I_ANY, 0, 0)
        elif k == N_CLASS:
            _ = self.emit(I_CLASS, self.nval[n], 0)
        elif k == N_BOL:
            _ = self.emit(I_BOL, 0, 0)
        elif k == N_EOL:
            _ = self.emit(I_EOL, 0, 0)
        elif k == N_WORDB:
            _ = self.emit(I_WORDB, 0, 0)
        elif k == N_NWORDB:
            _ = self.emit(I_NWORDB, 0, 0)
        elif k == N_CAT:
            self.gen(self.na[n])
            self.gen(self.nb[n])
        elif k == N_ALT:
            var split = self.emit(I_SPLIT, 0, 0)
            self.a[split] = len(self.op)
            self.gen(self.na[n])
            var jmp = self.emit(I_JMP, 0, 0)
            self.b[split] = len(self.op)
            self.gen(self.nb[n])
            self.a[jmp] = len(self.op)
        elif k == N_GROUP:
            var g = self.nval[n]
            if g > 0:
                _ = self.emit(I_SAVE, 2 * g, 0)
            self.gen(self.na[n])
            if g > 0:
                _ = self.emit(I_SAVE, 2 * g + 1, 0)
        elif k == N_REPEAT:
            var child = self.na[n]
            var lo = self.nlo[n]
            var hi = self.nhi[n]
            var greedy = self.ngreedy[n]
            for _ in range(lo):
                self.gen(child)
                if self.failed():
                    return
            if hi < 0:
                # zero or more: L1: split L2, L3; L2: child; jmp L1; L3:
                var split = self.emit(I_SPLIT, 0, 0)
                self.gen(child)
                _ = self.emit(I_JMP, split, 0)
                self.set_split(split, split + 1, len(self.op), greedy)
            else:
                # up to (hi - lo) more, each one optional; all of them can leave to the end
                var splits = List[Int]()
                for _ in range(hi - lo):
                    splits.append(self.emit(I_SPLIT, 0, 0))
                    self.gen(child)
                    if self.failed():
                        return
                for s in splits:
                    self.set_split(s, s + 1, len(self.op), greedy)

    def set_split(mut self, at: Int, into: Int, past: Int, greedy: Bool):
        self.a[at] = into if greedy else past
        self.b[at] = past if greedy else into

    def find_first(mut self):
        """Work out cheap facts used to skip positions where no match can start."""
        # follow the program from the start through instructions that consume nothing
        var pc = 0
        self.anchored = False
        self.first = -1
        while pc < len(self.op):
            var o = self.op[pc]
            if o == I_SAVE:
                pc += 1
            elif o == I_BOL:
                self.anchored = True
                pc += 1
            elif o == I_CHAR:
                if not self.ignore_case:
                    self.first = self.a[pc]
                return
            else:
                return

    # ----------------------------------------------------------------- matcher
    def step_ok(self, pc: Int, c: Int) -> Bool:
        """Does the consuming instruction at pc accept character c?"""
        var o = self.op[pc]
        if o == I_CHAR:
            return (fold(c) if self.ignore_case else c) == self.a[pc]
        if o == I_ANY:
            return c != 10
        return in_ranges_bs(c, self.classes[self.a[pc]])

    def add_thread(
        self, pc0: Int, caps: List[Int], text: List[Int], at: Int, gen: Int,
        mut mark: List[Int], mut pcs: List[Int], mut slots: List[Int],
    ):
        """Add the thread at pc0 to a list, following every instruction that consumes no
        input. Threads are added in priority order; a pc already on the list is skipped."""
        var pc = pc0
        var cp = caps.copy()
        while True:
            if mark[pc] == gen:
                return
            mark[pc] = gen
            var o = self.op[pc]
            if o == I_JMP:
                pc = self.a[pc]
            elif o == I_SPLIT:
                self.add_thread(self.a[pc], cp, text, at, gen, mark, pcs, slots)
                pc = self.b[pc]
            elif o == I_SAVE:
                cp[self.a[pc]] = at
                pc += 1
            elif o == I_BOL:
                if at != 0:
                    return
                pc += 1
            elif o == I_EOL:
                if at != len(text):
                    return
                pc += 1
            elif o == I_WORDB or o == I_NWORDB:
                var before = at > 0 and is_ident(text[at - 1])
                var after = at < len(text) and is_ident(text[at])
                if (before != after) != (o == I_WORDB):
                    return
                pc += 1
            else:
                pcs.append(pc)
                for v in cp:
                    slots.append(v)
                return

    def run(self, text: List[Int], start: Int, anchored: Bool) -> List[Int]:
        """The Pike VM. Returns capture positions [s0, e0, s1, e1, ...] (-1 for groups that
        did not take part), or an empty list when there is no match."""
        var result = List[Int]()
        if not self.ok:
            return result^
        var n = len(text)
        var width = 2 * (self.groups + 1)
        var plen = len(self.op)
        var mark = List[Int](length=plen, fill=-1)
        var pcs = List[Int]()
        var slots = List[Int]()
        var npcs = List[Int]()
        var nslots = List[Int]()
        var blank = List[Int](length=width, fill=-1)
        var matched = False
        var at = start
        var gen = 0
        while True:
            if not matched and (at == start or not (anchored or self.anchored)):
                # a new attempt starting here, behind every thread that started earlier
                var go = True
                if self.first >= 0 and len(pcs) == 0:
                    # nothing in flight: jump ahead to the next possible first character
                    while at < n and text[at] != self.first:
                        if anchored or self.anchored:
                            break
                        at += 1
                    go = at < n and text[at] == self.first
                if go:
                    var caps = blank.copy()
                    caps[0] = at
                    self.add_thread(0, caps, text, at, gen, mark, pcs, slots)
            if len(pcs) == 0:
                if matched or anchored or self.anchored or at >= n:
                    break
                at += 1
                gen += 1            # the marks belong to one text position
                continue
            var c = text[at] if at < n else -1
            gen += 1
            npcs.clear()
            nslots.clear()
            for t in range(len(pcs)):
                var pc = pcs[t]
                if self.op[pc] == I_MATCH:
                    # the best thread so far has finished: remember it and drop the
                    # threads behind it (they have lower priority)
                    result.clear()
                    for k in range(width):
                        result.append(slots[t * width + k])
                    result[1] = at
                    matched = True
                    break
                if c >= 0 and self.step_ok(pc, c):
                    var caps = List[Int]()
                    for k in range(width):
                        caps.append(slots[t * width + k])
                    self.add_thread(pc + 1, caps, text, at + 1, gen, mark, npcs, nslots)
            swap(pcs, npcs)
            swap(slots, nslots)
            if at >= n:
                break
            at += 1
        return result^

    def search(self, text: List[Int], start: Int) -> List[Int]:
        """Leftmost match at or after `start`: [s0, e0, s1, e1, ...], or empty."""
        return self.run(text, start, False)

    def match_at(self, text: List[Int], start: Int) -> List[Int]:
        """A match that begins exactly at `start`, or empty."""
        return self.run(text, start, True)

    def expand(self, template: List[Int], text: List[Int], caps: List[Int]) -> List[Int]:
        """Build replacement text: $1..$99 and ${1} insert a group, $0 and $& the whole
        match, $$ a dollar sign; \\n \\t \\\\ are a newline, a tab and a backslash. A group
        that does not exist or did not take part inserts nothing."""
        var out = List[Int]()
        var n = len(template)
        var i = 0
        while i < n:
            var c = template[i]
            if c == 92 and i + 1 < n:
                var e = template[i + 1]
                if e == 110:
                    out.append(10)
                    i += 2
                    continue
                if e == 116:
                    out.append(9)
                    i += 2
                    continue
                if e == 92:
                    out.append(92)
                    i += 2
                    continue
            if c == 36 and i + 1 < n:
                var e = template[i + 1]
                var g = -1
                var used = 0
                if e == 36:
                    out.append(36)
                    i += 2
                    continue
                if e == 38:
                    g = 0
                    used = 2
                elif e >= 48 and e <= 57:
                    g = e - 48
                    used = 2
                    # a second digit belongs to the number only if that group exists
                    if i + 2 < n and template[i + 2] >= 48 and template[i + 2] <= 57:
                        var g2 = g * 10 + template[i + 2] - 48
                        if g2 <= self.groups:
                            g = g2
                            used = 3
                elif e == 123:
                    var j = i + 2
                    var v = 0
                    while j < n and template[j] >= 48 and template[j] <= 57 and j - i < 6:
                        v = v * 10 + template[j] - 48
                        j += 1
                    if j < n and template[j] == 125 and j > i + 2:
                        g = v
                        used = j + 1 - i
                if used > 0:
                    if g <= self.groups and 2 * g + 1 < len(caps) and caps[2 * g] >= 0:
                        for k in range(caps[2 * g], caps[2 * g + 1]):
                            out.append(text[k])
                    i += used
                    continue
            out.append(c)
            i += 1
        return out^


def regex_compile(pattern: List[Int], ignore_case: Bool) -> Regex:
    """Compile a pattern. Check `.ok`; when it is False `.error` says why and `.error_at`
    where."""
    var re = Regex()
    re.pat = pattern.copy()
    re.ignore_case = ignore_case
    if len(pattern) >= 4 and pattern[0] == 40 and pattern[1] == 63 and pattern[2] == 105 and pattern[3] == 41:
        re.ignore_case = True
        re.pos = 4
    var root = re.parse_alt(0)
    if not re.failed() and re.pos < len(re.pat):
        re.fail("unmatched )", re.pos)
    if re.failed():
        return re^
    _ = re.emit(I_SAVE, 0, 0)
    re.gen(root)
    _ = re.emit(I_SAVE, 1, 0)
    _ = re.emit(I_MATCH, 0, 0)
    if re.failed():
        re.op.clear()
        return re^
    re.find_first()
    re.ok = True
    return re^
