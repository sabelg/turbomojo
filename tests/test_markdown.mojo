"""Tests for the Markdown renderer (src/markdown.mojo)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from markdown import *
from highlight import Highlighter, C_KW, C_STR, C_TEXT, C_CMT
from util import decode, to_str, char_width, cp_len


def render(text: String, width: Int) -> List[MdLine]:
    return md_render(text, width, Highlighter())


def plain(text: String, width: Int) -> String:
    return md_plain(render(text, width))


def styles(line: MdLine) -> String:
    """One letter per character: . text, B bold, I italic, C code, H heading, L link,
    D dim, K code block."""
    var out = String("")
    for s in line.st:
        if s == MD_TEXT:
            out += "."
        elif s == MD_BOLD:
            out += "B"
        elif s == MD_ITALIC:
            out += "I"
        elif s == MD_CODE:
            out += "C"
        elif s == MD_HEAD:
            out += "H"
        elif s == MD_LINK:
            out += "L"
        elif s == MD_DIM:
            out += "D"
        else:
            out += "K"
    return out


# ------------------------------------------------------------------- inline
def test_inline_emphasis_and_code() raises:
    var l = render("a **bold** and *it* and `co de` end", 80)
    assert_equal(len(l), 1)
    assert_equal(to_str(l[0].cps), "a bold and it and co de end")
    assert_equal(styles(l[0]), "..BBBB.....II.....CCCCC....")
    var u = render("__strong__ _soft_ snake_case_name 2*3*4", 80)
    assert_equal(to_str(u[0].cps), "strong soft snake_case_name 2*3*4")
    assert_equal(styles(u[0]), "BBBBBB.IIII......................")
    var nested = render("**bold with `code` inside**", 80)
    assert_equal(to_str(nested[0].cps), "bold with code inside")
    assert_equal(styles(nested[0]), "BBBBBBBBBBCCCCBBBBBBB")


def test_unclosed_markers_stay_as_typed() raises:
    assert_equal(plain("a * b and **c", 80), "a * b and **c")
    assert_equal(plain("one `tick", 80), "one `tick")
    assert_equal(plain("[not a link] (x)", 80), "[not a link] (x)")
    assert_equal(plain("5 < 6 and 7 > 2", 80), "5 < 6 and 7 > 2")


def test_escapes_entities_and_links() raises:
    assert_equal(plain("\\*not italic\\* and \\_x\\_", 80), "*not italic* and _x_")
    assert_equal(plain("a &lt;b&gt; &amp; &quot;c&quot;", 80), "a <b> & \"c\"")
    var l = render("see [the docs](https://example.org/x) or <https://example.org>", 80)
    assert_equal(to_str(l[0].cps), "see the docs or https://example.org")
    assert_equal(styles(l[0]), "....LLLLLLLL....LLLLLLLLLLLLLLLLLLL")
    assert_equal(plain("``a ` b``", 80), "a ` b")
    assert_equal(plain("path\\to\\file", 80), "path\\to\\file")       # backslash before a letter stays


# ------------------------------------------------------------------- blocks
def test_paragraphs_are_joined_and_wrapped() raises:
    var text = String("First line\ncontinues here.\n\n\n\nSecond paragraph that is long enough to wrap around.")
    assert_equal(plain(text, 24), "First line continues\nhere.\n\nSecond paragraph that is\nlong enough to wrap\naround.")
    for l in render(text, 24):
        assert_true(cp_len(to_str(l.cps)) <= 24)
    assert_equal(plain("", 20), "")
    assert_equal(plain("\n\n  \n", 20), "")
    assert_equal(plain("word", 20), "word")
    assert_equal(plain("averyveryverylongwordwithoutanybreaks ok", 10), "averyveryv\nerylongwor\ndwithoutan\nybreaks ok")


def test_wide_characters_wrap_by_columns() raises:
    var l = render("日本語のテキストです 日本語のテキストです", 12)
    for row in l:
        var w = 0
        for c in row.cps:
            w += char_width(c)
        assert_true(w <= 12, to_str(row.cps))
    assert_equal(len(l), 4)


def test_headings_and_rules() raises:
    var l = render("# Title `code`\ntext\n\n## Second ##\n---\nafter", 20)
    assert_equal(md_plain(l), "Title code\n\ntext\n\nSecond\n────────────────────\nafter")
    assert_equal(styles(l[0]), "HHHHHHHHHH")
    assert_equal(styles(l[5]), "DDDDDDDDDDDDDDDDDDDD")
    assert_equal(plain("#hashtag is text", 40), "#hashtag is text")
    assert_equal(plain("####### seven", 40), "####### seven")
    # no rule and no blank line at the very top, none at the end
    assert_equal(plain("---\ntext\n---", 10), "text\n──────────")


def test_lists_with_hanging_indent() raises:
    var text = String("- first item that wraps\n- second\n  continues\n* third\n\n1. one\n10) ten is here")
    assert_equal(
        plain(text, 16),
        "• first item\n  that wraps\n• second\n  continues\n• third\n\n1. one\n10) ten is here",
    )
    var l = render("- a **b**", 20)
    assert_equal(styles(l[0]), "DD..B")
    var nested = plain("- top\n  - inner item\n- next", 20)
    assert_equal(nested, "• top\n  • inner item\n• next")
    assert_equal(plain("-not a list\n2.5 is a number", 40), "-not a list 2.5 is a number")


def test_block_quote() raises:
    var l = render("> quoted *text* here\nplain", 12)
    assert_equal(md_plain(l), "│ quoted\n│ text here\n\nplain")
    assert_equal(styles(l[0]), "DDIIIIII")


def test_code_blocks_keep_their_lines_and_get_syntax_colours() raises:
    var text = String("Intro\n```mojo\ndef f():   # note\n\treturn \"s\"\n```\nAfter")
    var l = render(text, 12)
    assert_equal(md_plain(l), "Intro\n\ndef f():   # note\n    return \"s\"\n\nAfter")
    assert_equal(l[2].st[0], MD_BLOCK + C_KW)            # def
    assert_equal(l[2].st[11], MD_BLOCK + C_CMT)          # the comment
    assert_equal(l[3].st[4], MD_BLOCK + C_KW)            # return
    assert_equal(l[3].st[11], MD_BLOCK + C_STR)
    # another language: kept as text, one style
    var sh = render("```sh\ndef x  # y\n```", 40)
    assert_equal(md_plain(sh), "def x  # y")
    assert_equal(sh[0].st[0], MD_BLOCK + C_TEXT)
    # markup inside code is not interpreted, and an unclosed block runs to the end
    assert_equal(plain("```\n**not bold** `x`\n# no heading", 40), "**not bold** `x`\n# no heading")
    assert_equal(plain("~~~\ntilde fence\n~~~", 40), "tilde fence")


def test_docstring_state_carries_across_code_lines() raises:
    var l = render("```mojo\nx = \"\"\"start\nstill string\n\"\"\"\ny = 1\n```", 40)
    assert_equal(l[1].st[0], MD_BLOCK + C_STR)
    assert_equal(l[3].st[0], MD_BLOCK + C_TEXT)


def test_what_the_mojo_server_sends() raises:
    # the shape of a real hover / completion documentation string
    var text = String("### alias `IteratorOwnedType`\n\n---\n\n###\nThe owned iterator type for this list.\n\n\n---\n\n###\n```mojo\ncomptime X: Int = 1\n```")
    assert_equal(
        plain(text, 30),
        "alias IteratorOwnedType\n──────────────────────────────\nThe owned iterator type for\nthis list.\n──────────────────────────────\ncomptime X: Int = 1",
    )


def test_never_wider_than_asked_except_code() raises:
    var samples: List[String] = [
        "A paragraph with **bold words** and `inline code` that goes on for quite a while.",
        "- item one is rather long too\n  - nested item also long enough\n9. numbered and long as well ok",
        "> a quote that needs to be wrapped several times over to fit",
        "# A heading that is longer than the width allows",
    ]
    for s in samples:
        for w in [10, 17, 33]:
            for row in render(s, w):
                var cols = 0
                for c in row.cps:
                    cols += char_width(c)
                assert_true(cols <= w, String(w) + ": " + to_str(row.cps))
                assert_equal(len(row.cps), len(row.st))


def test_code_fence_info_strings_and_titles() raises:
    var links = List[String]()
    var r = md_render_rich("```mojo no-test title=\"demo.mojo\"\ndef hi():\n    pass\n```\n", 40, Highlighter(), links, True)
    assert_equal(to_str(r[0].cps), "── demo.mojo ──")
    assert_equal(styles(r[0]), "DDDDDDDDDDDDDDD")
    assert_equal(to_str(r[1].cps), "def hi():")
    assert_equal(r[1].st[0], MD_BLOCK + C_KW)
    var comma = render("```mojo,ignore\ndef f():\n    pass\n```", 40)
    assert_equal(comma[0].st[0], MD_BLOCK + C_KW)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
