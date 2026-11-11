"""The bytes a key sends to a program in a terminal, as xterm sends them."""
from std.collections import List
from term import (
    K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB, KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
    KEY_HOME, KEY_END, KEY_PGUP, KEY_PGDN, KEY_INSERT, KEY_DELETE, KEY_F1, MOD_SHIFT, MOD_ALT,
    MOD_CTRL, KEY_MASK,
)


def put_str(mut out: List[UInt8], s: String):
    for b in s.as_bytes():
        out.append(b)


def put_cp(mut out: List[UInt8], c: Int):
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


def mod_param(k: Int) -> Int:
    """xterm's modifier parameter: 1 + Shift 1 + Alt 2 + Ctrl 4 (1 = none)."""
    var m = 1
    if k & MOD_SHIFT != 0:
        m += 1
    if k & MOD_ALT != 0:
        m += 2
    if k & MOD_CTRL != 0:
        m += 4
    return m


def encode_key(k: Int, app_cursor: Bool) -> List[UInt8]:
    """The bytes for key `k`; `app_cursor`: the program asked for application cursor
    keys (DECCKM), as full-screen programs do. Empty when the key sends nothing."""
    var out = List[UInt8]()
    var base = k & KEY_MASK
    var m = mod_param(k)
    if base < K_BASE:
        # a character
        if k & MOD_CTRL != 0:
            var c = base
            if c >= 97 and c <= 122:
                c -= 32
            if c >= 64 and c <= 95:
                if k & MOD_ALT != 0:
                    out.append(27)
                out.append(UInt8(c - 64))      # Ctrl-A = 1 ... Ctrl-_ = 31
                return out^
            if c == 32 or c == 50:
                out.append(0)                  # Ctrl-Space, Ctrl-2
                return out^
            if c == 63:
                out.append(127)
                return out^
        if k & MOD_ALT != 0:
            out.append(27)
        put_cp(out, base)
        return out^
    if base == KEY_ENTER:
        if k & MOD_ALT != 0:
            out.append(27)
        out.append(13)
        return out^
    if base == KEY_TAB:
        if k & MOD_SHIFT != 0:
            put_str(out, "\x1b[Z")
        else:
            out.append(9)
        return out^
    if base == KEY_BACKSPACE:
        if k & MOD_ALT != 0:
            out.append(27)
        out.append(UInt8(8) if k & MOD_CTRL != 0 else UInt8(127))
        return out^
    if base == KEY_ESC:
        out.append(27)
        return out^
    var letter = 0
    if base == KEY_UP:
        letter = 65
    elif base == KEY_DOWN:
        letter = 66
    elif base == KEY_RIGHT:
        letter = 67
    elif base == KEY_LEFT:
        letter = 68
    elif base == KEY_HOME:
        letter = 72
    elif base == KEY_END:
        letter = 70
    if letter != 0:
        if m > 1:
            put_str(out, "\x1b[1;" + String(m) + chr(letter))
        elif app_cursor:
            put_str(out, "\x1bO" + chr(letter))
        else:
            put_str(out, "\x1b[" + chr(letter))
        return out^
    var tilde = 0
    if base == KEY_INSERT:
        tilde = 2
    elif base == KEY_DELETE:
        tilde = 3
    elif base == KEY_PGUP:
        tilde = 5
    elif base == KEY_PGDN:
        tilde = 6
    if base >= KEY_F1 and base < KEY_F1 + 12:
        var n = base - KEY_F1 + 1
        if n <= 4:
            var fl = chr(80 + n - 1)            # F1-F4: SS3 P Q R S
            if m > 1:
                put_str(out, "\x1b[1;" + String(m) + fl)
            else:
                put_str(out, "\x1bO" + fl)
            return out^
        var codes = [15, 17, 18, 19, 20, 21, 23, 24]
        tilde = codes[n - 5]
    if tilde != 0:
        if m > 1:
            put_str(out, "\x1b[" + String(tilde) + ";" + String(m) + "~")
        else:
            put_str(out, "\x1b[" + String(tilde) + "~")
        return out^
    return out^


def paste_bytes(text: List[Int], bracketed: Bool) -> List[UInt8]:
    """Pasted text for a program; with bracketed paste (mode 2004) it is marked so that
    the program does not take it for typing. Line ends are sent as Enter (CR)."""
    var out = List[UInt8]()
    if bracketed:
        put_str(out, "\x1b[200~")
    var k = 0
    while k < len(text):
        var c = text[k]
        if c == 13 and k + 1 < len(text) and text[k + 1] == 10:
            k += 1
            c = 10
        if c == 10:
            out.append(13)
        elif not (bracketed and c == 27):      # an ESC inside could end the paste early
            put_cp(out, c)
        k += 1
    if bracketed:
        put_str(out, "\x1b[201~")
    return out^
