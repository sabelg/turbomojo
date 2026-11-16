"""Text buffer: a rope of UTF-8 text addressed by (row, column in codepoints), with
grouped undo/redo and the per-file settings (line endings, indentation, final newline).

The text itself lives in `Rope` (src/rope.mojo), so loading, editing and line lookups stay
fast on very large files. Line endings are normalised to "\n" in memory; `crlf` remembers
that the file used CR LF and `to_bytes` writes it back that way."""
from std.collections import List
from std.memory import ArcPointer
from util import encode_cp, decode_list, decode, to_str
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


comptime CHANGES_MAX = 2000           # recorded edits kept before giving up on them
comptime CHANGES_MAX_CHARS = 1000000  # ...and the text they may hold together


@fieldwise_init
struct DocChange(Copyable, Movable):
    """One edit in the form the language-server protocol uses: the range that was
    replaced (lines, and columns in UTF-16 units, as they were just before the edit) and
    the new text. Applying the recorded changes in order to the old text gives the new."""
    var sl: Int
    var sc: Int
    var el: Int
    var ec: Int
    var text: List[Int]


struct Mark(Copyable, Movable):
    """A problem reported for a range of the text (lines and character columns)."""
    var l1: Int
    var c1: Int
    var l2: Int
    var c2: Int
    var severity: Int      # 1 error, 2 warning, 3 information, 4 hint
    var message: String
    var deprecated: Bool

    def __init__(
        out self,
        l1: Int,
        c1: Int,
        l2: Int,
        c2: Int,
        severity: Int,
        message: String,
        deprecated: Bool = False,
    ):
        self.l1 = l1
        self.c1 = c1
        self.l2 = l2
        self.c2 = c2
        self.severity = severity
        self.message = message
        self.deprecated = deprecated


@fieldwise_init
struct Hint(Copyable, Movable):
    """A note the language server attaches to a place (an inferred type, the name of a
    parameter); row -1 = dropped by an edit."""
    var row: Int
    var col: Int
    var label: String
    var kind: Int          # 1 type, 2 parameter, 0 not said


