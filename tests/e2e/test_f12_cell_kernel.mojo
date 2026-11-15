"""E2E Test Suite for Feature #12: Stateful Persistent # %% Cells & Badges.
Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
- 6 Upgrade E2E tests (Persistent Kernels, FD Stdout Suppression, LSP Virtualization,
  Error Line Remapping & Jump, Duplicate Title + Edit Row Shifting, Outline Merge & Cell Fold)
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from buffer import TextBuffer
from cells import (
    CELL_SUCCESS, CELL_ERROR, CELL_INTERRUPTED,
    CELL_SK_STRUCT as SK_STRUCT, CELL_SK_CELL as SK_CELL,
    CodeCell, parse_cells, cell_at_row, is_cell_marker_str, cell_marker_title,
    is_mojo_notebook, build_mojo_notebook_virtual_doc, build_cell_runner_mapped,
    parse_cell_kernel_output, remap_cell_runner_output,
    CellResult, CellKernel, format_cell_divider_badge, scan_outline_with_cells, CellFoldState,
)
from outline import OutlineItem, SK_FUNCTION, SK_CLASS, merge_outline_cells
from window import Window, WK_EDITOR, ACT_TYPE
from lsp import Diag, DocDiags, path_to_uri
from app import App
from commands import CM_NEW, CM_RUN_CELL, CM_CELL_RESTART
from signals import own_pid
from swap import delete_file
from util import decode, to_str, write_file, str_bytes, shell_quote, popen_read


# ===========================================================================
# Tier 1: Happy Path Tests (5 tests)
# ===========================================================================

def test_f12_tier1_01_cell_parser_with_metadata_and_titles() raises:
    """Verify parse_cells parses # %% cell markers, titles, line boundaries, and preamble."""
    var src = (
        "import math\n"           # 0
        "import sys\n"            # 1
        "import os\n"             # 2 (Preamble ends at 2)
        "# %% Step 1: Init\n"     # 3 (Header row 3)
        "x = 10\n"                # 4 (Start row 4)
        "y = 20\n"                # 5
        "items = [1, 2]\n"        # 6 (End row 6)
        "# %% Step 2: Compute\n"  # 7 (Header row 7)
        "z = x + y\n"             # 8 (Start row 8)
        "print(z)\n"              # 9
        "result = z"              # 10 (End row 10, no trailing newline)
    )
    var buf = TextBuffer()
    buf.load(decode(src))

    var cells = parse_cells(buf)
    assert_equal(len(cells), 3, "Expected 3 cells (Preamble + 2 cells)")

    # Cell 0: Preamble
    assert_equal(cells[0].title, "Preamble")
    assert_equal(cells[0].header_row, -1)
    assert_equal(cells[0].start_row, 0)
    assert_equal(cells[0].end_row, 2)

    # Cell 1: Step 1: Init
    assert_equal(cells[1].title, "Step 1: Init")
    assert_equal(cells[1].header_row, 3)
    assert_equal(cells[1].start_row, 4)
    assert_equal(cells[1].end_row, 6)

    # Cell 2: Step 2: Compute
    assert_equal(cells[2].title, "Step 2: Compute")
    assert_equal(cells[2].header_row, 7)
    assert_equal(cells[2].start_row, 8)
    assert_equal(cells[2].end_row, 10)

    # Check cell_at_row for row 5 (inside Step 1)
    assert_equal(cell_at_row(cells, 5), 1)
    assert_equal(cell_at_row(cells, 9), 2)


def test_f12_tier1_02_persistent_kernel_resident_namespace() raises:
    """Verify variables defined in earlier cells persist for subsequent cells."""
    var kernel = CellKernel()
    assert_true(kernel.is_alive())

    # Cell 1: define accum and items
    var r1 = kernel.execute("accum = 100\nitems = [1, 2, 3]\n")
    assert_equal(r1.status, CELL_SUCCESS)

    # Cell 2: access accum and items from resident namespace
    var r2 = kernel.execute("accum += sum(items)\nprint('ACCUM=' + str(accum))\n")
    assert_equal(r2.status, CELL_SUCCESS)
    assert_true(r2.output.find("ACCUM=106") >= 0, "Missing ACCUM=106 in: " + r2.output)


