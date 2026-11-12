"""Raw terminal I/O: termios, window size, key + SGR mouse + bracketed paste parsing."""
from platform import raw_termios, TIOCGWINSZ, TCSAFLUSH
from std.ffi import external_call
from std.collections import List
from std.time import perf_counter_ns
from util import decode_list, append_str, env_or
from crash import CrashGuard
from caps import Caps, CAPS_QUERY, detect_color_level, detect_styled_underline

comptime K_BASE = 0x110000
comptime KEY_ESC = K_BASE + 1
comptime KEY_ENTER = K_BASE + 2
comptime KEY_TAB = K_BASE + 3
comptime KEY_BACKSPACE = K_BASE + 4
comptime KEY_UP = K_BASE + 5
comptime KEY_DOWN = K_BASE + 6
comptime KEY_LEFT = K_BASE + 7
comptime KEY_RIGHT = K_BASE + 8
comptime KEY_HOME = K_BASE + 9
comptime KEY_END = K_BASE + 10
comptime KEY_PGUP = K_BASE + 11
comptime KEY_PGDN = K_BASE + 12
comptime KEY_INSERT = K_BASE + 13
comptime KEY_DELETE = K_BASE + 14
comptime KEY_F1 = K_BASE + 21  # F1..F12 are consecutive

comptime MOD_SHIFT = 1 << 24
comptime MOD_ALT = 1 << 25
comptime MOD_CTRL = 1 << 26
comptime KEY_MASK = (1 << 24) - 1

comptime EV_KEY = 1
comptime EV_MOUSE = 2
comptime EV_PASTE = 3

comptime MB_LEFT = 0
comptime MB_RIGHT = 2
comptime MB_WHEEL_UP = 64
comptime MB_WHEEL_DOWN = 65


def fkey(n: Int) -> Int:
    return KEY_F1 + n - 1


def ctrl(c: Int) -> Int:
    return MOD_CTRL | c


def alt(c: Int) -> Int:
    return MOD_ALT | c


@fieldwise_init
struct Event(Copyable, Movable):
    var kind: Int
    var key: Int
    var mx: Int
    var my: Int
    var button: Int
    var pressed: Bool
    var drag: Bool
    var text: List[Int]


def key_event(k: Int) -> Event:
    return Event(EV_KEY, k, 0, 0, 0, False, False, List[Int]())


comptime ESC_TIMEOUT_MS = 25
comptime KITTY_PUSH = "\x1b[>1u"     # push keyboard flags: 1 = disambiguate escape codes
comptime KITTY_POP = "\x1b[<u"


def is_terminal() -> Bool:
    """True when both input and output are attached to a terminal."""
    return Int(external_call["isatty", Int32](Int32(0))) == 1 and Int(external_call["isatty", Int32](Int32(1))) == 1


def wait_readable(fds: List[Int], timeout_ms: Int) -> Int:
    """Sleep in poll() until one of `fds` is readable or the timeout passes.

    timeout_ms < 0 waits forever. Returns a bit mask: bit i is set when fds[i] is readable
    (or closed/in error, so the caller's read will notice). 0 means the timeout expired."""
    # struct pollfd { int fd; short events; short revents; } -> two Int32 per entry
    var n = len(fds)
    var pf = List[Int32](length=2 * n, fill=0)
    for i in range(n):
        pf[2 * i] = Int32(fds[i])
        pf[2 * i + 1] = Int32(1)  # events = POLLIN, revents = 0
    var t = timeout_ms if timeout_ms < 0 else max(0, timeout_ms)
    var r = external_call["poll", Int32](pf.unsafe_ptr(), UInt64(n), Int32(t))
    var mask = 0
    if Int(r) <= 0:
        return mask
    for i in range(n):
        var revents = (Int(pf[2 * i + 1]) >> 16) & 0xFFFF
        if revents != 0:
            mask |= 1 << i
    return mask


