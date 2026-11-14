"""The vim interface's search patterns and `:` command lines (P12-03), worked out on the
text alone: vim's pattern syntax turned into TurboMojo's regular expressions (regex.mojo),
a `:s` replacement turned into the form Search.replacement expands, and a command line
split into its range, name, ! and argument. app_vimcmd.mojo runs them."""
from std.collections import List
from util import decode, to_str


def is_alpha(ch: Int) -> Bool:
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122)


def is_digit(ch: Int) -> Bool:
    return ch >= 48 and ch <= 57


struct VimPat(Copyable, Movable):
    var pat: List[Int]      # TurboMojo's regular expression
    var icase: Bool         # \c in the pattern: ignore case

    def __init__(out self, var pat: List[Int], icase: Bool):
        self.pat = pat^
        self.icase = icase


def vim_pattern(p: List[Int]) -> VimPat:
    """vim's "magic" pattern syntax as TurboMojo's regular expression: . * [ ] ^ $ as
    they are; \\( \\) \\| \\+ \\? \\= \\{ for groups, alternatives and repeats, while a bare
    ( ) | + ? { } is the character itself; \\< \\> word boundaries; \\c ignore case, \\C
    not; \\v ("very magic") then takes ( ) | + ? { } as operators."""
    var out = List[Int]()
    var icase = False
    var very = False
    var brace = False           # inside \{...}: the bare } closes it
    var i = 0
    var n = len(p)
    while i < n:
        var ch = p[i]
        if ch == 92 and i + 1 < n:              # \
            var e = p[i + 1]
            i += 2
            if e == 99:                         # \c
                icase = True
            elif e == 67:                       # \C
                icase = False
            elif e == 118:                      # \v
                very = True
            elif e == 109 or e == 77:           # \m \M: back to magic
                very = False
            elif e == 60 or e == 62:            # \< \>
                out.append(92)
                out.append(98)
            elif not very and (e == 40 or e == 41 or e == 124 or e == 43 or e == 63):
                out.append(e)                   # \( \) \| \+ \?
            elif not very and e == 61:          # \=
                out.append(63)
            elif not very and e == 123:         # \{
                out.append(123)
                brace = True
            else:
                out.append(92)                  # \d \w \s \t \. \* \/ \\ ...
                out.append(e)
            continue
        if ch == 91:                            # [...] copied as it is
            var j = i + 1
            if j < n and p[j] == 94:
                j += 1
            if j < n and p[j] == 93:
                j += 1
            while j < n and p[j] != 93:
                if p[j] == 92:
                    j += 1
                j += 1
            if j < n:
                for k in range(i, j + 1):
                    out.append(p[k])
                i = j + 1
                continue
            out.append(92)                      # an unclosed [ is the character
            out.append(91)
            i += 1
            continue
        if ch == 125 and brace:
            out.append(125)
            brace = False
        elif very and (ch == 60 or ch == 62):   # \v: < > are word boundaries
            out.append(92)
            out.append(98)
        elif very and ch == 61:
            out.append(63)
        elif not very and (ch == 40 or ch == 41 or ch == 124 or ch == 43 or ch == 63 or ch == 123 or ch == 125):
            out.append(92)
            out.append(ch)
        else:
            out.append(ch)
        i += 1
    return VimPat(out^, icase)


def vim_replacement(r: List[Int]) -> List[Int]:
    """A `:s` replacement as Search.replacement expands it: & and \\0 the match, \\1 to \\9
    its groups, \\& a &, \\r a line break, \\t a tab, \\\\ a backslash; a $ stays a $."""
    var out = List[Int]()
    var i = 0
    while i < len(r):
        var ch = r[i]
        if ch == 92 and i + 1 < len(r):
            var e = r[i + 1]
            i += 2
            if is_digit(e):
                for c in decode("${"):
                    out.append(c)
                out.append(e)
                out.append(125)
            elif e == 114 or e == 110:          # \r (\n too: vim's would be a NUL)
                out.append(92)
                out.append(110)
            elif e == 116:
                out.append(92)
                out.append(116)
            elif e == 36:                       # \$
                out.append(36)
                out.append(36)
            else:
                if e == 92:
                    out.append(92)              # (expand keeps \\ as one \)
                out.append(e)                   # \& \\ \/ ...: the character
            continue
        if ch == 38:                            # &
            for c in decode("${0}"):
                out.append(c)
        elif ch == 36:                          # $ is not special in vim
            out.append(36)
            out.append(36)
        else:
            out.append(ch)
        i += 1
    return out^


struct VimSub(Copyable, Movable):
    """`:s/pattern/replacement/flags`, split."""
    var ok: Bool
    var error: String
    var pat: List[Int]      # vim's syntax, as typed (empty: the last search's)
    var rep: List[Int]
    var all: Bool           # g: every match in the line, not only the first
    var icase: Bool         # i
    var noic: Bool          # I

    def __init__(out self):
        self.ok = False
        self.error = ""
        self.pat = List[Int]()
        self.rep = List[Int]()
        self.all = False
        self.icase = False
        self.noic = False


