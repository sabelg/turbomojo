"""What to search for: text or a regular expression, with the Find dialog's options.
Matching works on one line at a time (a list of codepoints)."""
from std.collections import List
from regex import Regex, regex_compile, fold
from util import is_ident, decode


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

    def is_multiline(self) -> Bool:
        """Does the search pattern span multiple lines (literal newline or regex `\\n`)?"""
        var n = len(self.pat)
        for i in range(n):
            if self.pat[i] == 10:
                return True
        if self.use_regex:
            var k = 0
            while k < n:
                if self.pat[k] == 92 and k + 1 < n:
                    if self.pat[k + 1] == 110:
                        return True
                    k += 2
                    continue
                k += 1
        return False

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


@fieldwise_init
struct MatchSpan(Copyable, Movable):
    """Represents a match span from (r1, c1) to (r2, c2) in line and codepoint coordinates."""
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int


def offset_to_span(cps: List[Int], start_off: Int, end_off: Int) -> MatchSpan:
    """Map linear codepoint offsets [start_off, end_off) to line and column coordinates."""
    var r1 = 0
    var c1 = 0
    var r2 = 0
    var c2 = 0
    var row = 0
    var col = 0
    var limit = min(len(cps), max(start_off, end_off))
    for i in range(limit):
        if i == start_off:
            r1 = row
            c1 = col
        if i == end_off:
            r2 = row
            c2 = col
            break
        if cps[i] == 10:
            row += 1
            col = 0
        else:
            col += 1

    if limit == start_off:
        r1 = row
        c1 = col
    if limit == end_off:
        r2 = row
        c2 = col

    return MatchSpan(r1, c1, r2, c2)


def search_multiline_literal(cps: List[Int], pat_s: String, ignore_case: Bool = False) -> List[MatchSpan]:
    """Search for multi-line literal pattern and return MatchSpans."""
    var out = List[MatchSpan]()
    var pat = decode(pat_s)
    var m = len(pat)
    var n = len(cps)
    if m == 0 or n < m:
        return out^

    if ignore_case:
        for k in range(m):
            pat[k] = fold(pat[k])

    var i = 0
    while i <= n - m:
        var matched = True
        for j in range(m):
            var c = fold(cps[i + j]) if ignore_case else cps[i + j]
            if c != pat[j]:
                matched = False
                break
        if matched:
            out.append(offset_to_span(cps, i, i + m))
            i += m  # Advance past non-overlapping match
        else:
            i += 1
    return out^


def search_multiline_regex(cps: List[Int], pattern: String, ignore_case: Bool = False) -> List[MatchSpan]:
    """Search for multi-line regular expression across codepoints producing MatchSpans."""
    var out = List[MatchSpan]()
    var pat_cps = decode(pattern)
    if len(pat_cps) == 0:
        return out^
    var rx = regex_compile(pat_cps, ignore_case)
    if not rx.ok:
        return out^
    var n = len(cps)
    var i = 0
    while i <= n:
        var m = rx.search(cps, i)
        if len(m) < 2:
            break
        var start_off = m[0]
        var end_off = m[1]
        if start_off < 0 or end_off <= start_off:
            i = max(i + 1, start_off + 1)
            continue
        out.append(offset_to_span(cps, start_off, end_off))
        i = end_off  # Advance past match
    return out^


struct ChunkMatchCache(Copyable, Movable):
    var chunk_keys: List[String]
    var chunk_versions: List[Int]
    var chunk_counts: List[Int]
    var chunk_pats: List[String]
    var chunk_regex: List[Bool]
    var chunk_icase: List[Bool]
    var chunk_spans: List[List[MatchSpan]]
    var hits: Int
    var misses: Int

    def __init__(out self):
        self.chunk_keys = List[String]()
        self.chunk_versions = List[Int]()
        self.chunk_counts = List[Int]()
        self.chunk_pats = List[String]()
        self.chunk_regex = List[Bool]()
        self.chunk_icase = List[Bool]()
        self.chunk_spans = List[List[MatchSpan]]()
        self.hits = 0
        self.misses = 0

    def update_and_search(
        mut self,
        chunk_key: String,
        version: Int,
        chunk_text: List[Int],
        pat: String,
        use_regex: Bool = False,
        ignore_case: Bool = False,
    ) -> List[MatchSpan]:
        """Lookup cached MatchSpans for chunk, computing and caching literal or regex matches on miss."""
        for i in range(len(self.chunk_keys)):
            if self.chunk_keys[i] == chunk_key:
                if (
                    self.chunk_versions[i] == version
                    and self.chunk_pats[i] == pat
                    and self.chunk_regex[i] == use_regex
                    and self.chunk_icase[i] == ignore_case
                ):
                    self.hits += 1
                    return self.chunk_spans[i].copy()
                else:
                    self.misses += 1
                    var matches = (
                        search_multiline_regex(chunk_text, pat, ignore_case)
                        if use_regex
                        else search_multiline_literal(chunk_text, pat, ignore_case)
                    )
                    self.chunk_versions[i] = version
                    self.chunk_counts[i] = len(matches)
                    self.chunk_pats[i] = pat
                    self.chunk_regex[i] = use_regex
                    self.chunk_icase[i] = ignore_case
                    self.chunk_spans[i] = matches.copy()
                    return matches^
        self.misses += 1
        var matches = (
            search_multiline_regex(chunk_text, pat, ignore_case)
            if use_regex
            else search_multiline_literal(chunk_text, pat, ignore_case)
        )
        self.chunk_keys.append(chunk_key)
        self.chunk_versions.append(version)
        self.chunk_counts.append(len(matches))
        self.chunk_pats.append(pat)
        self.chunk_regex.append(use_regex)
        self.chunk_icase.append(ignore_case)
        self.chunk_spans.append(matches.copy())
        return matches^

    def get_count(
        mut self,
        chunk_key: String,
        version: Int,
        chunk_text: List[Int],
        pat: String,
        use_regex: Bool = False,
        ignore_case: Bool = False,
    ) -> Int:
        """Lookup cached match count for chunk, computing and caching if missing or modified."""
        return len(self.update_and_search(chunk_key, version, chunk_text, pat, use_regex, ignore_case))
