"""E2E Test Suite for Feature #28:
Vim Mojo text objects ia/aa for arguments/parameters, if/af/ii/ai for indentation blocks,
and Ex commands :set, :g/:v, :norm, :vimgrep/:cdo, and split navigation Ctrl-W =/>/</H/J/K/L.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from buffer import TextBuffer, Pos
from vim_motion import vim_object, obj_bracket, obj_word, obj_quote, obj_para, obj_arg, obj_func, obj_indent, VimSpan
from vim_cmd import parse_ex, parse_sub, ex_is, VimEx, VimSub, parse_set, parse_global, parse_vimgrep
from signals import own_pid
from util import decode, to_str, env_or, run_system, shell_quote


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f28-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f28_case1_bracket_text_objects_inner_and_outer() raises:
    """Verify obj_bracket and obj_arg compute exact spans for i(/a( and ia/aa."""
    var buf = TextBuffer()
    buf.load(decode("call(param1, param2)"))

    # Cursor on 'param1' at column 6
    var inner = obj_bracket(buf, 0, 6, True, 0)
    assert_true(inner.ok)
    assert_equal(inner.r1, 0)
    assert_equal(inner.c1, 5)  # right after '('
    assert_equal(inner.r2, 0)
    assert_equal(inner.c2, 19) # right before ')'

    var outer = obj_bracket(buf, 0, 6, False, 0)
    assert_true(outer.ok)
    assert_equal(outer.r1, 0)
    assert_equal(outer.c1, 4)  # on '('
    assert_equal(outer.r2, 0)
    assert_equal(outer.c2, 20) # after ')'

    # Mojo argument text objects: ia and aa
    var buf_arg = TextBuffer()
    buf_arg.load(decode("def add(x: Int, y: Int):"))
    var ia1 = vim_object(buf_arg, 0, 9, True, 97)  # 'a'
    assert_true(ia1.ok)
    assert_equal(ia1.c1, 8)
    assert_equal(ia1.c2, 14)  # 'x: Int'

    var aa1 = vim_object(buf_arg, 0, 9, False, 97)
    assert_true(aa1.ok)
    assert_equal(aa1.c1, 8)
    assert_equal(aa1.c2, 16)  # 'x: Int, '

    var ia2 = vim_object(buf_arg, 0, 17, True, 97)  # second arg
    assert_true(ia2.ok)
    assert_equal(ia2.c1, 16)
    assert_equal(ia2.c2, 22)  # 'y: Int'

    var aa2 = vim_object(buf_arg, 0, 17, False, 97)
    assert_true(aa2.ok)
    assert_equal(aa2.c1, 14)  # ', y: Int'
    assert_equal(aa2.c2, 22)


def test_tier1_f28_case2_bracket_text_objects_square_and_brace() raises:
    """Verify obj_bracket and function/indent text objects if/af/ii/ai."""
    var buf = TextBuffer()
    buf.load(decode("items = [10, 20]; map = {a: 1}"))

    # Inside [10, 20] (cursor at col 10)
    var inner_sq = obj_bracket(buf, 0, 10, True, 1)
    assert_true(inner_sq.ok)
    assert_equal(inner_sq.c1, 9)
    assert_equal(inner_sq.c2, 15)

    # Inside {a: 1} (cursor at col 26)
    var inner_br = obj_bracket(buf, 0, 26, True, 2)
    assert_true(inner_br.ok)
    assert_equal(inner_br.c1, 25)
    assert_equal(inner_br.c2, 29)

    # Function text objects: if and af
    var buf_fn = TextBuffer()
    buf_fn.load(decode("def compute():\n    var a = 1\n    var b = 2"))
    var if1 = vim_object(buf_fn, 1, 6, True, 102)  # 'f'
    assert_true(if1.ok)
    assert_equal(if1.r1, 1)  # inner body line 1..2
    assert_equal(if1.r2, 2)

    var af1 = vim_object(buf_fn, 1, 6, False, 102)  # 'f'
    assert_true(af1.ok)
    assert_equal(af1.r1, 0)  # outer includes def line 0..2
    assert_equal(af1.r2, 2)

    # Indentation block text object: ii
    var ii1 = vim_object(buf_fn, 1, 6, True, 105)  # 'i'
    assert_true(ii1.ok)
    assert_equal(ii1.r1, 1)
    assert_equal(ii1.r2, 2)


def test_tier1_f28_case3_word_text_objects_inner_and_outer() raises:
    """Verify obj_word distinguishes iw (word only) from aw (word with trailing whitespace)."""
    var line = decode("hello   world")

    # Cursor on 'hello' at col 2
    var iw = obj_word(line, 0, 2, True, False)
    assert_true(iw.ok)
    assert_equal(iw.c1, 0)
    assert_equal(iw.c2, 5)

    var aw = obj_word(line, 0, 2, False, False)
    assert_true(aw.ok)
    assert_equal(aw.c1, 0)
    assert_equal(aw.c2, 8)  # Includes 3 trailing spaces


def test_tier1_f28_case4_ex_command_substitute_parsing() raises:
    """Verify parse_sub parses /pattern/replacement/flags."""
    var sub = parse_sub(decode("/foo/bar/gi"))
    assert_true(sub.ok)
    assert_equal(to_str(sub.pat), "foo")
    assert_equal(to_str(sub.rep), "bar")
    assert_true(sub.all)    # 'g' flag: all matches on the line
    assert_true(sub.icase)  # 'i' flag: ignore case


def test_tier1_f28_case5_ex_command_address_range_parsing() raises:
    """Verify parse_ex parses whole buffer range '%' and explicit line ranges '10,20'."""
    # '%' range on 100-line buffer (0..99)
    var ex_all = parse_ex(decode("%d"), 5, 99, 0, 0)
    assert_true(ex_all.ok)
    assert_true(ex_all.has_range)
    assert_equal(ex_all.r1, 0)
    assert_equal(ex_all.r2, 99)
    assert_equal(ex_all.name, "d")

    # Explicit '10,20' range (1-indexed in Vim, 0-indexed in engine)
    var ex_range = parse_ex(decode("10,20y"), 5, 99, 0, 0)
    assert_true(ex_range.ok)
    assert_true(ex_range.has_range)
    assert_equal(ex_range.r1, 9)
    assert_equal(ex_range.r2, 19)
    assert_equal(ex_range.name, "y")


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f28_bound1_quote_text_objects_unclosed() raises:
    """Verify obj_quote handles unclosed quotes or missing quotes safely without crashing."""
    var line_unclosed = decode("var msg = \"unclosed string")
    var span_unclosed = obj_quote(line_unclosed, 0, 15, True, 34)  # 34 = '"'
    # Should safely return not ok
    assert_false(span_unclosed.ok)

    var line_none = decode("no quotes here")
    var span_none = obj_quote(line_none, 0, 3, True, 34)
    assert_false(span_none.ok)


def test_tier2_f28_bound2_text_object_cursor_outside_delimiters() raises:
    """Verify calling obj_bracket when outside any bracket pair returns no span."""
    var buf = TextBuffer()
    buf.load(decode("plain line without any delimiters"))

    var span = obj_bracket(buf, 0, 10, True, 0)
    assert_false(span.ok)
    assert_equal(span.r1, 0)
    assert_equal(span.c1, 0)


def test_tier2_f28_bound3_ex_substitute_escaped_delimiters() raises:
    """Verify parse_sub handles escaped delimiters in patterns and replacements."""
    var sub = parse_sub(decode("/a\\/b/c\\/d/"))
    assert_true(sub.ok)
    assert_equal(to_str(sub.pat), "a/b")
    assert_equal(to_str(sub.rep), "c/d")


def test_tier2_f28_bound4_ex_command_bang_and_prefix_matching() raises:
    """Verify ex_is matches shortest command prefixes and identifies bang modifier '!'' and :set commands."""
    assert_true(ex_is("w", "write", 1))
    assert_true(ex_is("wr", "write", 1))
    assert_true(ex_is("write", "write", 1))
    assert_false(ex_is("x", "write", 1))

    assert_true(ex_is("sp", "split", 2))
    assert_true(ex_is("split", "split", 2))
    assert_false(ex_is("s", "split", 2))  # Shortest is 2 ("sp")

    var ex_bang = parse_ex(decode("q!"), 0, 10, 0, 0)
    assert_true(ex_bang.ok)
    assert_true(ex_bang.bang)
    assert_equal(ex_bang.name, "q")

    # Ex command :set
    assert_true(ex_is("se", "set", 2))
    assert_true(ex_is("set", "set", 2))
    var ex_set = parse_ex(decode("set number"), 0, 10, 0, 0)
    assert_true(ex_set.ok)
    assert_equal(ex_set.name, "set")
    assert_equal(ex_set.arg, "number")


def test_tier2_f28_bound5_paragraph_text_object_buffer_edges() raises:
    """Verify obj_para at the first and last line of buffer bounds paragraphs safely."""
    var buf = TextBuffer()
    buf.load(decode("first block\nstill first\n\nsecond block\n"))

    # Paragraph at line 0
    var p0 = obj_para(buf, 0, True)
    assert_true(p0.ok)
    assert_equal(p0.r1, 0)
    assert_equal(p0.r2, 1)

    # Paragraph at line 3
    var p3 = obj_para(buf, 3, True)
    assert_true(p3.ok)
    assert_equal(p3.r1, 3)
    assert_equal(p3.r2, 3)


def test_tier2_f28_bound6_multiline_obj_arg_and_ex_parsers() raises:
    """Verify multi-line ia/aa argument text objects and :set / :g / :v / :vimgrep command parsers."""
    var buf = TextBuffer()
    buf.load(decode('def kernel(\n    x: Int,\n    label: String = "a, b",\n    dims: Tuple[Int, Int] = (1, 2),\n) -> None:\n    pass'))

    # Cursor on first param `x: Int` (row 1, col 5)
    var ia0 = vim_object(buf, 1, 5, True, 97)
    assert_true(ia0.ok)
    assert_equal(to_str(buf.get_text(ia0.r1, ia0.c1, ia0.r2, ia0.c2)), "x: Int")
    var aa0 = vim_object(buf, 1, 5, False, 97)
    assert_true(aa0.ok)
    assert_equal(aa0.r1, 1)
    assert_equal(aa0.c1, 4)
    assert_equal(aa0.r2, 2)
    assert_equal(aa0.c2, 4)

    # Cursor on second param containing `,` inside string literal
    var ia1 = vim_object(buf, 2, 10, True, 97)
    assert_true(ia1.ok)
    assert_equal(to_str(buf.get_text(ia1.r1, ia1.c1, ia1.r2, ia1.c2)), 'label: String = "a, b"')

    # Cursor on third param containing `,` inside nested brackets + trailing comma before `)`
    var ia2 = vim_object(buf, 3, 8, True, 97)
    assert_true(ia2.ok)
    assert_equal(to_str(buf.get_text(ia2.r1, ia2.c1, ia2.r2, ia2.c2)), "dims: Tuple[Int, Int] = (1, 2)")

    # :set parser
    var sopts = parse_set("nu rnu nowrap ic list ts=4 sw=2")
    assert_equal(len(sopts), 7)
    assert_true(sopts[0].ok and sopts[0].key == "number" and sopts[0].bool_val)
    assert_true(sopts[2].ok and sopts[2].key == "wrap" and not sopts[2].bool_val)
    assert_true(sopts[5].ok and sopts[5].key == "tabstop" and sopts[5].int_val == 4)
    assert_true(sopts[6].ok and sopts[6].key == "shiftwidth" and sopts[6].int_val == 2)

    # :g and :v parser
    var gl = parse_global(decode("/TODO/d"), False)
    assert_true(gl.ok and not gl.invert)
    assert_equal(to_str(gl.pat), "TODO")
    assert_equal(gl.cmd, "d")

    var vgl = parse_global(decode("/keep/s/a/b/g"), True)
    assert_true(vgl.ok and vgl.invert)
    assert_equal(vgl.cmd, "s/a/b/g")

    # :vimgrep parser
    var vg = parse_vimgrep(decode("/fn\\s\\+main/gj src/*.mojo tests/*.mojo"))
    assert_true(vg.ok and vg.all and vg.nojump)
    assert_equal(to_str(vg.pat), "fn\\s\\+main")
    assert_equal(len(vg.files), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