def test_f12_tier1_03_kernel_restart_resets_namespace() raises:
    """Verify Restart Kernel clears resident namespace and returns to ready state."""
    var kernel = CellKernel()
    var r1 = kernel.execute("x = 42\n")
    assert_equal(r1.status, CELL_SUCCESS)

    # Restart kernel
    kernel.restart()
    assert_true(kernel.is_alive())
    assert_equal(kernel.session_id, 2)

    # Accessing x should now raise NameError
    var r2 = kernel.execute("print(x)\n")
    assert_equal(r2.status, CELL_ERROR)
    assert_true(r2.error.find("name 'x' is not defined") >= 0 or r2.error.find("NameError") >= 0)


def test_f12_tier1_04_cell_divider_badge_formatting() raises:
    """Verify cell divider badge formats [✓ <ms>ms | <preview>] and [✗ ...]."""
    # Success badge
    var b_ok = format_cell_divider_badge(CELL_SUCCESS, 42, "42")
    assert_true(b_ok.find("✓") >= 0)
    assert_true(b_ok.find("42ms") >= 0)
    assert_true(b_ok.find("| 42]") >= 0)

    # Error badge
    var b_err = format_cell_divider_badge(CELL_ERROR, 15, "ZeroDivisionError")
    assert_true(b_err.find("✗") >= 0)
    assert_true(b_err.find("15ms") >= 0)
    assert_true(b_err.find("ZeroDivisionError") >= 0)


def test_f12_tier1_05_outline_symbols_include_cells() raises:
    """Verify # %% cells appear as outline symbols in outline tree."""
    var src = (
        "struct Model(Copyable, Movable):\n"
        "    var lr: Float64\n"
        "\n"
        "# %% Setup Hyperparameters\n"
        "var lr = 0.001\n"
        "\n"
        "# %% Train Loop\n"
        "print('training')\n"
    )
    var buf = TextBuffer()
    buf.load(decode(src))

    var items = scan_outline_with_cells(buf)
    assert_true(len(items) >= 3, "Expected at least struct + 2 cells in outline")

    var found_struct = False
    var found_cell1 = False
    var found_cell2 = False

    for it in items:
        if it.name == "Model" and it.kind == SK_STRUCT:
            found_struct = True
        elif it.name == "Setup Hyperparameters" and it.kind == SK_CELL:
            found_cell1 = True
            assert_equal(it.row, 3)
        elif it.name == "Train Loop" and it.kind == SK_CELL:
            found_cell2 = True
            assert_equal(it.row, 6)

    assert_true(found_struct, "Missing Model struct in outline")
    assert_true(found_cell1, "Missing Setup cell in outline")
    assert_true(found_cell2, "Missing Train cell in outline")


# ===========================================================================
# Tier 2: Boundary & Corner Cases Tests (5 tests)
# ===========================================================================

def test_f12_tier2_06_cell_block_folding_and_unfolding() raises:
    """Verify # %% cells can be folded, collapsing internal lines while header remains visible."""
    var src = (
        "# %% Cell One\n"  # 0
        "a = 1\n"          # 1
        "b = 2\n"          # 2
        "# %% Cell Two\n"  # 3
        "c = 3\n"          # 4
        "d = 4\n"          # 5
    )
    var buf = TextBuffer()
    buf.load(decode(src))
    var cells = parse_cells(buf)
    assert_equal(len(cells), 2)

    var folder = CellFoldState()
    assert_false(folder.is_folded(0))

    # Fold Cell 0 (rows 0 to 2)
    folder.set_fold(0, True)
    assert_true(folder.is_folded(0))

    # Header line (row 0) must remain visible
    assert_false(folder.is_row_hidden(cells, 0))
    # Internal lines (rows 1 and 2) must be hidden
    assert_true(folder.is_row_hidden(cells, 1))
    assert_true(folder.is_row_hidden(cells, 2))
    # Cell 1 lines must remain visible
    assert_false(folder.is_row_hidden(cells, 3))
    assert_false(folder.is_row_hidden(cells, 4))

    # Unfold Cell 0
    folder.set_fold(0, False)
    assert_false(folder.is_folded(0))
    assert_false(folder.is_row_hidden(cells, 1))
    assert_false(folder.is_row_hidden(cells, 2))


