"""E2E Test Suite for v3.0 Phase 18 (v2.9):
Inline AI Transform (`CM_INLINE_AI`), Closed-Loop Mojo 1.2 Compiler Self-Healing Verification,
and Local `max serve` / OpenAI-Compatible FIM Ghost Text (`Tab`, `Ctrl-Right`, `Esc`).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from std.time import perf_counter_ns
from app import App
from screen import CONT
from term import KEY_TAB, KEY_RIGHT, KEY_ESC, MOD_CTRL
from commands import CM_INLINE_AI, CM_AI_VERIFY_TOGGLE, CM_FIM_GHOST
from dialog import D_NONE, D_INLINE_AI
from signals import own_pid
from util import env_or, run_system, write_file, str_bytes, bytes_to_str, to_str


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v30-p18-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def _screen_text(app: App) -> String:
    var cps = List[Int]()
    for y in range(app.scr.h):
        for x in range(app.scr.w):
            var c = app.scr.ch[y * app.scr.w + x]
            if c == CONT:
                continue
            cps.append(c if c >= 32 else 32)
        cps.append(10)
    return to_str(cps)


def test_p18_01_verified_patch_mode_self_healing_compiler_loop() raises:
    """Attempt 1 emits invalid legacy `fn` Mojo; shadow `mojo build` catches the error and feeds
    compiler diagnostics back so Attempt 2 self-heals to valid Mojo 1.2 `def` before showing diff!"""
    var d = _scratch("verify")
    try:
        # Mock OpenAI endpoint script:
        # - If prompt contains "failed to compile" (repair turn), emits valid Mojo 1.2 `def square(x: Int) -> Int:`
        # - Otherwise (Attempt 1), emits broken legacy `fn square(x: Int) -> Int:` (`let y = x * x`)
        var mock_py = d + "/mock_ai.py"
        var py_code = (
            "import json, sys\n"
            "req = sys.stdin.read()\n"
            "if 'Compiler Diagnostics' in req:\n"
            "    code = 'def square(x: Int) -> Int:\\n    var y = x * x\\n    return y'\n"
            "else:\n"
            "    code = 'fn square(x: Int) -> Int:\\n    let y = x * x\\n    return y'\n"
            "print(json.dumps({'choices': [{'message': {'content': code}}]}))\n"
        )
        assert_true(write_file(mock_py, str_bytes(py_code)))

        var src_p = d + "/math_fn.mojo"
        var orig_src = (
            "def square(x: Int) -> Int:\n"
            "    return 0\n\n"
            "def main():\n"
            "    print(square(7))\n"
        )
        assert_true(write_file(src_p, str_bytes(orig_src)))

        var app = App()
        app.cwd = d
        app.scr.resize(100, 30)
        var pixi_mojo = env_or("MODULAR_HOME", "")
        if pixi_mojo.byte_length() > 0:
            app.compiler = "/home/user/turbomojo/.pixi/envs/default/bin/mojo"
        app.ai_inline_endpoint = "cmd:python3 '" + mock_py + "'"
        app.ai_verify_edits = True
        app.open_path(src_p)
        var ei = app.find_editor(src_p)
        assert_true(ei >= 0)

        # Select lines 0..1 (`def square ... return 0`)
        app.wins[ei].ar = 0
        app.wins[ei].ac = 0
        app.wins[ei].cr = 1
        app.wins[ei].cc = app.wins[ei].buf.llen(1)
        app.wins[ei].sel = True

        app.exec(CM_INLINE_AI)
        assert_equal(app.dlg.kind, D_INLINE_AI)
        app.dlg.kind = D_NONE
        app.inline_ai_apply("compute x squared")
        if app.dlg.kind != D_NONE:
            app.dialog_button(0)

        ei = app.find_editor(src_p)
        var updated = bytes_to_str(app.wins[ei].buf.to_bytes())
        assert_true(updated.find("def square(x: Int) -> Int:") >= 0, updated)
        assert_true(updated.find("var y = x * x") >= 0, updated)
        assert_equal(updated.find("fn square"), -1)
        assert_true(app.status.find("verified by mojo build (2 attempts)") >= 0, app.status)

        # Toggle AI verify mode command
        app.config_path = d + "/config.toml"
        app.exec(CM_AI_VERIFY_TOGGLE)
        assert_false(app.ai_verify_edits)
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_p18_02_fim_ghost_text_render_word_accept_full_accept_and_esc() raises:
    """FIM ghost text renders dimmed italic at cursor EOL, accepts word-by-word on Ctrl-Right,
    accepts full remainder on Tab, and dismisses cleanly on Esc."""
    var d = _scratch("fim")
    try:
        var fim_py = d + "/mock_fim.py"
        var py_code = (
            "import json, sys\n"
            "_ = sys.stdin.read()\n"
            "print(json.dumps({'choices': [{'message': {'content': 'alpha + beta'}}]}))\n"
        )
        assert_true(write_file(fim_py, str_bytes(py_code)))

        var app = App()
        app.cwd = d
        app.scr.resize(100, 28)
        app.ai_inline_endpoint = "cmd:python3 '" + fim_py + "'"
        var fim_src_p = d + "/fim_demo.mojo"
        assert_true(write_file(fim_src_p, str_bytes("def main():\n    var total = \n")))
        app.open_path(fim_src_p)
        var ei = app.find_editor(fim_src_p)
        assert_true(ei >= 0)
        app.wins[ei].goto(1, 16)

        # Trigger async FIM request and pump `fim_tick()`
        app.exec(CM_FIM_GHOST)
        var t0 = Int(perf_counter_ns())
        while app.fim_fd >= 0 and (Int(perf_counter_ns()) - t0 < 5_000_000_000):
            app.fim_tick()
            _ = external_call["usleep", Int32](UInt32(10000))
        assert_equal(app.wins[ei].ghost_text, "alpha + beta")

        # Draw screen and verify ghost text appears visually on row 1 without mutating buffer yet
        app.draw()
        assert_true(_screen_text(app).find("var total = alpha + beta") >= 0)
        assert_equal(to_str(app.wins[ei].buf.line(1)), "    var total = ")

        # Ctrl-Right accepts first word (`alpha`) and keeps ` + beta` as ghost text
        app.handle_key(KEY_RIGHT | MOD_CTRL)
        assert_equal(to_str(app.wins[ei].buf.line(1)), "    var total = alpha")
        assert_equal(app.wins[ei].ghost_text, " + beta")

        # Tab at EOL accepts the rest (` + beta`)
        app.handle_key(KEY_TAB)
        assert_equal(to_str(app.wins[ei].buf.line(1)), "    var total = alpha + beta")
        assert_equal(app.wins[ei].ghost_text, "")

        # Esc dismisses active ghost text without mutating buffer
        app.wins[ei].ghost_text = " + gamma"
        app.wins[ei].ghost_row = 1
        app.handle_key(KEY_ESC)
        assert_equal(app.wins[ei].ghost_text, "")
        assert_equal(to_str(app.wins[ei].buf.line(1)), "    var total = alpha + beta")
    finally:
        _ = run_system("rm -rf '" + d + "'")


def main() raises:
    var suite = TestSuite()
    suite.test[test_p18_01_verified_patch_mode_self_healing_compiler_loop]()
    suite.test[test_p18_02_fim_ghost_text_render_word_accept_full_accept_and_esc]()
    suite^.run()
