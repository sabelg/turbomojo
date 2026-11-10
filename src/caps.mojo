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


struct Caps(Copyable, Movable):
    var color: Int             # COLOR_16 / COLOR_256 / COLOR_TRUE
    var sync_output: Bool      # mode 2026: flicker-free frame updates
    var grapheme: Bool         # mode 2027: grapheme-cluster cursor movement
    var color_scheme: Bool     # mode 2031: light/dark change notifications
    var inband_resize: Bool    # mode 2048: resize reports on the input stream
    var kitty_keyboard: Bool   # progressive keyboard enhancement protocol
    var styled_underline: Bool # curly and coloured underlines (guessed from the environment)
    var answered: Bool         # the terminal replied to the final DA1 request

    def __init__(out self):
        self.color = COLOR_TRUE
        self.sync_output = False
        self.grapheme = False
        self.color_scheme = False
        self.inband_resize = False
        self.kitty_keyboard = False
        self.styled_underline = False
        self.answered = False

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
        out.append("curly underlines    : " + yes_no(self.styled_underline) + " (guessed)")
        out.append("answered queries    : " + yes_no(self.answered))
        return out^


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


def sgr_16(index: Int, background: Bool) -> Int:
    """SGR parameter for an ANSI colour index: 30-37/90-97 or 40-47/100-107."""
    var base = 40 if background else 30
    if index >= 8:
        return base + 60 + index - 8
    return base + index
