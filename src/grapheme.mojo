"""Grapheme clusters: what a user perceives as one character.

A cluster can be several codepoints: a letter with combining accents, an emoji with a skin
tone or a variation selector, a ZWJ sequence such as a family, a flag made of two regional
indicators, or Hangul jamo forming a syllable. The cursor moves, and Delete removes, one
cluster at a time.

The rules follow Unicode UAX #29 (extended grapheme clusters): GB6-8 (Hangul), GB9
(Extend, ZWJ), GB9a (spacing marks), GB11 (emoji ZWJ sequences), GB12/13 (regional
indicator pairs). The character classes are range tables covering the scripts and emoji in
common use, not the full Unicode database. Not implemented: GB9b (Prepend) and GB9c
(Indic conjuncts), so a Devanagari conjunct is split after its virama."""
from std.collections import List
from util import char_width, in_ranges

comptime G_OTHER = 0
comptime G_EXTEND = 1
comptime G_ZWJ = 2
comptime G_SPACING = 3
comptime G_RI = 4          # regional indicator
comptime G_PICT = 5        # Extended_Pictographic (emoji base)
comptime G_L = 6           # Hangul leading consonant
comptime G_V = 7
comptime G_T = 8
comptime G_LV = 9
comptime G_LVT = 10


def g_class(cp: Int) -> Int:
    if cp < 0x300:
        if cp == 0xA9 or cp == 0xAE:
            return G_PICT
        return G_OTHER
    if cp == 0x200D:
        return G_ZWJ
    if cp >= 0x1F1E6 and cp <= 0x1F1FF:
        return G_RI
    # Hangul
    if (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0xA960 and cp <= 0xA97C):
        return G_L
    if (cp >= 0x1160 and cp <= 0x11A7) or (cp >= 0xD7B0 and cp <= 0xD7C6):
        return G_V
    if (cp >= 0x11A8 and cp <= 0x11FF) or (cp >= 0xD7CB and cp <= 0xD7FB):
        return G_T
    if cp >= 0xAC00 and cp <= 0xD7A3:
        return G_LV if (cp - 0xAC00) % 28 == 0 else G_LVT
    var extend: List[Int] = [
        0x0300, 0x036F, 0x0483, 0x0489, 0x0591, 0x05BD, 0x05BF, 0x05BF, 0x05C1, 0x05C2,
        0x05C4, 0x05C5, 0x05C7, 0x05C7, 0x0610, 0x061A, 0x064B, 0x065F, 0x0670, 0x0670,
        0x06D6, 0x06DC, 0x06DF, 0x06E4, 0x06E7, 0x06E8, 0x06EA, 0x06ED, 0x0900, 0x0902,
        0x093A, 0x093A, 0x093C, 0x093C, 0x0941, 0x0948, 0x094D, 0x094D, 0x0951, 0x0957,
        0x0E31, 0x0E31, 0x0E34, 0x0E3A, 0x0E47, 0x0E4E, 0x1AB0, 0x1AFF, 0x1DC0, 0x1DFF,
        0x200C, 0x200C, 0x20D0, 0x20FF, 0x302A, 0x302F, 0x3099, 0x309A, 0xFE00, 0xFE0F,
        0xFE20, 0xFE2F, 0x1F3FB, 0x1F3FF, 0xE0020, 0xE007F, 0xE0100, 0xE01EF,
    ]
    if in_ranges(cp, extend):
        return G_EXTEND
    var spacing: List[Int] = [0x0903, 0x0903, 0x093B, 0x093B, 0x093E, 0x0940, 0x0949, 0x094C, 0x094E, 0x094F]
    if in_ranges(cp, spacing):
        return G_SPACING
    var pict: List[Int] = [
        0x203C, 0x203C, 0x2049, 0x2049, 0x2122, 0x2122, 0x2139, 0x2139, 0x2194, 0x2199,
        0x21A9, 0x21AA, 0x231A, 0x231B, 0x2328, 0x2328, 0x23CF, 0x23CF, 0x23E9, 0x23F3,
        0x23F8, 0x23FA, 0x24C2, 0x24C2, 0x25AA, 0x25AB, 0x25B6, 0x25B6, 0x25C0, 0x25C0,
        0x25FB, 0x25FE, 0x2600, 0x27BF, 0x2934, 0x2935, 0x2B05, 0x2B07, 0x2B1B, 0x2B1C,
        0x2B50, 0x2B50, 0x2B55, 0x2B55, 0x3030, 0x3030, 0x303D, 0x303D, 0x3297, 0x3297,
        0x3299, 0x3299, 0x1F000, 0x1F1E5, 0x1F200, 0x1F3FA, 0x1F400, 0x1FAFF, 0x1FC00, 0x1FFFD,
    ]
    if in_ranges(cp, pict):
        return G_PICT
    return G_OTHER


