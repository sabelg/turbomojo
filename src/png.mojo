"""PNG decoding to RGBA pixels, for sixel pictures in the docs reader (P10-22c).

Grey, grey + alpha, RGB, RGBA (8 or 16 bits a sample) and palette pictures (1, 2, 4,
8 bits, with tRNS transparency); not interlaced ones (Adam7) - those, and anything
damaged or too large, give `ok == False` and stay a link. CRCs are not checked."""
from std.collections import List
from inflate import zlib_inflate

comptime PNG_MAX_PIXELS = 4096 * 4096


struct Picture(Movable):
    var ok: Bool
    var w: Int
    var h: Int
    var rgba: List[UInt8]       # w * h * 4 bytes, row by row

    def __init__(out self):
        self.ok = False
        self.w = 0
        self.h = 0
        self.rgba = List[UInt8]()


def be32(d: List[UInt8], at: Int) -> Int:
    return (Int(d[at]) << 24) | (Int(d[at + 1]) << 16) | (Int(d[at + 2]) << 8) | Int(d[at + 3])


def paeth(a: Int, b: Int, c: Int) -> Int:
    var p = a + b - c
    var pa = abs(p - a)
    var pb = abs(p - b)
    var pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def png_decode(data: List[UInt8]) -> Picture:
    var pic = Picture()
    var sig: List[Int] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    if len(data) < 33:
        return pic^
    for k in range(8):
        if Int(data[k]) != sig[k]:
            return pic^
    var w = 0
    var h = 0
    var depth = 0
    var ctype = -1
    var palette = List[UInt8]()
    var trns = List[UInt8]()
    var idat = List[UInt8]()
    var at = 8
    var seen_end = False
    while at + 8 <= len(data):
        var n = be32(data, at)
        var t = String("")
        for k in range(4):
            t += chr(Int(data[at + 4 + k]))
        var body = at + 8
        if n < 0 or body + n + 4 > len(data):
            return pic^
        if t == "IHDR":
            if n < 13:
                return pic^
            w = be32(data, body)
            h = be32(data, body + 4)
            depth = Int(data[body + 8])
            ctype = Int(data[body + 9])
            if Int(data[body + 10]) != 0 or Int(data[body + 11]) != 0 or Int(data[body + 12]) != 0:
                return pic^         # another compression, filter method, or interlaced
        elif t == "PLTE":
            for k in range(n):
                palette.append(data[body + k])
        elif t == "tRNS":
            for k in range(n):
                trns.append(data[body + k])
        elif t == "IDAT":
            for k in range(n):
                idat.append(data[body + k])
        elif t == "IEND":
            seen_end = True
            break
        at = body + n + 4
    _ = seen_end
    if w <= 0 or h <= 0 or w * h > PNG_MAX_PIXELS:
        return pic^
    var channels: Int
    if ctype == 0:
        channels = 1
    elif ctype == 2:
        channels = 3
    elif ctype == 3:
        channels = 1
    elif ctype == 4:
        channels = 2
    elif ctype == 6:
        channels = 4
    else:
        return pic^
    var ok_depth = depth == 8 or depth == 16 if ctype != 3 and ctype != 0 else (depth == 1 or depth == 2 or depth == 4 or depth == 8 or (ctype == 0 and depth == 16))
    if not ok_depth or (ctype == 3 and len(palette) < 3):
        return pic^
    var bpp_bits = channels * depth
    var stride = (w * bpp_bits + 7) // 8
    var bpp = max(1, bpp_bits // 8)            # the filters' byte distance
    var inf = zlib_inflate(idat, (stride + 1) * h)
    if not inf[0] or len(inf[1]) < (stride + 1) * h:
        return pic^
    var raw = inf[1].copy()
    # undo the filters, row by row
    var img = List[UInt8](length=stride * h, fill=0)
    for y in range(h):
        var f = Int(raw[y * (stride + 1)])
        var src = y * (stride + 1) + 1
        var dst = y * stride
        for x in range(stride):
            var a = Int(img[dst + x - bpp]) if x >= bpp else 0
            var b = Int(img[dst - stride + x]) if y > 0 else 0
            var c = Int(img[dst - stride + x - bpp]) if y > 0 and x >= bpp else 0
            var v = Int(raw[src + x])
            if f == 1:
                v += a
            elif f == 2:
                v += b
            elif f == 3:
                v += (a + b) // 2
            elif f == 4:
                v += paeth(a, b, c)
            elif f != 0:
                return pic^
            img[dst + x] = UInt8(v & 255)
    # to RGBA
    pic.rgba = List[UInt8](length=w * h * 4, fill=255)
    var step = 2 if depth == 16 else 1
    for y in range(h):
        var row = y * stride
        for x in range(w):
            var o = (y * w + x) * 4
            if ctype == 3 or (ctype == 0 and depth < 8):
                var per = 8 // depth
                var byte = Int(img[row + x // per])
                var shift = 8 - depth * (x % per + 1)
                var v = (byte >> shift) & ((1 << depth) - 1)
                if ctype == 3:
                    if v * 3 + 2 >= len(palette):
                        return pic^
                    pic.rgba[o] = palette[v * 3]
                    pic.rgba[o + 1] = palette[v * 3 + 1]
                    pic.rgba[o + 2] = palette[v * 3 + 2]
                    pic.rgba[o + 3] = trns[v] if v < len(trns) else UInt8(255)
                else:
                    var g = UInt8(v * 255 // ((1 << depth) - 1))
                    pic.rgba[o] = g
                    pic.rgba[o + 1] = g
                    pic.rgba[o + 2] = g
                continue
            var p = row + x * channels * step
            if ctype == 0:
                pic.rgba[o] = img[p]
                pic.rgba[o + 1] = img[p]
                pic.rgba[o + 2] = img[p]
            elif ctype == 4:
                pic.rgba[o] = img[p]
                pic.rgba[o + 1] = img[p]
                pic.rgba[o + 2] = img[p]
                pic.rgba[o + 3] = img[p + step]
            elif ctype == 2:
                pic.rgba[o] = img[p]
                pic.rgba[o + 1] = img[p + step]
                pic.rgba[o + 2] = img[p + 2 * step]
            else:
                pic.rgba[o] = img[p]
                pic.rgba[o + 1] = img[p + step]
                pic.rgba[o + 2] = img[p + 2 * step]
                pic.rgba[o + 3] = img[p + 3 * step]
    pic.w = w
    pic.h = h
    pic.ok = True
    return pic^
