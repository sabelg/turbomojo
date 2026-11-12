"""Fuzz harnesses (P9-01): random input, seeded so a failure can be replayed, each with a
property to keep rather than only "it did not crash":

- the key parser (term.Terminal.feed): the same events however the bytes are split;
- JSON: generated documents parse, dump and parse again to the same dump; mutated
  ones never crash the parser, and nesting is limited;
- the rope (buffer.TextBuffer): random edits agree with a plain model after every
  step, undoing all of them gives the start back and redoing them the end;
- the VT parser (vt.VtTerm): random output and resizes keep the cursor on the screen
  and the screen its size.

FUZZ_ITERS scales the work (the gate's default is small) and FUZZ_SEED picks the
random start; scripts/fuzz.sh runs long passes with new seeds and prints the seed of a
failure. Every failure message names the seed."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from term import Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, EV_FOCUS
from json import json_parse, json_parse_bytes, json_quote, JSON_MAX_DEPTH
from buffer import TextBuffer
from vt import VtTerm
from util import env_or, decode, to_str


struct Rng(Copyable, Movable):
    """xorshift64*: small, fast and the same everywhere for a seed."""
    var s: UInt64

    def __init__(out self, seed: Int):
        self.s = UInt64(seed) * 0x9E3779B97F4A7C15 + 1

    def next(mut self) -> UInt64:
        self.s ^= self.s >> 12
        self.s ^= self.s << 25
        self.s ^= self.s >> 27
        return self.s * 0x2545F4914F6CDD1D

    def below(mut self, n: Int) -> Int:
        if n <= 1:
            return 0
        return Int(self.next() % UInt64(n))

    def chance(mut self, percent: Int) -> Bool:
        return self.below(100) < percent


def iters(default: Int) -> Int:
    try:
        return max(1, atol(env_or("FUZZ_ITERS", String(default))))
    except:
        return default


def seed() -> Int:
    try:
        return atol(env_or("FUZZ_SEED", "20261112"))
    except:
        return 20261112


# ------------------------------------------------------------------ key parser
def random_input(mut r: Rng) -> List[UInt8]:
    """Bytes as a terminal sends them, and some it should not: escape sequences (CSI,
    SS3, mouse, kitty, paste brackets), UTF-8, control bytes, and garbage."""
    var out = List[UInt8]()
    var parts = 1 + r.below(12)
    for _ in range(parts):
        var kind = r.below(9)
        if kind == 0:
            for c in "\x1b[".as_bytes():
                out.append(c)
            for _ in range(r.below(4)):
                for c in String(r.below(300)).as_bytes():
                    out.append(c)
                if r.chance(70):
                    out.append(59)                 # ;
            out.append(UInt8(64 + r.below(63)))    # the final byte (some are invalid)
        elif kind == 1:
            for c in "\x1bO".as_bytes():
                out.append(c)
            out.append(UInt8(65 + r.below(26)))
        elif kind == 2:
            var m = "\x1b[<" + String(r.below(70)) + ";" + String(r.below(300)) + ";" + String(r.below(100)) + ("M" if r.chance(50) else "m")
            for c in m.as_bytes():
                out.append(c)
        elif kind == 3:
            var k = "\x1b[" + String(r.below(60000)) + ";" + String(1 + r.below(16)) + "u"
            for c in k.as_bytes():
                out.append(c)
        elif kind == 4:
            for c in "\x1b[200~".as_bytes():
                out.append(c)
            for _ in range(r.below(20)):
                out.append(UInt8(32 + r.below(95)))
            if r.chance(80):
                for c in "\x1b[201~".as_bytes():
                    out.append(c)
        elif kind == 5:
            var cps = [0xE9, 0x20AC, 0x1F525, 0x4E2D]
            for c in chr(cps[r.below(4)]).as_bytes():
                out.append(c)
        elif kind == 6:
            out.append(UInt8(r.below(32)))         # control bytes, Esc among them
        elif kind == 7:
            out.append(UInt8(r.below(256)))        # anything
        else:
            out.append(UInt8(32 + r.below(95)))
    return out^


def events_text(evs: List[Event]) -> String:
    var s = String("")
    for e in evs:
        s += String(e.kind) + ":" + String(e.key) + ":" + String(e.mx) + ":" + String(e.my) + ":" + String(e.button) + ":" + String(e.pressed) + ":" + String(e.drag) + ":" + String(len(e.text)) + "|"
    return s^


def test_key_parser_split_anywhere() raises:
    var sd = seed()
    var r = Rng(sd)
    for n in range(iters(300)):
        var data = random_input(r)
        var whole = Terminal()
        var a = whole.feed(data, False)
        for e in whole.feed(List[UInt8](), True):
            a.append(e.copy())
        var split = Terminal()
        var b = List[Event]()
        var i = 0
        while i < len(data):
            var k = min(len(data), i + 1 + r.below(6))
            var chunk = List[UInt8]()
            for j in range(i, k):
                chunk.append(data[j])
            for e in split.feed(chunk, False):
                b.append(e.copy())
            i = k
        for e in split.feed(List[UInt8](), True):
            b.append(e.copy())
        assert_equal(events_text(b), events_text(a), "seed " + String(sd) + ", input " + String(n))
        for e in a:
            assert_true(e.kind == EV_KEY or e.kind == EV_MOUSE or e.kind == EV_PASTE or e.kind == EV_FOCUS, "seed " + String(sd))


def test_plain_text_is_one_key_per_character() raises:
    var sd = seed()
    var r = Rng(sd + 1)
    for _ in range(iters(100)):
        var s = String("")
        for _ in range(1 + r.below(40)):
            s += chr(32 + r.below(95))
        var t = Terminal()
        var evs = t.feed(List[UInt8](s.as_bytes()), False)
        assert_equal(len(evs), s.byte_length(), "seed " + String(sd) + ": " + s)


# ------------------------------------------------------------------------ JSON
def random_json(mut r: Rng, depth: Int) -> String:
    var k = r.below(8) if depth < 6 else r.below(5)
    if k == 0:
        return "null"
    if k == 1:
        return "true" if r.chance(50) else "false"
    if k == 2:
        var n = Int(r.below(2000000)) - 1000000
        return String(n)
    if k == 3:
        var parts = ["a", "b c", "\"q\"", "back\\slash", "tab\there", "line\nfeed", "é", "€", "🔥", "\x01"]
        var s = String("")
        for _ in range(r.below(5)):
            s += String(parts[r.below(10)])
        return json_quote(s)
    if k == 4:
        return String(r.below(1000)) + "." + String(r.below(1000))
    if k == 5 or k == 6:
        var s = String("[")
        for i in range(r.below(5)):
            s += ("," if i > 0 else String("")) + random_json(r, depth + 1)
        return s + "]"
    var o = String("{")
    for i in range(r.below(5)):
        o += ("," if i > 0 else String("")) + json_quote("k" + String(i)) + ":" + random_json(r, depth + 1)
    return o + "}"


def test_json_round_trip_and_mutations() raises:
    var sd = seed()
    var r = Rng(sd + 2)
    for n in range(iters(300)):
        var text = random_json(r, 0)
        var doc = json_parse(text)
        assert_true(doc.ok, "seed " + String(sd) + " doc " + String(n) + ": " + doc.error + " in " + text)
        var once = doc.dump(0)
        var twice = json_parse(once).dump(0)
        assert_equal(twice, once, "seed " + String(sd) + " doc " + String(n))
        # a few random bytes changed, dropped or doubled: no crash, a usable document
        var b = List[UInt8](text.as_bytes())
        for _ in range(1 + r.below(4)):
            if len(b) == 0:
                break
            var at = r.below(len(b))
            var how = r.below(3)
            if how == 0:
                b[at] = UInt8(r.below(256))
            elif how == 1:
                _ = b.pop(at)
            else:
                b.insert(at, b[at])
        var m = json_parse_bytes(b)
        _ = m.dump(0)
        _ = m.str(m.get(0, "k0"), "")
    # nesting beyond the limit is refused, not a crash
    var deep = String("[") * (JSON_MAX_DEPTH + 50)
    assert_false(json_parse(deep).ok)


# ------------------------------------------------------------------------ rope
def offset_of(model: List[Int], row: Int, col: Int) -> Int:
    var r = 0
    var i = 0
    while i < len(model) and r < row:
        if model[i] == 10:
            r += 1
        i += 1
    return i + col


def lines_of(model: List[Int]) -> List[Int]:
    """The length of each line of the model."""
    var out = List[Int]()
    var n = 0
    for c in model:
        if c == 10:
            out.append(n)
            n = 0
        else:
            n += 1
    out.append(n)
    return out^


def random_piece(mut r: Rng) -> List[Int]:
    var cps = [97, 98, 32, 10, 0xE9, 0x20AC, 0x1F525, 9]
    var out = List[Int]()
    for _ in range(r.below(30)):
        out.append(cps[r.below(8)])
    if r.chance(5):
        for _ in range(3000):                 # sometimes a big one (rope nodes split)
            out.append(97 + r.below(26) if r.chance(95) else 10)
    return out^


def test_rope_agrees_with_a_model() raises:
    var sd = seed()
    var r = Rng(sd + 3)
    var start = List[Int]()
    for k in range(3000):
        for c in ("line " + String(k)).as_bytes():
            start.append(Int(c))
        start.append(10)
    var b = TextBuffer()
    b.load(start)
    var model = start.copy()
    var ops = min(iters(200), 400)
    for n in range(ops):
        var ls = lines_of(model)
        var r1 = r.below(len(ls))
        var c1 = r.below(ls[r1] + 1)
        if r.chance(55):
            var piece = random_piece(r)
            if len(piece) == 0:
                piece.append(120)
            _ = b.insert(r1, c1, piece, r1, c1, n + 1)
            var at = offset_of(model, r1, c1)
            for j in range(len(piece)):
                model.insert(at + j, piece[j])
        else:
            var r2 = min(len(ls) - 1, r1 + r.below(4))
            var c2 = r.below(ls[r2] + 1)
            if r2 == r1 and c2 < c1:
                var t = c1
                c1 = c2
                c2 = t
            var a = offset_of(model, r1, c1)
            var z = offset_of(model, r2, c2)
            if z <= a:
                continue
            _ = b.delete(r1, c1, r2, c2, r1, c1, n + 1)
            for _ in range(z - a):
                _ = model.pop(a)
        if n % 25 == 0 or n == ops - 1:
            assert_equal(to_str(b.all_text()), to_str(model), "seed " + String(sd) + " after edit " + String(n))
            assert_equal(b.count(), len(lines_of(model)), "seed " + String(sd))
    var end = model.copy()
    while b.undo().r >= 0:
        pass
    assert_equal(to_str(b.all_text()), to_str(start), "seed " + String(sd) + ": undo all")
    while b.redo().r >= 0:
        pass
    assert_equal(to_str(b.all_text()), to_str(end), "seed " + String(sd) + ": redo all")


# ------------------------------------------------------------------ VT parser
def test_vt_parser_keeps_its_screen() raises:
    var sd = seed()
    var r = Rng(sd + 4)
    var t = VtTerm()
    assert_true(t.open(40, 12))
    var cols = 40
    var rows = 12
    for n in range(iters(300)):
        var data = random_input(r)                 # (the same mix: CSI, OSC-like, UTF-8, garbage)
        if r.chance(20):
            for c in ("\x1b]0;title " + String(n) + "\x07").as_bytes():
                data.append(c)
        if r.chance(10):
            for c in "\x1b[?1049h".as_bytes():
                data.append(c)
        t.write(data)
        if r.chance(5):
            cols = 1 + r.below(120)
            rows = 1 + r.below(50)
            t.resize(cols, rows)
        t.update()
        assert_true(t.cursor_x >= 0 and t.cursor_x <= t.cols, "seed " + String(sd) + " step " + String(n) + ": x " + String(t.cursor_x))
        assert_true(t.cursor_y >= 0 and t.cursor_y < t.rows, "seed " + String(sd) + " step " + String(n) + ": y " + String(t.cursor_y))
        assert_equal(t.cols, cols)
        assert_equal(t.rows, rows)
        assert_equal(len(t.cp), cols * rows, "seed " + String(sd))
        assert_equal(len(t.text().split("\n")), rows + 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
