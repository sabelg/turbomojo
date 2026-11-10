"""Double-buffered cell screen with truecolor diff rendering."""
from std.collections import List
from util import decode, encode_cp, append_str, append_int, char_width
from caps import COLOR_16, COLOR_256, COLOR_TRUE, rgb_to_256, rgb_to_16, sgr_16

comptime CONT = -5  # right half of a double-width character


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
    var force: Bool
    var cx: Int
    var cy: Int
    var cvis: Bool
    var cblock: Bool
    var color_mode: Int   # COLOR_TRUE / COLOR_256 / COLOR_16: how colours are sent
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
        self.force = True
        self.cx = 0
        self.cy = 0
        self.cvis = False
        self.cblock = False
        self.color_mode = COLOR_TRUE
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

    def set_cell(mut self, x: Int, y: Int, c: Int, fg: Int, bg: Int):
        """Raw cell store that keeps double-width pairs consistent."""
        var k = y * self.w + x
        if self.ch[k] == CONT and x > 0:
            self.ch[k - 1] = 32
            self.cmb[k - 1] = 0
        if x + 1 < self.w and self.ch[k + 1] == CONT and c != CONT:
            self.ch[k + 1] = 32
        self.ch[k] = c
        self.cmb[k] = 0
        self.fg[k] = fg
        self.bg[k] = bg

    def put(mut self, x: Int, y: Int, c: Int, fg: Int, bg: Int):
        if x < self.cx0 or x >= self.cx1 or y < self.cy0 or y >= self.cy1:
            return
        var ch = c
        if ch < 32:
            ch = 0x2400 + ch if ch >= 0 else 32  # control pictures
        elif ch == 127:
            ch = 0x2421
        var w = char_width(ch)
        if w == 0:
            # lone combining mark: show it on a dotted circle
            self.set_cell(x, y, 0x25CC, fg, bg)
            self.cmb[y * self.w + x] = ch
            return
        if w == 2 and x + 1 >= self.cx1:
            ch = 0x2026
            w = 1
        self.set_cell(x, y, ch, fg, bg)
        if w == 2:
            self.set_cell(x + 1, y, CONT, fg, bg)

    def combine(mut self, x: Int, y: Int, mark: Int):
        """Attach a combining mark to the character drawn at (x, y)."""
        if x < self.cx0 or x >= self.cx1 or y < self.cy0 or y >= self.cy1:
            return
        var k = y * self.w + x
        if self.ch[k] == CONT and x > 0:
            k -= 1
        self.cmb[k] = mark

    def draw_cp(mut self, x: Int, y: Int, c: Int, fg: Int, bg: Int) -> Int:
        """Draw one codepoint; returns the x after it (handles wide + combining)."""
        var w = char_width(c)
        if w == 0 and x > 0:
            self.combine(x - 1, y, c)
            return x
        self.put(x, y, c, fg, bg)
        return x + max(w, 1)

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
            if self.cmb[k] != 0:
                out.append(self.cmb[k])
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
                    and self.fg[k] == self.pfg[k] and self.bg[k] == self.pbg[k]
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
                var c = self.ch[k]
                if c < 32:
                    c = 32
                encode_cp(c, out)
                if self.cmb[k] != 0:
                    encode_cp(self.cmb[k], out)
                px = x + char_width(c)
                if x + 1 < self.w and self.ch[k + 1] == CONT:
                    px = x + 2
                py = y
                self.pcmb[k] = self.cmb[k]
                self.pch[k] = self.ch[k]
                self.pfg[k] = f
                self.pbg[k] = b
        self.force = False
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
