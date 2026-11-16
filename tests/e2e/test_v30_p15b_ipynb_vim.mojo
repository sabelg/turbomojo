"""E2E Test Suite for v3.0 Phase 15B:
Jupyter .ipynb Open/Create/Save Hardening, Help > Jupyter & Notebooks Documentation,
and `tmide vim` / `CM_VIM_ZEN` Chromeless Whole-Vim Mode.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from std.time import perf_counter_ns
from app import App
from screen import CONT
from term import KEY_ENTER, KEY_ESC, MOD_SHIFT, MOD_ALT
from dialog import NEXT_NONE
from highlight import HL_JSON, HL_MOJO, HL_PYTHON
from vim import KEYMAP_VIM, VM_NORMAL
from commands import (
    CM_NEW_NOTEBOOK,
    CM_OPEN_NOTEBOOK,
    CM_HELP_NOTEBOOKS,
    CM_VIM_ZEN,
    CM_SAVE,
    CM_SPLIT_RIGHT,
)
from cells import parse_cells
from ipynb import ipynb_to_percent_text, percent_text_to_ipynb
from json import json_parse, J_OBJ, J_ARR
from signals import own_pid
from util import (
    env_or,
    run_system,
    write_file,
    read_file,
    bytes_to_str,
    str_bytes,
    decode,
    to_str,
    path_exists,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v30-p15b-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def _row_text(app: App, row: Int) -> String:
    var cps = List[Int]()
    for c in range(app.scr.w):
        var ch = app.scr.ch[row * app.scr.w + c]
        if ch != CONT:
            cps.append(ch)
    return to_str(cps)


def _screen_text(app: App) -> String:
    var out = String("")
    for r in range(app.scr.h):
        out += _row_text(app, r) + "\n"
    return out^


def _type_keys(mut app: App, s: String) raises:
    for cp in decode(s):
        app.handle_key(cp)


def test_ipynb_hardening_empty_bom_v3_and_save() raises:
    var d = _scratch("ipynb")
    try:
        # 1. UTF-8 BOM + nbformat v3 worksheet with heading & input
        var bom_v3 = List[UInt8]()
        bom_v3.append(0xEF)
        bom_v3.append(0xBB)
        bom_v3.append(0xBF)
        var v3_body = (
            '{"nbformat": 3, "nbformat_minor": 0, "metadata": {}, "worksheets": [{"cells": ['
            '{"cell_type": "heading", "level": 2, "source": ["Intro"]},'
            '{"cell_type": "code", "input": ["x = 42\\n", "print(x)"], "outputs": []}'
            ']}]}\n'
        )
        for b in str_bytes(v3_body):
            bom_v3.append(b)
        var conv_v3 = ipynb_to_percent_text(bytes_to_str(bom_v3))
        assert_true(conv_v3.ok)
        assert_false(conv_v3.is_mojo)
        assert_true(conv_v3.text.find("## Intro") >= 0)
        assert_true(conv_v3.text.find("x = 42") >= 0)
        var upgraded_v4 = json_parse(percent_text_to_ipynb(conv_v3.text, False, bytes_to_str(bom_v3)))
        assert_true(upgraded_v4.ok and upgraded_v4.int(upgraded_v4.get(0, "nbformat"), 0) == 4)

        # 2. 0-byte and `{}` empty .ipynb files open cleanly as interactive notebooks
        var p_zero = d + "/zero.ipynb"
        _ = write_file(p_zero, List[UInt8]())
        var p_braces = d + "/empty_obj.ipynb"
        _ = write_file(p_braces, str_bytes("{}\n"))
        var p_new = d + "/brand_new.ipynb"  # does not exist on disk yet

        var app = App()
        app.cwd = d
        app.scr.resize(100, 30)
        _ = write_file(d + "/pyproject.toml", str_bytes("[project]\nname = 'demo'\n"))

        app.open_path(p_zero)
        var z_idx = app.find_editor(p_zero)
        assert_true(z_idx >= 0)
        assert_equal(app.wins[z_idx].lang_override, HL_PYTHON)
        assert_true(app.wins[z_idx].inline_cell_outputs)
        assert_true(bytes_to_str(app.wins[z_idx].buf.to_bytes()).find("# %%") >= 0)

        app.open_path(p_braces)
        var b_idx = app.find_editor(p_braces)
        assert_true(b_idx >= 0)
        assert_equal(app.wins[b_idx].lang_override, HL_PYTHON)

        # 3. Non-existent `brand_new.ipynb` initializes `# %%` and saves valid nbformat v4 JSON
        app.open_path(p_new)
        var n_idx = app.find_editor(p_new)
        assert_true(n_idx >= 0)
        app.wins[n_idx].buf.load_bytes(str_bytes("# %% [Setup]\ny = 99\n"))
        app.wins[n_idx].buf.modified = True
        assert_true(app.save_window(n_idx, NEXT_NONE))
        var raw_saved = bytes_to_str(read_file(p_new))
        var jdoc = json_parse(raw_saved)
        assert_true(jdoc.ok and jdoc.kind(0) == J_OBJ)
        assert_equal(jdoc.int(jdoc.get(0, "nbformat"), 0), 4)
        assert_equal(jdoc.kind(jdoc.get(0, "cells")), J_ARR)

        # 4. Corrupt `.ipynb` opens as HL_JSON so saving doesn't silently destroy raw JSON
        var p_bad = d + "/broken.ipynb"
        _ = write_file(p_bad, str_bytes("{broken json"))
        app.open_path(p_bad)
        var bad_idx = app.find_editor(p_bad)
        assert_true(bad_idx >= 0)
        assert_equal(app.wins[bad_idx].lang_override, HL_JSON)

        # 5. File > New Jupyter notebook & File > Open notebook (.ipynb)...
        app.exec(CM_NEW_NOTEBOOK)
        var top = app.top_editor()
        assert_true(top >= 0)
        assert_equal(app.wins[top].title, "notebook.ipynb")
        assert_true(app.wins[top].inline_cell_outputs)

        app.exec(CM_OPEN_NOTEBOOK)
        assert_equal(app.dlg.title, "Open Jupyter Notebook (.ipynb)")
        assert_true(len(app.dlg.items) > 0)
        for it in app.dlg.items:
            assert_true(it == "../" or it.endswith("/") or it.endswith(".ipynb"))
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_help_notebooks_page_and_vim_help() raises:
    var d = _scratch("help")
    try:
        var app = App()
        app.cwd = d
        app.help_dir = d + "/help"
        app.scr.resize(100, 32)
        app.exec(CM_HELP_NOTEBOOKS)
        app.draw()
        var txt = _screen_text(app)
        assert_true(txt.find("Notebooks") >= 0 or txt.find("Jupyter") >= 0)
        assert_true(path_exists(d + "/help/notebooks.md"))
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_whole_vim_zen_chrome_welcome_splits_and_chords() raises:
    var d = _scratch("vimzen")
    try:
        var app = App()
        app.cwd = d
        app.help_dir = d + "/help"
        app.scr.resize(100, 30)
        _ = app.new_editor("[No Name]", "")
        app.enter_vim_zen(True)
        assert_true(app.vim_zen)
        assert_true(app.tiled)
        assert_equal(app.keymap, KEYMAP_VIM)
        assert_true(app.rel_numbers)

        app.draw()
        var te = app.top_editor()
        assert_true(te >= 0)
        assert_true(app.wins[te].chromeless)
        assert_equal(app.wins[te].y, 0)
        assert_equal(app.wins[te].pad(), 0)
        assert_equal(app.wins[te].h, 28)  # 30 - 2 (statusline at 28, cmdline at 29)

        # Welcome splash on empty `[No Name]`, tilde `~` rows, and NORMAL pill on row h-2
        var full_scr = _screen_text(app)
        assert_true(full_scr.find("Mojo 1.2 Vim Edition") >= 0)
        assert_true(full_scr.find("~") >= 0)
        var status_row = _row_text(app, 28)
        assert_true(status_row.find("NORMAL") >= 0)
        assert_true(status_row.find("[No Name]") >= 0)

        # Open a multi-cell file, test `]n` / `[n` cell jumps and `:w out.ipynb`
        var mojo_nb = d + "/cells.mojo"
        _ = write_file(mojo_nb, str_bytes("# %% [First]\nvar a = 1\n\n# %% [Second]\nvar b = 2\n"))
        app.open_path(mojo_nb)
        app.draw()
        var ci = app.find_editor(mojo_nb)
        assert_true(ci >= 0)
        app.wins[ci].cr = 0
        _type_keys(app, "]n")
        assert_equal(app.wins[ci].cr, 3)
        _type_keys(app, "[n")
        assert_equal(app.wins[ci].cr, 0)

        # `:w exported.ipynb` from Vim command line writes valid Jupyter JSON!
        var exp_ipynb = d + "/exported.ipynb"
        _type_keys(app, ":w " + exp_ipynb)
        app.handle_key(KEY_ENTER)
        assert_true(path_exists(exp_ipynb))
        var exp_doc = json_parse(bytes_to_str(read_file(exp_ipynb)))
        assert_true(exp_doc.ok and exp_doc.int(exp_doc.get(0, "nbformat"), 0) == 4)

        # Vertical split (`:vsp`) draws single-column `│` divider without Borland box frame
        _type_keys(app, ":vsp")
        app.handle_key(KEY_ENTER)
        app.draw()
        var has_sep = False
        for k in range(len(app.wins)):
            if app.wins[k].split_sep:
                has_sep = True
        assert_true(has_sep)

        # `-` opens Explorer at row 0 and `-` inside Explorer closes it cleanly
        _type_keys(app, "-")
        assert_true(app.explorer_index() >= 0)
        assert_equal(app.wins[app.explorer_index()].y, 0)
        _type_keys(app, "-")
        assert_equal(app.explorer_index(), -1)

        # `<Space>z` toggles Whole-Vim mode off -> standard `<Space>` becomes `l` motion
        _type_keys(app, " z")
        assert_false(app.vim_zen)
        var ed_now = app.top_editor()
        app.wins[ed_now].cr = 1
        app.wins[ed_now].cc = 0
        _type_keys(app, " ")
        assert_equal(app.wins[ed_now].cc, 1)

        # `:zen` re-enters Whole-Vim mode, and `:qall!` exits (`app.running == False`)
        _type_keys(app, ":zen")
        app.handle_key(KEY_ENTER)
        assert_true(app.vim_zen)
        _type_keys(app, ":qa!")
        app.handle_key(KEY_ENTER)
        assert_false(app.running)
    finally:
        _ = run_system("rm -rf '" + d + "'")


def _wait_cells_idle(mut app: App, timeout_s: Float64 = 15.0) raises:
    var t0 = Int(perf_counter_ns())
    var budget_ns = Int(timeout_s * 1_000_000_000.0)
    while (app.cell_k_active or app.job.active or len(app.cell_queue_indices) > 0) and (
        Int(perf_counter_ns()) - t0 < budget_ns
    ):
        app.cell_kernel_tick()
        if app.job.active:
            app.poll_job()
        _ = external_call["usleep", Int32](UInt32(10000))


def test_whole_vim_quit_last_buffer_exits_app() raises:
    var d = _scratch("vimquit")
    try:
        var p = d + "/hello.mojo"
        _ = write_file(p, str_bytes("def main():\n    print(1)\n"))
        var app = App()
        app.cwd = d
        app.scr.resize(80, 24)
        app.open_path(p)
        app.enter_vim_zen(True)
        assert_true(app.running)
        _type_keys(app, ":q")
        app.handle_key(KEY_ENTER)
        assert_false(app.running)
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_real_jupyter_live_execution_magics_and_cmd_mode() raises:
    var d = _scratch("realjup")
    var app = App()
    try:
        app.cwd = d
        app.scr.resize(110, 36)

        # 1. Python .ipynb: Markdown cell + IPython %magic / !shell interpolation + bare Out[2]
        var py_src = (
            "# %% [markdown]\n"
            "# # Real Jupyter Title\n\n"
            "# %% [Setup]\n"
            "%matplotlib inline\n"
            "x = 21\n"
            "!echo magic_x={x}\n\n"
            "# %% [Compute]\n"
            "x * 2\n"
        )
        var py_nb = d + "/analysis.ipynb"
        _ = write_file(py_nb, str_bytes(percent_text_to_ipynb(py_src, False)))
        app.open_path(py_nb)
        var ni = app.find_editor(py_nb)
        assert_true(ni >= 0)
        assert_true(app.wins[ni].is_notebook())
        assert_equal(len(parse_cells(app.wins[ni].buf)), 3)

        # Move to Cell 1 (`# %% [Setup]`) and press Shift-Enter -> executes & advances to Cell 2
        app.wins[ni].goto(4, 0)
        app.handle_key(KEY_ENTER | MOD_SHIFT)
        _wait_cells_idle(app, 15.0)
        ni = app.find_editor(py_nb)
        var c_after_1 = parse_cells(app.wins[ni].buf)
        assert_equal(len(c_after_1), 3)
        assert_true(app.wins[ni].cr >= c_after_1[2].header_row)

        # Press Shift-Enter on the LAST cell -> executes AND auto-appends a new `# %%` cell!
        app.handle_key(KEY_ENTER | MOD_SHIFT)
        _wait_cells_idle(app, 15.0)
        ni = app.find_editor(py_nb)
        var c_after_2 = parse_cells(app.wins[ni].buf)
        assert_equal(len(c_after_2), 4)
        assert_true(app.wins[ni].cr >= c_after_2[3].header_row)

        app.draw()
        var scr = _screen_text(app)
        assert_true(scr.find("magic_x=21") >= 0)
        assert_true(scr.find("42") >= 0)
        assert_true(scr.find("[1]") >= 0)
        assert_true(scr.find("[2]") >= 0)
        assert_true(scr.find("Run") >= 0)
        # Clean rendered Markdown cell (cursor is in Cell 3, so Cell 0 hides raw `# # ` and `# `)
        assert_true(scr.find("Real Jupyter Title") >= 0)
        assert_equal(scr.find("# Real Jupyter Title"), -1)

        # 2. Jupyter Command Mode (`Esc` -> `NB:CMD`, `b`, `m`, `y`, `dd`, `Enter` -> `NB:EDIT`)
        app.handle_key(KEY_ESC)
        assert_true(app.wins[ni].nb_cmd_mode)
        app.status_until = 0
        app.draw()
        assert_true(_screen_text(app).find("NB:CMD") >= 0)

        _type_keys(app, "b")
        assert_equal(len(parse_cells(app.wins[ni].buf)), 5)
        _type_keys(app, "m")
        var hdr_row = app.wins[ni].cell_header_for_row(app.wins[ni].cr)
        assert_true(app.wins[ni].is_markdown_header(hdr_row))
        _type_keys(app, "y")
        assert_false(app.wins[ni].is_markdown_header(app.wins[ni].cell_header_for_row(app.wins[ni].cr)))
        _type_keys(app, "dd")
        assert_equal(len(parse_cells(app.wins[ni].buf)), 4)
        app.handle_key(KEY_ENTER)
        assert_false(app.wins[ni].nb_cmd_mode)

        # 3. Round-trip save persists live outputs into nbformat v4 JSON
        assert_true(app.save_window(ni, NEXT_NONE))
        var saved_ipynb = bytes_to_str(read_file(py_nb))
        assert_true(saved_ipynb.find("magic_x=21") >= 0)
        assert_true(saved_ipynb.find("42") >= 0)

        # 4. Stateful Mojo .ipynb execution across cells via Shift-Enter
        var mojo_src = (
            "# %% [Cell 1]\n"
            "var base = 21\n\n"
            "# %% [Cell 2]\n"
            'print("mojo_ans =", base * 2)\n'
        )
        var mojo_nb = d + "/kernel_demo.ipynb"
        _ = write_file(mojo_nb, str_bytes(percent_text_to_ipynb(mojo_src, True)))
        app.open_path(mojo_nb)
        var mi = app.find_editor(mojo_nb)
        assert_true(mi >= 0)
        assert_equal(app.wins[mi].lang_override, HL_MOJO)
        app.wins[mi].goto(1, 0)
        app.handle_key(KEY_ENTER | MOD_SHIFT)
        _wait_cells_idle(app, 25.0)
        app.handle_key(KEY_ENTER | MOD_SHIFT)
        _wait_cells_idle(app, 25.0)
        mi = app.find_editor(mojo_nb)
        assert_true(mi >= 0)
        app.draw()
        assert_true(_screen_text(app).find("mojo_ans = 42") >= 0)
    finally:
        app.cell_restart_kernels()
        _ = run_system("rm -rf '" + d + "'")


def main() raises:
    var suite = TestSuite()
    suite.test[test_ipynb_hardening_empty_bom_v3_and_save]()
    suite.test[test_help_notebooks_page_and_vim_help]()
    suite.test[test_whole_vim_zen_chrome_welcome_splits_and_chords]()
    suite.test[test_whole_vim_quit_last_buffer_exits_app]()
    suite.test[test_real_jupyter_live_execution_magics_and_cmd_mode]()
    suite^.run()
