"""What to search for: text or a regular expression, with the Find dialog's options.
Matching works on one line at a time (a list of codepoints)."""
from std.collections import List
from regex import Regex, regex_compile, fold
from util import is_ident


struct Search(Copyable, Movable):
    var pat: List[Int]
    var case_sensitive: Bool
    var whole_word: Bool
    var use_regex: Bool
    var ok: Bool               # False: nothing to search for, or a bad regular expression
    var error: String
    var re: Regex
    var folded: List[Int]      # the pattern in the form it is compared in

    def __init__(out self):
        self.pat = List[Int]()
        self.case_sensitive = False
        self.whole_word = False
        self.use_regex = False
        self.ok = False
        self.error = ""
        self.re = Regex()
        self.folded = List[Int]()

    def word_ok(self, ln: List[Int], s: Int, e: Int) -> Bool:
        """Is [s, e) bounded by word boundaries on both sides?"""
        var n = len(ln)
        var left = s == 0 or not is_ident(ln[s - 1]) or not is_ident(ln[s])
        var right = e >= n or not is_ident(ln[e]) or not is_ident(ln[e - 1])
        return left and right

    def caps_in(self, ln: List[Int], start: Int) -> List[Int]:
        """The first match in the line at or after `start`: [s, e] followed by the spans
        of the capture groups; empty if there is none. Matches of length zero are skipped
        (there would be nothing to select or replace)."""
        var out = List[Int]()
        if not self.ok:
            return out^
        var n = len(ln)
        var c = max(0, start)
        if self.use_regex:
            while c <= n:
                var m = self.re.search(ln, c)
                if len(m) == 0:
                    return out^
                if m[1] > m[0] and (not self.whole_word or self.word_ok(ln, m[0], m[1])):
                    return m^
                c = m[0] + 1
            return out^
        var k = len(self.folded)
        var first = self.folded[0]
        while c + k <= n:
            var a = ln[c] if self.case_sensitive else fold(ln[c])
            if a == first:
                var same = True
                for i in range(1, k):
                    var b = ln[c + i] if self.case_sensitive else fold(ln[c + i])
                    if b != self.folded[i]:
                        same = False
                        break
                if same and (not self.whole_word or self.word_ok(ln, c, c + k)):
                    out.append(c)
                    out.append(c + k)
                    return out^
            c += 1
        return out^

    def all_in(self, ln: List[Int], lo: Int, hi: Int) -> List[Int]:
        """Start and end of every match that lies inside columns [lo, hi), left to right,
        not overlapping."""
        var out = List[Int]()
        var c = lo
        while c < hi:
            var m = self.caps_in(ln, c)
            if len(m) == 0 or m[1] > hi:
                break
            out.append(m[0])
            out.append(m[1])
            c = m[1]
        return out^

    def replacement(self, rep: List[Int], ln: List[Int], caps: List[Int]) -> List[Int]:
        """The text that replaces a match: in regular-expression mode $1, ${1}, $0, $&, $$,
        \\n and \\t are expanded, otherwise `rep` is taken as it is."""
        if self.use_regex:
            return self.re.expand(rep, ln, caps)
        return rep.copy()


def make_search(pat: List[Int], case_sensitive: Bool, whole_word: Bool, use_regex: Bool) -> Search:
    var s = Search()
    s.pat = pat.copy()
    s.case_sensitive = case_sensitive
    s.whole_word = whole_word
    s.use_regex = use_regex
    if len(pat) == 0:
        return s^
    if use_regex:
        s.re = regex_compile(pat, not case_sensitive)
        s.ok = s.re.ok
        s.error = s.re.error
        return s^
    for c in pat:
        s.folded.append(c if case_sensitive else fold(c))
    s.ok = True
    return s^
