"""Tests for incremental highlighting: the fast line-state scanner must agree with the
highlighter, and the per-line state cache must equal a full re-scan after any edits."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from highlight import Highlighter, line_state, scan_states, C_STR, C_KW
from window import Window, WK_EDITOR, WK_MESSAGE, LEX_BUDGET, ACT_OTHER
from window_search import *
from window_draw import *
from screen import Screen
from palette import theme
from util import decode, to_str, str_bytes, encode_cp


struct Rng:
    var s: Int

    def __init__(out self, seed: Int):
        self.s = seed

    def next(mut self, n: Int) -> Int:
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.s >> 8) % n


def random_line(mut rng: Rng, n: Int) -> List[Int]:
    # heavy on the characters that matter to the lexer state
    var alphabet = decode("ab \"\"\"'''##\\\\x=1 é🔥()\"'")
    var out = List[Int]()
    for _ in range(n):
        out.append(alphabet[rng.next(len(alphabet))])
    return out^


def bytes_of(cps: List[Int]) -> List[UInt8]:
    var b = List[UInt8]()
    for c in cps:
        encode_cp(c, b)
    return b^


def win(text: String) -> Window:
    var w = Window(WK_EDITOR, "t.mojo", "", 0, 0, 60, 12, 1)
    w.buf.load(decode(text))
    return w^


def ref_states(w: Window) -> List[Int]:
    """State at the start of every line (and after the last), by the real highlighter."""
    var h = Highlighter()
    var out = List[Int]()
    var st = 0
    var cls = List[Int]()
    out.append(0)
    for r in range(w.buf.count()):
        st = h.line(w.buf.line(r), st, cls)
        out.append(st)
    return out^


def cache_matches(w: Window, what: String) raises:
    """Every cached state equals the reference (the cache may cover only a prefix)."""
    var want = ref_states(w)
    assert_true(len(w.buf.lstate) <= len(want), what + ": cache longer than the text")
    for i in range(len(w.buf.lstate)):
        assert_equal(Int(w.buf.lstate[i]), want[i], what + ": state at line " + String(i))


def fully_synced(mut w: Window, what: String) raises:
    w.sync_lex(w.buf.count())
    # one state per line start; after a re-scan the state after the last line is kept too
    assert_true(len(w.buf.lstate) >= w.buf.count(), what + ": cache should cover every line")
    cache_matches(w, what)
    assert_equal(w.buf.ldirty_from, -1)


# ---------------------------------------------------------- scanner vs lexer
def test_line_state_agrees_with_the_highlighter() raises:
    var h = Highlighter()
    var rng = Rng(20261110)
    var cls = List[Int]()
    for _ in range(6000):
        var cps = random_line(rng, rng.next(24))
        var b = bytes_of(cps)
        for st in range(3):
            assert_equal(line_state(b, 0, len(b), st), h.line(cps, st, cls), "line: " + to_str(cps) + " state " + String(st))


def test_line_state_on_hand_written_cases() raises:
    var cases = List[String]()
    var states = List[Int]()
    for c in ["x = 1", "s = \"a # b\"", "# \"\"\" in a comment", "\"\"\"doc", "'''doc", "\"\"\"one line\"\"\"", "s = 'it\\'s' # c", "\"\"\"a\"\"\" + \"\"\"b", "\"unterminated", "\"\"\"\"", "", "x = \"\\\\\" # c \"\"\""]:
        cases.append(String(c))
    for s in [0, 0, 0, 1, 2, 0, 0, 1, 0, 1, 0, 0]:
        states.append(s)
    for i in range(len(cases)):
        var b = str_bytes(cases[i])
        assert_equal(line_state(b, 0, len(b), 0), states[i], cases[i])
    var b = str_bytes("still inside")
    assert_equal(line_state(b, 0, len(b), 1), 1)
    assert_equal(line_state(b, 0, len(b), 2), 2)
    var c = str_bytes("end\"\"\" x = '''open")
    assert_equal(line_state(c, 0, len(c), 1), 2)     # closes the double-quoted one, opens the other
    # starting inside a single-quoted triple string: the double quotes do not close it,
    # the three single quotes later on the line do
    assert_equal(line_state(c, 0, len(c), 2), 0)
    var e = str_bytes("end\"\"\" still open")
    assert_equal(line_state(e, 0, len(e), 2), 2)
    # a sub-range of a larger buffer
    var d = str_bytes("junk\"\"\"|x = 1|\"\"\"junk")
    assert_equal(line_state(d, 8, 13, 0), 0)


def test_scan_states_equals_line_by_line() raises:
    var rng = Rng(7)
    var h = Highlighter()
    var cls = List[Int]()
    for _ in range(60):
        var text = List[UInt8]()
        var want = List[Int]()
        var st = 0
        var lines = 1 + rng.next(40)
        for _ in range(lines):
            var cps = random_line(rng, rng.next(20))
            st = h.line(cps, st, cls)
            want.append(st)
            for b in bytes_of(cps):
                text.append(b)
            text.append(10)
        var got = List[UInt8]()
        var end = scan_states(text, 0, got)
        assert_equal(len(got), lines)
        assert_equal(end, st)
        for i in range(lines):
            assert_equal(Int(got[i]), want[i])


# -------------------------------------------------------------------- cache
def test_fresh_buffer_knows_only_the_first_line() raises:
    var w = win("a\nb\nc\n")
    assert_equal(len(w.buf.lstate), 1)
    assert_equal(Int(w.buf.lstate[0]), 0)
    assert_equal(w.lex_state_at(0), 0)


def test_cache_is_built_lazily_up_to_what_is_needed() raises:
    var text = String("")
    for i in range(500):
        text += "x = " + String(i) + "\n"
    var w = win(text)
    w.sync_lex(20)
    assert_equal(len(w.buf.lstate), 21)
    assert_equal(w.buf.lex_work, 20)
    w.sync_lex(20)                                   # already covered: no more work
    assert_equal(w.buf.lex_work, 20)
    w.sync_lex(10)
    assert_equal(w.buf.lex_work, 20)
    fully_synced(w, "after full sync")


def test_docstring_state_is_found() raises:
    var w = win("x = 1\n\"\"\"start\nmiddle\nend\"\"\"\ny = 2\n'''other\nin\n")
    fully_synced(w, "docstrings")
    var want = List[Int]()
    for s in [0, 0, 1, 1, 0, 0, 2, 2]:
        want.append(s)
    for i in range(8):
        assert_equal(Int(w.buf.lstate[i]), want[i])
        assert_equal(w.lex_state_at(i), want[i])


def test_typing_in_a_big_file_rescans_almost_nothing() raises:
    var text = String("")
    for i in range(5000):
        text += "    value_" + String(i) + " = compute(" + String(i) + ")\n"
    var w = win(text)
    fully_synced(w, "initial")
    var before = w.buf.lex_work
    w.goto(2500, 4)
    w.type_char(120, True)
    w.sync_lex(2600)
    assert_true(w.buf.lex_work - before <= 2, "typing one character cost " + String(w.buf.lex_work - before) + " lines")
    assert_true(len(w.buf.lstate) >= 5001, "the cache still covers the whole file")
    cache_matches(w, "after typing")
    # a new line shifts every later line, but still costs only the edited lines
    before = w.buf.lex_work
    w.newline(True)
    w.sync_lex(2600)
    assert_true(w.buf.lex_work - before <= 3, "newline cost " + String(w.buf.lex_work - before))
    assert_true(len(w.buf.lstate) >= 5002)
    cache_matches(w, "after newline")
    before = w.buf.lex_work
    w.backspace()
    w.backspace()
    w.sync_lex(2600)
    assert_true(w.buf.lex_work - before <= 4)
    cache_matches(w, "after joining lines")


def test_opening_and_closing_a_docstring_propagates() raises:
    var text = String("")
    for i in range(300):
        text += "x = " + String(i) + "\n"
    var w = win(text)
    fully_synced(w, "initial")
    w.goto(10, 0)
    w.insert_text(decode("\"\"\""), ACT_OTHER)
    fully_synced(w, "after opening a string")
    assert_equal(w.lex_state_at(11), 1)
    assert_equal(w.lex_state_at(299), 1)
    w.goto(20, 0)
    w.insert_text(decode("\"\"\""), ACT_OTHER)
    fully_synced(w, "after closing it")
    assert_equal(w.lex_state_at(20), 1)
    assert_equal(w.lex_state_at(21), 0)
    assert_equal(w.lex_state_at(299), 0)
    w.undo()
    fully_synced(w, "after undo")
    assert_equal(w.lex_state_at(299), 1)


def test_long_propagation_is_cut_off_and_finished_lazily() raises:
    var text = String("")
    for i in range(12000):
        text += "x = " + String(i) + "\n"
    var w = win(text)
    fully_synced(w, "initial")
    var before = w.buf.lex_work
    w.goto(0, 0)
    w.insert_text(decode("'''"), ACT_OTHER)          # now every later line is inside a string
    w.sync_lex(40)                                   # only the first screen is needed
    var cost = w.buf.lex_work - before
    assert_true(cost <= LEX_BUDGET + 5, "re-scan was bounded, cost " + String(cost))
    assert_true(len(w.buf.lstate) < 12001, "the tail is left for later")
    cache_matches(w, "prefix after a cut-off propagation")
    assert_equal(w.lex_state_at(30), 2)
    fully_synced(w, "after scanning the rest")
    assert_equal(w.lex_state_at(11999), 2)


def test_several_edits_before_one_sync() raises:
    var w = win("a = 1\nb = 2\nc = 3\nd = 4\ne = 5\nf = 6\n")
    fully_synced(w, "initial")
    w.goto(4, 0)
    w.insert_text(decode("\"\"\"x\n"), ACT_OTHER)    # opens a string at line 4
    w.goto(1, 0)
    w.insert_text(decode("new\nlines\n"), ACT_OTHER) # earlier edit that shifts the first
    w.goto(0, 0)
    _ = w.delete_line()
    fully_synced(w, "after three edits")


def test_large_paste_and_large_delete() raises:
    var text = String("")
    for i in range(400):
        text += "x = " + String(i) + "\n"
    var w = win(text)
    fully_synced(w, "initial")
    var paste = String("\"\"\"big\n")
    for i in range(200):
        paste += "pasted " + String(i) + "\n"
    w.goto(100, 0)
    w.insert_text(decode(paste), ACT_OTHER)
    fully_synced(w, "after a 200-line paste")
    assert_equal(w.lex_state_at(150), 1)
    w.goto(50, 0)
    w.sel = True
    w.ar = 50
    w.ac = 0
    w.cr = 350
    w.cc = 0
    _ = w.delete_sel(w.new_group())
    fully_synced(w, "after deleting 300 lines")


def test_random_edits_keep_the_cache_equal_to_a_full_rescan() raises:
    for seed in [1, 2, 3, 4, 5, 6]:
        var rng = Rng(seed * 7919)
        var w = win("def f():\n    return 1\n")
        for step in range(250):
            var rows = w.buf.count()
            var r = rng.next(rows)
            var c = rng.next(w.buf.llen(r) + 1)
            w.cr = r
            w.cc = c
            w.sel = False
            var roll = rng.next(100)
            if roll < 45:
                w.insert_text(random_line(rng, 1 + rng.next(6)), ACT_OTHER)
            elif roll < 60:
                w.newline(False)
            elif roll < 75:
                w.backspace()
            elif roll < 85:
                _ = w.delete_line()
            elif roll < 92:
                w.undo()
            else:
                var t = random_line(rng, 3)
                t.append(10)
                for x in random_line(rng, 3):
                    t.append(x)
                w.insert_text(t, ACT_OTHER)
            var what = "seed " + String(seed) + " step " + String(step)
            if step % 3 == 0:
                # sometimes only the "visible" part is synced, as when drawing
                w.sync_lex(rng.next(w.buf.count() + 1))
                cache_matches(w, what + " (partial)")
            else:
                fully_synced(w, what)
        fully_synced(w, "seed " + String(seed) + " final")


def test_state_lookup_is_right_even_without_a_sync() raises:
    var rng = Rng(99)
    var w = win("a\n\"\"\"\nb\nc\n\"\"\"\nd\n")
    fully_synced(w, "initial")
    for step in range(120):
        w.cr = rng.next(w.buf.count())
        w.cc = 0
        w.sel = False
        w.insert_text(random_line(rng, 1 + rng.next(4)), ACT_OTHER)
        if rng.next(3) == 0:
            w.newline(False)
        var want = ref_states(w)
        for _ in range(5):
            var row = rng.next(w.buf.count())
            assert_equal(w.lex_state_at(row), want[row], "step " + String(step) + " row " + String(row))
        if step % 10 == 0:
            w.sync_lex(w.buf.count())


def test_message_windows_are_not_lexed() raises:
    var w = Window(WK_MESSAGE, "Message", "", 0, 0, 60, 8, 2)
    w.buf.load(decode("\"\"\"not code\nline two\n"))
    w.sync_lex(10)
    assert_equal(len(w.buf.lstate), 1)
    assert_equal(w.lex_state_at(1), 0)


# ------------------------------------------------------------------ drawing
def test_view_starting_inside_a_docstring_is_coloured_as_string() raises:
    var text = String("\"\"\"\n")
    for i in range(100):
        text += "def not_code_" + String(i) + "():\n"
    text += "\"\"\"\ndef real():\n"
    var w = win(text)
    var p = theme(0)
    var h = Highlighter()
    var s = Screen(60, 12)
    w.top = 50
    w.sync_lex(w.top + 12)
    w.draw(s, p, h, True, False, True, False)
    assert_equal(s.fg_at(1, 1), p.syn[C_STR], "'def' inside the docstring is string-coloured")
    # after the docstring ends, the same word is a keyword again
    w.top = 102
    w.sync_lex(w.top + 12)
    w.draw(s, p, h, True, False, True, False)
    assert_equal(s.fg_at(1, 1), p.syn[C_KW])
    # drawing without a sync still gives the right colours (slow path)
    var v = win(text)
    v.top = 50
    v.draw(s, p, h, True, False, True, False)
    assert_equal(s.fg_at(1, 1), p.syn[C_STR])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
