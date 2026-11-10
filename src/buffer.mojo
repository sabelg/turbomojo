"""Text buffer: a rope of UTF-8 text addressed by (row, column in codepoints), with
grouped undo/redo and the per-file settings (line endings, indentation, final newline).

The text itself lives in `Rope` (src/rope.mojo), so loading, editing and line lookups stay
fast on very large files. Line endings are normalised to "\n" in memory; `crlf` remembers
that the file used CR LF and `to_bytes` writes it back that way."""
from std.collections import List
from util import encode_cp
from rope import Rope

comptime UNDO_INSERT = 1
comptime UNDO_DELETE = 2
comptime TAB_WIDTH = 4   # default; each buffer carries its own tab_width / indent_size


@fieldwise_init
struct UndoRec(Copyable, Movable):
    var kind: Int
    var r: Int
    var c: Int
    var text: List[Int]
    var cr: Int
    var cc: Int
    var group: Int


@fieldwise_init
struct Pos(Copyable, Movable):
    var r: Int
    var c: Int


struct TextBuffer(Copyable, Movable):
    var rope: Rope
    var undos: List[UndoRec]
    var redos: List[UndoRec]
    var modified: Bool
    var version: Int
    var crlf: Bool
    var use_tabs: Bool
    var eol_at_eof: Bool
    var tab_width: Int      # columns a tab character advances to (display)
    var indent_size: Int    # spaces per indentation level when indenting with spaces
    var trim_on_save: Bool  # strip trailing whitespace when saving (.editorconfig)

    def __init__(out self):
        self.rope = Rope()
        self.undos = List[UndoRec]()
        self.redos = List[UndoRec]()
        self.modified = False
        self.version = 0
        self.crlf = False
        self.use_tabs = False
        self.eol_at_eof = True
        self.tab_width = TAB_WIDTH
        self.indent_size = TAB_WIDTH
        self.trim_on_save = False

    def load(mut self, cps: List[Int]):
        """Replace the content. Tabs are kept; "\r\n" becomes "\n" in memory and the file
        is remembered as CRLF; a trailing newline shows as a final empty line."""
        var clean = List[Int]()
        var crlf_n = 0
        var lf_n = 0
        var tabs = 0
        var spaces = 0
        var at_line_start = True
        var n = len(cps)
        for i in range(n):
            var c = cps[i]
            if c == 13 and i + 1 < n and cps[i + 1] == 10:
                crlf_n += 1
                continue                # dropped: the following "\n" ends the line
            if c == 10:
                if not (i > 0 and cps[i - 1] == 13):
                    lf_n += 1
                clean.append(10)
                at_line_start = True
                continue
            if at_line_start:
                if c == 9:
                    tabs += 1
                elif c == 32:
                    spaces += 1
                at_line_start = False
            clean.append(c)
        self.eol_at_eof = len(clean) == 0 or clean[len(clean) - 1] == 10
        self.crlf = crlf_n > lf_n
        self.use_tabs = tabs > spaces
        self.rope.load_cps(clean)
        self.undos.clear()
        self.redos.clear()
        self.modified = False
        self.version += 1

    def all_text(self) -> List[Int]:
        """The whole text as codepoints, lines separated by "\n"."""
        return self.rope.to_cps()

    def to_bytes(self) -> List[UInt8]:
        """The bytes to write to disk: the file's line endings, and a final newline when
        the buffer's policy asks for one and the last line is not empty."""
        var raw = self.rope.to_bytes()
        var need_final = self.eol_at_eof and self.rope.line_len(self.rope.line_count() - 1) > 0
        if not self.crlf:
            if need_final:
                raw.append(10)
            return raw^
        var out = List[UInt8]()
        for b in raw:
            if b == 10:
                out.append(13)
            out.append(b)
        if need_final:
            out.append(13)
            out.append(10)
        return out^

    def count(self) -> Int:
        """Number of lines (at least 1)."""
        return self.rope.line_count()

    def llen(self, r: Int) -> Int:
        """Characters in line r, without its newline."""
        return self.rope.line_len(r)

    def line(self, r: Int) -> List[Int]:
        """Codepoints of line r (a copy; empty for a row that does not exist). Fetch a
        line once and index the result rather than calling `at` for every character."""
        return self.rope.line(r)

    def at(self, r: Int, c: Int) -> Int:
        """Codepoint at (r, c), or -1 outside the text (including at the line's end)."""
        if r < 0 or r >= self.rope.line_count() or c < 0:
            return -1
        var start = self.rope.line_start(r)
        if c >= self.rope.line_end(r) - start:
            return -1
        return self.rope.char_at(start + c)

    def end_of(self, r: Int, c: Int, text: List[Int]) -> Pos:
        var rr = r
        var cc = c
        for ch in text:
            if ch == 10:
                rr += 1
                cc = 0
            else:
                cc += 1
        return Pos(rr, cc)

    def get_text(self, r1: Int, c1: Int, r2: Int, c2: Int) -> List[Int]:
        """Text from (r1, c1) up to (r2, c2); columns past a line's end are clamped."""
        var a = self.rope.offset(r1, c1)
        var b = self.rope.offset(r2, c2)
        if b <= a:
            return List[Int]()
        return self.rope.slice(a, b)

    # --------------------------------------------------------- raw edits
    def insert_raw(mut self, r: Int, c: Int, text: List[Int]) -> Pos:
        # clamp like the rope does, so the returned end position matches what happened
        var rr = max(0, min(r, self.rope.line_count() - 1))
        var cc = max(0, min(c, self.rope.line_len(rr)))
        self.rope.insert(self.rope.offset(rr, cc), text)
        self.modified = True
        self.version += 1
        return self.end_of(rr, cc, text)

    def delete_raw(mut self, r1: Int, c1: Int, r2: Int, c2: Int) -> List[Int]:
        var a = self.rope.offset(r1, c1)
        var b = self.rope.offset(r2, c2)
        var out = List[Int]()
        if b > a:
            out = self.rope.slice(a, b)
            self.rope.delete(a, b)
        self.modified = True
        self.version += 1
        return out^

    # ----------------------------------------------------- recorded edits
    def insert(mut self, r: Int, c: Int, text: List[Int], cr: Int, cc: Int, group: Int) -> Pos:
        var p = self.insert_raw(r, c, text)
        var merged = False
        var n = len(self.undos)
        if group != 0 and n > 0 and self.undos[n - 1].group == group and self.undos[n - 1].kind == UNDO_INSERT:
            var e = self.end_of(self.undos[n - 1].r, self.undos[n - 1].c, self.undos[n - 1].text)
            if e.r == r and e.c == c:
                for t in text:
                    self.undos[n - 1].text.append(t)
                merged = True
        if not merged:
            self.undos.append(UndoRec(UNDO_INSERT, r, c, text.copy(), cr, cc, group))
        self.redos.clear()
        return p^

    def delete(mut self, r1: Int, c1: Int, r2: Int, c2: Int, cr: Int, cc: Int, group: Int) -> List[Int]:
        var t = self.delete_raw(r1, c1, r2, c2)
        self.undos.append(UndoRec(UNDO_DELETE, r1, c1, t.copy(), cr, cc, group))
        self.redos.clear()
        return t^

    def undo(mut self) -> Pos:
        if len(self.undos) == 0:
            return Pos(-1, -1)
        var g = self.undos[len(self.undos) - 1].group
        var pos = Pos(-1, -1)
        while len(self.undos) > 0:
            var u = self.undos.pop()
            if u.kind == UNDO_INSERT:
                var e = self.end_of(u.r, u.c, u.text)
                _ = self.delete_raw(u.r, u.c, e.r, e.c)
            else:
                _ = self.insert_raw(u.r, u.c, u.text)
            pos = Pos(u.cr, u.cc)
            self.redos.append(u^)
            if g == 0 or len(self.undos) == 0 or self.undos[len(self.undos) - 1].group != g:
                break
        return pos^

    def redo(mut self) -> Pos:
        if len(self.redos) == 0:
            return Pos(-1, -1)
        var g = self.redos[len(self.redos) - 1].group
        var pos = Pos(-1, -1)
        while len(self.redos) > 0:
            var u = self.redos.pop()
            if u.kind == UNDO_INSERT:
                pos = self.insert_raw(u.r, u.c, u.text)
            else:
                var e = self.end_of(u.r, u.c, u.text)
                _ = self.delete_raw(u.r, u.c, e.r, e.c)
                pos = Pos(u.r, u.c)
            self.undos.append(u^)
            if g == 0 or len(self.redos) == 0 or self.redos[len(self.redos) - 1].group != g:
                break
        return pos^
