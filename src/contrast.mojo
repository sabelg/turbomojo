"""Contrast of a theme's colours, by two measures:

- WCAG 2.x contrast ratio (1 to 21): 4.5 is the AA floor for text, 7 for AAA, 3 for
  large text and interface parts;
- APCA Lc (Accessible Perceptual Contrast Algorithm, version 0.0.98G-4g, the candidate
  for WCAG 3): 0 to about 106 for dark text on light, 0 to about -108 for light on dark;
  its guidance is about 75 for body text and code, 60 for other text, 45 for large or
  secondary text, 30 for disabled text and decorations.

`theme_contrast` lists the pairs of a theme (text on its background) with the floor
each must reach; `contrast_problems` says which fall short. Only colours given as RGB
can be measured: a palette slot or the terminal's default colour (Terminal ANSI and
Mono) depends on the terminal and is skipped.
"""
from std.collections import List
from std.math import pow
from palette import Palette, is_rgb, mix, ANSI_BASE
from caps import COLOR_256, COLOR_16, rgb_to_256, rgb_to_16, x256_rgb, ansi16_rgb

comptime ROLE_TEXT = 0          # body text, code and selections: WCAG 4.5:1 and Lc 45
comptime ROLE_SECONDARY = 1     # comments, line numbers, dim text: WCAG 3:1 and Lc 30
comptime ROLE_DISABLED = 2      # disabled items, inactive frames: Lc 15 (WCAG exempts them)


def lin(c: Int) -> Float64:
    """An sRGB channel (0-255) made linear, as WCAG defines it."""
    var v = Float64(c) / 255.0
    if v <= 0.04045:
        return v / 12.92
    return pow((v + 0.055) / 1.055, 2.4)


def wcag_luminance(rgb: Int) -> Float64:
    return 0.2126 * lin((rgb >> 16) & 255) + 0.7152 * lin((rgb >> 8) & 255) + 0.0722 * lin(rgb & 255)


def wcag_ratio(a: Int, b: Int) -> Float64:
    var la = wcag_luminance(a)
    var lb = wcag_luminance(b)
    var hi = la if la > lb else lb
    var lo = lb if la > lb else la
    return (hi + 0.05) / (lo + 0.05)


def apca_y(rgb: Int) -> Float64:
    """APCA's screen luminance: a simple 2.4 power, then a soft clamp near black."""
    var r = pow(Float64((rgb >> 16) & 255) / 255.0, 2.4)
    var g = pow(Float64((rgb >> 8) & 255) / 255.0, 2.4)
    var b = pow(Float64(rgb & 255) / 255.0, 2.4)
    var y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    if y < 0.022:
        y += pow(0.022 - y, 1.414)
    return y


def apca_lc(text: Int, bg: Int) -> Float64:
    """APCA lightness contrast of `text` on `bg` (positive: dark on light; negative:
    light on dark)."""
    var yt = apca_y(text)
    var yb = apca_y(bg)
    if abs(yb - yt) < 0.0005:
        return 0.0
    if yb > yt:
        var sapc = (pow(yb, 0.56) - pow(yt, 0.57)) * 1.14
        return 0.0 if sapc < 0.1 else (sapc - 0.027) * 100.0
    var sapc = (pow(yb, 0.65) - pow(yt, 0.62)) * 1.14
    return 0.0 if sapc > -0.1 else (sapc + 0.027) * 100.0


struct ContrastPair(Copyable, Movable):
    var what: String        # "ed_fg on ed_bg", "syntax comment on ed_bg"
    var fg: Int
    var bg: Int
    var role: Int

    def __init__(out self, what: String, fg: Int, bg: Int, role: Int):
        self.what = what
        self.fg = fg
        self.bg = bg
        self.role = role


def floors(role: Int) -> Tuple[Float64, Float64]:
    """(WCAG ratio, |APCA Lc|) a pair of this role must reach."""
    if role == ROLE_TEXT:
        return (4.5, 45.0)
    if role == ROLE_SECONDARY:
        return (3.0, 30.0)
    return (1.0, 15.0)


