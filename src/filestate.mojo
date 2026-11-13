"""What is remembered about a file between sessions: where the cursor was, how far it was
scrolled, which blocks were folded (version 2) and the undo history. One small text file per edited file, in the state directory. It is only used
again if the file on disk still has exactly the content the history belongs to (size and
a hash of its bytes), so an old history can never be applied to a changed file."""
from std.collections import List
from buffer import UndoRec
from util import decode, to_str

comptime STATE_SUFFIX = ".hist"
comptime STATE_MAGIC = "turbomojo-history 2"      # 2: the folds after the cursor
comptime STATE_MAGIC_1 = "turbomojo-history 1"    # still read: no folds
comptime STATE_MAX_FOLDS = 10000
comptime STATE_MAX_RECORDS = 5000       # the most recent undo steps kept
comptime STATE_MAX_CHARS = 2000000      # ...and the most text they may hold together


def content_hash(data: List[UInt8]) -> Int:
    """FNV-1a over the bytes, kept to 62 bits so it is a plain positive Int."""
    var h = 0x0BF29CE484222325
    for b in data:
        h = ((h ^ Int(b)) * 0x100000001B3) & 0x3FFFFFFFFFFFFFFF
    return h


def state_name(path: String) -> String:
    """File name of the history file for a path: "/" becomes "%", "%" is doubled."""
    var out = List[Int]()
    for c in decode(path):
        if c == 47:
            out.append(37)
        elif c == 37:
            out.append(37)
            out.append(37)
        else:
            out.append(c)
    return to_str(out) + STATE_SUFFIX


struct FileState(Movable):
    var ok: Bool
    var hash: Int
    var size: Int
    var cr: Int
    var cc: Int
    var top: Int
    var folds: List[Int]
    var undos: List[UndoRec]
    var redos: List[UndoRec]

    def __init__(out self):
        self.ok = False
        self.hash = 0
        self.size = 0
        self.cr = 0
        self.cc = 0
        self.top = 0
        self.folds = List[Int]()
        self.undos = List[UndoRec]()
        self.redos = List[UndoRec]()


def put_int(mut out: List[UInt8], v: Int):
    var s = String(v)
    for b in s.as_bytes():
        out.append(b)
    out.append(32)


def put_records(mut out: List[UInt8], tag: String, recs: List[UndoRec], first: Int):
    for b in tag.as_bytes():
        out.append(b)
    out.append(32)
    put_int(out, len(recs) - first)
    out.append(10)
    for i in range(first, len(recs)):
        put_int(out, recs[i].kind)
        put_int(out, recs[i].r)
        put_int(out, recs[i].c)
        put_int(out, recs[i].cr)
        put_int(out, recs[i].cc)
        put_int(out, recs[i].group)
        put_int(out, len(recs[i].text))
        for v in recs[i].text:
            put_int(out, v)
        out.append(10)


def state_encode(hash: Int, size: Int, cr: Int, cc: Int, top: Int, undos: List[UndoRec], redos: List[UndoRec], folds: List[Int] = List[Int]()) -> List[UInt8]:
    """The history file's content. Only the newest undo steps are kept when there are
    very many or they hold very much text; redo steps are dropped in that case."""
    var first = max(0, len(undos) - STATE_MAX_RECORDS)
    var chars = 0
    var i = len(undos) - 1
    while i >= first:
        chars += len(undos[i].text)
        if chars > STATE_MAX_CHARS:
            first = i + 1
            break
        i -= 1
    var keep_redo = first == 0
    if keep_redo:
        for r in redos:
            chars += len(r.text)
        keep_redo = chars <= STATE_MAX_CHARS and len(redos) <= STATE_MAX_RECORDS
    # an undo group must not be cut in half: start at a group boundary
    while first > 0 and first < len(undos) and undos[first].group != 0 and undos[first].group == undos[first - 1].group:
        first += 1
    var out = List[UInt8]()
    for b in STATE_MAGIC.as_bytes():
        out.append(b)
    out.append(10)
    put_int(out, hash)
    put_int(out, size)
    put_int(out, cr)
    put_int(out, cc)
    put_int(out, top)
    out.append(10)
    for b in "folds".as_bytes():
        out.append(b)
    out.append(32)
    var nf = min(len(folds), STATE_MAX_FOLDS)
    put_int(out, nf)
    for k in range(nf):
        put_int(out, folds[k])
    out.append(10)
    put_records(out, "undo", undos, first)
    if keep_redo:
        put_records(out, "redo", redos, 0)
    else:
        put_records(out, "redo", List[UndoRec](), 0)
    # a last word, so that a file cut short by a full disk or a crash is recognised
    for b in "end".as_bytes():
        out.append(b)
    out.append(10)
    return out^


