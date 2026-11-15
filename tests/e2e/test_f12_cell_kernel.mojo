"""E2E Test Suite for Feature #12: Stateful Persistent # %% Cells & Badges.
Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from buffer import TextBuffer
from cells import (
    CELL_SUCCESS, CELL_ERROR, CELL_INTERRUPTED,
    CELL_SK_STRUCT as SK_STRUCT, CELL_SK_CELL as SK_CELL,
    CodeCell, parse_cells, cell_at_row, is_cell_marker_str, cell_marker_title,
    CellResult, CellKernel, format_cell_divider_badge, scan_outline_with_cells, CellFoldState,
)
from util import decode


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
