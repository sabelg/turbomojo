"""Rope: text stored as UTF-8 chunks in a B-tree whose nodes carry summaries.

Every node knows, for the text below it, the number of bytes, characters (codepoints),
newlines and UTF-16 code units. That makes these O(log n) regardless of file size:

    insert / delete at a character offset
    character offset  <->  (line, column)
    character offset  <->  UTF-16 offset        (what language servers speak)
    start / length / text of line N

Nodes live in an arena (parallel lists indexed by node id) so the tree needs no recursive
types. All leaves are at the same depth. Leaves hold at most MAX_LEAF bytes and are only
ever cut between characters, so each leaf is valid UTF-8 on its own. The rope always holds
valid UTF-8: callers pass codepoints, and `load_bytes` expects sanitised input."""
from std.collections import List
from util import encode_cp, decode_list

comptime MAX_LEAF = 1024      # bytes per leaf
comptime MIN_LEAF = 256       # leaves smaller than this are merged with a neighbour
comptime MAX_KIDS = 16        # children per internal node
comptime MIN_KIDS = 4


def is_char_start(b: UInt8) -> Bool:
    return (Int(b) & 0xC0) != 0x80


struct Rope(Copyable, Movable):
    var leaf: List[Bool]
    var data: List[List[UInt8]]     # leaf text
    var kids: List[List[Int]]       # children of an internal node
    var s_bytes: List[Int]
    var s_chars: List[Int]
    var s_lines: List[Int]          # number of '\n'
    var s_u16: List[Int]
    var free: List[Int]
    var root: Int

    def __init__(out self):
        self.leaf = List[Bool]()
        self.data = List[List[UInt8]]()
        self.kids = List[List[Int]]()
        self.s_bytes = List[Int]()
        self.s_chars = List[Int]()
        self.s_lines = List[Int]()
        self.s_u16 = List[Int]()
        self.free = List[Int]()
        self.root = 0
        self.root = self.new_leaf(List[UInt8]())

    # ----------------------------------------------------------------- arena
    def slot(mut self) -> Int:
        if len(self.free) > 0:
            return self.free.pop()
        self.leaf.append(True)
        self.data.append(List[UInt8]())
        self.kids.append(List[Int]())
        self.s_bytes.append(0)
        self.s_chars.append(0)
        self.s_lines.append(0)
        self.s_u16.append(0)
        return len(self.leaf) - 1

    def new_leaf(mut self, var bytes: List[UInt8]) -> Int:
        var i = self.slot()
        self.leaf[i] = True
        self.data[i] = bytes^
        self.kids[i] = List[Int]()
        self.resum(i)
        return i

    def new_node(mut self, var children: List[Int]) -> Int:
        var i = self.slot()
        self.leaf[i] = False
        self.data[i] = List[UInt8]()
        self.kids[i] = children^
        self.resum(i)
        return i

    def release(mut self, i: Int):
        self.data[i] = List[UInt8]()
        self.kids[i] = List[Int]()
        self.s_bytes[i] = 0
        self.s_chars[i] = 0
        self.s_lines[i] = 0
        self.s_u16[i] = 0
        self.free.append(i)

    def release_tree(mut self, i: Int):
        if not self.leaf[i]:
            var ks = self.kids[i].copy()
            for k in ks:
                self.release_tree(k)
        self.release(i)

    def resum(mut self, i: Int):
        """Recompute the summary of node i from its text or its children."""
        var nb = 0
        var nc = 0
        var nl = 0
        var nu = 0
        if self.leaf[i]:
            nb = len(self.data[i])
            for k in range(nb):
                var b = Int(self.data[i][k])
                if (b & 0xC0) != 0x80:
                    nc += 1
                    nu += 2 if b >= 0xF0 else 1
                    if b == 10:
                        nl += 1
        else:
            for k in self.kids[i]:
                nb += self.s_bytes[k]
                nc += self.s_chars[k]
                nl += self.s_lines[k]
                nu += self.s_u16[k]
        self.s_bytes[i] = nb
        self.s_chars[i] = nc
        self.s_lines[i] = nl
        self.s_u16[i] = nu

    # ----------------------------------------------------------------- sizes
    def len_chars(self) -> Int:
        return self.s_chars[self.root]

    def len_bytes(self) -> Int:
        return self.s_bytes[self.root]

    def len_utf16(self) -> Int:
        return self.s_u16[self.root]

    def newlines(self) -> Int:
        return self.s_lines[self.root]

    def line_count(self) -> Int:
        """Lines as an editor counts them: one more than the number of newlines."""
        return self.s_lines[self.root] + 1

    # ------------------------------------------------------------- building
    def chunks(self, bytes: List[UInt8]) -> List[List[UInt8]]:
        """Cut bytes into pieces of at most MAX_LEAF bytes, only between characters,
        of roughly equal size (so no piece is tiny)."""
        var out = List[List[UInt8]]()
        var n = len(bytes)
        if n <= MAX_LEAF:
            out.append(bytes.copy())
            return out^
        var target = MAX_LEAF * 3 // 4
        var pieces = (n + target - 1) // target
        var size = (n + pieces - 1) // pieces
        var start = 0
        while start < n:
            var end = min(n, start + size)
            # never cut inside a UTF-8 sequence: move the cut back to a character start
            while end < n and not is_char_start(bytes[end]):
                end -= 1
            if end <= start:
                end = min(n, start + size)      # cannot happen for valid UTF-8
            var piece = List[UInt8]()
            for k in range(start, end):
                piece.append(bytes[k])
            out.append(piece^)
            start = end
        return out^

    def group(mut self, var ids: List[Int]) -> Int:
        """Build internal levels over a list of same-depth nodes; returns the top node."""
        while len(ids) > MAX_KIDS:
            var n = len(ids)
            var groups = (n + MAX_KIDS - 1) // MAX_KIDS
            var size = (n + groups - 1) // groups
            var up = List[Int]()
            var i = 0
            while i < n:
                var part = List[Int]()
                for k in range(i, min(n, i + size)):
                    part.append(ids[k])
                up.append(self.new_node(part^))
                i += size
            ids = up^
        if len(ids) == 1:
            return ids[0]
        return self.new_node(ids^)

    def load_bytes(mut self, bytes: List[UInt8]):
        """Replace the whole content. `bytes` must be valid UTF-8."""
        self.leaf.clear()
        self.data.clear()
        self.kids.clear()
        self.s_bytes.clear()
        self.s_chars.clear()
        self.s_lines.clear()
        self.s_u16.clear()
        self.free.clear()
        var ids = List[Int]()
        for piece in self.chunks(bytes):
            ids.append(self.new_leaf(piece.copy()))
        self.root = self.group(ids^)

    def load_cps(mut self, cps: List[Int]):
        var bytes = List[UInt8]()
        for c in cps:
            encode_cp(c, bytes)
        self.load_bytes(bytes)

    # --------------------------------------------------------------- insert
    def byte_pos(self, node: Int, k: Int) -> Int:
        """Byte index of the k-th character of a leaf (its length if k is the end)."""
        var n = len(self.data[node])
        if k <= 0:
            return 0
        if k >= self.s_chars[node]:
            return n
        if self.s_chars[node] == n:
            return k                    # pure ASCII leaf
        var seen = 0
        for i in range(n):
            if is_char_start(self.data[node][i]):
                if seen == k:
                    return i
                seen += 1
        return n

    def insert_rec(mut self, node: Int, at: Int, bytes: List[UInt8]) -> List[Int]:
        """Insert into the subtree; returns new right siblings created by splitting."""
        var extra = List[Int]()
        if self.leaf[node]:
            var bp = self.byte_pos(node, at)
            var merged = List[UInt8]()
            for k in range(bp):
                merged.append(self.data[node][k])
            for b in bytes:
                merged.append(b)
            for k in range(bp, len(self.data[node])):
                merged.append(self.data[node][k])
            if len(merged) <= MAX_LEAF:
                self.data[node] = merged^
                self.resum(node)
                return extra^
            var pieces = self.chunks(merged)
            self.data[node] = pieces[0].copy()
            self.resum(node)
            for k in range(1, len(pieces)):
                extra.append(self.new_leaf(pieces[k].copy()))
            return extra^
        # internal node: find the child that contains the position
        var ks = self.kids[node].copy()
        var acc = 0
        var which = len(ks) - 1
        for k in range(len(ks)):
            var c = self.s_chars[ks[k]]
            if at <= acc + c:
                which = k
                break
            acc += c
        var born = self.insert_rec(ks[which], at - acc, bytes)
        for k in range(len(born)):
            ks.insert(which + 1 + k, born[k])
        if len(ks) <= MAX_KIDS:
            self.kids[node] = ks^
            self.resum(node)
            return extra^
        # too many children: keep the first group here, hand the rest to new siblings
        var n = len(ks)
        var groups = (n + MAX_KIDS - 1) // MAX_KIDS
        var size = (n + groups - 1) // groups
        var first = List[Int]()
        for k in range(size):
            first.append(ks[k])
        self.kids[node] = first^
        self.resum(node)
        var i = size
        while i < n:
            var part = List[Int]()
            for k in range(i, min(n, i + size)):
                part.append(ks[k])
            extra.append(self.new_node(part^))
            i += size
        return extra^

    def insert_bytes(mut self, at: Int, bytes: List[UInt8]):
        """Insert valid UTF-8 at a character offset (clamped to the text)."""
        if len(bytes) == 0:
            return
        var pos = max(0, min(at, self.len_chars()))
        var born = self.insert_rec(self.root, pos, bytes)
        if len(born) > 0:
            var top = List[Int]()
            top.append(self.root)
            for b in born:
                top.append(b)
            self.root = self.group(top^)

    def insert(mut self, at: Int, cps: List[Int]):
        var bytes = List[UInt8]()
        for c in cps:
            encode_cp(c, bytes)
        self.insert_bytes(at, bytes)

    # --------------------------------------------------------------- delete
    def delete_rec(mut self, node: Int, a: Int, b: Int):
        """Remove characters [a, b) of the subtree (offsets relative to the node)."""
        if self.leaf[node]:
            var ba = self.byte_pos(node, a)
            var bb = self.byte_pos(node, b)
            var kept = List[UInt8]()
            for k in range(ba):
                kept.append(self.data[node][k])
            for k in range(bb, len(self.data[node])):
                kept.append(self.data[node][k])
            self.data[node] = kept^
            self.resum(node)
            return
        var ks = self.kids[node].copy()
        var keep = List[Int]()
        var acc = 0
        for k in ks:
            var c = self.s_chars[k]
            var lo = acc
            var hi = acc + c
            acc = hi
            if hi <= a or lo >= b:
                keep.append(k)
            elif a <= lo and hi <= b:
                self.release_tree(k)
            else:
                self.delete_rec(k, max(a, lo) - lo, min(b, hi) - lo)
                if self.s_bytes[k] == 0:
                    self.release_tree(k)
                else:
                    keep.append(k)
        # merge small neighbours so that the tree does not fill up with crumbs
        var out = List[Int]()
        for k in keep:
            if len(out) > 0:
                var p = out[len(out) - 1]
                if self.leaf[k]:
                    if (self.s_bytes[p] < MIN_LEAF or self.s_bytes[k] < MIN_LEAF) and self.s_bytes[p] + self.s_bytes[k] <= MAX_LEAF:
                        for bt in self.data[k].copy():
                            self.data[p].append(bt)
                        self.resum(p)
                        self.release(k)
                        continue
                else:
                    if (len(self.kids[p]) < MIN_KIDS or len(self.kids[k]) < MIN_KIDS) and len(self.kids[p]) + len(self.kids[k]) <= MAX_KIDS:
                        for kk in self.kids[k].copy():
                            self.kids[p].append(kk)
                        self.resum(p)
                        self.release(k)
                        continue
            out.append(k)
        self.kids[node] = out^
        self.resum(node)

    def delete(mut self, a: Int, b: Int):
        """Remove the characters in [a, b) (clamped)."""
        var lo = max(0, a)
        var hi = min(b, self.len_chars())
        if lo >= hi:
            return
        self.delete_rec(self.root, lo, hi)
        # shrink the tree from the top while the root has a single child
        while not self.leaf[self.root] and len(self.kids[self.root]) == 1:
            var only = self.kids[self.root][0]
            self.release(self.root)
            self.root = only
        if not self.leaf[self.root] and len(self.kids[self.root]) == 0:
            self.release(self.root)
            self.root = self.new_leaf(List[UInt8]())

    def clear(mut self):
        self.load_bytes(List[UInt8]())

    # ---------------------------------------------------------------- reading
    def collect(self, node: Int, a: Int, b: Int, mut out: List[UInt8]):
        """Append the bytes of characters [a, b) of the subtree."""
        if a >= b:
            return
        if self.leaf[node]:
            var ba = self.byte_pos(node, a)
            var bb = self.byte_pos(node, b)
            for k in range(ba, bb):
                out.append(self.data[node][k])
            return
        var acc = 0
        for k in self.kids[node]:
            var c = self.s_chars[k]
            var lo = acc
            var hi = acc + c
            acc = hi
            if hi <= a:
                continue
            if lo >= b:
                break
            self.collect(k, max(a, lo) - lo, min(b, hi) - lo, out)

    def slice_bytes(self, a: Int, b: Int) -> List[UInt8]:
        var out = List[UInt8]()
        self.collect(self.root, max(0, a), min(b, self.len_chars()), out)
        return out^

    def slice(self, a: Int, b: Int) -> List[Int]:
        """Codepoints of characters [a, b)."""
        return decode_list(self.slice_bytes(a, b))

    def to_bytes(self) -> List[UInt8]:
        return self.slice_bytes(0, self.len_chars())

    def to_cps(self) -> List[Int]:
        return self.slice(0, self.len_chars())

    def char_at(self, i: Int) -> Int:
        """Codepoint at character offset i (-1 if out of range)."""
        if i < 0 or i >= self.len_chars():
            return -1
        var cps = self.slice(i, i + 1)
        return cps[0] if len(cps) > 0 else -1

    # ------------------------------------------------------------------ lines
    def line_start(self, row: Int) -> Int:
        """Character offset where line `row` begins (the text length if past the end)."""
        if row <= 0:
            return 0
        if row > self.s_lines[self.root]:
            return self.len_chars()
        var node = self.root
        var need = row              # newlines still to pass
        var acc = 0                 # characters before `node`
        while not self.leaf[node]:
            var next = -1
            for k in self.kids[node]:
                if self.s_lines[k] >= need:
                    next = k
                    break
                need -= self.s_lines[k]
                acc += self.s_chars[k]
            if next < 0:
                return self.len_chars()
            node = next
        var chars = 0
        for i in range(len(self.data[node])):
            var b = self.data[node][i]
            if is_char_start(b):
                chars += 1
                if b == 10:
                    need -= 1
                    if need == 0:
                        return acc + chars
        return self.len_chars()

    def line_end(self, row: Int) -> Int:
        """Character offset of the newline ending line `row` (or of the end of text)."""
        if row >= self.s_lines[self.root]:
            return self.len_chars()
        return self.line_start(row + 1) - 1

    def line_len(self, row: Int) -> Int:
        """Characters in line `row`, not counting its newline."""
        if row < 0 or row > self.s_lines[self.root]:
            return 0
        return self.line_end(row) - self.line_start(row)

    def line(self, row: Int) -> List[Int]:
        """Codepoints of line `row` without its newline."""
        if row < 0 or row > self.s_lines[self.root]:
            return List[Int]()
        return self.slice(self.line_start(row), self.line_end(row))

    def line_of(self, offset: Int) -> Int:
        """Row that contains character offset `offset` (number of newlines before it)."""
        var off = max(0, min(offset, self.len_chars()))
        var node = self.root
        var rows = 0
        while not self.leaf[node]:
            # the offset always falls inside some child because summaries add up
            var next = self.kids[node][len(self.kids[node]) - 1]
            for k in self.kids[node]:
                if off <= self.s_chars[k]:
                    next = k
                    break
                off -= self.s_chars[k]
                rows += self.s_lines[k]
            node = next
        var chars = 0
        for i in range(len(self.data[node])):
            if chars >= off:
                break
            var b = self.data[node][i]
            if is_char_start(b):
                chars += 1
                if b == 10:
                    rows += 1
        return rows

    def offset(self, row: Int, col: Int) -> Int:
        """Character offset of (row, col), with both clamped into the text."""
        var r = max(0, min(row, self.s_lines[self.root]))
        var start = self.line_start(r)
        return start + max(0, min(col, self.line_end(r) - start))

    # ------------------------------------------------------------------ UTF-16
    def to_utf16(self, offset: Int) -> Int:
        """UTF-16 code units before character offset `offset`."""
        var off = max(0, min(offset, self.len_chars()))
        var node = self.root
        var units = 0
        while not self.leaf[node]:
            var next = self.kids[node][len(self.kids[node]) - 1]
            for k in self.kids[node]:
                if off <= self.s_chars[k]:
                    next = k
                    break
                off -= self.s_chars[k]
                units += self.s_u16[k]
            node = next
        var chars = 0
        for i in range(len(self.data[node])):
            if chars >= off:
                break
            var b = Int(self.data[node][i])
            if (b & 0xC0) != 0x80:
                chars += 1
                units += 2 if b >= 0xF0 else 1
        return units

    def from_utf16(self, units: Int) -> Int:
        """Character offset for a UTF-16 offset. An offset in the middle of a surrogate
        pair maps to the character that contains it."""
        var u = max(0, min(units, self.len_utf16()))
        var node = self.root
        var chars = 0
        while not self.leaf[node]:
            var next = self.kids[node][len(self.kids[node]) - 1]
            for k in self.kids[node]:
                if u <= self.s_u16[k]:
                    next = k
                    break
                u -= self.s_u16[k]
                chars += self.s_chars[k]
            node = next
        var seen = 0
        for i in range(len(self.data[node])):
            var b = Int(self.data[node][i])
            if (b & 0xC0) != 0x80:
                if seen >= u:
                    break
                var w = 2 if b >= 0xF0 else 1
                if seen + w > u:
                    break               # inside this character
                seen += w
                chars += 1
        return chars

    # -------------------------------------------------------------- diagnostics
    def depth(self) -> Int:
        var d = 1
        var node = self.root
        while not self.leaf[node]:
            node = self.kids[node][0]
            d += 1
        return d

    def leaf_count(self) -> Int:
        return self.count_leaves(self.root)

    def count_leaves(self, node: Int) -> Int:
        if self.leaf[node]:
            return 1
        var n = 0
        for k in self.kids[node]:
            n += self.count_leaves(k)
        return n

    def check_node(self, node: Int, level: Int, leaf_level: Int) -> String:
        if self.leaf[node]:
            if level != leaf_level:
                return "leaf at depth " + String(level) + ", expected " + String(leaf_level)
            var n = len(self.data[node])
            if n > MAX_LEAF:
                return "leaf larger than MAX_LEAF"
            if n == 0 and node != self.root:
                return "empty leaf below the root"
            if n > 0 and not is_char_start(self.data[node][0]):
                return "leaf starts inside a character"
            var nc = 0
            var nl = 0
            var nu = 0
            for i in range(n):
                var b = Int(self.data[node][i])
                if (b & 0xC0) != 0x80:
                    nc += 1
                    nu += 2 if b >= 0xF0 else 1
                    if b == 10:
                        nl += 1
            if self.s_bytes[node] != n or self.s_chars[node] != nc or self.s_lines[node] != nl or self.s_u16[node] != nu:
                return "wrong leaf summary"
            return ""
        var ks = self.kids[node].copy()
        if len(ks) == 0:
            return "internal node without children"
        if len(ks) > MAX_KIDS:
            return "too many children"
        var nb = 0
        var nc = 0
        var nl = 0
        var nu = 0
        for k in ks:
            var err = self.check_node(k, level + 1, leaf_level)
            if err.byte_length() > 0:
                return err
            nb += self.s_bytes[k]
            nc += self.s_chars[k]
            nl += self.s_lines[k]
            nu += self.s_u16[k]
        if self.s_bytes[node] != nb or self.s_chars[node] != nc or self.s_lines[node] != nl or self.s_u16[node] != nu:
            return "wrong internal summary"
        return ""

    def check(self) -> String:
        """'' if the structure is sound, otherwise what is wrong."""
        if not self.leaf[self.root] and len(self.kids[self.root]) == 1:
            return "root has a single child"
        return self.check_node(self.root, 1, self.depth())