def sem_word(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128


comptime ENC_UTF8 = 0
comptime ENC_LATIN1 = 1


@fieldwise_init
struct UndoDeltaNode(Copyable, Movable):
    var id: Int
    var parent: Int
    var children: List[Int]
    var seq: Int
    var group: Int
    var recs: List[UndoRec]
    var before_pos: Pos
    var after_pos: Pos
    var desc: String


@fieldwise_init
struct BufferCore(Copyable, Movable):
    var rope: Rope
    var utree_nodes: List[UndoDeltaNode]
    var utree_active: Int
    var utree_next_seq: Int

    def __init__(out self):
        self.rope = Rope()
        self.utree_nodes = List[UndoDeltaNode]()
        self.utree_nodes.append(
            UndoDeltaNode(0, -1, List[Int](), 0, 0, List[UndoRec](), Pos(0, 0), Pos(0, 0), "root")
        )
        self.utree_active = 0
        self.utree_next_seq = 0

    def reset_undo_tree(mut self):
        self.utree_nodes.clear()
        self.utree_nodes.append(
            UndoDeltaNode(0, -1, List[Int](), 0, 0, List[UndoRec](), Pos(0, 0), Pos(0, 0), "root")
        )
        self.utree_active = 0
        self.utree_next_seq = 0


struct TextBuffer(Copyable, Movable):
    var core: ArcPointer[BufferCore]
    var undos: List[UndoRec]
    var redos: List[UndoRec]
    var modified: Bool
    var folds: List[Int]      # rows of the folded block headers, ascending
    var fold_ends: List[Int]  # last hidden row of each fold (as of fold_version)
    var fold_version: Int
    var cell_badge_rows: List[Int]
    var cell_badges: List[String]
    var cell_out_rows: List[Int]
    var cell_out_texts: List[String]
    var cell_out_errs: List[Bool]
    var cell_out_plots: List[String]
    var cell_out_counts: List[Int]
    var marks: List[Mark]     # problems shown in this buffer (from the language server)
    var bps: List[Int]        # rows with a breakpoint, ascending; they move with the text
    var bp_looks: List[Int]   # how each is shown (Breakpoint.look)
    var bp_stamp: Int         # which state of the IDE's breakpoint list they come from (-1: none)
    var exec_row: Int         # the line the program being debugged is stopped at (-1: none)
    var git_state: Int        # GB_*: what is known of the file's version in git's index
    var git_path: String      # the path git_base was asked for
    var git_base: List[UInt64]  # line hashes of that version (GB_KNOWN)
    var git_base_text: String   # and the version itself
    var git_ver: Int          # `version` git_marks were worked out for (-1: not yet)
    var git_marks: List[UInt8]  # LM_* per line: added, changed, removed lines
    var sem: List[Int]        # semantic colours from the language server: row, c1, c2, class
                              # per token, by row; class -1 = dropped by an edit
    var hints: List[Hint]     # inlay hints from the language server
    var track: Bool           # record edits in `changes` (a language server follows this buffer)
    var changes: List[DocChange]
    var changes_lost: Bool    # too much happened, or the text was replaced: send it whole
    var changes_chars: Int
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
        self.core = ArcPointer(BufferCore())
        self.undos = List[UndoRec]()
        self.redos = List[UndoRec]()
        self.modified = False
        self.large = False
        self.bom = False
        self.encoding = ENC_UTF8
        self.mixed_eol = False
        self.marks = List[Mark]()
        self.bps = List[Int]()
        self.bp_looks = List[Int]()
        self.bp_stamp = -1
        self.exec_row = -1
        self.git_state = 0
        self.git_path = ""
        self.git_base = List[UInt64]()
        self.git_base_text = ""
        self.git_ver = -1
        self.git_marks = List[UInt8]()
        self.sem = List[Int]()
        self.hints = List[Hint]()
        self.track = False
        self.changes = List[DocChange]()
        self.changes_lost = False
        self.changes_chars = 0
        self.folds = List[Int]()
        self.fold_ends = List[Int]()
        self.fold_version = -1
        self.cell_badge_rows = List[Int]()
        self.cell_badges = List[String]()
        self.cell_out_rows = List[Int]()
        self.cell_out_texts = List[String]()
        self.cell_out_errs = List[Bool]()
        self.cell_out_plots = List[String]()
        self.cell_out_counts = List[Int]()
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
        self.sem.clear()
        self.hints.clear()
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
        self.core[].rope.load_cps(clean)
        self.after_load()

    def load_bytes(mut self, bytes: List[UInt8]):
        """load() straight from a file's bytes, without the detour through a list of
        codepoints (8 bytes per character). A UTF-8 byte order mark at the start is taken
        off and remembered. Bytes that are not valid UTF-8 mean the file is in another
        encoding: it is then read as Latin-1, one character per byte, which loses nothing
        and writes back the same bytes."""
        self.sem.clear()
        self.hints.clear()
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
        self.core[].rope.load_bytes(clean)
        self.after_load()

    def utf16_col(self, r: Int, c: Int) -> Int:
        """Column c of line r counted in UTF-16 code units."""
        var start = self.core[].rope.line_start(r)
        return self.core[].rope.to_utf16(self.core[].rope.offset(r, c)) - self.core[].rope.to_utf16(start)

    def note_change(mut self, sl: Int, sc: Int, el: Int, ec: Int, text: List[Int]):
        if not self.track or self.changes_lost:
            return
        self.changes_chars += len(text)
        if len(self.changes) >= CHANGES_MAX or self.changes_chars > CHANGES_MAX_CHARS:
            self.drop_changes()
            self.changes_lost = True
            return
        self.changes.append(DocChange(sl, sc, el, ec, text.copy()))

    def drop_changes(mut self):
        self.changes.clear()
        self.changes_chars = 0

    def start_tracking(mut self):
        """From now on edits are recorded; the follower has the current text."""
        self.track = True
        self.drop_changes()
        self.changes_lost = False

    def stop_tracking(mut self):
        self.track = False
        self.drop_changes()
        self.changes_lost = False

    def take_changes(mut self) -> List[DocChange]:
        """The edits since the last call (and forget them). Check `changes_lost` first:
        when it is set the list is not complete and the whole text has to be sent;
        clear the flag with start_tracking()."""
        var out = self.changes.copy()
        self.drop_changes()
        return out^

    def mark_severity(self, r: Int) -> Int:
        """The most serious problem that touches line r (1 = error ... 4 = hint; 0 none)."""
        var best = 0
        for m in self.marks:
            if r >= m.l1 and r <= m.l2 and (best == 0 or m.severity < best):
                best = m.severity
        return best

    def mark_text(self, r: Int) -> String:
        """"error: message" for the most serious problem that starts on line r ('' if
        none); only the first line of the message."""
        var best = -1
        for i in range(len(self.marks)):
            if self.marks[i].l1 == r and (best < 0 or self.marks[i].severity < self.marks[best].severity):
                best = i
        if best < 0:
            return ""
        var word = String("error") if self.marks[best].severity == 1 else (String("warning") if self.marks[best].severity == 2 else String("note"))
        var first = List[Int]()
        for c in decode(self.marks[best].message):
            if c == 10:
                break
            first.append(c)
        return word + ": " + to_str(first)

    def after_load(mut self):
        self.marks.clear()
        self.bps.clear()
        self.bp_looks.clear()
        self.bp_stamp = -1          # the IDE puts the file's breakpoints back
        if self.track:
            self.drop_changes()
            self.changes_lost = True       # a different text altogether
        self.folds.clear()
        self.fold_ends.clear()
        self.cell_badge_rows.clear()
        self.cell_badges.clear()
        self.cell_out_rows.clear()
        self.cell_out_texts.clear()
        self.cell_out_errs.clear()
        self.cell_out_plots.clear()
        self.cell_out_counts.clear()
        self.lstate.clear()
        self.lstate.append(0)
        self.ldirty_from = -1
        self.ldirty_to = -1
        self.undos.clear()
        self.redos.clear()
        self.core[].reset_undo_tree()
        self.modified = False
        self.version += 1

    # ------------------------------------------------------------ folding
    def is_cell_header(self, r: Int) -> Bool:
        """Does line r start a `# %%` code cell?"""
        if r < 0 or r >= self.core[].rope.line_count():
            return False
        var b = self.line_bytes(r)
        var i = 0
        var n = len(b)
        while i < n and (b[i] == 32 or b[i] == 9):
            i += 1
        if i + 4 <= n and b[i] == 35 and b[i + 1] == 32 and b[i + 2] == 37 and b[i + 3] == 37:
            return i + 4 == n or b[i + 4] == 32 or b[i + 4] == 9
        if i + 3 <= n and b[i] == 35 and b[i + 1] == 37 and b[i + 2] == 37:
            return i + 3 == n or b[i + 3] == 32 or b[i + 3] == 9
        return False

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
        deeper than r (blank lines between them included), or for `# %%` cells up to the
        line before the next `# %%` (or count() - 1). r itself if there is none."""
        var count = self.core[].rope.line_count()
        if self.is_cell_header(r):
            var jc = r + 1
            while jc < count and not self.is_cell_header(jc):
                jc += 1
            return jc - 1
        var base = self.indent_cols(r)
        if base < 0:
            return r
        var end = r
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
        that is not blank, or checks `# %%` cell span.)"""
        if self.is_cell_header(r):
            return self.block_end(r) > r
        var base = self.indent_cols(r)
        if base < 0:
            return False
        var count = self.core[].rope.line_count()
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
        var count = self.core[].rope.line_count()
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

    def bp_look(self, r: Int) -> Int:
        """How row r's breakpoint is shown (0: there is none)."""
        for i in range(len(self.bps)):
            if self.bps[i] == r:
                return self.bp_looks[i]
        return 0

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
        var count = self.core[].rope.line_count()
        var prev = -1          # the last line that was not blank
        var prev_ind = 0
        for r in range(count):
            if self.is_cell_header(r):
                if self.block_end(r) > r:
                    self.folds.append(r)
                prev = -1
                continue
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

    def set_cell_badge(mut self, row: Int, badge: String):
        for i in range(len(self.cell_badge_rows)):
            if self.cell_badge_rows[i] == row:
                self.cell_badges[i] = badge
                return
        self.cell_badge_rows.append(row)
        self.cell_badges.append(badge)

    def clear_cell_badges(mut self):
        self.cell_badge_rows.clear()
        self.cell_badges.clear()
        self.clear_cell_outputs()

    def set_cell_output(
        mut self,
        row: Int,
        text: String,
        is_err: Bool,
        plots_joined: String = "",
        exec_count: Int = 0,
    ):
        for i in range(len(self.cell_out_rows)):
            if self.cell_out_rows[i] == row:
                self.cell_out_texts[i] = text
                self.cell_out_errs[i] = is_err
                self.cell_out_plots[i] = plots_joined
                self.cell_out_counts[i] = exec_count
                return
        self.cell_out_rows.append(row)
        self.cell_out_texts.append(text)
        self.cell_out_errs.append(is_err)
        self.cell_out_plots.append(plots_joined)
        self.cell_out_counts.append(exec_count)

    def clear_cell_outputs(mut self):
        self.cell_out_rows.clear()
        self.cell_out_texts.clear()
        self.cell_out_errs.clear()
        self.cell_out_plots.clear()
        self.cell_out_counts.clear()

    def cell_end_for_header(self, hdr_row: Int) -> Int:
        """Return the anchor buffer row where virtual output for `hdr_row` is rendered
        (the last visible line of that cell, or `hdr_row` itself when the cell's code is
        collapsed so `Out [k]` and inline images remain visible right below the card header)."""
        var count = self.core[].rope.line_count()
        if hdr_row < 0 or hdr_row >= count:
            return -1
        if hdr_row > 0 and not self.is_cell_header(hdr_row):
            return -1
        if self.fold_index(hdr_row) >= 0:
            return hdr_row
        var jc = hdr_row + 1
        while jc < count and not self.is_cell_header(jc):
            jc += 1
        var end_r = jc - 1
        while end_r > hdr_row and self.core[].rope.line_len(end_r) == 0:
            end_r -= 1
        var h = self.hidden_by(end_r)
        if h >= hdr_row:
            end_r = h
        return end_r

    def all_text(self) -> List[Int]:
        """The whole text as codepoints, lines separated by "\n"."""
        return self.core[].rope.to_cps()

    def latin1_ok(self) -> Bool:
        """Can every character be written as one Latin-1 byte (nothing above U+00FF)?"""
        for b in self.core[].rope.to_bytes():
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

    def lsp_bytes(self) -> List[UInt8]:
        """The text exactly as the editor holds it: UTF-8, "\n" between lines, nothing
        added. This is the document a language server is given, so that its line and
        column numbers are the editor's."""
        return self.core[].rope.to_bytes()

    def text_bytes(self) -> List[UInt8]:
        """The text as UTF-8 with the file's line endings and final newline: what tools
        that take UTF-8 (the language server) are given."""
        var raw = self.core[].rope.to_bytes()
        var need_final = self.eol_at_eof and self.core[].rope.line_len(self.core[].rope.line_count() - 1) > 0
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
        return self.core[].rope.line_count()

    def llen(self, r: Int) -> Int:
        """Characters in line r, without its newline."""
        return self.core[].rope.line_len(r)

    def line(self, r: Int) -> List[Int]:
        """Codepoints of line r (a copy; empty for a row that does not exist). Fetch a
        line once and index the result rather than calling `at` for every character."""
        return self.core[].rope.line(r)

    def at(self, r: Int, c: Int) -> Int:
        """Codepoint at (r, c), or -1 outside the text (including at the line's end)."""
        if r < 0 or r >= self.core[].rope.line_count() or c < 0:
            return -1
        var start = self.core[].rope.line_start(r)
        if c >= self.core[].rope.line_end(r) - start:
            return -1
        return self.core[].rope.char_at(start + c)

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
        var a = self.core[].rope.offset(r1, c1)
        var b = self.core[].rope.offset(r2, c2)
        if b <= a:
            return List[Int]()
        return self.core[].rope.slice(a, b)

    def line_bytes(self, r: Int) -> List[UInt8]:
        """UTF-8 bytes of line r without its newline."""
        return self.core[].rope.slice_bytes(self.core[].rope.line_start(r), self.core[].rope.line_end(r))

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

    # ------------------------------------------------- semantic colours
    def sem_first(self, r: Int) -> Int:
        """Index (in tokens) of the first token on row >= r."""
        var lo = 0
        var hi = len(self.sem) // 4
        while lo < hi:
            var mid = (lo + hi) // 2
            if self.sem[mid * 4] < r:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def sem_apply(self, r: Int, mut classes: List[Int]):
        """Lay the server's colours for row r over the lexer's classes. Only plain
        identifiers are recoloured (classes 0, 2, 8, 9, 10): keywords, strings and
        comments stay the lexer's, so a token left stale by an edit cannot paint them."""
        var n = len(self.sem) // 4
        var k = self.sem_first(r)
        while k < n and self.sem[k * 4] == r:
            var cls = self.sem[k * 4 + 3]
            if cls >= 0:
                var c2 = min(self.sem[k * 4 + 2], len(classes))
                for c in range(max(0, self.sem[k * 4 + 1]), c2):
                    var was = classes[c]
                    if was == 0 or was == 2 or was == 8 or was == 9 or was == 10:
                        classes[c] = cls
            k += 1

    def sem_inserted(mut self, r: Int, c: Int, text: List[Int], breaks: Int):
        """Keep the colours in step with an insertion until the server reports again:
        tokens after it on its row move right, a token typed into grows, rows below
        move down; what cannot be kept simply is dropped (the lexer's colour shows)."""
        var n = len(self.sem) // 4
        var k = self.sem_first(r)
        var wordy = len(text) > 0
        for ch in text:
            if not sem_word(ch):
                wordy = False
        var tail = 0                # characters of the text after its last line break
        for ch in text:
            tail = 0 if ch == 10 else tail + 1
        while k < n and self.sem[k * 4] == r:
            var a = self.sem[k * 4 + 1]
            var b = self.sem[k * 4 + 2]
            if breaks > 0:
                if a >= c:
                    # behind the insertion: now on the last of the new lines
                    self.sem[k * 4] = r + breaks
                    self.sem[k * 4 + 1] = a - c + tail
                    self.sem[k * 4 + 2] = b - c + tail
                elif b > c:
                    self.sem[k * 4 + 3] = -1
            elif a >= c and not (a == c and wordy):
                self.sem[k * 4 + 1] = a + len(text)
                self.sem[k * 4 + 2] = b + len(text)
            elif b >= c and a <= c:
                if wordy:
                    self.sem[k * 4 + 2] = b + len(text)     # typing inside or at the end of a name
                elif b > c:
                    self.sem[k * 4 + 3] = -1                # the name was split
            k += 1
        if breaks > 0:
            while k < n:
                self.sem[k * 4] += breaks
                k += 1

    def sem_deleted(mut self, r1: Int, c1: Int, r2: Int, c2: Int):
        var n = len(self.sem) // 4
        var k = self.sem_first(r1)
        while k < n and self.sem[k * 4] <= r2:
            var row = self.sem[k * 4]
            var a = self.sem[k * 4 + 1]
            var b = self.sem[k * 4 + 2]
            if r1 == r2:
                if a >= c2:
                    self.sem[k * 4 + 1] = a - (c2 - c1)
                    self.sem[k * 4 + 2] = b - (c2 - c1)
                elif b > c1:
                    if a <= c1 and b >= c2 and b - (c2 - c1) > a:
                        self.sem[k * 4 + 2] = b - (c2 - c1)     # characters removed inside a name
                    else:
                        self.sem[k * 4 + 3] = -1
            elif row == r2 and a >= c2:
                # behind the removed text: now on the first line, after what is left of it
                self.sem[k * 4] = r1
                self.sem[k * 4 + 1] = a - c2 + c1
                self.sem[k * 4 + 2] = b - c2 + c1
            elif row > r1 or b > c1:
                self.sem[k * 4 + 3] = -1
                if row > r1:
                    self.sem[k * 4] = r1        # keeps the list in row order
            k += 1
        if r2 > r1:
            while k < n:
                self.sem[k * 4] -= r2 - r1
                k += 1

    def hints_text(self, r: Int) -> String:
        """What the hints on row r say, for showing after the end of the line: a type
        hint as "name: Type", a parameter hint as "name: argument"."""
        var out = String("")
        var line = List[Int]()
        var loaded = False
        for h in self.hints:
            if h.row != r:
                continue
            if not loaded:
                line = self.line(r)
                loaded = True
            var col = max(0, min(h.col, len(line)))
            var label = String(h.label.strip())
            var piece: String
            if h.kind == 2 or (h.kind == 0 and label.endswith(":")):
                # the argument the name belongs to
                var e = col
                var depth = 0
                while e < len(line) and e - col < 24:
                    var ch = line[e]
                    if ch == 40 or ch == 91:
                        depth += 1
                    elif ch == 41 or ch == 93:
                        if depth == 0:
                            break
                        depth -= 1
                    elif ch == 44 and depth == 0:
                        break
                    e += 1
                var arg = List[Int]()
                for q in range(col, e):
                    arg.append(line[q])
                piece = label + " " + String(to_str(arg).strip())
            else:
                var a = col
                while a > 0 and sem_word(line[a - 1]):
                    a -= 1
                var name = List[Int]()
                for q in range(a, col):
                    name.append(line[q])
                piece = to_str(name) + label
            if piece.byte_length() > 0:
                out += (", " if out.byte_length() > 0 else "") + piece
        return out

    # --------------------------------------------------------- raw edits
    def insert_raw(mut self, r: Int, c: Int, text: List[Int]) -> Pos:
        # clamp like the rope does, so the returned end position matches what happened
        var rr = max(0, min(r, self.core[].rope.line_count() - 1))
        var cc = max(0, min(c, self.core[].rope.line_len(rr)))
        if self.track and len(text) > 0:
            var u = self.utf16_col(rr, cc)
            self.note_change(rr, u, rr, u, text)
        self.core[].rope.insert(self.core[].rope.offset(rr, cc), text)
        var breaks = 0
        for ch in text:
            if ch == 10:
                breaks += 1
        self.note_edit(rr, 0, breaks)
        if len(self.sem) > 0:
            self.sem_inserted(rr, cc, text, breaks)
        if len(self.hints) > 0:
            for i in range(len(self.hints)):
                if self.hints[i].row == rr:
                    self.hints[i].row = -1          # asked for again after the edit
                elif self.hints[i].row > rr:
                    self.hints[i].row += breaks
        if breaks > 0 and len(self.marks) > 0:
            # problems below the insertion keep pointing at their lines until the
            # server reports again
            for i in range(len(self.marks)):
                if self.marks[i].l1 > rr or (self.marks[i].l1 == rr and cc <= self.marks[i].c1):
                    self.marks[i].l1 += breaks
                    self.marks[i].l2 += breaks
        if breaks > 0 and len(self.bps) > 0:
            # a breakpoint stays on its statement: a line break before it moves it down
            for i in range(len(self.bps)):
                if self.bps[i] > rr or (self.bps[i] == rr and cc == 0):
                    self.bps[i] += breaks
        if breaks > 0 and len(self.folds) > 0:
            # folded headers below the insertion move down with their lines
            for i in range(len(self.folds)):
                if self.folds[i] > rr or (self.folds[i] == rr and cc == 0):
                    self.folds[i] += breaks
        if breaks > 0 and len(self.cell_badge_rows) > 0:
            for i in range(len(self.cell_badge_rows)):
                if self.cell_badge_rows[i] > rr or (self.cell_badge_rows[i] == rr and cc == 0):
                    self.cell_badge_rows[i] += breaks
        if breaks > 0 and len(self.cell_out_rows) > 0:
            for i in range(len(self.cell_out_rows)):
                if self.cell_out_rows[i] > rr or (self.cell_out_rows[i] == rr and cc == 0):
                    self.cell_out_rows[i] += breaks
        self.modified = True
        self.version += 1
        return self.end_of(rr, cc, text)

    def delete_raw(mut self, r1: Int, c1: Int, r2: Int, c2: Int) -> List[Int]:
        var a = self.core[].rope.offset(r1, c1)
        var b = self.core[].rope.offset(r2, c2)
        var out = List[Int]()
        if b > a:
            var first = self.core[].rope.line_of(a)
            var breaks = self.core[].rope.line_of(b) - first
            if self.track:
                var last = first + breaks
                var su = self.core[].rope.to_utf16(a) - self.core[].rope.to_utf16(self.core[].rope.line_start(first))
                var eu = self.core[].rope.to_utf16(b) - self.core[].rope.to_utf16(self.core[].rope.line_start(last))
                self.note_change(first, su, last, eu, List[Int]())
            out = self.core[].rope.slice(a, b)
            self.core[].rope.delete(a, b)
            self.note_edit(first, breaks, 0)
            if len(self.sem) > 0:
                self.sem_deleted(first, c1, first + breaks, c2)
            if len(self.hints) > 0:
                for i in range(len(self.hints)):
                    if self.hints[i].row >= first and self.hints[i].row <= first + breaks:
                        self.hints[i].row = -1
                    elif self.hints[i].row > first + breaks:
                        self.hints[i].row -= breaks
            if breaks > 0 and len(self.marks) > 0:
                var left = List[Mark]()
                for m in self.marks:
                    if m.l1 <= first:
                        left.append(m.copy())
                    elif m.l1 > first + breaks:
                        left.append(Mark(m.l1 - breaks, m.c1, m.l2 - breaks, m.c2, m.severity, m.message, m.deprecated))
                self.marks = left^
            if breaks > 0 and len(self.bps) > 0:
                # breakpoints of removed lines gather on the line that is left
                for i in range(len(self.bps)):
                    if self.bps[i] > first + breaks:
                        self.bps[i] -= breaks
                    elif self.bps[i] > first:
                        self.bps[i] = first
            if breaks > 0 and len(self.folds) > 0:
                # headers on removed lines lose their fold; the ones below move up
                var kept = List[Int]()
                for f in self.folds:
                    if f < first or (f == first and (self.is_cell_header(first) or self.foldable(first))):
                        kept.append(f)
                    elif f == first + breaks and c1 == 0 and c2 == 0:
                        kept.append(first)
                    elif f > first + breaks:
                        kept.append(f - breaks)
                self.folds = kept^
                self.fold_version = -1
            if breaks > 0 and len(self.cell_badge_rows) > 0:
                var krows = List[Int]()
                var kvals = List[String]()
                for i in range(len(self.cell_badge_rows)):
                    var br = self.cell_badge_rows[i]
                    if br < first or (br == first and (br == 0 or self.is_cell_header(first))):
                        krows.append(br)
                        kvals.append(self.cell_badges[i])
                    elif br == first + breaks and self.is_cell_header(first):
                        krows.append(first)
                        kvals.append(self.cell_badges[i])
                    elif br > first + breaks:
                        krows.append(br - breaks)
                        kvals.append(self.cell_badges[i])
                self.cell_badge_rows = krows^
                self.cell_badges = kvals^
            if breaks > 0 and len(self.cell_out_rows) > 0:
                var orows = List[Int]()
                var otexts = List[String]()
                var oerrs = List[Bool]()
                var oplots = List[String]()
                var ocounts = List[Int]()
                for i in range(len(self.cell_out_rows)):
                    var obr = self.cell_out_rows[i]
                    var keep_r = -1
                    if obr < first or (obr == first and (obr == 0 or self.is_cell_header(first))):
                        keep_r = obr
                    elif obr == first + breaks and self.is_cell_header(first):
                        keep_r = first
                    elif obr > first + breaks:
                        keep_r = obr - breaks
                    if keep_r >= 0:
                        orows.append(keep_r)
                        otexts.append(self.cell_out_texts[i])
                        oerrs.append(self.cell_out_errs[i])
                        oplots.append(self.cell_out_plots[i])
                        ocounts.append(self.cell_out_counts[i])
                self.cell_out_rows = orows^
                self.cell_out_texts = otexts^
                self.cell_out_errs = oerrs^
                self.cell_out_plots = oplots^
                self.cell_out_counts = ocounts^
        self.modified = True
        self.version += 1
        return out^

    # ----------------------------------------------------- recorded edits
    def insert(mut self, r: Int, c: Int, text: List[Int], cr: Int, cc: Int, group: Int) -> Pos:
        var p = self.insert_raw(r, c, text)
        var act = self.core[].utree_active
        var can_merge = len(self.redos) == 0 and len(self.core[].utree_nodes[act].children) == 0
        var eff_group = group
        if not can_merge and group != 0 and act > 0 and self.core[].utree_nodes[act].group == group:
            eff_group = -group - 1000000
        var merged = False
        var n = len(self.undos)
        if can_merge and eff_group != 0 and n > 0 and self.undos[n - 1].group == eff_group and self.undos[n - 1].kind == UNDO_INSERT:
            var e = self.end_of(self.undos[n - 1].r, self.undos[n - 1].c, self.undos[n - 1].text)
            if e.r == r and e.c == c:
                for t in text:
                    self.undos[n - 1].text.append(t)
                if act > 0 and len(self.core[].utree_nodes[act].recs) > 0:
                    var nr = len(self.core[].utree_nodes[act].recs) - 1
                    for t2 in text:
                        self.core[].utree_nodes[act].recs[nr].text.append(t2)
                    self.core[].utree_nodes[act].after_pos = p.copy()
                merged = True
        if not merged:
            var rec = UndoRec(UNDO_INSERT, r, c, text.copy(), cr, cc, eff_group)
            self.undos.append(rec.copy())
            if can_merge and eff_group != 0 and act > 0 and self.core[].utree_nodes[act].group == eff_group:
                self.core[].utree_nodes[act].recs.append(rec^)
                self.core[].utree_nodes[act].after_pos = p.copy()
            else:
                self.core[].utree_next_seq += 1
                var seq = self.core[].utree_next_seq
                var nid = len(self.core[].utree_nodes)
                var recs = List[UndoRec]()
                recs.append(rec^)
                var node = UndoDeltaNode(
                    nid, act, List[Int](), seq, eff_group, recs^, Pos(cr, cc), p.copy(), "insert"
                )
                self.core[].utree_nodes.append(node^)
                self.core[].utree_nodes[act].children.append(nid)
                self.core[].utree_active = nid
        self.redos.clear()
        return p^

    def delete(mut self, r1: Int, c1: Int, r2: Int, c2: Int, cr: Int, cc: Int, group: Int) -> List[Int]:
        var t = self.delete_raw(r1, c1, r2, c2)
        var act = self.core[].utree_active
        var can_merge = len(self.redos) == 0 and len(self.core[].utree_nodes[act].children) == 0
        var eff_group = group
        if not can_merge and group != 0 and act > 0 and self.core[].utree_nodes[act].group == group:
            eff_group = -group - 1000000
        var rec = UndoRec(UNDO_DELETE, r1, c1, t.copy(), cr, cc, eff_group)
        self.undos.append(rec.copy())
        if can_merge and eff_group != 0 and act > 0 and self.core[].utree_nodes[act].group == eff_group:
            self.core[].utree_nodes[act].recs.append(rec^)
            self.core[].utree_nodes[act].after_pos = Pos(r1, c1)
        else:
            self.core[].utree_next_seq += 1
            var seq = self.core[].utree_next_seq
            var nid = len(self.core[].utree_nodes)
            var recs = List[UndoRec]()
            recs.append(rec^)
            var node = UndoDeltaNode(
                nid, act, List[Int](), seq, eff_group, recs^, Pos(cr, cc), Pos(r1, c1), "delete"
            )
            self.core[].utree_nodes.append(node^)
            self.core[].utree_nodes[act].children.append(nid)
            self.core[].utree_active = nid
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
        var act = self.core[].utree_active
        if act > 0 and self.core[].utree_nodes[act].parent >= 0:
            self.core[].utree_active = self.core[].utree_nodes[act].parent
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
        var act = self.core[].utree_active
        var n_ch = len(self.core[].utree_nodes[act].children)
        if n_ch > 0:
            self.core[].utree_active = self.core[].utree_nodes[act].children[n_ch - 1]
        return pos^

    def _sync_linear_from_utree(mut self, target_id: Int):
        """Rebuild linear `undos` / `redos` stacks to align with `target_id` in the undo tree."""
        self.undos.clear()
        self.redos.clear()
        var path = List[Int]()
        var cur = target_id
        while cur > 0:
            path.append(cur)
            cur = self.core[].utree_nodes[cur].parent
        var k = len(path) - 1
        while k >= 0:
            var nid = path[k]
            for j in range(len(self.core[].utree_nodes[nid].recs)):
                self.undos.append(self.core[].utree_nodes[nid].recs[j].copy())
            k -= 1
        var fwd = List[Int]()
        var ch_cur = target_id
        while True:
            var n_ch = len(self.core[].utree_nodes[ch_cur].children)
            if n_ch == 0:
                break
            ch_cur = self.core[].utree_nodes[ch_cur].children[n_ch - 1]
            fwd.append(ch_cur)
        var fk = len(fwd) - 1
        while fk >= 0:
            var fnid = fwd[fk]
            var rj = len(self.core[].utree_nodes[fnid].recs) - 1
            while rj >= 0:
                self.redos.append(self.core[].utree_nodes[fnid].recs[rj].copy())
                rj -= 1
            fk -= 1

    def undo_jump_to(mut self, target_id: Int) -> Tuple[Bool, Pos]:
        """Jump directly to node `target_id` in the non-linear undo tree."""
        var total = len(self.core[].utree_nodes)
        if target_id < 0 or target_id >= total:
            return (False, Pos(-1, -1))
        var cur = self.core[].utree_active
        if target_id == cur:
            return (True, self.core[].utree_nodes[cur].after_pos.copy())
        var anc_cur = List[Int]()
        var x = cur
        while x >= 0:
            anc_cur.append(x)
            x = self.core[].utree_nodes[x].parent
        var anc_tgt = List[Int]()
        var y = target_id
        while y >= 0:
            anc_tgt.append(y)
            y = self.core[].utree_nodes[y].parent
        var ic = len(anc_cur) - 1
        var it = len(anc_tgt) - 1
        while ic > 0 and it > 0 and anc_cur[ic - 1] == anc_tgt[it - 1]:
            ic -= 1
            it -= 1
        var pos = Pos(0, 0)
        # Walk up from `cur` to LCA (`anc_cur[ic]`)
        for ui in range(ic):
            var nid = anc_cur[ui]
            var recs = self.core[].utree_nodes[nid].recs.copy()
            var rk = len(recs) - 1
            while rk >= 0:
                var u = recs[rk].copy()
                if u.kind == UNDO_INSERT:
                    var e = self.end_of(u.r, u.c, u.text)
                    _ = self.delete_raw(u.r, u.c, e.r, e.c)
                else:
                    _ = self.insert_raw(u.r, u.c, u.text)
                pos = Pos(u.cr, u.cc)
                rk -= 1
        # Walk down from LCA (`anc_tgt[it]`) to `target_id`
        var di = it - 1
        while di >= 0:
            var nid2 = anc_tgt[di]
            var recs2 = self.core[].utree_nodes[nid2].recs.copy()
            for rj in range(len(recs2)):
                var u2 = recs2[rj].copy()
                if u2.kind == UNDO_INSERT:
                    pos = self.insert_raw(u2.r, u2.c, u2.text)
                else:
                    var e2 = self.end_of(u2.r, u2.c, u2.text)
                    _ = self.delete_raw(u2.r, u2.c, e2.r, e2.c)
                    pos = Pos(u2.r, u2.c)
            di -= 1
        self.core[].utree_active = target_id
        self._sync_linear_from_utree(target_id)
        return (True, pos^)

    def undo_earlier(mut self) -> Tuple[Bool, Pos]:
        """Step backward chronologically (`g-`) across any undo branch."""
        var cur = self.core[].utree_active
        var cur_seq = self.core[].utree_nodes[cur].seq
        var best_id = -1
        var best_seq = -1
        for i in range(len(self.core[].utree_nodes)):
            var s = self.core[].utree_nodes[i].seq
            if s < cur_seq and s > best_seq:
                best_seq = s
                best_id = i
        if best_id < 0:
            return (False, Pos(-1, -1))
        return self.undo_jump_to(best_id)

    def undo_later(mut self) -> Tuple[Bool, Pos]:
        """Step forward chronologically (`g+`) across any undo branch."""
        var cur = self.core[].utree_active
        var cur_seq = self.core[].utree_nodes[cur].seq
        var best_id = -1
        var best_seq = 1000000000
        for i in range(len(self.core[].utree_nodes)):
            var s = self.core[].utree_nodes[i].seq
            if s > cur_seq and s < best_seq:
                best_seq = s
                best_id = i
        if best_id < 0:
            return (False, Pos(-1, -1))
        return self.undo_jump_to(best_id)

    def undo_tree_lines(self) -> List[String]:
        """Render lines of the buffer's non-linear undo tree for inspection/picker."""
        var out = List[String]()
        var act = self.core[].utree_active
        for i in range(len(self.core[].utree_nodes)):
            var prefix = "* " if i == act else "  "
            var line = (
                prefix
                + "["
                + String(self.core[].utree_nodes[i].id)
                + "] (seq "
                + String(self.core[].utree_nodes[i].seq)
                + "): "
                + self.core[].utree_nodes[i].desc
            )
            if self.core[].utree_nodes[i].parent >= 0:
                line += " <- [" + String(self.core[].utree_nodes[i].parent) + "]"
            var n_ch = len(self.core[].utree_nodes[i].children)
            if n_ch > 1:
                line += " [branch " + String(n_ch) + "]"
            out.append(line)
        return out^


@fieldwise_init
struct DiffSpan(Copyable, Movable):
    var prefix_len: Int
    var suffix_len: Int
    var del_text: List[Int]
    var ins_text: List[Int]


def compute_diff_span(old_text: List[Int], new_text: List[Int]) -> DiffSpan:
    """Find maximal common prefix and suffix, producing minimal replacement delta."""
    var n = len(old_text)
    var m = len(new_text)
    var p = 0
    while p < n and p < m and old_text[p] == new_text[p]:
        p += 1
    var s = 0
    while s < (n - p) and s < (m - p) and old_text[n - 1 - s] == new_text[m - 1 - s]:
        s += 1

    var del_slice = List[Int]()
    for i in range(p, n - s):
        del_slice.append(old_text[i])

    var ins_slice = List[Int]()
    for j in range(p, m - s):
        ins_slice.append(new_text[j])

    return DiffSpan(p, s, del_slice^, ins_slice^)


def replace_all_text_diff(mut b: TextBuffer, new_cps: List[Int], group: Int = 0) -> DiffSpan:
    """Replace buffer content with minimal diff span and compact undo record."""
    var cur = b.all_text()
    var diff = compute_diff_span(cur, new_cps)
    if len(diff.del_text) == 0 and len(diff.ins_text) == 0:
        return diff^

    # Map codepoint offset `p` to buffer row and col
    var r1 = 0
    var c1 = 0
    var r2 = 0
    var c2 = 0
    var row = 0
    var col = 0
    var limit = len(cur) - diff.suffix_len
    for k in range(limit + 1):
        if k == diff.prefix_len:
            r1 = row
            c1 = col
        if k == limit:
            r2 = row
            c2 = col
            break
        if k < len(cur):
            if cur[k] == 10:
                row += 1
                col = 0
            else:
                col += 1

    var grp = group if group != 0 else 10001
    if len(diff.del_text) > 0:
        _ = b.delete(r1, c1, r2, c2, r1, c1, grp)
    if len(diff.ins_text) > 0:
        _ = b.insert(r1, c1, diff.ins_text.copy(), r1, c1, grp)

    return diff^


@fieldwise_init
struct UndoNode(Copyable, Movable):
    var id: Int
    var parent: Int
    var children: List[Int]
    var seq: Int              # Chronological sequence number
    var text_snapshot: List[Int]
    var desc: String


struct UndoTreeArena(Copyable, Movable):
    var nodes: List[UndoNode]
    var active: Int
    var next_seq: Int

    def __init__(out self, initial_text: List[Int] = List[Int]()):
        self.nodes = List[UndoNode]()
        self.active = 0
        self.next_seq = 0
        var root = UndoNode(0, -1, List[Int](), 0, initial_text.copy(), "root")
        self.nodes.append(root^)

    def record_state(mut self, text: List[Int], desc: String) -> Int:
        """Create a new state node attached to current active state (branching if active has children)."""
        self.next_seq += 1
        var new_id = len(self.nodes)
        var node = UndoNode(new_id, self.active, List[Int](), self.next_seq, text.copy(), desc)
        self.nodes.append(node^)
        self.nodes[self.active].children.append(new_id)
        self.active = new_id
        return new_id

    def undo_branch(mut self, mut b: TextBuffer) -> Bool:
        """Move up to parent node in active branch."""
        if self.nodes[self.active].parent < 0:
            return False
        self.active = self.nodes[self.active].parent
        b.load(self.nodes[self.active].text_snapshot.copy())
        return True

    def redo_branch(mut self, mut b: TextBuffer, child_idx: Int = -1) -> Bool:
        """Move down to child node in active branch (defaults to latest child)."""
        var n_children = len(self.nodes[self.active].children)
        if n_children == 0:
            return False
        var target_child = self.nodes[self.active].children[n_children - 1]
        if child_idx >= 0 and child_idx < n_children:
            target_child = self.nodes[self.active].children[child_idx]
        self.active = target_child
        b.load(self.nodes[self.active].text_snapshot.copy())
        return True

    def vim_g_minus(mut self, mut b: TextBuffer) -> Bool:
        """Step back chronologically (by sequence number) across any branch."""
        var cur_seq = self.nodes[self.active].seq
        var target_id = -1
        var best_seq = -1
        for i in range(len(self.nodes)):
            var s = self.nodes[i].seq
            if s < cur_seq and s > best_seq:
                best_seq = s
                target_id = i
        if target_id >= 0:
            self.active = target_id
            b.load(self.nodes[target_id].text_snapshot.copy())
            return True
        return False

    def vim_g_plus(mut self, mut b: TextBuffer) -> Bool:
        """Step forward chronologically (by sequence number) across any branch."""
        var cur_seq = self.nodes[self.active].seq
        var target_id = -1
        var best_seq = 1000000000
        for i in range(len(self.nodes)):
            var s = self.nodes[i].seq
            if s > cur_seq and s < best_seq:
                best_seq = s
                target_id = i
        if target_id >= 0:
            self.active = target_id
            b.load(self.nodes[target_id].text_snapshot.copy())
            return True
        return False

    def render_visual_picker(self) -> String:
        """Render ASCII representation of the undo tree for interactive visual picker."""
        var out = String("")
        for i in range(len(self.nodes)):
            var prefix = "  "
            if i == self.active:
                prefix = "* "
            out += prefix + "[" + String(self.nodes[i].id) + "] (seq " + String(self.nodes[i].seq) + "): " + self.nodes[i].desc
            if len(self.nodes[i].children) > 1:
                out += " [branch " + String(len(self.nodes[i].children)) + "]"
            out += "\n"
        return out

    def jump_to_node(mut self, target_id: Int, mut b: TextBuffer) -> Bool:
        """Jump directly to any node in the arena."""
        if target_id < 0 or target_id >= len(self.nodes):
            return False
        self.active = target_id
        b.load(self.nodes[target_id].text_snapshot.copy())
        return True
