"""Tests for src/buffer.mojo: loading/saving, edits, undo/redo, randomised consistency."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1, CHANGES_MAX
from swap import write_bytes_atomic
from util import decode, to_str, bytes_to_str, decode_list, read_file, str_bytes, env_or, run_system


def text_of(b: TextBuffer) -> String:
    return to_str(b.all_text())


def saved(b: TextBuffer) -> String:
    return bytes_to_str(b.to_bytes())


def loaded(s: String) -> TextBuffer:
    var b = TextBuffer()
    b.load(decode(s))
    return b^


# ------------------------------------------------------------- load / save
def test_new_buffer_is_one_empty_line() raises:
    var b = TextBuffer()
    assert_equal(b.count(), 1)
    assert_equal(b.llen(0), 0)
    assert_false(b.modified)
    assert_equal(saved(b), "")


def test_load_splits_on_newlines() raises:
    var b = loaded("ab\ncd")
    assert_equal(b.count(), 2)
    assert_equal(b.llen(0), 2)
    assert_equal(b.llen(1), 2)
    assert_false(b.modified)


def test_roundtrip_with_final_newline() raises:
    var b = loaded("a\nb\n")
    assert_equal(b.count(), 3)  # trailing newline shows as a last empty line
    assert_equal(saved(b), "a\nb\n")


def test_roundtrip_without_final_newline() raises:
    var b = loaded("a\nb")
    assert_equal(saved(b), "a\nb")


def test_new_file_gets_final_newline() raises:
    var b = TextBuffer()
    _ = b.insert(0, 0, decode("x = 1"), 0, 0, 0)
    assert_equal(saved(b), "x = 1\n")


def test_file_with_newline_keeps_one_after_typing_on_last_line() raises:
    var b = loaded("a\n")
    _ = b.insert(1, 0, decode("b"), 1, 0, 0)
    assert_equal(saved(b), "a\nb\n")


def test_crlf_detected_and_preserved() raises:
    var b = loaded("a\r\nb\r\n")
    assert_true(b.crlf)
    assert_equal(b.llen(0), 1)  # the \r is not part of the line
    assert_equal(saved(b), "a\r\nb\r\n")
    _ = b.insert(0, 1, decode("\nX"), 0, 1, 0)
    assert_equal(saved(b), "a\r\nX\r\nb\r\n")


def test_lf_file_is_not_crlf() raises:
    var b = loaded("a\nb\n")
    assert_false(b.crlf)


def test_tabs_are_kept() raises:
    var b = loaded("\tx\n\t\ty\n")
    assert_equal(b.at(0, 0), 9)
    assert_equal(b.llen(1), 3)
    assert_true(b.use_tabs)
    assert_equal(saved(b), "\tx\n\t\ty\n")


def test_space_indented_file_does_not_use_tabs() raises:
    var b = loaded("def f():\n    pass\n    pass\n\tx\n")
    assert_false(b.use_tabs)


def test_unicode_roundtrip() raises:
    var s = String("s = \"日本語 🔥 café\"\n")
    assert_equal(saved(loaded(s)), s)


# ------------------------------------------------------------------- edits
def test_insert_single_line_returns_end() raises:
    var b = loaded("hello")
    var p = b.insert(0, 2, decode("XY"), 0, 2, 0)
    assert_equal(text_of(b), "heXYllo")
    assert_equal(p.r, 0)
    assert_equal(p.c, 4)
    assert_true(b.modified)


def test_insert_multiline_splits_line() raises:
    var b = loaded("hello")
    var p = b.insert(0, 2, decode("A\nB\nC"), 0, 2, 0)
    assert_equal(text_of(b), "heA\nB\nCllo")
    assert_equal(b.count(), 3)
    assert_equal(p.r, 2)
    assert_equal(p.c, 1)


def test_delete_within_line() raises:
    var b = loaded("hello world")
    var t = b.delete(0, 5, 0, 11, 0, 11, 0)
    assert_equal(to_str(t), " world")
    assert_equal(text_of(b), "hello")


def test_delete_across_lines_joins() raises:
    var b = loaded("one\ntwo\nthree")
    var t = b.delete(0, 2, 2, 3, 0, 2, 0)
    assert_equal(to_str(t), "e\ntwo\nthr")
    assert_equal(text_of(b), "onee")
    assert_equal(b.count(), 1)


def test_get_text_ranges() raises:
    var b = loaded("one\ntwo\nthree")
    assert_equal(to_str(b.get_text(0, 1, 0, 3)), "ne")
    assert_equal(to_str(b.get_text(0, 3, 1, 0)), "\n")
    assert_equal(to_str(b.get_text(1, 1, 2, 2)), "wo\nth")


def test_at_out_of_range() raises:
    var b = loaded("ab")
    assert_equal(b.at(0, 1), 98)
    assert_equal(b.at(0, 2), -1)
    assert_equal(b.at(5, 0), -1)
    assert_equal(b.at(0, -1), -1)


# --------------------------------------------------------------- undo/redo
def test_undo_nothing() raises:
    var b = loaded("x")
    var p = b.undo()
    assert_equal(p.r, -1)
    var q = b.redo()
    assert_equal(q.r, -1)


def test_undo_redo_insert_restores_text_and_cursor() raises:
    var b = loaded("hello")
    _ = b.insert(0, 5, decode(" world"), 0, 5, 0)
    var p = b.undo()
    assert_equal(text_of(b), "hello")
    assert_equal(p.r, 0)
    assert_equal(p.c, 5)  # cursor before the edit
    var q = b.redo()
    assert_equal(text_of(b), "hello world")
    assert_equal(q.c, 11)  # cursor after the re-applied insert


def test_undo_redo_delete() raises:
    var b = loaded("one\ntwo")
    _ = b.delete(0, 1, 1, 1, 1, 1, 0)
    assert_equal(text_of(b), "owo")
    var p = b.undo()
    assert_equal(text_of(b), "one\ntwo")
    assert_equal(p.r, 1)
    assert_equal(p.c, 1)
    var q = b.redo()
    assert_equal(text_of(b), "owo")
    assert_equal(q.r, 0)
    assert_equal(q.c, 1)


def test_same_group_contiguous_inserts_merge_into_one_undo() raises:
    var b = loaded("")
    _ = b.insert(0, 0, decode("a"), 0, 0, 7)
    _ = b.insert(0, 1, decode("b"), 0, 1, 7)
    _ = b.insert(0, 2, decode("c"), 0, 2, 7)
    assert_equal(len(b.undos), 1)
    var p = b.undo()
    assert_equal(text_of(b), "")
    assert_equal(p.c, 0)
    _ = b.redo()
    assert_equal(text_of(b), "abc")


def test_group_zero_never_merges() raises:
    var b = loaded("")
    _ = b.insert(0, 0, decode("a"), 0, 0, 0)
    _ = b.insert(0, 1, decode("b"), 0, 1, 0)
    _ = b.undo()
    assert_equal(text_of(b), "a")


def test_group_spans_delete_and_insert() raises:
    # replacing a selection = delete + insert in one group -> one undo step
    var b = loaded("hello world")
    _ = b.delete(0, 6, 0, 11, 0, 11, 3)
    _ = b.insert(0, 6, decode("there"), 0, 6, 3)
    assert_equal(text_of(b), "hello there")
    _ = b.undo()
    assert_equal(text_of(b), "hello world")
    _ = b.redo()
    assert_equal(text_of(b), "hello there")


def test_different_groups_undo_separately() raises:
    var b = loaded("")
    _ = b.insert(0, 0, decode("a"), 0, 0, 1)
    _ = b.insert(0, 1, decode("b"), 0, 1, 2)
    _ = b.undo()
    assert_equal(text_of(b), "a")
    _ = b.undo()
    assert_equal(text_of(b), "")


def test_new_edit_clears_redo() raises:
    var b = loaded("x")
    _ = b.insert(0, 1, decode("y"), 0, 1, 0)
    _ = b.undo()
    _ = b.insert(0, 1, decode("z"), 0, 1, 0)
    var q = b.redo()
    assert_equal(q.r, -1)
    assert_equal(text_of(b), "xz")


# ------------------------------------------------- randomised consistency
struct Rng:
    var s: Int

    def __init__(out self, seed: Int):
        self.s = seed

    def next(mut self, n: Int) -> Int:
        """Deterministic LCG; returns a value in [0, n)."""
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.s >> 8) % n


def pos_at(b: TextBuffer, off: Int) -> Pos:
    """Row/col of a flat offset where each newline counts as one character."""
    var left = off
    for r in range(b.count()):
        var n = b.llen(r)
        if left <= n:
            return Pos(r, left)
        left -= n + 1
    return Pos(b.count() - 1, b.llen(b.count() - 1))


def same(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def test_random_edits_match_reference_and_undo_redo_roundtrip() raises:
    var rng = Rng(20261110)
    var b = loaded("def main():\n    print(1)\n")
    var model = b.all_text()          # naive model: flat list of codepoints
    var snaps = List[List[Int]]()   # reference text after each step
    snaps.append(model.copy())
    var alphabet = decode("ab \n\tz日")
    var steps = 400
    for _ in range(steps):
        var do_insert = len(model) == 0 or rng.next(100) < 60
        if do_insert:
            var off = rng.next(len(model) + 1)
            var n = 1 + rng.next(6)
            var t = List[Int]()
            for _ in range(n):
                t.append(alphabet[rng.next(len(alphabet))])
            var p = pos_at(b, off)
            var e = b.insert(p.r, p.c, t, p.r, p.c, 0)
            for k in range(n):
                model.insert(off + k, t[k])
            var want_end = pos_at(b, off + n)
            assert_equal(e.r, want_end.r)
            assert_equal(e.c, want_end.c)
        else:
            var a = rng.next(len(model))
            var z = min(len(model), a + 1 + rng.next(8))
            var p1 = pos_at(b, a)
            var p2 = pos_at(b, z)
            var removed = b.delete(p1.r, p1.c, p2.r, p2.c, p1.r, p1.c, 0)
            var want = List[Int]()
            for k in range(a, z):
                want.append(model[k])
            assert_true(same(removed, want), "deleted text differs from reference")
            for _ in range(z - a):
                _ = model.pop(a)
        assert_true(same(b.all_text(), model), "buffer diverged from reference model")
        snaps.append(model.copy())
    # undo everything, checking every intermediate state
    var i = steps
    while i > 0:
        var p = b.undo()
        assert_true(p.r >= 0)
        i -= 1
        assert_true(same(b.all_text(), snaps[i]), "undo produced wrong text")
    assert_equal(b.undo().r, -1)
    # redo everything
    while i < steps:
        var p = b.redo()
        assert_true(p.r >= 0)
        i += 1
        assert_true(same(b.all_text(), snaps[i]), "redo produced wrong text")
    assert_equal(b.redo().r, -1)



# ------------------------------------------------------- loading from bytes
def same_as_codepoint_load(bytes: List[UInt8], what: String) raises:
    """load_bytes must give exactly what the original codepoint loader gives."""
    var a = TextBuffer()
    a.load(decode_list(bytes))
    var b = TextBuffer()
    b.load_bytes(bytes)
    assert_equal(to_str(b.all_text()), to_str(a.all_text()), what + ": text")
    assert_equal(b.crlf, a.crlf, what + ": crlf")
    assert_equal(b.use_tabs, a.use_tabs, what + ": tabs")
    assert_equal(b.eol_at_eof, a.eol_at_eof, what + ": final newline")
    assert_equal(b.count(), a.count(), what + ": lines")
    assert_equal(bytes_to_str(b.to_bytes()), bytes_to_str(a.to_bytes()), what + ": saved bytes")
    assert_false(b.modified)


def test_load_bytes_plain_cases() raises:
    same_as_codepoint_load(str_bytes(""), "empty")
    same_as_codepoint_load(str_bytes("one"), "no final newline")
    same_as_codepoint_load(str_bytes("one\ntwo\n"), "lf")
    same_as_codepoint_load(str_bytes("one\r\ntwo\r\n"), "crlf")
    same_as_codepoint_load(str_bytes("one\r\ntwo\nthree\n"), "mixed endings")
    same_as_codepoint_load(str_bytes("a\rb\n"), "lone carriage return")
    same_as_codepoint_load(str_bytes("\tx\n\ty\n  z\n"), "tabs")
    same_as_codepoint_load(str_bytes("café 日本 🔥\n"), "multi-byte")
    same_as_codepoint_load(str_bytes("\n\n\n"), "blank lines")


def test_load_bytes_keeps_the_file_round_trip() raises:
    var src = String("def f():\r\n\treturn \"é😀\"\r\n")
    var b = TextBuffer()
    b.load_bytes(str_bytes(src))
    assert_true(b.crlf)
    assert_true(b.use_tabs)
    assert_equal(b.count(), 3)
    assert_equal(to_str(b.line(1)), "\treturn \"é😀\"")
    assert_equal(bytes_to_str(b.to_bytes()), src)


def test_load_bytes_with_invalid_utf8() raises:
    var cases = List[List[UInt8]]()
    var c1: List[UInt8] = [97, 0xFF, 98, 10]                 # stray byte
    var c2: List[UInt8] = [97, 0xE6, 0x97]                   # cut off at the end
    var c3: List[UInt8] = [0xC0, 0x80, 10]                   # overlong
    var c4: List[UInt8] = [0xED, 0xA0, 0x80, 10]             # surrogate
    var c5: List[UInt8] = [0xF5, 0x80, 0x80, 0x80]           # beyond Unicode
    var c6: List[UInt8] = [0x80, 0x80]                       # continuation bytes alone
    var c7: List[UInt8] = [0xE6, 0x97, 0xA5, 0xC3, 10]       # good char, then a broken one
    var c8: List[UInt8] = [0xF4, 0x90, 0x80, 0x80]           # above U+10FFFF
    cases.append(c1.copy())
    cases.append(c2.copy())
    cases.append(c3.copy())
    cases.append(c4.copy())
    cases.append(c5.copy())
    cases.append(c6.copy())
    cases.append(c7.copy())
    cases.append(c8.copy())
    # not UTF-8: read as Latin-1, one character per byte, and written back unchanged
    for i in range(len(cases)):
        var t = TextBuffer()
        t.load_bytes(cases[i])
        assert_equal(t.encoding, ENC_LATIN1, "case " + String(i + 1))
        assert_false(t.bom)
        var back = t.to_bytes()
        assert_equal(len(back), len(cases[i]), "case " + String(i + 1) + ": length")
        for k in range(len(back)):
            assert_equal(Int(back[k]), Int(cases[i][k]), "case " + String(i + 1) + ": byte " + String(k))
    var b = TextBuffer()
    b.load_bytes(c1)
    assert_equal(b.at(0, 0), 97)
    assert_equal(b.at(0, 1), 0xFF)                      # ÿ, not a replacement mark
    assert_equal(b.at(0, 2), 98)


def test_load_bytes_random_input() raises:
    var r = Rng(77)
    var pieces: List[String] = ["a", "xyz", " ", "\t", "\n", "\r\n", "\r", "é", "日", "🔥", "    ", "#"]
    for round in range(200):
        var bytes = List[UInt8]()
        var n = r.next(60)
        for _ in range(n):
            if r.next(25) == 0:
                bytes.append(UInt8(128 + r.next(128)))        # sometimes a broken byte
            else:
                for q in str_bytes(pieces[r.next(len(pieces))]):
                    bytes.append(q)
        var probe = TextBuffer()
        probe.load_bytes(bytes)
        if probe.encoding == ENC_UTF8:
            same_as_codepoint_load(bytes, "round " + String(round))
        else:
            # read as Latin-1: writing and reading again gives the same text. (Left out:
            # inputs with carriage returns, where "\r\r\n" in an LF file is written back
            # as "\r\n" - a line-ending matter that has nothing to do with the encoding.)
            var has_cr = False
            for q in bytes:
                if q == 13:
                    has_cr = True
            if has_cr:
                continue
            var again = TextBuffer()
            again.load_bytes(probe.to_bytes())
            assert_equal(again.encoding, ENC_LATIN1, "round " + String(round))
            assert_equal(to_str(again.all_text()), to_str(probe.all_text()), "round " + String(round))
            assert_equal(bytes_to_str(again.to_bytes()), bytes_to_str(probe.to_bytes()), "round " + String(round))


def test_load_bytes_resets_undo_and_lexer_cache() raises:
    var b = TextBuffer()
    b.load_bytes(str_bytes("one\n"))
    _ = b.insert(0, 0, decode("x"), 0, 0, 0)
    assert_true(b.modified)
    b.load_bytes(str_bytes("two\nthree\n"))
    assert_false(b.modified)
    assert_equal(b.undo().r, -1)
    assert_equal(len(b.lstate), 1)
    assert_equal(to_str(b.line(0)), "two")


def test_read_file_returns_exact_bytes() raises:
    var dir = env_or("TMPDIR", "/tmp")
    var path = dir + "/turbomojo-readfile-test.bin"
    var data = List[UInt8]()
    for i in range(200000):
        data.append(UInt8((i * 7 + i // 256) % 256))          # includes NUL bytes
    assert_true(write_bytes_atomic(path, data))
    var got = read_file(path)
    assert_equal(len(got), len(data))
    var same = True
    for i in range(len(data)):
        if got[i] != data[i]:
            same = False
            break
    assert_true(same, "bytes differ")
    _ = run_system("rm -f '" + path + "'")
    assert_equal(len(read_file(path)), 0)                     # missing file
    _ = run_system(": > '" + path + "'")
    assert_equal(len(read_file(path)), 0)                     # empty file
    _ = run_system("rm -f '" + path + "'")
    # a file that reports size 0 but has content
    assert_true(len(read_file("/proc/self/status")) > 0)



# ---------------------------------------------------------------- encodings
def same_bytes(a: List[UInt8], b: List[UInt8], what: String) raises:
    assert_equal(len(a), len(b), what + ": length")
    for k in range(len(a)):
        assert_equal(Int(a[k]), Int(b[k]), what + ": byte " + String(k))


def test_utf8_bom_is_kept() raises:
    var src: List[UInt8] = [0xEF, 0xBB, 0xBF, 104, 105, 10]
    var b = TextBuffer()
    b.load_bytes(src)
    assert_true(b.bom)
    assert_equal(b.encoding, ENC_UTF8)
    assert_equal(to_str(b.all_text()), "hi\n")           # the mark is not part of the text
    assert_equal(b.llen(0), 2)
    same_bytes(b.to_bytes(), src, "unchanged")
    _ = b.insert(0, 0, decode("é"), 0, 0, 0)
    var want: List[UInt8] = [0xEF, 0xBB, 0xBF, 0xC3, 0xA9, 104, 105, 10]
    same_bytes(b.to_bytes(), want, "after an edit")
    # tools get the text without the mark
    assert_equal(bytes_to_str(b.text_bytes()), "éhi\n")
    var only: List[UInt8] = [0xEF, 0xBB, 0xBF]
    b.load_bytes(only)
    assert_true(b.bom)
    assert_equal(b.count(), 1)
    same_bytes(b.to_bytes(), only, "only a mark")
    var plain = TextBuffer()
    plain.load_bytes(str_bytes("hi\n"))
    assert_false(plain.bom)
    assert_equal(len(plain.to_bytes()), 3)
    # a mark in the middle of the text is an ordinary character
    var mid: List[UInt8] = [97, 0xEF, 0xBB, 0xBF, 98]
    plain.load_bytes(mid)
    assert_false(plain.bom)
    assert_equal(plain.llen(0), 3)


def test_latin1_file_round_trips_and_shows_real_characters() raises:
    var src: List[UInt8] = [99, 97, 102, 0xE9, 32, 0xFC, 98, 101, 114, 13, 10, 0xA9, 13, 10]   # "café über" CRLF "©"
    var b = TextBuffer()
    b.load_bytes(src)
    assert_equal(b.encoding, ENC_LATIN1)
    assert_true(b.crlf)
    assert_equal(to_str(b.line(0)), "café über")
    assert_equal(to_str(b.line(1)), "©")
    same_bytes(b.to_bytes(), src, "unchanged")
    _ = b.insert(1, 1, decode(" ñ"), 0, 0, 0)            # still Latin-1
    assert_true(b.latin1_ok())
    var want: List[UInt8] = [99, 97, 102, 0xE9, 32, 0xFC, 98, 101, 114, 13, 10, 0xA9, 32, 0xF1, 13, 10]
    same_bytes(b.to_bytes(), want, "edited")
    # the language server is given UTF-8
    assert_equal(bytes_to_str(b.text_bytes()), "café über\r\n© ñ\r\n")


def test_latin1_buffer_with_other_characters_is_written_as_utf8() raises:
    var src: List[UInt8] = [0xE9, 10]
    var b = TextBuffer()
    b.load_bytes(src)
    assert_equal(b.encoding, ENC_LATIN1)
    _ = b.insert(0, 1, decode("日"), 0, 0, 0)
    assert_false(b.latin1_ok())
    assert_equal(bytes_to_str(b.to_bytes()), "é日\n")    # nothing is lost


def test_mixed_line_endings_are_noticed() raises:
    var b = TextBuffer()
    b.load_bytes(str_bytes("a\r\nb\nc\n"))
    assert_true(b.mixed_eol)
    assert_false(b.crlf)                                 # the majority decides what is written
    assert_equal(bytes_to_str(b.to_bytes()), "a\nb\nc\n")
    b.load_bytes(str_bytes("a\r\nb\r\nc\n"))
    assert_true(b.mixed_eol)
    assert_true(b.crlf)
    b.load_bytes(str_bytes("a\r\nb\r\n"))
    assert_false(b.mixed_eol)
    b.load_bytes(str_bytes("a\nb\n"))
    assert_false(b.mixed_eol)
    b.load(decode("a\r\nb\n"))
    assert_true(b.mixed_eol)
    b.load(decode("plain"))
    assert_false(b.mixed_eol)
    assert_false(b.bom)
    assert_equal(b.encoding, ENC_UTF8)



# ------------------------------------------------- change recording (for LSP)
def chg(b: TextBuffer) -> String:
    """The recorded changes as "sl:sc-el:ec=text" separated by "|"."""
    var out = String("")
    for c in b.changes:
        if out.byte_length() > 0:
            out += "|"
        out += String(c.sl) + ":" + String(c.sc) + "-" + String(c.el) + ":" + String(c.ec) + "=" + to_str(c.text)
    return out


def test_edits_are_recorded_as_ranges_in_utf16_units() raises:
    var b = TextBuffer()
    b.load(decode("a🔥b\nsecond"))
    _ = b.insert(0, 1, decode("x"), 0, 0, 0)
    assert_equal(len(b.changes), 0)                      # nobody is following yet
    b.start_tracking()
    _ = b.insert(0, 3, decode("Z"), 0, 0, 0)             # after "ax🔥": the emoji counts as two
    assert_equal(chg(b), "0:4-0:4=Z")
    _ = b.delete(0, 2, 0, 3, 0, 0, 0)                    # remove the emoji
    assert_equal(chg(b), "0:4-0:4=Z|0:2-0:4=")
    _ = b.delete(0, 3, 1, 2, 0, 0, 0)                    # across the line break
    assert_equal(chg(b), "0:4-0:4=Z|0:2-0:4=|0:3-1:2=")
    assert_equal(to_str(b.all_text()), "axZcond")
    _ = b.undo()                                         # undo is an edit like any other
    assert_true(chg(b).endswith("|0:3-0:3=b\nse"), chg(b))
    var taken = b.take_changes()
    assert_equal(len(taken), 4)
    assert_equal(len(b.changes), 0)
    b.stop_tracking()
    _ = b.insert(0, 0, decode("q"), 0, 0, 0)
    assert_equal(len(b.changes), 0)


def test_recording_gives_up_when_there_is_too_much() raises:
    var b = TextBuffer()
    b.load(decode("x"))
    b.start_tracking()
    for _ in range(CHANGES_MAX):
        _ = b.insert(0, 0, decode("y"), 0, 0, 0)
    assert_false(b.changes_lost)
    _ = b.insert(0, 0, decode("y"), 0, 0, 0)
    assert_true(b.changes_lost)
    assert_equal(len(b.changes), 0)
    b.start_tracking()
    assert_false(b.changes_lost)
    b.load(decode("another text"))                       # loading replaces everything
    assert_true(b.changes_lost)
    assert_true(b.track)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
