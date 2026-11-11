"""Line diff: which lines of an old text became which lines of a new one.

Lines are compared by a 64-bit hash (`line_hash`), so callers hash once and diff the
hashes. The algorithm is Myers' O(ND) difference with the common start and end taken off
first (an edit in a large file then costs only its own size). Past `max_d` differences
the middle is reported as one changed block instead of searching further.
"""
from std.collections import List


@fieldwise_init
struct Hunk(Copyable, Movable, Equatable):
    """Old lines [a, a + la) were replaced by new lines [b, b + lb) (0-based). la = 0:
    lines were inserted before old line a; lb = 0: lines were removed before new line b."""
    var a: Int
    var la: Int
    var b: Int
    var lb: Int

    def __eq__(self, o: Self) -> Bool:
        return self.a == o.a and self.la == o.la and self.b == o.b and self.lb == o.lb

    def __ne__(self, o: Self) -> Bool:
        return not self == o


def line_hash(line: List[Int]) -> UInt64:
    """FNV-1a over the code points; a carriage return at the end is not part of it."""
    var n = len(line)
    if n > 0 and line[n - 1] == 13:
        n -= 1
    var h: UInt64 = 0xCBF29CE484222325
    for k in range(n):
        h = (h ^ UInt64(line[k])) * 0x100000001B3
    return h


def text_hashes(text: List[Int]) -> List[UInt64]:
    """The hashes of the lines of `text` (split at line feeds; a final line feed does
    not start another line, as in a file)."""
    var out = List[UInt64]()
    var line = List[Int]()
    for c in text:
        if c == 10:
            out.append(line_hash(line))
            line.clear()
        else:
            line.append(c)
    if len(line) > 0:
        out.append(line_hash(line))
    return out^


def diff_lines(old: List[UInt64], new: List[UInt64], max_d: Int = 1000) -> List[Hunk]:
    """The changes from `old` to `new`, in order."""
    var n = len(old)
    var m = len(new)
    var pre = 0
    while pre < n and pre < m and old[pre] == new[pre]:
        pre += 1
    var suf = 0
    while suf < n - pre and suf < m - pre and old[n - 1 - suf] == new[m - 1 - suf]:
        suf += 1
    var out = List[Hunk]()
    var a0 = pre
    var a1 = n - suf
    var b0 = pre
    var b1 = m - suf
    if a0 == a1 and b0 == b1:
        return out^
    if a0 == a1 or b0 == b1:
        out.append(Hunk(a0, a1 - a0, b0, b1 - b0))
        return out^
    # Myers on old[a0:a1] against new[b0:b1]; v[k] = furthest x on diagonal k
    var N = a1 - a0
    var M = b1 - b0
    var limit = min(N + M, max_d)
    var off = limit + 1
    var v = List[Int](length=2 * limit + 3, fill=0)
    var trace = List[List[Int]]()
    var found = -1
    for d in range(limit + 1):
        # what v was before step d, kept for walking back
        var keep = List[Int](length=2 * d + 1, fill=0)
        for k in range(-d, d + 1):
            keep[k + d] = v[k + off]
        trace.append(keep^)
        for k in range(-d, d + 1, 2):
            var x: Int
            if k == -d or (k != d and v[k - 1 + off] < v[k + 1 + off]):
                x = v[k + 1 + off]          # down: a line of new inserted
            else:
                x = v[k - 1 + off] + 1      # right: a line of old removed
            var y = x - k
            while x < N and y < M and old[a0 + x] == new[b0 + y]:
                x += 1
                y += 1
            v[k + off] = x
            if x >= N and y >= M:
                found = d
                break
        if found >= 0:
            break
    if found < 0:
        # too different to be worth working out: one block
        out.append(Hunk(a0, N, b0, M))
        return out^
    # walk back from (N, M), collecting the matching runs (snakes)
    var pairs_x = List[Int]()      # start of each matching run, from the end backwards
    var pairs_y = List[Int]()
    var lens = List[Int]()
    var x = N
    var y = M
    var d = found
    while d > 0:
        var k = x - y
        ref prev = trace[d]         # v before step d (indices -(d-1)..(d-1) are valid)
        var down: Bool
        if k == -d:
            down = True
        elif k == d:
            down = False
        else:
            down = prev[k - 1 + d] < prev[k + 1 + d]
        var pk = k + 1 if down else k - 1
        var px = prev[pk + d]
        var py = px - pk
        # where step d's single move ended
        var sx = px if down else px + 1
        var sy = sx - k
        if x > sx:
            pairs_x.append(sx)
            pairs_y.append(sy)
            lens.append(x - sx)
        x = px
        y = py
        d -= 1
    if x > 0:
        pairs_x.append(0)
        pairs_y.append(0)
        lens.append(x)
    # forwards: the gaps between matching runs are the hunks
    var cx = 0
    var cy = 0
    var j = len(lens) - 1
    while j >= -1:
        var mx = N
        var my = M
        var ml = 0
        if j >= 0:
            mx = pairs_x[j]
            my = pairs_y[j]
            ml = lens[j]
        if mx > cx or my > cy:
            out.append(Hunk(a0 + cx, mx - cx, b0 + cy, my - cy))
        cx = mx + ml
        cy = my + ml
        j -= 1
    return out^


comptime LM_NONE = 0
comptime LM_ADDED = 1
comptime LM_CHANGED = 2
comptime LM_DELETED_ABOVE = 3   # lines were removed just above this line
comptime LM_DELETED_BELOW = 4   # lines were removed after this, the last line


def line_marks(hunks: List[Hunk], new_count: Int) -> List[UInt8]:
    """A mark per line of the new text, for a gutter."""
    var marks = List[UInt8](length=new_count, fill=UInt8(LM_NONE))
    for h in hunks:
        if h.lb > 0:
            var mark = LM_ADDED if h.la == 0 else LM_CHANGED
            for r in range(h.b, min(h.b + h.lb, new_count)):
                marks[r] = UInt8(mark)
        elif new_count > 0:
            if h.b < new_count:
                if marks[h.b] == LM_NONE:
                    marks[h.b] = UInt8(LM_DELETED_ABOVE)
            elif marks[new_count - 1] == LM_NONE:
                marks[new_count - 1] = UInt8(LM_DELETED_BELOW)
    return marks^
