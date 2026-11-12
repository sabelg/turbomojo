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
from palette import Palette, is_rgb

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
