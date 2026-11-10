"""Markdown to styled text lines, for hover windows and documentation panels.

Understands what documentation in practice uses: headings, paragraphs, fenced code blocks
(Mojo and Python blocks get the editor's syntax colours), bullet and numbered lists, block
quotes, horizontal rules, and inline **bold**, *italic*, `code`, [links](url), backslash
escapes and a few HTML entities. Paragraphs are wrapped to a width; code lines are not.
Anything else (tables, HTML, images) is shown as the text it is."""
from std.collections import List
from highlight import Highlighter
from util import decode, char_width, is_ident, to_str

comptime MD_TEXT = 0
comptime MD_BOLD = 1
comptime MD_ITALIC = 2
comptime MD_CODE = 3        # inline code
comptime MD_HEAD = 4
comptime MD_LINK = 5
comptime MD_DIM = 6         # rules, quote bars, list bullets
comptime MD_BLOCK = 16      # a code block line: MD_BLOCK + syntax class of the character


struct MdLine(Copyable, Movable):
    var cps: List[Int]
    var st: List[Int]       # one style per codepoint

    def __init__(out self):
        self.cps = List[Int]()
        self.st = List[Int]()

    def add(mut self, cp: Int, style: Int):
        self.cps.append(cp)
        self.st.append(style)

    def add_all(mut self, cps: List[Int], style: Int):
        for c in cps:
            self.cps.append(c)
            self.st.append(style)


def md_width(cps: List[Int], a: Int, b: Int) -> Int:
    var w = 0
    for i in range(a, b):
        w += char_width(cps[i])
    return w


def is_space(c: Int) -> Bool:
    return c == 32 or c == 9


def is_punct(c: Int) -> Bool:
    """ASCII punctuation: what a backslash can escape in Markdown."""
    return (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126)