def test_f12_tier2_07_cell_runtime_exception_preserves_kernel_alive() raises:
    """Verify runtime exception in cell does not kill persistent kernel daemon."""
    var kernel = CellKernel()
    _ = kernel.execute("val = 50\n")

    # Cell with ZeroDivisionError
    var r_err = kernel.execute("x = 1 / 0\n")
    assert_equal(r_err.status, CELL_ERROR)
    assert_true(r_err.error.find("division by zero") >= 0 or r_err.error.find("ZeroDivision") >= 0)
    assert_true(kernel.is_alive(), "Kernel should remain alive after exception")

    # Next cell: access previous variable val
    var r_ok = kernel.execute("print('ALIVE=' + str(val))\n")
    assert_equal(r_ok.status, CELL_SUCCESS)
    assert_true(r_ok.output.find("ALIVE=50") >= 0)


def test_f12_tier2_08_cell_execution_cancellation_sigint() raises:
    """Verify interrupting cell execution cancels task and keeps kernel alive."""
    var kernel = CellKernel()
    var r = kernel.interrupt()
    assert_equal(r.status, CELL_INTERRUPTED)
    assert_true(r.error.find("KeyboardInterrupt") >= 0)
    assert_true(kernel.is_alive(), "Kernel must remain alive after interrupt")

    # Ready for immediate next cell
    var r2 = kernel.execute("print('READY')\n")
    assert_equal(r2.status, CELL_SUCCESS)
    assert_true(r2.output.find("READY") >= 0)


def test_f12_tier2_09_consecutive_markers_and_whitespace_cells() raises:
    """Verify consecutive markers, blank markers, and trailing cells parse robustly."""
    var buf = TextBuffer()
    buf.load(decode("# %%\n# %%\n# %% Last\n"))
    var cells = parse_cells(buf)

    assert_equal(len(cells), 3, "Expected exactly 3 cells")
    for c in cells:
        assert_true(c.end_row >= c.start_row, "Negative row span in cell")

    # Executing empty cell is a clean no-op
    var badge = format_cell_divider_badge(CELL_SUCCESS, 0, "")
    assert_true(badge.find("0ms | ]") >= 0)


def test_f12_tier2_10_large_cell_output_preview_truncation() raises:
    """Verify massive output preview is clamped without overflowing screen boundary."""
    var big_out = String("")
    for i in range(100):
        big_out += "Long output line " + String(i) + " with lots of text...\n"

    var badge = format_cell_divider_badge(CELL_SUCCESS, 12, big_out)
    assert_true(badge.byte_length() < 70, "Badge preview not clamped: " + badge)
    assert_true(badge.find("…") >= 0, "Missing ellipsis in clamped badge: " + badge)
    assert_true(badge.find("\n") < 0, "Badge should not contain linebreaks")


# ===========================================================================
# Upgrade Verification Suite: All 6 Notebook Mode Upgrades End-to-End
# ===========================================================================

def _wait_cell_kernel(mut app: App, max_iters: Int = 1500):
    for _ in range(max_iters):
        app.cell_kernel_tick()
        if not app.cell_k_active:
            return
        _ = external_call["usleep", Int32](UInt32(10000))


def _capture_shell(cmd: String) -> String:
    var fp = popen_read(cmd)
    if fp == 0:
        return ""
    var out = List[UInt8]()
    var chunk = List[UInt8](length=4096, fill=0)
    while True:
        var n = external_call["read", Int](external_call["fileno", Int32](fp), chunk.unsafe_ptr(), Int(4096))
        if n <= 0:
            break
        for k in range(n):
            out.append(chunk[k])
    _ = external_call["pclose", Int32](fp)
    var cps = List[Int]()
    for b in out:
        cps.append(Int(b))
    return to_str(cps)


