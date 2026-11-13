"""The tiled layout: a tree of splits whose leaves are tab groups. A group holds the
ids of its windows (one of them showing); a split puts two subtrees side by side or one
above the other. This module knows nothing about windows beyond their ids."""
from std.collections import List

comptime L_GROUP = 0
comptime L_ROW = 1          # two children side by side
comptime L_COL = 2          # two children, one above the other
comptime PANE_MIN_W = 16
comptime PANE_MIN_H = 5
comptime RATIO_MIN = 150    # per mille of the split that the first child gets
comptime RATIO_MAX = 850


struct Layout(Copyable, Movable):
    var kind: List[Int]
    var parent: List[Int]       # -1 for the root
    var first: List[Int]        # children of a split
    var second: List[Int]
    var ratio: List[Int]
    var tabs: List[List[Int]]   # window ids of a group, in tab order
    var active: List[Int]       # which tab of a group shows
    var alive: List[Bool]
    var root: Int
    var cur: Int                # the group that has the keyboard
    var gx: List[Int]           # where each node was placed last
    var gy: List[Int]
    var gw: List[Int]
    var gh: List[Int]

    def __init__(out self):
        self.kind = List[Int]()
        self.parent = List[Int]()
        self.first = List[Int]()
        self.second = List[Int]()
        self.ratio = List[Int]()
        self.tabs = List[List[Int]]()
        self.active = List[Int]()
        self.alive = List[Bool]()
        self.gx = List[Int]()
        self.gy = List[Int]()
        self.gw = List[Int]()
        self.gh = List[Int]()
        self.root = 0
        self.cur = 0
        self.root = self.new_node(L_GROUP, -1)

    def new_node(mut self, kind: Int, parent: Int) -> Int:
        self.kind.append(kind)
        self.parent.append(parent)
        self.first.append(-1)
        self.second.append(-1)
        self.ratio.append(500)
        self.tabs.append(List[Int]())
        self.active.append(0)
        self.alive.append(True)
        self.gx.append(0)
        self.gy.append(0)
        self.gw.append(0)
        self.gh.append(0)
        return len(self.kind) - 1

    # ------------------------------------------------------------- queries
    def groups(self) -> List[Int]:
        """The groups in reading order: left before right, upper before lower."""
        var out = List[Int]()
        var stack = List[Int]()
        stack.append(self.root)
        while len(stack) > 0:
            var n = stack.pop()
            if self.kind[n] == L_GROUP:
                out.append(n)
            else:
                stack.append(self.second[n])
                stack.append(self.first[n])
        return out^

    def group_of(self, id: Int) -> Int:
        for g in self.groups():
            if id in self.tabs[g]:
                return g
        return -1

    def ids(self) -> List[Int]:
        var out = List[Int]()
        for g in self.groups():
            for id in self.tabs[g]:
                out.append(id)
        return out^

    def shown(self, g: Int) -> Int:
        """The id of the window a group shows (-1 if the group is empty)."""
        if len(self.tabs[g]) == 0:
            return -1
        return self.tabs[g][max(0, min(self.active[g], len(self.tabs[g]) - 1))]

    def first_group_under(self, n: Int) -> Int:
        var k = n
        while self.kind[k] != L_GROUP:
            k = self.first[k]
        return k

    # ------------------------------------------------------------- changes
    def add(mut self, id: Int):
        """A new window: a tab of the current group, shown at once."""
        if self.group_of(id) >= 0:
            return
        var at = min(self.active[self.cur] + 1, len(self.tabs[self.cur]))
        self.tabs[self.cur].insert(at, id)
        self.active[self.cur] = at

    def collapse(mut self, g: Int):
        """Take an empty group out of the tree: its sibling takes the place of the split."""
        var p = self.parent[g]
        if p < 0:
            return                          # the last group stays, empty
        var sib = self.second[p] if self.first[p] == g else self.first[p]
        var gp = self.parent[p]
        self.parent[sib] = gp
        if gp < 0:
            self.root = sib
        elif self.first[gp] == p:
            self.first[gp] = sib
        else:
            self.second[gp] = sib
        self.alive[g] = False
        self.alive[p] = False
        if self.cur == g:
            self.cur = self.first_group_under(sib)

    def remove(mut self, id: Int):
        var g = self.group_of(id)
        if g < 0:
            return
        var at = 0
        for k in range(len(self.tabs[g])):
            if self.tabs[g][k] == id:
                at = k
        _ = self.tabs[g].pop(at)
        if self.active[g] > at or self.active[g] >= len(self.tabs[g]):
            self.active[g] = max(0, self.active[g] - 1)
        if len(self.tabs[g]) == 0:
            self.collapse(g)

    def activate(mut self, id: Int):
        """Make a window the one its group shows, and that group the current one."""
        var g = self.group_of(id)
        if g < 0:
            return
        self.cur = g
        for k in range(len(self.tabs[g])):
            if self.tabs[g][k] == id:
                self.active[g] = k

    def split(mut self, side_by_side: Bool) -> String:
        """Split the current group: the tab it shows moves into a new group to the right
        (or below), which becomes the current one. Returns '' or why it cannot be done."""
        var g = self.cur
        if len(self.tabs[g]) < 2:
            return "Open a second file in this pane first: a split shows two files"
        if side_by_side and self.gw[g] > 0 and self.gw[g] < 2 * PANE_MIN_W:
            return "This pane is too narrow to split"
        if not side_by_side and self.gh[g] > 0 and self.gh[g] < 2 * PANE_MIN_H:
            return "This pane is too low to split"
        var id = self.shown(g)
        var at = self.active[g]
        _ = self.tabs[g].pop(at)
        self.active[g] = max(0, at - 1)
        var p = self.parent[g]
        var s = self.new_node(L_ROW if side_by_side else L_COL, p)
        var n = self.new_node(L_GROUP, s)
        self.tabs[n].append(id)
        self.first[s] = g
        self.second[s] = n
        self.parent[g] = s
        if p < 0:
            self.root = s
        elif self.first[p] == g:
            self.first[p] = s
        else:
            self.second[p] = s
        self.cur = n
        return ""

    def next_group(mut self, delta: Int):
        var gs = self.groups()
        for k in range(len(gs)):
            if gs[k] == self.cur:
                self.cur = gs[(k + delta + len(gs)) % len(gs)]
                return

    def next_tab(mut self, delta: Int):
        var n = len(self.tabs[self.cur])
        if n > 0:
            self.active[self.cur] = (self.active[self.cur] + delta + n) % n

    def move_tab(mut self) -> Bool:
        """Move the tab the current group shows to the next group, and follow it."""
        var gs = self.groups()
        if len(gs) < 2 or len(self.tabs[self.cur]) == 0:
            return False
        var id = self.shown(self.cur)
        var k = 0
        for q in range(len(gs)):
            if gs[q] == self.cur:
                k = q
        var to = gs[(k + 1) % len(gs)]
        self.remove(id)                     # may collapse the group it leaves
        self.cur = to
        self.add(id)
        return True

    def resize(mut self, delta: Int) -> Bool:
        """Give the current group `delta` per mille more (or less) of the split it is in."""
        var p = self.parent[self.cur]
        if p < 0:
            return False
        var r = self.ratio[p] + (delta if self.first[p] == self.cur else -delta)
        r = max(RATIO_MIN, min(RATIO_MAX, r))
        if r == self.ratio[p]:
            return False
        self.ratio[p] = r
        return True

    # ------------------------------------------------------------ geometry
    def half_ratios(self, g: Int) -> List[Int]:
        """The split ratios with group `g` given at least half the width and half the
        height of the whole (zoom's middle step): on the path from `g` to the root, `g`'s
        side of each split grows to t, where t^k = 1/2 for the k splits of that
        direction on the path (within RATIO_MIN..RATIO_MAX). The saved ratios stay."""
        var r = self.ratio.copy()
        if g < 0 or g >= len(self.kind):
            return r^
        var rows = 0
        var cols = 0
        var n = g
        while self.parent[n] >= 0:
            if self.kind[self.parent[n]] == L_ROW:
                rows += 1
            else:
                cols += 1
            n = self.parent[n]
        n = g
        while self.parent[n] >= 0:
            var p = self.parent[n]
            var k = rows if self.kind[p] == L_ROW else cols
            var t = 500
            if k == 2:
                t = 708
            elif k == 3:
                t = 794
            elif k >= 4:
                t = RATIO_MAX
            var share = r[p] if self.first[p] == n else 1000 - r[p]
            if share < t:
                share = min(t, RATIO_MAX)
                r[p] = share if self.first[p] == n else 1000 - share
            n = p
        return r^

    def place(mut self, x: Int, y: Int, w: Int, h: Int, boost: Int = -1):
        """Give every node its rectangle inside (x, y, w, h); with `boost`, as if that
        group had been given half the room (`half_ratios`)."""
        var ratio = self.half_ratios(boost) if boost >= 0 else self.ratio.copy()
        var stack = List[Int]()
        self.gx[self.root] = x
        self.gy[self.root] = y
        self.gw[self.root] = w
        self.gh[self.root] = h
        stack.append(self.root)
        while len(stack) > 0:
            var n = stack.pop()
            if self.kind[n] == L_GROUP:
                continue
            var a = self.first[n]
            var b = self.second[n]
            if self.kind[n] == L_ROW:
                var wa = (self.gw[n] * ratio[n]) // 1000
                wa = max(min(PANE_MIN_W, self.gw[n] // 2), min(wa, self.gw[n] - min(PANE_MIN_W, self.gw[n] // 2)))
                self.gx[a] = self.gx[n]
                self.gw[a] = wa
                self.gx[b] = self.gx[n] + wa
                self.gw[b] = self.gw[n] - wa
                self.gy[a] = self.gy[n]
                self.gy[b] = self.gy[n]
                self.gh[a] = self.gh[n]
                self.gh[b] = self.gh[n]
            else:
                var ha = (self.gh[n] * ratio[n]) // 1000
                ha = max(min(PANE_MIN_H, self.gh[n] // 2), min(ha, self.gh[n] - min(PANE_MIN_H, self.gh[n] // 2)))
                self.gy[a] = self.gy[n]
                self.gh[a] = ha
                self.gy[b] = self.gy[n] + ha
                self.gh[b] = self.gh[n] - ha
                self.gx[a] = self.gx[n]
                self.gx[b] = self.gx[n]
                self.gw[a] = self.gw[n]
                self.gw[b] = self.gw[n]
            stack.append(a)
            stack.append(b)

    def describe(self) -> String:
        """The tree as text, for tests and sessions: a group is [ids] with * on the tab
        it shows and ! on the current group; splits are (a | b) and (a / b)."""
        return self.describe_node(self.root)

    def describe_node(self, n: Int) -> String:
        if self.kind[n] == L_GROUP:
            var s = String("[")
            for k in range(len(self.tabs[n])):
                if k > 0:
                    s += " "
                s += String(self.tabs[n][k]) + ("*" if k == self.active[n] else "")
            return s + "]" + ("!" if n == self.cur else "")
        return "(" + self.describe_node(self.first[n]) + (" | " if self.kind[n] == L_ROW else " / ") + self.describe_node(self.second[n]) + ")"

    # ------------------------------------------------------- as text
    def encode(self) -> String:
        """The tree as words, for a session file: a group is "G <count> <active>
        <ids...>" with "!" in front if it is the current one, a split "R <ratio>" or
        "C <ratio>" followed by its two children."""
        return self.encode_node(self.root)

    def encode_node(self, n: Int) -> String:
        if self.kind[n] == L_GROUP:
            var s = ("!G " if n == self.cur else "G ") + String(len(self.tabs[n])) + " " + String(self.active[n])
            for id in self.tabs[n]:
                s += " " + String(id)
            return s
        return ("R " if self.kind[n] == L_ROW else "C ") + String(self.ratio[n]) + " " + self.encode_node(self.first[n]) + " " + self.encode_node(self.second[n])


def layout_number(word: String) -> Int:
    """A non-negative number, or -1 if the word is not one."""
    var n = 0
    var any = False
    for c in word.as_bytes():
        var d = Int(c) - 48
        if d < 0 or d > 9:
            return -1
        n = min(n * 10 + d, 1000000000)
        any = True
    return n if any else -1


def decode_node(mut l: Layout, words: List[String], mut at: Int, parent: Int, mut seen: List[Int]) -> Int:
    """Build the node that starts at words[at]; returns its index, -1 if the text is
    not a tree. `at` moves past what was read."""
    if at >= len(words):
        return -1
    var w = words[at]
    at += 1
    if w == "G" or w == "!G":
        if at + 1 >= len(words):
            return -1
        var count = layout_number(words[at])
        var active = layout_number(words[at + 1])
        at += 2
        if count < 0 or active < 0 or at + count > len(words):
            return -1
        var g = l.new_node(L_GROUP, parent)
        for _ in range(count):
            var id = layout_number(words[at])
            at += 1
            if id < 0 or id in seen:
                return -1                   # a window can be in one place only
            seen.append(id)
            l.tabs[g].append(id)
        l.active[g] = min(active, max(0, count - 1))
        if w == "!G":
            l.cur = g
        return g
    if w == "R" or w == "C":
        if at >= len(words):
            return -1
        var ratio = layout_number(words[at])
        at += 1
        if ratio < 0:
            return -1
        var s = l.new_node(L_ROW if w == "R" else L_COL, parent)
        l.ratio[s] = max(RATIO_MIN, min(RATIO_MAX, ratio))
        var a = decode_node(l, words, at, s, seen)
        if a < 0:
            return -1
        var b = decode_node(l, words, at, s, seen)
        if b < 0:
            return -1
        l.first[s] = a
        l.second[s] = b
        return s
    return -1


def layout_decode(text: String) -> Layout:
    """The tree encode() wrote. Anything that is not a whole, well-formed tree gives a
    fresh layout with one empty group."""
    var words = List[String]()
    for w in text.split(" "):
        if w.byte_length() > 0:
            words.append(String(w))
    var l = Layout()
    # the nodes are built after the initial root; if all goes well the root is replaced
    var seen = List[Int]()
    var at = 0
    l.cur = -1
    var root = decode_node(l, words, at, -1, seen)
    if root < 0 or at != len(words):
        return Layout()
    l.alive[l.root] = False
    l.root = root
    if l.cur < 0 or l.kind[l.cur] != L_GROUP:
        l.cur = l.first_group_under(root)
    # groups that came out empty would never be filled: take them out
    for g in l.groups():
        if len(l.tabs[g]) == 0 and l.parent[g] >= 0:
            l.collapse(g)
    return l^
