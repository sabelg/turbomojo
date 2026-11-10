"""Raw terminal I/O: termios, window size, key + SGR mouse + bracketed paste parsing."""
from std.ffi import external_call
from std.collections import List
from util import decode_list, append_str

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

    def __init__(out self):
        self.saved = List[UInt8](length=128, fill=0)
        self.have_saved = False
        self.inbuf = List[UInt8]()
        self.out = List[UInt8]()
        self.in_paste = False
        self.paste = List[UInt8]()

    # ------------------------------------------------------------- modes
    def raw(mut self):
        if Int(external_call["tcgetattr", Int32](Int32(0), self.saved.unsafe_ptr())) == 0:
            self.have_saved = True
        var t = self.saved.copy()
        # iflag: BRKINT | ICRNL | INPCK | ISTRIP | IXON
        set_u32(t, 0, get_u32(t, 0) & ~(0x2 | 0x100 | 0x10 | 0x20 | 0x400))
        # oflag: OPOST
        set_u32(t, 4, get_u32(t, 4) & ~0x1)
        # cflag: CS8
        set_u32(t, 8, get_u32(t, 8) | 0x30)
        # lflag: ECHO | ICANON | IEXTEN | ISIG
        set_u32(t, 12, get_u32(t, 12) & ~(0x8 | 0x2 | 0x8000 | 0x1))
        t[17 + 6] = 0  # VMIN
        t[17 + 5] = 1  # VTIME (1/10 s) -> periodic wakeups for the clock
        _ = external_call["tcsetattr", Int32](Int32(0), Int32(2), t.unsafe_ptr())

    def cooked(mut self):
        if self.have_saved:
            _ = external_call["tcsetattr", Int32](Int32(0), Int32(2), self.saved.unsafe_ptr())

    def enter(mut self):
        self.raw()
        append_str(
            self.out,
            "\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[?25l\x1b[H\x1b[2J",
        )
        self.flush()

    def leave(mut self):
        append_str(
            self.out,
            "\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[0 q\x1b[?25h\x1b[?1049l",
        )
        self.flush()
        self.cooked()

    def size(self) -> Tuple[Int, Int]:
        var ws = List[UInt16](length=4, fill=0)
        var r = external_call["ioctl", Int32](Int32(1), UInt64(0x5413), ws.unsafe_ptr())
        if Int(r) != 0 or Int(ws[1]) == 0:
            return (80, 25)
        return (Int(ws[1]), Int(ws[0]))

    def flush(mut self):
        var off = 0
        var n = len(self.out)
        while off < n:
            var w = external_call["write", Int](Int(1), self.out.unsafe_ptr().unsafe_offset(off), n - off)
            if w <= 0:
                break
            off += w
        self.out.clear()

    def wait_byte(mut self):
        """Block until any input byte arrives (used by the user screen)."""
        var tmp = List[UInt8](length=64, fill=0)
        while True:
            var n = external_call["read", Int](Int(0), tmp.unsafe_ptr(), Int(64))
            if n > 0:
                return

    # ------------------------------------------------------------- input
    def poll(mut self) -> List[Event]:
        var tmp = List[UInt8](length=4096, fill=0)
        var n = external_call["read", Int](Int(0), tmp.unsafe_ptr(), Int(4096))
        for i in range(n):
            self.inbuf.append(tmp[i])
        var evs = List[Event]()
        var stale = n <= 0
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
            if stale or n - i > 64:
                var keep = 5 if not stale else 0
                var upto = max(i, n - keep)
                for k in range(i, upto):
                    self.paste.append(self.inbuf[k])
                if upto - i > 0:
                    return upto - i
            return 0
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
                var private = j > i + 2 and Int(self.inbuf[i + 2]) == 60
                var params = List[Int]()
                var cur = 0
                var have = False
                var start = i + 3 if private else i + 2
                for k in range(start, j):
                    var b = Int(self.inbuf[k])
                    if b >= 48 and b <= 57:
                        cur = cur * 10 + (b - 48)
                        have = True
                    elif b == 59:
                        params.append(cur)
                        cur = 0
                        have = False
                if have:
                    params.append(cur)
                if private and (final == 77 or final == 109):
                    if len(params) >= 3:
                        var b = params[0]
                        var btn = b & 3
                        if b & 64 != 0:
                            btn = MB_WHEEL_UP + (b & 1)
                        evs.append(
                            Event(EV_MOUSE, 0, params[1] - 1, params[2] - 1, btn, final == 77, (b & 32) != 0, List[Int]())
                        )
                    return j - i + 1
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

    def csi(mut self, final: Int, params: List[Int], mut evs: List[Event]):
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
            var p = params[0]
            if p == 13:
                k = KEY_ENTER
            elif p == 9:
                k = KEY_TAB
            elif p == 27:
                k = KEY_ESC
            elif p == 127:
                k = KEY_BACKSPACE
            else:
                k = p
                if (mods & MOD_SHIFT) != 0 and k >= 97 and k <= 122:
                    k -= 32
                    mods &= ~MOD_SHIFT
        if k != 0:
            evs.append(key_event(k | mods))
