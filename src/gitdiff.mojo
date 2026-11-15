"""The diff view's model: a unified diff of two versions of a file, and what staging,
unstaging or reverting one change (hunk) of it makes of them.

The two sides are lists of lines (no line feeds) plus whether the text ends with a line
feed. In the view's "Changes" mode the old side is git's index and the new side the
buffer (as edited); in "Staged" mode the old side is HEAD and the new side the index.
"""
from std.collections import List
from linediff import Hunk, diff_lines, line_hash
from util import decode, cp_len, slice_str

comptime DR_HEADER = 0      # @@ -a,la +b,lb @@
comptime DR_SAME = 1        # a line both sides have (context)
comptime DR_OLD = 2         # only the old side (removed)
comptime DR_NEW = 3         # only the new side (added)
comptime DR_NOTE = 4        # something said about the whole diff
comptime DR_SPLIT_CHG = 5   # side-by-side paired old/new changed row (± ... │ ...)

comptime DIFF_CONTEXT = 3


@fieldwise_init
struct DiffRow(Copyable, Movable):
    var kind: Int
    var text: String        # as shown: "@@ ...", " line", "-line", "+line"
    var hunk: Int           # the hunk the row belongs to (-1: none)
    var new_line: Int       # 0-based line of the new side it is at (-1: none)


@fieldwise_init
struct Side(Copyable, Movable):
    var lines: List[String]
    var eol: Bool           # the text ends with a line feed

    @staticmethod
    def of(text: String) -> Side:
        var lines = List[String]()
        for l in text.split("\n"):
            lines.append(String(String(l).rstrip("\r")))
        var eol = text.endswith("\n")
        if len(lines) > 0 and lines[len(lines) - 1].byte_length() == 0:
            _ = lines.pop()             # after the last line feed: not a line
        return Side(lines^, eol or len(lines) == 0)

    def text(self) -> String:
        var s = String("")
        for k in range(len(self.lines)):
            if k > 0:
                s += "\n"
            s += self.lines[k]
        if self.eol and len(self.lines) > 0:
            s += "\n"
        return s^

    def hashes(self) -> List[UInt64]:
        var out = List[UInt64](capacity=len(self.lines))
        for l in self.lines:
            out.append(line_hash(decode(l)))
        return out^


def side_hunks(old: Side, new: Side) -> List[Hunk]:
    var h = diff_lines(old.hashes(), new.hashes())
    if len(h) == 0 and old.eol != new.eol and len(old.lines) > 0 and len(new.lines) > 0:
        # only the line feed after the last line differs: that line changed
        var n = len(old.lines)
        h.append(Hunk(n - 1, 1, len(new.lines) - 1, 1))
    return h^


def unified(old: Side, new: Side, hunks: List[Hunk], context: Int = DIFF_CONTEXT) -> List[DiffRow]:
    """The rows of a unified diff (a hunk's context lines are shared by hunks that are
    close together, as in `git diff`, but each hunk keeps its own header)."""
    var rows = List[DiffRow]()
    var shown_to = 0                    # old lines up to here are on rows already
    for hi in range(len(hunks)):
        var h = hunks[hi].copy()
        var c0 = max(max(0, h.a - context), shown_to)
        var c1 = min(len(old.lines), h.a + h.la + context)
        if hi + 1 < len(hunks):
            c1 = min(c1, hunks[hi + 1].a)
        var before = h.a - c0
        var after = c1 - (h.a + h.la)
        shown_to = c1
        var ostart = c0
        var nstart = h.b - before
        var olen = before + h.la + after
        var nlen = before + h.lb + after
        rows.append(DiffRow(DR_HEADER, "@@ -" + String(ostart + 1 if olen > 0 else ostart) + "," + String(olen)
            + " +" + String(nstart + 1 if nlen > 0 else nstart) + "," + String(nlen) + " @@", hi, max(0, h.b)))
        for k in range(before):
            rows.append(DiffRow(DR_SAME, " " + old.lines[c0 + k], hi, nstart + k))
        for k in range(h.la):
            rows.append(DiffRow(DR_OLD, "-" + old.lines[h.a + k], hi, h.b))
        for k in range(h.lb):
            rows.append(DiffRow(DR_NEW, "+" + new.lines[h.b + k], hi, h.b + k))
        for k in range(after):
            rows.append(DiffRow(DR_SAME, " " + old.lines[h.a + h.la + k], hi, h.b + h.lb + k))
    return rows^


def _pad_num(n: Int) -> String:
    if n <= 0:
        return "    "
    var s = String(n)
    while s.byte_length() < 4:
        s = " " + s
    return s


