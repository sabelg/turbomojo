#!/usr/bin/env python3
"""Generate tests/data/regex_cases.txt: patterns and texts with the match that Python's
`re` module reports, used by tests/test_regex.mojo as an independent reference.

    python3 tests/helpers/gen_regex_cases.py > tests/data/regex_cases.txt

Line format (tab separated):  flags  pattern  text  expected
  flags     "-" or "i" (ignore case)
  pattern   codepoints in decimal, comma separated ("" for an empty one)
  text      the same
  expected  "-" for no match, else start,end of the match and of every group (-1,-1 for a
            group that took no part)

Only syntax both engines share is generated, and nothing whose result is known to differ
by design: a repeated group that can match the empty string (see src/regex.mojo).
The output is deterministic (fixed seed)."""
import random
import re
import sys

random.seed(20261110)
out = []


def enc(s):
    return ",".join(str(ord(c)) for c in s)


def case(pattern, text, flags=""):
    try:
        rx = re.compile(pattern, re.IGNORECASE if "i" in flags else 0)
    except re.error as e:
        sys.exit("bad pattern %r: %s" % (pattern, e))
    m = rx.search(text)
    if m is None:
        exp = "-"
    else:
        spans = [m.span(0)] + [m.span(i + 1) for i in range(rx.groups)]
        exp = ",".join("%d,%d" % sp for sp in spans)
    out.append("\t".join([flags or "-", enc(pattern), enc(text), exp]))


# ---- hand-picked patterns, each tried on several texts
HAND = [
    (r"abc", ["abc", "xxabcxx", "ab", "", "aabcabc"]),
    (r"a.c", ["abc", "a\nc", "ac", "xa-c"]),
    (r"a*", ["", "aaa", "baaa", "b"]),
    (r"a+", ["", "aaa", "baaa", "b"]),
    (r"a?b", ["b", "ab", "aab", "a"]),
    (r"a*?b", ["aaab", "b", "aaa"]),
    (r"a+?", ["aaa", "b"]),
    (r"(a+?)(a*)", ["aaaa", "a", ""]),
    (r"(a*)(a+?)", ["aaaa", "a"]),
    (r"a??b", ["ab", "b"]),
    (r"(a|ab)(c|bcd)(d*)", ["abcd", "acd", "abc"]),
    (r"(a|b)*c", ["ababc", "c", "abab", "xbac"]),
    (r"(?:a|b)+", ["xxabbay", "ccc"]),
    (r"(?:(a)|b)*", ["ab", "ba", "bb", ""]),
    (r"(a)|(b)", ["a", "b", "c", "cb"]),
    (r"a{3}", ["aa", "aaa", "aaaa", "baaab"]),
    (r"a{2,3}", ["a", "aa", "aaa", "aaaa"]),
    (r"a{2,}", ["a", "aa", "aaaaa"]),
    (r"a{2,3}?", ["aaaa"]),
    (r"a{0,2}b", ["b", "ab", "aab", "aaab"]),
    (r"(ab){2}", ["abab", "ab", "xababab"]),
    (r"x{2", ["x{2", "xx"]),
    (r"[abc]+", ["xxabcabx", "def"]),
    (r"[^abc]+", ["abcdefabc", "abc"]),
    (r"[a-cx-z]+", ["mabcxyzm", "m"]),
    (r"[]a]+", ["]a]b", "b"]),
    (r"[^]a]+", ["]ab]", "]a"]),
    (r"[a-]+", ["-a-b", "b"]),
    (r"[-a]+", ["-a-b"]),
    (r"[\d.]+", ["v1.25b", "abc"]),
    (r"[\w-]+", ["foo-bar baz", "!!"]),
    (r"[^\s]+", ["  word  ", "   "]),
    (r"[\]\\]+", [r"a]\]b"]),
    (r"[\t ]+x", ["a \t x"]),
    (r"\d+", ["abc123def", "abc", "9"]),
    (r"\D+", ["123abc456", "123"]),
    (r"\w+", ["  foo_bar9  ", "!!!"]),
    (r"\W+", ["foo, bar", "foo"]),
    (r"\s+", ["a \t b", "ab"]),
    (r"\S+", ["  ab  ", "   "]),
    (r"\bfoo\b", ["foo", "a foo b", "afoo", "foob", "foo.bar", " foo"]),
    (r"\Boo\B", ["foo", "fooo", "oo", "xoox"]),
    (r"\b", ["", "a", " a", "  "]),
    # not tried on "": Python before 3.14 says \B does not match an empty text
    (r"\B", ["a", "ab", " "]),
    (r"^abc", ["abc", "xabc", "abcabc"]),
    (r"abc$", ["abc", "abcx", "xabc"]),
    (r"^$", ["", "a"]),
    (r"^a*$", ["", "aaa", "aab"]),
    (r"$", ["", "abc"]),
    (r"^", ["", "abc"]),
    (r"a|^b", ["b", "cb", "ca"]),
    (r"(^a|b)c", ["ac", "xac", "xbc"]),
    (r"", ["", "abc"]),
    (r"()", ["", "abc"]),
    (r"a|", ["a", "b", ""]),
    (r"|a", ["a", "b"]),
    (r"(a|)b", ["ab", "b", "cb"]),
    (r"(a)(b)?(c)", ["abc", "ac", "a"]),
    (r"(a(b(c)))", ["xabcx", "ab"]),
    (r"((a)|(b))+", ["ab", "ba", "aab"]),
    (r"(?P<x>a+)(?P<y>b+)", ["aabbb", "ab", "a"]),
    (r"\.\*\+\?\(\)\[\]\{\}\|\^\$\\", [r".*+?()[]{}|^$" + "\\", "x"]),
    (r"\x41\x62", ["Ab", "ab"]),
    (r"é+", ["caféé", "cafe"]),
    (r"\U0001F525", ["a\U0001F525b", "ab"]),
    (r"\t\n\r\f\v", ["\t\n\r\f\v", "t"]),
    (r"日.語", ["日本語", "日語"]),
    (r"[぀-ゟ]+", ["abcひらがなdef", "abc"]),
    (r"[^a-z]", ["abc\U0001F600def", "abc"]),
    (r"x*", ["é"]),
    (r"def\s+(\w+)\s*\(", ["def main():", "  def  foo_1 (x):", "define(", "def ("]),
    (r"(\w+)\s*=\s*(\d+|\"[^\"]*\")", ['x = 12', 'name="a b" ', "y=", "= 3"]),
    (r"^\s*#.*$", ["  # comment", "x # c", "#"]),
    (r"(\d+)\.(\d+)\.(\d+)", ["v1.20.3", "1.2", "10.20.30.40"]),
    (r"[A-Za-z_]\w*", ["9lives _x1", "123"]),
    # short texts only: these patterns take exponential time in a backtracking engine
    (r"(a+)+b", ["aaaaaaaaaaaac", "aaab"]),
    (r"(x+x+)+y", ["xxxxxxxxxxxx", "xxy"]),
    (r"(?:a?){12}a{12}", ["a" * 12, "a" * 11]),
    (r".*foo", ["xxfooyyfoo", "fo"]),
    (r".*?foo", ["xxfooyyfoo"]),
    (r"(.*)(\d+)", ["abc123", "abc"]),
    (r"(.*?)(\d+)", ["abc123"]),
    (r"(.+)@(.+)\.(com|org)", ["me@site.org", "a@b.net", "a@b.c.com"]),
    (r"a.*b.*c", ["a--b--c--b--c", "acb"]),
    (r"(a|aa)(a|aa)", ["aaa", "aa", "a"]),
    (r"(aa|a)(aa|a)", ["aaa", "aa"]),
    (r"(ab|a)(bc|c)?", ["abc", "ab", "ac"]),
    (r"x?y?z?", ["xyz", "yz", "q", "zx"]),
    (r"(?:ab)*a", ["ababa", "abab", "b"]),
    (r"[ab]*c|a", ["abab", "ababc"]),
]
for pat, texts in HAND:
    for t in texts:
        case(pat, t)

