"""Tests for src/util.mojo: UTF-8, display widths, strings, paths, base64."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from util import (
    decode, decode_list, encode_cp, to_str, slice_str, str_bytes, bytes_to_str,
    char_width, str_width, cp_len, pad_right, is_digit, is_alpha, is_ident, lower,
    lower_str, fuzzy_score, shell_quote, strip_ansi, join_path, dirname, basename,
    stem, normalize_path, abs_path, base64, wrap_plain,
)


def bytes_of(vals: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


# ------------------------------------------------------------------ UTF-8
def test_decode_ascii() raises:
    var cps = decode("abc")
    assert_equal(len(cps), 3)
    assert_equal(cps[0], 97)
    assert_equal(cps[2], 99)


def test_decode_multibyte() raises:
    # é U+00E9 (2 bytes), 日 U+65E5 (3 bytes), 🔥 U+1F525 (4 bytes)
    var cps = decode("é日🔥")
    assert_equal(len(cps), 3)
    assert_equal(cps[0], 0xE9)
    assert_equal(cps[1], 0x65E5)
    assert_equal(cps[2], 0x1F525)


def test_decode_invalid_bytes_become_replacement() raises:
    # lone continuation byte, then a truncated 3-byte sequence at the end
    var cps = decode_list(bytes_of([0x80, 0x41, 0xE6, 0x97]))
    assert_equal(cps[0], 0xFFFD)
    assert_equal(cps[1], 0x41)
    assert_equal(cps[2], 0xFFFD)


def test_encode_lengths() raises:
    var b = List[UInt8]()
    encode_cp(0x41, b)
    assert_equal(len(b), 1)
    encode_cp(0xE9, b)
    assert_equal(len(b), 3)
    encode_cp(0x65E5, b)
    assert_equal(len(b), 6)
    encode_cp(0x1F525, b)
    assert_equal(len(b), 10)
    # exact bytes of U+1F525: F0 9F 94 A5
    assert_equal(Int(b[6]), 0xF0)
    assert_equal(Int(b[7]), 0x9F)
    assert_equal(Int(b[8]), 0x94)
    assert_equal(Int(b[9]), 0xA5)


def test_roundtrip() raises:
    var s = String("héllo 日本語 🔥 ok")
    assert_equal(to_str(decode(s)), s)
    assert_equal(bytes_to_str(str_bytes(s)), s)


def test_slice_str_clamps() raises:
    var cps = decode("hello")
    assert_equal(slice_str(cps, 1, 3), "el")
    assert_equal(slice_str(cps, -5, 2), "he")
    assert_equal(slice_str(cps, 3, 99), "lo")
    assert_equal(slice_str(cps, 4, 2), "")


# ------------------------------------------------------------------ widths
def test_char_width_basic() raises:
    assert_equal(char_width(65), 1)
    assert_equal(char_width(0xE9), 1)
    assert_equal(char_width(0x2550), 1)  # box drawing ═
    assert_equal(char_width(0x25A0), 1)  # ■


def test_char_width_wide() raises:
    assert_equal(char_width(0x65E5), 2)   # 日
    assert_equal(char_width(0xAC00), 2)   # 가
    assert_equal(char_width(0x3042), 2)   # あ
    assert_equal(char_width(0xFF21), 2)   # fullwidth A
    assert_equal(char_width(0x1F525), 2)  # 🔥
    assert_equal(char_width(0x1F600), 2)  # 😀
    assert_equal(char_width(0x20000), 2)  # CJK ext B


def test_char_width_zero() raises:
    assert_equal(char_width(0x301), 0)    # combining acute
    assert_equal(char_width(0x200D), 0)   # zero width joiner
    assert_equal(char_width(0xFE0F), 0)   # variation selector 16


def test_str_width() raises:
    assert_equal(cp_len("abc"), 3)
    assert_equal(cp_len("日本語"), 6)
    assert_equal(str_width(decode("café")), 4)
    assert_equal(cp_len("a🔥b"), 4)


def test_pad_right() raises:
    assert_equal(pad_right("ab", 5), "ab   ")
    assert_equal(pad_right("abcdef", 3), "abc")
    # a wide char that would straddle the limit is dropped and padded
    assert_equal(pad_right("a日", 2), "a ")
    assert_equal(pad_right("日本", 4), "日本")
    assert_equal(cp_len(pad_right("日本語テスト", 7)), 7)


# ------------------------------------------------------------------ chars
def test_char_classes() raises:
    assert_true(is_digit(48))
    assert_true(is_digit(57))
    assert_false(is_digit(47))
    assert_true(is_alpha(95))       # underscore
    assert_true(is_alpha(0xE9))     # é counts as identifier char
    assert_false(is_alpha(45))
    assert_true(is_ident(51))
    assert_false(is_ident(32))
    assert_equal(lower(65), 97)
    assert_equal(lower(97), 97)
    assert_equal(lower(48), 48)
    assert_equal(lower_str("HeLLo 1"), "hello 1")


# ------------------------------------------------------------------ fuzzy
def test_fuzzy_score() raises:
    assert_equal(fuzzy_score("Window: Tile", "zzz"), -1)
    assert_true(fuzzy_score("anything", "") > 0)
    # substring beats scattered subsequence
    assert_true(fuzzy_score("Window: Tile", "tile") > fuzzy_score("Toggle line", "tile"))
    # earlier substring beats later substring
    assert_true(fuzzy_score("tile windows", "tile") > fuzzy_score("windows tile", "tile"))
    # case-insensitive
    assert_true(fuzzy_score("Go To Line", "goto") > 0)
    # order matters for subsequences
    assert_equal(fuzzy_score("abc", "cba"), -1)
    # exact / basename match and path/camelCase word boundaries
    assert_equal(fuzzy_score("app.mojo  src/app.mojo", "app.mojo"), 2200)
    assert_true(fuzzy_score("src/window_draw.mojo", "wd") > fuzzy_score("src/shadowed.mojo", "wd"))
    assert_true(fuzzy_score("openQuickPicker", "oqp") > fuzzy_score("opaque", "oqp"))


# ------------------------------------------------------------------ shell / ansi
def test_shell_quote() raises:
    assert_equal(shell_quote("plain"), "'plain'")
    assert_equal(shell_quote("has space"), "'has space'")
    assert_equal(shell_quote("it's"), "'it'\\''s'")
    assert_equal(shell_quote("$HOME;rm"), "'$HOME;rm'")


def test_strip_ansi() raises:
    var line = decode("\x1b[1;31merror\x1b[0m: bad\r")
    assert_equal(to_str(strip_ansi(line)), "error: bad")
    assert_equal(to_str(strip_ansi(decode("no codes"))), "no codes")


# ------------------------------------------------------------------ paths
def test_join_path() raises:
    assert_equal(join_path("/a/b", "c.mojo"), "/a/b/c.mojo")
    assert_equal(join_path("/a/b/", "c.mojo"), "/a/b/c.mojo")
    assert_equal(join_path("/a/b", "/abs.mojo"), "/abs.mojo")
    assert_equal(join_path("", "c.mojo"), "c.mojo")


def test_dirname_basename_stem() raises:
    assert_equal(dirname("/a/b/c.mojo"), "/a/b")
    assert_equal(dirname("/c.mojo"), "/")
    assert_equal(dirname("c.mojo"), ".")
    assert_equal(basename("/a/b/c.mojo"), "c.mojo")
    assert_equal(basename("c.mojo"), "c.mojo")
    assert_equal(stem("/a/b/c.mojo"), "c")
    assert_equal(stem("archive.tar.gz"), "archive.tar")
    assert_equal(stem("noext"), "noext")
    assert_equal(stem(".hidden"), ".hidden")


def test_normalize_and_abs() raises:
    assert_equal(normalize_path("/a/./b/../c//d"), "/a/c/d")
    assert_equal(normalize_path("/../.."), "/")
    assert_equal(normalize_path("/"), "/")
    assert_equal(abs_path("/home/u", "x/../y.mojo"), "/home/u/y.mojo")
    assert_equal(abs_path("/home/u", "/etc/z"), "/etc/z")


# ------------------------------------------------------------------ base64
def test_base64_rfc4648_vectors() raises:
    assert_equal(base64(str_bytes("")), "")
    assert_equal(base64(str_bytes("f")), "Zg==")
    assert_equal(base64(str_bytes("fo")), "Zm8=")
    assert_equal(base64(str_bytes("foo")), "Zm9v")
    assert_equal(base64(str_bytes("foob")), "Zm9vYg==")
    assert_equal(base64(str_bytes("fooba")), "Zm9vYmE=")
    assert_equal(base64(str_bytes("foobar")), "Zm9vYmFy")



def test_decode_keeps_text_after_a_bad_byte() raises:
    # a Latin-1 "é" (0xE9) looks like the start of a three-byte sequence; the two
    # characters after it must not be swallowed
    var b: List[UInt8] = [99, 97, 102, 0xE9, 32, 110, 10]
    var want: List[Int] = [99, 97, 102, 0xFFFD, 32, 110, 10]
    assert_equal(to_str(decode_list(b)), to_str(want))
    var b2: List[UInt8] = [0xC3, 65, 0xF0, 0x9F, 66, 0xE2, 0x82]
    var want2: List[Int] = [0xFFFD, 65, 0xFFFD, 0xFFFD, 66, 0xFFFD, 0xFFFD]
    assert_equal(to_str(decode_list(b2)), to_str(want2))
    var good: List[UInt8] = [0xC3, 0xA9, 0xE6, 0x97, 0xA5, 0xF0, 0x9F, 0x94, 0xA5]
    var want3: List[Int] = [0xE9, 0x65E5, 0x1F525]
    assert_equal(to_str(decode_list(good)), to_str(want3))



def joined(lines: List[String]) -> String:
    var out = String("")
    for i in range(len(lines)):
        out += ("|" if i > 0 else "") + lines[i]
    return out


def test_wrap_plain() raises:
    assert_equal(joined(wrap_plain("one two three four", 9)), "one two|three|four")
    assert_equal(joined(wrap_plain("abcdefghijkl", 5)), "abcde|fghij|kl")          # a long word is cut
    assert_equal(joined(wrap_plain("first\n\nsecond line", 20)), "first||second line")
    assert_equal(joined(wrap_plain("text\n```mojo\ncode()\n```\nmore", 20)), "text|code()|more")
    assert_equal(joined(wrap_plain("tail\n\n\n", 20)), "tail")
    assert_equal(joined(wrap_plain("", 20)), "")
    assert_equal(joined(wrap_plain("日本語 テキスト", 4)), "日本語|テキスト")
    for l in wrap_plain("a quite long sentence that has to be broken several times over", 11):
        assert_true(cp_len(l) <= 11, l)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
