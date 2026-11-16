"""E2E Test Suite for v3.0 Phase 15 (v2.6):
Inline Virtual Notebook Outputs, Sequential Cell Queue, Bidirectional .ipynb Outputs,
and Live Tensor / SIMD / DataFrame Inspector.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from std.time import perf_counter_ns
from app import App
from screen import CONT
from commands import (
    CM_SAVE,
    CM_RUN_CELL,
    CM_RUN_ALL_CELLS,
    CM_RUN_CELLS_ABOVE,
    CM_CELL_INLINE_OUT,
    CM_CELL_CLEAR_OUT,
)
from ipynb import ipynb_to_percent_text, percent_text_to_ipynb
from json import json_parse, J_ARR
from tensor_inspect import summarize_mojo_value, extract_tensor_cards, parse_numeric_elements
from dbgview import VarNode, watch_text
from dap import DS_STOPPED, DS_OFF
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
    var d = env_or("TMPDIR", "/tmp") + "/tm-v30-p15-" + tag + "-" + String(own_pid())
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


def _wait_cells_idle(mut app: App, timeout_s: Float64 = 12.0) raises:
    var t0 = Int(perf_counter_ns())
    var budget_ns = Int(timeout_s * 1_000_000_000.0)
    while (app.cell_k_active or app.job.active or len(app.cell_queue_indices) > 0) and (
        Int(perf_counter_ns()) - t0 < budget_ns
    ):
        app.cell_kernel_tick()
        if app.job.active:
            app.poll_job()
        _ = external_call["usleep", Int32](UInt32(10000))


def test_v30_p15_01_virtual_cell_outputs_and_cursor_geometry() raises:
    """Virtual multi-line outputs render beneath `# %%` cells without mutating buffer text,
    clamp past 6 lines, keep cursor_cell() + screen_to_pos() exact, and toggle/clear cleanly."""
    var d = _scratch("virt")
    var nb_path = d + "/virt_demo.py"
    var src = (
        "# %% First Cell\n"
        "x = 10\n"
        "print(x)\n"
        "# %% Second Cell\n"
        "y = x + 5\n"
    )
    assert_true(write_file(nb_path, str_bytes(src)))

    var app = App()
    app.cwd = d
    app.scr.resize(100, 32)
    app.open_path(nb_path)
    var ed = app.active_editor()
    assert_true(ed >= 0)

    # Attach an 8-line output to First Cell (header row 0; cell ends at row 2)
    var big_out = "alpha=1\nbeta=2\ngamma=3\ndelta=4\nepsilon=5\nzeta=6\neta=7\ntheta=8"
    app.wins[ed].set_cell_output(0, big_out, False, "", 1)

    # Buffer bytes MUST remain 100% identical to source code!
    assert_equal(bytes_to_str(app.wins[ed].buf.to_bytes()), src)

    # Virtual lines at row 2 should clamp to 6 rows with "+3 more lines" indicator
    var vres = app.wins[ed].virtual_out_lines_at(2)
    assert_equal(len(vres[0]), 6)
    assert_equal(vres[0][0], "alpha=1")
    assert_true(vres[0][5].find("+3 more lines") >= 0, vres[0][5])

    # Put cursor on `# %% Second Cell` (row 3) and draw screen
    app.wins[ed].goto(3, 0)
    app.draw()
    var dump = _screen_text(app)
    assert_true(dump.find("│  alpha=1") >= 0, dump)
    assert_true(dump.find("+3 more lines") >= 0, dump)

    # Row 3 is shifted down by 6 virtual rows compared to having inline outputs off!
    var pos_with_virt = app.wins[ed].cursor_cell()
    # Hit-testing at pos_with_virt (Pos(y, x)) must map back to row 3!
    var hit = app.wins[ed].screen_to_pos(pos_with_virt.c, pos_with_virt.r)
    assert_equal(hit.r, 3)

    # Toggle inline cell outputs OFF -> row 3 moves up by 6 screen rows!
    app.exec(CM_CELL_INLINE_OUT)
    assert_false(app.wins[ed].inline_cell_outputs)
    var pos_no_virt = app.wins[ed].cursor_cell()
    assert_equal(pos_with_virt.r - pos_no_virt.r, 6)
    app.draw()
    assert_true(_screen_text(app).find("│  alpha=1") < 0)

    # Toggle back ON, then clear outputs via CM_CELL_CLEAR_OUT
    app.exec(CM_CELL_INLINE_OUT)
    assert_true(app.wins[ed].inline_cell_outputs)
    app.exec(CM_CELL_CLEAR_OUT)
    assert_equal(len(app.wins[ed].buf.cell_out_rows), 0)

    app.cell_kernels_stop()
    _ = run_system("rm -rf '" + d + "'")


def test_v30_p15_02_run_all_and_run_above_queue_and_error_halt() raises:
    """`CM_RUN_CELLS_ABOVE` runs strictly preceding cells; `CM_RUN_ALL_CELLS` runs top-to-bottom
    (including markdown cells) and halts immediately when a cell fails."""
    var d = _scratch("queue")
    var nb_path = d + "/pipeline.py"
    var src = (
        "# %% [markdown] Header\n"
        "# Pipeline Demo\n"
        "# %% Step 1\n"
        "val = 21\n"
        "print('S1=' + str(val))\n"
        "# %% Step 2\n"
        "val = val * 2\n"
        "print('S2=' + str(val))\n"
        "# %% Step 3\n"
        "val = val + 8\n"
        "print('S3=' + str(val))\n"
    )
    assert_true(write_file(nb_path, str_bytes(src)))

    var app = App()
    app.cwd = d
    app.scr.resize(100, 32)
    app.open_path(nb_path)
    var ed = app.active_editor()
    assert_true(ed >= 0)

    # Place cursor in Step 3 (row 9) and run `CM_RUN_CELLS_ABOVE` -> runs Markdown + Step 1 + Step 2 only
    app.wins[ed].goto(9, 0)
    app.exec(CM_RUN_CELLS_ABOVE)
    _wait_cells_idle(app)

    app.draw()
    var dump1 = _screen_text(app)
    assert_true(dump1.find("│  S1=21") >= 0, dump1)
    assert_true(dump1.find("│  S2=42") >= 0, dump1)
    assert_true(dump1.find("│  S3=50") < 0, dump1)

    # Now run `CM_RUN_ALL_CELLS` -> all 3 code cells run cleanly!
    app.exec(CM_RUN_ALL_CELLS)
    _wait_cells_idle(app)
    app.draw()
    var dump2 = _screen_text(app)
    assert_true(dump2.find("│  S3=50") >= 0, dump2)

    # Now test halting on error: cell 1 raises ZeroDivisionError -> cell 2 MUST NOT execute!
    var err_nb = d + "/halt.py"
    var err_src = (
        "# %% Cell A\n"
        "marker = 'before'\n"
        "# %% Cell Boom\n"
        "1 / 0\n"
        "# %% Cell After\n"
        "marker = 'after_boom'\n"
        "print(marker)\n"
    )
    assert_true(write_file(err_nb, str_bytes(err_src)))
    app.open_path(err_nb)
    var ed2 = app.active_editor()
    app.exec(CM_RUN_ALL_CELLS)
    _wait_cells_idle(app)

    assert_equal(len(app.cell_queue_indices), 0)
    app.draw()
    var dump_err = _screen_text(app)
    assert_true(dump_err.find("ZeroDivisionError") >= 0, dump_err)
    # Cell After (header row 4) must not have executed
    var ran_after = False
    for k in range(len(app.wins[ed2].buf.cell_out_rows)):
        if app.wins[ed2].buf.cell_out_rows[k] == 4:
            ran_after = True
    assert_false(ran_after, "Cell After should not run after Cell Boom fails!")

    app.cell_kernels_stop()
    _ = run_system("rm -rf '" + d + "'")


def test_v30_p15_03_tensor_dataframe_and_mojo_simd_inspector() raises:
    """Verify Python tensor/DataFrame summary cards (including NaN/Inf warnings and `_` expression)
    and Mojo SIMD/LayoutTensor cards in REPL & DAP debugger views."""
    var d = _scratch("tensor")
    var py_path = d + "/inspect_demo.py"
    # Works whether or not numpy/pandas are installed by testing real numpy if present + protocol duck-typing!
    var py_src = (
        "# %% Array & DataFrame Cards\n"
        "class FakeDType:\n"
        "    kind = 'f'\n"
        "    def __str__(self): return 'float32'\n"
        "class DuckTensor:\n"
        "    __module__ = 'torch'\n"
        "    shape = (2, 3)\n"
        "    dtype = 'torch.float32'\n"
        "    device = 'cuda:0'\n"
        "    def stride(self): return (3, 1)\n"
        "    def detach(self): return self\n"
        "    def numel(self): return 0\n"
        "    def is_floating_point(self): return True\n"
        "class DuckFrame:\n"
        "    __module__ = 'pandas.core.frame'\n"
        "    shape = (128, 3)\n"
        "    columns = ['step', 'loss', 'lr']\n"
        "    dtypes = {'step': 'int64', 'loss': 'float32', 'lr': 'float32'}\n"
        "t = DuckTensor()\n"
        "DataFrame = type('DataFrame', (DuckFrame,), {'__module__': 'pandas.core.frame'})\n"
        "df = DataFrame()\n"
        "try:\n"
        "    import numpy as np\n"
        "    arr = np.array([[1.0, 2.0], [float('nan'), 5.0]], dtype=np.float32)\n"
        "except Exception:\n"
        "    pass\n"
        "21 * 2\n"
    )
    assert_true(write_file(py_path, str_bytes(py_src)))

    var app = App()
    app.cwd = d
    app.scr.resize(110, 32)
    app.open_path(py_path)
    var ed = app.find_editor(py_path)
    app.wins[ed].goto(1, 0)
    app.exec(CM_RUN_CELL)
    _wait_cells_idle(app)
    ed = app.find_editor(py_path)
    assert_true(ed >= 0)

    assert_true(len(app.wins[ed].buf.cell_out_texts) > 0, app.status)
    var cell_txt = app.wins[ed].buf.cell_out_texts[0]
    assert_true(cell_txt.find("42") >= 0, "Expected trailing expression result 42 in: " + cell_txt)
    assert_true(cell_txt.find("t: [Tensor float32[2, 3] · cuda:0 · stride=[3, 1]]") >= 0, cell_txt)
    assert_true(cell_txt.find("df: [DataFrame 128×3 · cols: step(int64), loss(float32), lr(float32)") >= 0, cell_txt)

    # Pure-Mojo SIMD & Tensor inspector + LLDB dump extraction + NaN/Inf detection
    var st = parse_numeric_elements("{ [0] = 1.0, [1] = 3.0, [2] = nan, [3] = inf }")
    assert_equal(st.count, 4)
    assert_equal(st.finite_count, 2)
    assert_equal(st.nan_count, 1)
    assert_equal(st.inf_count, 1)
    assert_equal(st.min_val, 1.0)
    assert_equal(st.max_val, 3.0)
    assert_equal(st.mean_val, 2.0)

    var simd_card = summarize_mojo_value(
        "vec", "SIMD[DType.float32, 4]", "{ [0] = 1.0, [1] = 3.0, [2] = nan, [3] = 5.0 }"
    )
    assert_true(simd_card.find("vec: [SIMD float32[4] · min=1.0 max=5.0 mean=3.0 · ⚠ 1 NaN]") >= 0, simd_card)

    var repl_dump = "(SIMD[DType.float16, 4]) acc = {\n  [0] = 2.0\n  [1] = 4.0\n  [2] = 6.0\n  [3] = 8.0\n}"
    var ext = extract_tensor_cards(repl_dump)
    assert_equal(len(ext[1]), 1)
    assert_true(ext[0].find("acc: [SIMD float16[4] · min=2.0 max=8.0 mean=5.0 · 0 NaN]") >= 0, ext[0])

    # Verify VarNode.line(), watch_text(), and App.debug_sync_inline_locals() render SIMD summary cards!
    var vnode = VarNode(
        "weights",
        "SIMD[DType.float32, 4]",
        "{ [0] = 0.5, [1] = 1.5, [2] = nan, [3] = 2.5 }",
        1,
        "",
        "weights",
        0,
        "weights",
    )
    assert_true(vnode.line().find("weights = [SIMD float32[4]") >= 0, vnode.line())
    assert_true(vnode.line().find("⚠ 1 NaN") >= 0, vnode.line())
    var wtxt = watch_text("weights", True, vnode.value, vnode.type, "")
    assert_true(wtxt.find("weights = [SIMD float32[4]") >= 0, wtxt)

    # Test debug_sync_inline_locals on a Mojo editor buffer
    var mj_path = d + "/kern.mojo"
    var mj_src = "def compute():\n    var weights = SIMD[DType.float32, 4](0.5, 1.5, 0.0, 2.5)\n    print(weights)\n"
    assert_true(write_file(mj_path, str_bytes(mj_src)))
    app.open_path(mj_path)
    var med = app.active_editor()
    app.dbg.state = DS_STOPPED
    app.dbg.stop_file = mj_path
    app.dbg.stop_line = 3
    app.dview.nodes.clear()
    app.dview.nodes.append(vnode^)
    app.debug_sync_inline_locals()
    assert_equal(len(app.wins[med].dbg_inline_vals), 1)
    assert_true(app.wins[med].dbg_inline_vals[0].find("[SIMD float32[4]") >= 0, app.wins[med].dbg_inline_vals[0])
    app.dbg.state = DS_OFF

    app.cell_kernels_stop()
    _ = run_system("rm -rf '" + d + "'")


def test_v30_p15_04_ipynb_outputs_and_png_plot_bidirectional_persistence() raises:
    """Opening an `.ipynb` restores saved cell outputs, `execution_count`, and embedded base64 PNG plots;
    saving writes live outputs and plots back into standard nbformat v4 `outputs`."""
    var d = _scratch("ipynb_out")
    var nb_path = d + "/saved_outputs.ipynb"
    # Valid 1x1 red PNG in base64
    var png_1x1_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    var initial_json = (
        "{\n"
        "  \"cells\": [\n"
        "    {\n"
        "      \"cell_type\": \"code\",\n"
        "      \"execution_count\": 7,\n"
        "      \"metadata\": {\"title\": \"Plot Cell\"},\n"
        "      \"outputs\": [\n"
        "        {\"name\": \"stdout\", \"output_type\": \"stream\", \"text\": [\"loss=0.125\\n\"]},\n"
        "        {\"data\": {\"image/png\": \"" + png_1x1_b64 + "\", \"text/plain\": [\"<Figure>\"]}, \"metadata\": {}, \"output_type\": \"display_data\"}\n"
        "      ],\n"
        "      \"source\": [\"print('loss=0.125')\\n\"]\n"
        "    }\n"
        "  ],\n"
        "  \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3\", \"language\": \"python\", \"name\": \"python3\"}},\n"
        "  \"nbformat\": 4,\n"
        "  \"nbformat_minor\": 5\n"
        "}\n"
    )
    assert_true(write_file(nb_path, str_bytes(initial_json)))

    var app = App()
    app.cwd = d
    app.scr.resize(100, 30)
    app.open_path(nb_path)
    var ed = app.active_editor()
    assert_true(ed >= 0)

    # Saved output and PNG plot should be immediately hydrated on open!
    assert_equal(len(app.wins[ed].buf.cell_out_texts), 1)
    assert_true(app.wins[ed].buf.cell_out_texts[0].find("loss=0.125") >= 0)
    assert_equal(app.wins[ed].buf.cell_out_counts[0], 7)
    assert_true(app.wins[ed].buf.cell_out_plots[0].byte_length() > 0)
    assert_true(path_exists(app.wins[ed].buf.cell_out_plots[0]))
    assert_equal(len(app.cell_last_plots), 1)

    # Save `.ipynb` via CM_SAVE and verify `outputs` (stream + display_data image/png + execution_count) persist!
    app.wins[ed].buf.modified = True
    app.exec(CM_SAVE)
    var saved_raw = bytes_to_str(read_file(nb_path))
    var j = json_parse(saved_raw)
    assert_true(j.ok, j.error)
    var cells_arr = j.get(0, "cells")
    assert_equal(j.kind(cells_arr), J_ARR)
    var c0 = j.children(cells_arr)[0]
    assert_equal(j.int(j.get(c0, "execution_count"), 0), 7)
    var outs = j.get(c0, "outputs")
    assert_equal(j.kind(outs), J_ARR)
    assert_true(len(j.children(outs)) >= 2, saved_raw)
    assert_true(saved_raw.find("loss=0.125") >= 0, saved_raw)
    assert_true(saved_raw.find("image/png") >= 0, saved_raw)

    app.cell_kernels_stop()
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
