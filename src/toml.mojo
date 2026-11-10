"""A small TOML reader/writer for configuration files.

Supported: comments, `[table]` headers, `key = value` with basic strings ("..." with
\\ \" \n \t escapes), literal strings ('...'), integers, booleans and one-line arrays of
those. Not supported (reported as a problem, never fatal): multi-line strings and arrays,
inline tables, arrays of tables, dotted keys, dates and floats.

Values are addressed as "table.key" (or just "key" before the first table header).
`toml_set` changes one value in existing text and leaves everything else, including the
user's comments and ordering, untouched."""
from std.collections import List
from util import decode, to_str, slice_str, is_digit

comptime T_STR = 0
comptime T_INT = 1
comptime T_BOOL = 2
comptime T_LIST = 3


struct TomlValue(Copyable, Movable):
    var kind: Int
    var s: String
    var i: Int
    var b: Bool
    var items: List[String]   # list elements as text (strings unquoted, ints as digits)

    def __init__(out self):
        self.kind = T_STR
        self.s = ""
        self.i = 0
        self.b = False
        self.items = List[String]()


struct TomlDoc(Copyable, Movable):
    var keys: List[String]
    var vals: List[TomlValue]
    var problems: List[String]   # "line N: what is wrong"

    def __init__(out self):
        self.keys = List[String]()
        self.vals = List[TomlValue]()
        self.problems = List[String]()

    def find(self, key: String) -> Int:
        # the last assignment wins, as when a later file overrides an earlier one
        var i = len(self.keys) - 1
        while i >= 0:
            if self.keys[i] == key:
                return i
            i -= 1
        return -1

    def has(self, key: String) -> Bool:
        return self.find(key) >= 0

    def get_str(self, key: String, default: String) -> String:
        var i = self.find(key)
        if i < 0 or self.vals[i].kind != T_STR:
            return default
        return self.vals[i].s

    def get_int(self, key: String, default: Int) -> Int:
        var i = self.find(key)
        if i < 0 or self.vals[i].kind != T_INT:
            return default
        return self.vals[i].i

    def get_bool(self, key: String, default: Bool) -> Bool:
        var i = self.find(key)
        if i < 0 or self.vals[i].kind != T_BOOL:
            return default
        return self.vals[i].b

    def get_list(self, key: String) -> List[String]:
        var i = self.find(key)
        if i < 0:
            return List[String]()
        if self.vals[i].kind == T_STR:
            # a single string is accepted where a list is expected
            var one = List[String]()
            one.append(self.vals[i].s)
            return one^
        if self.vals[i].kind != T_LIST:
            return List[String]()
        return self.vals[i].items.copy()

    def keys_in(self, table: String) -> List[String]:
        """Key names (without the table prefix) defined in a table, in file order."""
        var out = List[String]()
        var prefix = decode(table + ".")
        for k in self.keys:
            var kc = decode(k)
            if len(kc) <= len(prefix):
                continue
            var same = True
            for j in range(len(prefix)):
                if kc[j] != prefix[j]:
                    same = False
                    break
            if same:
                var name = slice_str(kc, len(prefix), len(kc))
                if not (name in out):
                    out.append(name)
        return out^

    def merge(mut self, other: TomlDoc):
        """Layer another document on top: its values override ours."""
        for i in range(len(other.keys)):
            self.keys.append(other.keys[i])
            self.vals.append(other.vals[i].copy())
        for p in other.problems:
            self.problems.append(p)


def is_space(c: Int) -> Bool:
    return c == 32 or c == 9 or c == 13


def is_key_char(c: Int) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or is_digit(c) or c == 95 or c == 45 or c == 46


