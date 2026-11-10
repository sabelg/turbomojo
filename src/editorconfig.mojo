"""EditorConfig support (https://editorconfig.org).

For a file, every `.editorconfig` from its directory up to the filesystem root (or up to
one containing `root = true`) is read. Files nearer the edited file win over farther ones,
and within one file later matching sections win over earlier ones.

Supported properties: indent_style, indent_size, tab_width, end_of_line (lf / crlf),
insert_final_newline, trim_trailing_whitespace. `charset` and `max_line_length` are read
and ignored. Supported glob syntax: `*`, `**`, `?`, `[abc]`, `[!abc]`, `[a-z]`,
`{a,b,c}`, `{1..5}` and backslash escapes."""
from std.collections import List
from util import decode, to_str, slice_str, lower, is_digit, dirname, join_path, path_exists

comptime EC_FILE_NAME = ".editorconfig"


struct EcProps(Copyable, Movable):
    """The properties that apply to one file. A `has_` flag is False when unspecified."""
    var has_indent_style: Bool
    var use_tabs: Bool
    var has_indent_size: Bool
    var indent_size: Int
    var indent_size_is_tab: Bool
    var has_tab_width: Bool
    var tab_width: Int
    var has_eol: Bool
    var crlf: Bool
    var has_final_newline: Bool
    var final_newline: Bool
    var has_trim: Bool
    var trim: Bool

    def __init__(out self):
        self.has_indent_style = False
        self.use_tabs = False
        self.has_indent_size = False
        self.indent_size = 4
        self.indent_size_is_tab = False
        self.has_tab_width = False
        self.tab_width = 4
        self.has_eol = False
        self.crlf = False
        self.has_final_newline = False
        self.final_newline = True
        self.has_trim = False
        self.trim = False

    def set(mut self, key: String, value: String):
        """Apply one `key = value` pair (both already lower-cased)."""
        var unset = value == "unset"
        if key == "indent_style":
            self.has_indent_style = not unset and (value == "tab" or value == "space")
            self.use_tabs = value == "tab"
        elif key == "indent_size":
            if value == "tab":
                self.has_indent_size = True
                self.indent_size_is_tab = True
            else:
                var n = to_int(value)
                self.has_indent_size = not unset and n >= 1 and n <= 64
                self.indent_size_is_tab = False
                if self.has_indent_size:
                    self.indent_size = n
        elif key == "tab_width":
            var n = to_int(value)
            self.has_tab_width = not unset and n >= 1 and n <= 64
            if self.has_tab_width:
                self.tab_width = n
        elif key == "end_of_line":
            self.has_eol = not unset and (value == "lf" or value == "crlf")
            self.crlf = value == "crlf"
        elif key == "insert_final_newline":
            self.has_final_newline = not unset and (value == "true" or value == "false")
            self.final_newline = value == "true"
        elif key == "trim_trailing_whitespace":
            self.has_trim = not unset and (value == "true" or value == "false")
            self.trim = value == "true"

    def effective_tab_width(self, default: Int) -> Int:
        """tab_width, falling back to a numeric indent_size, then the default."""
        if self.has_tab_width:
            return self.tab_width
        if self.has_indent_size and not self.indent_size_is_tab:
            return self.indent_size
        return default

    def effective_indent_size(self, default: Int) -> Int:
        """indent_size; `tab` means "one tab stop", i.e. the tab width."""
        if self.has_indent_size and not self.indent_size_is_tab:
            return self.indent_size
        if self.has_indent_size and self.indent_size_is_tab:
            return self.effective_tab_width(default)
        # per the EditorConfig rules: indenting with tabs and no indent_size given
        # means indent_size = tab
        if self.has_indent_style and self.use_tabs:
            return self.effective_tab_width(default)
        return default


def to_int(s: String) -> Int:
    """Non-negative decimal integer, or -1."""
    var c = decode(s)
    if len(c) == 0 or len(c) > 9:
        return -1
    var n = 0
    for d in c:
        if not is_digit(d):
            return -1
        n = n * 10 + d - 48
    return n


def trim_lower(cps: List[Int], a: Int, b: Int) -> String:
    var lo = a
    var hi = b
    while lo < hi and (cps[lo] == 32 or cps[lo] == 9 or cps[lo] == 13):
        lo += 1
    while hi > lo and (cps[hi - 1] == 32 or cps[hi - 1] == 9 or cps[hi - 1] == 13):
        hi -= 1
    var out = List[Int]()
    for i in range(lo, hi):
        out.append(lower(cps[i]))
    return to_str(out)


