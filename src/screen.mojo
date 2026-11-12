"""Double-buffered cell screen with truecolor diff rendering."""
from std.collections import List
from util import decode, encode_cp, append_str, append_int, char_width
from caps import COLOR_16, COLOR_256, COLOR_TRUE, rgb_to_256, rgb_to_16, sgr_16

comptime CONT = -5  # a further cell of a character wider than one cell
comptime XBASE = 0x1000000  # cmb values from here on are indexes into Screen.xseq
comptime XSEQ_MAX = 2048


comptime BOLD_BIT = 1 << 30        # in a cell's underline word: the character is bold


struct Screen(Movable):
    var w: Int
    var h: Int
    var ch: List[Int]
    var fg: List[Int]
    var bg: List[Int]
    var pch: List[Int]
    var pfg: List[Int]
    var pbg: List[Int]
    var cmb: List[Int]
    var pcmb: List[Int]
    var ul: List[Int]           # underline per cell: 0 none, else (kind << 24) | colour; kind 1 straight, 3 curly
    var pul: List[Int]
    var styled_ul: Bool         # the terminal draws curly and coloured underlines
    var xseq: List[List[Int]]   # pool of multi-codepoint cell extras (see intern)
    var clustered: Bool         # terminal draws grapheme clusters as one glyph (mode 2027)
    var force: Bool
    var cx: Int
    var cy: Int
    var cvis: Bool
    var cblock: Bool
    var color_mode: Int   # COLOR_TRUE / COLOR_256 / COLOR_16: how colours are sent
    var plain: Bool       # screen-reader mode: box drawing and shading drawn as blanks
    var sync: Bool        # wrap each frame in synchronized-output markers (mode 2026)
    var cx0: Int
    var cy0: Int
    var cx1: Int
    var cy1: Int

    def __init__(out self, w: Int, h: Int):
        self.w = 0
        self.h = 0
        self.ch = List[Int]()
        self.fg = List[Int]()
        self.bg = List[Int]()
        self.pch = List[Int]()
        self.pfg = List[Int]()
        self.pbg = List[Int]()
        self.cmb = List[Int]()
        self.pcmb = List[Int]()
        self.ul = List[Int]()
        self.pul = List[Int]()
        self.styled_ul = False
        self.xseq = List[List[Int]]()
        self.clustered = False
        self.force = True
        self.cx = 0
        self.cy = 0
        self.cvis = False
        self.cblock = False
        self.color_mode = COLOR_TRUE
        self.plain = False
        self.sync = True
        self.cx0 = 0
        self.cy0 = 0
        self.cx1 = 0
        self.cy1 = 0
        self.resize(w, h)

    def resize(mut self, w: Int, h: Int):
        self.w = w
        self.h = h
        var n = w * h
        self.ch = List[Int](length=n, fill=32)
        self.fg = List[Int](length=n, fill=0xAAAAAA)
        self.bg = List[Int](length=n, fill=0)
        self.pch = List[Int](length=n, fill=-1)
        self.pfg = List[Int](length=n, fill=-1)
        self.pbg = List[Int](length=n, fill=-1)
        self.cmb = List[Int](length=n, fill=0)
        self.pcmb = List[Int](length=n, fill=0)
        self.ul = List[Int](length=n, fill=0)
        self.pul = List[Int](length=n, fill=0)
        self.force = True
        self.no_clip()

    def no_clip(mut self):
        self.cx0 = 0
        self.cy0 = 0
        self.cx1 = self.w
        self.cy1 = self.h

    def clip(mut self, x: Int, y: Int, w: Int, h: Int):
        self.cx0 = max(0, x)
        self.cy0 = max(0, y)
        self.cx1 = min(self.w, x + w)
        self.cy1 = min(self.h, y + h)

    def intern(mut self, seq: List[Int]) -> Int:
        """Value for `cmb` describing the extra codepoints of a cell: 0 for none, the
        codepoint itself for one, otherwise XBASE + index into the sequence pool. Equal
        sequences get equal values, so frames can be compared cell by cell."""
        var n = len(seq)
        if n == 0:
            return 0
        if n == 1:
            return seq[0]
        for i in range(len(self.xseq)):
            if len(self.xseq[i]) == n:
                var same = True
                for j in range(n):
                    if self.xseq[i][j] != seq[j]:
                        same = False
                        break
                if same:
                    return XBASE + i
        self.xseq.append(seq.copy())
        return XBASE + len(self.xseq) - 1

    def extras(self, k: Int) -> List[Int]:
        """The codepoints that follow the first one in cell k (accents, joiners, ...)."""
        var out = List[Int]()
        var m = self.cmb[k]
        if m == 0:
            return out^
        if m < XBASE:
            out.append(m)
            return out^
        return self.xseq[m - XBASE].copy()

    def head_of(self, k: Int) -> Int:
        """Index of the cell that holds the character covering cell k."""
        var row0 = (k // self.w) * self.w
        var h = k
        while h > row0 and self.ch[h] == CONT:
            h -= 1
        return h

    def break_run(mut self, k: Int):
        """If cell k is part of a character wider than one cell, blank all of it."""
        var h = self.head_of(k)
        var row_end = (k // self.w + 1) * self.w
        var e = h + 1
        while e < row_end and self.ch[e] == CONT:
            e += 1
        if e - h < 2 and self.ch[h] != CONT:
            return
        for j in range(h, e):
            self.ch[j] = 32
            self.cmb[j] = 0

    def place(mut self, x: Int, y: Int, c: Int, xid: Int, w: Int, fg: Int, bg: Int):
        """Raw store of a character `w` cells wide; keeps multi-cell characters whole."""
        var k = y * self.w + x
        var n = max(1, min(w, self.w - x))
        for j in range(n):
            self.break_run(k + j)
        for j in range(n):
            self.ch[k + j] = CONT if j > 0 else c
            self.cmb[k + j] = 0
            self.ul[k + j] = 0
            self.fg[k + j] = fg
            self.bg[k + j] = bg
        self.cmb[k] = xid

    def set_cell(mut self, x: Int, y: Int, c: Int, fg: Int, bg: Int):
        self.place(x, y, c, 0, 1, fg, bg)

    def put(mut self, x: Int, y: Int, c: Int, fg: Int, bg: Int):
        if x < self.cx0 or x >= self.cx1 or y < self.cy0 or y >= self.cy1:
            return
        var ch = c
        if self.plain and ch >= 0x2500 and ch <= 0x259F:
            ch = 32                 # frames, lines, shading: noise to a screen reader
        if ch < 32:
            ch = 0x2400 + ch if ch >= 0 else 32  # control pictures
        elif ch == 127:
            ch = 0x2421
        var w = char_width(ch)
        if w == 0:
            # lone combining mark: show it on a dotted circle
            self.place(x, y, 0x25CC, ch, 1, fg, bg)
            return
        if w == 2 and x + 1 >= self.cx1:
            ch = 0x2026
            w = 1
        self.place(x, y, ch, 0, w, fg, bg)

    def put_cluster(mut self, x: Int, y: Int, cps: List[Int], s: Int, e: Int, w: Int, fg: Int, bg: Int):
        """Draw the grapheme cluster cps[s:e] as one character `w` cells wide. The whole
        cluster is kept in the first cell and sent to the terminal in one piece."""
        if e - s == 1:
            self.put(x, y, cps[s], fg, bg)
            return
        if x < self.cx0 or x >= self.cx1 or y < self.cy0 or y >= self.cy1 or s >= e:
            return
        var rest = List[Int]()
        if w == 0:
            for i in range(s, e):
                rest.append(cps[i])
            self.place(x, y, 0x25CC, self.intern(rest), 1, fg, bg)
            return
        if x + w > self.cx1:
            # does not fit before the clip edge
            for j in range(x, self.cx1):
                self.place(j, y, 0x2026 if j == x else 32, 0, 1, fg, bg)
            return
        for i in range(s + 1, e):
            rest.append(cps[i])
        self.place(x, y, cps[s], self.intern(rest), w, fg, bg)

    def combine(mut self, x: Int, y: Int, mark: Int):
        """Attach one more codepoint (combining mark, joiner, selector) to the character
        drawn at (x, y)."""
        if x < self.cx0 or x >= self.cx1 or y < self.cy0 or y >= self.cy1:
            return
        var k = self.head_of(y * self.w + x)
        var seq = self.extras(k)
        seq.append(mark)
        self.cmb[k] = self.intern(seq)

    def draw_cp(mut self, x: Int, y: Int, c: Int, fg: Int, bg: Int) -> Int:
        """Draw one codepoint; returns the x after it (handles wide + combining)."""
        var w = char_width(c)
        if w == 0 and x > 0:
            self.combine(x - 1, y, c)
            return x
        self.put(x, y, c, fg, bg)
        return x + max(w, 1)

    def underline(mut self, x: Int, y: Int, curly: Bool, rgb: Int):
        """Underline the character already drawn at (x, y). `curly` and the colour are
        used on terminals that can draw them; elsewhere it is a plain underline in the
        text colour. Drawing a character there again removes it."""
        if x < self.cx0 or x >= self.cx1 or y < self.cy0 or y >= self.cy1:
            return
        var k = self.head_of(y * self.w + x)
        self.ul[k] = (self.ul[k] & BOLD_BIT) | ((3 if curly else 1) << 24) | (rgb & 0xFFFFFF)

    def ul_at(self, x: Int, y: Int) -> Int:
        """0 = not underlined, 1 = straight, 3 = curly."""
        return (self.ul[self.head_of(y * self.w + x)] >> 24) & 7

    def bold(mut self, x: Int, y: Int, n: Int = 1):
        """Make the `n` characters already drawn from (x, y) bold (drawing a character
        there again removes it). Kept as a bit beside the underline of each cell."""
        for j in range(n):
            if x + j < self.cx0 or x + j >= self.cx1 or y < self.cy0 or y >= self.cy1:
                continue
            var k = self.head_of(y * self.w + x + j)
            self.ul[k] |= BOLD_BIT

    def is_bold(self, x: Int, y: Int) -> Bool:
        return (self.ul[self.head_of(y * self.w + x)] & BOLD_BIT) != 0

    def set_fg(mut self, x: Int, y: Int, fg: Int):
        if x < self.cx0 or x >= self.cx1 or y < self.cy0 or y >= self.cy1:
            return
        self.fg[y * self.w + x] = fg

    def set_bg(mut self, x: Int, y: Int, bg: Int):
        if x < self.cx0 or x >= self.cx1 or y < self.cy0 or y >= self.cy1:
            return
        self.bg[y * self.w + x] = bg

    def text(mut self, x: Int, y: Int, s: String, fg: Int, bg: Int) -> Int:
        var xx = x
        for c in decode(s):
            xx = self.draw_cp(xx, y, c, fg, bg)
        return xx

    def hot_text(mut self, x: Int, y: Int, s: String, fg: Int, hot: Int, bg: Int) -> Int:
        """Draw text where '~' toggles the highlight colour (Turbo Vision style)."""
        var xx = x
        var on = False
        for c in decode(s):
            if c == 126:
                on = not on
                continue
            xx = self.draw_cp(xx, y, c, hot if on else fg, bg)
        return xx

    def cps(mut self, x: Int, y: Int, cps: List[Int], fg: Int, bg: Int) -> Int:
        var xx = x
        for c in cps:
            xx = self.draw_cp(xx, y, c, fg, bg)
        return xx

    def fill(mut self, x: Int, y: Int, w: Int, h: Int, c: Int, fg: Int, bg: Int):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.put(xx, yy, c, fg, bg)

    def frame(mut self, x: Int, y: Int, w: Int, h: Int, double: Bool, fg: Int, bg: Int):
        var hz = 0x2550 if double else 0x2500
        var vt = 0x2551 if double else 0x2502
        self.put(x, y, 0x2554 if double else 0x250C, fg, bg)
        self.put(x + w - 1, y, 0x2557 if double else 0x2510, fg, bg)
        self.put(x, y + h - 1, 0x255A if double else 0x2514, fg, bg)
        self.put(x + w - 1, y + h - 1, 0x255D if double else 0x2518, fg, bg)
        for xx in range(x + 1, x + w - 1):
            self.put(xx, y, hz, fg, bg)
            self.put(xx, y + h - 1, hz, fg, bg)
        for yy in range(y + 1, y + h - 1):
            self.put(x, yy, vt, fg, bg)
            self.put(x + w - 1, yy, vt, fg, bg)

    def shadow(mut self, x: Int, y: Int, w: Int, h: Int, sfg: Int, sbg: Int):
        """Turbo Vision drop shadow: two columns right, one row below."""
        for yy in range(y + 1, y + h + 1):
            for xx in range(x + w, x + w + 2):
                if xx >= 0 and xx < self.w and yy >= 0 and yy < self.h:
                    var k = yy * self.w + xx
                    self.fg[k] = sfg
                    self.bg[k] = sbg
        var yy = y + h
        if yy >= 0 and yy < self.h:
            for xx in range(x + 2, x + w):
                if xx >= 0 and xx < self.w:
                    var k = yy * self.w + xx
                    self.fg[k] = sfg
                    self.bg[k] = sbg

    def row_text(self, y: Int) -> List[Int]:
        """Codepoints shown on row y (wide-char halves merged, trailing blanks cut)."""
        var out = List[Int]()
        for x in range(self.w):
            var k = y * self.w + x
            var c = self.ch[k]
            if c == CONT:
                continue
            out.append(c if c >= 32 else 32)
            for m in self.extras(k):
                out.append(m)
        while len(out) > 0 and out[len(out) - 1] == 32:
            _ = out.pop()
        return out^

    def to_text(self) -> List[Int]:
        """The whole screen as plain text, one line per row (for tests and dumps)."""
        var out = List[Int]()
        for y in range(self.h):
            for c in self.row_text(y):
                out.append(c)
            out.append(10)
        return out^

    def fg_at(self, x: Int, y: Int) -> Int:
        return self.fg[y * self.w + x]

    def bg_at(self, x: Int, y: Int) -> Int:
        return self.bg[y * self.w + x]

    def emit_color(self, mut out: List[UInt8], rgb: Int, background: Bool):
        """Append the SGR sequence for one colour in the terminal's colour depth."""
        if self.color_mode == COLOR_TRUE:
            append_str(out, "\x1b[48;2;" if background else "\x1b[38;2;")
            append_int(out, (rgb >> 16) & 255)
            append_str(out, ";")
            append_int(out, (rgb >> 8) & 255)
            append_str(out, ";")
            append_int(out, rgb & 255)
        elif self.color_mode == COLOR_256:
            append_str(out, "\x1b[48;5;" if background else "\x1b[38;5;")
            append_int(out, rgb_to_256(rgb))
        else:
            append_str(out, "\x1b[")
            append_int(out, sgr_16(rgb_to_16(rgb), background))
        append_str(out, "m")

    def render(mut self, mut out: List[UInt8]):
        if self.sync:
            append_str(out, "\x1b[?2026h")
        append_str(out, "\x1b[?25l")
        var lastfg = -1
        var lastbg = -1
        var lastul = 0          # every frame ends with underlining switched off
        var px = -1
        var py = -1
        for y in range(self.h):
            for x in range(self.w):
                var k = y * self.w + x
                if self.ch[k] == CONT:
                    # drawn together with its left half
                    self.pch[k] = CONT
                    self.pfg[k] = self.fg[k]
                    self.pbg[k] = self.bg[k]
                    continue
                if (
                    not self.force and self.ch[k] == self.pch[k] and self.cmb[k] == self.pcmb[k]
                    and self.fg[k] == self.pfg[k] and self.bg[k] == self.pbg[k] and self.ul[k] == self.pul[k]
                ):
                    continue
                if py != y or px != x:
                    append_str(out, "\x1b[")
                    append_int(out, y + 1)
                    append_str(out, ";")
                    append_int(out, x + 1)
                    append_str(out, "H")
                var f = self.fg[k]
                var b = self.bg[k]
                if f != lastfg:
                    self.emit_color(out, f, False)
                    lastfg = f
                if b != lastbg:
                    self.emit_color(out, b, True)
                    lastbg = b
                var u = self.ul[k]
                if (u & BOLD_BIT) != (lastul & BOLD_BIT):
                    append_str(out, "\x1b[1m" if (u & BOLD_BIT) != 0 else "\x1b[22m")
                    lastul = (lastul & ~BOLD_BIT) | (u & BOLD_BIT)
                if u != lastul:
                    if (u & ~BOLD_BIT) == 0:
                        append_str(out, "\x1b[24m")
                    elif self.styled_ul:
                        append_str(out, "\x1b[4:")
                        append_int(out, (u >> 24) & 7)
                        append_str(out, "m\x1b[58:2::")
                        append_int(out, (u >> 16) & 255)
                        append_str(out, ":")
                        append_int(out, (u >> 8) & 255)
                        append_str(out, ":")
                        append_int(out, u & 255)
                        append_str(out, "m")
                    else:
                        append_str(out, "\x1b[4m")
                    lastul = u
                var c = self.ch[k]
                if c < 32:
                    c = 32
                encode_cp(c, out)
                var m = self.cmb[k]
                if m != 0 and m < XBASE:
                    encode_cp(m, out)
                elif m != 0:
                    for q in self.xseq[m - XBASE]:
                        encode_cp(q, out)
                var run = 1
                while x + run < self.w and self.ch[k + run] == CONT:
                    run += 1
                # after a long cluster do not trust where the terminal left its cursor
                px = x + run if m < XBASE else -1
                py = y
                self.pcmb[k] = self.cmb[k]
                self.pul[k] = u
                self.pch[k] = self.ch[k]
                self.pfg[k] = f
                self.pbg[k] = b
        if (lastul & ~BOLD_BIT) != 0:
            append_str(out, "\x1b[24m")
        if (lastul & BOLD_BIT) != 0:
            append_str(out, "\x1b[22m")
        self.force = False
        if len(self.xseq) > XSEQ_MAX:
            # the pool only grows; start over and repaint everything next frame
            self.xseq.clear()
            for k in range(len(self.cmb)):
                if self.cmb[k] >= XBASE:
                    self.cmb[k] = 0
                    self.pcmb[k] = 0
            self.force = True
        if self.cvis:
            append_str(out, "\x1b[")
            append_int(out, self.cy + 1)
            append_str(out, ";")
            append_int(out, self.cx + 1)
            append_str(out, "H")
            append_str(out, "\x1b[1 q" if self.cblock else "\x1b[3 q")
            append_str(out, "\x1b[?25h")
        if self.sync:
            append_str(out, "\x1b[?2026l")