def one_decimal(x: Float64) -> String:
    var n = Int(x * 10.0 + 0.5)
    return String(n // 10) + "." + String(n % 10)


comptime SYNTAX_NAMES = "text keyword type comment string number decorator symbol builtin self def param property namespace"


def theme_contrast(p: Palette) -> List[ContrastPair]:
    var out = List[ContrastPair]()
    for pre in ["ed", "msg", "dlg", "doc", "list", "in"]:
        out.append(ContrastPair(String(pre) + "_fg on " + String(pre) + "_bg", palette_pair(p, String(pre), True), palette_pair(p, String(pre), False), ROLE_TEXT))
    out.append(ContrastPair("menu_fg on menu_bg", p.menu_fg, p.menu_bg, ROLE_TEXT))
    out.append(ContrastPair("status_fg on status_bg", p.status_fg, p.status_bg, ROLE_TEXT))
    out.append(ContrastPair("sel_fg on sel_bg", p.sel_fg, p.sel_bg, ROLE_TEXT))
    out.append(ContrastPair("menu_sel_fg on menu_sel_bg", p.menu_sel_fg, p.menu_sel_bg, ROLE_TEXT))
    out.append(ContrastPair("msg_sel_fg on msg_sel_bg", p.msg_sel_fg, p.msg_sel_bg, ROLE_TEXT))
    out.append(ContrastPair("list_sel_fg on list_sel_bg", p.list_sel_fg, p.list_sel_bg, ROLE_TEXT))
    out.append(ContrastPair("btn_fg on btn_bg", p.btn_fg, p.btn_bg, ROLE_TEXT))
    out.append(ContrastPair("menu_hot on menu_bg", p.menu_hot, p.menu_bg, ROLE_TEXT))
    out.append(ContrastPair("diag_err on ed_bg", p.diag_err, p.ed_bg, ROLE_TEXT))
    out.append(ContrastPair("diag_warn on ed_bg", p.diag_warn, p.ed_bg, ROLE_TEXT))
    out.append(ContrastPair("msg_err on msg_bg", p.msg_err, p.msg_bg, ROLE_TEXT))
    out.append(ContrastPair("msg_warn on msg_bg", p.msg_warn, p.msg_bg, ROLE_TEXT))
    out.append(ContrastPair("gutter_fg on gutter_bg", p.gutter_fg, p.gutter_bg, ROLE_SECONDARY))
    out.append(ContrastPair("doc_dim on doc_bg", p.doc_dim, p.doc_bg, ROLE_SECONDARY))
    out.append(ContrastPair("frame_inact on ed_bg", p.frame_inact, p.ed_bg, ROLE_DISABLED))
    out.append(ContrastPair("menu_dis on menu_bg", p.menu_dis, p.menu_bg, ROLE_DISABLED))
    var names = SYNTAX_NAMES.split(" ")
    for k in range(min(len(p.syn), len(names))):
        var role = ROLE_SECONDARY if String(names[k]) == "comment" else ROLE_TEXT
        out.append(ContrastPair("syntax " + String(names[k]) + " on ed_bg", p.syn[k], p.ed_bg, role))
    return out^


def palette_pair(p: Palette, pre: String, fg: Bool) -> Int:
    if pre == "ed":
        return p.ed_fg if fg else p.ed_bg
    if pre == "msg":
        return p.msg_fg if fg else p.msg_bg
    if pre == "dlg":
        return p.dlg_fg if fg else p.dlg_bg
    if pre == "doc":
        return p.doc_fg if fg else p.doc_bg
    if pre == "list":
        return p.list_fg if fg else p.list_bg
    return p.in_fg if fg else p.in_bg


def contrast_problems(p: Palette) -> List[String]:
    """The pairs of a theme below their floors ("ed_fg on ed_bg: 3.2:1, Lc 41 (needs
    4.5:1, Lc 60)"); pairs with a colour that is not RGB are skipped."""
    var out = List[String]()
    for c in theme_contrast(p):
        if not is_rgb(c.fg) or not is_rgb(c.bg):
            continue
        var f = floors(c.role)
        var w = wcag_ratio(c.fg, c.bg)
        var l = abs(apca_lc(c.fg, c.bg))
        if w < f[0] or l < f[1]:
            out.append(c.what + ": " + one_decimal(w) + ":1, Lc " + String(Int(l)) + " (needs " + one_decimal(f[0]) + ":1, Lc " + String(Int(f[1])) + ")")
    return out^


# ------------------------------------------------- muted and disabled text
def toned(fg: Int, bg: Int, start_pct: Int, role: Int) -> Int:
    """`fg` moved toward `bg` - `start_pct` percent of fg left - but no further than
    the floors of `role` allow (closer to fg in steps of 5 until they are met)."""
    var f = floors(role)
    var pct = start_pct
    while pct < 100:
        var c = mix(fg, bg, pct)
        if wcag_ratio(c, bg) >= f[0] and abs(apca_lc(c, bg)) >= f[1]:
            return c
        pct += 5
    return fg


def text_muted(fg: Int, bg: Int) -> Int:
    """Secondary text on a surface whose text is `fg` (key labels in menus and the
    palette, a file's folder, the status line's file facts): as dim as the
    secondary floor (WCAG 3:1, Lc 30) allows. A colour that is not RGB stays."""
    if not is_rgb(fg) or not is_rgb(bg):
        return fg
    return toned(fg, bg, 60, ROLE_SECONDARY)


def text_disabled(p: Palette, fg: Int, bg: Int) -> Int:
    """Text of something that cannot be used now: the theme's `menu_dis` on the menu
    bar's and the status line's surfaces (where it is measured), elsewhere `fg`
    toward `bg` down to the disabled floor (Lc 15); `menu_dis` for colours that are
    not RGB."""
    if bg == p.menu_bg or bg == p.status_bg or not is_rgb(fg) or not is_rgb(bg):
        return p.menu_dis
    return toned(fg, bg, 35, ROLE_DISABLED)


def dimmed(fg: Int, bg: Int) -> Int:
    """A cell's text while the terminal does not have the focus (ui.dim_unfocused)."""
    if not is_rgb(fg) or not is_rgb(bg):
        return fg
    return mix(fg, bg, 55)


# ------------------------------------------------- colour-vision deficiency
comptime CVD_NONE = 0
comptime CVD_PROTAN = 1         # no long-wave (red) cones
comptime CVD_DEUTAN = 2         # no medium-wave (green) cones
comptime CVD_TRITAN = 3         # no short-wave (blue) cones
comptime CVD_SIGNAL_MIN = 20.0  # CIE76 delta E signal colours keep from each other
comptime CVD_SYNTAX_MIN = 10.0  # ... and the main syntax classes


def cvd_name(kind: Int) -> String:
    if kind == CVD_PROTAN:
        return "protanopia"
    if kind == CVD_DEUTAN:
        return "deuteranopia"
    if kind == CVD_TRITAN:
        return "tritanopia"
    return "normal vision"


def cvd_linear(rgb: Int, kind: Int) -> Tuple[Float64, Float64, Float64]:
    """The colour as seen with the deficiency `kind` at full severity, as linear RGB
    (the matrices of Machado, Oliveira and Fernandes 2009, applied to linear RGB)."""
    var r = lin((rgb >> 16) & 255)
    var g = lin((rgb >> 8) & 255)
    var b = lin(rgb & 255)
    if kind == CVD_NONE:
        return (r, g, b)
    var m: List[Float64]
    if kind == CVD_PROTAN:
        m = [0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998]
    elif kind == CVD_DEUTAN:
        m = [0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881]
    else:
        m = [1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900]
    var o = List[Float64]()
    for i in range(3):
        var v = m[3 * i] * r + m[3 * i + 1] * g + m[3 * i + 2] * b
        o.append(min(1.0, max(0.0, v)))
    return (o[0], o[1], o[2])


def lab_f(t: Float64) -> Float64:
    if t > 0.008856:
        return pow(t, 1.0 / 3.0)
    return 7.787 * t + 16.0 / 116.0


def cvd_lab(rgb: Int, kind: Int) -> Tuple[Float64, Float64, Float64]:
    """CIE L*a*b* (D65) of the colour as seen with `kind`."""
    var c = cvd_linear(rgb, kind)
    var x = 0.4124 * c[0] + 0.3576 * c[1] + 0.1805 * c[2]
    var y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    var z = 0.0193 * c[0] + 0.1192 * c[1] + 0.9505 * c[2]
    var fx = lab_f(x / 0.95047)
    var fy = lab_f(y)
    var fz = lab_f(z / 1.08883)
    return (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))


