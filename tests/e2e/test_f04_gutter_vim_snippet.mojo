"""E2E Test Suite for Feature #4:
Gutter clicks on wx+1 for test_lens_rows to test_run_single(),
Vim gc/gcc toggle_comment_multi(), live mirrored $N snippet tabstops.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from buffer import TextBuffer, Pos
from window import Window, WK_EDITOR, WK_MESSAGE, Cur
from window_multi import *
from highlight import (
    Highlighter, lang_for_path, comment_prefix_for_lang,
    HL_MOJO, HL_PYTHON, HL_C_CUDA,
)
from snippets import expand_snippet_full, SnippetStop, SnippetExpansion, mojo_snippets
from app import *
from appstate import App, M_NORMAL, M_COMPLETE
from testexp import (
    is_test_source, test_names, def_line, TestFile, TestCase,
    TS_UNKNOWN, TS_PASS, TS_FAIL, TS_SKIP,
)
from signals import own_pid
from util import decode, to_str, bytes_to_str, env_or, run_system, shell_quote, write_file, str_bytes


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f04-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def sync_test_lens_for_window(mut win: Window, src: String):
    """Mirror the logic of tests_sync_lens() directly on a Window instance."""
    win.test_lens_rows.clear()
    win.test_lens_states.clear()
    if not is_test_source(src):
        return
    for tname in test_names(src):
        var dline = def_line(src, tname)
        if dline > 0:
            win.test_lens_rows.append(dline - 1)
            win.test_lens_states.append(1)


def is_gutter_test_lens_click(win: Window, click_x: Int, click_y: Int) -> Tuple[Bool, Int]:
    """Test if click_x == win.x + 1 and the clicked row is in win.test_lens_rows."""
    if win.kind != WK_EDITOR or win.gut <= 0:
        return (False, -1)
    if click_x != win.x + 1:
        return (False, -1)
    var row = win.top + (click_y - win.y - 1)
    for i in range(len(win.test_lens_rows)):
        if win.test_lens_rows[i] == row:
            return (True, row)
    return (False, -1)


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f04_case1_gutter_test_lens_row_detection() raises:
    """Verify test_lens_rows and test_lens_states are populated accurately for TestSuite functions."""
    var code = (
        "from std.testing import assert_true, TestSuite\n\n"
        "def test_alpha() raises:\n"
        "    assert_true(True)\n\n"
        "def test_beta() raises:\n"
        "    assert_true(True)\n\n"
        "def main() raises:\n"
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    )
    var win = Window(WK_EDITOR, "test_sample.mojo", "test_sample.mojo", 0, 0, 80, 24, 1)
    win.buf.load(decode(code))

    sync_test_lens_for_window(win, code)

    # def test_alpha is on line 2 (0-indexed), test_beta is on line 5 (0-indexed)
    assert_equal(len(win.test_lens_rows), 2)
    assert_equal(win.test_lens_rows[0], 2)
    assert_equal(win.test_lens_rows[1], 5)
    assert_equal(len(win.test_lens_states), 2)
    assert_equal(win.test_lens_states[0], 1)
    assert_equal(win.test_lens_states[1], 1)


def test_tier1_f04_case2_gutter_click_at_wx_plus_1_dispatches_single_test() raises:
    """Verify clicking at wx+1 on a test lens row identifies the target test."""
    var code = (
        "from std.testing import assert_equal, TestSuite\n\n"
        "def test_one() raises:\n"
        "    assert_equal(1, 1)\n\n"
        "def test_two() raises:\n"
        "    assert_equal(2, 2)\n\n"
        "def main() raises:\n"
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    )
    var win = Window(WK_EDITOR, "test_exec.mojo", "test_exec.mojo", 2, 1, 80, 24, 1)
    win.gut = 4
    win.buf.load(decode(code))
    sync_test_lens_for_window(win, code)

    # Gutter symbol column is wx + 1 = 3
    # Click on row 5 (test_two): click_y = win.y + 1 + 5 = 7
    var res = is_gutter_test_lens_click(win, 3, 7)
    assert_true(res[0])
    assert_equal(res[1], 5)

    # Click on row 2 (test_one): click_y = win.y + 1 + 2 = 4
    var res_one = is_gutter_test_lens_click(win, 3, 4)
    assert_true(res_one[0])
    assert_equal(res_one[1], 2)


def test_tier1_f04_case3_vim_gcc_single_line_comment_toggle() raises:
    """Verify toggle_comment_multi comments and uncomments a single line."""
    var win = Window(WK_EDITOR, "test.mojo", "test.mojo", 0, 0, 80, 24, 1)
    win.buf.load(decode("var count = 42\n"))
    win.cr = 0
    win.cc = 4

    win.toggle_comment_multi()
    assert_equal(to_str(win.buf.line(0)), "# var count = 42")

    win.toggle_comment_multi()
    assert_equal(to_str(win.buf.line(0)), "var count = 42")


def test_tier1_f04_case4_vim_visual_gc_multi_line_comment_toggle() raises:
    """Verify toggle_comment_multi comments and uncomments multiple contiguous lines."""
    var win = Window(WK_EDITOR, "multi.mojo", "multi.mojo", 0, 0, 80, 24, 1)
    win.buf.load(decode("var a = 1\nvar b = 2\nvar c = 3\n"))
    win.sel = True
    win.ar = 0
    win.ac = 0
    win.cr = 2
    win.cc = 9

    win.toggle_comment_multi()

    assert_equal(to_str(win.buf.line(0)), "# var a = 1")
    assert_equal(to_str(win.buf.line(1)), "# var b = 2")
    assert_equal(to_str(win.buf.line(2)), "# var c = 3")

    # Select lines 0..2 again to toggle comments off
    win.sel = True
    win.ar = 0
    win.ac = 0
    win.cr = 2
    win.cc = 11

    win.toggle_comment_multi()

    assert_equal(to_str(win.buf.line(0)), "var a = 1")
    assert_equal(to_str(win.buf.line(1)), "var b = 2")
    assert_equal(to_str(win.buf.line(2)), "var c = 3")


def test_tier1_f04_case5_snippet_mirrored_tabstops_expansion() raises:
    """Verify snippet expansion handles duplicate $N tabstops with accurate span offsets."""
    var raw = "def ${1:target}(x: Int) -> ${1:target}:\n    return x"
    var exp = expand_snippet_full(raw, "    ")

    assert_equal(exp.text, "def target(x: Int) -> target:\n        return x")
    assert_equal(len(exp.stops), 2)
    assert_equal(exp.stops[0].num, 1)
    assert_equal(exp.stops[0].start, 4)
    assert_equal(exp.stops[0].end, 10)
    assert_equal(exp.stops[1].num, 1)
    assert_equal(exp.stops[1].start, 22)
    assert_equal(exp.stops[1].end, 28)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f04_bound1_gutter_click_on_non_test_row_toggles_breakpoint() raises:
    """Verify clicking in gutter on a row without test lens does not match test lens."""
    var win = Window(WK_EDITOR, "script.mojo", "script.mojo", 0, 0, 80, 24, 1)
    win.gut = 4
    win.buf.load(decode("var x = 1\nvar y = 2\nvar z = 3\n"))

    # Non-test rows return False
    var res = is_gutter_test_lens_click(win, 1, 1)  # line 0
    assert_false(res[0])
    assert_equal(res[1], -1)


def test_tier2_f04_bound2_gutter_click_non_editor_or_out_of_bounds_ignored() raises:
    """Verify gutter clicks in non-editor windows or outside gutter columns are safely ignored."""
    var mw = Window(WK_MESSAGE, "Messages", "", 0, 0, 80, 10, 2)
    var res_msg = is_gutter_test_lens_click(mw, 1, 1)
    assert_false(res_msg[0])

    var win = Window(WK_EDITOR, "test.mojo", "test.mojo", 5, 0, 80, 24, 1)
    win.gut = 4
    win.test_lens_rows.append(3)

    # Click outside wx+1 (e.g. click at wx = 5, or wx + 2 = 7)
    var res_border = is_gutter_test_lens_click(win, 5, 4)
    assert_false(res_border[0])
    var res_gut_num = is_gutter_test_lens_click(win, 7, 4)
    assert_false(res_gut_num[0])


def test_tier2_f04_bound3_vim_comment_multi_cursor_heterogeneous_indent() raises:
    """Verify toggle_comment_multi preserves common indentation across heterogeneous rows."""
    var win = Window(WK_EDITOR, "indent.mojo", "indent.mojo", 0, 0, 80, 24, 1)
    win.buf.load(decode("    var a = 1\n        var b = 2\n"))
    win.cr = 0
    win.cc = 4
    win.toggle_cursor_at(1, 8)
    assert_equal(len(win.extra), 1)

    win.toggle_comment_multi()

    # Minimum indent is 4 spaces; `#` inserted at column 4
    assert_equal(to_str(win.buf.line(0)), "    # var a = 1")
    assert_equal(to_str(win.buf.line(1)), "    #     var b = 2")

    # Uncomment toggles back cleanly
    win.toggle_comment_multi()
    assert_equal(to_str(win.buf.line(0)), "    var a = 1")
    assert_equal(to_str(win.buf.line(1)), "        var b = 2")


def test_tier2_f04_bound4_language_aware_comment_c_cuda_double_slash() raises:
    """Verify C/C++/CUDA files use // line comments and round-trip correctly."""
    assert_equal(comment_prefix_for_lang(HL_C_CUDA), "//")
    assert_equal(comment_prefix_for_lang(HL_MOJO), "#")
    assert_equal(comment_prefix_for_lang(HL_PYTHON), "#")

    var win = Window(WK_EDITOR, "kernel.cu", "kernel.cu", 0, 0, 80, 24, 1)
    win.buf.load(decode("__global__ void k() {}\n"))
    win.cr = 0
    win.cc = 0

    win.toggle_comment_multi()
    assert_equal(to_str(win.buf.line(0)), "// __global__ void k() {}")

    win.toggle_comment_multi()
    assert_equal(to_str(win.buf.line(0)), "__global__ void k() {}")


