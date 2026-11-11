"""A terminal session: a program on a pty and the emulator keeping its screen (used by
the Terminal and Run windows, see app_terminal.mojo)."""
from std.collections import List
from pty import Pty
from vt import VtTerm


comptime TS_SHELL = 0        # the terminal the user opens (a shell)
comptime TS_RUN = 1          # the one Run uses


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