def test_f12_upgrade1_app_persistent_python_and_mojo_kernels() raises:
    """Verify App runs live persistent Python and Mojo cell kernels without re-running
    prior cells, preserves state across cells, and resets state on CM_CELL_RESTART."""
    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    var ei = app.top_editor()
    assert_true(ei >= 0)

    # 1. Persistent Python notebook in App (with unexecuted Preamble)
    app.wins[ei].title = "nb_live.py"
    var py_src = (
        "import math\n"               # 0 (Preamble)
        "runs = 0\n"                  # 1
        "# %% Step 1\n"               # 2
        "runs += 1\n"                 # 3
        "base = 16\n"                 # 4
        "print('PY1', runs)\n"        # 5
        "# %% Step 2\n"               # 6
        "print('PY2', runs, int(math.sqrt(base)))\n"  # 7
    )
    app.wins[ei].buf.load(decode(py_src))
    app.wins[ei].cr = 3
    app.exec(CM_RUN_CELL)
    assert_true(app.cell_k_active, "Expected persistent Python cell kernel to activate")
    _wait_cell_kernel(app)
    assert_false(app.cell_k_active, "Python cell 1 timed out")
    var mi = app.msg_index()
    assert_true(mi >= 0)
    var msg1 = to_str(app.wins[mi].buf.all_text())
    assert_true(msg1.find("PY1 1") >= 0, "Expected PY1 1 in Message: " + msg1)

    # Run Step 2: Step 1 MUST NOT re-execute (`runs` stays 1, no PY1 in output)
    ei = app.top_editor()
    app.wins[ei].cr = 7
    app.exec(CM_RUN_CELL)
    _wait_cell_kernel(app)
    assert_false(app.cell_k_active, "Python cell 2 timed out")
    mi = app.msg_index()
    ei = app.top_editor()
    var msg2 = to_str(app.wins[mi].buf.all_text())
    assert_true(msg2.find("PY2 1 4") >= 0, "Expected PY2 1 4 in Message: " + msg2)
    assert_true(msg2.find("PY1") < 0, "Prior cell output leaked into cell 2: " + msg2)
    assert_true(len(app.wins[ei].cell_badges) >= 2, "Expected badges on both Python cells")

    # Restart cell kernel: clears badges and wipes `base` from Python namespace
    app.exec(CM_CELL_RESTART)
    ei = app.top_editor()
    assert_equal(len(app.wins[ei].cell_badges), 0, "CM_CELL_RESTART must clear cell badges")
    app.wins[ei].cr = 7
    app.exec(CM_RUN_CELL)
    _wait_cell_kernel(app)
    assert_false(app.cell_k_active)
    mi = app.msg_index()
    var msg3 = to_str(app.wins[mi].buf.all_text())
    assert_true(msg3.find("NameError") >= 0, "Expected NameError after restart: " + msg3)
    assert_true(len(app.errs) >= 1, "Expected Python traceback location in app.errs")
    assert_equal(app.errs[0].row, 8, "Expected 1-based line 8 for failing Step 2 print")
    ei = app.top_editor()
    app.wins[ei].cr = 0
    app.goto_error(1)
    ei = app.top_editor()
    assert_equal(app.wins[ei].cr, 7, "jump_to_error should move cursor to 0-based row 7")

    # 2. Persistent Mojo notebook (`mojo repl` kernel) in App
    app.wins[ei].title = "nb_live.mojo"
    app.wins[ei].clear_cell_badges()
    var mj_src = (
        "# %% Init\n"
        "var score = 40\n"
        "print('MJ_INIT', score)\n"
        "# %% Next\n"
        "score += 2\n"
        "print('MJ_NEXT', score)\n"
    )
    app.wins[ei].buf.load(decode(mj_src))
    app.wins[ei].cr = 1
    app.exec(CM_RUN_CELL)
    _wait_cell_kernel(app, 2500)
    assert_false(app.cell_k_active, "Mojo cell 1 timed out")
    mi = app.msg_index()
    var mj_msg1 = to_str(app.wins[mi].buf.all_text())
    assert_true(mj_msg1.find("MJ_INIT 40") >= 0, "Expected MJ_INIT 40 in: " + mj_msg1)

    ei = app.top_editor()
    app.wins[ei].cr = 4
    app.exec(CM_RUN_CELL)
    _wait_cell_kernel(app, 2500)
    assert_false(app.cell_k_active, "Mojo cell 2 timed out")
    mi = app.msg_index()
    var mj_msg2 = to_str(app.wins[mi].buf.all_text())
    assert_true(mj_msg2.find("MJ_NEXT 42") >= 0, "Expected MJ_NEXT 42 in: " + mj_msg2)
    assert_true(mj_msg2.find("MJ_INIT") < 0, "Mojo cell 1 output leaked into cell 2: " + mj_msg2)

    app.cell_kernels_stop()