struct Scan:
    """Cursor over one line of codepoints."""
    var c: List[Int]
    var i: Int
    var ok: Bool
    var err: String

    def __init__(out self, var c: List[Int]):
        self.c = c^
        self.i = 0
        self.ok = True
        self.err = ""

    def skip_ws(mut self):
        while self.i < len(self.c) and is_space(self.c[self.i]):
            self.i += 1

    def at_end(self) -> Bool:
        return self.i >= len(self.c) or self.c[self.i] == 35

    def peek(self) -> Int:
        return self.c[self.i] if self.i < len(self.c) else -1

    def fail(mut self, msg: String):
        if self.ok:
            self.ok = False
            self.err = msg

    def key(mut self) -> String:
        """A bare key or a quoted key."""
        self.skip_ws()
        if self.peek() == 34 or self.peek() == 39:
            return self.string()
        var start = self.i
        while self.i < len(self.c) and is_key_char(self.c[self.i]):
            self.i += 1
        if self.i == start:
            self.fail("expected a key name")
        return slice_str(self.c, start, self.i)

    def string(mut self) -> String:
        var q = self.peek()
        self.i += 1
        var out = List[Int]()
        while self.i < len(self.c):
            var ch = self.c[self.i]
            if ch == q:
                self.i += 1
                return to_str(out)
            if ch == 92 and q == 34:
                self.i += 1
                var e = self.peek()
                if e == 110:
                    out.append(10)
                elif e == 116:
                    out.append(9)
                elif e == 34 or e == 92:
                    out.append(e)
                else:
                    self.fail("unsupported escape in string")
                    return to_str(out)
                self.i += 1
                continue
            out.append(ch)
            self.i += 1
        self.fail("string is not closed")
        return to_str(out)

    def scalar(mut self) -> TomlValue:
        var v = TomlValue()
        self.skip_ws()
        var ch = self.peek()
        if ch == 34 or ch == 39:
            if self.i + 2 < len(self.c) and self.c[self.i + 1] == ch and self.c[self.i + 2] == ch:
                self.fail("multi-line strings are not supported")
                return v^
            v.kind = T_STR
            v.s = self.string()
            return v^
        var start = self.i
        while self.i < len(self.c) and not is_space(self.c[self.i]) and self.c[self.i] != 44 and self.c[self.i] != 93 and self.c[self.i] != 35:
            self.i += 1
        var word = slice_str(self.c, start, self.i)
        if word == "true" or word == "false":
            v.kind = T_BOOL
            v.b = word == "true"
            return v^
        var wc = decode(word)
        var j = 0
        var neg = False
        if len(wc) > 0 and (wc[0] == 45 or wc[0] == 43):
            neg = wc[0] == 45
            j = 1
        var digits = 0
        var n = 0
        while j < len(wc):
            if is_digit(wc[j]):
                n = n * 10 + wc[j] - 48
                digits += 1
            elif wc[j] != 95:
                digits = -1000
                break
            j += 1
        if digits > 0:
            v.kind = T_INT
            v.i = -n if neg else n
            return v^
        if len(wc) == 0:
            self.fail("missing value")
        else:
            self.fail("unsupported value: " + word)
        return v^

    def value(mut self) -> TomlValue:
        self.skip_ws()
        if self.peek() != 91:
            return self.scalar()
        var v = TomlValue()
        v.kind = T_LIST
        self.i += 1
        while True:
            self.skip_ws()
            if self.peek() == 93:
                self.i += 1
                return v^
            if self.i >= len(self.c):
                self.fail("array is not closed on this line")
                return v^
            var item = self.scalar()
            if not self.ok:
                return v^
            if item.kind == T_STR:
                v.items.append(item.s)
            elif item.kind == T_INT:
                v.items.append(String(item.i))
            else:
                v.items.append("true" if item.b else "false")
            self.skip_ws()
            if self.peek() == 44:
                self.i += 1
            elif self.peek() != 93:
                self.fail("expected ',' or ']' in array")
                return v^


def split_lines(text: String) -> List[List[Int]]:
    var out = List[List[Int]]()
    var cur = List[Int]()
    for c in decode(text):
        if c == 10:
            out.append(cur.copy())
            cur.clear()
        else:
            cur.append(c)
    out.append(cur.copy())
    return out^


