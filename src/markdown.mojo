"""Markdown to styled text lines, for hover windows and documentation panels.

Understands what documentation in practice uses: headings, paragraphs, fenced code blocks
(Mojo and Python blocks get the editor's syntax colours), bullet and numbered lists, block
quotes, horizontal rules, and inline **bold**, *italic*, `code`, [links](url), backslash
escapes and a few HTML entities, tables (in the rich form), and images - Markdown
`![alt](src)` and HTML `<img src=... alt=...>` - as a "[image: alt]" link to the picture.
Paragraphs are wrapped to a width; code lines are not. Other HTML is shown as the text
it is."""
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
comptime MD_STRIKE = 7      # ~~strikethrough~~
comptime MD_BLOCK = 16      # a code block line: MD_BLOCK + syntax class of the character


struct MdLine(Copyable, Movable):
    var cps: List[Int]
    var st: List[Int]       # one style per codepoint
    var img: Int            # a row of a picture: its index in the reader's images (-1: text)
    var img_row: Int        # ...and which row of it

    def __init__(out self):
        self.cps = List[Int]()
        self.st = List[Int]()
        self.img = -1
        self.img_row = -1

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
    var links = List[String]()
    var from_at = len(out.st)
    md_inline_links(src, base, out, links)
    for k in range(from_at, len(out.st)):
        if out.st[k] < 0:
            out.st[k] = MD_LINK


def lower_ascii(c: Int) -> Int:
    return c + 32 if c >= 65 and c <= 90 else c


def starts_at(src: List[Int], i: Int, word: String) -> Bool:
    """`word` (ASCII, compared without case) at src[i]."""
    var w = decode(word)
    if i + len(w) > len(src):
        return False
    for k in range(len(w)):
        if lower_ascii(src[i + k]) != w[k]:
            return False
    return True


def html_attr(tag: List[Int], name: String) -> String:
    """The value of attribute `name` in an HTML tag's text (quoted with " or ', or bare),
    "" if it has none. Names are compared without case."""
    var n = len(tag)
    var i = 0
    var nl = len(decode(name))
    while i < n:
        if starts_at(tag, i, name) and (i == 0 or is_space(tag[i - 1])):
            var j = i + nl
            while j < n and is_space(tag[j]):
                j += 1
            if j < n and tag[j] == 61:
                j += 1
                while j < n and is_space(tag[j]):
                    j += 1
                var out = List[Int]()
                if j < n and (tag[j] == 34 or tag[j] == 39):
                    var q = tag[j]
                    j += 1
                    while j < n and tag[j] != q:
                        out.append(tag[j])
                        j += 1
                else:
                    while j < n and not is_space(tag[j]) and tag[j] != 62 and tag[j] != 47:
                        out.append(tag[j])
                        j += 1
                return to_str(out)
        i += 1
    return ""


def image_name(src: String) -> String:
    """The file name an image address ends in (no directory, query or fragment)."""
    var cps = decode(src)
    var end = len(cps)
    for k in range(len(cps)):
        if cps[k] == 63 or cps[k] == 35:
            end = k
            break
    var start = 0
    for k in range(end):
        if cps[k] == 47:
            start = k + 1
    var out = List[Int]()
    for k in range(start, end):
        out.append(cps[k])
    return to_str(out)


def image_only(line: MdLine) -> Int:
    """The link index of a line that is one picture and nothing else ("[image: ...]"
    as a single link), -1 otherwise."""
    var n = len(line.cps)
    if n < 7 or line.cps[0] != 91 or line.cps[n - 1] != 93:
        return -1
    var st = line.st[0]
    if st >= 0:
        return -1
    for s in line.st:
        if s != st:
            return -1
    if not to_str(line.cps).startswith("[image"):
        return -1
    return -st - 1