def trim_keep_case(cps: List[Int], a: Int, b: Int) -> String:
    var lo = a
    var hi = b
    while lo < hi and (cps[lo] == 32 or cps[lo] == 9 or cps[lo] == 13):
        lo += 1
    while hi > lo and (cps[hi - 1] == 32 or cps[hi - 1] == 9 or cps[hi - 1] == 13):
        hi -= 1
    return slice_str(cps, lo, hi)


struct EcFile(Copyable, Movable):
    """One parsed .editorconfig: sections in file order, each with its key/value pairs."""
    var root: Bool
    var patterns: List[String]
    var keys: List[List[String]]
    var values: List[List[String]]

    def __init__(out self):
        self.root = False
        self.patterns = List[String]()
        self.keys = List[List[String]]()
        self.values = List[List[String]]()


def ec_parse(text: String) -> EcFile:
    var f = EcFile()
    var cur = List[Int]()
    var all = decode(text)
    all.append(10)
    for c in all:
        if c != 10:
            cur.append(c)
            continue
        var line = cur.copy()
        cur.clear()
        var first = 0
        while first < len(line) and (line[first] == 32 or line[first] == 9):
            first += 1
        if first >= len(line) or line[first] == 35 or line[first] == 59:
            continue
        if line[first] == 91:
            var close = len(line) - 1
            while close > first and line[close] != 93:
                close -= 1
            if close > first:
                f.patterns.append(trim_keep_case(line, first + 1, close))
                f.keys.append(List[String]())
                f.values.append(List[String]())
            continue
        var eq = -1
        for i in range(first, len(line)):
            if line[i] == 61 or line[i] == 58:
                eq = i
                break
        if eq < 0:
            continue
        var key = trim_lower(line, first, eq)
        var value = trim_lower(line, eq + 1, len(line))
        if len(f.patterns) == 0:
            if key == "root":
                f.root = value == "true"
            continue
        f.keys[len(f.keys) - 1].append(key)
        f.values[len(f.values) - 1].append(value)
    return f^


# --------------------------------------------------------------------- globs
def expand_braces(pattern: List[Int]) -> List[List[Int]]:
    """Expand the first {a,b} or {n..m} group, recursively. A pattern without a valid
    group is returned as is."""
    var out = List[List[Int]]()
    var n = len(pattern)
    var i = 0
    while i < n:
        if pattern[i] == 92:
            i += 2
            continue
        if pattern[i] == 123:
            var depth = 0
            var j = i
            var close = -1
            var commas = List[Int]()
            while j < n:
                if pattern[j] == 92:
                    j += 2
                    continue
                if pattern[j] == 123:
                    depth += 1
                elif pattern[j] == 125:
                    depth -= 1
                    if depth == 0:
                        close = j
                        break
                elif pattern[j] == 44 and depth == 1:
                    commas.append(j)
                j += 1
            if close < 0:
                break
            var alts = List[List[Int]]()
            if len(commas) > 0:
                var start = i + 1
                commas.append(close)
                for cpos in commas:
                    var a = List[Int]()
                    for k in range(start, cpos):
                        a.append(pattern[k])
                    alts.append(a^)
                    start = cpos + 1
            else:
                # numeric range {lo..hi}
                var inner = slice_str(pattern, i + 1, close)
                var dots = inner.find("..")
                if dots > 0:
                    var ic = decode(inner)
                    var lo = signed_int(slice_str(ic, 0, dots))
                    var hi = signed_int(slice_str(ic, dots + 2, len(ic)))
                    if lo.ok and hi.ok and hi.v - lo.v >= 0 and hi.v - lo.v <= 200:
                        for v in range(lo.v, hi.v + 1):
                            alts.append(decode(String(v)))
            if len(alts) == 0:
                i = close + 1
                continue
            for a in alts:
                var p = List[Int]()
                for k in range(i):
                    p.append(pattern[k])
                for c in a:
                    p.append(c)
                for k in range(close + 1, n):
                    p.append(pattern[k])
                for e in expand_braces(p):
                    out.append(e.copy())
            return out^
        i += 1
    out.append(pattern.copy())
    return out^


@fieldwise_init
struct MaybeInt(Copyable, Movable):
    var ok: Bool
    var v: Int


def signed_int(s: String) -> MaybeInt:
    var c = decode(s)
    var neg = len(c) > 0 and c[0] == 45
    var digits = slice_str(c, 1 if neg else 0, len(c))
    var n = to_int(digits)
    if n < 0:
        return MaybeInt(False, 0)
    return MaybeInt(True, -n if neg else n)