def test_f12_upgrade2_mojo_runner_suppresses_prior_cell_stdout() raises:
    """Verify standalone Mojo cell runner suppresses print() inside loops and helpers in prior cells."""
    var src = (
        "def noisy_helper() -> Int:\n"
        "    print('LEAK_FROM_HELPER')\n"
        "    return 21\n"
        "\n"
        "# %% Cell 1\n"
        "var acc = noisy_helper()\n"
        "for k in range(3):\n"
        "    print('LEAK_FROM_LOOP', k)\n"
        "    acc += k\n"
        "\n"
        "# %% Cell 2\n"
        "print('CLEAN_TARGET', acc)\n"
    )
    var buf = TextBuffer()
    buf.load(decode(src))
    var cells = parse_cells(buf)
    var target_idx = len(cells) - 1
    var mapped = build_cell_runner_mapped(buf, cells, target_idx, False)
    var tmp = "/tmp/tm-u2-" + String(own_pid()) + ".mojo"
    assert_true(write_file(tmp, str_bytes(mapped.source)))
    var out = _capture_shell("mojo run " + shell_quote(tmp) + " 2>&1")
    delete_file(tmp)
    assert_true(out.find("CLEAN_TARGET 24") >= 0, "Expected CLEAN_TARGET 24 in: " + out)
    assert_true(out.find("LEAK_") < 0, "Prior Mojo cell leaked stdout: " + out)


def test_f12_upgrade3_mojo_notebook_virtual_doc_and_lsp_mapping() raises:
    """Verify NotebookVirtualDoc synthesizes valid Mojo 1.2 code for # %% top-level statements
    and round-trips bidirectional (row, col) coordinates accurately."""
    var std_buf = TextBuffer()
    std_buf.load(decode("# %% Section\ndef main():\n    var x = 1\n    print(x)\n"))
    assert_false(is_mojo_notebook(std_buf), "File with only def main() should not virtualize")

    var nb_src = (
        "# %% Types\n"                             # 0
        "from std.math import sqrt\n"              # 1
        "\n"                                       # 2
        "@fieldwise_init\n"                        # 3
        "struct Pt(Copyable, Movable):\n"          # 4
        "    var x: Float64\n"                     # 5
        "    var y: Float64\n"                     # 6
        "\n"                                       # 7
        "# %% Compute\n"                           # 8
        "var p = Pt(3.0, 4.0)\n"                   # 9
        "var d = sqrt(p.x * p.x + p.y * p.y)\n"    # 10
        "print('DIST', d)\n"                       # 11
    )
    var nb_buf = TextBuffer()
    nb_buf.load(decode(nb_src))
    assert_true(is_mojo_notebook(nb_buf))

    var vdoc = build_mojo_notebook_virtual_doc(nb_buf)
    assert_true(vdoc.active)
    assert_true(vdoc.text.find("def __tm_notebook__() raises:") >= 0)

    var win = Window(WK_EDITOR, "nb.mojo", "/tmp/nb.mojo", 0, 0, 80, 24, 1)
    win.buf.load(decode(nb_src))
    win.lsp_nb_active = vdoc.active
    win.lsp_nb_v2b_row = vdoc.v2b_row.copy()
    win.lsp_nb_v2b_col = vdoc.v2b_col.copy()
    win.lsp_nb_b2v_row = vdoc.b2v_row.copy()
    win.lsp_nb_b2v_col = vdoc.b2v_col.copy()

    # Row 4 (`struct Pt` at col 7) is hoisted unindented -> round-trips to (4, 7)
    var vp_decl = win.lsp_to_virtual_pos(4, 7)
    var bp_decl = win.lsp_from_virtual_pos(vp_decl[0], vp_decl[1])
    assert_equal(bp_decl[0], 4)
    assert_equal(bp_decl[1], 7)

    # Row 10 (`var d = sqrt(...)` at col 8) is indented +4 in __tm_notebook__ -> round-trips to (10, 8)
    var vp_stmt = win.lsp_to_virtual_pos(10, 8)
    assert_equal(vp_stmt[1], 12)
    var bp_stmt = win.lsp_from_virtual_pos(vp_stmt[0], vp_stmt[1])
    assert_equal(bp_stmt[0], 10)
    assert_equal(bp_stmt[1], 8)

    # Verify App.lsp_sync_notebook_map + lsp_set_marks + problems_collect map virtual diags back
    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    var ei = app.top_editor()
    app.wins[ei].path = "/tmp/nb_virtual_check.mojo"
    app.wins[ei].buf.load(decode(nb_src))
    var sync_res = app.lsp_sync_notebook_map(ei)
    assert_true(sync_res[0])
    var dd = DocDiags(path_to_uri(app.wins[ei].path))
    # Synthetic wrapper row (`def __tm_notebook__() raises:`) maps to -1 -> ignored
    var wrapper_vrow = -1
    for vr in range(len(vdoc.v2b_row)):
        if vdoc.v2b_row[vr] < 0 and vr > 0:
            wrapper_vrow = vr
            break
    if wrapper_vrow >= 0:
        dd.items.append(Diag(wrapper_vrow, 0, wrapper_vrow, 10, 2, "synthetic wrapper note"))
    # Virtualized row for buffer row 10 (`    var d = sqrt(...)`, col 12 -> buffer col 8)
    dd.items.append(Diag(vp_stmt[0], 12, vp_stmt[0], 16, 1, "type mismatch on sqrt"))
    app.lsp.diags.append(dd^)
    app.lsp_set_marks(ei)
    assert_equal(len(app.wins[ei].buf.marks), 1, "Wrapper diag must be filtered; stmt diag kept")
    assert_equal(app.wins[ei].buf.marks[0].l1, 10)
    assert_equal(app.wins[ei].buf.marks[0].c1, 8)
    var probs = app.problems_collect()
    assert_equal(len(probs), 1)
    assert_equal(probs[0].line, 11)
    assert_equal(probs[0].col, 9)

    # Compile and execute the synthesized virtual module to prove zero Mojo 1.2 errors/warnings
    var runnable = vdoc.text + "\ndef main() raises:\n    __tm_notebook__()\n"
    var tmp = "/tmp/tm-u3-" + String(own_pid()) + ".mojo"
    assert_true(write_file(tmp, str_bytes(runnable)))
    var out = _capture_shell("mojo run " + shell_quote(tmp) + " 2>&1")
    delete_file(tmp)
    assert_true(out.find("DIST 5.0") >= 0, "Virtualized notebook failed to compile/run: " + out)