def is_image_name(src: String) -> Bool:
    """The address names a picture (by its extension)."""
    var n = image_name(src).lower()
    for ext in [".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".bmp"]:
        if n.endswith(String(ext)):
            return True
    return False


def image_label(alt: List[Int], src: String) -> List[Int]:
    """What stands for an image in text: "[image: alt]", or the file name without alt."""
    var out = decode("[image: ")
    var shown = alt.copy()
    var blank = True
    for c in alt:
        if not is_space(c):
            blank = False
    if blank:
        shown = decode(image_name(src))
    if len(shown) == 0:
        return decode("[image]")
    for c in shown:
        out.append(32 if c == 10 or c == 9 else c)
    out.append(93)
    return out^


def add_image(alt: List[Int], src: String, mut out: MdLine, mut links: List[String]):
    links.append(src)
    out.add_all(image_label(alt, src), -len(links))


def md_inline_links(src: List[Int], base: Int, mut out: MdLine, mut links: List[String]):
    """md_inline that also keeps where links lead: the address of each link is added to
    `links`, and the link's characters get the style -(its index in `links`) - 1."""
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
        # strikethrough: ~~text~~
        if c == 126 and i + 1 < n and src[i + 1] == 126 and i + 2 < n and not is_space(src[i + 2]) and src[i + 2] != 126:
            var close = find_closing(src, i + 2, 126, 2)
            if close > i + 2:
                var inner = List[Int]()
                for k in range(i + 2, close):
                    inner.append(src[k])
                md_inline_links(inner, MD_STRIKE if base == MD_TEXT else base, out, links)
                i = close + 2
                continue
        # bold: **text** or __text__
        if (c == 42 or c == 95) and i + 1 < n and src[i + 1] == c and i + 2 < n and not is_space(src[i + 2]) and (i == 0 or not is_word_char(src[i - 1])):
            var close = find_closing(src, i + 2, c, 2)
            if close > i + 2:
                var inner = List[Int]()
                for k in range(i + 2, close):
                    inner.append(src[k])
                md_inline_links(inner, MD_BOLD if base == MD_TEXT or base == MD_ITALIC else base, out, links)
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
                md_inline_links(inner, MD_ITALIC if base == MD_TEXT else base, out, links)
                i = close + 1
                continue
        # image: ![alt](src "title") - the alt text stands for it, as a link to the picture
        if c == 33 and i + 1 < n and src[i + 1] == 91:
            var rb = -1
            for k in range(i + 2, n):
                if src[k] == 93:
                    rb = k
                    break
            if rb > i and rb + 1 < n and src[rb + 1] == 40:
                var rp = -1
                for k in range(rb + 2, n):
                    if src[k] == 41:
                        rp = k
                        break
                if rp > 0:
                    var alt = List[Int]()
                    for k in range(i + 2, rb):
                        alt.append(src[k])
                    var target = List[Int]()
                    var k = rb + 2
                    while k < rp and is_space(src[k]):
                        k += 1
                    while k < rp and not is_space(src[k]):
                        target.append(src[k])
                        k += 1
                    add_image(alt, to_str(target), out, links)
                    i = rp + 1
                    continue
        # <img src="..." alt="..."> in HTML
        if c == 60 and starts_at(src, i + 1, "img") and i + 4 < n and (is_space(src[i + 4]) or src[i + 4] == 47 or src[i + 4] == 62):
            var gt = -1
            for k in range(i + 4, n):
                if src[k] == 62:
                    gt = k
                    break
            if gt > 0:
                var tag = List[Int]()
                for k in range(i + 4, gt):
                    tag.append(src[k])
                var isrc = html_attr(tag, "src")
                if isrc.byte_length() > 0:
                    add_image(decode(html_attr(tag, "alt")), isrc, out, links)
                    i = gt + 1
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
                    var target = List[Int]()
                    for k in range(rb + 2, rp):
                        target.append(src[k])
                    var p0 = len(out.st)
                    var inner_links = List[String]()
                    md_inline_links(inner, MD_LINK, out, inner_links)
                    links.append(to_str(target))
                    for k in range(p0, len(out.st)):
                        if out.st[k] == MD_LINK or out.st[k] < 0:
                            out.st[k] = -len(links)
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
                var target = List[Int]()
                for k in range(i + 1, gt):
                    target.append(src[k])
                links.append(to_str(target))
                for k in range(i + 1, gt):
                    out.add(src[k], -len(links))
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
    var links = List[String]()
    var out = md_render_rich(text, width, hl, links, False)
    for k in range(len(out)):
        for q in range(len(out[k].st)):
            if out[k].st[q] < 0:
                out[k].st[q] = MD_LINK
    return out^


def table_cells(line: List[Int]) -> List[List[Int]]:
    """The cells of a table row "| a | b |" (outer bars optional, \\| is a bar in a cell)."""
    var cells = List[List[Int]]()
    var cur = List[Int]()
    var a = 0
    var b = len(line)
    while a < b and is_space(line[a]):
        a += 1
    while b > a and is_space(line[b - 1]):
        b -= 1
    if a < b and line[a] == 124:
        a += 1
    if b > a and line[b - 1] == 124 and not (b - 2 >= a and line[b - 2] == 92):
        b -= 1
    var i = a
    while i < b:
        if line[i] == 92 and i + 1 < b and line[i + 1] == 124:
            cur.append(124)
            i += 2
            continue
        if line[i] == 124:
            cells.append(cur.copy())
            cur.clear()
        else:
            cur.append(line[i])
        i += 1
    cells.append(cur.copy())
    # trim
    for k in range(len(cells)):
        var c = cells[k].copy()
        var x = 0
        var y = len(c)
        while x < y and is_space(c[x]):
            x += 1
        while y > x and is_space(c[y - 1]):
            y -= 1
        var t = List[Int]()
        for q in range(x, y):
            t.append(c[q])
        cells[k] = t^
    return cells^


def is_table_rule(line: List[Int]) -> Bool:
    """The line under a table's header: bars, dashes, colons and blanks, with a dash."""
    var dash = False
    var bar = False
    for c in line:
        if c == 45:
            dash = True
        elif c == 124:
            bar = True
        elif c != 58 and not is_space(c):
            return False
    return dash and bar


def md_table(rows: List[List[List[Int]]], width: Int, mut links: List[String], mut out: List[MdLine]):
    """Draw a table (the first row is its header) as a grid no wider than `width`:
    columns as wide as their longest cell, the widest ones narrowed and their cells
    wrapped if it would not fit."""
    var ncol = 0
    for r in rows:
        ncol = max(ncol, len(r))
    if ncol == 0:
        return
    # every cell as styled text
    var cells = List[List[MdLine]]()
    var widths = List[Int]()
    for _ in range(ncol):
        widths.append(1)
    for ri in range(len(rows)):
        var line_cells = List[MdLine]()
        for ci in range(ncol):
            var m = MdLine()
            if ci < len(rows[ri]):
                md_inline_links(rows[ri][ci], MD_BOLD if ri == 0 else MD_TEXT, m, links)
            widths[ci] = max(widths[ci], md_width(m.cps, 0, len(m.cps)))
            line_cells.append(m^)
        cells.append(line_cells^)
    # fit: borders take 3 columns per cell and one more
    var room = max(ncol * 4, width - (3 * ncol + 1))
    var total = 0
    for wv in widths:
        total += wv
    while total > room:
        var widest = 0
        for ci in range(ncol):
            if widths[ci] > widths[widest]:
                widest = ci
        if widths[widest] <= 4:
            break
        widths[widest] -= 1
        total -= 1
    def_rule(widths, 0x250C, 0x252C, 0x2510, out)
    for ri in range(len(cells)):
        # wrap each cell to its column; the row is as high as its highest cell
        var wrapped = List[List[MdLine]]()
        var height = 1
        for ci in range(ncol):
            var part = List[MdLine]()
            md_wrap(cells[ri][ci], widths[ci], MdLine(), MdLine(), part)
            if len(part) == 0:
                part.append(MdLine())
            height = max(height, len(part))
            wrapped.append(part^)
        for h in range(height):
            var row = MdLine()
            row.add(0x2502, MD_DIM)
            for ci in range(ncol):
                row.add(32, MD_TEXT)
                var used = 0
                if h < len(wrapped[ci]):
                    for q in range(len(wrapped[ci][h].cps)):
                        row.add(wrapped[ci][h].cps[q], wrapped[ci][h].st[q])
                    used = md_width(wrapped[ci][h].cps, 0, len(wrapped[ci][h].cps))
                for _ in range(max(0, widths[ci] - used)):
                    row.add(32, MD_TEXT)
                row.add(32, MD_TEXT)
                row.add(0x2502, MD_DIM)
            out.append(row^)
        if ri == 0 and len(cells) > 1:
            def_rule(widths, 0x251C, 0x253C, 0x2524, out)
    def_rule(widths, 0x2514, 0x2534, 0x2518, out)


def def_rule(widths: List[Int], left: Int, mid: Int, right: Int, mut out: List[MdLine]):
    var r = MdLine()
    r.add(left, MD_DIM)
    for ci in range(len(widths)):
        for _ in range(widths[ci] + 2):
            r.add(0x2500, MD_DIM)
        r.add(right if ci == len(widths) - 1 else mid, MD_DIM)
    out.append(r^)


def md_render_rich(text: String, width: Int, hl: Highlighter, mut links: List[String], rich: Bool) -> List[MdLine]:
    """md_render for whole documents. The addresses of links are collected in `links`
    (a link's characters have the style -(index) - 1). With `rich`, tables are drawn
    as grids and first- and second-level headings get a rule under them."""
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
        var table = rich and not blank and not at_end and heading == 0 and bullet == 0 and line[ind] == 124 and k < len(lines) and is_table_rule(lines[k])
        var breaks = at_end or blank or fence or heading > 0 or rule or quote or bullet > 0 or table
        if breaks and len(para_src) > 0:
            if md_gap(len(out), last_kind, 1, blank_seen):
                out.append(MdLine())
            last_kind = 1
            blank_seen = False
            md_inline_links(para_src, MD_TEXT, para, links)
            md_wrap(para, w, MdLine(), MdLine(), out)
            para = MdLine()
            para_src.clear()
        if at_end:
            break
        if blank:
            blank_seen = True
            continue
        if table:
            var rows = List[List[List[Int]]]()
            rows.append(table_cells(line))
            k += 1                      # the rule under the header
            while k < len(lines):
                var tl = lines[k].copy()
                var ti = 0
                while ti < len(tl) and is_space(tl[ti]):
                    ti += 1
                if ti == len(tl) or tl[ti] != 124:
                    break
                rows.append(table_cells(tl))
                k += 1
            if md_gap(len(out), last_kind, 7, blank_seen):
                out.append(MdLine())
            last_kind = 7
            blank_seen = False
            md_table(rows, w, links, out)
            continue
        if fence:
            # the language is the first word after the fence (before spaces, commas or attributes)
            var q0 = ind + 3
            while q0 < len(line) and (line[q0] == 96 or line[q0] == 126):
                q0 += 1
            while q0 < len(line) and is_space(line[q0]):
                q0 += 1
            var lang = List[Int]()
            var q = q0
            while q < len(line) and not is_space(line[q]) and line[q] != 44 and line[q] != 123 and line[q] != 58:
                var lc = line[q]
                if lc >= 65 and lc <= 90:
                    lc += 32
                lang.append(lc)
                q += 1
            var info_rest = List[Int]()
            for r0 in range(q, len(line)):
                info_rest.append(line[r0])
            var fence_title = html_attr(info_rest, "title")
            var name = to_str(lang)
            code_lang_ok = len(lang) == 0 or name == "mojo" or name == "python" or name == "py" or name == "🔥"
            code_state = 0
            in_code = True
            if md_gap(len(out), last_kind, 3, blank_seen):
                out.append(MdLine())
            if rich and fence_title.byte_length() > 0:
                var th = MdLine()
                th.add_all(decode("── " + fence_title + " ──"), MD_DIM)
                out.append(th^)
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
            md_inline_links(body, MD_HEAD, hline, links)
            # inline code inside a heading keeps the heading look
            for z in range(len(hline.st)):
                if hline.st[z] == MD_CODE:
                    hline.st[z] = MD_HEAD
            var before = len(out)
            md_wrap(hline, w, MdLine(), MdLine(), out)
            if rich and heading <= 2:
                # the big headings stand on a rule as long as their text
                var longest = 1
                for z in range(before, len(out)):
                    longest = max(longest, md_width(out[z].cps, 0, len(out[z].cps)))
                var under = MdLine()
                for _ in range(min(w, longest if heading == 2 else w)):
                    under.add(0x2550 if heading == 1 else 0x2500, MD_DIM)
                out.append(under^)
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
            md_inline_links(body, MD_ITALIC, qt, links)
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
            var task_glyph = 0
            if (
                bullet == 2
                and len(body) >= 3
                and body[0] == 91
                and (body[1] == 32 or body[1] == 120 or body[1] == 88)
                and body[2] == 93
                and (len(body) == 3 or is_space(body[3]))
            ):
                task_glyph = 0x2610 if body[1] == 32 else 0x2611
                var strip_n = 4 if len(body) > 3 and is_space(body[3]) else 3
                var trimmed_body = List[Int]()
                for z in range(strip_n, len(body)):
                    trimmed_body.append(body[z])
                body = trimmed_body^
            var item = MdLine()
            md_inline_links(body, MD_TEXT, item, links)
            var first = MdLine()
            var rest = MdLine()
            var depth = min(ind, 12)
            for _ in range(depth):
                first.add(32, MD_TEXT)
                rest.add(32, MD_TEXT)
            if bullet == 2:
                first.add(task_glyph if task_glyph != 0 else 0x2022, MD_DIM)
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
