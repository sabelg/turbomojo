"""Tests for multi-cursor power editing and IDE token-verified fallback rename."""
from std.testing import assert_equal, assert_true, TestSuite
from app import *
from appstate import App, M_DIALOG
from window import Cur
from dialog import D_RENAME, D_RENAME_APPLY
from commands import CM_SELECT_ALL_OCC, CM_COMMENT, CM_UPPER, CM_LOWER, CM_RENAME, CM_UNDO
from term import key_event, KEY_TAB, KEY_BACKSPACE, KEY_ENTER, MOD_SHIFT, MOD_CTRL
from signals import own_pid
from util import decode, to_str, env_or, run_system, write_file, str_bytes, shell_quote


def test_multicursor_select_all_tab_comment_worddel_and_case() raises:
    var d = env_or("TMPDIR", "/tmp") + "/tm-mc-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var cu = d + "/kern.cu"
    _ = write_file(cu, str_bytes("alpha_val = 1;\nalpha_val = 2;\nother = alpha_val;\n"))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(cu)
    var ei = app.find_editor(cu)

    # 1. Select every occurrence of `alpha_val`
    app.wins[ei].goto(0, 2)
    app.exec(CM_SELECT_ALL_OCC)
    assert_equal(len(app.wins[ei].extra), 2)

    # 2. Case transform across all 3 selections + Undo
    app.exec(CM_UPPER)
    assert_true(to_str(app.wins[ei].buf.line(0)).startswith("ALPHA_VAL"))
    assert_true(to_str(app.wins[ei].buf.line(2)).find("ALPHA_VAL") > 0)
    app.exec(CM_LOWER)
    assert_true(to_str(app.wins[ei].buf.line(0)).startswith("alpha_val"))

    # 3. Multi-cursor Ctrl-Backspace deletes word left on every cursor simultaneously
    app.wins[ei].extra.clear()
    app.wins[ei].sel = False
    app.wins[ei].goto(0, 9)
    app.wins[ei].extra.append(Cur(1, 9, False, 1, 9, 9))
    app.handle(key_event(KEY_BACKSPACE | MOD_CTRL))
    assert_equal(to_str(app.wins[ei].buf.line(0)), " = 1;")
    assert_equal(to_str(app.wins[ei].buf.line(1)), " = 2;")

    # 4. Multi-cursor Tab indents lines and Shift-Tab unindents
    app.wins[ei].goto(0, 0)
    app.wins[ei].extra.clear()
    app.wins[ei].extra.append(Cur(1, 0, False, 1, 0, 0))
    app.handle(key_event(KEY_TAB))
    assert_true(to_str(app.wins[ei].buf.line(0)).startswith("     = 1;"))
    assert_true(to_str(app.wins[ei].buf.line(1)).startswith("     = 2;"))
    app.handle(key_event(KEY_TAB | MOD_SHIFT))
    assert_equal(to_str(app.wins[ei].buf.line(0)), " = 1;")

    # 5. Language-aware Ctrl-/ uses `//` in C/CUDA files!
    app.exec(CM_COMMENT)
    assert_true(String(to_str(app.wins[ei].buf.line(0)).lstrip()).startswith("//"))
    assert_true(String(to_str(app.wins[ei].buf.line(1)).lstrip()).startswith("//"))
    app.exec(CM_COMMENT)
    assert_equal(to_str(app.wins[ei].buf.line(0)), " = 1;")

    _ = run_system("rm -rf " + shell_quote(d))


def test_token_verified_fallback_rename_skips_comments_and_strings() raises:
    var d = env_or("TMPDIR", "/tmp") + "/tm-ren-fb-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var a = d + "/a.mojo"
    var b = d + "/b.mojo"
    _ = write_file(
        a,
        str_bytes(
            "def compute(total: Int) -> Int:\n    # total in a comment must stay total\n    var msg = \"total in string\"\n    return total + 1\n"
        ),
    )
    _ = write_file(b, str_bytes("from a import compute\n# total untouched\nvar total = compute(5)\n"))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.project_dir = d
    app.open_path(a)
    var ei = app.find_editor(a)
    app.wins[ei].goto(0, 13)  # on `total`

    # With no LSP active, Shift-F2 launches IDE token-verified fallback rename
    app.exec(CM_RENAME)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_RENAME)
    assert_true(app.ren_local)
    app.dlg.fields[0].text = decode("sum_val")
    app.handle(key_event(KEY_ENTER))
    # Because `b.mojo` is also affected, `offer_edit` asks for confirmation via `D_RENAME_APPLY`
    if app.mode == M_DIALOG and app.dlg.kind == D_RENAME_APPLY:
        app.handle(key_event(KEY_ENTER))

    ei = app.find_editor(a)
    # Open buffer `a.mojo` updated in code tokens ONLY; comment & string literal preserved!
    assert_equal(to_str(app.wins[ei].buf.line(0)), "def compute(sum_val: Int) -> Int:")
    assert_equal(to_str(app.wins[ei].buf.line(1)), "    # total in a comment must stay total")
    assert_equal(to_str(app.wins[ei].buf.line(2)), "    var msg = \"total in string\"")
    assert_equal(to_str(app.wins[ei].buf.line(3)), "    return sum_val + 1")

    # Closed project file `b.mojo` was opened and updated in memory cleanly (nothing saved behind user's back)!
    var eb = app.find_editor(b)
    assert_true(eb >= 0)
    var b_txt = to_str(app.wins[eb].buf.all_text())
    assert_true(b_txt.find("# total untouched") >= 0, b_txt)
    assert_true(b_txt.find("var sum_val = compute(5)") >= 0, b_txt)

    # Single Undo in `a.mojo` reverts both code occurrences at once
    app.focus(ei)
    ei = app.find_editor(a)
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[ei].buf.line(0)), "def compute(total: Int) -> Int:")
    assert_equal(to_str(app.wins[ei].buf.line(3)), "    return total + 1")

    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