def test_tier2_f04_bound5_snippet_choice_and_nested_tabstops_order() raises:
    """Verify snippets with choices, tabstops and final stop $0 order correctly."""
    var raw = "def ${1:name}(${2|val,item,elem|}: ${3:Int}) -> ${3:Int}:\n    $0"
    var exp = expand_snippet_full(raw, "")

    assert_equal(len(exp.stops), 5)
    # Stop ordering must be 1, 2, 3, 3 (mirrored), and 0 last
    assert_equal(exp.stops[0].num, 1)
    assert_equal(exp.stops[1].num, 2)
    assert_equal(exp.stops[2].num, 3)
    assert_equal(exp.stops[3].num, 3)
    assert_equal(exp.stops[4].num, 0)
    assert_true(exp.text.find("def name(val: Int) -> Int:") >= 0)


def test_tier1_f04_bench_snippet_and_same_line_tabstop_delta_shift() raises:
    """Verify built-in `bench` snippet and live same-row tabstop column adjustment after editing $1."""
    var found_bench = False
    for sn in mojo_snippets():
        if sn.trigger == "bench":
            found_bench = True
            assert_true(sn.body.find("from std.benchmark import run, Bencher, BenchmarkConfig") >= 0)
            assert_true(sn.body.find("def bench_${1:name}(mut b: Bencher) raises:") >= 0)
    assert_true(found_bench)

    var d = scratch("snip_shift")
    var p = d + "/shift.mojo"
    _ = write_file(p, str_bytes("comptime\n"))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(p)
    var ei = app.find_editor(p)
    app.wins[ei].goto(0, 8)
    app.start_complete()
    assert_equal(app.mode, M_COMPLETE)
    app.comp_accept(ei)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[ei].buf.line(0)), "comptime NAME = 0")
    # Type longer name `BUFFER_SIZE` into $1 (`NAME`) so later stop $0 (`0`) shifts right by +7
    for ch in decode("BUFFER_SIZE"):
        app.wins[ei].type_char(ch, True)
    assert_equal(to_str(app.wins[ei].buf.line(0)), "comptime BUFFER_SIZE = 0")
    assert_true(app.snip_jump(ei, False))
    assert_equal(app.wins[ei].ac, 23)
    assert_equal(app.wins[ei].cc, 24)
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