def cvd_distance(a: Int, b: Int, kind: Int) -> Float64:
    """How far apart two colours look with `kind` (CIE76 delta E; about 2.3 is just
    noticeable, 10 plainly different side by side)."""
    var p = cvd_lab(a, kind)
    var q = cvd_lab(b, kind)
    var d0 = p[0] - q[0]
    var d1 = p[1] - q[1]
    var d2 = p[2] - q[2]
    return (d0 * d0 + d1 * d1 + d2 * d2) ** 0.5


struct CvdPair(Copyable, Movable):
    var what: String
    var a: Int
    var b: Int
    var floor: Float64

    def __init__(out self, what: String, a: Int, b: Int, floor: Float64):
        self.what = what
        self.a = a
        self.b = b
        self.floor = floor


def cvd_pairs(p: Palette) -> List[CvdPair]:
    """The colours that tell things apart and must stay apart: the problem severities
    (in the editor and the Message window), success against failure, the git
    markers, and the main syntax classes."""
    var out = List[CvdPair]()
    out.append(CvdPair("diag_err / diag_warn", p.diag_err, p.diag_warn, CVD_SIGNAL_MIN))
    out.append(CvdPair("diag_err / diag_note", p.diag_err, p.diag_note, CVD_SIGNAL_MIN))
    out.append(CvdPair("diag_warn / diag_note", p.diag_warn, p.diag_note, CVD_SIGNAL_MIN))
    out.append(CvdPair("msg_err / msg_warn", p.msg_err, p.msg_warn, CVD_SIGNAL_MIN))
    out.append(CvdPair("msg_err / msg_note", p.msg_err, p.msg_note, CVD_SIGNAL_MIN))
    out.append(CvdPair("msg_warn / msg_note", p.msg_warn, p.msg_note, CVD_SIGNAL_MIN))
    out.append(CvdPair("msg_ok / msg_err", p.msg_ok, p.msg_err, CVD_SIGNAL_MIN))
    out.append(CvdPair("git_add / git_mod", p.git_add, p.git_mod, CVD_SIGNAL_MIN))
    out.append(CvdPair("git_add / git_del", p.git_add, p.git_del, CVD_SIGNAL_MIN))
    out.append(CvdPair("git_mod / git_del", p.git_mod, p.git_del, CVD_SIGNAL_MIN))
    var names = SYNTAX_NAMES.split(" ")
    var main = [1, 2, 3, 4, 5, 10]          # keyword type comment string number def
    for x in range(len(main)):
        for y in range(x + 1, len(main)):
            var i = main[x]
            var j = main[y]
            if j < len(p.syn):
                out.append(CvdPair("syntax " + String(names[i]) + " / " + String(names[j]), p.syn[i], p.syn[j], CVD_SYNTAX_MIN))
    return out^