def cluster_end(cps: List[Int], start: Int) -> Int:
    """Index just past the grapheme cluster that begins at `start`."""
    var n = len(cps)
    if start >= n:
        return n
    var i = start + 1
    var first = cps[start]
    if first < 32 or first == 127:
        return i                      # GB4: a control character (tab included) stands alone
    if first < 0x300 and (i >= n or cps[i] < 0x300):
        return i                      # plain text: nothing can attach
    var prev = g_class(first)
    var ri_count = 1 if prev == G_RI else 0
    # for GB11: are we inside "ExtPict Extend*" (so that ZWJ + ExtPict may continue)?
    var pict_run = prev == G_PICT
    var after_pict_zwj = False
    while i < n:
        var cur = g_class(cps[i])
        var join = False
        if cur == G_EXTEND or cur == G_ZWJ or cur == G_SPACING:
            join = True                                          # GB9, GB9a
        elif prev == G_L and (cur == G_L or cur == G_V or cur == G_LV or cur == G_LVT):
            join = True                                          # GB6
        elif (prev == G_LV or prev == G_V) and (cur == G_V or cur == G_T):
            join = True                                          # GB7
        elif (prev == G_LVT or prev == G_T) and cur == G_T:
            join = True                                          # GB8
        elif after_pict_zwj and cur == G_PICT:
            join = True                                          # GB11
        elif prev == G_RI and cur == G_RI and ri_count % 2 == 1:
            join = True                                          # GB12/13: pairs only
        if not join:
            break
        after_pict_zwj = cur == G_ZWJ and pict_run
        if cur == G_PICT:
            pict_run = True
        elif cur != G_EXTEND:
            pict_run = False      # a ZWJ ends the run: only one may sit before the next emoji
        if cur == G_RI:
            ri_count += 1
        prev = cur
        i += 1
    return i


def cluster_start(cps: List[Int], pos: Int) -> Int:
    """Start of the cluster that ends at `pos` (i.e. the previous cluster boundary).
    Clusters depend on what comes before, so this walks forward from the line start."""
    if pos <= 0:
        return 0
    var i = 0
    var last = 0
    var lim = min(pos, len(cps))
    while i < lim:
        last = i
        i = cluster_end(cps, i)
    return last


def snap_to_cluster(cps: List[Int], pos: Int) -> Int:
    """`pos` if it is a cluster boundary, otherwise the start of the cluster around it."""
    if pos <= 0:
        return 0
    if pos >= len(cps):
        return len(cps)
    var i = 0
    while i < pos:
        var e = cluster_end(cps, i)
        if e > pos:
            return i
        i = e
    return pos


def cluster_count(cps: List[Int]) -> Int:
    var n = 0
    var i = 0
    while i < len(cps):
        i = cluster_end(cps, i)
        n += 1
    return n


def cluster_width(cps: List[Int], start: Int, end: Int, clustered: Bool) -> Int:
    """Terminal columns a cluster occupies.

    Most terminals lay text out codepoint by codepoint, so the width is the sum of the
    codepoint widths (a ZWJ family shows as its members side by side). A terminal with
    grapheme clustering (mode 2027) draws the cluster as one glyph: `clustered` selects
    that model, where the first codepoint decides, an emoji presentation selector
    (U+FE0F) or a second regional indicator makes it two columns, and nothing else adds."""
    if start >= end:
        return 0
    if not clustered:
        var w = 0
        for i in range(start, end):
            w += char_width(cps[i])
        return w
    var w = char_width(cps[start])
    if w == 0:
        return 0
    for i in range(start + 1, end):
        if cps[i] == 0xFE0F:
            return 2
        if cps[i] >= 0x1F1E6 and cps[i] <= 0x1F1FF:
            return 2
    return w


def ends_with_plain_mark(cps: List[Int], start: Int, end: Int) -> Bool:
    """True when the cluster's last codepoint is an ordinary combining mark on a base
    letter (not a selector, joiner, tag or emoji modifier). Backspace then removes just
    that mark, so an accent can be corrected without retyping the letter."""
    if end - start < 2:
        return False
    var c = cps[end - 1]
    if g_class(c) != G_EXTEND:
        return False
    if (c >= 0xFE00 and c <= 0xFE0F) or c == 0x200C or (c >= 0x1F3FB and c <= 0x1F3FF) or (c >= 0xE0020 and c <= 0xE007F) or (c >= 0x20D0 and c <= 0x20FF):
        return False
    for i in range(start, end):
        var k = g_class(cps[i])
        if k == G_PICT or k == G_RI or k == G_ZWJ:
            return False
    return True