def _fit_col(s: String, width: Int) -> String:
    var clean = s.replace("\t", "    ")
    var cps = decode(clean)
    var w = max(4, width)
    if len(cps) > w:
        return slice_str(cps, 0, w - 1) + "…"
    var out = clean
    var pad = w - len(cps)
    for _ in range(pad):
        out += " "
    return out


def side_by_side(old: Side, new: Side, hunks: List[Hunk], total_w: Int, context: Int = DIFF_CONTEXT) -> List[DiffRow]:
    """Build side-by-side split diff rows (`left │ right`) pairing deleted and added lines."""
    var rows = List[DiffRow]()
    var usable = max(32, total_w - 4)
    var half_w = max(14, (usable - 3) // 2)
    var text_w = max(8, half_w - 7)
    var shown_to = 0
    for hi in range(len(hunks)):
        var h = hunks[hi].copy()
        var c0 = max(max(0, h.a - context), shown_to)
        var c1 = min(len(old.lines), h.a + h.la + context)
        if hi + 1 < len(hunks):
            c1 = min(c1, hunks[hi + 1].a)
        var before = h.a - c0
        var after = c1 - (h.a + h.la)
        shown_to = c1
        var ostart = c0
        var nstart = h.b - before
        var olen = before + h.la + after
        var nlen = before + h.lb + after
        rows.append(
            DiffRow(
                DR_HEADER,
                "@@ -" + String(ostart + 1 if olen > 0 else ostart) + "," + String(olen)
                + " +" + String(nstart + 1 if nlen > 0 else nstart) + "," + String(nlen) + " @@  [split]",
                hi,
                max(0, h.b),
            )
        )
        for k in range(before):
            var ltxt = " " + _pad_num(c0 + k + 1) + "  " + _fit_col(old.lines[c0 + k], text_w)
            var rtxt = _pad_num(nstart + k + 1) + "  " + _fit_col(new.lines[nstart + k], text_w)
            rows.append(DiffRow(DR_SAME, ltxt + " │ " + rtxt, hi, nstart + k))
        var pairs = max(h.la, h.lb)
        for k in range(pairs):
            var has_l = k < h.la
            var has_r = k < h.lb
            if has_l and has_r:
                var ltxt = "±" + _pad_num(h.a + k + 1) + "- " + _fit_col(old.lines[h.a + k], text_w)
                var rtxt = _pad_num(h.b + k + 1) + "+ " + _fit_col(new.lines[h.b + k], text_w)
                rows.append(DiffRow(DR_SPLIT_CHG, ltxt + " │ " + rtxt, hi, h.b + k))
            elif has_l:
                var ltxt = "-" + _pad_num(h.a + k + 1) + "- " + _fit_col(old.lines[h.a + k], text_w)
                var rtxt = "      " + _fit_col("", text_w)
                rows.append(DiffRow(DR_OLD, ltxt + " │ " + rtxt, hi, h.b))
            else:
                var ltxt = "+     " + _fit_col("", text_w)
                var rtxt = _pad_num(h.b + k + 1) + "+ " + _fit_col(new.lines[h.b + k], text_w)
                rows.append(DiffRow(DR_NEW, ltxt + " │ " + rtxt, hi, h.b + k))
        for k in range(after):
            var ltxt = " " + _pad_num(h.a + h.la + k + 1) + "  " + _fit_col(old.lines[h.a + h.la + k], text_w)
            var rtxt = _pad_num(h.b + h.lb + k + 1) + "  " + _fit_col(new.lines[h.b + h.lb + k], text_w)
            rows.append(DiffRow(DR_SAME, ltxt + " │ " + rtxt, hi, h.b + h.lb + k))
    return rows^


def with_hunk(old: Side, new: Side, h: Hunk) -> Side:
    """The old side with this one change of the new side made (staging it)."""
    var lines = List[String]()
    for k in range(h.a):
        lines.append(old.lines[k])
    for k in range(h.b, h.b + h.lb):
        lines.append(new.lines[k])
    for k in range(h.a + h.la, len(old.lines)):
        lines.append(old.lines[k])
    var eol = new.eol if h.a + h.la >= len(old.lines) else old.eol
    return Side(lines^, eol)


def without_hunk(old: Side, new: Side, h: Hunk) -> Side:
    """The new side with this one change undone (unstaging it, or reverting it)."""
    var lines = List[String]()
    for k in range(h.b):
        lines.append(new.lines[k])
    for k in range(h.a, h.a + h.la):
        lines.append(old.lines[k])
    for k in range(h.b + h.lb, len(new.lines)):
        lines.append(new.lines[k])
    var eol = old.eol if h.b + h.lb >= len(new.lines) else new.eol
    return Side(lines^, eol or len(lines) == 0)


def with_hunk_lines(base: Side, cur: Side, h: Hunk, selected_rows: List[Int]) -> Side:
    """Apply only the selected changed lines (`0 .. h.la - 1` for removed base lines,
    `h.la .. h.la + h.lb - 1` for added cur lines) of hunk `h` onto `base`."""
    var lines = List[String]()
    for k in range(h.a):
        lines.append(base.lines[k])
    for k in range(h.la):
        if not (k in selected_rows):
            lines.append(base.lines[h.a + k])
    for k in range(h.lb):
        if (h.la + k) in selected_rows:
            lines.append(cur.lines[h.b + k])
    for k in range(h.a + h.la, len(base.lines)):
        lines.append(base.lines[k])
    var all_sel = True
    for k in range(h.la + h.lb):
        if not (k in selected_rows):
            all_sel = False
            break
    var eol = cur.eol if (all_sel and h.a + h.la >= len(base.lines)) else base.eol
    return Side(lines^, eol or len(lines) == 0)


def without_hunk_lines(base: Side, cur: Side, h: Hunk, selected_rows: List[Int]) -> Side:
    """Undo only the selected changed lines (`0 .. h.la - 1` for removed base lines,
    `h.la .. h.la + h.lb - 1` for added cur lines) of hunk `h` from `cur` toward `base`."""
    var lines = List[String]()
    for k in range(h.b):
        lines.append(cur.lines[k])
    for k in range(h.la):
        if k in selected_rows:
            lines.append(base.lines[h.a + k])
    for k in range(h.lb):
        if not ((h.la + k) in selected_rows):
            lines.append(cur.lines[h.b + k])
    for k in range(h.b + h.lb, len(cur.lines)):
        lines.append(cur.lines[k])
    var all_sel = True
    for k in range(h.la + h.lb):
        if not (k in selected_rows):
            all_sel = False
            break
    var eol = base.eol if (all_sel and h.b + h.lb >= len(cur.lines)) else cur.eol
    return Side(lines^, eol or len(lines) == 0)


def hunk_selected_rows(rows: List[DiffRow], h: Hunk, hi: Int, r1: Int, r2: Int) -> List[Int]:
    """Map diff view row range `[r1, r2]` within hunk `hi` to hunk-local changed indices
    (`0 .. h.la - 1` for old lines, `h.la .. h.la + h.lb - 1` for new lines)."""
    var out = List[Int]()
    var old_ord = 0
    var new_ord = 0
    var split_ord = 0
    for idx in range(len(rows)):
        if rows[idx].hunk != hi:
            continue
        var kd = rows[idx].kind
        var in_sel = idx >= r1 and idx <= r2
        if kd == DR_SPLIT_CHG:
            if in_sel:
                if split_ord < h.la and not (split_ord in out):
                    out.append(split_ord)
                if split_ord < h.lb and not ((h.la + split_ord) in out):
                    out.append(h.la + split_ord)
            split_ord += 1
            old_ord += 1
            new_ord += 1
        elif kd == DR_OLD:
            if in_sel and old_ord < h.la and not (old_ord in out):
                out.append(old_ord)
            old_ord += 1
            split_ord += 1
        elif kd == DR_NEW:
            if in_sel and new_ord < h.lb and not ((h.la + new_ord) in out):
                out.append(h.la + new_ord)
            new_ord += 1
            split_ord += 1
    return out^


def hunk_at_line(hunks: List[Hunk], row: Int) -> Int:
    """The hunk that touches line `row` of the new side (a removal counts for the line
    after it, or the last line): -1 if none."""
    for k in range(len(hunks)):
        var h = hunks[k].copy()
        if h.lb > 0 and row >= h.b and row < h.b + h.lb:
            return k
        if h.lb == 0 and (row == h.b or (row == h.b - 1 and k == len(hunks) - 1)):
            return k
    return -1


def stage_script(root: String, rel: String, tmp: String, remove: Bool) -> String:
    """A shell script that puts the content of file `tmp` into git's index as `rel`
    (keeping the file's mode), or with `remove` takes `rel` out of the index."""
    var q_rel = "'" + rel.replace("'", "'\\''") + "'"
    var q_tmp = "'" + tmp.replace("'", "'\\''") + "'"
    var q_root = "'" + root.replace("'", "'\\''") + "'"
    if remove:
        return "cd " + q_root + " && git rm -q --cached -- " + q_rel + "; rc=$?; rm -f " + q_tmp + "; exit $rc"
    return ("cd " + q_root + " && m=$(git ls-files -s -- " + q_rel + " | cut -d' ' -f1); [ -n \"$m\" ] || m=100644; "
        + "sha=$(git hash-object -w --path=" + q_rel + " -- " + q_tmp + ") && git update-index --add --cacheinfo \"$m,$sha," + rel.replace("\"", "\\\"").replace("$", "\\$").replace("`", "\\`") + "\"; "
        + "rc=$?; rm -f " + q_tmp + "; exit $rc")
