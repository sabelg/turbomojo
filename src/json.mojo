"""JSON reader and writer (RFC 8259).

`json_parse` turns text into a `Json` document: a flat list of nodes addressed by index,
with node 0 as the root. Accessors take a node index and are safe to chain: an index of -1
(a missing key, an out-of-range element) yields the default instead of failing, so

    doc.str(doc.path(0, "result/capabilities/positionEncoding"), "utf-16")

needs no intermediate checks. Malformed input never raises: `ok` is False and `error`
says what is wrong and at which byte.

`JsonWriter` builds JSON text piece by piece and places the commas itself."""
from std.collections import List
from util import str_bytes, bytes_to_str, encode_cp

comptime J_NULL = 0
comptime J_BOOL = 1
comptime J_NUM = 2
comptime J_STR = 3
comptime J_ARR = 4
comptime J_OBJ = 5

comptime JSON_MAX_DEPTH = 256


struct Json(Copyable, Movable):
    var kinds: List[Int]
    var ints: List[Int]          # integer value (also 0/1 for booleans)
    var floats: List[Float64]    # numeric value as a float
    var whole: List[Bool]        # the number was written without fraction or exponent
    var strs: List[String]       # string value
    var keys: List[String]       # member name when the node is an object member
    var first: List[Int]         # first child (-1 if none)
    var next: List[Int]          # next sibling (-1 if none)
    var counts: List[Int]        # number of children
    var ok: Bool
    var error: String
    var error_pos: Int

    def __init__(out self):
        self.kinds = List[Int]()
        self.ints = List[Int]()
        self.floats = List[Float64]()
        self.whole = List[Bool]()
        self.strs = List[String]()
        self.keys = List[String]()
        self.first = List[Int]()
        self.next = List[Int]()
        self.counts = List[Int]()
        self.ok = True
        self.error = ""
        self.error_pos = -1

    def add(mut self, kind: Int) -> Int:
        self.kinds.append(kind)
        self.ints.append(0)
        self.floats.append(0.0)
        self.whole.append(False)
        self.strs.append("")
        self.keys.append("")
        self.first.append(-1)
        self.next.append(-1)
        self.counts.append(0)
        return len(self.kinds) - 1

    # ------------------------------------------------------------ accessors
    def valid(self, i: Int) -> Bool:
        return i >= 0 and i < len(self.kinds)

    def kind(self, i: Int) -> Int:
        """Node kind, or -1 for an invalid index."""
        return self.kinds[i] if self.valid(i) else -1

    def is_null(self, i: Int) -> Bool:
        return self.kind(i) == J_NULL

    def size(self, i: Int) -> Int:
        """Number of elements of an array or members of an object (0 otherwise)."""
        return self.counts[i] if self.valid(i) else 0

    def children(self, i: Int) -> List[Int]:
        var out = List[Int]()
        if not self.valid(i):
            return out^
        var c = self.first[i]
        while c >= 0:
            out.append(c)
            c = self.next[c]
        return out^

    def at(self, i: Int, n: Int) -> Int:
        """Index of the n-th element of an array (or member of an object), or -1."""
        if not self.valid(i) or n < 0 or n >= self.counts[i]:
            return -1
        var c = self.first[i]
        for _ in range(n):
            c = self.next[c]
        return c

    def get(self, i: Int, key: String) -> Int:
        """Index of an object member by name, or -1."""
        if self.kind(i) != J_OBJ:
            return -1
        var c = self.first[i]
        while c >= 0:
            if self.keys[c] == key:
                return c
            c = self.next[c]
        return -1

    def has(self, i: Int, key: String) -> Bool:
        return self.get(i, key) >= 0

    def key_of(self, i: Int) -> String:
        return self.keys[i] if self.valid(i) else ""

    def path(self, i: Int, where: String) -> Int:
        """Follow a '/'-separated path of member names; a numeric segment indexes an
        array. Returns -1 as soon as a step does not exist."""
        var cur = i
        for seg in where.split("/"):
            var s = String(seg)
            if s.byte_length() == 0:
                continue
            if self.kind(cur) == J_ARR:
                var n = 0
                var numeric = True
                for b in s.as_bytes():
                    if b < 48 or b > 57:
                        numeric = False
                        break
                    n = n * 10 + Int(b) - 48
                cur = self.at(cur, n) if numeric else -1
            else:
                cur = self.get(cur, s)
            if cur < 0:
                return -1
        return cur

    def str(self, i: Int, default: String = "") -> String:
        return self.strs[i] if self.kind(i) == J_STR else default

    def int(self, i: Int, default: Int = 0) -> Int:
        """Integer value; a float is truncated toward zero."""
        if self.kind(i) != J_NUM:
            return default
        return self.ints[i] if self.whole[i] else Int(self.floats[i])

    def float(self, i: Int, default: Float64 = 0.0) -> Float64:
        return self.floats[i] if self.kind(i) == J_NUM else default

    def bool(self, i: Int, default: Bool = False) -> Bool:
        return self.ints[i] != 0 if self.kind(i) == J_BOOL else default

    # ----------------------------------------------------------------- dump
    def dump(self, i: Int = 0) -> String:
        """Compact JSON text of a node and everything below it."""
        var w = JsonWriter()
        self.dump_into(i, w)
        return w.text()

    def dump_into(self, i: Int, mut w: JsonWriter):
        var k = self.kind(i)
        if k == J_NULL or k < 0:
            w.null()
        elif k == J_BOOL:
            w.bool(self.ints[i] != 0)
        elif k == J_NUM:
            if self.whole[i]:
                w.int(self.ints[i])
            else:
                w.float(self.floats[i])
        elif k == J_STR:
            w.str(self.strs[i])
        elif k == J_ARR:
            w.begin_arr()
            var c = self.first[i]
            while c >= 0:
                self.dump_into(c, w)
                c = self.next[c]
            w.end_arr()
        else:
            w.begin_obj()
            var c = self.first[i]
            while c >= 0:
                w.key(self.keys[c])
                self.dump_into(c, w)
                c = self.next[c]
            w.end_obj()


