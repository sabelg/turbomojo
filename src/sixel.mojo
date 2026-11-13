"""Sixel output, for pictures in the docs reader where the terminal has no kitty
graphics (P10-22c): a decoded picture scaled to its cells, its colours put on the
6 x 6 x 6 cube (216 registers), sent band by band (six pixel rows each) with
run-length counts. Mostly transparent pixels stay transparent (P2 = 1)."""
from std.collections import List
from png import Picture


def scale_to(pic: Picture, w: Int, h: Int) -> List[UInt8]:
    """The picture as w x h RGBA pixels (nearest neighbour)."""
    var out = List[UInt8](length=w * h * 4, fill=0)
    for y in range(h):
        var sy = min(pic.h - 1, y * pic.h // h)
        for x in range(w):
            var sx = min(pic.w - 1, x * pic.w // w)
            var s = (sy * pic.w + sx) * 4
            var d = (y * w + x) * 4
            out[d] = pic.rgba[s]
            out[d + 1] = pic.rgba[s + 1]
            out[d + 2] = pic.rgba[s + 2]
            out[d + 3] = pic.rgba[s + 3]
    return out^


def fit_pixels(pw: Int, ph: Int, box_w: Int, box_h: Int) -> Tuple[Int, Int]:
    """The largest size with the picture's proportions inside the box (never larger
    than the picture itself is not required: small pictures are scaled up to fit)."""
    var w = box_w
    var h = ph * box_w // pw
    if h > box_h:
        h = box_h
        w = max(1, pw * box_h // ph)
    return (max(1, w), max(1, h))


def cube_index(r: Int, g: Int, b: Int) -> Int:
    return ((r * 5 + 127) // 255) * 36 + ((g * 5 + 127) // 255) * 6 + (b * 5 + 127) // 255


def put_run(mut out: String, ch: Int, n: Int):
    if n <= 0:
        return
    if n > 3:
        out += "!" + String(n) + chr(ch)
    else:
        for _ in range(n):
            out += chr(ch)


def sixel_encode(rgba: List[UInt8], w: Int, h: Int, bg: Int) -> String:
    """Sixel data for w x h RGBA pixels. Half-transparent pixels are mixed with `bg`
    (0xRRGGBB, the page's background); pixels under alpha 64 are left out."""
    var idx = List[Int](length=w * h, fill=-1)
    var used = List[Bool](length=216, fill=False)
    var br = (bg >> 16) & 255
    var bgc = (bg >> 8) & 255
    var bb = bg & 255
    for k in range(w * h):
        var a = Int(rgba[k * 4 + 3])
        if a < 64:
            continue
        var r = (Int(rgba[k * 4]) * a + br * (255 - a)) // 255
        var g = (Int(rgba[k * 4 + 1]) * a + bgc * (255 - a)) // 255
        var b = (Int(rgba[k * 4 + 2]) * a + bb * (255 - a)) // 255
        var c = cube_index(r, g, b)
        idx[k] = c
        used[c] = True
    var out = String("\x1bP0;1;0q\"1;1;") + String(w) + ";" + String(h)
    for c in range(216):
        if used[c]:
            out += "#" + String(c) + ";2;" + String((c // 36) * 20) + ";" + String(((c // 6) % 6) * 20) + ";" + String((c % 6) * 20)
    var bits = List[Int](length=216 * w, fill=0)
    var band = 0
    while band * 6 < h:
        var colours = List[Int]()
        var have = List[Bool](length=216, fill=False)
        for x in range(w):
            for dy in range(6):
                var y = band * 6 + dy
                if y >= h:
                    break
                var c = idx[y * w + x]
                if c < 0:
                    continue
                if not have[c]:
                    have[c] = True
                    colours.append(c)
                bits[c * w + x] |= 1 << dy
        for ci in range(len(colours)):
            var c = colours[ci]
            out += "#" + String(c)
            var run = 0
            var last = -1
            for x in range(w):
                var v = 63 + bits[c * w + x]
                bits[c * w + x] = 0
                if v == last:
                    run += 1
                else:
                    put_run(out, last, run)
                    last = v
                    run = 1
            if last != 63:
                put_run(out, last, run)     # (empty sixels at the end of a line are left out)
            out += "$" if ci + 1 < len(colours) else ""
        out += "-"
        band += 1
    return out + "\x1b\\"