def cvd_problems(p: Palette) -> List[String]:
    """The pairs that come too close with normal vision or one of the three
    deficiencies ("git_add / git_del: 8.1 with deuteranopia (needs 20)"). Signal
    colours (severities, success / failure, git markers) must always be apart -
    except in a theme of one hue by design (`monochrome`: Amber CRT, Terminal Mono),
    which tells them apart by letters and marks alone. Syntax classes a theme gives
    alike on purpose (closer than the floor with normal vision) are its choice; the
    others must stay apart with each deficiency. Pairs with a colour that is not RGB
    are skipped."""
    var out = List[String]()
    for c in cvd_pairs(p):
        if not is_rgb(c.a) or not is_rgb(c.b):
            continue
        var signal = c.floor >= CVD_SIGNAL_MIN
        if signal and p.monochrome:
            continue
        if not signal and cvd_distance(c.a, c.b, CVD_NONE) < c.floor:
            continue
        for kind in range(4):
            var d = cvd_distance(c.a, c.b, kind)
            if d < c.floor:
                out.append(c.what + ": " + one_decimal(d) + " with " + cvd_name(kind) + " (needs " + String(Int(c.floor)) + ")")
    return out^


# ------------------------------------------------- 256 and 16 colours
def depth_rgb(c: Int, mode: Int) -> Int:
    """The colour a terminal of depth `mode` shows for c, as RGB: the xterm-256 value
    of its index, or the VGA value of its slot of 16; -1 when it depends on the
    terminal (its default colour). An xterm index shown with 16 colours goes to the
    nearest slot, as the screen sends it."""
    if c >= ANSI_BASE and c < ANSI_BASE + 256:
        var n = c - ANSI_BASE
        if n < 16:
            return ansi16_rgb(n)
        return x256_rgb(n) if mode == COLOR_256 else ansi16_rgb(rgb_to_16(x256_rgb(n)))
    if not is_rgb(c):
        return -1
    if mode == COLOR_256:
        return x256_rgb(rgb_to_256(c))
    if mode == COLOR_16:
        return ansi16_rgb(rgb_to_16(c))
    return c


