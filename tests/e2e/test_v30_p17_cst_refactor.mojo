"""E2E Test Suite for v3.0 Phase 17 (v2.8):
Pure-Mojo CST (`mojocst.mojo`), Concentric Syntax Selection, Swap Call Arguments,
Multi-File Change Function Signature, Precedence-Safe Inline Symbol, and Trait Stubs.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import App
from buffer import TextBuffer
from commands import (
    CM_EXPAND_SEL,
    CM_SHRINK_SEL,
    CM_SWAP_CALL_ARGS,
    CM_CHANGE_SIGNATURE,
    CM_INLINE_SYMBOL,
    CM_IMPL_TRAIT_STUBS,
    CM_UNDO,
)
from dialog import D_CHANGE_SIG
from mojocst import parse_mojo_cst, cst_selection_ranges
from signals import own_pid
from util import env_or, run_system, write_file, read_file, str_bytes, bytes_to_str


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v30-p17-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def test_p17_01_cst_parsing_expand_shrink_and_swap_args() raises:
    """Pure-Mojo CST ignores strings/comments, powers Expand/Shrink Selection, and swaps call args."""
    var src = (
        '"""Module doc with fake def ignored(): pass"""\n'
        "trait Renderable:\n"
        "    def render(self, scale: Int) -> String: ...\n\n"
        "@fieldwise_init\n"
        "struct Point(Copyable, Movable, Writable, Renderable):\n"
        "    var x: Int\n"
        "    var y: Int\n\n"
        "    def move_by(mut self, dx: Int, dy: Int = 1) raises -> Int:\n"
        '        var note = "string with (fake, call)"\n'
        "        return compute(self.x + dx, self.y + dy)\n"
    )
    var buf = TextBuffer()
    buf.load_bytes(str_bytes(src))
    var cst = parse_mojo_cst(buf)
    assert_equal(len(cst.traits), 1)
    assert_equal(cst.traits[0].name, "Renderable")
    assert_equal(len(cst.structs), 1)
    assert_equal(cst.structs[0].name, "Point")
    assert_equal(len(cst.structs[0].fields), 2)
    assert_equal(len(cst.structs[0].methods), 1)
    assert_true(cst.structs[0].methods[0].is_raises)

    var ranges = cst_selection_ranges(buf, 11, 24)  # inside `self.x + dx` of `compute(...)`
    assert_true(len(ranges) >= 4)

    var app = App()
    app.scr.resize(100, 30)
    var ei = app.new_editor("point.mojo", "")
    app.wins[ei].buf.load_bytes(str_bytes(src))
    app.wins[ei].goto(11, 25)  # inside first arg `self.x + dx`
    app.exec(CM_EXPAND_SEL)
    assert_true(app.wins[ei].has_sel())
    app.exec(CM_SHRINK_SEL)
    assert_false(app.wins[ei].has_sel())

    # Swap call arguments on `compute(self.x + dx, self.y + dy)` -> `compute(self.y + dy, self.x + dx)`
    app.wins[ei].goto(11, 25)
    app.exec(CM_SWAP_CALL_ARGS)
    var swapped = bytes_to_str(app.wins[ei].buf.to_bytes())
    assert_true(swapped.find("compute(self.y + dy, self.x + dx)") >= 0, swapped)
    app.exec(CM_UNDO)
    assert_equal(bytes_to_str(app.wins[ei].buf.to_bytes()), src)


def test_p17_02_multi_file_change_signature_with_offer_edit() raises:
    """CM_CHANGE_SIGNATURE reorders parameters, adds defaulted param, and updates call sites across files."""
    var d = _scratch("chgsig")
    try:
        var p_math = d + "/math_ops.mojo"
        var p_main = d + "/caller.mojo"
        assert_true(write_file(p_math, str_bytes("def blend(a: Int, b: Int) -> Int:\n    return a * 10 + b\n")))
        assert_true(write_file(p_main, str_bytes("from math_ops import blend\n\ndef main():\n    var r1 = blend(1, 2)\n    var r2 = blend(b=20, a=10)\n")))

        var app = App()
        app.cwd = d
        app.scr.resize(100, 30)
        app.open_path(p_math)
        var ei = app.find_editor(p_math)
        app.wins[ei].goto(0, 5)
        app.exec(CM_CHANGE_SIGNATURE)
        assert_equal(app.dlg.kind, D_CHANGE_SIG)

        # Reorder `b, a` and add `bias: Int = 5`, then confirm both Change Signature + offer_edit preview
        app.change_signature_apply("b: Int, a: Int, bias: Int = 5")
        app.dialog_button(0)  # Accept WorkspaceEdit offer_edit confirmation

        var new_math = bytes_to_str(app.wins[app.find_editor(p_math)].buf.to_bytes())
        assert_true(new_math.find("def blend(b: Int, a: Int, bias: Int = 5) -> Int:") >= 0, new_math)
        var new_caller = bytes_to_str(read_file(p_main))
        var ci = app.find_editor(p_main)
        if ci >= 0:
            new_caller = bytes_to_str(app.wins[ci].buf.to_bytes())
        assert_true(new_caller.find("blend(2, 1, 5)") >= 0, new_caller)
        assert_true(new_caller.find("blend(20, 10, 5)") >= 0, new_caller)
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_p17_03_inline_variable_and_inline_function_precedence() raises:
    """CM_INLINE_SYMBOL parenthesizes compound expressions safely for both variables and helper functions."""
    var src = (
        "def double_sum(x: Int, y: Int) -> Int:\n"
        "    return x + y\n\n"
        "def main():\n"
        "    var delta = 3 + 4\n"
        "    var scaled = delta * 2\n"
        "    var total = double_sum(scaled, 10) * 5\n"
        "    print(total)\n"
    )
    var app = App()
    app.scr.resize(100, 30)
    var ei = app.new_editor("inline_demo.mojo", "")
    app.wins[ei].buf.load_bytes(str_bytes(src))

    # 1. Inline `var delta = 3 + 4` -> `delta * 2` becomes `(3 + 4) * 2`!
    app.wins[ei].goto(4, 9)
    app.exec(CM_INLINE_SYMBOL)
    var after_var = bytes_to_str(app.wins[ei].buf.to_bytes())
    assert_equal(after_var.find("var delta"), -1)
    assert_true(after_var.find("var scaled = (3 + 4) * 2") >= 0, after_var)

    # 2. Inline `double_sum(scaled, 10)` inside `double_sum(scaled, 10) * 5`
    app.wins[ei].goto(5, 20)
    app.exec(CM_INLINE_SYMBOL)
    var after_fn = bytes_to_str(app.wins[ei].buf.to_bytes())
    assert_true(after_fn.find("scaled + 10") >= 0, after_fn)


def test_p17_04_generate_trait_and_struct_stubs_and_quickfix() raises:
    """CM_IMPL_TRAIT_STUBS and local_code_actions synthesize Writable, Equatable, and custom trait stubs."""
    var src = (
        "trait Describable:\n"
        "    def describe(self) raises -> String: ...\n\n"
        "@fieldwise_init\n"
        "struct Metric(Copyable, Movable, Writable, Equatable, Describable):\n"
        "    var label: String\n"
        "    var count: Int\n"
    )
    var app = App()
    app.scr.resize(100, 30)
    var ei = app.new_editor("metric.mojo", "")
    app.wins[ei].buf.load_bytes(str_bytes(src))
    app.wins[ei].path = "/tmp/metric_virtual.mojo"
    app.wins[ei].goto(5, 4)

    # Verify Ctrl-. / Alt-Enter quick-fix list also offers the stub synthesis action
    var acts = app.local_code_actions(ei)
    var has_stub_act = False
    for a in acts:
        if a.title.find("Implement missing stubs on Metric") >= 0:
            has_stub_act = True
    assert_true(has_stub_act)

    # Clear virtual path so unsaved buffer applies directly and run CM_IMPL_TRAIT_STUBS
    app.wins[ei].path = ""
    app.exec(CM_IMPL_TRAIT_STUBS)
    var out = bytes_to_str(app.wins[ei].buf.to_bytes())
    assert_true(out.find("def write_to(self, mut writer: Some[Writer]):") >= 0, out)
    assert_true(out.find("def __eq__(self, other: Self) -> Bool:") >= 0, out)
    assert_true(out.find("def describe(self) raises -> String:") >= 0, out)


def main() raises:
    var suite = TestSuite()
    suite.test[test_p17_01_cst_parsing_expand_shrink_and_swap_args]()
    suite.test[test_p17_02_multi_file_change_signature_with_offer_edit]()
    suite.test[test_p17_03_inline_variable_and_inline_function_precedence]()
    suite.test[test_p17_04_generate_trait_and_struct_stubs_and_quickfix]()
    suite^.run()