def test_f12_upgrade4_error_line_remapping_and_unsaved_jump() raises:
    """Verify mojo repl Expression [k]:L:C and temp-runner diagnostics map back to exact
    buffer rows and jump cleanly even in unsaved NONAME00.mojo buffers."""
    var raw_repl = (
        "[User] error: Expression [3]:2:9: use of unknown declaration 'missing_sym'\n"
        "__TM_CELL_END_7__\n"
    )
    # Cell body starts at 0-based row 6 (line 7), so line 2 of expression is 1-based line 8!
    var parsed = parse_cell_kernel_output(raw_repl, 7, False, "NONAME00.mojo", 6)
    assert_true(parsed[0])
    assert_equal(parsed[1], CELL_ERROR)
    assert_true(
        parsed[2].find("NONAME00.mojo:8:9: error: use of unknown declaration 'missing_sym'") >= 0,
        "Unexpected rewritten diagnostic: " + parsed[2],
    )

    var lmap = List[Int]()
    lmap.append(-1)
    lmap.append(12)  # generated line 2 -> 0-based buffer row 12 (1-based line 13)
    var remapped = remap_cell_runner_output(
        "/tmp/turbomojo-cell-1.mojo:2:5: error: bad type\n",
        "/tmp/turbomojo-cell-1.mojo",
        "NONAME00.mojo",
        lmap,
    )
    assert_equal(remapped, "NONAME00.mojo:13:5: error: bad type\n")

    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    var ei = app.top_editor()
    var lines = String("")
    for k in range(15):
        lines += "var line_" + String(k) + " = " + String(k) + "\n"
    app.wins[ei].buf.load(decode(lines))
    app.panel_write(0)
    _ = app.fill_messages("Cell [Test] in NONAME00.mojo", str_bytes(parsed[2]), "Failed")
    assert_equal(len(app.errs), 1)
    assert_equal(app.errs[0].row, 8)
    assert_equal(app.errs[0].col, 9)
    app.goto_error(1)
    ei = app.top_editor()
    assert_equal(app.wins[ei].cr, 7)
    assert_equal(app.wins[ei].cc, 8)