def get_u32(b: List[UInt8], off: Int) -> Int:
    return Int(b[off]) | (Int(b[off + 1]) << 8) | (Int(b[off + 2]) << 16) | (Int(b[off + 3]) << 24)


def set_u32(mut b: List[UInt8], off: Int, v: Int):
    b[off] = UInt8(v & 0xFF)
    b[off + 1] = UInt8((v >> 8) & 0xFF)
    b[off + 2] = UInt8((v >> 16) & 0xFF)
    b[off + 3] = UInt8((v >> 24) & 0xFF)


struct Terminal(Movable):
    var saved: List[UInt8]
    var have_saved: Bool
    var inbuf: List[UInt8]
    var out: List[UInt8]
    var in_paste: Bool
    var paste: List[UInt8]
    var last_input_ns: Int
    var guard: CrashGuard
    var caps: Caps
    var early: List[Event]     # input that arrived while probing the terminal
    var crash_log: String      # set before enter() to enable the crash guard
    var crash_header: String
    var grapheme_on: Bool
    var kitty_on: Bool        # kitty keyboard protocol flags are pushed
    var event_type: Int       # of the sequence being parsed: 0/1 press, 2 repeat, 3 release
    var scheme: Int           # the terminal's colour scheme (mode 2031): 0 unknown, 1 dark, 2 light

    def __init__(out self):
        self.saved = List[UInt8](length=128, fill=0)
        self.have_saved = False
        self.inbuf = List[UInt8]()
        self.out = List[UInt8]()
        self.in_paste = False
        self.paste = List[UInt8]()
        self.last_input_ns = 0
        self.guard = CrashGuard()
        self.caps = Caps()
        self.early = List[Event]()
        self.crash_log = ""
        self.crash_header = ""
        self.grapheme_on = False
        self.kitty_on = False
        self.event_type = 0
        self.scheme = 0

    # ------------------------------------------------------------- modes
    def raw(mut self):
        if Int(external_call["tcgetattr", Int32](Int32(0), self.saved.unsafe_ptr())) == 0:
            self.have_saved = True
        var t = raw_termios(self.saved)   # (the layout and flags of this system: platform.mojo)
        _ = external_call["tcsetattr", Int32](Int32(0), Int32(TCSAFLUSH), t.unsafe_ptr())

    def cooked(mut self):
        if self.have_saved:
            _ = external_call["tcsetattr", Int32](Int32(0), Int32(TCSAFLUSH), self.saved.unsafe_ptr())

    def enter(mut self):
        self.raw()
        if not self.guard.installed and self.crash_log.byte_length() > 0 and self.have_saved:
            _ = self.guard.install(self.saved, self.crash_log, self.crash_header)
        self.guard.set_tui(True)
        append_str(
            self.out,
            "\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[?25l\x1b[H\x1b[2J",
        )
        if self.grapheme_on:
            append_str(self.out, "\x1b[?2027h")
        if self.kitty_on:
            append_str(self.out, KITTY_PUSH)
        # tell us when the terminal turns light or dark, and ask what it is now
        append_str(self.out, "\x1b[?2031h\x1b[?996n")
        self.flush()

    def set_kitty(mut self, on: Bool):
        """Ask for unambiguous key reports (kitty keyboard protocol, "disambiguate" flag):
        Esc, Ctrl-I / Tab, Ctrl-M / Enter, Ctrl-Shift-letter and friends become distinct.
        The terminal keeps one flag stack per screen, so this is pushed after entering
        the alternate screen and popped before leaving it."""
        if on == self.kitty_on:
            return
        self.kitty_on = on
        append_str(self.out, KITTY_PUSH if on else KITTY_POP)

    def set_grapheme(mut self, on: Bool):
        """Turn the terminal's grapheme clustering (mode 2027) on or off. With it on the
        terminal draws a whole cluster as one glyph of a predictable width."""
        self.grapheme_on = on
        append_str(self.out, "\x1b[?2027h" if on else "\x1b[?2027l")

    def leave(mut self):
        if self.kitty_on:
            append_str(self.out, KITTY_POP)
        if self.grapheme_on:
            append_str(self.out, "\x1b[?2027l")
        append_str(self.out, "\x1b[?2031l")
        append_str(
            self.out,
            "\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[0 q\x1b[?25h\x1b[?1049l",
        )
        self.flush()
        self.cooked()
        self.guard.set_tui(False)

    def probe(mut self, timeout_ms: Int) -> Caps:
        """Ask the terminal what it supports. Waits until it answers the final request
        or the timeout passes (a terminal that answers nothing costs one timeout)."""
        self.caps.color = detect_color_level(env_or("COLORTERM", ""), env_or("TERM", ""), env_or("TURBOMOJO_COLORS", ""))
        self.caps.styled_underline = detect_styled_underline(
            env_or("TERM", ""), env_or("TERM_PROGRAM", ""), env_or("VTE_VERSION", ""), env_or("TURBOMOJO_UNDERLINE", "")
        )
        if not is_terminal():
            return self.caps.copy()     # nobody there to answer
        append_str(self.out, CAPS_QUERY)
        self.flush()
        var deadline = Int(perf_counter_ns()) + timeout_ms * 1000000
        var fds = List[Int]()
        fds.append(0)
        while not self.caps.answered:
            var left = (deadline - Int(perf_counter_ns())) // 1000000
            if left <= 0:
                break
            if wait_readable(fds, left) == 0:
                break
            for e in self.poll():
                self.early.append(e.copy())
        return self.caps.copy()

    def take_early(mut self) -> List[Event]:
        var out = List[Event]()
        for e in self.early:
            out.append(e.copy())
        self.early.clear()
        return out^

    def size(self) -> Tuple[Int, Int]:
        var ws = List[UInt16](length=4, fill=0)
        var r = external_call["ioctl", Int32](Int32(1), UInt64(TIOCGWINSZ), ws.unsafe_ptr())
        if Int(r) != 0 or Int(ws[1]) == 0:
            return (80, 25)
        return (Int(ws[1]), Int(ws[0]))

    def flush(mut self):
        var off = 0
        var n = len(self.out)
        while off < n:
            var w = external_call["write", Int](Int32(1), self.out.unsafe_ptr().unsafe_offset(off), n - off)
            if w <= 0:
                break
            off += w
        self.out.clear()

    def wait_byte(mut self):
        """Block until any input byte arrives (used by the user screen)."""
        var tmp = List[UInt8](length=64, fill=0)
        var fds = List[Int]()
        fds.append(0)
        while True:
            _ = wait_readable(fds, -1)
            var n = external_call["read", Int](Int32(0), tmp.unsafe_ptr(), Int(64))
            if n > 0:
                return

    # ------------------------------------------------------------- input
    def pending(self) -> Bool:
        """True while an incomplete sequence (e.g. a lone ESC) waits for more bytes."""
        return len(self.inbuf) > 0

    def poll(mut self) -> List[Event]:
        """Read whatever the terminal has sent (never blocks) and parse it.

        An incomplete sequence is only resolved once ESC_TIMEOUT_MS has passed without
        new bytes, so a sequence split across reads is not mistaken for a lone Esc."""
        var tmp = List[UInt8](length=4096, fill=0)
        var n = external_call["read", Int](Int32(0), tmp.unsafe_ptr(), Int(4096))
        var data = List[UInt8]()
        for i in range(n):
            data.append(tmp[i])
        var now = Int(perf_counter_ns())
        if n > 0:
            self.last_input_ns = now
        var stale = n <= 0 and now - self.last_input_ns >= ESC_TIMEOUT_MS * 1000000
        return self.feed(data, stale)

    def feed(mut self, data: List[UInt8], stale: Bool) -> List[Event]:
        """Parse input bytes into events. Needs no terminal, so tests can drive it.

        `stale` means no new bytes arrived for a while: an incomplete sequence still
        waiting in the buffer (such as a lone ESC) is then resolved instead of kept."""
        for b in data:
            self.inbuf.append(b)
        var evs = List[Event]()
        var i = 0
        while i < len(self.inbuf):
            var used = self.parse_one(i, evs, stale)
            if used == 0:
                break
            i += used
        if i > 0:
            var rest = List[UInt8]()
            for k in range(i, len(self.inbuf)):
                rest.append(self.inbuf[k])
            self.inbuf = rest^
        return evs^

    def plain_len(self, i: Int) -> Int:
        var c = Int(self.inbuf[i])
        if c < 0x80:
            return 1
        if c >= 0xF0:
            return 4
        if c >= 0xE0:
            return 3
        if c >= 0xC0:
            return 2
        return 1

    def plain_key(self, i: Int, l: Int) -> Int:
        var c = Int(self.inbuf[i])
        if l > 1:
            var b = List[UInt8]()
            for k in range(l):
                b.append(self.inbuf[i + k])
            var cps = decode_list(b)
            return cps[0] if len(cps) > 0 else 0xFFFD
        if c == 13 or c == 10:
            return KEY_ENTER
        if c == 9:
            return KEY_TAB
        if c == 127 or c == 8:
            return KEY_BACKSPACE
        if c == 0:
            return ctrl(32)
        if c >= 1 and c <= 26:
            return ctrl(96 + c)
        if c == 0x1F:
            return ctrl(47)
        if c == 0x1D:
            return ctrl(93)
        if c == 0x1C:
            return ctrl(92)
        return c

    def parse_one(mut self, i: Int, mut evs: List[Event], stale: Bool) -> Int:
        var n = len(self.inbuf)
        if self.in_paste:
            var j = i
            while j + 5 < n:
                if (
                    self.inbuf[j] == 27 and self.inbuf[j + 1] == 91 and self.inbuf[j + 2] == 50
                    and self.inbuf[j + 3] == 48 and self.inbuf[j + 4] == 49 and self.inbuf[j + 5] == 126
                ):
                    for k in range(i, j):
                        self.paste.append(self.inbuf[k])
                    self.in_paste = False
                    var cps = decode_list(self.paste)
                    self.paste.clear()
                    evs.append(Event(EV_PASTE, 0, 0, 0, 0, False, False, cps^))
                    return j + 6 - i
                j += 1
            # No terminator yet: take the text, but keep back any tail that could be
            # the start of the terminator (ESC [ 2 0 1 ~) arriving split across reads.
            var term = List[UInt8]()
            for tb in [27, 91, 50, 48, 49, 126]:
                term.append(UInt8(tb))
            var keep = min(5, n - i)
            while keep > 0:
                var is_prefix = True
                for q in range(keep):
                    if self.inbuf[n - keep + q] != term[q]:
                        is_prefix = False
                        break
                if is_prefix:
                    break
                keep -= 1
            var upto = n - keep
            for k in range(i, upto):
                self.paste.append(self.inbuf[k])
            return upto - i
        var c = Int(self.inbuf[i])
        if c == 27:
            if i + 1 >= n:
                if stale:
                    evs.append(key_event(KEY_ESC))
                    return 1
                return 0
            var d = Int(self.inbuf[i + 1])
            if d == 91:
                var j = i + 2
                while j < n and not (Int(self.inbuf[j]) >= 0x40 and Int(self.inbuf[j]) <= 0x7E):
                    j += 1
                if j >= n:
                    if stale:
                        evs.append(key_event(KEY_ESC))
                        return 1
                    return 0
                var final = Int(self.inbuf[j])
                # a leading < = > ? marks a private sequence: "<" is SGR mouse, "?" a reply
                var marker = 0
                if j > i + 2 and Int(self.inbuf[i + 2]) >= 60 and Int(self.inbuf[i + 2]) <= 63:
                    marker = Int(self.inbuf[i + 2])
                var private = marker == 60
                var params = List[Int]()
                var cur = 0
                var have = False
                # "a:b:c" sub-parameters (kitty keyboard protocol): the first value is the
                # parameter; of the rest only the second parameter's first sub-value is
                # kept: the event type (1 press, 2 repeat, 3 release)
                var in_sub = 0
                var sub = 0
                var event_type = 0
                var start = i + 3 if marker != 0 else i + 2
                for k in range(start, j):
                    var b = Int(self.inbuf[k])
                    if b >= 48 and b <= 57:
                        if in_sub == 0:
                            cur = cur * 10 + (b - 48)
                            have = True
                        elif in_sub == 1:
                            sub = sub * 10 + (b - 48)
                    elif b == 58:
                        in_sub += 1
                    elif b == 59:
                        if len(params) == 1 and in_sub >= 1:
                            event_type = sub
                        params.append(cur)
                        cur = 0
                        have = False
                        in_sub = 0
                        sub = 0
                if have or in_sub > 0:
                    if len(params) == 1 and in_sub >= 1:
                        event_type = sub
                    params.append(cur)
                self.event_type = event_type
                if private and (final == 77 or final == 109):
                    if len(params) >= 3:
                        var b = params[0]
                        var btn = b & 3
                        if b & 64 != 0:
                            btn = MB_WHEEL_UP + (b & 1)
                        # modifier keys held during the click travel in `key`
                        var mmods = 0
                        if b & 4 != 0:
                            mmods |= MOD_SHIFT
                        if b & 8 != 0:
                            mmods |= MOD_ALT
                        if b & 16 != 0:
                            mmods |= MOD_CTRL
                        evs.append(
                            Event(EV_MOUSE, mmods, params[1] - 1, params[2] - 1, btn, final == 77, (b & 32) != 0, List[Int]())
                        )
                    return j - i + 1
                if marker == 63:
                    self.terminal_reply(final, params)
                elif marker == 0:
                    self.csi(final, params, evs)
                return j - i + 1
            if d == 79:
                if i + 2 >= n:
                    if stale:
                        evs.append(key_event(alt(111)))
                        return 2
                    return 0
                var f = Int(self.inbuf[i + 2])
                var k = 0
                if f == 80:
                    k = fkey(1)
                elif f == 81:
                    k = fkey(2)
                elif f == 82:
                    k = fkey(3)
                elif f == 83:
                    k = fkey(4)
                elif f == 65:
                    k = KEY_UP
                elif f == 66:
                    k = KEY_DOWN
                elif f == 67:
                    k = KEY_RIGHT
                elif f == 68:
                    k = KEY_LEFT
                elif f == 72:
                    k = KEY_HOME
                elif f == 70:
                    k = KEY_END
                if k != 0:
                    evs.append(key_event(k))
                return 3
            if d == 27:
                evs.append(key_event(KEY_ESC))
                return 1
            var l = self.plain_len(i + 1)
            if i + 1 + l > n:
                return 0
            var k = self.plain_key(i + 1, l)
            if k >= 65 and k <= 90:
                k = k + 32
            evs.append(key_event(k | MOD_ALT))
            return 1 + l
        var l = self.plain_len(i)
        if i + l > n:
            if stale:
                return n - i
            return 0
        evs.append(key_event(self.plain_key(i, l)))
        return l

    def csi_u_key(self, p: Int) -> Int:
        """Key code for the number in a "CSI number ; modifiers u" report (0: ignore)."""
        if p == 13 or p == 57414:
            return KEY_ENTER
        if p == 9:
            return KEY_TAB
        if p == 27:
            return KEY_ESC
        if p == 127 or p == 8:
            return KEY_BACKSPACE
        if p >= 57399 and p <= 57408:
            return 48 + p - 57399       # keypad digits
        if p == 57409:
            return 46
        if p == 57410:
            return 47
        if p == 57411:
            return 42
        if p == 57412:
            return 45
        if p == 57413:
            return 43
        if p == 57415:
            return 61
        if p == 57417:
            return KEY_LEFT
        if p == 57418:
            return KEY_RIGHT
        if p == 57419:
            return KEY_UP
        if p == 57420:
            return KEY_DOWN
        if p == 57421:
            return KEY_PGUP
        if p == 57422:
            return KEY_PGDN
        if p == 57423:
            return KEY_HOME
        if p == 57424:
            return KEY_END
        if p == 57425:
            return KEY_INSERT
        if p == 57426:
            return KEY_DELETE
        if p < 32 or (p >= 57344 and p <= 63743):
            return 0                    # lock keys, modifier keys, media keys...
        return p

    def terminal_reply(mut self, final: Int, params: List[Int]):
        """Replies to our capability queries ("CSI ? ... final"). They produce no events."""
        if final == 121 and len(params) >= 2:       # DECRPM: CSI ? mode ; value $ y
            self.caps.mode_report(params[0], params[1])
        elif final == 117:                          # kitty keyboard: CSI ? flags u
            self.caps.kitty_keyboard = True
        elif final == 99:                           # DA1: CSI ? ... c
            self.caps.answered = True
        elif final == 110 and len(params) >= 2 and params[0] == 997:
            # the colour scheme (mode 2031; answer to CSI ? 996 n): 1 dark, 2 light
            self.scheme = params[1]

    def csi(mut self, final: Int, params: List[Int], mut evs: List[Event]):
        if self.event_type == 3:
            return                      # a key release: only presses and repeats matter
        var mods = 0
        if len(params) >= 2:
            var m = params[1] - 1
            if m & 1:
                mods |= MOD_SHIFT
            if m & 2:
                mods |= MOD_ALT
            if m & 4:
                mods |= MOD_CTRL
        var k = 0
        if final == 65:
            k = KEY_UP
        elif final == 66:
            k = KEY_DOWN
        elif final == 67:
            k = KEY_RIGHT
        elif final == 68:
            k = KEY_LEFT
        elif final == 72:
            k = KEY_HOME
        elif final == 70:
            k = KEY_END
        elif final == 80:
            k = fkey(1)
        elif final == 81:
            k = fkey(2)
        elif final == 82:
            k = fkey(3)
        elif final == 83:
            k = fkey(4)
        elif final == 90:
            k = KEY_TAB
            mods |= MOD_SHIFT
        elif final == 126 and len(params) > 0:
            var p = params[0]
            if p == 200:
                self.in_paste = True
                self.paste.clear()
                return
            if p == 1 or p == 7:
                k = KEY_HOME
            elif p == 2:
                k = KEY_INSERT
            elif p == 3:
                k = KEY_DELETE
            elif p == 4 or p == 8:
                k = KEY_END
            elif p == 5:
                k = KEY_PGUP
            elif p == 6:
                k = KEY_PGDN
            elif p >= 11 and p <= 15:
                k = fkey(p - 10)
            elif p >= 17 and p <= 21:
                k = fkey(p - 11)
            elif p == 23:
                k = fkey(11)
            elif p == 24:
                k = fkey(12)
        elif final == 117 and len(params) > 0:
            k = self.csi_u_key(params[0])
            if k >= 65 and k <= 90 and (mods & (MOD_CTRL | MOD_ALT)) != 0:
                k += 32                 # Ctrl-Shift-P is Ctrl+Shift+"p", as key names say
            elif k >= 97 and k <= 122 and mods == MOD_SHIFT:
                k -= 32                 # Shift alone just types the capital
                mods = 0
            elif k >= 32 and k < K_BASE and mods == MOD_SHIFT:
                mods = 0                # a shifted symbol arrives as the symbol itself
            elif (k == KEY_BACKSPACE or k == KEY_ESC) and mods == MOD_SHIFT:
                mods = 0                # Shift held while correcting a capital letter
            elif k == KEY_ENTER and (mods & MOD_ALT) == 0:
                mods = 0                # Shift-Enter and Ctrl-Enter are Enter, as before
        if k != 0:
            evs.append(key_event(k | mods))