struct Reader:
    var data: List[UInt8]
    var pos: Int
    var bad: Bool

    def __init__(out self, data: List[UInt8]):
        self.data = data.copy()
        self.pos = 0
        self.bad = False

    def word(mut self) -> String:
        """The next run of non-blank bytes ("" at the end)."""
        var n = len(self.data)
        while self.pos < n and (self.data[self.pos] == 32 or self.data[self.pos] == 10):
            self.pos += 1
        var out = List[Int]()
        while self.pos < n and self.data[self.pos] != 32 and self.data[self.pos] != 10:
            out.append(Int(self.data[self.pos]))
            self.pos += 1
        return to_str(out)

    def number(mut self) -> Int:
        var n = len(self.data)
        while self.pos < n and (self.data[self.pos] == 32 or self.data[self.pos] == 10):
            self.pos += 1
        var neg = False
        if self.pos < n and self.data[self.pos] == 45:
            neg = True
            self.pos += 1
        var v = 0
        var digits = 0
        while self.pos < n and self.data[self.pos] >= 48 and self.data[self.pos] <= 57:
            v = v * 10 + Int(self.data[self.pos]) - 48
            self.pos += 1
            digits += 1
            if digits > 19:
                self.bad = True
                return 0
        if digits == 0:
            self.bad = True
        return -v if neg else v

    def records(mut self, tag: String, mut out: List[UndoRec]):
        if self.word() != tag:
            self.bad = True
            return
        var count = self.number()
        if self.bad or count < 0 or count > STATE_MAX_RECORDS:
            self.bad = True
            return
        for _ in range(count):
            var kind = self.number()
            var r = self.number()
            var c = self.number()
            var cr = self.number()
            var cc = self.number()
            var group = self.number()
            var n = self.number()
            if self.bad or n < 0 or n > STATE_MAX_CHARS or (kind != 1 and kind != 2) or r < 0 or c < 0:
                self.bad = True
                return
            var text = List[Int]()
            for _ in range(n):
                var v = self.number()
                if self.bad or v < 0 or v > 0x10FFFF:
                    self.bad = True
                    return
                text.append(v)
            out.append(UndoRec(kind, r, c, text^, cr, cc, group))


def state_decode(data: List[UInt8]) -> FileState:
    """Parse a history file. Anything unexpected gives `.ok == False`: a damaged file is
    simply not used."""
    var st = FileState()
    var magic = STATE_MAGIC.as_bytes()
    if len(data) < len(magic) + 1:
        return st^
    var version = 2
    for i in range(len(magic)):
        if data[i] != magic[i]:
            version = 0
    if version == 0:
        var m1 = STATE_MAGIC_1.as_bytes()
        version = 1
        for i in range(len(m1)):
            if data[i] != m1[i]:
                return st^
    var rd = Reader(data)
    rd.pos = len(magic)
    st.hash = rd.number()
    st.size = rd.number()
    st.cr = rd.number()
    st.cc = rd.number()
    st.top = rd.number()
    if version >= 2 and not rd.bad:
        if rd.word() != "folds":
            rd.bad = True
        var nf = rd.number()
        if rd.bad or nf < 0 or nf > STATE_MAX_FOLDS:
            rd.bad = True
        else:
            for _ in range(nf):
                var r = rd.number()
                if rd.bad or r < 0:
                    rd.bad = True
                    break
                st.folds.append(r)
    rd.records("undo", st.undos)
    if not rd.bad:
        rd.records("redo", st.redos)
    if not rd.bad and rd.word() != "end":
        rd.bad = True
    if rd.bad or st.cr < 0 or st.cc < 0 or st.top < 0:
        st.undos.clear()
        st.redos.clear()
        st.folds.clear()
        return st^
    st.ok = True
    return st^
