"""Tests for Mojo 1.2 synthesized quick fixes and tab-stop snippet engine (src/snippets.mojo)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from snippets import expand_snippet_full, mojo_snippets, synthesize_mojo_quickfixes
from buffer import TextBuffer
from app import *
from appstate import App, M_NORMAL, M_COMPLETE, M_DIALOG
from dialog import D_ACTIONS
from commands import CM_NEW, CM_COMPLETE, CM_ACTIONS
from term import key_event, KEY_ENTER, KEY_TAB, KEY_ESC, MOD_SHIFT
from signals import own_pid
from util import decode, to_str, env_or, run_system, write_file, str_bytes, shell_quote


def _buf_of(s: String) -> TextBuffer:
    var b = TextBuffer()
    b.load(decode(s))
    return b^


def test_snippet_tabstop_expansion() raises:
    var exp = expand_snippet_full("def ${1:name}(${2:x}: Int) -> ${3:Int}:\n    ${0:return 0}", "    ")
    assert_equal(exp.text, "def name(x: Int) -> Int:\n        return 0")
    assert_equal(len(exp.stops), 4)
    # Ordered $1, $2, $3, then $0 last
    assert_equal(exp.stops[0].num, 1)
    assert_equal(exp.stops[1].num, 2)
    assert_equal(exp.stops[2].num, 3)
    assert_equal(exp.stops[3].num, 0)
    assert_equal(exp.stops[0].start, 4)
    assert_equal(exp.stops[0].end, 8)


def test_mirrored_tabstops_multi_cursor() raises:
    var exp = expand_snippet_full("var ${1:foo} = ${1:foo} + 1", "    ")
    assert_equal(exp.text, "var foo = foo + 1")
    assert_equal(len(exp.stops), 2)
    assert_equal(exp.stops[0].num, 1)
    assert_equal(exp.stops[1].num, 1)


def test_builtin_mojo_snippets_are_modern_mojo_12() raises:
    var snips = mojo_snippets()
    assert_true(len(snips) >= 9)
    var saw_gpu = False
    var saw_pymod = False
    var saw_struct = False
    for sn in snips:
        assert_true(sn.body.find("fn ") < 0, "no removed fn keyword in snippets")
        assert_true(sn.body.find("alias ") < 0, "no removed alias keyword in snippets")
        assert_true(sn.body.find("inout ") < 0, "no removed inout keyword in snippets")
        if sn.trigger == "gpu":
            saw_gpu = True
            assert_true(sn.body.find("from max.gpu import global_idx") >= 0)
            assert_true(sn.body.find("MutPointer") >= 0)
        elif sn.trigger == "pymod":
            saw_pymod = True
            assert_true(sn.body.find("PyInit_") >= 0)
            assert_true(sn.body.find("abi(\"C\")") >= 0)
        elif sn.trigger == "struct":
            saw_struct = True
            assert_true(sn.body.find("@fieldwise_init") >= 0)
    assert_true(saw_gpu and saw_pymod and saw_struct)


def test_synthesized_mojo_12_quickfixes() raises:
    var empty_m = List[String]()
    var empty_c = List[Int]()

    # 1. stdlib & gpu import fixes
    var b_imp = _buf_of("from collections import List\nfrom gpu import thread_idx\n")
    var f_std = synthesize_mojo_quickfixes(b_imp, 0, 5, empty_m, empty_c, empty_c)
    assert_true(len(f_std) >= 1 and f_std[0].new_text == "from std.collections import List")
    var f_gpu = synthesize_mojo_quickfixes(b_imp, 1, 5, empty_m, empty_c, empty_c)
    assert_true(len(f_gpu) >= 1 and f_gpu[0].new_text == "from max.gpu import thread_idx")

    # 2. Legacy keywords: fn -> def, alias -> comptime, let -> var, @value -> @fieldwise_init
    var b_kw = _buf_of("fn compute(inout x: Int, owned s: String):\n    alias N = 4\n    let y = x + N\n@value\n")
    var f_fn = synthesize_mojo_quickfixes(b_kw, 0, 0, empty_m, empty_c, empty_c)
    var titles0 = String("")
    for fx in f_fn:
        titles0 += fx.title + " | "
    assert_true(titles0.find("def") >= 0 and titles0.find("mut") >= 0 and titles0.find("var") >= 0, titles0)
    var f_alias = synthesize_mojo_quickfixes(b_kw, 1, 4, empty_m, empty_c, empty_c)
    assert_true(len(f_alias) >= 1 and f_alias[0].new_text == "    comptime N = 4")
    var f_let = synthesize_mojo_quickfixes(b_kw, 2, 4, empty_m, empty_c, empty_c)
    assert_true(len(f_let) >= 1 and f_let[0].new_text == "    var y = x + N")
    var f_val = synthesize_mojo_quickfixes(b_kw, 3, 0, empty_m, empty_c, empty_c)
    assert_true(len(f_val) >= 1 and f_val[0].new_text.find("@fieldwise_init") >= 0)

    # 3. inout self in __init__ -> out self
    var b_init = _buf_of("    def __init__(inout self, v: Int):\n        self.v = v\n")
    var f_init = synthesize_mojo_quickfixes(b_init, 0, 17, empty_m, empty_c, empty_c)
    assert_true(len(f_init) >= 1 and f_init[0].new_text == "out" and f_init[0].title.find("out self") >= 0)

    # 4. Missing `var`, missing `raises`, implicit copy, and len(s) -> s.byte_length()
    var b_body = _buf_of("def load_data(items: List[String]):\n    count = 10\n    var dup = items\n    var n = len(s)\n")
    var f_var = synthesize_mojo_quickfixes(b_body, 1, 4, empty_m, empty_c, empty_c)
    assert_true(len(f_var) >= 1 and f_var[0].new_text == "var ")

    var dm_raises = List[String]()
    dm_raises.append("call can raise, function is not marked 'raises'")
    var dc1 = List[Int]()
    dc1.append(4)
    var dc2 = List[Int]()
    dc2.append(12)
    var f_raises = synthesize_mojo_quickfixes(b_body, 1, 4, dm_raises, dc1, dc2)
    var saw_raises = False
    for fx in f_raises:
        if fx.r1 == 0 and fx.new_text.find("raises") >= 0:
            saw_raises = True
    assert_true(saw_raises)

    var dm_copy = List[String]()
    dm_copy.append("value of type 'List[String]' cannot be implicitly copied")
    var f_copy = synthesize_mojo_quickfixes(b_body, 2, 14, dm_copy, dc1, dc2)
    var copy_titles = String("")
    for fx in f_copy:
        copy_titles += fx.new_text + "|"
    assert_true(copy_titles.find(".copy()") >= 0 and copy_titles.find("^") >= 0, copy_titles)

    var dm_len = List[String]()
    dm_len.append("no matching function 'len' for String")
    var f_len = synthesize_mojo_quickfixes(b_body, 3, 12, dm_len, dc1, dc2)
    var saw_blen = False
    for fx in f_len:
        if fx.new_text == "s.byte_length()":
            saw_blen = True
    assert_true(saw_blen)


def test_app_snippet_tab_jump_and_quickfix_dialog() raises:
    var d = env_or("TMPDIR", "/tmp") + "/tm-qf-snip-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var p = d + "/demo.mojo"
    _ = write_file(p, str_bytes("fn old_add(x: Int) -> Int:\n    return x\n\ncomptime\n"))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(p)
    var ei = app.find_editor(p)

    # Alt-Enter on `fn` opens quick-fix picker even without an active LSP server
    app.wins[ei].goto(0, 0)
    app.exec(CM_ACTIONS)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_ACTIONS)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[ei].buf.line(0)), "def old_add(x: Int) -> Int:")

    # Ctrl-Space at end of `comptime` offers built-in Mojo 1.2 snippet and Tab jumps $1 -> $0
    app.wins[ei].goto(3, 8)
    app.exec(CM_COMPLETE)
    assert_equal(app.mode, M_COMPLETE)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[ei].buf.line(3)), "comptime NAME = 0")
    assert_true(app.wins[ei].has_sel())
    # Type replacement for $1 (`NAME`), then press Tab to jump to $0 (`0`)
    app.handle(key_event(75))  # 'K'
    assert_equal(to_str(app.wins[ei].buf.line(3)), "comptime K = 0")
    app.handle(key_event(KEY_TAB))
    assert_equal(app.wins[ei].ac, 13)
    assert_equal(app.wins[ei].cc, 14)
    app.handle(key_event(KEY_TAB | MOD_SHIFT))
    assert_equal(app.wins[ei].ac, 9)
    assert_equal(app.wins[ei].cc, 10)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.snip_wid, -1)

    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
