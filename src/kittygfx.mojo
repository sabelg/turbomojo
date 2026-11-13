"""Kitty graphics protocol, for pictures in the documentation reader (P10-22b).

A picture is sent once as it is (PNG, f=100) and given a *virtual placement* (U=1)
of so many columns and rows; the screen then shows it through ordinary text cells:
each holds U+10EEEE with combining marks that say which row and column of the picture
it is, in a foreground colour that says which picture (the image id, as an xterm-256
index). Because those are just characters, the picture scrolls, clips and repaints
with the text, and it passes through tmux (which only has to let the commands
through: `set -g allow-passthrough on`). https://sw.kovidgoyal.net/kitty/graphics-protocol/
"""
from std.collections import List
from util import base64, decode

comptime PLACEHOLDER = 0x10EEEE
comptime GFX_FIRST_ID = 16      # ids 16..255: sent as 38;5;id (0..15 would be SGR 30-37)
comptime GFX_LAST_ID = 255
comptime GFX_MAX_BYTES = 8000000   # larger files stay a link
comptime GFX_CHUNK = 4096

# The row / column marks, in order (kitty's gen/rowcolumn-diacritics.txt: 297 of them).
comptime DIACRITICS_HEX = "0305 030D 030E 0310 0312 033D 033E 033F 0346 034A 034B 034C 0350 0351 0352 0357\n035B 0363 0364 0365 0366 0367 0368 0369 036A 036B 036C 036D 036E 036F 0483 0484\n0485 0486 0487 0592 0593 0594 0595 0597 0598 0599 059C 059D 059E 059F 05A0 05A1\n05A8 05A9 05AB 05AC 05AF 05C4 0610 0611 0612 0613 0614 0615 0616 0617 0657 0658\n0659 065A 065B 065D 065E 06D6 06D7 06D8 06D9 06DA 06DB 06DC 06DF 06E0 06E1 06E2\n06E4 06E7 06E8 06EB 06EC 0730 0732 0733 0735 0736 073A 073D 073F 0740 0741 0743\n0745 0747 0749 074A 07EB 07EC 07ED 07EE 07EF 07F0 07F1 07F3 0816 0817 0818 0819\n081B 081C 081D 081E 081F 0820 0821 0822 0823 0825 0826 0827 0829 082A 082B 082C\n082D 0951 0953 0954 0F82 0F83 0F86 0F87 135D 135E 135F 17DD 193A 1A17 1A75 1A76\n1A77 1A78 1A79 1A7A 1A7B 1A7C 1B6B 1B6D 1B6E 1B6F 1B70 1B71 1B72 1B73 1CD0 1CD1\n1CD2 1CDA 1CDB 1CE0 1DC0 1DC1 1DC3 1DC4 1DC5 1DC6 1DC7 1DC8 1DC9 1DCB 1DCC 1DD1\n1DD2 1DD3 1DD4 1DD5 1DD6 1DD7 1DD8 1DD9 1DDA 1DDB 1DDC 1DDD 1DDE 1DDF 1DE0 1DE1\n1DE2 1DE3 1DE4 1DE5 1DE6 1DFE 20D0 20D1 20D4 20D5 20D6 20D7 20DB 20DC 20E1 20E7\n20E9 20F0 2CEF 2CF0 2CF1 2DE0 2DE1 2DE2 2DE3 2DE4 2DE5 2DE6 2DE7 2DE8 2DE9 2DEA\n2DEB 2DEC 2DED 2DEE 2DEF 2DF0 2DF1 2DF2 2DF3 2DF4 2DF5 2DF6 2DF7 2DF8 2DF9 2DFA\n2DFB 2DFC 2DFD 2DFE 2DFF A66F A67C A67D A6F0 A6F1 A8E0 A8E1 A8E2 A8E3 A8E4 A8E5\nA8E6 A8E7 A8E8 A8E9 A8EA A8EB A8EC A8ED A8EE A8EF A8F0 A8F1 AAB0 AAB2 AAB3 AAB7\nAAB8 AABE AABF AAC1 FE20 FE21 FE22 FE23 FE24 FE25 FE26 10A0F 10A38 1D185 1D186 1D187\n1D188 1D189 1D1AA 1D1AB 1D1AC 1D1AD 1D242 1D243 1D244"


