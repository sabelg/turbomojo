"""Terminal capabilities: what the terminal says it supports, and colour-depth handling.

Capabilities are learned by asking the terminal (DECRQM mode queries, the kitty keyboard
query, and a final DA1 request that every terminal answers so we know when to stop
waiting). Colour depth comes from the environment, because there is no query that all
terminals answer."""
from std.collections import List

comptime COLOR_16 = 0
comptime COLOR_256 = 1
comptime COLOR_TRUE = 2

comptime MODE_SYNC_OUTPUT = 2026
comptime MODE_GRAPHEME = 2027
comptime MODE_COLOR_SCHEME = 2031
comptime MODE_INBAND_RESIZE = 2048

# Sent once at startup. The DA1 request ("CSI c") must stay last.
comptime CAPS_QUERY = "\x1b[?2026$p\x1b[?2027$p\x1b[?2031$p\x1b[?2048$p\x1b[?u\x1b[c"
# The background colour (OSC 11): light or dark when mode 2031 gets no answer.
comptime OSC11_QUERY = "\x1b]11;?\x1b\\"
# DCS queries, left out under GNU screen (it shows them or passes them on mangled):
# truecolor by setting an RGB background and asking for it back (DECRQSS "m"), and
# styled underlines from the terminfo entries the terminal itself has (XTGETTCAP
# Smulx: curly; Setulc: coloured).
comptime TRUECOLOR_QUERY = "\x1b[48;2;1;2;3m\x1bP$qm\x1b\\\x1b[0m"
comptime UNDERLINE_QUERY = "\x1bP+q536d756c78;536574756c63\x1b\\"
# kitty graphics: a query for a 1x1 image that is not stored (a=q); a terminal with the
# protocol answers "ESC _ G i=31;OK ESC \" before the DA1 reply. (An APC, so left out
# under GNU screen too.) Sixel is in the DA1 reply itself (attribute 4).
# The size of a cell in pixels (XTWINOPS 16: answered CSI 6 ; height ; width t), so
# that pictures get their proportions; terminals that do not know it say nothing.
comptime CELL_SIZE_QUERY = "\x1b[16t"
comptime KITTY_GRAPHICS_QUERY = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"


def caps_query(dcs: Bool) -> String:
    """All the questions, DA1 last (every terminal answers it: then we stop waiting)."""
    var q = String("\x1b[?2026$p\x1b[?2027$p\x1b[?2031$p\x1b[?2048$p\x1b[?u") + OSC11_QUERY
    if dcs:
        q += String(TRUECOLOR_QUERY) + UNDERLINE_QUERY + KITTY_GRAPHICS_QUERY
    return q + CELL_SIZE_QUERY + "\x1b[c"


def under_gnu_screen(term: String, sty: String, tmux: String) -> Bool:
    """GNU screen (it sets STY; tmux, which can also call itself "screen", sets TMUX)."""
    if tmux.byte_length() > 0:
        return False
    return sty.byte_length() > 0 or term.startswith("screen")


def hex_val(b: Int) -> Int:
    if b >= 48 and b <= 57:
        return b - 48
    if b >= 97 and b <= 102:
        return b - 87
    if b >= 65 and b <= 70:
        return b - 55
    return -1


