"""Tests for polyglot syntax highlighting and full extra-server LSP parity."""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from highlight import (
    Highlighter, line_state, lang_for_path, comment_prefix_for_lang,
    HL_MOJO, HL_PYTHON, HL_C_CUDA, HL_TOML, HL_JSON, HL_SHELL_YAML, HL_MARKDOWN,
    C_KW, C_CMT, C_NUM, C_DEF,
)
from app import *
from appstate import App, now_ns, M_NORMAL, M_COMPLETE, M_DIALOG
from lsp import LSP_READY
from dialog import D_RENAME
from commands import CM_LSP, CM_COMPLETE, CM_DEFINITION, CM_REFERENCES, CM_RENAME, CM_SIGNATURE
from config import load_settings
from term import wait_readable, key_event, KEY_ENTER
from signals import own_pid
from util import decode, to_str, env_or, run_system, write_file, str_bytes, shell_quote, getcwd


def _agree(lang: Int, lines: List[String]) raises:
    var hl = Highlighter()
    var st = 0
    var row = List[Int]()
    for s in lines:
        var bs = str_bytes(s)
        var fast = line_state(bs, 0, len(bs), st, lang)
        st = hl.line(decode(s), st, row, lang)
        assert_equal(fast, st, "line_state != Highlighter.line for lang=" + String(lang) + " line=" + s)


def test_polyglot_lang_mapping_and_state_machines() raises:
    assert_equal(lang_for_path("src/main.mojo"), HL_MOJO)
    assert_equal(lang_for_path("scripts/mcp_server.py"), HL_PYTHON)
    assert_equal(lang_for_path("kernels/gemm.cu"), HL_C_CUDA)
    assert_equal(lang_for_path("include/api.hpp"), HL_C_CUDA)
    assert_equal(lang_for_path("pixi.toml"), HL_TOML)
    assert_equal(lang_for_path("package.json"), HL_JSON)
    assert_equal(lang_for_path("scripts/check.sh"), HL_SHELL_YAML)
    assert_equal(lang_for_path(".github/workflows/ci.yml"), HL_SHELL_YAML)
    assert_equal(lang_for_path("README.md"), HL_MARKDOWN)

    assert_equal(comment_prefix_for_lang(HL_C_CUDA), "//")
    assert_equal(comment_prefix_for_lang(HL_MOJO), "#")
    assert_equal(comment_prefix_for_lang(HL_PYTHON), "#")

    _agree(HL_PYTHON, ["async def fetch(x: int) -> str:", "    s = '''multi", "    line'''", "    # done"])
    _agree(HL_C_CUDA, ["#include <cuda.h>", "/* multi-line", "   block comment */", "__global__ void k(float* p) { p[0] = 1.0f; // ok", "}"])
    _agree(HL_TOML, ["[workspace]", "name = \"turbomojo\" # comment", "channels = [\"conda-forge\"]"])
    _agree(HL_JSON, ["{", "  \"ok\": true,", "  \"count\": 42", "}"])
    _agree(HL_SHELL_YAML, ["#!/usr/bin/env bash", "set -euo pipefail # strict", "key: \"value\""])
    _agree(HL_MARKDOWN, ["# Heading", "Some **bold** and `inline` text", "```mojo", "def main():", "    pass", "```"])

    # Verify token classes in CUDA & JSON
    var hl = Highlighter()
    var cols = List[Int]()
    _ = hl.line(decode("__global__ void kern() // note"), 0, cols, HL_C_CUDA)
    assert_equal(cols[0], C_KW)
    assert_equal(cols[16], C_DEF)
    assert_equal(cols[24], C_CMT)

    _ = hl.line(decode("{\"key\": true, \"n\": 12}"), 0, cols, HL_JSON)
    assert_equal(cols[1], C_DEF)   # JSON object key highlighted distinctly from string values
    assert_equal(cols[8], C_KW)    # true
    assert_equal(cols[19], C_NUM)  # 12


