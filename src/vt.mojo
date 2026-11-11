"""Terminal emulation for the integrated terminal: libghostty-vt (Ghostty's terminal
core, MIT, from conda-forge) parses what a program writes - every CSI, SGR with 256
colours and truecolor, the alternate screen, scroll regions, cursor and keyboard modes,
wide characters, scrollback - and keeps the screen. This module feeds it and reads the
screen back as cells the IDE can draw.

The library is linked statically (`-Xlinker <prefix>/lib/libghostty-vt.a` on every
build, see pixi.toml and scripts/check.sh), so the IDE has no run-time dependency on it.

C calls follow the project rule of one signature per function: handles and the optional
allocator are passed as Int (an allocator of 0 means the default one), out-parameters
as buffers. The only option set is the reply callback: a program's questions (cursor
position, device attributes, mode queries) are answered by the library through
`vt_reply_c`, which writes "[terminal][length][bytes]" into a pipe kept at a fixed
descriptor; `vt_take_replies` reads them back, and the IDE passes each to the program of
that terminal.
"""
from std.ffi import external_call
from std.collections import List, Dict

comptime VT_REPLY_FD = 978          # the write end of the replies pipe
comptime VT_REPLY_READ_FD = 979     # its read end
comptime O_CLOEXEC = 0x80000

comptime VF_BOLD = 1
comptime VF_ITALIC = 2
comptime VF_FAINT = 4
comptime VF_BLINK = 8
comptime VF_INVERSE = 16
comptime VF_INVISIBLE = 32
comptime VF_STRIKE = 64
comptime VF_UNDERLINE = 0x700       # the underline style (any non-zero value underlines)

# data kinds of the library (see include/ghostty/vt/render.h, terminal.h, screen.h)
comptime RS_ROW_ITERATOR = 4
comptime RS_CURSOR_VISIBLE = 11
comptime RS_CURSOR_HAS_VALUE = 14
comptime RS_CURSOR_X = 15
comptime RS_CURSOR_Y = 16
comptime ROW_CELLS = 3
comptime CELL_RAW = 1
comptime CELL_STYLE = 2
comptime CELL_GRAPHEMES = 4
comptime CELL_BG = 5
comptime CELL_FG = 6
comptime CELL_WIDE = 3              # (ghostty_cell_get)
comptime TERM_ACTIVE_SCREEN = 6
comptime TERM_MOUSE_TRACKING = 11
comptime TERM_SCROLLBACK_ROWS = 15
comptime OPT_WRITE_PTY = 2


def vt_reply_c(term: Int, userdata: Int, data: UnsafePointer[UInt8, MutAnyOrigin], n: Int):
    """Called by the library inside a write when the program asked something. No IDE
    state is touched here: the answer goes into the replies pipe."""
    var head = List[Int](length=2, fill=0)
    head[0] = term
    head[1] = n
    _ = external_call["write", Int](Int32(VT_REPLY_FD), head.unsafe_ptr(), 16)
    _ = external_call["write", Int](Int32(VT_REPLY_FD), data, n)


def vt_replies_open() -> Bool:
    """The replies pipe, once per process (both ends non-blocking, closed on exec)."""
    if Int(external_call["fcntl", Int32](Int32(VT_REPLY_FD), Int32(1), Int32(0))) != -1:
        return True
    var fds = List[Int32](length=2, fill=0)
    if Int(external_call["pipe", Int32](fds.unsafe_ptr())) != 0:
        return False
    _ = external_call["dup3", Int32](fds[1], Int32(VT_REPLY_FD), Int32(O_CLOEXEC))
    _ = external_call["dup3", Int32](fds[0], Int32(VT_REPLY_READ_FD), Int32(O_CLOEXEC))
    _ = external_call["close", Int32](fds[0])
    _ = external_call["close", Int32](fds[1])
    for fd in [VT_REPLY_FD, VT_REPLY_READ_FD]:
        var fl = external_call["fcntl", Int32](Int32(fd), Int32(3), Int32(0))
        _ = external_call["fcntl", Int32](Int32(fd), Int32(4), fl | Int32(2048))
    return True