def match_from(p: List[Int], pi: Int, s: List[Int], si: Int) -> Bool:
    var i = pi
    var j = si
    var np = len(p)
    var ns = len(s)
    while i < np:
        var c = p[i]
        if c == 42:
            if i + 1 < np and p[i + 1] == 42:
                # ** : any characters including '/'. "**/" may also match nothing.
                var rest = i + 2
                if rest < np and p[rest] == 47:
                    if match_from(p, rest + 1, s, j):
                        return True
                for k in range(j, ns + 1):
                    if match_from(p, rest, s, k):
                        return True
                return False
            # * : any characters except '/'
            var k = j
            while True:
                if match_from(p, i + 1, s, k):
                    return True
                if k >= ns or s[k] == 47:
                    return False
                k += 1
        if j >= ns:
            return False
        if c == 63:
            if s[j] == 47:
                return False
        elif c == 91:
            var close = i + 1
            if close < np and (p[close] == 33 or p[close] == 94):
                close += 1
            if close < np and p[close] == 93:
                close += 1
            while close < np and p[close] != 93:
                close += 1
            if close >= np:
                if s[j] != 91:      # no closing bracket: a literal '['
                    return False
            else:
                var k = i + 1
                var negate = p[k] == 33 or p[k] == 94
                if negate:
                    k += 1
                var hit = False
                while k < close:
                    if k + 2 < close and p[k + 1] == 45:
                        if s[j] >= p[k] and s[j] <= p[k + 2]:
                            hit = True
                        k += 3
                    else:
                        if s[j] == p[k]:
                            hit = True
                        k += 1
                if hit == negate or s[j] == 47:
                    return False
                i = close
        elif c == 92 and i + 1 < np:
            i += 1
            if s[j] != p[i]:
                return False
        elif s[j] != c:
            return False
        i += 1
        j += 1
    return j == ns


def glob_match(pattern: String, rel_path: String) -> Bool:
    """Does an EditorConfig section pattern match a path relative to the directory of
    the .editorconfig file? A pattern without '/' matches the file name at any depth."""
    var p = decode(pattern)
    var has_slash = False
    for c in p:
        if c == 47:
            has_slash = True
    if not has_slash:
        var q = decode("**/")
        for c in p:
            q.append(c)
        p = q^
    elif len(p) > 0 and p[0] == 47:
        var q = List[Int]()
        for k in range(1, len(p)):
            q.append(p[k])
        p = q^
    var s = decode(rel_path)
    for alt in expand_braces(p):
        if match_from(alt, 0, s, 0):
            return True
    return False


# -------------------------------------------------------------------- lookup
def ec_apply(mut props: EcProps, f: EcFile, rel_path: String):
    """Apply every matching section of one file, in file order."""
    for i in range(len(f.patterns)):
        if glob_match(f.patterns[i], rel_path):
            for k in range(len(f.keys[i])):
                props.set(f.keys[i][k], f.values[i][k])


def ec_resolve(dirs: List[String], texts: List[String], path: String) -> EcProps:
    """Resolve properties for `path` from .editorconfig contents.
    dirs[0] is the directory nearest to the file, each following one a parent of it;
    texts[i] is the content of dirs[i]/.editorconfig. Farther files are applied first so
    that nearer ones override them; lookup stops above a file with `root = true`."""
    var files = List[EcFile]()
    var count = 0
    for i in range(len(dirs)):
        var f = ec_parse(texts[i])
        var is_root = f.root
        files.append(f^)
        count += 1
        if is_root:
            break
    var props = EcProps()
    var i = count - 1
    while i >= 0:
        var d = decode(dirs[i])
        var pc = decode(path)
        var start = len(d)
        if start < len(pc) and pc[start] == 47:
            start += 1
        if len(d) == 1 and d[0] == 47:
            start = 1
        ec_apply(props, files[i], slice_str(pc, start, len(pc)))
        i -= 1
    return props^


def ec_for_file(path: String) -> EcProps:
    """Read the .editorconfig files that apply to an absolute path and resolve them."""
    var dirs = List[String]()
    var texts = List[String]()
    var d = dirname(path)
    for _ in range(64):
        var p = join_path(d, EC_FILE_NAME)
        if path_exists(p):
            try:
                var t: String
                with open(p, "r") as f:
                    t = f.read()
                dirs.append(d)
                texts.append(t)
            except:
                pass
        if d == "/" or d == "." or d.byte_length() == 0:
            break
        d = dirname(d)
    return ec_resolve(dirs, texts, path)