# -------------------------------------------------------------------- parser
struct Parser:
    var b: List[UInt8]
    var i: Int
    var doc: Json

    def __init__(out self, var data: List[UInt8]):
        self.b = data^
        self.i = 0
        self.doc = Json()

    def fail(mut self, msg: String):
        if self.doc.ok:
            self.doc.ok = False
            self.doc.error = msg + " at byte " + String(self.i)
            self.doc.error_pos = self.i

    def peek(self) -> Int:
        return Int(self.b[self.i]) if self.i < len(self.b) else -1

    def skip_ws(mut self):
        while self.i < len(self.b):
            var c = self.b[self.i]
            if c == 32 or c == 9 or c == 10 or c == 13:
                self.i += 1
            else:
                break

    def literal(mut self, word: String) -> Bool:
        var w = str_bytes(word)
        if self.i + len(w) > len(self.b):
            return False
        for k in range(len(w)):
            if self.b[self.i + k] != w[k]:
                return False
        self.i += len(w)
        return True

    def hex4(mut self) -> Int:
        if self.i + 4 > len(self.b):
            self.fail("truncated \\u escape")
            return -1
        var v = 0
        for _ in range(4):
            var c = Int(self.b[self.i])
            var d = -1
            if c >= 48 and c <= 57:
                d = c - 48
            elif c >= 97 and c <= 102:
                d = c - 87
            elif c >= 65 and c <= 70:
                d = c - 55
            if d < 0:
                self.fail("bad hex digit in \\u escape")
                return -1
            v = v * 16 + d
            self.i += 1
        return v

    def string(mut self) -> String:
        """Parse a string; the cursor is on the opening quote."""
        self.i += 1
        var out = List[UInt8]()
        while True:
            if self.i >= len(self.b):
                self.fail("unterminated string")
                return ""
            var c = Int(self.b[self.i])
            if c == 34:
                self.i += 1
                return bytes_to_str(out)
            if c < 32:
                self.fail("control character in string")
                return ""
            if c != 92:
                out.append(UInt8(c))
                self.i += 1
                continue
            self.i += 1
            var e = self.peek()
            self.i += 1
            if e == 34 or e == 92 or e == 47:
                out.append(UInt8(e))
            elif e == 98:
                out.append(8)
            elif e == 102:
                out.append(12)
            elif e == 110:
                out.append(10)
            elif e == 114:
                out.append(13)
            elif e == 116:
                out.append(9)
            elif e == 117:
                var cp = self.hex4()
                if cp < 0:
                    return ""
                if cp >= 0xD800 and cp <= 0xDBFF:
                    # high surrogate: must be followed by \uDC00..\uDFFF
                    if self.i + 1 < len(self.b) and self.b[self.i] == 92 and self.b[self.i + 1] == 117:
                        var save = self.i
                        self.i += 2
                        var lo = self.hex4()
                        if lo < 0:
                            return ""
                        if lo >= 0xDC00 and lo <= 0xDFFF:
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        else:
                            self.i = save      # not a pair: keep the second escape
                            cp = 0xFFFD
                    else:
                        cp = 0xFFFD
                elif cp >= 0xDC00 and cp <= 0xDFFF:
                    cp = 0xFFFD                # lone low surrogate
                encode_cp(cp, out)
            else:
                self.i -= 1
                self.fail("invalid escape")
                return ""

    def number(mut self, node: Int):
        var start = self.i
        var neg = False
        if self.peek() == 45:
            neg = True
            self.i += 1
        var c = self.peek()
        if c < 48 or c > 57:
            self.fail("invalid number")
            return
        var n = 0
        var digits = 0
        if c == 48:
            self.i += 1
            if self.peek() >= 48 and self.peek() <= 57:
                self.fail("leading zeros are not allowed")
                return
        else:
            while self.peek() >= 48 and self.peek() <= 57:
                if digits < 18:
                    n = n * 10 + self.peek() - 48
                digits += 1
                self.i += 1
        var is_whole = digits <= 18
        if self.peek() == 46:
            is_whole = False
            self.i += 1
            if self.peek() < 48 or self.peek() > 57:
                self.fail("digits expected after the decimal point")
                return
            while self.peek() >= 48 and self.peek() <= 57:
                self.i += 1
        if self.peek() == 101 or self.peek() == 69:
            is_whole = False
            self.i += 1
            if self.peek() == 43 or self.peek() == 45:
                self.i += 1
            if self.peek() < 48 or self.peek() > 57:
                self.fail("digits expected in the exponent")
                return
            while self.peek() >= 48 and self.peek() <= 57:
                self.i += 1
        self.doc.whole[node] = is_whole
        if is_whole:
            self.doc.ints[node] = -n if neg else n
            self.doc.floats[node] = Float64(self.doc.ints[node])
            return
        var text = List[UInt8]()
        for k in range(start, self.i):
            text.append(self.b[k])
        try:
            self.doc.floats[node] = atof(bytes_to_str(text))
        except:
            self.fail("invalid number")
            return
        self.doc.ints[node] = Int(self.doc.floats[node])

    def value(mut self, depth: Int) -> Int:
        """Parse one value; returns its node index (or -1 after an error)."""
        if depth > JSON_MAX_DEPTH:
            self.fail("nesting too deep")
            return -1
        self.skip_ws()
        var c = self.peek()
        if c == 123:
            var node = self.doc.add(J_OBJ)
            self.i += 1
            self.skip_ws()
            if self.peek() == 125:
                self.i += 1
                return node
            var last = -1
            while True:
                self.skip_ws()
                if self.peek() != 34:
                    self.fail("member name expected")
                    return -1
                var key = self.string()
                if not self.doc.ok:
                    return -1
                self.skip_ws()
                if self.peek() != 58:
                    self.fail("':' expected")
                    return -1
                self.i += 1
                var child = self.value(depth + 1)
                if child < 0:
                    return -1
                self.doc.keys[child] = key
                if last < 0:
                    self.doc.first[node] = child
                else:
                    self.doc.next[last] = child
                last = child
                self.doc.counts[node] += 1
                self.skip_ws()
                if self.peek() == 44:
                    self.i += 1
                    continue
                if self.peek() == 125:
                    self.i += 1
                    return node
                self.fail("',' or '}' expected")
                return -1
        if c == 91:
            var node = self.doc.add(J_ARR)
            self.i += 1
            self.skip_ws()
            if self.peek() == 93:
                self.i += 1
                return node
            var last = -1
            while True:
                var child = self.value(depth + 1)
                if child < 0:
                    return -1
                if last < 0:
                    self.doc.first[node] = child
                else:
                    self.doc.next[last] = child
                last = child
                self.doc.counts[node] += 1
                self.skip_ws()
                if self.peek() == 44:
                    self.i += 1
                    continue
                if self.peek() == 93:
                    self.i += 1
                    return node
                self.fail("',' or ']' expected")
                return -1
        if c == 34:
            var node = self.doc.add(J_STR)
            var s = self.string()
            if not self.doc.ok:
                return -1
            self.doc.strs[node] = s
            return node
        if c == 116:
            if self.literal("true"):
                var node = self.doc.add(J_BOOL)
                self.doc.ints[node] = 1
                return node
        elif c == 102:
            if self.literal("false"):
                return self.doc.add(J_BOOL)
        elif c == 110:
            if self.literal("null"):
                return self.doc.add(J_NULL)
        elif c == 45 or (c >= 48 and c <= 57):
            var node = self.doc.add(J_NUM)
            self.number(node)
            return node if self.doc.ok else -1
        if c < 0:
            self.fail("unexpected end of input")
        else:
            self.fail("unexpected character")
        return -1


