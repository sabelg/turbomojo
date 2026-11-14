"""Tests for the Mojo syntax highlighter (src/highlight.mojo)."""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from highlight import (
    Highlighter, C_TEXT, C_KW, C_TYPE, C_CMT, C_STR, C_NUM, C_DECO, C_SYM, C_BUILTIN,
    C_SELF, C_DEF,
)
from util import decode


struct Lexed(Movable):
    var cls: List[Int]
    var state: Int

    def __init__(out self, var cls: List[Int], state: Int):
        self.cls = cls^
        self.state = state


def lex(s: String, state: Int = 0) -> Lexed:
    var h = Highlighter()
    var cls = List[Int]()
    var st = h.line(decode(s), state, cls)
    return Lexed(cls^, st)


def all_are(cls: List[Int], a: Int, b: Int, want: Int) -> Bool:
    for i in range(a, b):
        if cls[i] != want:
            return False
    return True


def test_one_class_per_codepoint() raises:
    var r = lex("x = \"日本\"  # ok")
    assert_equal(len(r.cls), 14)
    assert_equal(len(lex("").cls), 0)


def test_def_line() raises:
    #        0123456789012345678901
    var r = lex("def foo(x: Int) -> Int:")
    assert_true(all_are(r.cls, 0, 3, C_KW))      # def
    assert_true(all_are(r.cls, 4, 7, C_DEF))     # foo
    assert_equal(r.cls[7], C_SYM)                # (
    assert_equal(r.cls[8], C_TEXT)               # x
    assert_true(all_are(r.cls, 11, 14, C_TYPE))  # Int
    assert_true(all_are(r.cls, 19, 22, C_TYPE))  # Int
    assert_equal(r.cls[22], C_SYM)               # :
    assert_equal(r.state, 0)


def test_struct_and_trait_names() raises:
    var r = lex("struct Foo(Copyable, Movable):")
    assert_true(all_are(r.cls, 0, 6, C_KW))
    assert_true(all_are(r.cls, 7, 10, C_DEF))
    assert_true(all_are(r.cls, 11, 19, C_TYPE))
    var t = lex("trait Shape:")
    assert_true(all_are(t.cls, 6, 11, C_DEF))


def test_comptime_name() raises:
    var r = lex("comptime WIDTH = 4")
    assert_true(all_are(r.cls, 0, 8, C_KW))
    assert_true(all_are(r.cls, 9, 14, C_DEF))
    assert_equal(r.cls[17], C_NUM)


def test_keywords_builtins_self() raises:
    var r = lex("if self.ok and not None: print(len(x))")
    assert_true(all_are(r.cls, 0, 2, C_KW))        # if
    assert_true(all_are(r.cls, 3, 7, C_SELF))      # self
    assert_true(all_are(r.cls, 8, 10, C_TEXT))     # ok (member name)
    assert_true(all_are(r.cls, 11, 14, C_KW))      # and
    assert_true(all_are(r.cls, 15, 18, C_KW))      # not
    assert_true(all_are(r.cls, 19, 23, C_KW))      # None
    assert_true(all_are(r.cls, 25, 30, C_BUILTIN)) # print
    assert_true(all_are(r.cls, 31, 34, C_BUILTIN)) # len


def test_keyword_inside_identifier_is_not_keyword() raises:
    var r = lex("define = format_if + selfish")
    assert_true(all_are(r.cls, 0, 6, C_TEXT))
    assert_true(all_are(r.cls, 9, 18, C_TEXT))
    assert_true(all_are(r.cls, 21, 28, C_TEXT))


def test_comment() raises:
    var r = lex("x = 1  # set x")
    assert_equal(r.cls[4], C_NUM)
    assert_true(all_are(r.cls, 7, 14, C_CMT))
    var full = lex("# def not code \"str\"")
    assert_true(all_are(full.cls, 0, len(full.cls), C_CMT))


def test_hash_inside_string_is_not_comment() raises:
    #        0123456789012
    var r = lex("s = \"a # b\" + t")
    assert_true(all_are(r.cls, 4, 11, C_STR))
    assert_equal(r.cls[12], C_SYM)   # +
    assert_equal(r.cls[14], C_TEXT)  # t


def test_strings_and_escapes() raises:
    var r = lex("a = 'it\\'s' + \"q\\\"q\"")
    # 'it\'s' spans 4..10 inclusive
    assert_true(all_are(r.cls, 4, 11, C_STR))
    assert_equal(r.cls[12], C_SYM)
    assert_true(all_are(r.cls, 14, 20, C_STR))
    assert_equal(r.state, 0)


