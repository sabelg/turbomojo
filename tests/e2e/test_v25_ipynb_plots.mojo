"""E2E Test Suite for v2.5.0 Milestone 2:
Jupyter `.ipynb` Bidirectional Open/Save & Inline Terminal Plots (Kitty / Sixel).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from std.time import perf_counter_ns
from ipynb import is_ipynb_path, ipynb_to_percent_text, percent_text_to_ipynb
from json import json_parse, J_ARR, J_OBJ
from highlight import HL_MOJO, HL_PYTHON
from window import ACT_TYPE, WK_IMGVIEW
from app import App
from appstate import M_NORMAL
from commands import CM_SAVE, CM_RUN_CELL, CM_EXPORT_IPYNB, CM_CELL_VIEW_PLOT
from signals import own_pid
from swap import delete_file
from png import png_decode
from sixel import sixel_encode
from util import (
    env_or, run_system, write_file, read_file, bytes_to_str, str_bytes, decode, to_str, path_exists,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v25-m2-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def test_v25_m2_01_ipynb_codec_roundtrip_and_kernel_detection() raises:
    """Lossless `.ipynb` <-> `# %%` / `# %% [markdown]` conversion with Mojo & Python metadata."""
    assert_true(is_ipynb_path("/work/demo.ipynb"))
    assert_true(is_ipynb_path("Demo.IPYNB"))
    assert_false(is_ipynb_path("demo.mojo"))

    var raw_mojo_nb = (
        "{\n"
        "  \"cells\": [\n"
        "    {\"cell_type\": \"markdown\", \"metadata\": {\"title\": \"Intro\"}, \"source\": [\"# GPU Demo\\n\", \"\\n\", \"Fast matmul.\"]},\n"
        "    {\"cell_type\": \"code\", \"execution_count\": 1, \"metadata\": {\"name\": \"Setup\"}, \"outputs\": [], \"source\": [\"comptime TILE = 16\\n\", \"print(TILE)\"]}\n"
        "  ],\n"
        "  \"metadata\": {\n"
        "    \"custom_author\": \"turbomojo\",\n"
        "    \"kernelspec\": {\"display_name\": \"Mojo\", \"language\": \"mojo\", \"name\": \"mojo\"}\n"
        "  },\n"
        "  \"nbformat\": 4,\n"
        "  \"nbformat_minor\": 5\n"
        "}\n"
    )
    var doc = ipynb_to_percent_text(raw_mojo_nb)
    assert_true(doc.ok, doc.error)
    assert_true(doc.is_mojo)
    assert_equal(doc.lang_id(), HL_MOJO)
    assert_true(doc.text.find("# %% [markdown] Intro\n# # GPU Demo\n#\n# Fast matmul.\n") >= 0, doc.text)
    assert_true(doc.text.find("# %% Setup\ncomptime TILE = 16\nprint(TILE)\n") >= 0, doc.text)

    var serialized = percent_text_to_ipynb(doc.text, doc.is_mojo, raw_mojo_nb)
    var j = json_parse(serialized)
    assert_true(j.ok, j.error)
    assert_equal(j.kind(0), J_OBJ)
    assert_equal(j.str(j.path(0, "metadata/custom_author"), ""), "turbomojo")
    assert_equal(j.str(j.path(0, "metadata/kernelspec/language"), ""), "mojo")
    var cells_n = j.get(0, "cells")
    assert_equal(j.kind(cells_n), J_ARR)
    assert_equal(j.size(cells_n), 2)

    var doc2 = ipynb_to_percent_text(serialized)
    assert_true(doc2.ok)
    assert_equal(doc2.text, doc.text)


def test_v25_m2_02_app_open_edit_save_and_export_ipynb() raises:
    """`App.open_path` opens `.ipynb` as `# %%`, `CM_SAVE` writes valid `.ipynb` JSON, and `CM_EXPORT_IPYNB` exports."""
    var dir = _scratch("open_save")
    var py_nb = dir + "/analysis.ipynb"
    var init_json = percent_text_to_ipynb(
        "# %% [markdown]\n# ## Experiment\n# %% Load\nx = 21\nprint(x * 2)\n",
        False,
    )
    _ = write_file(py_nb, str_bytes(init_json))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(py_nb)
    var ei = app.find_editor(py_nb)
    assert_true(ei >= 0)
    assert_equal(app.wins[ei].effective_lang(), HL_PYTHON)
    var loaded_txt = bytes_to_str(app.wins[ei].buf.to_bytes())
    assert_true(loaded_txt.find("# %% [markdown]") >= 0, loaded_txt)
    assert_true(loaded_txt.find("x = 21") >= 0, loaded_txt)

    # Append a new cell in the editor and save back to `.ipynb`
    app.focus(ei)
    ei = app.top_editor()
    app.wins[ei].goto(app.wins[ei].buf.count() - 1, app.wins[ei].buf.llen(app.wins[ei].buf.count() - 1))
    app.wins[ei].insert_text(decode("\n# %% Extra\ny = x + 9"), ACT_TYPE)
    app.exec(CM_SAVE)

    var disk_raw = bytes_to_str(read_file(py_nb))
    var parsed = json_parse(disk_raw)
    assert_true(parsed.ok, disk_raw)
    assert_equal(parsed.size(parsed.get(0, "cells")), 3)
    assert_false(app.disk_changed(app.find_editor(py_nb)), "saved .ipynb must match disk_hash")

    # Export a `.mojo` `# %%` notebook to `.ipynb` via CM_EXPORT_IPYNB
    var mj_src = dir + "/kernels.mojo"
    _ = write_file(mj_src, str_bytes("# %% [markdown]\n# Kernel notes\n# %% Bench\ndef main():\n    print(7)\n"))
    app.open_path(mj_src)
    app.exec(CM_EXPORT_IPYNB)
    var exported_p = dir + "/kernels.ipynb"
    assert_true(path_exists(exported_p), "Expected exported kernels.ipynb")
    var exp_doc = ipynb_to_percent_text(bytes_to_str(read_file(exported_p)))
    assert_true(exp_doc.ok and exp_doc.is_mojo)

    _ = run_system("rm -rf '" + dir + "'")


def test_v25_m2_03_live_cell_plot_capture_badge_and_terminal_graphics_preview() raises:
    """Running a `# %%` plot cell captures PNG, sets `📊 plot` badge, and renders via `CM_CELL_VIEW_PLOT`."""
    var dir = _scratch("plots")
    var nb = dir + "/plot_demo.ipynb"
    var png_out = dir + "/wave.png"
    # Pure-Python 16x16 valid RGB PNG generator + MPLBACKEND & pyplot auto-hook check
    var py_cell = (
        "# %% [markdown]\n"
        "# Sine wave plot\n"
        "# %% Render Plot\n"
        "import os, sys, types, struct, zlib\n"
        "assert os.environ.get('MPLBACKEND') == 'Agg'\n"
        "w, h = 16, 16\n"
        "rows = []\n"
        "for y in range(h):\n"
        "    row = bytearray([0])\n"
        "    for x in range(w):\n"
        "        row.extend([(x * 15) & 255, (y * 15) & 255, 200])\n"
        "    rows.append(bytes(row))\n"
        "data = b''.join(rows)\n"
        "def chunk(tag, body):\n"
        "    return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)\n"
        "png = b'\\x89PNG\\r\\n\\x1a\\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(data)) + chunk(b'IEND', b'')\n"
        "open('" + png_out + "', 'wb').write(png)\n"
        "print('plot_ready')\n"
        "print('__TM_PLOT__ " + png_out + "')\n"
        "# %% Auto Pyplot Hook\n"
        "mod = types.ModuleType('matplotlib.pyplot')\n"
        "class _FakeFig:\n"
        "    def savefig(self, path, **kw):\n"
        "        open(path, 'wb').write(png)\n"
        "mod._figs = [1]\n"
        "mod.get_fignums = lambda: list(mod._figs)\n"
        "mod.figure = lambda n: _FakeFig()\n"
        "mod.close = lambda which: mod._figs.clear()\n"
        "sys.modules['matplotlib.pyplot'] = mod\n"
        "print('pyplot_auto')\n"
    )
    _ = write_file(nb, str_bytes(percent_text_to_ipynb(py_cell, False)))

    var app = App()
    app.scr.resize(100, 32)
    app.cwd = dir
    app.open_path(nb)

    # First test pressing CM_RUN_CELL on `# %% [markdown]` cell (row 0)
    var ei = app.find_editor(nb)
    app.focus(ei)
    ei = app.top_editor()
    app.wins[ei].goto(0, 0)
    app.exec(CM_RUN_CELL)
    assert_true(app.wins[ei].cell_badges[0].find("markdown") >= 0, app.wins[ei].cell_badges[0])

    # Now execute the `# %% Render Plot` Python cell
    app.wins[ei].goto(3, 0)
    app.exec(CM_RUN_CELL)
    var deadline = Int(perf_counter_ns()) + 15_000_000_000
    while (app.cell_k_active or app.job.active) and Int(perf_counter_ns()) < deadline:
        app.cell_kernel_tick()
        app.poll_job()
        _ = external_call["usleep", Int32](UInt32(10000))

    assert_equal(len(app.cell_last_plots), 1)
    assert_equal(app.cell_last_plots[0], png_out)
    ei = app.find_editor(nb)
    var found_plot_badge = False
    for b in app.wins[ei].cell_badges:
        if b.find("📊 plot") >= 0 and b.find("plot_ready") >= 0:
            found_plot_badge = True
    assert_true(found_plot_badge, "Expected [✓ ... | 📊 plot | plot_ready] badge")

    # Also verify automatic matplotlib.pyplot figure capture hook in PYTHON_CELL_DAEMON_SCRIPT
    var auto_row = -1
    for r in range(app.wins[ei].buf.count()):
        if to_str(app.wins[ei].buf.line(r)).find("# %% Auto Pyplot Hook") >= 0:
            auto_row = r + 1
            break
    assert_true(auto_row > 0)
    app.wins[ei].goto(auto_row, 0)
    app.exec(CM_RUN_CELL)
    var deadline2 = Int(perf_counter_ns()) + 15_000_000_000
    while (app.cell_k_active or app.job.active) and Int(perf_counter_ns()) < deadline2:
        app.cell_kernel_tick()
        app.poll_job()
        _ = external_call["usleep", Int32](UInt32(10000))
    app.cell_kernels_stop()
    assert_equal(len(app.cell_last_plots), 1)
    assert_true(path_exists(app.cell_last_plots[0]), "Expected auto-saved pyplot PNG on disk")
    delete_file(app.cell_last_plots[0])
    app.cell_last_plots[0] = png_out

    # Verify PNG decodes & encodes cleanly to Sixel AND opens in M_DOCS via CM_CELL_VIEW_PLOT
    var pic = png_decode(read_file(png_out))
    assert_true(pic.ok)
    assert_equal(pic.w, 16)
    assert_equal(pic.h, 16)
    var six = sixel_encode(pic.rgba, pic.w, pic.h, 0)
    assert_true(six.byte_length() > 20)

    app.exec(CM_CELL_VIEW_PLOT)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.wins[app.top()].kind, WK_IMGVIEW)
    app.draw()
    assert_true(app.status.find("Showing 1 cell plot(s)") >= 0, app.status)

    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
