"""Tests for terminal capability detection and colour-depth fallbacks."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from caps import (
    detect_styled_underline,
    Caps, detect_color_level, rgb_to_256, rgb_to_16, sgr_16, cube_level, cube_value,
    ansi16_rgb, COLOR_16, COLOR_256, COLOR_TRUE, CAPS_QUERY,
)
from term import Terminal, EV_KEY, KEY_ENTER, ctrl
from screen import Screen
from util import str_bytes, bytes_to_str


def feed(mut t: Terminal, s: String) -> Int:
    """Feed reply bytes; returns how many input events they produced."""
    return len(t.feed(str_bytes(s), False))


# ------------------------------------------------------------ reply parsing
def test_defaults_before_probing() raises:
    var c = Caps()
    assert_equal(c.color, COLOR_TRUE)
    assert_false(c.sync_output)
    assert_false(c.kitty_keyboard)
    assert_false(c.answered)


def test_mode_reports() raises:
    var t = Terminal()
    assert_equal(feed(t, "\x1b[?2026;2$y"), 0)    # supported, currently reset
    assert_true(t.caps.sync_output)
    assert_equal(feed(t, "\x1b[?2027;1$y"), 0)    # supported, currently set
    assert_true(t.caps.grapheme)
    assert_equal(feed(t, "\x1b[?2031;0$y"), 0)    # not recognised
    assert_false(t.caps.color_scheme)
    assert_equal(feed(t, "\x1b[?2048;4$y"), 0)    # permanently reset: cannot be enabled
    assert_false(t.caps.inband_resize)
    assert_equal(feed(t, "\x1b[?2048;3$y"), 0)    # permanently set
    assert_true(t.caps.inband_resize)
    assert_equal(feed(t, "\x1b[?9999;1$y"), 0)    # a mode we never asked about
    assert_false(t.caps.color_scheme)


def test_kitty_and_da1_replies() raises:
    var t = Terminal()
    assert_false(t.caps.kitty_keyboard)
    assert_equal(feed(t, "\x1b[?0u"), 0)
    assert_true(t.caps.kitty_keyboard)
    assert_false(t.caps.answered)
    assert_equal(feed(t, "\x1b[?62;4;22c"), 0)
    assert_true(t.caps.answered)


def test_replies_mixed_with_typing_keep_the_keys() raises:
    var t = Terminal()
    var evs = t.feed(str_bytes("a\x1b[?2026;2$yb\x1b[?1;2c\r"), False)
    assert_equal(len(evs), 3)
    assert_equal(evs[0].key, 97)
    assert_equal(evs[1].key, 98)
    assert_equal(evs[2].key, KEY_ENTER)
    assert_true(t.caps.sync_output)
    assert_true(t.caps.answered)


def test_kitty_key_event_is_still_a_key_not_a_reply() raises:
    var t = Terminal()
    var evs = t.feed(str_bytes("\x1b[97;5u"), False)
    assert_equal(len(evs), 1)
    assert_equal(evs[0].key, ctrl(97))
    assert_false(t.caps.kitty_keyboard)


def test_reply_split_across_reads() raises:
    var t = Terminal()
    assert_equal(feed(t, "\x1b[?2026"), 0)
    assert_false(t.caps.sync_output)
    assert_equal(feed(t, ";2$y"), 0)
    assert_true(t.caps.sync_output)


def test_query_ends_with_the_request_every_terminal_answers() raises:
    var q = String(CAPS_QUERY)
    assert_true(q.endswith("\x1b[c"))
    assert_true(q.find("\x1b[?2026$p") >= 0)
    assert_true(q.find("\x1b[?u") >= 0)


def test_describe_lists_every_capability() raises:
    var c = Caps()
    c.sync_output = True
    var lines = c.describe()
    assert_equal(len(lines), 12)
    assert_true(lines[0].endswith("24-bit colour"))
    assert_true(lines[1].endswith(": yes"))
    assert_true(lines[2].endswith(": no"))
    var bg = -1
    for k in range(len(lines)):
        if lines[k].startswith("background"):
            bg = k
    assert_true(bg >= 0 and lines[bg].endswith("not said"))
    c.background = 0x1A1B26
    assert_true(c.describe()[bg].endswith("#1a1b26"), c.describe()[bg])
    var wl = -1
    for k in range(len(lines)):
        if lines[k].startswith("measured widths"):
            wl = k
    assert_true(wl >= 0 and lines[wl].endswith("not measured"))
    c.widths = [2, 2, 2, 2]
    assert_true(c.describe()[wl].endswith("2, 2, 2, 2 (joins emoji sequences; emoji selector widens)"), c.describe()[wl])


# ------------------------------------------------------------ colour depth
def test_color_level_from_environment() raises:
    assert_equal(detect_color_level("truecolor", "xterm-256color", ""), COLOR_TRUE)
    assert_equal(detect_color_level("24bit", "xterm", ""), COLOR_TRUE)
    assert_equal(detect_color_level("", "xterm-256color", ""), COLOR_256)
    assert_equal(detect_color_level("", "tmux-256color", ""), COLOR_256)
    assert_equal(detect_color_level("", "xterm-direct", ""), COLOR_TRUE)
    assert_equal(detect_color_level("", "xterm-kitty", ""), COLOR_TRUE)
    assert_equal(detect_color_level("", "xterm", ""), COLOR_16)
    assert_equal(detect_color_level("", "linux", ""), COLOR_16)
    assert_equal(detect_color_level("", "", ""), COLOR_16)


def test_color_level_override_wins() raises:
    assert_equal(detect_color_level("truecolor", "xterm-256color", "16"), COLOR_16)
    assert_equal(detect_color_level("", "linux", "truecolor"), COLOR_TRUE)
    assert_equal(detect_color_level("truecolor", "xterm", "256"), COLOR_256)
    assert_equal(detect_color_level("truecolor", "xterm", "nonsense"), COLOR_TRUE)


def test_cube_levels() raises:
    assert_equal(cube_level(0), 0)
    assert_equal(cube_level(47), 0)
    assert_equal(cube_level(48), 1)      # nearer to 95 than to 0
    assert_equal(cube_level(95), 1)
    assert_equal(cube_level(114), 1)
    assert_equal(cube_level(115), 2)     # nearer to 135
    assert_equal(cube_level(170), 3)     # CGA 0xAA -> 175
    assert_equal(cube_level(255), 5)
    assert_equal(cube_value(0), 0)
    assert_equal(cube_value(1), 95)
    assert_equal(cube_value(5), 255)


def test_rgb_to_256_known_values() raises:
    assert_equal(rgb_to_256(0x000000), 16)
    assert_equal(rgb_to_256(0xFFFFFF), 231)
    assert_equal(rgb_to_256(0xFF0000), 196)
    assert_equal(rgb_to_256(0x00FF00), 46)
    assert_equal(rgb_to_256(0x0000FF), 21)
    assert_equal(rgb_to_256(0x0000AA), 19)   # Turbo blue -> (0,0,175)
    assert_equal(rgb_to_256(0x00AAAA), 37)   # Turbo cyan -> (0,175,175)
    assert_equal(rgb_to_256(0x808080), 244)  # exact grey-ramp value 128
    assert_equal(rgb_to_256(0xAAAAAA), 248)  # grey 168 is nearer than cube 175
    assert_equal(rgb_to_256(0x080808), 232)  # darkest grey step


def test_rgb_to_256_is_always_a_valid_index() raises:
    var v = 0
    while v < 0x1000000:
        var i = rgb_to_256(v)
        assert_true(i >= 16 and i <= 255)
        v += 0x030507                    # sample ~80k colours across the space


def test_rgb_to_16_maps_the_cga_palette_exactly() raises:
    for i in range(16):
        assert_equal(rgb_to_16(ansi16_rgb(i)), i)
    assert_equal(rgb_to_16(0x0000A0), 4)     # slightly off blue is still blue
    assert_equal(rgb_to_16(0x1A1B26), 0)     # Midnight theme background -> black
    assert_equal(rgb_to_16(0xC0CAF5), 15)    # Midnight theme text -> bright white


def test_sgr_codes_for_16_colours() raises:
    assert_equal(sgr_16(0, False), 30)
    assert_equal(sgr_16(4, False), 34)
    assert_equal(sgr_16(7, True), 47)
    assert_equal(sgr_16(8, False), 90)
    assert_equal(sgr_16(11, False), 93)      # bright yellow text
    assert_equal(sgr_16(15, True), 107)


# ---------------------------------------------------------------- rendering
def rendered(mode: Int, sync: Bool) -> String:
    var s = Screen(4, 1)
    s.color_mode = mode
    s.sync = sync
    _ = s.text(0, 0, "ab", 0xFFFF55, 0x0000AA)   # Turbo yellow on blue
    var out = List[UInt8]()
    s.render(out)
    return bytes_to_str(out)


def test_truecolor_rendering() raises:
    var o = rendered(COLOR_TRUE, True)
    assert_true(o.find("\x1b[38;2;255;255;85m") >= 0)
    assert_true(o.find("\x1b[48;2;0;0;170m") >= 0)
    assert_true(o.find("ab") >= 0)


def test_256_colour_rendering() raises:
    var o = rendered(COLOR_256, True)
    assert_true(o.find("\x1b[38;5;227m") >= 0)    # (255,255,95)
    assert_true(o.find("\x1b[48;5;19m") >= 0)
    assert_equal(o.find("38;2;"), -1)
    assert_equal(o.find("48;2;"), -1)


def test_16_colour_rendering() raises:
    var o = rendered(COLOR_16, True)
    assert_true(o.find("\x1b[93m") >= 0)          # bright yellow
    assert_true(o.find("\x1b[44m") >= 0)          # blue background
    assert_equal(o.find("38;"), -1)
    assert_equal(o.find("48;"), -1)


def test_sync_markers_only_when_supported() raises:
    var on = rendered(COLOR_TRUE, True)
    assert_true(on.startswith("\x1b[?2026h"))
    assert_true(on.endswith("\x1b[?2026l"))
    var off = rendered(COLOR_TRUE, False)
    assert_equal(off.find("2026"), -1)
    assert_true(off.find("ab") >= 0)


def test_screen_defaults_keep_previous_behaviour() raises:
    var s = Screen(2, 1)
    assert_equal(s.color_mode, COLOR_TRUE)
    assert_true(s.sync)



def test_styled_underline_guess() raises:
    assert_true(detect_styled_underline("xterm-kitty", "", "", ""))
    assert_true(detect_styled_underline("xterm-256color", "WezTerm", "", ""))
    assert_true(detect_styled_underline("xterm-256color", "", "7600", ""))      # a recent VTE
    assert_false(detect_styled_underline("xterm-256color", "", "5000", ""))     # an old one
    assert_false(detect_styled_underline("xterm-256color", "", "", ""))
    assert_false(detect_styled_underline("xterm-256color", "", "abc", ""))
    assert_false(detect_styled_underline("tmux-256color", "WezTerm", "7600", ""))   # inside tmux: no
    assert_false(detect_styled_underline("screen", "", "", ""))
    assert_true(detect_styled_underline("tmux-256color", "", "", "curly"))      # the user knows better
    assert_false(detect_styled_underline("xterm-kitty", "", "", "plain"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
