"""Tests for the terminal input parser (src/term.mojo) driven through feed()."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, KEY_ESC, KEY_ENTER, KEY_TAB, KEY_BACKSPACE,
    KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP, KEY_PGDN, KEY_INSERT,
    KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, fkey, ctrl, alt, MB_LEFT, MB_RIGHT,
    MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from util import str_bytes, to_str


def raw(vals: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


def keys(s: String) -> List[Event]:
    var t = Terminal()
    return t.feed(str_bytes(s), False)


def one_key(s: String) raises -> Int:
    var evs = keys(s)
    assert_equal(len(evs), 1)
    assert_equal(evs[0].kind, EV_KEY)
    return evs[0].key


# ---------------------------------------------------------------- plain keys
def test_printable_and_sequence_of_keys() raises:
    assert_equal(one_key("a"), 97)
    var evs = keys("ab\x1b[A")
    assert_equal(len(evs), 3)
    assert_equal(evs[0].key, 97)
    assert_equal(evs[1].key, 98)
    assert_equal(evs[2].key, KEY_UP)


def test_control_bytes() raises:
    var t = Terminal()
    var evs = t.feed(raw([13, 9, 127, 8, 1, 19, 0, 0x1F, 0x1D]), False)
    assert_equal(len(evs), 9)
    assert_equal(evs[0].key, KEY_ENTER)
    assert_equal(evs[1].key, KEY_TAB)
    assert_equal(evs[2].key, KEY_BACKSPACE)
    assert_equal(evs[3].key, KEY_BACKSPACE)
    assert_equal(evs[4].key, ctrl(97))    # Ctrl-A
    assert_equal(evs[5].key, ctrl(115))   # Ctrl-S
    assert_equal(evs[6].key, ctrl(32))    # Ctrl-Space
    assert_equal(evs[7].key, ctrl(47))    # Ctrl-/
    assert_equal(evs[8].key, ctrl(93))    # Ctrl-]


def test_utf8_keys() raises:
    assert_equal(one_key("é"), 0xE9)
    assert_equal(one_key("日"), 0x65E5)
    assert_equal(one_key("🔥"), 0x1F525)


def test_utf8_split_across_reads() raises:
    var t = Terminal()
    var b = str_bytes("日")
    var first = List[UInt8]()
    first.append(b[0])
    var rest = List[UInt8]()
    rest.append(b[1])
    rest.append(b[2])
    assert_equal(len(t.feed(first, False)), 0)
    var evs = t.feed(rest, False)
    assert_equal(len(evs), 1)
    assert_equal(evs[0].key, 0x65E5)


# ---------------------------------------------------------------- cursor keys
def test_arrows_and_modifiers() raises:
    assert_equal(one_key("\x1b[A"), KEY_UP)
    assert_equal(one_key("\x1b[B"), KEY_DOWN)
    assert_equal(one_key("\x1b[C"), KEY_RIGHT)
    assert_equal(one_key("\x1b[D"), KEY_LEFT)
    assert_equal(one_key("\x1b[1;2A"), KEY_UP | MOD_SHIFT)
    assert_equal(one_key("\x1b[1;3D"), KEY_LEFT | MOD_ALT)
    assert_equal(one_key("\x1b[1;5C"), KEY_RIGHT | MOD_CTRL)
    assert_equal(one_key("\x1b[1;6B"), KEY_DOWN | MOD_CTRL | MOD_SHIFT)
    # application cursor mode (SS3)
    assert_equal(one_key("\x1bOA"), KEY_UP)


def test_navigation_keys() raises:
    assert_equal(one_key("\x1b[H"), KEY_HOME)
    assert_equal(one_key("\x1b[F"), KEY_END)
    assert_equal(one_key("\x1b[1~"), KEY_HOME)
    assert_equal(one_key("\x1b[4~"), KEY_END)
    assert_equal(one_key("\x1b[5~"), KEY_PGUP)
    assert_equal(one_key("\x1b[6~"), KEY_PGDN)
    assert_equal(one_key("\x1b[2~"), KEY_INSERT)
    assert_equal(one_key("\x1b[3~"), KEY_DELETE)
    assert_equal(one_key("\x1b[3;5~"), KEY_DELETE | MOD_CTRL)
    assert_equal(one_key("\x1b[2;2~"), KEY_INSERT | MOD_SHIFT)
    assert_equal(one_key("\x1b[1;5H"), KEY_HOME | MOD_CTRL)
    assert_equal(one_key("\x1b[1;2F"), KEY_END | MOD_SHIFT)
    assert_equal(one_key("\x1b[Z"), KEY_TAB | MOD_SHIFT)


def test_function_keys() raises:
    assert_equal(one_key("\x1bOP"), fkey(1))
    assert_equal(one_key("\x1bOQ"), fkey(2))
    assert_equal(one_key("\x1bOR"), fkey(3))
    assert_equal(one_key("\x1bOS"), fkey(4))
    assert_equal(one_key("\x1b[15~"), fkey(5))
    assert_equal(one_key("\x1b[17~"), fkey(6))
    assert_equal(one_key("\x1b[18~"), fkey(7))
    assert_equal(one_key("\x1b[19~"), fkey(8))
    assert_equal(one_key("\x1b[20~"), fkey(9))
    assert_equal(one_key("\x1b[21~"), fkey(10))
    assert_equal(one_key("\x1b[23~"), fkey(11))
    assert_equal(one_key("\x1b[24~"), fkey(12))
    assert_equal(one_key("\x1b[11~"), fkey(1))  # rxvt/linux console style


def test_function_keys_with_modifiers() raises:
    assert_equal(one_key("\x1b[20;5~"), fkey(9) | MOD_CTRL)   # Ctrl-F9 run
    assert_equal(one_key("\x1b[20;3~"), fkey(9) | MOD_ALT)    # Alt-F9 format
    assert_equal(one_key("\x1b[17;2~"), fkey(6) | MOD_SHIFT)  # Shift-F6
    assert_equal(one_key("\x1b[1;3R"), fkey(3) | MOD_ALT)     # Alt-F3 (xterm)
    assert_equal(one_key("\x1b[13;3~"), fkey(3) | MOD_ALT)    # Alt-F3 (tilde form)
    assert_equal(one_key("\x1b[1;5Q"), fkey(2) | MOD_CTRL)    # Ctrl-F2 cancel


# ------------------------------------------------------------------ alt / esc
def test_alt_letters() raises:
    assert_equal(one_key("\x1bf"), alt(102))
    assert_equal(one_key("\x1bF"), alt(102))   # normalised to lower case
    assert_equal(one_key("\x1bx"), alt(120))
    assert_equal(one_key("\x1b0"), alt(48))
    assert_equal(one_key("\x1b\x7f"), KEY_BACKSPACE | MOD_ALT)


def test_lone_escape_needs_idle_tick() raises:
    var t = Terminal()
    assert_equal(len(t.feed(raw([27]), False)), 0)   # could be the start of a sequence
    var evs = t.feed(List[UInt8](), True)            # nothing followed -> it was Esc
    assert_equal(len(evs), 1)
    assert_equal(evs[0].key, KEY_ESC)


def test_escape_sequence_split_across_reads() raises:
    var t = Terminal()
    assert_equal(len(t.feed(raw([27]), False)), 0)
    assert_equal(len(t.feed(str_bytes("[1;5"), False)), 0)
    var evs = t.feed(str_bytes("C"), False)
    assert_equal(len(evs), 1)
    assert_equal(evs[0].key, KEY_RIGHT | MOD_CTRL)


def test_double_escape() raises:
    var t = Terminal()
    var evs = t.feed(raw([27, 27]), True)
    assert_equal(len(evs), 2)
    assert_equal(evs[0].key, KEY_ESC)
    assert_equal(evs[1].key, KEY_ESC)


def test_kitty_csi_u() raises:
    assert_equal(one_key("\x1b[97;5u"), ctrl(97))
    assert_equal(one_key("\x1b[13u"), KEY_ENTER)
    assert_equal(one_key("\x1b[27u"), KEY_ESC)
    assert_equal(one_key("\x1b[9;2u"), KEY_TAB | MOD_SHIFT)


# --------------------------------------------------------------------- mouse
def mouse(s: String) raises -> Event:
    var evs = keys(s)
    assert_equal(len(evs), 1)
    assert_equal(evs[0].kind, EV_MOUSE)
    return evs[0].copy()


def test_mouse_press_release() raises:
    var e = mouse("\x1b[<0;10;5M")
    assert_equal(e.button, MB_LEFT)
    assert_equal(e.mx, 9)   # reported 1-based, stored 0-based
    assert_equal(e.my, 4)
    assert_true(e.pressed)
    assert_false(e.drag)
    var r = mouse("\x1b[<0;10;5m")
    assert_false(r.pressed)
    var rb = mouse("\x1b[<2;3;4M")
    assert_equal(rb.button, MB_RIGHT)


def test_mouse_drag_and_wheel() raises:
    var d = mouse("\x1b[<32;12;6M")
    assert_equal(d.button, MB_LEFT)
    assert_true(d.drag)
    assert_true(d.pressed)
    assert_equal(d.mx, 11)
    assert_equal(d.my, 5)
    assert_equal(mouse("\x1b[<64;1;1M").button, MB_WHEEL_UP)
    assert_equal(mouse("\x1b[<65;1;1M").button, MB_WHEEL_DOWN)


def test_mouse_large_coordinates() raises:
    var e = mouse("\x1b[<0;250;120M")
    assert_equal(e.mx, 249)
    assert_equal(e.my, 119)


# --------------------------------------------------------------------- paste
def test_bracketed_paste_single_read() raises:
    var evs = keys("\x1b[200~hello\nwörld\x1b[201~x")
    assert_equal(len(evs), 2)
    assert_equal(evs[0].kind, EV_PASTE)
    assert_equal(to_str(evs[0].text), "hello\nwörld")
    assert_equal(evs[1].kind, EV_KEY)
    assert_equal(evs[1].key, 120)


def test_paste_does_not_interpret_escape_sequences() raises:
    var evs = keys("\x1b[200~a\x1b[Ab\x1b[201~")
    assert_equal(len(evs), 1)
    assert_equal(evs[0].kind, EV_PASTE)
    assert_equal(len(evs[0].text), 5)   # a ESC [ A b kept as text


def test_paste_split_across_reads() raises:
    var t = Terminal()
    assert_equal(len(t.feed(str_bytes("\x1b[200~abc"), False)), 0)
    assert_equal(len(t.feed(List[UInt8](), True)), 0)
    var evs = t.feed(str_bytes("def\x1b[201~"), False)
    assert_equal(len(evs), 1)
    assert_equal(to_str(evs[0].text), "abcdef")
    # parser is back to normal afterwards
    var after = t.feed(str_bytes("z"), False)
    assert_equal(after[0].key, 122)


def test_paste_terminator_split_across_reads() raises:
    var t = Terminal()
    assert_equal(len(t.feed(str_bytes("\x1b[200~abc\x1b[20"), False)), 0)
    assert_equal(len(t.feed(List[UInt8](), True)), 0)   # idle tick must not eat "ESC[20"
    var evs = t.feed(str_bytes("1~"), False)
    assert_equal(len(evs), 1)
    assert_equal(evs[0].kind, EV_PASTE)
    assert_equal(to_str(evs[0].text), "abc")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
