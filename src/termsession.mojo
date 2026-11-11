"""A terminal session: a program on a pty and the emulator keeping its screen (used by
the Terminal and Run windows, see app_terminal.mojo)."""
from std.collections import List
from pty import Pty
from vt import VtTerm


comptime TS_SHELL = 0        # the terminal the user opens (a shell)
comptime TS_RUN = 1          # the one Run uses
comptime TS_REPL = 2         # the Mojo REPL


struct TermSession(Movable):
    """A program on a pty and the emulator that keeps its screen."""
    var pty: Pty
    var vt: VtTerm
    var title: String
    var started: Bool
    var ended_note: String          # shown after the program has ended ('' while it runs)
    var dirty: Bool                 # output arrived since the last picture
    var sel_on: Bool                # a mouse selection (screen cells, as shown)
    var sel_a: Int
    var sel_b: Int
    var pty_argv: List[String]      # what was started, to start it again
    var pty_cwd: String
    var pending: List[UInt8]        # to write once the program shows its first prompt
    var last_output_ns: Int

    def __init__(out self):
        self.pty = Pty()
        self.vt = VtTerm()
        self.title = ""
        self.started = False
        self.ended_note = ""
        self.dirty = False
        self.sel_on = False
        self.sel_a = 0
        self.sel_b = 0
        self.pty_argv = List[String]()
        self.pty_cwd = ""
        self.pending = List[UInt8]()
        self.last_output_ns = 0


def ansi_color(i: Int) -> Int:
    """The xterm colour of a 256-colour palette index, as 0xRRGGBB."""
    var base = [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
    if i < 16:
        return base[max(0, i)]
    if i < 232:
        var n = i - 16
        var steps = [0, 95, 135, 175, 215, 255]
        return (steps[n // 36] << 16) | (steps[(n // 6) % 6] << 8) | steps[n % 6]
    var g = 8 + 10 * (i - 232)
    return (g << 16) | (g << 8) | g




def repl_bytes(text: List[Int]) -> List[UInt8]:
    """Code for the REPL as typed: lines ended by CR, trailing blank lines dropped, then
    one empty line - the REPL evaluates what came before a blank line."""
    var lines = List[List[Int]]()
    var cur = List[Int]()
    for c in text:
        if c == 10:
            lines.append(cur^)
            cur = List[Int]()
        elif c != 13:
            cur.append(c)
    lines.append(cur^)
    while len(lines) > 0 and len(lines[len(lines) - 1]) == 0:
        _ = lines.pop()
    var out = List[UInt8]()
    for l in lines:
        if len(l) == 0:
            continue        # a blank line inside would end the expression early
        for c in l:
            if c < 0x80:
                out.append(UInt8(c))
            elif c < 0x800:
                out.append(UInt8(0xC0 | (c >> 6)))
                out.append(UInt8(0x80 | (c & 63)))
            elif c < 0x10000:
                out.append(UInt8(0xE0 | (c >> 12)))
                out.append(UInt8(0x80 | ((c >> 6) & 63)))
                out.append(UInt8(0x80 | (c & 63)))
            else:
                out.append(UInt8(0xF0 | (c >> 18)))
                out.append(UInt8(0x80 | ((c >> 12) & 63)))
                out.append(UInt8(0x80 | ((c >> 6) & 63)))
                out.append(UInt8(0x80 | (c & 63)))
        out.append(13)
    if len(out) > 0:
        out.append(13)
    return out^