def test_f12_upgrade5_duplicate_titles_and_live_badge_row_shift() raises:
    """Verify duplicate # %% titles attach badges by cell index/row and shift live across edits/undo/redo."""
    var src = (
        "# %% Plot\n"      # 0
        "var a = 1\n"      # 1
        "\n"               # 2
        "# %% Plot\n"      # 3
        "var b = 2\n"      # 4
    )
    var win = Window(WK_EDITOR, "dup.mojo", "", 0, 0, 80, 24, 1)
    win.buf.load(decode(src))
    win.set_cell_badge(3, "[✓ 4ms | second]")
    assert_equal(len(win.cell_badge_rows), 1)
    assert_equal(win.cell_badge_rows[0], 3)

    # Insert 2 new lines at row 1 (above the second `# %% Plot`)
    win.cr = 1
    win.cc = 0
    win.insert_text(decode("var x = 10\nvar y = 20\n"), ACT_TYPE)
    win.sync_cell_badges()
    assert_equal(win.cell_badge_rows[0], 5, "Badge row must shift +2 after inserting 2 lines above")
    assert_equal(win.cell_badges[0], "[✓ 4ms | second]")

    # Undo restores row 3; Redo restores row 5
    win.undo()
    win.sync_cell_badges()
    assert_equal(win.cell_badge_rows[0], 3, "Undo must shift badge back to row 3")
    win.redo()
    win.sync_cell_badges()
    assert_equal(win.cell_badge_rows[0], 5, "Redo must shift badge forward to row 5")


def test_f12_upgrade6_outline_cell_merge_symbol_dialog_and_inner_fold() raises:
    """Verify LSP outline preserves # %% cells, Go to Symbol lists cells & Python classes,
    and Alt-- (toggle_fold) from inside a cell folds the enclosing # %% header."""
    var src = (
        "# %% Imports & Config\n"          # 0
        "class Trainer:\n"                 # 1
        "    async def step(self):\n"      # 2
        "        return 1\n"               # 3
        "\n"                               # 4
        "# %% Evaluate\n"                  # 5
        "trainer = Trainer()\n"            # 6
        "print(trainer)\n"                 # 7
    )
    var buf = TextBuffer()
    buf.load(decode(src))

    # Simulate LSP returning only class + method (without # %% comments)
    var srv = List[OutlineItem]()
    srv.append(OutlineItem("Trainer", SK_CLASS, 1, 0, 0))
    srv.append(OutlineItem("step", SK_FUNCTION, 2, 4, 1))
    var merged = merge_outline_cells(srv, buf)
    assert_equal(len(merged), 4, "Expected 2 # %% cells + 2 LSP symbols")
    assert_equal(merged[0].kind, SK_CELL)
    assert_equal(merged[0].name, "Imports & Config")
    assert_equal(merged[1].name, "Trainer")
    assert_equal(merged[2].name, "step")
    assert_equal(merged[3].kind, SK_CELL)
    assert_equal(merged[3].name, "Evaluate")

    # Go to Symbol dialog (`symbol_dialog`) includes `⊞` cells and `class` / `async def`
    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    var ei = app.top_editor()
    app.wins[ei].title = "train.py"
    app.wins[ei].buf.load(decode(src))
    app.symbol_dialog()
    var joined_items = "\n".join(app.dlg.items)
    assert_true(joined_items.find("⊞ Imports & Config") >= 0, "Missing cell 1 in Go to Symbol: " + joined_items)
    assert_true(joined_items.find("⊞ Evaluate") >= 0, "Missing cell 2 in Go to Symbol: " + joined_items)
    assert_true(joined_items.find("Trainer") >= 0, "Missing Python class in Go to Symbol: " + joined_items)
    assert_true(joined_items.find("step") >= 0, "Missing async def in Go to Symbol: " + joined_items)

    # Folding from an indent-0 line INSIDE `# %% Evaluate` (row 6) folds header row 5!
    app.wins[ei].cr = 6
    app.wins[ei].cc = 2
    assert_true(app.wins[ei].toggle_fold(6), "toggle_fold on cell body line 6 should fold enclosing # %% cell")
    assert_true(app.wins[ei].buf.fold_index(5) >= 0, "Expected fold anchored on # %% Evaluate header row 5")
    assert_equal(app.wins[ei].cr, 5, "Cursor should move to # %% header row 5 when body hides")
    assert_true(app.wins[ei].buf.hidden_by(6) == 5)
    assert_true(app.wins[ei].toggle_fold(5), "toggle_fold on folded header row 5 should unfold")
    assert_true(app.wins[ei].buf.hidden_by(6) < 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