def parse_sub(a: List[Int]) -> VimSub:
    """What follows `:s`: a delimiter (any character that is not a letter, a digit, a
    blank or \\ " |), the pattern, the replacement and the flags; the last delimiter may
    be left out. A \\ and the delimiter stand for the delimiter."""
    var s = VimSub()
    if len(a) == 0:
        s.error = "E35: No previous regular expression (give :s a pattern: :s/old/new/)"
        return s^
    var d = a[0]
    if is_alpha(d) or is_digit(d) or d == 32 or d == 92 or d == 34 or d == 124:
        s.error = "E146: Regular expressions can't be delimited by letters"
        return s^
    var part = 0
    var i = 1
    var flags = List[Int]()
    while i < len(a):
        var ch = a[i]
        if part < 2 and ch == 92 and i + 1 < len(a):
            if a[i + 1] == d:
                if part == 0:
                    s.pat.append(d)
                else:
                    s.rep.append(d)
            else:
                if part == 0:
                    s.pat.append(92)
                    s.pat.append(a[i + 1])
                else:
                    s.rep.append(92)
                    s.rep.append(a[i + 1])
            i += 2
            continue
        if part < 2 and ch == d:
            part += 1
            i += 1
            continue
        if part == 0:
            s.pat.append(ch)
        elif part == 1:
            s.rep.append(ch)
        else:
            flags.append(ch)
        i += 1
    for f in flags:
        if f == 103:
            s.all = True
        elif f == 105:
            s.icase = True
        elif f == 73:
            s.noic = True
        elif f == 32:
            pass
        else:
            s.error = "E488: Trailing characters: " + to_str(flags) + " (the flags here are g, i and I)"
            return s^
    s.ok = True
    return s^


struct VimEx(Copyable, Movable):
    """A `:` command line, split: [range] name[!] [argument]."""
    var ok: Bool
    var error: String
    var has_range: Bool
    var r1: Int             # 0-based rows, r1 <= r2
    var r2: Int
    var name: String
    var bang: Bool
    var arg: String
    var raw: List[Int]      # what follows the name (for :s, as it was typed)

    def __init__(out self):
        self.ok = False
        self.error = ""
        self.has_range = False
        self.r1 = 0
        self.r2 = 0
        self.name = ""
        self.bang = False
        self.arg = ""
        self.raw = List[Int]()


def parse_addr(t: List[Int], mut i: Int, cur: Int, last: Int, v1: Int, v2: Int) -> Int:
    """One address at t[i]: a line number, . (this line), $ (the last), '< '> (the
    Visual selection's first and last), each with + N / - N after it. -1 when there is
    none; -2 for '< '> without a selection. `i` moves past it."""
    var row = -1
    if i < len(t) and is_digit(t[i]):
        var v = 0
        while i < len(t) and is_digit(t[i]):
            v = min(v * 10 + (t[i] - 48), 1000000000)
            i += 1
        row = v - 1
    elif i < len(t) and t[i] == 46:
        row = cur
        i += 1
    elif i < len(t) and t[i] == 36:
        row = last
        i += 1
    elif i + 1 < len(t) and t[i] == 39 and (t[i + 1] == 60 or t[i + 1] == 62):
        if v1 < 0:
            return -2
        row = v1 if t[i + 1] == 60 else v2
        i += 2
    while i < len(t) and (t[i] == 43 or t[i] == 45):
        var sign = 1 if t[i] == 43 else -1
        i += 1
        var v2_ = 0
        var any = False
        while i < len(t) and is_digit(t[i]):
            v2_ = min(v2_ * 10 + (t[i] - 48), 1000000000)
            any = True
            i += 1
        if row < 0:
            row = cur
        row += sign * (v2_ if any else 1)
    return row


def parse_ex(line: List[Int], cur: Int, last: Int, v1: Int, v2: Int) -> VimEx:
    """Split command line `line` (without its colon); `cur` the cursor's row, `last` the
    last row, v1 / v2 the Visual selection's rows (-1: none)."""
    var x = VimEx()
    var t = line.copy()
    var i = 0
    while i < len(t) and (t[i] == 32 or t[i] == 58):       # blanks and more colons
        i += 1
    if i < len(t) and t[i] == 37:                          # %: every line
        x.has_range = True
        x.r1 = 0
        x.r2 = last
        i += 1
    else:
        var a = parse_addr(t, i, cur, last, v1, v2)
        if a == -2:
            x.error = "E20: Mark not set (there is no Visual selection)"
            return x^
        if a >= -1 and a != -1:
            x.has_range = True
            x.r1 = a
            x.r2 = a
            if i < len(t) and (t[i] == 44 or t[i] == 59):
                i += 1
                var b = parse_addr(t, i, cur, last, v1, v2)
                if b == -2:
                    x.error = "E20: Mark not set (there is no Visual selection)"
                    return x^
                if b >= 0:
                    x.r2 = b
        if x.has_range:
            if x.r1 < 0 or x.r2 < 0 or x.r1 > last or x.r2 > last:
                x.error = "E16: Invalid range"
                return x^
            if x.r1 > x.r2:
                var k = x.r1
                x.r1 = x.r2
                x.r2 = k
    while i < len(t) and t[i] == 32:
        i += 1
    var name = List[Int]()
    while i < len(t) and is_alpha(t[i]):
        name.append(t[i])
        i += 1
    # a name of TurboMojo's own commands may have dots and capitals: compile.build
    while len(name) > 0 and i < len(t) and (t[i] == 46 or is_alpha(t[i]) or is_digit(t[i])):
        name.append(t[i])
        i += 1
    x.name = to_str(name)
    if i < len(t) and t[i] == 33:
        x.bang = True
        i += 1
    for k in range(i, len(t)):
        x.raw.append(t[k])
    var j = i
    while j < len(t) and t[j] == 32:
        j += 1
    var e = len(t)
    while e > j and t[e - 1] == 32:
        e -= 1
    var arg = List[Int]()
    for k in range(j, e):
        arg.append(t[k])
    x.arg = to_str(arg)
    x.ok = True
    return x^


def ex_is(name: String, full: String, shortest: Int) -> Bool:
    """Is `name` command `full` or a short form of it at least `shortest` letters long
    (vim's abbreviations: :w :wr... :write)?"""
    if name.byte_length() < shortest or name.byte_length() > full.byte_length():
        return False
    return full.startswith(name)