def kitty_diacritics() -> List[Int]:
    var out = List[Int]()
    var v = 0
    var digits = 0
    for c in DIACRITICS_HEX.codepoints():
        var b = Int(c)
        var d = -1
        if b >= 48 and b <= 57:
            d = b - 48
        elif b >= 65 and b <= 70:
            d = b - 55
        if d >= 0:
            v = v * 16 + d
            digits += 1
        elif digits > 0:
            out.append(v)
            v = 0
            digits = 0
    if digits > 0:
        out.append(v)
    return out^


def png_size(data: List[UInt8]) -> Tuple[Int, Int]:
    """Width and height from a PNG's IHDR chunk; (-1, -1) if it is not a PNG."""
    var sig: List[Int] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    if len(data) < 24:
        return (-1, -1)
    for k in range(8):
        if Int(data[k]) != sig[k]:
            return (-1, -1)
    if Int(data[12]) != 0x49 or Int(data[13]) != 0x48 or Int(data[14]) != 0x44 or Int(data[15]) != 0x52:
        return (-1, -1)
    var w = (Int(data[16]) << 24) | (Int(data[17]) << 16) | (Int(data[18]) << 8) | Int(data[19])
    var h = (Int(data[20]) << 24) | (Int(data[21]) << 16) | (Int(data[22]) << 8) | Int(data[23])
    if w <= 0 or h <= 0:
        return (-1, -1)
    return (w, h)


def image_cells(w: Int, h: Int, max_cols: Int, max_rows: Int, cell_w: Int = 10, cell_h: Int = 20) -> Tuple[Int, Int]:
    """Columns and rows for a w x h picture with cells of cell_w x cell_h pixels (the
    terminal's, else about 10 x 20), never wider than `max_cols` or higher than
    `max_rows`, the proportions kept."""
    var cols = max(1, min(max_cols, (w + cell_w - 1) // cell_w))
    var rows = max(1, (cols * cell_w * h + w * cell_h // 2) // (w * cell_h))
    if rows > max_rows:
        rows = max(1, max_rows)
        cols = max(1, min(cols, (rows * cell_h * w + h * cell_w // 2) // (h * cell_w)))
    return (cols, rows)


def wrap_for_tmux(seq: String) -> String:
    """A command passed through tmux to the terminal outside (DCS tmux; with every ESC
    doubled)."""
    return "\x1bPtmux;" + seq.replace("\x1b", "\x1b\x1b") + "\x1b\\"


def kitty_transmit(id: Int, png: List[UInt8], cols: Int, rows: Int, tmux: Bool) -> String:
    """Send the PNG and make its virtual placement of cols x rows cells (quietly: q=2,
    the terminal answers nothing)."""
    var data = base64(png)
    var n = data.byte_length()
    var out = String("")
    var at = 0
    var first = True
    while first or at < n:
        var end = min(n, at + GFX_CHUNK)
        var more = 1 if end < n else 0
        var head = String("")
        if first:
            head = "a=T,U=1,f=100,t=d,i=" + String(id) + ",c=" + String(cols) + ",r=" + String(rows) + ",q=2,m=" + String(more)
        else:
            head = "m=" + String(more) + ",q=2"
        var apc = "\x1b_G" + head + ";" + String(data[byte=at:end]) + "\x1b\\"
        out += wrap_for_tmux(apc) if tmux else apc
        at = end
        first = False
    return out


def kitty_delete(id: Int, tmux: Bool) -> String:
    """Delete the picture and its placements (the terminal frees its memory)."""
    var apc = "\x1b_Ga=d,d=I,i=" + String(id) + ",q=2\x1b\\"
    return wrap_for_tmux(apc) if tmux else apc
