"""Tests for src/regex.mojo. Matching is checked against results recorded from Python's
`re` module (tests/data/regex_cases.txt, made by tests/helpers/gen_regex_cases.py), plus
hand-written tests for errors, replacement templates, the API and running time."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from regex import regex_compile, Regex, fold, unfold, normalize, complement
from util import decode, to_str, read_file


def re(p: String) -> Regex:
    return regex_compile(decode(p), False)


def spans(m: List[Int]) -> String:
    if len(m) == 0:
        return "-"
    var s = String("")
    for i in range(len(m)):
        if i > 0:
            s += ","
        s += String(m[i])
    return s


def find(p: String, text: String) raises -> String:
    var r = re(p)
    assert_true(r.ok, "pattern rejected: " + p + ": " + r.error)
    return spans(r.search(decode(text), 0))


def numbers(field: List[UInt8]) -> List[Int]:
    """Comma separated decimal numbers (negative allowed)."""
    var out = List[Int]()
    var v = 0
    var neg = False
    var have = False
    for b in field:
        if b == 44:
            out.append(-v if neg else v)
            v = 0
            neg = False
            have = False
        elif b == 45:
            neg = True
        else:
            v = v * 10 + Int(b) - 48
            have = True
    if have:
        out.append(-v if neg else v)
    return out^


# ------------------------------------------------------- reference comparison
def test_matches_agree_with_python_reference() raises:
    var data = read_file("tests/data/regex_cases.txt")
    assert_true(len(data) > 1000, "reference file missing")
    var fields = List[List[UInt8]]()
    var cur = List[UInt8]()
    var checked = 0
    var wrong = 0
    var report = String("")
    for i in range(len(data)):
        var b = data[i]
        if b != 9 and b != 10:
            cur.append(b)
            continue
        fields.append(cur.copy())
        cur.clear()
        if b == 9:
            continue
        if len(fields) == 4:
            var icase = len(fields[0]) > 0 and fields[0][0] == 105
            var pat = numbers(fields[1])
            var text = numbers(fields[2])
            var no_match = len(fields[3]) == 1 and fields[3][0] == 45
            var want = String("-") if no_match else spans(numbers(fields[3]))
            var r = regex_compile(pat, icase)
            var got = String("rejected: ") + r.error
            if r.ok:
                got = spans(r.search(text, 0))
            checked += 1
            if got != want:
                wrong += 1
                if wrong <= 12:
                    report += "\n  /" + to_str(pat) + "/ on \"" + to_str(text) + "\": want " + want + " got " + got
        fields.clear()
    assert_true(checked > 5000, "too few cases: " + String(checked))
    assert_equal(wrong, 0, String(wrong) + " of " + String(checked) + " differ:" + report)


# ------------------------------------------------------------------- basics
def test_literals_and_groups() raises:
    assert_equal(find("abc", "xxabcxx"), "2,5")
    assert_equal(find("(a+)(b|c)?\\d{2,3}", "xx aab1234"), "3,9,3,5,5,6")
    assert_equal(find("(a)|(b)", "b"), "0,1,-1,-1,0,1")
    assert_equal(find("", "abc"), "0,0")
    assert_equal(find("x", ""), "-")


def test_group_count_and_named_groups() raises:
    assert_equal(re("abc").groups, 0)
    assert_equal(re("(a)(?:b)(c(d))").groups, 3)
    assert_equal(re("(?<year>\\d+)-(?P<month>\\d+)").groups, 2)
    assert_equal(find("(?<year>\\d+)-(?P<month>\\d+)", "on 2026-11"), "3,10,3,7,8,10")


def test_search_from_an_offset() raises:
    var r = re("ab")
    var t = decode("ab ab ab")
    assert_equal(spans(r.search(t, 0)), "0,2")
    assert_equal(spans(r.search(t, 1)), "3,5")
    assert_equal(spans(r.search(t, 6)), "6,8")
    assert_equal(spans(r.search(t, 7)), "-")
    assert_equal(spans(r.search(t, 8)), "-")
    # anchors and word boundaries look at the whole text, not at the offset
    assert_equal(spans(re("^ab").search(t, 3)), "-")
    assert_equal(spans(re("\\bb").search(decode("ab b"), 1)), "3,4")
    assert_equal(spans(re("b+").search(decode("aaabbb"), 1)), "3,6")
    assert_equal(spans(re("$").search(t, 2)), "8,8")


def test_match_at_is_anchored_to_the_position() raises:
    var r = re("b+")
    var t = decode("aabbb")
    assert_equal(spans(r.match_at(t, 0)), "-")
    assert_equal(spans(r.match_at(t, 2)), "2,5")
    assert_equal(spans(r.match_at(t, 4)), "4,5")
    assert_equal(spans(r.match_at(t, 5)), "-")
    assert_equal(spans(re("a*").match_at(decode("bbb"), 1)), "1,1")


def test_all_matches_can_be_walked() raises:
    # the way "replace all" uses the engine: search again from the end of each match
    var r = re("\\d+")
    var t = decode("a1 b22 c333")
    var found = String("")
    var at = 0
    while at <= len(t):
        var m = r.search(t, at)
        if len(m) == 0:
            break
        found += String(m[0]) + "-" + String(m[1]) + " "
        at = m[1] if m[1] > m[0] else m[1] + 1
    assert_equal(found, "1-2 4-6 8-11 ")


def test_ignore_case() raises:
    var r = regex_compile(decode("héllo [a-c]+"), True)
    assert_equal(spans(r.search(decode("HÉLLO ABC"), 0)), "0,9")
    assert_equal(spans(regex_compile(decode("(?i)mojo"), False).search(decode("My MoJo"), 0)), "3,7")
    assert_equal(spans(regex_compile(decode("mojo"), False).search(decode("My MoJo"), 0)), "-")
    assert_equal(spans(regex_compile(decode("жук"), True).search(decode("ЖУК"), 0)), "0,3")
    assert_equal(spans(regex_compile(decode("[^a]"), True).search(decode("Aab"), 0)), "2,3")
    for c in [65, 90, 0xC9, 0x391, 0x416, 0x401]:
        assert_true(fold(c) != c)
        assert_equal(unfold(fold(c)), c)
    for c in [48, 95, 0xD7, 0xF7, 0x65E5]:
        assert_equal(fold(c), c)
        assert_equal(unfold(c), c)


def test_word_characters_include_letters_beyond_ascii() raises:
    assert_equal(find("\\w+", "  café_日本 !"), "2,9")
    assert_equal(find("\\bé", "é"), "0,1")


def test_range_helpers() raises:
    var r: List[Int] = [10, 20, 5, 7, 18, 30, 8, 9, 40, 40]
    assert_equal(spans(normalize(r)), "5,30,40,40")
    assert_equal(spans(complement(normalize(r))), "0,4,31,39,41,1114111")
    var all: List[Int] = [0, 0x10FFFF]
    assert_equal(len(complement(all)), 0)


# ------------------------------------------------------------------- errors
def bad(p: String, msg: String, at: Int) raises:
    var r = re(p)
    assert_false(r.ok, "should be rejected: " + p)
    assert_true(r.error.find(msg) >= 0, p + ": got \"" + r.error + "\"")
    assert_equal(r.error_at, at, p + ": position")
    assert_equal(len(r.search(decode("anything"), 0)), 0)


def test_syntax_errors_are_reported_with_a_position() raises:
    bad("(abc", "missing )", 0)
    bad("ab(c(d)", "missing )", 2)
    bad("abc)", "unmatched )", 3)
    bad("a)b", "unmatched )", 1)
    bad("[abc", "missing ]", 0)
    bad("x[]", "missing ]", 1)
    bad("*a", "nothing to repeat", 0)
    bad("a|+", "nothing to repeat", 2)
    bad("^*", "nothing to repeat", 1)
    bad("\\b+", "nothing to repeat", 2)
    bad("abc\\", "ends with a backslash", 3)
    bad("[a\\", "ends with a backslash", 2)
    bad("[z-a]", "backwards", 1)
    bad("a{3,2}", "backwards", 1)
    bad("a{1001}", "too large", 1)
    bad("a{2,5000}", "too large", 1)
    bad("\\xZZ", "hex digits", 0)
    bad("\\u12", "hex digits", 0)
    bad("\\q", "unknown escape", 0)
    bad("[a-\\d]", "cannot end a range", 3)


def test_unsupported_features_say_so() raises:
    bad("(a)\\1", "backreferences", 3)
    bad("a(?=b)", "lookahead", 1)
    bad("a(?!b)", "lookahead", 1)
    bad("(?<=a)b", "lookbehind", 0)
    bad("(?<!a)b", "lookbehind", 0)
    bad("a++", "possessive", 2)
    bad("\\p{L}", "Unicode properties", 0)
    bad("a(?i)b", "only allowed at the start", 1)
    bad("(?x)a", "unknown group syntax", 0)
    bad("(?<>a)", "group name", 0)
    bad("(?<na me>a)", "group name", 5)


def test_oversized_patterns_are_rejected() raises:
    var r = re("((a{1000}){1000}){1000}")
    assert_false(r.ok)
    assert_true(r.error.find("too large") >= 0, r.error)
    var deep = String("")
    for _ in range(300):
        deep += "("
    assert_true(re(deep).error.find("nested too deeply") >= 0)
    assert_true(re("(a{1000}){40}").ok)


def test_braces_that_are_not_a_count_are_literal() raises:
    assert_equal(find("x{", "ax{"), "1,3")
    assert_equal(find("x{a}", "x{a}"), "0,4")
    assert_equal(find("x{2", "x{2"), "0,3")
    assert_equal(find("}]", "a}]"), "1,3")


# -------------------------------------------------------------- replacement
def expand(p: String, text: String, template: String) raises -> String:
    var r = re(p)
    assert_true(r.ok)
    var t = decode(text)
    var m = r.search(t, 0)
    assert_true(len(m) > 0, "no match")
    return to_str(r.expand(decode(template), t, m))


def test_replacement_templates() raises:
    assert_equal(expand("(\\w+)@(\\w+)", "me@site", "$2 at $1"), "site at me")
    assert_equal(expand("(\\w+)@(\\w+)", "me@site", "[$0] [$&]"), "[me@site] [me@site]")
    assert_equal(expand("(a)", "a", "${1}1 $$1 $"), "a1 $1 $")
    assert_equal(expand("(a)", "a", "$10"), "a0")              # there is no group 10
    assert_equal(expand("(a)(b)?", "a", "<$2>"), "<>")         # group took no part
    assert_equal(expand("(a)", "a", "$7|${9}|$x|${x}"), "||$x|${x}")
    assert_equal(expand("a", "a", "x\\ny\\tz\\\\ \\q"), "x\ny\tz\\ \\q")
    assert_equal(expand("(日)(本)", "日本", "$2$1"), "本日")
    var twelve = String("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)")
    assert_equal(expand(twelve, "abcdefghijkl", "$12-$1-${11}"), "l-a-k")


# ------------------------------------------------------------- running time
def test_no_exponential_blow_up() raises:
    var t0 = Int(perf_counter_ns())
    var many = List[Int]()
    for _ in range(3000):
        many.append(97)
    many.append(99)
    assert_equal(spans(re("(a+)+b").search(many, 0)), "-")
    assert_equal(spans(re("(a|aa)+$").search(many, 0)), "-")
    assert_equal(spans(re("(a*)*b").search(many, 0)), "-")
    var a30 = List[Int]()
    for _ in range(30):
        a30.append(97)
    var r = re("(?:a?){30}a{30}")
    assert_equal(spans(r.search(a30, 0)), "0,30")
    var ms = (Int(perf_counter_ns()) - t0) // 1000000
    # a backtracking engine needs longer than the age of the universe for the first one
    assert_true(ms < 20000, "took " + String(ms) + " ms")


def test_long_line_search_is_fast() raises:
    var t = List[Int]()
    for i in range(200000):
        t.append(97 + i % 3)
    for c in decode("needle42"):
        t.append(c)
    var t0 = Int(perf_counter_ns())
    assert_equal(spans(re("needle\\d+").search(t, 0)), "200000,200008")
    assert_equal(spans(re("[n]eedle(\\d+)").search(t, 0)), "200000,200008,200006,200008")
    var ms = (Int(perf_counter_ns()) - t0) // 1000000
    assert_true(ms < 5000, "took " + String(ms) + " ms")


def test_not_a_word_boundary_matches_in_empty_text() raises:
    # Python before 3.14 disagrees here; an empty text has no word boundary at 0
    assert_equal(find("\\B", ""), "0,0")
    assert_equal(find("\\b", ""), "-")


def test_empty_group_in_a_loop_still_matches() raises:
    # documented difference: the group may be reported as unset, the match is the same
    var m = re("(a*)*").search(decode("b"), 0)
    assert_equal(m[0], 0)
    assert_equal(m[1], 0)
    var m2 = re("(a*)*b").search(decode("aab"), 0)
    assert_equal(m2[0], 0)
    assert_equal(m2[1], 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