def json_parse_bytes(data: List[UInt8]) -> Json:
    var p = Parser(data.copy())
    var root = p.value(0)
    if root >= 0 and p.doc.ok:
        p.skip_ws()
        if p.i < len(p.b):
            p.fail("unexpected text after the value")
    if not p.doc.ok and len(p.doc.kinds) == 0:
        _ = p.doc.add(J_NULL)      # keep node 0 valid so accessors stay safe
    return p.doc.copy()


def json_parse(text: String) -> Json:
    return json_parse_bytes(str_bytes(text))


# -------------------------------------------------------------------- writer
def json_escape_into(s: String, mut out: List[UInt8]):
    """Append `s` as a quoted JSON string."""
    var hexd = str_bytes("0123456789abcdef")
    out.append(34)
    for c in s.as_bytes():
        if c == 34:
            out.append(92)
            out.append(34)
        elif c == 92:
            out.append(92)
            out.append(92)
        elif c == 10:
            out.append(92)
            out.append(110)
        elif c == 13:
            out.append(92)
            out.append(114)
        elif c == 9:
            out.append(92)
            out.append(116)
        elif c < 32:
            out.append(92)
            out.append(117)
            out.append(48)
            out.append(48)
            out.append(hexd[Int(c) >> 4])
            out.append(hexd[Int(c) & 15])
        else:
            out.append(c)       # UTF-8 passes through unchanged
    out.append(34)