def is_word_char(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c >= 0x80


def find_closing(cps: List[Int], start: Int, marker: Int, count: Int) -> Int:
    """Index of the next run of exactly-or-more `count` marker characters at or after
    `start` that could close an emphasis (not preceded by a blank); -1 if none."""
    var n = len(cps)
    var i = start
    while i + count <= n:
        if cps[i] == 92:            # backslash: skip the escaped character
            i += 2
            continue
        var all = True
        for k in range(count):
            if cps[i + k] != marker:
                all = False
                break
        if all and i > start and not is_space(cps[i - 1]):
            return i
        i += 1
    return -1


def md_inline(src: List[Int], base: Int, mut out: MdLine):
    """Parse inline markup of one paragraph's text and append it to `out`."""
    var n = len(src)
    var i = 0
    while i < n:
        var c = src[i]
        # backslash escape of punctuation
        if c == 92 and i + 1 < n and is_punct(src[i + 1]):
            out.add(src[i + 1], base)
            i += 2
            continue
        # inline code: `...` or ``...``
        if c == 96:
            var ticks = 1
            while i + ticks < n and src[i + ticks] == 96:
                ticks += 1
            var j = i + ticks
            var close = -1
            while j + ticks <= n:
                var all = True
                for k in range(ticks):
                    if src[j + k] != 96:
                        all = False
                        break
                if all and (j + ticks >= n or src[j + ticks] != 96):
                    close = j
                    break
                j += 1
            if close >= 0:
                for k in range(i + ticks, close):
                    out.add(src[k], MD_CODE)
                i = close + ticks
                continue
            out.add(c, base)
            i += 1
            continue
        # bold: **text** or __text__
        if (c == 42 or c == 95) and i + 1 < n and src[i + 1] == c and i + 2 < n and not is_space(src[i + 2]) and (i == 0 or not is_word_char(src[i - 1])):
            var close = find_closing(src, i + 2, c, 2)
            if close > i + 2:
                var inner = List[Int]()
                for k in range(i + 2, close):
                    inner.append(src[k])
                md_inline(inner, MD_BOLD if base == MD_TEXT or base == MD_ITALIC else base, out)
                i = close + 2
                continue
        # italic: *text* or _text_ (an underscore inside a word is just an underscore)
        if (c == 42 or c == 95) and i + 1 < n and not is_space(src[i + 1]) and src[i + 1] != c:
            var word_ok = i == 0 or not is_word_char(src[i - 1])
            var close = find_closing(src, i + 1, c, 1)
            if word_ok and close > i + 1 and (c == 42 or close + 1 >= n or not is_ident(src[close + 1])):
                var inner = List[Int]()
                for k in range(i + 1, close):
                    inner.append(src[k])
                md_inline(inner, MD_ITALIC if base == MD_TEXT else base, out)
                i = close + 1
                continue
        # link: [text](url) shows the text; <http://...> shows the address
        if c == 91:
            var rb = -1
            var depth = 0
            for k in range(i + 1, n):
                if src[k] == 91:
                    depth += 1
                elif src[k] == 93:
                    if depth == 0:
                        rb = k
                        break
                    depth -= 1
            if rb > i and rb + 1 < n and src[rb + 1] == 40:
                var rp = -1
                for k in range(rb + 2, n):
                    if src[k] == 41:
                        rp = k
                        break
                if rp > 0:
                    var inner = List[Int]()
                    for k in range(i + 1, rb):
                        inner.append(src[k])
                    md_inline(inner, MD_LINK, out)
                    i = rp + 1
                    continue
        if c == 60:
            var gt = -1
            for k in range(i + 1, n):
                if src[k] == 62:
                    gt = k
                    break
                if is_space(src[k]):
                    break
            if gt > i + 8 and src[i + 1] == 104 and src[i + 2] == 116 and src[i + 3] == 116 and src[i + 4] == 112:
                for k in range(i + 1, gt):
                    out.add(src[k], MD_LINK)
                i = gt + 1
                continue
        # a few HTML entities
        if c == 38:
            var names: List[String] = ["&lt;", "&gt;", "&amp;", "&quot;", "&nbsp;", "&#39;"]
            var vals: List[Int] = [60, 62, 38, 34, 32, 39]
            var hit = False
            for e in range(len(names)):
                var ec = decode(names[e])
                if i + len(ec) <= n:
                    var same = True
                    for k in range(len(ec)):
                        if src[i + k] != ec[k]:
                            same = False
                            break
                    if same:
                        out.add(vals[e], base)
                        i += len(ec)
                        hit = True
                        break
            if hit:
                continue
        out.add(32 if c == 9 else c, base)
        i += 1


def md_wrap(text: MdLine, width: Int, first: MdLine, rest: MdLine, mut out: List[MdLine]):
    """Break styled text into lines of at most `width` columns. The first line starts
    with `first`, the following ones with `rest` (for bullets and hanging indents)."""
    var w = max(8, width)
    var n = len(text.cps)
    var i = 0
    var is_first = True
    while True:
        # skip blanks at the start of a line
        while i < n and text.cps[i] == 32:
            i += 1
        var line = first.copy() if is_first else rest.copy()
        if i >= n:
            if is_first:
                out.append(line^)
            return
        var room = w - md_width(line.cps, 0, len(line.cps))
        if room < 4:
            room = 4
        # take as much as fits, then back up to the last blank
        var j = i
        var used = 0
        var last_space = -1
        while j < n:
            var cw = char_width(text.cps[j])
            if used + cw > room:
                break
            if text.cps[j] == 32:
                last_space = j
            used += cw
            j += 1
        var end = j
        if j < n and text.cps[j] != 32 and last_space > i:
            end = last_space        # the word does not fit: break before it
        if end == i:
            end = i + 1             # a single character wider than the room
        for k in range(i, end):
            line.add(text.cps[k], text.st[k])
        # no blanks at the end of a line
        while len(line.cps) > 0 and line.cps[len(line.cps) - 1] == 32:
            _ = line.cps.pop()
            _ = line.st.pop()
        out.append(line^)
        i = end
        is_first = False


def is_rule(line: List[Int]) -> Bool:
    """--- *** ___ (three or more, blanks allowed between)."""
    var marker = 0
    var count = 0
    for c in line:
        if is_space(c):
            continue
        if c != 45 and c != 42 and c != 95:
            return False
        if marker == 0:
            marker = c
        elif c != marker:
            return False
        count += 1
    return count >= 3


def md_gap(lines_so_far: Int, last_kind: Int, kind: Int, blank_seen: Bool) -> Bool:
    """Should a blank line go before a block of `kind`? Not at the top and not next to
    a rule; otherwise between blocks of different kinds, between paragraphs, and
    wherever the source had one (so list items stay together unless written apart)."""
    if lines_so_far == 0 or last_kind == 4 or kind == 4:
        return False
    return blank_seen or last_kind != kind or kind == 1


def md_render(text: String, width: Int, hl: Highlighter) -> List[MdLine]:
    """The Markdown `text` as styled lines no wider than `width` columns (code block
    lines may be wider; the caller clips them)."""
    var out = List[MdLine]()
    var w = max(8, width)
    var src = decode(text)
    src.append(10)
    # split into lines
    var lines = List[List[Int]]()
    var cur = List[Int]()
    for c in src:
        if c == 10:
            lines.append(cur.copy())
            cur.clear()
        elif c != 13:
            cur.append(c)
    var para = MdLine()             # the paragraph being collected
    var para_src = List[Int]()
    var in_code = False
    var code_lang_ok = False
    var code_state = 0
    # for the blank lines between blocks: what the last block was (0 nothing, 1
    # paragraph, 2 heading, 3 code, 4 rule, 5 quote, 6 list item) and whether the
    # source had a blank line since
    var last_kind = 0
    var blank_seen = False
    var classes = List[Int]()
    var k = 0
    while k <= len(lines):
        var at_end = k == len(lines)
        var line = List[Int]() if at_end else lines[k].copy()
        k += 1
        # leading blanks and the rest
        var ind = 0
        while ind < len(line) and is_space(line[ind]):
            ind += 1
        var blank = ind == len(line)
        var fence = not at_end and len(line) - ind >= 3 and ((line[ind] == 96 and line[ind + 1] == 96 and line[ind + 2] == 96) or (line[ind] == 126 and line[ind + 1] == 126 and line[ind + 2] == 126))
        if in_code:
            if fence or at_end:
                in_code = False
                continue
            var row = MdLine()
            var plain = List[Int]()
            for c in line:
                if c == 9:
                    for _ in range(4):
                        plain.append(32)
                else:
                    plain.append(c)
            if code_lang_ok:
                code_state = hl.line(plain, code_state, classes)
                for q in range(len(plain)):
                    row.add(plain[q], MD_BLOCK + classes[q])
            else:
                row.add_all(plain, MD_BLOCK)
            out.append(row^)
            continue
        # anything that is not paragraph text ends the paragraph in progress
        var heading = 0
        if not blank and line[ind] == 35:
            var h = ind
            while h < len(line) and line[h] == 35:
                h += 1
            if h - ind <= 6 and (h == len(line) or is_space(line[h])):
                heading = h - ind
        var rule = not blank and heading == 0 and is_rule(line)
        var quote = not blank and line[ind] == 62
        var bullet = 0              # length of the list marker including the blank after it
        if not blank and heading == 0 and not rule:
            if (line[ind] == 45 or line[ind] == 42 or line[ind] == 43) and ind + 1 < len(line) and is_space(line[ind + 1]):
                bullet = 2
            else:
                var d = ind
                while d < len(line) and line[d] >= 48 and line[d] <= 57:
                    d += 1
                if d > ind and d - ind <= 3 and d + 1 < len(line) and (line[d] == 46 or line[d] == 41) and is_space(line[d + 1]):
                    bullet = d - ind + 2
        var breaks = at_end or blank or fence or heading > 0 or rule or quote or bullet > 0
        if breaks and len(para_src) > 0:
            if md_gap(len(out), last_kind, 1, blank_seen):
                out.append(MdLine())
            last_kind = 1
            blank_seen = False
            md_inline(para_src, MD_TEXT, para)
            md_wrap(para, w, MdLine(), MdLine(), out)
            para = MdLine()
            para_src.clear()
        if at_end:
            break
        if blank:
            blank_seen = True
            continue
        if fence:
            # the language after the fence decides whether to colour the code
            var lang = List[Int]()
            for q in range(ind + 3, len(line)):
                if not is_space(line[q]) and line[q] != 96 and line[q] != 126:
                    var lc = line[q]
                    if lc >= 65 and lc <= 90:
                        lc += 32
                    lang.append(lc)
            var name = to_str(lang)
            code_lang_ok = len(lang) == 0 or name == "mojo" or name == "python" or name == "py" or name == "🔥"
            code_state = 0
            in_code = True
            if md_gap(len(out), last_kind, 3, blank_seen):
                out.append(MdLine())
            last_kind = 3
            blank_seen = False
            continue
        if heading > 0:
            var body = List[Int]()
            var q = ind + heading
            while q < len(line) and is_space(line[q]):
                q += 1
            var e = len(line)
            # closing #s of "## title ##"
            while e > q and (line[e - 1] == 35 or is_space(line[e - 1])):
                e -= 1
            for z in range(q, e):
                body.append(line[z])
            if len(body) == 0:
                continue            # "###" alone: some servers use it as a spacer
            if md_gap(len(out), last_kind, 2, blank_seen):
                out.append(MdLine())
            last_kind = 2
            blank_seen = False
            var hline = MdLine()
            md_inline(body, MD_HEAD, hline)
            # inline code inside a heading keeps the heading look
            for z in range(len(hline.st)):
                if hline.st[z] == MD_CODE:
                    hline.st[z] = MD_HEAD
            md_wrap(hline, w, MdLine(), MdLine(), out)
            continue
        if rule:
            # a rule between blocks; none at the very top
            if len(out) > 0:
                var r = MdLine()
                for _ in range(w):
                    r.add(0x2500, MD_DIM)
                out.append(r^)
                last_kind = 4
            blank_seen = False
            continue
        if quote:
            var body = List[Int]()
            var q = ind + 1
            if q < len(line) and is_space(line[q]):
                q += 1
            for z in range(q, len(line)):
                body.append(line[z])
            if md_gap(len(out), last_kind, 5, blank_seen):
                out.append(MdLine())
            last_kind = 5
            blank_seen = False
            var qt = MdLine()
            md_inline(body, MD_ITALIC, qt)
            var bar = MdLine()
            bar.add(0x2502, MD_DIM)
            bar.add(32, MD_DIM)
            md_wrap(qt, w, bar, bar, out)
            continue
        if bullet > 0:
            var body = List[Int]()
            for z in range(ind + bullet, len(line)):
                body.append(line[z])
            # the item may go on in following lines that are indented text
            while k < len(lines):
                var nx = lines[k].copy()
                var ni = 0
                while ni < len(nx) and is_space(nx[ni]):
                    ni += 1
                if ni == len(nx) or ni < ind + 2 or nx[ni] == 45 or nx[ni] == 42 or nx[ni] == 43 or nx[ni] == 35 or nx[ni] == 96 or (nx[ni] >= 48 and nx[ni] <= 57):
                    break
                body.append(32)
                for z in range(ni, len(nx)):
                    body.append(nx[z])
                k += 1
            if md_gap(len(out), last_kind, 6, blank_seen):
                out.append(MdLine())
            last_kind = 6
            blank_seen = False
            var item = MdLine()
            md_inline(body, MD_TEXT, item)
            var first = MdLine()
            var rest = MdLine()
            var depth = min(ind, 12)
            for _ in range(depth):
                first.add(32, MD_TEXT)
                rest.add(32, MD_TEXT)
            if bullet == 2:
                first.add(0x2022, MD_DIM)
                first.add(32, MD_DIM)
                rest.add(32, MD_TEXT)
                rest.add(32, MD_TEXT)
            else:
                for z in range(ind, ind + bullet):
                    first.add(line[z], MD_DIM)
                    rest.add(32, MD_TEXT)
            md_wrap(item, w, first, rest, out)
            continue
        # ordinary text: part of a paragraph
        if len(para_src) > 0:
            para_src.append(32)
        for z in range(ind, len(line)):
            para_src.append(line[z])
    # no blank lines at the end
    while len(out) > 0 and len(out[len(out) - 1].cps) == 0:
        _ = out.pop()
    return out^


def md_plain(lines: List[MdLine]) -> String:
    """The rendered lines as plain text (for tests and for copying)."""
    var out = String("")
    for i in range(len(lines)):
        if i > 0:
            out += "\n"
        out += to_str(lines[i].cps)
    return out
