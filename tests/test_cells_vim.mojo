"""Tests for `# %%` interactive code cells and Vim command-line history, Tab completion, and global marks."""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from cells import parse_cells, cell_at_row, build_cell_runner_source
from buffer import TextBuffer
from app import *
from appstate import App
from window import WK_MESSAGE
from vim import KEYMAP_VIM
from commands import CM_RUN_CELL_NEXT
from term import wait_readable, KEY_ESC, KEY_ENTER, KEY_UP, KEY_DOWN, KEY_TAB
from signals import own_pid
from util import decode, to_str, env_or, run_system, write_file, str_bytes, shell_quote


def test_cell_parser_and_runner_synthesis_mojo_and_python() raises:
    var src = (
        "# %% Imports & Struct\n"
        "from std.math import sqrt\n"
        "\n"
        "@fieldwise_init\n"
        "struct Pair(Copyable, Movable):\n"
        "    var a: Int\n"
        "    var b: Int\n"
        "\n"
        "var base = 40\n"
        "print(\"earlier cell output\")\n"
        "# %% Compute\n"
        "var p = Pair(base, 2)\n"
        "print(p.a + p.b)\n"
    )
    var b = TextBuffer()
    b.load(decode(src))
    var cells = parse_cells(b)
    assert_equal(len(cells), 2)
    assert_equal(cells[0].title, "Imports & Struct")
    assert_equal(cells[1].title, "Compute")
    assert_equal(cell_at_row(cells, 0), 0)
    assert_equal(cell_at_row(cells, 11), 1)

    var mojo_runner = build_cell_runner_source(b, cells, 1, False)
    assert_true(mojo_runner.find("struct Pair") >= 0)
    assert_true(mojo_runner.find("var base = 40") >= 0)
    assert_true(mojo_runner.find("def main() raises:") >= 0)
    assert_true(mojo_runner.find("print(p.a + p.b)") >= 0)

    var py_b = TextBuffer()
    py_b.load(decode("# %% Setup\nx = 21\nprint('hidden')\n# %% Run\nprint(x * 2)\n"))
    var py_cells = parse_cells(py_b)
    var py_runner = build_cell_runner_source(py_b, py_cells, 1, True)
    assert_true(py_runner.find("devnull") >= 0)
    assert_true(py_runner.find("print(x * 2)") >= 0)


def _pump_job(mut app: App) raises:
    var deadline = Int(perf_counter_ns()) + 5_000_000_000
    while Int(perf_counter_ns()) < deadline and app.job.active:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 20)
        app.poll_job()


def test_live_python_cell_run_and_advance() raises:
    var d = env_or("TMPDIR", "/tmp") + "/tm-cells-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var py = d + "/nb.py"
    _ = write_file(py, str_bytes("# %% First\nseed_val = 21\nprint('quiet')\n# %% Second\nprint('CELL_RESULT=' + str(seed_val * 2))\n"))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.project_dir = d
    app.open_path(py)
    var ei = app.find_editor(py)
    app.wins[ei].goto(1, 0)  # inside Cell 1

    # Run Cell 1 & Advance -> cursor jumps to Cell 2
    app.exec(CM_RUN_CELL_NEXT)
    _pump_job(app)
    ei = app.find_editor(py)
    assert_equal(app.wins[ei].cr, 4)

    # Now Run Cell 2 -> uses `seed_val` from Cell 1 without re-printing Cell 1's 'quiet'!
    app.focus(ei)
    app.exec(CM_RUN_CELL_NEXT)
    _pump_job(app)
    var mi = -1
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_MESSAGE:
            mi = i
            break
    assert_true(mi >= 0)
    var out = to_str(app.wins[mi].buf.all_text())
    assert_true(out.find("CELL_RESULT=42") >= 0, out)
    assert_true(out.find("quiet") < 0, "earlier cell stdout suppressed cleanly")

    _ = run_system("rm -rf " + shell_quote(d))


def _vkeys(mut app: App, s: String) raises:
    for c in decode(s):
        if c == 126:
            app.handle_key(KEY_ESC)
        elif c == 124:
            app.handle_key(KEY_ENTER)
        else:
            app.handle_key(c)


def test_vim_history_tab_completion_global_marks_and_jumpback() raises:
    var d = env_or("TMPDIR", "/tmp") + "/tm-vim-fin-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var a = d + "/alpha.mojo"
    var b = d + "/beta_target.mojo"
    _ = write_file(a, str_bytes("line 0\nline 1\nline 2\nline 3\n"))
    _ = write_file(b, str_bytes("b0\nb1\nb2\n"))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.project_dir = d
    app.open_path(a)
    app.keymap = KEYMAP_VIM
    app.vim_reset()
    app.rebuild_keys(False)

    var ea = app.find_editor(a)
    var last_row = app.wins[ea].buf.count() - 1
    # 1. Jump to bottom (`G`) then `''` toggles right back to line 0, and `''` again back to bottom!
    _vkeys(app, "G")
    assert_equal(app.wins[ea].cr, last_row)
    _vkeys(app, "''")
    assert_equal(app.wins[ea].cr, 0)
    _vkeys(app, "''")
    assert_equal(app.wins[ea].cr, last_row)

    # 2. Set uppercase global mark `mA` at alpha.mojo line 2, col 0
    _vkeys(app, "3GmA")
    assert_equal(app.wins[ea].cr, 2)

    # 3. `:e beta` + Tab completes filename to `beta_target.mojo` and opens it!
    _vkeys(app, ":e beta")
    app.handle_key(KEY_TAB)
    assert_true(to_str(app.vim.cl_text).find("beta_target.mojo") > 0, to_str(app.vim.cl_text))
    app.handle_key(KEY_ENTER)
    var eb = app.find_editor(b)
    assert_equal(app.top(), eb)

    # 4. `'A` in beta_target.mojo jumps across files back to alpha.mojo line 2!
    _vkeys(app, "'A")
    ea = app.find_editor(a)
    assert_equal(app.top(), ea)
    assert_equal(app.wins[ea].cr, 2)

    # 5. `:` command-line Up/Down recalls history with prefix filtering
    _vkeys(app, ":noh|")
    _vkeys(app, ":")
    app.handle_key(KEY_UP)
    assert_equal(to_str(app.vim.cl_text), "noh")
    app.handle_key(KEY_UP)
    assert_true(to_str(app.vim.cl_text).startswith("e "))
    app.handle_key(KEY_DOWN)
    assert_equal(to_str(app.vim.cl_text), "noh")
    app.handle_key(KEY_ESC)

    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
