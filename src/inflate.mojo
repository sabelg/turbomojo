"""Inflate: the zlib / DEFLATE decompressor (RFC 1950, 1951), for PNG pictures.

Written after Mark Adler's puff.c: canonical Huffman codes decoded bit by bit from
counts and sorted symbols - small and plain rather than fast (pictures for the docs
reader are small). Any damage gives `ok == False`, never a crash or an endless loop."""
from std.collections import List

comptime MAXBITS = 15


struct Huffman(Copyable, Movable):
    var count: List[Int]     # codes of each length (0..MAXBITS)
    var symbol: List[Int]    # symbols, ordered by code

    def __init__(out self):
        self.count = List[Int](length=MAXBITS + 1, fill=0)
        self.symbol = List[Int]()


struct Inflater:
    var src: List[UInt8]
    var pos: Int
    var bitbuf: Int
    var bitcnt: Int
    var bad: Bool
    var out: List[UInt8]
    var limit: Int           # most bytes the output may have (a bomb stops there)

    def __init__(out self, src: List[UInt8], start: Int, limit: Int):
        self.src = src.copy()
        self.pos = start
        self.bitbuf = 0
        self.bitcnt = 0
        self.bad = False
        self.out = List[UInt8]()
        self.limit = limit

    def bits(mut self, need: Int) -> Int:
        var val = self.bitbuf
        while self.bitcnt < need:
            if self.pos >= len(self.src):
                self.bad = True
                return 0
            val |= Int(self.src[self.pos]) << self.bitcnt
            self.pos += 1
            self.bitcnt += 8
        self.bitbuf = val >> need
        self.bitcnt -= need
        return val & ((1 << need) - 1)

    def decode(mut self, h: Huffman) -> Int:
        var code = 0
        var first = 0
        var index = 0
        for length in range(1, MAXBITS + 1):
            code |= self.bits(1)
            if self.bad:
                return -1
            var count = h.count[length]
            if code - count < first:
                var at = index + (code - first)
                if at < 0 or at >= len(h.symbol):
                    self.bad = True         # a code the table does not have (damage)
                    return -1
                return h.symbol[at]
            index += count
            first += count
            first <<= 1
            code <<= 1
        self.bad = True
        return -1

    def stored(mut self):
        self.bitbuf = 0
        self.bitcnt = 0
        if self.pos + 4 > len(self.src):
            self.bad = True
            return
        var n = Int(self.src[self.pos]) | (Int(self.src[self.pos + 1]) << 8)
        var nn = Int(self.src[self.pos + 2]) | (Int(self.src[self.pos + 3]) << 8)
        self.pos += 4
        if n != (~nn & 0xFFFF) or self.pos + n > len(self.src) or len(self.out) + n > self.limit:
            self.bad = True
            return
        for k in range(n):
            self.out.append(self.src[self.pos + k])
        self.pos += n

    def codes(mut self, lencode: Huffman, distcode: Huffman):
        var lbase: List[Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        var lext: List[Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        var dbase: List[Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        var dext: List[Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
        while True:
            var sym = self.decode(lencode)
            if self.bad or sym < 0:
                self.bad = True
                return
            if sym < 256:
                if len(self.out) >= self.limit:
                    self.bad = True
                    return
                self.out.append(UInt8(sym))
            elif sym == 256:
                return
            else:
                sym -= 257
                if sym >= 29:
                    self.bad = True
                    return
                var length = lbase[sym] + self.bits(lext[sym])
                var ds = self.decode(distcode)
                if self.bad or ds < 0 or ds >= 30:
                    self.bad = True
                    return
                var dist = dbase[ds] + self.bits(dext[ds])
                if self.bad or dist > len(self.out) or len(self.out) + length > self.limit:
                    self.bad = True
                    return
                var at = len(self.out) - dist
                for k in range(length):
                    self.out.append(self.out[at + k])


def construct(mut h: Huffman, lengths: List[Int], start: Int, n: Int) -> Int:
    """Make the code from symbol lengths. 0: complete, > 0: incomplete, < 0: too many
    codes of a length (unusable)."""
    for k in range(MAXBITS + 1):
        h.count[k] = 0
    for s in range(n):
        h.count[lengths[start + s]] += 1
    if h.count[0] == n:
        return 0
    var left = 1
    for length in range(1, MAXBITS + 1):
        left <<= 1
        left -= h.count[length]
        if left < 0:
            return left
    var offs = List[Int](length=MAXBITS + 1, fill=0)
    for length in range(1, MAXBITS):
        offs[length + 1] = offs[length] + h.count[length]
    h.symbol = List[Int](length=n, fill=0)
    for s in range(n):
        var l = lengths[start + s]
        if l != 0:
            h.symbol[offs[l]] = s
            offs[l] += 1
    return left


def inflate_raw(data: List[UInt8], start: Int, limit: Int) -> Tuple[Bool, List[UInt8]]:
    """DEFLATE data from `start`; (ok, bytes). At most `limit` bytes come out."""
    var s = Inflater(data, start, limit)
    var order: List[Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    var last = 0
    while last == 0 and not s.bad:
        last = s.bits(1)
        var kind = s.bits(2)
        if s.bad:
            break
        if kind == 0:
            s.stored()
        elif kind == 1:
            var lengths = List[Int](length=320, fill=0)
            for k in range(144):
                lengths[k] = 8
            for k in range(144, 256):
                lengths[k] = 9
            for k in range(256, 280):
                lengths[k] = 7
            for k in range(280, 288):
                lengths[k] = 8
            for k in range(288, 318):
                lengths[k] = 5
            var lc = Huffman()
            var dc = Huffman()
            _ = construct(lc, lengths, 0, 288)
            _ = construct(dc, lengths, 288, 30)
            s.codes(lc, dc)
        elif kind == 2:
            var nlen = s.bits(5) + 257
            var ndist = s.bits(5) + 1
            var ncode = s.bits(4) + 4
            if s.bad or nlen > 286 or ndist > 30:
                s.bad = True
                break
            var lengths = List[Int](length=320, fill=0)
            for k in range(ncode):
                lengths[order[k]] = s.bits(3)
            var lencode = Huffman()
            if construct(lencode, lengths, 0, 19) != 0:
                s.bad = True
                break
            var index = 0
            var lens = List[Int](length=320, fill=0)
            while index < nlen + ndist and not s.bad:
                var sym = s.decode(lencode)
                if s.bad or sym < 0:
                    s.bad = True
                    break
                if sym < 16:
                    lens[index] = sym
                    index += 1
                else:
                    var rl = 0
                    var rep = 0
                    if sym == 16:
                        if index == 0:
                            s.bad = True
                            break
                        rl = lens[index - 1]
                        rep = 3 + s.bits(2)
                    elif sym == 17:
                        rep = 3 + s.bits(3)
                    else:
                        rep = 11 + s.bits(7)
                    if index + rep > nlen + ndist:
                        s.bad = True
                        break
                    for _ in range(rep):
                        lens[index] = rl
                        index += 1
            if s.bad:
                break
            if lens[256] == 0:
                s.bad = True
                break
            var lc = Huffman()
            var dc = Huffman()
            var e1 = construct(lc, lens, 0, nlen)
            if e1 < 0 or (e1 > 0 and nlen - lc.count[0] != 1):
                s.bad = True
                break
            var dists = List[Int](length=30, fill=0)
            for k in range(ndist):
                dists[k] = lens[nlen + k]
            var e2 = construct(dc, dists, 0, ndist)
            if e2 < 0 or (e2 > 0 and ndist - dc.count[0] != 1):
                s.bad = True
                break
            s.codes(lc, dc)
        else:
            s.bad = True
    if s.bad:
        return (False, List[UInt8]())
    var out = s.out.copy()
    return (True, out^)


def zlib_inflate(data: List[UInt8], limit: Int) -> Tuple[Bool, List[UInt8]]:
    """A zlib stream (2-byte header, DEFLATE, Adler-32 not checked); (ok, bytes)."""
    if len(data) < 2:
        return (False, List[UInt8]())
    var cmf = Int(data[0])
    var flg = Int(data[1])
    if (cmf & 15) != 8 or ((cmf << 8) | flg) % 31 != 0 or (flg & 32) != 0:
        return (False, List[UInt8]())
    return inflate_raw(data, 2, limit)