def _pump(mut app: App, ms: Int):
    var end = Int(perf_counter_ns()) + ms * 1_000_000
    while Int(perf_counter_ns()) < end:
        _ = wait_readable(app.extra_fds(), 15)
        app.extra_tick(now_ns())


def test_extra_lsp_full_parity_completion_def_refs_rename_sig() raises:
    var d = env_or("TMPDIR", "/tmp") + "/tm-extra-parity-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var py = d + "/mod.py"
    _ = write_file(py, str_bytes("def helper(x):\n    return x + 1\n\nval = helper(10)\n"))

    var fake = "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_rpc_server.py")
    var cfg = "[lsp.pyfake]\ncommand = \"" + fake.replace("\"", "\\\"") + "\"\nextensions = [\".py\"]\n"

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.project_dir = d
    app.apply_settings(load_settings(cfg, ""))
    app.open_path(py)
    app.exec(CM_LSP)
    for _ in range(100):
        _pump(app, 25)
        if len(app.lsp_extra) > 0 and app.lsp_extra[0].client.state == LSP_READY and len(app.lsp_extra[0].client.docs) > 0:
            break
    assert_true(len(app.lsp_extra) == 1 and app.lsp_extra[0].client.state == LSP_READY)

    var ei = app.find_editor(py)
    app.focus(ei)
    ei = app.find_editor(py)
    # 1. Go to definition in .py routes to lsp_extra[0] and jumps to line 0 (`def helper`)
    app.wins[ei].goto(3, 7)
    app.exec(CM_DEFINITION)
    for _ in range(80):
        _pump(app, 25)
        ei = app.find_editor(py)
        if app.wins[ei].cr == 0:
            break
    ei = app.find_editor(py)
    assert_equal(app.wins[ei].cr, 0)

    # 2. Completion in .py routes to lsp_extra[0]
    app.focus(ei)
    ei = app.find_editor(py)
    app.wins[ei].goto(3, 6)
    app.exec(CM_COMPLETE)
    for _ in range(80):
        _pump(app, 25)
        if app.mode == M_COMPLETE and app.comp_srv_have:
            break
    assert_equal(app.mode, M_COMPLETE)
    app.mode = M_NORMAL

    # 3. Signature help inside `helper(10)` routes to lsp_extra[0]
    ei = app.find_editor(py)
    app.focus(ei)
    ei = app.find_editor(py)
    app.wins[ei].goto(3, 13)
    app.exec(CM_SIGNATURE)
    for _ in range(80):
        _pump(app, 25)
        if app.sig_on:
            break
    assert_true(app.sig_on, app.status)
    app.sig_on = False

    # 4. Find references in .py routes to lsp_extra[0]
    ei = app.find_editor(py)
    app.focus(ei)
    ei = app.find_editor(py)
    app.wins[ei].goto(0, 5)
    app.exec(CM_REFERENCES)
    for _ in range(80):
        _pump(app, 25)
        if len(app.errs) >= 2:
            break
    assert_true(len(app.errs) >= 2)

    # 5. Rename symbol in .py routes prepareRename + rename to lsp_extra[0]
    ei = app.find_editor(py)
    app.focus(ei)
    ei = app.find_editor(py)
    app.wins[ei].goto(0, 5)
    app.exec(CM_RENAME)
    for _ in range(80):
        _pump(app, 25)
        if app.mode == M_DIALOG and app.dlg.kind == D_RENAME:
            break
    assert_equal(app.dlg.kind, D_RENAME)
    app.dlg.fields[0].text = decode("assist")
    app.handle(key_event(KEY_ENTER))
    for _ in range(80):
        _pump(app, 25)
        ei = app.find_editor(py)
        if to_str(app.wins[ei].buf.line(0)).find("def assist(") >= 0:
            break
    ei = app.find_editor(py)
    assert_equal(to_str(app.wins[ei].buf.line(0)), "def assist(x):")
    assert_equal(to_str(app.wins[ei].buf.line(3)), "val = assist(10)")

    app.focus(ei)
    app.exec(CM_LSP)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