def osc11_rgb(body: String) -> Int:
    """The colour in an OSC 11 reply's body ("11;rgb:RRRR/GGGG/BBBB", 1 to 4 hex digits
    each) as 0xRRGGBB, or -1."""
    var at = body.find("rgb:")
    if not body.startswith("11;") or at < 0:
        return -1
    var parts = String(body[byte=at + 4:]).split("/")
    if len(parts) != 3:
        return -1
    var out = 0
    for p in parts:
        var s = String(p)
        var n = s.byte_length()
        if n < 1 or n > 4:
            return -1
        var v = 0
        for b in s.as_bytes():
            var h = hex_val(Int(b))
            if h < 0:
                return -1
            v = v * 16 + h
        var full = (1 << (4 * n)) - 1
        out = out * 256 + (v * 255 + full // 2) // full
    return out


def scheme_of_background(rgb: Int) -> Int:
    """1 dark, 2 light: light when the background's relative luminance is above 0.18
    (CIE L* 50, halfway between black and white as the eye sees it)."""
    var y = 0.0
    var w = [0.2126, 0.7152, 0.0722]
    for k in range(3):
        var v = Float64((rgb >> (16 - 8 * k)) & 255) / 255.0
        v = v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
        y += w[k] * v
    return 2 if y > 0.18 else 1


struct Caps(Copyable, Movable):
    var color: Int             # COLOR_16 / COLOR_256 / COLOR_TRUE
    var sync_output: Bool      # mode 2026: flicker-free frame updates
    var grapheme: Bool         # mode 2027: grapheme-cluster cursor movement
    var color_scheme: Bool     # mode 2031: light/dark change notifications
    var inband_resize: Bool    # mode 2048: resize reports on the input stream
    var kitty_keyboard: Bool   # progressive keyboard enhancement protocol
    var styled_underline: Bool # curly and coloured underlines (guessed from the environment)
    var answered: Bool         # the terminal replied to the final DA1 request
    var background: Int        # OSC 11: the terminal's background colour (-1: not said)
    var truecolor_said: Int    # DECRQSS: 1 the RGB colour came back, 2 it did not, 0 no answer
    var underline_said: Int    # XTGETTCAP Smulx / Setulc: 1 the terminal has them, 0 no answer
    var widths: List[Int]      # how far the cursor moved for each WIDTH_SAMPLES entry (measured)
    var kitty_graphics: Bool   # answered the kitty graphics query
    var sixel: Bool            # DA1 lists attribute 4 (sixel graphics)
    var cell_w: Int            # a cell's size in pixels (0: not said)
    var cell_h: Int

    def __init__(out self):
        self.color = COLOR_TRUE
        self.sync_output = False
        self.grapheme = False
        self.color_scheme = False
        self.inband_resize = False
        self.kitty_keyboard = False
        self.styled_underline = False
        self.answered = False
        self.background = -1
        self.truecolor_said = 0
        self.underline_said = 0
        self.widths = List[Int]()
        self.kitty_graphics = False
        self.sixel = False
        self.cell_w = 0
        self.cell_h = 0

    def dcs_reply(mut self, body: String):
        """A DCS reply's body (between ESC P and ST)."""
        if body.startswith("1$r") or body.startswith("0$r"):
            # DECRQSS "m": the RGB background we set, if the terminal kept it as RGB
            var ok = body.startswith("1$r") and (body.find("48;2;1;2;3") >= 0 or body.find("48:2:1:2:3") >= 0 or body.find("48:2::1:2:3") >= 0)
            self.truecolor_said = 1 if ok else 2
        elif body.startswith("1+r"):
            # XTGETTCAP: names hex-encoded; Smulx (536d756c78) or Setulc (536574756c63)
            if body.find("536d756c78") >= 0 or body.find("536574756c63") >= 0:
                self.underline_said = 1

    def settle(mut self, color_override: String, underline_override: String):
        """What the answers add to what the environment said. Answers only add: a
        terminal that says it keeps RGB colours gets them, one that has curly underlines
        in its terminfo (tmux too, when it is set up to pass them on) gets them; the
        user's TURBOMOJO_COLORS / TURBOMOJO_UNDERLINE still decide."""
        if self.truecolor_said == 1 and color_override.byte_length() == 0:
            self.color = COLOR_TRUE
        if self.underline_said == 1 and underline_override.byte_length() == 0:
            self.styled_underline = True

    def apc_reply(mut self, body: String):
        """An APC reply's body (between ESC _ and ST): the kitty graphics answer."""
        if body.startswith("Gi=31;") and body.find(";OK") >= 0:
            self.kitty_graphics = True

    def da1_reply(mut self, params: List[Int]):
        """The DA1 answer (CSI ? 6x ; attributes c): the last reply to our queries."""
        self.answered = True
        for k in range(1, len(params)):
            if params[k] == 4:
                self.sixel = True

    def width_report(mut self, col: Int):
        """A cursor-position report after one width sample (1-based column; the sample
        was written from column 1)."""
        if len(self.widths) < WIDTH_SAMPLE_COUNT:
            self.widths.append(col - 1)

    def mode_report(mut self, mode: Int, value: Int):
        """A DECRPM reply: value 1/2 = supported (set/reset), 3/4 = fixed, 0 = unknown.
        Only a mode we could switch ourselves (1 or 2) or one permanently on (3) counts."""
        var ok = value == 1 or value == 2 or value == 3
        if mode == MODE_SYNC_OUTPUT:
            self.sync_output = ok
        elif mode == MODE_GRAPHEME:
            self.grapheme = ok
        elif mode == MODE_COLOR_SCHEME:
            self.color_scheme = ok
        elif mode == MODE_INBAND_RESIZE:
            self.inband_resize = ok

    def describe(self) -> List[String]:
        var out = List[String]()
        var depth = "24-bit colour" if self.color == COLOR_TRUE else ("256 colours" if self.color == COLOR_256 else "16 colours")
        out.append("colour depth        : " + depth)
        out.append("synchronized output : " + yes_no(self.sync_output))
        out.append("grapheme clustering : " + yes_no(self.grapheme))
        out.append("colour-scheme notify: " + yes_no(self.color_scheme))
        out.append("in-band resize      : " + yes_no(self.inband_resize))
        out.append("kitty keyboard      : " + yes_no(self.kitty_keyboard))
        out.append("curly underlines    : " + yes_no(self.styled_underline) + (" (the terminal says so)" if self.underline_said == 1 else " (guessed)"))
        out.append("background          : " + (("#" + hex6(self.background)) if self.background >= 0 else String("not said")))
        out.append("measured widths     : " + width_summary(self.widths))
        out.append("images              : " + images_summary(self.kitty_graphics, self.sixel))
        out.append("cell size           : " + ((String(self.cell_w) + " x " + String(self.cell_h) + " pixels") if self.cell_w > 0 else String("not said")))
        out.append("answered queries    : " + yes_no(self.answered))
        return out^


# Glyphs whose width terminals disagree about, measured once at start-up: each is written
# (concealed) from column 1 and the cursor position asked for (CSI 6n); the column in the
# answer is the width the terminal really gave it. One sample per doubtful kind:
#   0 an emoji from Unicode 6 (wide in every width table since Unicode 9)
#   1 an emoji from Unicode 15 (narrow in older tables)
#   2 two emoji joined with ZWJ (2 where the terminal draws the cluster as one glyph, 4
#     where it lays the codepoints out one by one)
#   3 a text-style symbol with the emoji selector U+FE0F (1 or 2)
comptime WIDTH_SAMPLE_COUNT = 4
comptime EMOJI_NARROW_NONE = 0
comptime EMOJI_NARROW_NEW = 1     # the Unicode 12+ block U+1FA70..U+1FAFF is drawn narrow
comptime EMOJI_NARROW_ALL = 2     # every emoji is drawn narrow (a pre-Unicode-9 table)


def width_sample(k: Int) -> List[Int]:
    if k == 0:
        return [0x1F600]
    if k == 1:
        return [0x1FAE8]
    if k == 2:
        return [0x1F468, 0x200D, 0x1F469]
    return [0x2764, 0xFE0F]


def width_probe() -> String:
    """The measuring sequence: each sample concealed (SGR 8) from column 1, then CSI 6n;
    at the end the line is cleared and the attributes reset. Sent while the screen is
    about to be drawn anyway (alternate screen, cursor hidden)."""
    var s = String("\x1b[8m")
    for k in range(WIDTH_SAMPLE_COUNT):
        s += "\r"
        for c in width_sample(k):
            s += chr(c)
        s += "\x1b[6n"
    return s + "\r\x1b[2K\x1b[0m"


struct WidthVerdict(Copyable, Movable):
    """What the measured widths mean for drawing."""
    var measured: Bool      # every sample was answered
    var clusters: Bool      # the terminal draws a ZWJ sequence as one glyph by itself
    var emoji_narrow: Int   # EMOJI_NARROW_*
    var vs16_wide: Bool     # a symbol + U+FE0F takes two columns

    def __init__(out self):
        self.measured = False
        self.clusters = False
        self.emoji_narrow = EMOJI_NARROW_NONE
        self.vs16_wide = False


def width_verdict(widths: List[Int]) -> WidthVerdict:
    """Read the answers. Missing or implausible answers (a terminal that ignored the
    query, or answered from somewhere else on the line) change nothing."""
    var v = WidthVerdict()
    if len(widths) < WIDTH_SAMPLE_COUNT:
        return v^
    for w in widths:
        if w < 1 or w > 4:
            return v^
    v.measured = True
    if widths[0] == 1:
        v.emoji_narrow = EMOJI_NARROW_ALL
    elif widths[1] == 1:
        v.emoji_narrow = EMOJI_NARROW_NEW
    # (with narrow emoji a ZWJ pair is 2 laid out one by one too: no conclusion then)
    v.clusters = widths[0] == 2 and widths[2] == 2
    v.vs16_wide = widths[3] == 2
    return v^


def images_summary(kitty: Bool, sixel: Bool) -> String:
    if kitty and sixel:
        return "kitty graphics, sixel"
    if kitty:
        return "kitty graphics"
    if sixel:
        return "sixel"
    return "no (shown as text)"


def width_summary(widths: List[Int]) -> String:
    if len(widths) == 0:
        return "not measured"
    var v = width_verdict(widths)
    var s = String("")
    for k in range(len(widths)):
        s += (", " if k > 0 else "") + String(widths[k])
    if not v.measured:
        return s + " (incomplete: not used)"
    var notes = List[String]()
    if v.clusters:
        notes.append("joins emoji sequences")
    if v.emoji_narrow == EMOJI_NARROW_ALL:
        notes.append("emoji narrow")
    elif v.emoji_narrow == EMOJI_NARROW_NEW:
        notes.append("newer emoji narrow")
    if v.vs16_wide:
        notes.append("emoji selector widens")
    if len(notes) == 0:
        return s
    var t = String(" (")
    for k in range(len(notes)):
        t += ("; " if k > 0 else "") + notes[k]
    return s + t + ")"


def hex6(rgb: Int) -> String:
    var d = "0123456789abcdef"
    var s = String("")
    for k in range(6):
        var v = (rgb >> (20 - 4 * k)) & 15
        s += String(d[byte=v:v + 1])
    return s


def yes_no(b: Bool) -> String:
    return "yes" if b else "no"


def detect_styled_underline(term: String, term_program: String, vte_version: String, override: String) -> Bool:
    """Can the terminal draw curly, coloured underlines (SGR 4:3 and 58)? There is no
    query for it, so this goes by the names of terminals known to do it; the user can
    decide with TURBOMOJO_UNDERLINE=curly|plain. Inside tmux or screen the answer is no:
    they pass the sequences on only when configured to."""
    if override == "curly":
        return True
    if override == "plain":
        return False
    if term.startswith("tmux") or term.startswith("screen"):
        return False
    if term.find("kitty") >= 0 or term.find("ghostty") >= 0 or term.find("wezterm") >= 0 or term.find("foot") >= 0 or term.find("alacritty") >= 0 or term.find("contour") >= 0:
        return True
    if term_program == "WezTerm" or term_program == "ghostty" or term_program == "iTerm.app" or term_program == "vscode":
        return True
    # VTE (GNOME Terminal and relatives) since 0.52
    var v = 0
    for b in vte_version.as_bytes():
        if b < 48 or b > 57:
            return False
        v = v * 10 + Int(b) - 48
    return v >= 5200


def detect_color_level(colorterm: String, term: String, override: String) -> Int:
    """Colour depth from $COLORTERM / $TERM, or a user override
    (TURBOMOJO_COLORS=truecolor|256|16)."""
    if override == "truecolor" or override == "24bit":
        return COLOR_TRUE
    if override == "256":
        return COLOR_256
    if override == "16":
        return COLOR_16
    if colorterm == "truecolor" or colorterm == "24bit":
        return COLOR_TRUE
    if term.find("direct") >= 0 or term.find("truecolor") >= 0:
        return COLOR_TRUE
    if term.find("256color") >= 0:
        return COLOR_256
    # terminals known to do 24-bit colour without advertising it in $TERM
    if term.find("kitty") >= 0 or term.find("alacritty") >= 0 or term.find("ghostty") >= 0 or term.find("wezterm") >= 0 or term.find("foot") >= 0:
        return COLOR_TRUE
    return COLOR_16


# ------------------------------------------------------------- colour mapping
def cube_level(v: Int) -> Int:
    """Nearest of the six xterm colour-cube levels (0, 95, 135, 175, 215, 255)."""
    if v < 48:
        return 0
    if v < 115:
        return 1
    return min(5, (v - 35) // 40)


def cube_value(level: Int) -> Int:
    return 0 if level == 0 else 55 + 40 * level


def dist2(r1: Int, g1: Int, b1: Int, r2: Int, g2: Int, b2: Int) -> Int:
    return (r1 - r2) * (r1 - r2) + (g1 - g2) * (g1 - g2) + (b1 - b2) * (b1 - b2)


def rgb_to_256(rgb: Int) -> Int:
    """Nearest xterm-256 palette index (colour cube 16..231 or grey ramp 232..255)."""
    var r = (rgb >> 16) & 255
    var g = (rgb >> 8) & 255
    var b = rgb & 255
    var cr = cube_level(r)
    var cg = cube_level(g)
    var cb = cube_level(b)
    var cube = 16 + 36 * cr + 6 * cg + cb
    var dc = dist2(r, g, b, cube_value(cr), cube_value(cg), cube_value(cb))
    # grey ramp: 232 + i has value 8 + 10 i, for i in 0..23
    var avg = (r + g + b) // 3
    var gi = max(0, min(23, (avg - 3) // 10))
    var gv = 8 + 10 * gi
    var dg = dist2(r, g, b, gv, gv, gv)
    if dg < dc:
        return 232 + gi
    return cube


def ansi16_rgb(i: Int) -> Int:
    """The classic CGA/VGA values of the 16 ANSI colours."""
    var table: List[Int] = [
        0x000000, 0xAA0000, 0x00AA00, 0xAA5500, 0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
        0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
    ]
    return table[i]


def rgb_to_16(rgb: Int) -> Int:
    """Nearest ANSI colour index 0..15 (8..15 are the bright variants)."""
    var r = (rgb >> 16) & 255
    var g = (rgb >> 8) & 255
    var b = rgb & 255
    var best = 0
    var best_d = 1 << 30
    for i in range(16):
        var c = ansi16_rgb(i)
        var d = dist2(r, g, b, (c >> 16) & 255, (c >> 8) & 255, c & 255)
        if d < best_d:
            best_d = d
            best = i
    return best


def x256_rgb(n: Int) -> Int:
    """The RGB value of xterm-256 palette index n (0..15: the classic VGA values)."""
    if n < 16:
        return ansi16_rgb(n)
    if n >= 232:
        var v = 8 + 10 * (n - 232)
        return v << 16 | v << 8 | v
    var k = n - 16
    return cube_value(k // 36) << 16 | cube_value((k // 6) % 6) << 8 | cube_value(k % 6)


def sgr_16(index: Int, background: Bool) -> Int:
    """SGR parameter for an ANSI colour index: 30-37/90-97 or 40-47/100-107."""
    var base = 40 if background else 30
    if index >= 8:
        return base + 60 + index - 8
    return base + index
