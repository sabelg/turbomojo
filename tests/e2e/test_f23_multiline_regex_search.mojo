"""E2E Test Suite for Feature #23: Multi-Line Regex & Rope Search.
Covers Tier 1 (5 Happy Path tests) and Tier 2 (5 Boundary/Corner tests).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from rope import Rope, MAX_LEAF
from regex import regex_compile, Regex
from search import (
    MatchSpan, offset_to_span,
    search_multiline_literal, search_multiline_regex,
    ChunkMatchCache, make_search,
)
from window import Window, WK_EDITOR
from screen import Screen
from palette import theme
from highlight import Highlighter
from window_search import *
from window_draw import *
from signals import own_pid
from util import decode, to_str, env_or, run_system, shell_quote, str_bytes, bytes_to_str


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f23-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


# ---------------------------------------------------------------------------
# Tier 1: Isolated Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f23_case1_multiline_literal_search_basic() raises:
    """Search for literal containing \\n produces valid MatchSpan spanning lines."""
    var text = "first line\nalpha\nbeta\nlast line\n"
    var spans = search_multiline_literal(decode(text), "alpha\nbeta")
    assert_equal(len(spans), 1)
    assert_equal(spans[0].r1, 1)
    assert_equal(spans[0].c1, 0)
    assert_equal(spans[0].r2, 2)
    assert_equal(spans[0].c2, 4)


def test_tier1_f23_case2_multiline_regex_search() raises:
    """Regex matching multi-line function signature and return statement."""
    var text = "def solve():\n    return 0\n"
    var spans = search_multiline_regex(decode(text), "def [a-z]+\\(\\):\n    return 0")
    assert_equal(len(spans), 1)
    assert_equal(spans[0].r1, 0)
    assert_equal(spans[0].c1, 0)
    assert_equal(spans[0].r2, 1)
    assert_equal(spans[0].c2, 12)


def test_tier1_f23_case3_match_span_spanning_three_lines() raises:
    """MatchSpan spanning across 3 lines with non-zero start and end columns."""
    var text = "header\n  PART_A\n  PART_B\n  PART_C\ntrailer\n"
    var spans = search_multiline_literal(decode(text), "PART_A\n  PART_B\n  PART_C")
    assert_equal(len(spans), 1)
    assert_equal(spans[0].r1, 1)
    assert_equal(spans[0].c1, 2)
    assert_equal(spans[0].r2, 3)
    assert_equal(spans[0].c2, 8)


def test_tier1_f23_case4_cross_chunk_boundary_search() raises:
    """Verify search across Rope leaves when text exceeds MAX_LEAF (1024 bytes)."""
    var rope = Rope()
    var leaf0 = String("")
    for _ in range(100):
        leaf0 += "0123456789\n" # 1100 bytes: exceeds 1024 to create multiple leaves
    leaf0 += "CROSS_CHUNK_START\n"
    
    var leaf1 = "CROSS_CHUNK_END\nfinal line\n"
    var full_text = leaf0 + leaf1
    
    rope.load_cps(decode(full_text))
    var rope_cps = rope.to_cps()
        
    var spans = search_multiline_literal(rope_cps, "CROSS_CHUNK_START\nCROSS_CHUNK_END")
    assert_equal(len(spans), 1)
    assert_equal(spans[0].r1, 100)
    assert_equal(spans[0].c1, 0)
    assert_equal(spans[0].r2, 101)
    assert_equal(spans[0].c2, 15)


def test_tier1_f23_case5_cached_chunk_match_counts() raises:
    """Verify ChunkMatchCache reuses cached count on hits and recalculates on version change."""
    var cache = ChunkMatchCache()
    var chunk_a = decode("foo\nbar\nfoo\nbar\n")
    
    # First query -> Cache miss
    var c1 = cache.get_count("chunk_0", 1, chunk_a, "foo\nbar")
    assert_equal(c1, 2)
    assert_equal(cache.hits, 0)
    assert_equal(cache.misses, 1)
    
    # Second query same version -> Cache hit
    var c2 = cache.get_count("chunk_0", 1, chunk_a, "foo\nbar")
    assert_equal(c2, 2)
    assert_equal(cache.hits, 1)
    assert_equal(cache.misses, 1)
    
    # Version update (e.g. chunk modified) -> Cache miss, updated count
    var chunk_a_mod = decode("foo\nbar\n")
    var c3 = cache.get_count("chunk_0", 2, chunk_a_mod, "foo\nbar")
    assert_equal(c3, 1)
    assert_equal(cache.hits, 1)
    assert_equal(cache.misses, 2)


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f23_bound1_consecutive_newlines_and_empty_lines() raises:
    """Search for consecutive newlines \\n\\n across blank lines."""
    var text = "a\n\n\nb\n"
    var spans = search_multiline_literal(decode(text), "\n\n")
    assert_equal(len(spans), 1)
    assert_equal(spans[0].r1, 0)
    assert_equal(spans[0].c1, 1)
    assert_equal(spans[0].r2, 2)
    assert_equal(spans[0].c2, 0)


def test_tier2_f23_bound2_pattern_spanning_many_lines() raises:
    """Pattern spanning 25 lines in buffer."""
    var lines = String("")
    for i in range(30):
        lines += "line_" + String(i) + "\n"
        
    var pat = String("")
    for i in range(5, 25):
        pat += "line_" + String(i) + "\n"
    pat += "line_25"
    
    var spans = search_multiline_literal(decode(lines), pat)
    assert_equal(len(spans), 1)
    assert_equal(spans[0].r1, 5)
    assert_equal(spans[0].r2, 25)
    assert_equal(spans[0].c2, 7) # length of "line_25"


def test_tier2_f23_bound3_exact_chunk_boundary_newline() raises:
    """The \\n character is located at exact boundary between two segments."""
    var part1 = "prefix_word" # 11 chars
    var part2 = "\nsuffix_word" # starts with \n
    var combined = part1 + part2
    
    var spans = search_multiline_literal(decode(combined), "prefix_word\nsuffix_word")
    assert_equal(len(spans), 1)
    assert_equal(spans[0].r1, 0)
    assert_equal(spans[0].c1, 0)
    assert_equal(spans[0].r2, 1)
    assert_equal(spans[0].c2, 11)


def test_tier2_f23_bound4_unmatched_and_empty_queries() raises:
    """Empty query returns empty matches; unmatched multi-line pattern returns 0 matches."""
    var text = "alpha\nbeta\ngamma\n"
    var empty_spans = search_multiline_literal(decode(text), "")
    assert_equal(len(empty_spans), 0)
    
    var no_spans = search_multiline_literal(decode(text), "non\nexistent")
    assert_equal(len(no_spans), 0)


def test_tier2_f23_bound5_overlapping_candidates_non_overlapping_matches() raises:
    """Non-overlapping search over overlapping candidate sequences."""
    var text = "x\nx\nx\nx\n" # 4 lines of 'x'
    var spans = search_multiline_literal(decode(text), "x\nx")
    # Matches (0,0)->(1,1) and (2,0)->(3,1), skipping index 1
    assert_equal(len(spans), 2)
    assert_equal(spans[0].r1, 0)
    assert_equal(spans[0].r2, 1)
    assert_equal(spans[1].r1, 2)
    assert_equal(spans[1].r2, 3)


def test_tier2_f23_bound6_multiline_anchors_and_window_replace() raises:
    """Verify ^ and $ match internal line boundaries and Window search/replace/draw support multi-line."""
    var src = "ignore\ndef alpha():\n    pass\ndef beta():\n    pass\n"
    var re_spans = search_multiline_regex(decode(src), "^def [a-z]+\\(\\):$\n^    pass$")
    assert_equal(len(re_spans), 2)
    assert_equal(re_spans[0].r1, 1)
    assert_equal(re_spans[0].r2, 2)
    assert_equal(re_spans[1].r1, 3)
    assert_equal(re_spans[1].r2, 4)

    var cache = ChunkMatchCache()
    var c_spans = cache.update_and_search("c0", 1, decode(src), "^def [a-z]+\\(\\):$", use_regex=True)
    assert_equal(len(c_spans), 2)

    var win = Window(WK_EDITOR, "m.mojo", "m.mojo", 0, 0, 60, 12, 1)
    win.buf.load(decode("a = 1\nb = 2\na = 1\nb = 2"))
    var ms = make_search(decode("a = 1\\nb = 2"), True, False, True)
    assert_true(ms.is_multiline())
    assert_equal(win.count_matches(ms, 5000).r1, 2)
    assert_true(win.search_from(ms, 0, 0))
    assert_true(win.sel_is_match(ms))
    win.set_highlight(ms)

    var scr = Screen(60, 12)
    var pal = theme(0)
    var hl = Highlighter()
    win.draw(scr, pal, hl, True, False, True, False)
    # Second match on rows 2..3 gets match_bg highlight
    assert_equal(scr.bg_at(win.x + 1 + win.gut, win.y + 1 + 2), pal.match_bg)

    assert_true(win.replace_current(ms, decode("x = 9")))
    assert_equal(win.replace_matches(ms, decode("y = 0")), 1)
    assert_equal(to_str(win.buf.all_text()), "x = 9\ny = 0")


# ---------------------------------------------------------------------------
# Test Runner
# ---------------------------------------------------------------------------

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
