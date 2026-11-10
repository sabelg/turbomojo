"""Text buffer of codepoint lines with grouped undo/redo."""
from std.collections import List
from util import encode_cp

comptime UNDO_INSERT = 1
comptime UNDO_DELETE = 2
comptime TAB_WIDTH = 4


struct Line(Copyable, Movable):
    var c: List[Int]

    def __init__(out self):
        self.c = List[Int]()

    def __init__(out self, var c: List[Int]):
        self.c = c^


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
    var lines: List[Line]
    var undos: List[UndoRec]
    var redos: List[UndoRec]
    var modified: Bool
    var version: Int
    var crlf: Bool
    var use_tabs: Bool
    var eol_at_eof: Bool

    def __init__(out self):
        self.lines = List[Line]()
        self.lines.append(Line())
        self.undos = List[UndoRec]()
        self.redos = List[UndoRec]()
        self.modified = False
        self.version = 0
        self.crlf = False
        self.use_tabs = False
        self.eol_at_eof = True

    def load(mut self, cps: List[Int]):
        """Split exactly on newlines: tabs are kept, a trailing newline yields a
        final empty line, and CRLF files are remembered and saved as CRLF."""
        self.lines = List[Line]()
        var cur = List[Int]()
        var crlf_n = 0
        var lf_n = 0
        for i in range(len(cps)):
            var c = cps[i]
            if c == 10:
                if len(cur) > 0 and cur[len(cur) - 1] == 13:
                    _ = cur.pop()
                    crlf_n += 1
                else:
                    lf_n += 1
                self.lines.append(Line(cur^))
                cur = List[Int]()
            else:
                cur.append(c)
        self.eol_at_eof = len(cur) == 0
        self.lines.append(Line(cur^))
        self.crlf = crlf_n > lf_n
        var tabs = 0
        var spaces = 0
        for i in range(len(self.lines)):
            if len(self.lines[i].c) > 0:
                if self.lines[i].c[0] == 9:
                    tabs += 1
                elif self.lines[i].c[0] == 32:
                    spaces += 1
        self.use_tabs = tabs > spaces
        self.undos.clear()
        self.redos.clear()
        self.modified = False
        self.version += 1

    def all_text(self) -> List[Int]:
        var out = List[Int]()
        for i in range(len(self.lines)):
            for c in self.lines[i].c:
                out.append(c)
            if i + 1 < len(self.lines):
                out.append(10)
        return out^

    def to_bytes(self) -> List[UInt8]:
        var out = List[UInt8]()
        for i in range(len(self.lines)):
            if i > 0:
                if self.crlf:
                    out.append(13)
                out.append(10)
            for c in self.lines[i].c:
                encode_cp(c, out)
        if self.eol_at_eof and len(self.lines[len(self.lines) - 1].c) > 0:
            if self.crlf:
                out.append(13)
            out.append(10)
        return out^

    def count(self) -> Int:
        return len(self.lines)

    def llen(self, r: Int) -> Int:
        return len(self.lines[r].c)

    def at(self, r: Int, c: Int) -> Int:
        if r < 0 or r >= len(self.lines) or c < 0 or c >= len(self.lines[r].c):
            return -1
        return self.lines[r].c[c]

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
        var out = List[Int]()
        if r1 == r2:
            for i in range(c1, min(c2, len(self.lines[r1].c))):
                out.append(self.lines[r1].c[i])
            return out^
        for i in range(c1, len(self.lines[r1].c)):
            out.append(self.lines[r1].c[i])
        for r in range(r1 + 1, r2):
            out.append(10)
            for c in self.lines[r].c:
                out.append(c)
        out.append(10)
        for i in range(0, min(c2, len(self.lines[r2].c))):
            out.append(self.lines[r2].c[i])
        return out^

    # --------------------------------------------------------- raw edits
    def insert_raw(mut self, r: Int, c: Int, text: List[Int]) -> Pos:
        var tail = List[Int]()
        for i in range(c, len(self.lines[r].c)):
            tail.append(self.lines[r].c[i])
        while len(self.lines[r].c) > c:
            _ = self.lines[r].c.pop()
        var cur = r
        for ch in text:
            if ch == 10:
                cur += 1
                self.lines.insert(cur, Line())
            else:
                self.lines[cur].c.append(ch)
        var endc = len(self.lines[cur].c)
        for t in tail:
            self.lines[cur].c.append(t)
        self.modified = True
        self.version += 1
        return Pos(cur, endc)

    def delete_raw(mut self, r1: Int, c1: Int, r2: Int, c2: Int) -> List[Int]:
        var out = self.get_text(r1, c1, r2, c2)
        var tail = List[Int]()
        for i in range(c2, len(self.lines[r2].c)):
            tail.append(self.lines[r2].c[i])
        while len(self.lines[r1].c) > c1:
            _ = self.lines[r1].c.pop()
        for t in tail:
            self.lines[r1].c.append(t)
        for _ in range(r2 - r1):
            _ = self.lines.pop(r1 + 1)
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
