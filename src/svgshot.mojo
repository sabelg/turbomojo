"""The screen as an SVG picture (P11-02): `tmide --screenshot FILE.svg` draws the IDE as it
would appear and writes what is in its cells - characters, colours, bold, underlines - as
a grid of text, so the README can show it without a screen recorder. Each row is cut into
runs of one background (rectangles) and of one colour and weight (text stretched to the
run's cells, so a font with other widths keeps the grid)."""
from std.collections import List
from palette import ANSI_BASE, COLOR_DEFAULT
from caps import x256_rgb, hex6
from screen import Screen, CONT, BOLD_BIT


comptime SVG_CELL_W = 9
comptime SVG_CELL_H = 18


def svg_rgb(c: Int, dflt: Int) -> String:
    """`#rrggbb` for a cell colour: an RGB value, a palette slot (its xterm value) or
    the terminal's default (`dflt`)."""
    var v = c
    if c < 0 or c == COLOR_DEFAULT:
        v = dflt
    elif c >= ANSI_BASE:
        v = x256_rgb((c - ANSI_BASE) & 255)
    return "#" + hex6(v & 0xFFFFFF).lower()


def xml_text(c: Int) -> String:
    if c == 38:
        return "&amp;"
    if c == 60:
        return "&lt;"
    if c == 62:
        return "&gt;"
    if c == 34:
        return "&quot;"
    if c < 32 or (c >= 0xD800 and c < 0xE000) or c == 0xFFFE or c == 0xFFFF or c > 0x10FFFF:
        return " "          # not allowed in XML
    return chr(c)


def screen_svg(scr: Screen, def_fg: Int, def_bg: Int, title: String = "TurboMojo") -> String:
    var w = scr.w * SVG_CELL_W
    var h = scr.h * SVG_CELL_H
    var out = String("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"") + String(w) + "\" height=\"" + String(h) + "\" viewBox=\"0 0 " + String(w) + " " + String(h) + "\" font-family=\"'DejaVu Sans Mono','Cascadia Mono',Menlo,Consolas,monospace\" font-size=\"15\">\n"
    out += "<title>"
    for c in title.codepoints():
        out += xml_text(Int(c))
    out += "</title>\n"
    out += "<rect width=\"100%\" height=\"100%\" fill=\"" + svg_rgb(def_bg, def_bg) + "\"/>\n"
    for y in range(scr.h):
        # backgrounds
        var x = 0
        while x < scr.w:
            var b = scr.bg[y * scr.w + x]
            var e = x + 1
            while e < scr.w and scr.bg[y * scr.w + e] == b:
                e += 1
            if svg_rgb(b, def_bg) != svg_rgb(def_bg, def_bg):
                out += "<rect x=\"" + String(x * SVG_CELL_W) + "\" y=\"" + String(y * SVG_CELL_H) + "\" width=\"" + String((e - x) * SVG_CELL_W) + "\" height=\"" + String(SVG_CELL_H) + "\" fill=\"" + svg_rgb(b, def_bg) + "\"/>\n"
            x = e
        # text: runs of one colour, weight and underline
        x = 0
        while x < scr.w:
            var k = y * scr.w + x
            var f = scr.fg[k]
            var u = scr.ul[k]
            var e = x
            var text = String("")
            var blank = True
            while e < scr.w:
                var j = y * scr.w + e
                if scr.ch[j] != CONT and (scr.fg[j] != f or scr.ul[j] != u):
                    break
                var c = scr.ch[j]
                if c != CONT:
                    text += xml_text(c)
                    for m in scr.extras(j):
                        text += xml_text(m)
                    if c != 32:
                        blank = False
                e += 1
            if not blank or (u & ~BOLD_BIT) != 0:
                out += "<text x=\"" + String(x * SVG_CELL_W) + "\" y=\"" + String(y * SVG_CELL_H + 14) + "\" textLength=\"" + String((e - x) * SVG_CELL_W) + "\" lengthAdjust=\"spacingAndGlyphs\" xml:space=\"preserve\" fill=\"" + svg_rgb(f, def_fg) + "\""
                if (u & BOLD_BIT) != 0:
                    out += " font-weight=\"bold\""
                if (u & ~BOLD_BIT) != 0:
                    out += " text-decoration=\"underline\""
                out += ">" + text + "</text>\n"
            x = e
    return out + "</svg>\n"