def depth_problems(p: Palette, mode: Int) -> List[String]:
    """The pairs of a theme's palette for depth `mode` that fall short as the terminal
    shows them: in 256 colours (whose values terminals share) the same floors as in
    truecolor; in 16 colours, whose real values are the terminal's own, the WCAG
    floors with the VGA values and never text in its background's slot."""
    var out = List[String]()
    for c in theme_contrast(p):
        var f = depth_rgb(c.fg, mode)
        var b = depth_rgb(c.bg, mode)
        if f < 0 or b < 0:
            continue
        var fl = floors(c.role)
        var w = wcag_ratio(f, b)
        var l = abs(apca_lc(f, b))
        if mode == COLOR_16:
            if f == b and c.role != ROLE_DISABLED:
                out.append(c.what + ": the same colour as its background")
            elif w < fl[0] or (c.role == ROLE_DISABLED and f == b):
                out.append(c.what + ": " + one_decimal(w) + ":1 (needs " + one_decimal(fl[0]) + ":1)")
        elif w < fl[0] or l < fl[1]:
            out.append(c.what + ": " + one_decimal(w) + ":1, Lc " + String(Int(l)) + " (needs " + one_decimal(fl[0]) + ":1, Lc " + String(Int(fl[1])) + ")")
    return out^


# ------------------------------------------------- quiet code colours
comptime QUIET_SALIENCE = 80    # a code colour keeps under 80% of the error colour's distance from the text


def cvd_nearest(c: Int, others: List[Int]) -> Float64:
    """How close c comes to any of `others`, with normal vision or a deficiency."""
    var best = 1.0e9
    for o in others:
        if not is_rgb(o):
            continue
        for kind in range(4):
            best = min(best, cvd_distance(c, o, kind))
    return best


def calm_toward(c: Int, text: Int, bg: Int, below: Float64, others: List[Int]) -> Int:
    """The calmest colour near c - c mixed toward the text colour, the background,
    white or black, in steps of 5% - that is less than `below` from the text, at least CVD_SYNTAX_MIN
    from each of `others` with every deficiency, and readable on bg (the text
    floors). Without one that is apart: the most apart of those quiet enough; without
    one quiet enough: c."""
    if not is_rgb(c) or not is_rgb(text) or not is_rgb(bg):
        return c
    var best = c
    var best_d = 1.0e9          # distance from the text: smaller is calmer
    var fallback = c
    var fallback_apart = -1.0
    var floor = floors(ROLE_TEXT)
    var towards: List[Int] = [text, bg, 0xFFFFFF, 0x000000]
    for toward in towards:
        for pct in range(20, 101, 5):
            var cand = mix(c, toward, pct)
            var d = cvd_distance(cand, text, CVD_NONE)
            if below > 0.0 and d >= below:
                continue
            if wcag_ratio(cand, bg) < floor[0] or abs(apca_lc(cand, bg)) < floor[1]:
                continue
            var apart = cvd_nearest(cand, others)
            if apart >= CVD_SYNTAX_MIN and d < best_d:
                best = cand
                best_d = d
            if apart > fallback_apart:
                fallback = cand
                fallback_apart = apart
    if best_d < 1.0e9:
        return best
    return fallback


def quiet_syntax(p: Palette) -> List[Int]:
    """The theme's syntax colours folded into four, as restrained schemes do (tonsky's
    Alabaster): text - also keywords, types, built-ins, self, decorators, parameters,
    properties, namespaces and punctuation -, comments, strings and numbers, and
    definitions. Strings and definitions become the calmest colours near their own
    that are less than QUIET_SALIENCE percent as far from the text as the error
    colour is - so that problems stand out most -, still apart for colour-blind eyes
    and readable (calm_toward). Colours that are not RGB are taken as they are."""
    var syn = p.syn.copy()
    if len(syn) < 14:
        return syn^
    var text = syn[0]
    var below = 0.0
    if is_rgb(p.diag_err) and is_rgb(text):
        below = cvd_distance(p.diag_err, text, CVD_NONE) * Float64(QUIET_SALIENCE) / 100.0
    var cmt = syn[3]                # (comments are quiet already: muted text)
    var st = calm_toward(syn[4], text, p.ed_bg, below, [text, cmt])
    var de = calm_toward(syn[10], text, p.ed_bg, below, [text, cmt, st])
    var out = List[Int]()
    for k in range(len(syn)):
        if k == 3:
            out.append(cmt)
        elif k == 4 or k == 5:
            out.append(st)
        elif k == 10:
            out.append(de)
        else:
            out.append(text)
    return out^