def toml_parse(text: String) -> TomlDoc:
    var doc = TomlDoc()
    var table = String("")
    var lines = split_lines(text)
    for n in range(len(lines)):
        var sc = Scan(lines[n].copy())
        sc.skip_ws()
        if sc.at_end():
            continue
        if sc.peek() == 91:
            sc.i += 1
            if sc.peek() == 91:
                doc.problems.append("line " + String(n + 1) + ": arrays of tables are not supported")
                table = "?unsupported"
                continue
            var name = sc.key()
            sc.skip_ws()
            if not sc.ok or sc.peek() != 93:
                doc.problems.append("line " + String(n + 1) + ": malformed table header")
                table = "?malformed"
                continue
            sc.i += 1
            sc.skip_ws()
            if not sc.at_end():
                doc.problems.append("line " + String(n + 1) + ": unexpected text after table header")
            table = name
            continue
        var key = sc.key()
        sc.skip_ws()
        if not sc.ok or sc.peek() != 61:
            doc.problems.append("line " + String(n + 1) + ": expected key = value")
            continue
        sc.i += 1
        var v = sc.value()
        if sc.ok:
            sc.skip_ws()
            if not sc.at_end():
                sc.fail("unexpected text after the value")
        if not sc.ok:
            doc.problems.append("line " + String(n + 1) + ": " + sc.err)
            continue
        doc.keys.append(key if table.byte_length() == 0 else table + "." + key)
        doc.vals.append(v^)
    return doc^


# ------------------------------------------------------------------ writing
def toml_quote(s: String) -> String:
    var out = List[Int]()
    out.append(34)
    for c in decode(s):
        if c == 34 or c == 92:
            out.append(92)
            out.append(c)
        elif c == 10:
            out.append(92)
            out.append(110)
        elif c == 9:
            out.append(92)
            out.append(116)
        else:
            out.append(c)
    out.append(34)
    return to_str(out)


def toml_bool(b: Bool) -> String:
    return "true" if b else "false"


def line_table(line: List[Int]) -> String:
    """The table name if this line is a `[table]` header, else ''."""
    var sc = Scan(line.copy())
    sc.skip_ws()
    if sc.peek() != 91:
        return ""
    sc.i += 1
    var name = sc.key()
    if not sc.ok or sc.peek() != 93:
        return ""
    return name


def line_key(line: List[Int]) -> String:
    """The key if this line is a `key = ...` assignment, else ''."""
    var sc = Scan(line.copy())
    sc.skip_ws()
    if sc.at_end() or sc.peek() == 91:
        return ""
    var k = sc.key()
    sc.skip_ws()
    if not sc.ok or sc.peek() != 61:
        return ""
    return k


def toml_set(text: String, table: String, key: String, literal: String) -> String:
    """Return `text` with `[table] key = literal` set. An existing assignment is replaced
    in place (keeping a trailing comment is not attempted); otherwise the key is added at
    the end of its table, and the table is appended if it does not exist yet."""
    var lines = split_lines(text)
    # a final newline produces one empty last element: drop it while editing
    var had_trailing_newline = len(lines) > 0 and len(lines[len(lines) - 1]) == 0
    if had_trailing_newline:
        _ = lines.pop()
    var new_line = decode(key + " = " + literal)
    var current = String("")
    var table_start = -1     # index of the table's header line
    var table_last = -1      # index of the last non-blank line belonging to the table
    for n in range(len(lines)):
        var t = line_table(lines[n])
        if t.byte_length() > 0:
            current = t
            if t == table:
                table_start = n
                table_last = n
            continue
        if current == table and (table_start >= 0 or table.byte_length() == 0):
            var k = line_key(lines[n])
            if k == key:
                lines[n] = new_line.copy()
                return join_lines(lines)
            var blank = True
            for c in lines[n]:
                if not is_space(c):
                    blank = False
                    break
            if not blank:
                table_last = n
    if table.byte_length() == 0:
        lines.insert(max(0, table_last + 1), new_line.copy())
    elif table_start >= 0:
        lines.insert(table_last + 1, new_line.copy())
    else:
        if len(lines) > 0:
            lines.append(List[Int]())
        lines.append(decode("[" + table + "]"))
        lines.append(new_line.copy())
    return join_lines(lines)


def join_lines(lines: List[List[Int]]) -> String:
    var out = List[Int]()
    for l in lines:
        for c in l:
            out.append(c)
        out.append(10)
    return to_str(out)