def test_unterminated_string_runs_to_end_of_line_only() raises:
    var r = lex("s = \"oops")
    assert_true(all_are(r.cls, 4, 9, C_STR))
    assert_equal(r.state, 0)


def test_triple_quote_on_one_line() raises:
    var r = lex("\"\"\"doc\"\"\" x")
    assert_true(all_are(r.cls, 0, 9, C_STR))
    assert_equal(r.cls[10], C_TEXT)
    assert_equal(r.state, 0)


def test_triple_quote_across_lines() raises:
    var a = lex("    \"\"\"Start of doc")
    assert_equal(a.state, 1)
    assert_true(all_are(a.cls, 4, len(a.cls), C_STR))
    var b = lex("def not_code(): # still doc", a.state)
    assert_equal(b.state, 1)
    assert_true(all_are(b.cls, 0, len(b.cls), C_STR))
    var blank = lex("", b.state)
    assert_equal(blank.state, 1)
    var c = lex("end.\"\"\" + x", blank.state)
    assert_equal(c.state, 0)
    assert_true(all_are(c.cls, 0, 7, C_STR))
    assert_equal(c.cls[8], C_SYM)
    assert_equal(c.cls[10], C_TEXT)


def test_single_quote_triple_uses_its_own_state() raises:
    var a = lex("x = '''abc")
    assert_equal(a.state, 2)
    # a double-quote triple does not close it
    var b = lex("\"\"\" still", a.state)
    assert_equal(b.state, 2)
    var c = lex("''' done", b.state)
    assert_equal(c.state, 0)
    assert_true(all_are(c.cls, 0, 3, C_STR))
    assert_equal(c.cls[4], C_TEXT)


def test_string_reopens_after_close_on_same_line() raises:
    var a = lex("\"\"\"a")
    var b = lex("b\"\"\" + \"\"\"c", a.state)
    assert_equal(b.state, 1)   # second triple string left open
    assert_equal(b.cls[5], C_SYM)
    assert_true(all_are(b.cls, 7, 11, C_STR))


def test_numbers() raises:
    var r = lex("a = 42 + 0xFF + 1_000 + 3.14")
    assert_true(all_are(r.cls, 4, 6, C_NUM))
    assert_true(all_are(r.cls, 9, 13, C_NUM))
    assert_true(all_are(r.cls, 16, 21, C_NUM))
    assert_true(all_are(r.cls, 24, 28, C_NUM))


def test_digits_inside_identifier_are_not_numbers() raises:
    var r = lex("x1 = vec3d")
    assert_true(all_are(r.cls, 0, 2, C_TEXT))
    assert_true(all_are(r.cls, 5, 10, C_TEXT))


def test_decorator() raises:
    var r = lex("@fieldwise_init")
    assert_true(all_are(r.cls, 0, 15, C_DECO))
    var p = lex("    @staticmethod  # c")
    assert_true(all_are(p.cls, 4, 17, C_DECO))
    assert_true(all_are(p.cls, 19, 22, C_CMT))


def test_string_prefix() raises:
    var r = lex("p = r\"\\d+\"")
    assert_true(all_are(r.cls, 4, 10, C_STR))


def test_symbols_and_spaces() raises:
    var r = lex("a += [1]")
    assert_equal(r.cls[1], C_TEXT)   # space stays text
    assert_equal(r.cls[2], C_SYM)
    assert_equal(r.cls[3], C_SYM)
    assert_equal(r.cls[5], C_SYM)
    assert_equal(r.cls[6], C_NUM)
    assert_equal(r.cls[7], C_SYM)


def test_escaped_quotes_inside_triple_docstring_and_mojo12_types() raises:
    var a = lex("\"\"\"has \\\"\"\" inside")
    assert_equal(a.state, 1)
    assert_true(all_are(a.cls, 0, len(a.cls), C_STR))
    var b = lex("still \\\"\"\" and close\"\"\" x", a.state)
    assert_equal(b.state, 0)
    assert_true(all_are(b.cls, 0, 23, C_STR))
    assert_equal(b.cls[24], C_TEXT)
    var gpu_t = lex("var t: TileTensor")
    assert_true(all_are(gpu_t.cls, 7, 17, C_TYPE))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
