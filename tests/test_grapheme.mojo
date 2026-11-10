"""Grapheme cluster tests. The expected boundaries come from the rules of Unicode UAX #29
(extended grapheme clusters) and its published test cases, not from the implementation."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from grapheme import cluster_end, cluster_start, snap_to_cluster, cluster_count, cluster_width, ends_with_plain_mark
from window import Window, WK_EDITOR
from window_search import *
from window_draw import *
from screen import Screen, CONT
from palette import theme
from highlight import Highlighter
from util import decode, to_str, encode_cp

comptime ZWJ = 0x200D
comptime VS16 = 0xFE0F
comptime MAN = 0x1F468
comptime WOMAN = 0x1F469
comptime GIRL = 0x1F467
comptime RI_F = 0x1F1EB
comptime RI_R = 0x1F1F7
comptime RI_D = 0x1F1E9
comptime RI_E = 0x1F1EA


def sizes(cps: List[Int]) -> String:
    """Cluster lengths in codepoints, e.g. "1 2 5"."""
    var out = String("")
    var i = 0
    while i < len(cps):
        var e = cluster_end(cps, i)
        if i > 0:
            out += " "
        out += String(e - i)
        i = e
    return out


def family() -> List[Int]:
    var f: List[Int] = [MAN, ZWJ, WOMAN, ZWJ, GIRL]
    return f^


# ---------------------------------------------------------------- segmentation
def test_plain_text_is_one_cluster_per_character() raises:
    assert_equal(sizes(decode("abc")), "1 1 1")
    assert_equal(cluster_count(decode("")), 0)


def test_combining_marks_join_their_base() raises:
    var a: List[Int] = [0x65, 0x301, 0x323, 0x78]      # e + acute + dot below, x
    assert_equal(sizes(a), "3 1")


def test_regional_indicators_pair_up() raises:
    var two: List[Int] = [RI_F, RI_R, RI_D, RI_E]       # FR DE
    assert_equal(sizes(two), "2 2")
    var odd: List[Int] = [RI_F, RI_R, RI_D]             # FR + lone D
    assert_equal(sizes(odd), "2 1")
    var mixed: List[Int] = [0x61, RI_F, RI_R, 0x62]
    assert_equal(sizes(mixed), "1 2 1")


def test_zwj_sequence_is_one_cluster() raises:
    assert_equal(sizes(family()), "5")
    var tech: List[Int] = [WOMAN, 0x1F3FD, ZWJ, 0x1F4BB]   # woman technologist, medium skin
    assert_equal(sizes(tech), "4")
    var rainbow: List[Int] = [0x1F3F3, VS16, ZWJ, 0x1F308]  # rainbow flag
    assert_equal(sizes(rainbow), "4")


def test_zwj_only_joins_emoji() raises:
    var letters: List[Int] = [0x61, ZWJ, 0x62]           # ZWJ sticks to a, b starts anew
    assert_equal(sizes(letters), "2 1")
    var to_letter: List[Int] = [MAN, ZWJ, 0x61]
    assert_equal(sizes(to_letter), "2 1")
    var double: List[Int] = [MAN, ZWJ, ZWJ, WOMAN]       # two joiners do not join emoji
    assert_equal(sizes(double), "3 1")
    var two_emoji: List[Int] = [MAN, WOMAN]
    assert_equal(sizes(two_emoji), "1 1")


def test_modifiers_selectors_and_keycaps() raises:
    var thumb: List[Int] = [0x1F44D, 0x1F3FD, 0x21]       # thumbs up + skin tone, !
    assert_equal(sizes(thumb), "2 1")
    var heart: List[Int] = [0x2764, VS16, 0x2764]
    assert_equal(sizes(heart), "2 1")
    var keycap: List[Int] = [0x31, VS16, 0x20E3, 0x32]    # 1 + VS16 + enclosing keycap, 2
    assert_equal(sizes(keycap), "3 1")
    var wales: List[Int] = [0x1F3F4, 0xE0067, 0xE0062, 0xE0077, 0xE006C, 0xE0073, 0xE007F]
    assert_equal(sizes(wales), "7")


def test_hangul_syllables() raises:
    var jamo: List[Int] = [0x1112, 0x1161, 0x11AB]        # L V T -> one syllable
    assert_equal(sizes(jamo), "3")
    var lv_t: List[Int] = [0xAC00, 0x11A8]                # LV + T
    assert_equal(sizes(lv_t), "2")
    var lvt_t: List[Int] = [0xAC01, 0x11A8]               # LVT + T
    assert_equal(sizes(lvt_t), "2")
    var two: List[Int] = [0xAC00, 0xAC01]                 # two precomposed syllables
    assert_equal(sizes(two), "1 1")
    var l_lv: List[Int] = [0x1100, 0xAC00]                # L + LV
    assert_equal(sizes(l_lv), "2")
    var t_l: List[Int] = [0x11A8, 0x1100]                 # T then L: break
    assert_equal(sizes(t_l), "1 1")
    var lv_v: List[Int] = [0xAC00, 0x1161]                # LV + V
    assert_equal(sizes(lv_v), "2")
    var lvt_v: List[Int] = [0xAC01, 0x1161]               # LVT + V: break
    assert_equal(sizes(lvt_v), "1 1")


def test_spacing_marks_join() raises:
    var ki: List[Int] = [0x915, 0x93F, 0x915]             # ka + vowel sign i, ka
    assert_equal(sizes(ki), "2 1")
    var thai: List[Int] = [0xE01, 0xE34, 0xE48]           # ko kai + sara i + mai ek
    assert_equal(sizes(thai), "3")


def test_control_characters_stand_alone() raises:
    var tab: List[Int] = [9, 0x301, 0x61]
    assert_equal(sizes(tab), "1 1 1")


def test_boundary_helpers() raises:
    var a: List[Int] = [0x61, 0x65, 0x301, MAN, ZWJ, WOMAN, 0x62]
    assert_equal(sizes(a), "1 2 3 1")
    assert_equal(cluster_start(a, 7), 6)
    assert_equal(cluster_start(a, 6), 3)
    assert_equal(cluster_start(a, 3), 1)
    assert_equal(cluster_start(a, 1), 0)
    assert_equal(cluster_start(a, 0), 0)
    assert_equal(cluster_start(a, 5), 3)      # from inside a cluster: its start
    assert_equal(snap_to_cluster(a, 4), 3)
    assert_equal(snap_to_cluster(a, 2), 1)
    assert_equal(snap_to_cluster(a, 3), 3)
    assert_equal(snap_to_cluster(a, 99), 7)
    assert_equal(cluster_end(a, 7), 7)


def test_cluster_width_in_both_terminal_models() raises:
    var f = family()
    assert_equal(cluster_width(f, 0, 5, False), 6)    # three emoji side by side
    assert_equal(cluster_width(f, 0, 5, True), 2)     # one glyph
    var e: List[Int] = [0x65, 0x301]
    assert_equal(cluster_width(e, 0, 2, False), 1)
    assert_equal(cluster_width(e, 0, 2, True), 1)
    var heart: List[Int] = [0x2764, VS16]
    assert_equal(cluster_width(heart, 0, 2, False), 1)
    assert_equal(cluster_width(heart, 0, 2, True), 2)  # emoji presentation is wide
    var flag: List[Int] = [RI_F, RI_R]
    assert_equal(cluster_width(flag, 0, 2, True), 2)
    var han: List[Int] = [0x65E5]
    assert_equal(cluster_width(han, 0, 1, True), 2)
    var wales: List[Int] = [0x1F3F4, 0xE0067, 0xE0062, 0xE007F]
    assert_equal(cluster_width(wales, 0, 4, False), 2)  # tag characters take no room


def test_plain_mark_detection() raises:
    var e: List[Int] = [0x65, 0x301]
    assert_true(ends_with_plain_mark(e, 0, 2))
    var heart: List[Int] = [0x2764, VS16]
    assert_false(ends_with_plain_mark(heart, 0, 2))
    var thumb: List[Int] = [0x1F44D, 0x1F3FD]
    assert_false(ends_with_plain_mark(thumb, 0, 2))
    var f = family()
    assert_false(ends_with_plain_mark(f, 0, 5))
    var single: List[Int] = [0x65]
    assert_false(ends_with_plain_mark(single, 0, 1))


# ---------------------------------------------------------------------- editor
def win_cps(cps: List[Int]) -> Window:
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 40, 6, 1)
    w.buf.load(cps)
    return w^


def sample() -> List[Int]:
    # a | e+acute | family | b      (cluster starts at 0, 1, 3, 8; length 9)
    var a: List[Int] = [0x61, 0x65, 0x301, MAN, ZWJ, WOMAN, ZWJ, GIRL, 0x62]
    return a^


def test_cursor_moves_by_cluster() raises:
    var w = win_cps(sample())
    var stops = String("")
    for _ in range(4):
        w.move_right(False, False)
        stops += String(w.cc) + " "
    assert_equal(stops, "1 3 8 9 ")
    stops = ""
    for _ in range(4):
        w.move_left(False, False)
        stops += String(w.cc) + " "
    assert_equal(stops, "8 3 1 0 ")


def test_shift_arrow_selects_whole_cluster() raises:
    var flag: List[Int] = [0x78, RI_F, RI_R, 0x79]
    var w = win_cps(flag)
    w.cc = 1
    w.move_right(True, False)
    assert_true(w.has_sel())
    var s = w.sel_range()
    assert_equal(s.c1, 1)
    assert_equal(s.c2, 3)


def test_delete_removes_whole_cluster_and_undo_restores_it() raises:
    var w = win_cps(sample())
    w.cc = 3
    w.delete_fwd()
    var want: List[Int] = [0x61, 0x65, 0x301, 0x62]
    assert_equal(to_str(w.buf.line(0)), to_str(want))
    w.undo()
    assert_equal(to_str(w.buf.line(0)), to_str(sample()))
    w.cc = 1
    w.delete_fwd()                       # the letter goes together with its accent
    assert_equal(w.buf.llen(0), 7)
    assert_equal(w.buf.at(0, 0), 0x61)
    assert_equal(w.buf.at(0, 1), MAN)


def test_backspace_removes_one_accent_but_a_whole_emoji() raises:
    var w = win_cps(sample())
    w.cc = 3
    w.backspace()                        # only the accent
    assert_equal(w.cc, 2)
    assert_equal(w.buf.at(0, 1), 0x65)
    assert_equal(w.buf.at(0, 2), MAN)
    w.cc = 7                             # just after the family
    w.backspace()
    assert_equal(w.cc, 2)
    var want: List[Int] = [0x61, 0x65, 0x62]
    assert_equal(to_str(w.buf.line(0)), to_str(want))


def test_columns_follow_the_terminal_model() raises:
    var w = win_cps(sample())
    assert_equal(w.vcol(0, 8), 8)        # a(1) e(1) + three emoji (6)
    assert_equal(w.vcol(0, 5), 2)        # inside the family: the family's column
    w.clustered = True
    assert_equal(w.vcol(0, 8), 4)        # a(1) e(1) family(2)
    assert_equal(w.vcol(0, 9), 5)
    # a click anywhere on the family lands on one of its two edges, never inside
    assert_equal(w.col_at_vcol(0, 2), 3)
    assert_equal(w.col_at_vcol(0, 3), 8)
    assert_equal(w.col_at_vcol(0, 4), 8)
    assert_equal(w.col_at_vcol(0, 1), 1)
    w.clustered = False
    for v in range(10):
        var c = w.col_at_vcol(0, v)
        assert_true(c == 0 or c == 1 or c == 3 or c == 8 or c == 9, "column inside a cluster")


def test_vertical_move_lands_on_cluster_boundary() raises:
    var cps = decode("0123456789\n")
    for c in sample():
        cps.append(c)
    var w = win_cps(cps)
    for col in range(10):
        w.cr = 0
        w.cc = col
        w.sync_want()
        w.move_vert(1, False)
        assert_true(w.cc == 0 or w.cc == 1 or w.cc == 3 or w.cc == 8 or w.cc == 9, "cursor inside a cluster")


# ---------------------------------------------------------------------- screen
def test_screen_cell_holds_a_full_cluster() raises:
    var s = Screen(10, 1)
    var f = family()
    s.put(0, 0, 0x78, 1, 2)
    s.put_cluster(1, 0, f, 0, 5, 2, 1, 2)
    s.put(3, 0, 0x79, 1, 2)
    assert_equal(s.ch[1], MAN)
    assert_equal(s.ch[2], CONT)
    assert_equal(s.ch[3], 0x79)
    var want: List[Int] = [0x78, MAN, ZWJ, WOMAN, ZWJ, GIRL, 0x79]
    assert_equal(to_str(s.row_text(0)), to_str(want))
    # the terminal receives the cluster in one piece
    var out = List[UInt8]()
    s.render(out)
    var needle = List[UInt8]()
    for c in f:
        encode_cp(c, needle)
    var found = False
    for i in range(len(out) - len(needle) + 1):
        var same = True
        for j in range(len(needle)):
            if out[i + j] != needle[j]:
                same = False
                break
        if same:
            found = True
            break
    assert_true(found, "cluster bytes must be contiguous in the output")


def test_same_cluster_is_not_redrawn() raises:
    var s = Screen(10, 1)
    var f = family()
    s.put_cluster(1, 0, f, 0, 5, 2, 1, 2)
    var a = List[UInt8]()
    s.render(a)
    s.put_cluster(1, 0, f, 0, 5, 2, 1, 2)      # the next frame draws the same thing
    var b = List[UInt8]()
    s.render(b)
    var needle = List[UInt8]()
    encode_cp(MAN, needle)
    var hit = False
    for i in range(len(b) - 3):
        if b[i] == needle[0] and b[i + 1] == needle[1] and b[i + 2] == needle[2] and b[i + 3] == needle[3]:
            hit = True
    assert_false(hit, "unchanged cluster was sent again")
    var g: List[Int] = [MAN, ZWJ, WOMAN, ZWJ, 0x1F466]    # girl -> boy: must be sent
    s.put_cluster(1, 0, g, 0, 5, 2, 1, 2)
    var c = List[UInt8]()
    s.render(c)
    assert_true(len(c) > len(b), "changed cluster was not sent")


def test_several_marks_stay_on_one_cell() raises:
    var s = Screen(6, 1)
    var x = s.draw_cp(0, 0, 0x65, 1, 2)
    x = s.draw_cp(x, 0, 0x301, 1, 2)
    x = s.draw_cp(x, 0, 0x323, 1, 2)
    x = s.draw_cp(x, 0, 0x21, 1, 2)
    assert_equal(x, 2)
    var want: List[Int] = [0x65, 0x301, 0x323, 0x21]
    assert_equal(to_str(s.row_text(0)), to_str(want))


def test_overwriting_part_of_a_long_character_clears_all_of_it() raises:
    var s = Screen(8, 1)
    var f = family()
    s.put_cluster(1, 0, f, 0, 5, 4, 1, 2)     # pretend it is four cells wide
    assert_equal(s.ch[4], CONT)
    s.put(3, 0, 0x7A, 1, 2)
    assert_equal(s.ch[1], 32)
    assert_equal(s.ch[2], 32)
    assert_equal(s.ch[3], 0x7A)
    assert_equal(s.ch[4], 32)
    assert_equal(to_str(s.row_text(0)), "   z")


def test_cluster_cut_by_clip_edge_is_not_drawn_outside() raises:
    var s = Screen(8, 1)
    s.clip(0, 0, 3, 1)
    var f = family()
    s.put_cluster(2, 0, f, 0, 5, 2, 1, 2)
    s.no_clip()
    assert_equal(s.ch[2], 0x2026)
    assert_equal(s.ch[3], 32)


def draw_line(clustered: Bool) -> String:
    var s = Screen(30, 4)
    var p = theme(0)
    var cps: List[Int] = [0x78, MAN, ZWJ, WOMAN, ZWJ, GIRL, 0x79]
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 30, 4, 1)
    w.buf.load(cps)
    w.clustered = clustered
    var h = Highlighter()
    w.draw(s, p, h, True, False, False, False)
    # column (inside the frame) where the y ended up
    var col = -1
    for x in range(30):
        if s.ch[30 + x] == 0x79:
            col = x - 1
    return to_str(s.row_text(1)) + "|" + String(col)


def test_window_draws_cluster_at_its_terminal_width() raises:
    var legacy = draw_line(False)
    var modern = draw_line(True)
    var cps: List[Int] = [0x78, MAN, ZWJ, WOMAN, ZWJ, GIRL, 0x79]
    assert_true(legacy.find(to_str(cps)) >= 0, "all codepoints reach the screen in order")
    assert_true(modern.find(to_str(cps)) >= 0, "all codepoints reach the screen in order")
    assert_true(legacy.endswith("|7"), "three emoji side by side: " + legacy)
    assert_true(modern.endswith("|3"), "one two-column glyph: " + modern)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
