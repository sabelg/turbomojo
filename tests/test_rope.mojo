"""Tests for src/rope.mojo: every operation is checked against a naive list of codepoints."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from rope import Rope, MAX_LEAF, MAX_KIDS
from util import decode, to_str, encode_cp


# ---------------------------------------------------------------- reference
def ref_line_start(m: List[Int], row: Int) -> Int:
    if row <= 0:
        return 0
    var seen = 0
    for i in range(len(m)):
        if m[i] == 10:
            seen += 1
            if seen == row:
                return i + 1
    return len(m)


def ref_newlines(m: List[Int]) -> Int:
    var n = 0
    for c in m:
        if c == 10:
            n += 1
    return n


def ref_u16(m: List[Int], upto: Int) -> Int:
    var n = 0
    for i in range(min(upto, len(m))):
        n += 2 if m[i] >= 0x10000 else 1
    return n


def ref_bytes(m: List[Int]) -> Int:
    var b = List[UInt8]()
    for c in m:
        encode_cp(c, b)
    return len(b)


def same(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def agree(r: Rope, m: List[Int], what: String) raises:
    """The rope and the model describe the same text, and the rope is structurally sound."""
    assert_equal(r.check(), "", what)
    assert_equal(r.len_chars(), len(m), what + ": length")
    assert_true(same(r.to_cps(), m), what + ": content differs")
    assert_equal(r.newlines(), ref_newlines(m), what + ": newline count")
    assert_equal(r.len_bytes(), ref_bytes(m), what + ": byte length")
    assert_equal(r.len_utf16(), ref_u16(m, len(m)), what + ": utf-16 length")


struct Rng:
    var s: Int

    def __init__(out self, seed: Int):
        self.s = seed

    def next(mut self, n: Int) -> Int:
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.s >> 8) % n


def random_text(mut rng: Rng, n: Int) -> List[Int]:
    # ASCII, newlines, 2-, 3- and 4-byte characters
    var alphabet = decode("abcdefgh  \n\n\tXYZé日本🔥𝄞_0")
    var out = List[Int]()
    for _ in range(n):
        out.append(alphabet[rng.next(len(alphabet))])
    return out^


# -------------------------------------------------------------------- basics
def test_empty() raises:
    var r = Rope()
    assert_equal(r.check(), "")
    assert_equal(r.len_chars(), 0)
    assert_equal(r.len_bytes(), 0)
    assert_equal(r.line_count(), 1)
    assert_equal(r.line_start(0), 0)
    assert_equal(r.line_len(0), 0)
    assert_equal(len(r.line(0)), 0)
    assert_equal(r.char_at(0), -1)
    assert_equal(r.line_of(0), 0)
    assert_equal(r.offset(5, 5), 0)
    assert_equal(r.depth(), 1)
    r.delete(0, 10)                     # deleting from nothing is harmless
    assert_equal(r.len_chars(), 0)


def test_small_inserts_and_reads() raises:
    var r = Rope()
    r.insert(0, decode("world"))
    r.insert(0, decode("hello "))
    r.insert(r.len_chars(), decode("!\nsecond line\n"))
    assert_equal(to_str(r.to_cps()), "hello world!\nsecond line\n")
    assert_equal(r.line_count(), 3)
    assert_equal(to_str(r.line(0)), "hello world!")
    assert_equal(to_str(r.line(1)), "second line")
    assert_equal(to_str(r.line(2)), "")
    assert_equal(r.line_start(1), 13)
    assert_equal(r.line_end(0), 12)
    assert_equal(r.line_len(1), 11)
    assert_equal(r.char_at(4), 111)
    assert_equal(r.char_at(12), 10)
    assert_equal(to_str(r.slice(6, 11)), "world")
    assert_equal(r.line_of(0), 0)
    assert_equal(r.line_of(12), 0)      # the newline itself belongs to line 0
    assert_equal(r.line_of(13), 1)
    assert_equal(r.line_of(999), 2)
    assert_equal(r.offset(1, 3), 16)
    assert_equal(r.offset(1, 99), 24)   # column clamped to the line
    assert_equal(r.offset(99, 0), 25)   # row clamped to the last line
    assert_equal(r.check(), "")


def test_insert_positions_are_clamped() raises:
    var r = Rope()
    r.insert(-5, decode("b"))
    r.insert(999, decode("c"))
    r.insert(0, decode("a"))
    assert_equal(to_str(r.to_cps()), "abc")
    r.insert(1, List[Int]())            # empty insert
    assert_equal(to_str(r.to_cps()), "abc")


def test_delete_ranges() raises:
    var r = Rope()
    r.load_cps(decode("0123456789"))
    r.delete(3, 6)
    assert_equal(to_str(r.to_cps()), "0126789")
    r.delete(-4, 2)
    assert_equal(to_str(r.to_cps()), "26789")
    r.delete(3, 999)
    assert_equal(to_str(r.to_cps()), "267")
    r.delete(2, 2)
    r.delete(5, 3)
    assert_equal(to_str(r.to_cps()), "267")
    r.delete(0, 3)
    assert_equal(r.len_chars(), 0)
    assert_equal(r.check(), "")


def test_multibyte_characters_count_as_one() raises:
    var r = Rope()
    r.load_cps(decode("aé日🔥z"))
    assert_equal(r.len_chars(), 5)
    assert_equal(r.len_bytes(), 1 + 2 + 3 + 4 + 1)
    assert_equal(r.len_utf16(), 6)                  # the emoji is a surrogate pair
    assert_equal(r.char_at(3), 0x1F525)
    r.insert(2, decode("X"))
    assert_equal(to_str(r.to_cps()), "aéX日🔥z")
    r.delete(3, 5)
    assert_equal(to_str(r.to_cps()), "aéXz")


def test_utf16_conversions() raises:
    var r = Rope()
    r.load_cps(decode("a🔥b\n日🔥"))
    #  chars:  a 🔥 b \n 日 🔥      utf16 before each: 0 1 3 4 5 6, end 8
    var want = List[Int]()
    for v in [0, 1, 3, 4, 5, 6, 8]:
        want.append(v)
    for i in range(7):
        assert_equal(r.to_utf16(i), want[i])
        assert_equal(r.from_utf16(want[i]), i)
    assert_equal(r.from_utf16(2), 1)                # middle of the first emoji -> that emoji
    assert_equal(r.from_utf16(7), 5)
    assert_equal(r.from_utf16(99), 6)
    assert_equal(r.to_utf16(99), 8)
    assert_equal(r.to_utf16(-1), 0)


def test_lines_with_and_without_final_newline() raises:
    var a = Rope()
    a.load_cps(decode("one\ntwo"))
    assert_equal(a.line_count(), 2)
    assert_equal(to_str(a.line(1)), "two")
    assert_equal(a.line_end(1), 7)
    var b = Rope()
    b.load_cps(decode("one\ntwo\n"))
    assert_equal(b.line_count(), 3)
    assert_equal(to_str(b.line(2)), "")
    assert_equal(b.line_start(2), 8)
    assert_equal(b.line_start(3), 8)                # past the end: clamped
    assert_equal(len(b.line(7)), 0)
    assert_equal(len(b.line(-1)), 0)
    var c = Rope()
    c.load_cps(decode("\n\n\n"))
    assert_equal(c.line_count(), 4)
    for i in range(4):
        assert_equal(c.line_len(i), 0)
        assert_equal(c.line_start(i), i if i < 3 else 3)


# ------------------------------------------------------------- tree behaviour
def test_large_load_builds_a_balanced_tree() raises:
    var rng = Rng(7)
    var m = random_text(rng, 200000)
    var r = Rope()
    r.load_cps(m)
    agree(r, m, "after load")
    assert_true(r.depth() >= 3, "a text this size needs several levels")
    assert_true(r.depth() <= 6, "but stays shallow: depth " + String(r.depth()))
    assert_true(r.leaf_count() > 200)


def test_one_huge_insert_into_a_small_rope() raises:
    var rng = Rng(11)
    var m = decode("start|end")
    var r = Rope()
    r.load_cps(m)
    var big = random_text(rng, 120000)
    r.insert(6, big)
    for k in range(len(big)):
        m.insert(6 + k, big[k])
    agree(r, m, "after a 120k insert")
    assert_equal(to_str(r.slice(0, 6)), "start|")
    assert_equal(to_str(r.slice(r.len_chars() - 3, r.len_chars())), "end")


def test_typing_one_character_at_a_time() raises:
    var r = Rope()
    var m = List[Int]()
    var text = decode("def main():\n    print(\"日本語 🔥\")\n")
    for round in range(120):
        for c in text:
            var one = List[Int]()
            one.append(c)
            r.insert(r.len_chars(), one)
            m.append(c)
    agree(r, m, "after typing")
    assert_equal(r.line_count(), 241)
    assert_equal(to_str(r.line(239)), "    print(\"日本語 🔥\")")


def test_deleting_everything_in_pieces_returns_to_one_leaf() raises:
    var rng = Rng(3)
    var m = random_text(rng, 50000)
    var r = Rope()
    r.load_cps(m)
    while len(m) > 0:
        var a = rng.next(len(m))
        var b = min(len(m), a + 1 + rng.next(3000))
        r.delete(a, b)
        for _ in range(b - a):
            _ = m.pop(a)
        assert_equal(r.check(), "")
    assert_equal(r.len_chars(), 0)
    assert_equal(r.depth(), 1)
    assert_equal(r.leaf_count(), 1)
    r.insert(0, decode("fresh"))
    assert_equal(to_str(r.to_cps()), "fresh")


def test_arena_reuses_freed_nodes() raises:
    var rng = Rng(5)
    var r = Rope()
    var m = random_text(rng, 40000)
    r.load_cps(m)
    var high = len(r.leaf)
    for _ in range(30):
        r.delete(1000, 30000)
        r.insert(1000, random_text(rng, 29000))
    assert_true(len(r.leaf) < high * 3, "node storage must not grow without bound")
    assert_equal(r.check(), "")


def test_very_long_single_line() raises:
    var r = Rope()
    var m = List[Int]()
    for i in range(100000):
        m.append(97 + i % 26)
    r.load_cps(m)
    assert_equal(r.line_count(), 1)
    assert_equal(r.line_len(0), 100000)
    assert_equal(r.char_at(99999), 97 + 99999 % 26)
    r.insert(50000, decode("\n"))
    assert_equal(r.line_count(), 2)
    assert_equal(r.line_start(1), 50001)
    assert_equal(r.line_len(0), 50000)
    assert_equal(r.check(), "")


# ------------------------------------------------------ randomised comparison
def check_queries(r: Rope, m: List[Int], mut rng: Rng, what: String) raises:
    var rows = ref_newlines(m) + 1
    assert_equal(r.line_count(), rows, what)
    for _ in range(12):
        var row = rng.next(rows)
        var ls = ref_line_start(m, row)
        var le = ref_line_start(m, row + 1) - 1 if row + 1 < rows else len(m)
        assert_equal(r.line_start(row), ls, what + ": line_start(" + String(row) + ")")
        assert_equal(r.line_end(row), le, what + ": line_end")
        assert_equal(r.line_len(row), le - ls, what + ": line_len")
        var want = List[Int]()
        for i in range(ls, le):
            want.append(m[i])
        assert_true(same(r.line(row), want), what + ": line text")
        var col = rng.next(le - ls + 1)
        assert_equal(r.offset(row, col), ls + col, what + ": offset")
        assert_equal(r.line_of(ls + col), row, what + ": line_of")
    if len(m) > 0:
        for _ in range(12):
            var i = rng.next(len(m))
            assert_equal(r.char_at(i), m[i], what + ": char_at")
            var u = ref_u16(m, i)
            assert_equal(r.to_utf16(i), u, what + ": to_utf16")
            assert_equal(r.from_utf16(u), i, what + ": from_utf16")
            var j = min(len(m), i + rng.next(200))
            var want = List[Int]()
            for k in range(i, j):
                want.append(m[k])
            assert_true(same(r.slice(i, j), want), what + ": slice")


def run_random(seed: Int, steps: Int, big_every: Int) raises:
    var rng = Rng(seed)
    var r = Rope()
    var m = List[Int]()
    for step in range(steps):
        var what = "seed " + String(seed) + " step " + String(step)
        var roll = rng.next(100)
        if len(m) == 0 or roll < 55:
            var n = 1 + rng.next(40)
            if big_every > 0 and step % big_every == 0:
                n = 500 + rng.next(4000)        # a paste larger than several leaves
            var t = random_text(rng, n)
            var at = rng.next(len(m) + 1)
            r.insert(at, t)
            for k in range(len(t)):
                m.insert(at + k, t[k])
        else:
            var a = rng.next(len(m))
            var span = 1 + rng.next(60)
            if big_every > 0 and step % big_every == 1:
                span = 300 + rng.next(5000)     # a deletion that removes whole subtrees
            var b = min(len(m), a + span)
            r.delete(a, b)
            for _ in range(b - a):
                _ = m.pop(a)
        assert_equal(r.check(), "", what)
        assert_equal(r.len_chars(), len(m), what)
        if step % 20 == 0:
            agree(r, m, what)
            check_queries(r, m, rng, what)
    agree(r, m, "seed " + String(seed) + " final")
    check_queries(r, m, rng, "seed " + String(seed) + " final")


def test_random_small_edits() raises:
    run_random(20261110, 3000, 0)


def test_random_edits_with_large_pastes_and_cuts() raises:
    run_random(424242, 1500, 25)


def test_random_edits_other_seeds() raises:
    for seed in [1, 2, 3, 99, 31337]:
        run_random(seed, 400, 40)


def test_copy_is_independent() raises:
    var a = Rope()
    a.load_cps(decode("shared text"))
    var b = a.copy()
    b.insert(0, decode("changed "))
    assert_equal(to_str(a.to_cps()), "shared text")
    assert_equal(to_str(b.to_cps()), "changed shared text")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