struct VtReply(Copyable, Movable):
    var term: Int
    var data: List[UInt8]

    def __init__(out self, term: Int, var data: List[UInt8]):
        self.term = term
        self.data = data^


def vt_take_replies() -> List[VtReply]:
    """The answers the library gave since the last call, in order."""
    var raw = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=0)
    while True:
        var r = external_call["read", Int](Int32(VT_REPLY_READ_FD), buf.unsafe_ptr(), Int(4096))
        if r <= 0:
            break
        for i in range(r):
            raw.append(buf[i])
    var out = List[VtReply]()
    var k = 0
    while k + 16 <= len(raw):
        var term = 0
        var n = 0
        for i in range(8):
            term |= Int(raw[k + i]) << (8 * i)
            n |= Int(raw[k + 8 + i]) << (8 * i)
        k += 16
        var d = List[UInt8]()
        for i in range(k, min(k + n, len(raw))):
            d.append(raw[i])
        k += n
        out.append(VtReply(term, d^))
    return out^


struct VtTerm(Movable):
    """One emulated terminal and the last picture of its screen."""
    var term: Int                   # library handles (0: none)
    var state: Int
    var rows_it: Int
    var cells_it: Int
    var cols: Int
    var rows: Int
    var cp: List[Int]               # per cell: the first codepoint (0: empty), -1 the tail of a wide one
    var extra: Dict[Int, List[Int]] # cells with more than one codepoint (combining marks, emoji)
    var fg: List[Int]               # 0xRRGGBB, -1: the default colour; palette colours as -2 - index
    var bg: List[Int]
    var flags: List[Int]            # VF_*
    var cursor_x: Int
    var cursor_y: Int
    var cursor_shown: Bool
    var alt_screen: Bool
    var mouse_tracking: Bool
    var scrollback: Int
    var palette: Dict[Int, Int]     # the library's default 256 colours -> index

    def __init__(out self):
        self.term = 0
        self.state = 0
        self.rows_it = 0
        self.cells_it = 0
        self.cols = 0
        self.rows = 0
        self.cp = List[Int]()
        self.extra = Dict[Int, List[Int]]()
        self.fg = List[Int]()
        self.bg = List[Int]()
        self.flags = List[Int]()
        self.cursor_x = 0
        self.cursor_y = 0
        self.cursor_shown = True
        self.alt_screen = False
        self.mouse_tracking = False
        self.scrollback = 0
        self.palette = Dict[Int, Int]()

    def __del__(deinit self):
        if self.term != 0:
            external_call["ghostty_render_state_row_cells_free", NoneType](self.cells_it)
            external_call["ghostty_render_state_row_iterator_free", NoneType](self.rows_it)
            external_call["ghostty_render_state_free", NoneType](self.state)
            external_call["ghostty_terminal_free", NoneType](self.term)

    def open(mut self, cols: Int, rows: Int) -> Bool:
        if self.term != 0 or cols < 1 or rows < 1:
            return False
        if not vt_replies_open():
            return False
        var h = List[Int](length=4, fill=0)
        if Int(external_call["ghostty_terminal_new", Int32](Int(0), h.unsafe_ptr(), UInt16(cols), UInt16(rows))) != 0:
            return False
        var s = List[Int](length=1, fill=0)
        var it = List[Int](length=1, fill=0)
        var c = List[Int](length=1, fill=0)
        if Int(external_call["ghostty_render_state_new", Int32](Int(0), s.unsafe_ptr())) != 0 or Int(external_call["ghostty_render_state_row_iterator_new", Int32](Int(0), it.unsafe_ptr())) != 0 or Int(external_call["ghostty_render_state_row_cells_new", Int32](Int(0), c.unsafe_ptr())) != 0:
            external_call["ghostty_terminal_free", NoneType](h[0])
            return False
        self.term = h[0]
        self.state = s[0]
        self.rows_it = it[0]
        self.cells_it = c[0]
        _ = external_call["ghostty_terminal_set", Int32](self.term, Int32(OPT_WRITE_PTY), vt_reply_c)
        # the library's default palette, to tell palette colours from free RGB ones
        var pal = List[UInt8](length=768, fill=0)
        external_call["ghostty_color_palette_default", NoneType](pal.unsafe_ptr())
        for i in range(255, -1, -1):
            self.palette[(Int(pal[3 * i]) << 16) | (Int(pal[3 * i + 1]) << 8) | Int(pal[3 * i + 2])] = i
        self.cols = cols
        self.rows = rows
        self.update()
        return True

    def is_open(self) -> Bool:
        return self.term != 0

    def write(mut self, data: List[UInt8]):
        """What the program wrote."""
        if self.term == 0 or len(data) == 0:
            return
        external_call["ghostty_terminal_vt_write", NoneType](self.term, data.unsafe_ptr(), len(data))

    def write_text(mut self, text: String):
        var b = List[UInt8]()
        for c in text.as_bytes():
            b.append(c)
        self.write(b)

    def resize(mut self, cols: Int, rows: Int):
        if self.term == 0 or cols < 1 or rows < 1 or (cols == self.cols and rows == self.rows):
            return
        _ = external_call["ghostty_terminal_resize", Int32](self.term, UInt16(cols), UInt16(rows), UInt32(8), UInt32(16))
        self.cols = cols
        self.rows = rows

    def color_of(self, rgb: Int) -> Int:
        """A colour as the cells keep it: palette entries by index (so that the IDE can
        use its own colours for them), other colours as they are."""
        var i = self.palette.get(rgb, -1)
        if i >= 0:
            return -2 - i
        return rgb

    def update(mut self):
        """Take a new picture of the screen."""
        if self.term == 0:
            return
        var n = self.cols * self.rows
        self.cp = List[Int](length=n, fill=0)
        self.fg = List[Int](length=n, fill=-1)
        self.bg = List[Int](length=n, fill=-1)
        self.flags = List[Int](length=n, fill=0)
        self.extra = Dict[Int, List[Int]]()
        _ = external_call["ghostty_render_state_update", Int32](self.state, self.term)
        var it = List[Int](length=1, fill=0)
        it[0] = self.rows_it
        _ = external_call["ghostty_render_state_get", Int32](self.state, Int32(RS_ROW_ITERATOR), it.unsafe_ptr())
        var cells = List[Int](length=1, fill=0)
        cells[0] = self.cells_it
        var cps = List[UInt32](length=16, fill=0)
        var cpbuf = List[Int](length=3, fill=0)
        var rgb = List[UInt8](length=4, fill=0)
        var style = List[UInt8](length=16, fill=0)
        var raw = List[UInt64](length=1, fill=0)
        var wide = List[UInt32](length=1, fill=0)
        var y = 0
        while y < self.rows and external_call["ghostty_render_state_row_iterator_next", Bool](self.rows_it):
            _ = external_call["ghostty_render_state_row_get", Int32](self.rows_it, Int32(ROW_CELLS), cells.unsafe_ptr())
            var x = 0
            while x < self.cols and external_call["ghostty_render_state_row_cells_next", Bool](self.cells_it):
                var k = y * self.cols + x
                cpbuf[0] = Int(cps.unsafe_ptr())
                cpbuf[1] = 16
                cpbuf[2] = 0
                _ = external_call["ghostty_render_state_row_cells_get", Int32](self.cells_it, Int32(CELL_GRAPHEMES), cpbuf.unsafe_ptr())
                if cpbuf[2] > 0:
                    self.cp[k] = Int(cps[0])
                    if cpbuf[2] > 1:
                        var more = List[Int]()
                        for j in range(min(cpbuf[2], 16)):
                            more.append(Int(cps[j]))
                        self.extra[k] = more^
                else:
                    _ = external_call["ghostty_render_state_row_cells_get", Int32](self.cells_it, Int32(CELL_RAW), raw.unsafe_ptr())
                    _ = external_call["ghostty_cell_get", Int32](raw[0], Int32(CELL_WIDE), wide.unsafe_ptr())
                    if Int(wide[0]) == 2:
                        self.cp[k] = -1             # the right half of a wide character
                if Int(external_call["ghostty_render_state_row_cells_get", Int32](self.cells_it, Int32(CELL_FG), rgb.unsafe_ptr())) == 0:
                    self.fg[k] = self.color_of((Int(rgb[0]) << 16) | (Int(rgb[1]) << 8) | Int(rgb[2]))
                if Int(external_call["ghostty_render_state_row_cells_get", Int32](self.cells_it, Int32(CELL_BG), rgb.unsafe_ptr())) == 0:
                    self.bg[k] = self.color_of((Int(rgb[0]) << 16) | (Int(rgb[1]) << 8) | Int(rgb[2]))
                if Int(external_call["ghostty_render_state_row_cells_get", Int32](self.cells_it, Int32(CELL_STYLE), style.unsafe_ptr())) == 0:
                    self.flags[k] = Int(style[12]) | (Int(style[13]) << 8)
                x += 1
            y += 1
        _ = cps[0]
        var b1 = List[UInt8](length=8, fill=0)
        self.cursor_shown = False
        if Int(external_call["ghostty_render_state_get", Int32](self.state, Int32(RS_CURSOR_HAS_VALUE), b1.unsafe_ptr())) == 0 and b1[0] != 0:
            var v = List[UInt16](length=4, fill=0)
            _ = external_call["ghostty_render_state_get", Int32](self.state, Int32(RS_CURSOR_X), v.unsafe_ptr())
            self.cursor_x = Int(v[0])
            _ = external_call["ghostty_render_state_get", Int32](self.state, Int32(RS_CURSOR_Y), v.unsafe_ptr())
            self.cursor_y = Int(v[0])
            b1[0] = 0
            _ = external_call["ghostty_render_state_get", Int32](self.state, Int32(RS_CURSOR_VISIBLE), b1.unsafe_ptr())
            self.cursor_shown = b1[0] != 0
        var w = List[UInt32](length=2, fill=0)
        if Int(external_call["ghostty_terminal_get", Int32](self.term, Int32(TERM_ACTIVE_SCREEN), w.unsafe_ptr())) == 0:
            self.alt_screen = Int(w[0]) != 0
        var m = List[UInt8](length=8, fill=0)
        if Int(external_call["ghostty_terminal_get", Int32](self.term, Int32(TERM_MOUSE_TRACKING), m.unsafe_ptr())) == 0:
            self.mouse_tracking = m[0] != 0
        var sb = List[Int](length=1, fill=0)
        if Int(external_call["ghostty_terminal_get", Int32](self.term, Int32(TERM_SCROLLBACK_ROWS), sb.unsafe_ptr())) == 0:
            self.scrollback = sb[0]

    def row_text(self, y: Int) -> String:
        """A line of the screen as text (trailing blanks removed)."""
        var cps = List[Int]()
        for x in range(self.cols):
            var k = y * self.cols + x
            var c = self.cp[k]
            if c == -1:
                continue
            if k in self.extra:
                try:
                    for e in self.extra[k]:
                        cps.append(e)
                except:
                    cps.append(c)
            else:
                cps.append(c if c > 0 else 32)
        var s = String("")
        for c in cps:
            s += chr(c)
        return String(s.rstrip())

    def text(self) -> String:
        var s = String("")
        for y in range(self.rows):
            s += self.row_text(y) + "\n"
        return s