ICASE = [
    (r"abc", ["ABC", "xAbCx", "abd"]),
    (r"ABC", ["abc", "aBc"]),
    (r"[a-c]+", ["xxABCabcX", "XYZ"]),
    (r"[^a-c]+", ["ABCxyzABC", "abcABC"]),
    (r"[A-C]+z", ["abcZ", "abd"]),
    (r"hello\s+WORLD", ["Hello   World", "HELLO world!", "helloworld"]),
    (r"(a)(B)", ["Ab", "aB", "AB", "ba"]),
    (r"\w+x", ["FOOX", "bar"]),
    (r"été", ["ÉTÉ", "ete"]),
    (r"É", ["é"]),
    (r"[à-å]+", ["ÀÅx", "x"]),
]
for pat, texts in ICASE:
    for t in texts:
        case(pat, t, "i")


# ---- random patterns over a small alphabet
ATOMS = ["a", "b", "c", "a", "b", ".", "[ab]", "[^a]", "[b-c]", r"\w", r"\d", "ab", "bc"]
QUANT_ANY = ["*", "+", "*?", "+?", "{2}", "{1,2}", "{2,}", "{0,2}", "{1,3}?"]


def gen(depth):
    """Returns (pattern, can match the empty string, may take a quantifier)."""
    r = random.random()
    if depth <= 0 or r < 0.35:
        r2 = random.random()
        if r2 < 0.04:
            return "^", True, False
        if r2 < 0.08:
            return "$", True, False
        if r2 < 0.12:
            return r"\b", True, False
        return random.choice(ATOMS), False, True
    if r < 0.55:
        # concatenation
        parts = [gen(depth - 1) for _ in range(random.randint(2, 3))]
        return "".join(p[0] for p in parts), all(p[1] for p in parts), False
    if r < 0.72:
        # alternation in a group
        parts = [gen(depth - 1) for _ in range(random.randint(2, 3))]
        open_ = "(" if random.random() < 0.7 else "(?:"
        return open_ + "|".join(p[0] for p in parts) + ")", any(p[1] for p in parts), True
    if r < 0.82:
        p, nullable, _ = gen(depth - 1)
        open_ = "(" if random.random() < 0.7 else "(?:"
        return open_ + p + ")", nullable, True
    # quantified
    p, nullable, quantifiable = gen(depth - 1)
    if not quantifiable:
        p = "(?:" + p + ")"
    if len(p) > 1 and not (p.startswith("(") or p.startswith("[") or p.startswith("\\")):
        p = "(?:" + p + ")"
    if nullable:
        q = random.choice(["?", "??"])           # never loop over something that can be empty
        return p + q, True, False
    q = random.choice(QUANT_ANY + ["?", "??"])
    return p + q, q[0] in "*?" or q.startswith("{0"), False


def rand_text():
    n = random.randint(0, 9)
    return "".join(random.choice("aabbc c1") for _ in range(n))


count = 0
while count < 2500:
    pat, _, _ = gen(4)
    if len(pat) > 40:
        continue
    for _ in range(2):
        case(pat, rand_text())
    count += 1

sys.stdout.write("\n".join(out) + "\n")
