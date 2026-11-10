"""Text buffer: a rope of UTF-8 text addressed by (row, column in codepoints), with
grouped undo/redo and the per-file settings (line endings, indentation, final newline).

The text itself lives in `Rope` (src/rope.mojo), so loading, editing and line lookups stay
fast on very large files. Line endings are normalised to "\n" in memory; `crlf` remembers
that the file used CR LF and `to_bytes` writes it back that way."""
from std.collections import List
from util import encode_cp, decode_list
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


comptime ENC_UTF8 = 0
comptime ENC_LATIN1 = 1


struct TextBuffer(Copyable, Movable):
    var rope: Rope
    var undos: List[UndoRec]
    var redos: List[UndoRec]
    var modified: Bool
    var folds: List[Int]      # rows of the folded block headers, ascending
    var fold_ends: List[Int]  # last hidden row of each fold (as of fold_version)
    var fold_version: Int
    var bom: Bool             # the file starts with a UTF-8 byte order mark (kept on save)
    var encoding: Int         # ENC_UTF8 or ENC_LATIN1: how the file's bytes are read and written
    var mixed_eol: Bool       # the file had both LF and CRLF line ends (saving makes them one kind)
    var large: Bool           # large-file mode: expensive features are off for this buffer
    var version: Int
    var crlf: Bool
    var use_tabs: Bool
    var eol_at_eof: Bool
    var tab_width: Int      # columns a tab character advances to (display)
    var indent_size: Int    # spaces per indentation level when indenting with spaces
    var trim_on_save: Bool  # strip trailing whitespace when saving (.editorconfig)
    # Highlighter state cache (see Window.sync_lex): lstate[i] is the lexer state at the
    # start of line i for every i < len(lstate). Lines beyond that are not scanned yet.
    var lstate: List[UInt8]
    var ldirty_from: Int    # first row whose lines must be re-scanned (-1 = none)
    var ldirty_to: Int      # last row of the edited region
    var lex_work: Int       # lines scanned so far (for tests and profiling)

    def __init__(out self):
        self.rope = Rope()
        self.undos = List[UndoRec]()
        self.redos = List[UndoRec]()
        self.modified = False
        self.large = False
        self.bom = False
        self.encoding = ENC_UTF8
        self.mixed_eol = False
        self.folds = List[Int]()
        self.fold_ends = List[Int]()
        self.fold_version = -1
        self.version = 0
        self.crlf = False
        self.use_tabs = False
        self.eol_at_eof = True
        self.tab_width = TAB_WIDTH
        self.indent_size = TAB_WIDTH
        self.trim_on_save = False
        self.lstate = List[UInt8]()
        self.lstate.append(0)
        self.ldirty_from = -1
        self.ldirty_to = -1
        self.lex_work = 0

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
        self.mixed_eol = crlf_n > 0 and lf_n > 0
        self.bom = False
        self.encoding = ENC_UTF8
        self.use_tabs = tabs > spaces
        self.rope.load_cps(clean)
        self.after_load()

    def load_bytes(mut self, bytes: List[UInt8]):
        """load() straight from a file's bytes, without the detour through a list of
        codepoints (8 bytes per character). A UTF-8 byte order mark at the start is taken
        off and remembered. Bytes that are not valid UTF-8 mean the file is in another
        encoding: it is then read as Latin-1, one character per byte, which loses nothing
        and writes back the same bytes."""
        var n = len(bytes)
        var has_bom = n >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF
        var clean = List[UInt8](capacity=n)
        var crlf_n = 0
        var lf_n = 0
        var tabs = 0
        var spaces = 0
        var at_line_start = True
        var i = 3 if has_bom else 0
        while i < n:
            var c = Int(bytes[i])
            if c < 0x80:
                if c == 13 and i + 1 < n and bytes[i + 1] == 10:
                    crlf_n += 1
                    i += 1
                    continue            # dropped: the following "\n" ends the line
                if c == 10:
                    if not (i > 0 and bytes[i - 1] == 13):
                        lf_n += 1
                    at_line_start = True
                elif at_line_start:
                    if c == 9:
                        tabs += 1
                    elif c == 32:
                        spaces += 1
                    at_line_start = False
                clean.append(bytes[i])
                i += 1
                continue
            # a multi-byte character: check it is well formed
            var size = 0
            var lo = 0x80
            var hi = 0xBF
            if c >= 0xC2 and c <= 0xDF:
                size = 2
            elif c >= 0xE0 and c <= 0xEF:
                size = 3
                if c == 0xE0:
                    lo = 0xA0           # no overlong forms
                elif c == 0xED:
                    hi = 0x9F           # no surrogates
            elif c >= 0xF0 and c <= 0xF4:
                size = 4
                if c == 0xF0:
                    lo = 0x90
                elif c == 0xF4:
                    hi = 0x8F           # nothing above U+10FFFF
            var good = size > 0 and i + size <= n
            if good:
                var b1 = Int(bytes[i + 1])
                good = b1 >= lo and b1 <= hi
                for k in range(2, size):
                    var bk = Int(bytes[i + k])
                    if bk < 0x80 or bk > 0xBF:
                        good = False
            if not good:
                var cps = List[Int]()
                for q in range(n):
                    cps.append(Int(bytes[q]))
                self.load(cps)
                self.encoding = ENC_LATIN1
                return
            for k in range(size):
                clean.append(bytes[i + k])
            at_line_start = False
            i += size
        self.eol_at_eof = len(clean) == 0 or clean[len(clean) - 1] == 10
        self.crlf = crlf_n > lf_n
        self.mixed_eol = crlf_n > 0 and lf_n > 0
        self.bom = has_bom
        self.encoding = ENC_UTF8
        self.use_tabs = tabs > spaces
        self.rope.load_bytes(clean)
        self.after_load()

    def after_load(mut self):
        self.folds.clear()
        self.fold_ends.clear()
        self.lstate.clear()
        self.lstate.append(0)
        self.ldirty_from = -1
        self.ldirty_to = -1
        self.undos.clear()
        self.redos.clear()
        self.modified = False
        self.version += 1

    # ------------------------------------------------------------ folding
    def indent_cols(self, r: Int) -> Int:
        """Screen columns of the leading blanks of line r; -1 for a blank line."""
        var b = self.line_bytes(r)
        var v = 0
        for x in b:
            if x == 32:
                v += 1
            elif x == 9:
                v += self.tab_width - v % self.tab_width
            else:
                return v
        return -1

    def block_end(self, r: Int) -> Int:
        """Last line of the block that belongs to line r: the following lines indented
        deeper than r (blank lines between them included). r itself if there is none."""
        var base = self.indent_cols(r)
        if base < 0:
            return r
        var end = r
        var count = self.rope.line_count()
        var j = r + 1
        while j < count:
            var ind = self.indent_cols(j)
            if ind >= 0:
                if ind <= base:
                    break
                end = j
            j += 1
        return end

    def foldable(self, r: Int) -> Bool:
        """Does line r start a block? (Looks at most 200 lines ahead for the next line
        that is not blank.)"""
        var base = self.indent_cols(r)
        if base < 0:
            return False
        var count = self.rope.line_count()
        var j = r + 1
        while j < count and j <= r + 200:
            var ind = self.indent_cols(j)
            if ind >= 0:
                return ind > base
            j += 1
        return False

    def sync_folds(mut self):
        """Bring the fold ranges up to date after edits; folds whose header no longer
        starts a block disappear."""
        if self.fold_version == self.version and len(self.fold_ends) == len(self.folds):
            return
        var kept = List[Int]()
        var ends = List[Int]()
        var count = self.rope.line_count()
        for f in self.folds:
            if f < 0 or f >= count or (len(kept) > 0 and kept[len(kept) - 1] >= f):
                continue
            var e = self.block_end(f)
            if e > f:
                kept.append(f)
                ends.append(e)
        self.folds = kept^
        self.fold_ends = ends^
        self.fold_version = self.version

    def fold_index(self, r: Int) -> Int:
        """Index of the fold whose header is line r, or -1."""
        for i in range(len(self.folds)):
            if self.folds[i] == r:
                return i
            if self.folds[i] > r:
                break
        return -1

    def hidden_by(self, r: Int) -> Int:
        """Header line of the outermost fold that hides line r; -1 if r is visible."""
        if len(self.fold_ends) != len(self.folds):
            return -1
        for i in range(len(self.folds)):
            if self.folds[i] >= r:
                break
            if self.fold_ends[i] >= r:
                return self.folds[i]
        return -1

    def next_row(self, r: Int) -> Int:
        """The next visible line after r (the line count if there is none)."""
        if len(self.folds) > 0 and len(self.fold_ends) == len(self.folds):
            var h = self.hidden_by(r)
            var i = self.fold_index(r if h < 0 else h)
            if i >= 0:
                return self.fold_ends[i] + 1
        return r + 1

    def prev_row(self, r: Int) -> Int:
        """The visible line before r (-1 if there is none)."""
        if r <= 0:
            return -1
        var h = self.hidden_by(r - 1)
        return r - 1 if h < 0 else h

    def set_fold(mut self, r: Int, on: Bool) -> Bool:
        """Fold or unfold the block that starts at line r. False if r starts no block."""
        self.sync_folds()
        var i = self.fold_index(r)
        if not on:
            if i < 0:
                return False
            _ = self.folds.pop(i)
            self.fold_version = -1
            self.sync_folds()
            return True
        if i >= 0:
            return True
        if self.block_end(r) <= r:
            return False
        var k = 0
        while k < len(self.folds) and self.folds[k] < r:
            k += 1
        self.folds.insert(k, r)
        self.fold_version = -1
        self.sync_folds()
        return True

    def fold_all(mut self) -> Int:
        """Fold every block. Returns how many there are."""
        self.folds.clear()
        var count = self.rope.line_count()
        var prev = -1          # the last line that was not blank
        var prev_ind = 0
        for r in range(count):
            var ind = self.indent_cols(r)
            if ind < 0:
                continue
            if prev >= 0 and ind > prev_ind:
                self.folds.append(prev)
            prev = r
            prev_ind = ind
        self.fold_version = -1
        self.sync_folds()
        return len(self.folds)

    def unfold_all(mut self):
        self.folds.clear()
        self.fold_ends.clear()
        self.fold_version = -1

    def all_text(self) -> List[Int]:
        """The whole text as codepoints, lines separated by "\n"."""
        return self.rope.to_cps()

    def latin1_ok(self) -> Bool:
        """Can every character be written as one Latin-1 byte (nothing above U+00FF)?"""
        for b in self.rope.to_bytes():
            if b >= 0xC4:
                return False
        return True

    def to_bytes(self) -> List[UInt8]:
        """The bytes to write to disk: in the file's encoding, with its byte order mark,
        its line endings, and a final newline when the buffer's policy asks for one and
        the last line is not empty. A Latin-1 buffer that has gained characters Latin-1
        cannot hold is written as UTF-8 rather than losing them."""
        var text = self.text_bytes()
        if self.encoding == ENC_LATIN1 and self.latin1_ok():
            var out = List[UInt8](capacity=len(text))
            var i = 0
            while i < len(text):
                var b = Int(text[i])
                if b < 0x80:
                    out.append(text[i])
                    i += 1
                else:
                    # two UTF-8 bytes (C2/C3 xx) are one Latin-1 byte
                    out.append(UInt8(((b & 0x03) << 6) | (Int(text[i + 1]) & 0x3F)))
                    i += 2
            return out^
        if self.bom and self.encoding == ENC_UTF8:
            var out = List[UInt8](capacity=len(text) + 3)
            out.append(0xEF)
            out.append(0xBB)
            out.append(0xBF)
            for b in text:
                out.append(b)
            return out^
        return text^

    def text_bytes(self) -> List[UInt8]:
        """The text as UTF-8 with the file's line endings and final newline: what tools
        that take UTF-8 (the language server) are given."""
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

    def line_bytes(self, r: Int) -> List[UInt8]:
        """UTF-8 bytes of line r without its newline."""
        return self.rope.slice_bytes(self.rope.line_start(r), self.rope.line_end(r))

    def note_edit(mut self, r: Int, old_extra: Int, new_extra: Int):
        """Keep the state cache aligned with an edit that started on row r, removed
        `old_extra` line breaks and added `new_extra`. States of lines before r stay
        valid. States of the lines after the edit are kept (shifted to their new rows) so
        that re-scanning can stop as soon as it reaches a line whose state is unchanged."""
        var known = len(self.lstate) - 1            # lines 0..known-1 have been scanned
        if r >= known:
            return                                  # the edited line was never scanned
        if old_extra > 64 or new_extra > 64:
            # a large change: forget everything after the edit; it is rebuilt lazily
            while len(self.lstate) > r + 1:
                _ = self.lstate.pop()
            if self.ldirty_from > r:
                self.ldirty_from = -1
                self.ldirty_to = -1
            elif self.ldirty_from >= 0:
                self.ldirty_to = min(self.ldirty_to, r)
            return
        for _ in range(old_extra):
            if r + 1 < len(self.lstate):
                _ = self.lstate.pop(r + 1)
        for _ in range(new_extra):
            self.lstate.insert(r + 1, 255)          # placeholder, overwritten by sync_lex
        var delta = new_extra - old_extra
        if self.ldirty_from < 0:
            self.ldirty_from = r
            self.ldirty_to = r + new_extra
        else:
            var old_to = self.ldirty_to
            if old_to > r:
                old_to = max(r, old_to + delta)
            self.ldirty_from = min(self.ldirty_from, r)
            self.ldirty_to = max(old_to, r + new_extra)

    # --------------------------------------------------------- raw edits
    def insert_raw(mut self, r: Int, c: Int, text: List[Int]) -> Pos:
        # clamp like the rope does, so the returned end position matches what happened
        var rr = max(0, min(r, self.rope.line_count() - 1))
        var cc = max(0, min(c, self.rope.line_len(rr)))
        self.rope.insert(self.rope.offset(rr, cc), text)
        var breaks = 0
        for ch in text:
            if ch == 10:
                breaks += 1
        self.note_edit(rr, 0, breaks)
        if breaks > 0 and len(self.folds) > 0:
            # folded headers below the insertion move down with their lines
            for i in range(len(self.folds)):
                if self.folds[i] > rr or (self.folds[i] == rr and cc == 0):
                    self.folds[i] += breaks
        self.modified = True
        self.version += 1
        return self.end_of(rr, cc, text)

    def delete_raw(mut self, r1: Int, c1: Int, r2: Int, c2: Int) -> List[Int]:
        var a = self.rope.offset(r1, c1)
        var b = self.rope.offset(r2, c2)
        var out = List[Int]()
        if b > a:
            var first = self.rope.line_of(a)
            var breaks = self.rope.line_of(b) - first
            out = self.rope.slice(a, b)
            self.rope.delete(a, b)
            self.note_edit(first, breaks, 0)
            if breaks > 0 and len(self.folds) > 0:
                # headers on removed lines lose their fold; the ones below move up
                var kept = List[Int]()
                for f in self.folds:
                    if f <= first:
                        kept.append(f)
                    elif f > first + breaks:
                        kept.append(f - breaks)
                self.folds = kept^
                self.fold_version = -1
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