def json_quote(s: String) -> String:
    var out = List[UInt8]()
    json_escape_into(s, out)
    return bytes_to_str(out)


struct JsonWriter(Movable):
    var buf: List[UInt8]
    var first: List[Bool]      # per open container: no element written yet
    var after_key: Bool

    def __init__(out self):
        self.buf = List[UInt8]()
        self.first = List[Bool]()
        self.after_key = False

    def sep(mut self):
        """Write the comma that separates this value from the previous one, if needed."""
        if self.after_key:
            self.after_key = False
            return
        var n = len(self.first)
        if n > 0:
            if self.first[n - 1]:
                self.first[n - 1] = False
            else:
                self.buf.append(44)

    def raw_bytes(mut self, s: String):
        for c in s.as_bytes():
            self.buf.append(c)

    def begin_obj(mut self):
        self.sep()
        self.buf.append(123)
        self.first.append(True)

    def end_obj(mut self):
        self.buf.append(125)
        if len(self.first) > 0:
            _ = self.first.pop()

    def begin_arr(mut self):
        self.sep()
        self.buf.append(91)
        self.first.append(True)

    def end_arr(mut self):
        self.buf.append(93)
        if len(self.first) > 0:
            _ = self.first.pop()

    def key(mut self, k: String):
        self.sep()
        json_escape_into(k, self.buf)
        self.buf.append(58)
        self.after_key = True

    def str(mut self, s: String):
        self.sep()
        json_escape_into(s, self.buf)

    def int(mut self, n: Int):
        self.sep()
        self.raw_bytes(String(n))

    def float(mut self, f: Float64):
        self.sep()
        self.raw_bytes(String(f))

    def bool(mut self, b: Bool):
        self.sep()
        self.raw_bytes("true" if b else "false")

    def null(mut self):
        self.sep()
        self.raw_bytes("null")

    def raw(mut self, json_text: String):
        """Insert already-formed JSON text as one value."""
        self.sep()
        self.raw_bytes(json_text)

    # convenience: key + value in one call
    def kv_str(mut self, k: String, v: String):
        self.key(k)
        self.str(v)

    def kv_int(mut self, k: String, v: Int):
        self.key(k)
        self.int(v)

    def kv_bool(mut self, k: String, v: Bool):
        self.key(k)
        self.bool(v)

    def text(self) -> String:
        return bytes_to_str(self.buf)

    def bytes(self) -> List[UInt8]:
        return self.buf.copy()
