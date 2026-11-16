"""E2E Test Suite for v4.0 Phase 21 (`v3.1`):
Interactive `# @param` / `@interact` Notebook Widgets, Virtualized `WK_DATAGRID` Table & Heatmap
Window, Pure-Mojo GIF89a Export + Scrubber in `WK_IMGVIEW`, LaTeX/Mermaid Markdown Rendering, and
External Jupyter `ipykernel` Connection Bridge.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import App
from screen import CONT
from term import KEY_ENTER, KEY_ESC, KEY_RIGHT, KEY_LEFT, MOD_ALT
from commands import CM_CELL_DATAGRID, CM_IMG_SAVE_GIF, CM_CONNECT_KERNEL, CM_MD_PREVIEW
from window import WK_DATAGRID, WK_IMGVIEW, WK_MDPREVIEW
from dialog import D_SAVE_GIF, D_CONNECT_KERNEL
from ipynb import percent_text_to_ipynb
from png import Picture, png_decode
from nb_widgets import encode_gif89a
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
    shell_quote,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v40-p21-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def _clean(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def _screen_text(app: App) -> String:
    var out = String("")
    for r in range(app.scr.h):
        var cps = List[Int]()
        for c in range(app.scr.w):
            var ch = app.scr.ch[r * app.scr.w + c]
            if ch != CONT:
                cps.append(ch)
        out += to_str(cps) + "\n"
    return out^


def test_p21_e2e_interactive_notebook_widgets_and_latex_mermaid() raises:
    var d = _scratch("widgets")
    var nb_file = d + "/demo.ipynb"
    var src = (
        "# %% [markdown]\n"
        "# # Loss $\\nabla L(\\theta) = \\alpha x^2 + \\beta_0$\n"
        "# %%\n"
        "steps = 16  # @param {type:\"slider\", min:4, max:64, step:4}\n"
        "shadows = False  # @param {type:\"boolean\"}\n"
        "shader = \"flat\"  # @param [\"flat\", \"phong\", \"ray\"]\n"
    )
    _ = write_file(nb_file, str_bytes(percent_text_to_ipynb(src, False)))
    var app = App()
    app.scr.resize(130, 38)
    app.trust_enforced = False
    app.open_path(nb_file)
    var ei = app.top_editor()
    assert_true(ei >= 0)
    app.wins[ei].goto(3, 0)
    app.draw()
    var scr0 = _screen_text(app)
    assert_true(scr0.find("⚙ steps:") >= 0, "EOL slider widget bar rendered")
    assert_true(scr0.find("∇") >= 0 or scr0.find("α") >= 0, "Inline LaTeX math rendered in Markdown cell")

    # Step slider with Alt-Right on row 3 (`steps = 16` -> `steps = 20`) without running kernel
    _ = app.step_notebook_widget_at(ei, 3, 1, -1.0, False)
    assert_true(to_str(app.wins[ei].buf.line(3)).startswith("steps = 20  # @param"))

    # Toggle boolean widget on row 4 (`False` -> `True`) and dropdown on row 5 (`flat` -> `phong`)
    _ = app.step_notebook_widget_at(ei, 4, 1, -1.0, False)
    assert_true(to_str(app.wins[ei].buf.line(4)).startswith("shadows = True  # @param"))
    _ = app.step_notebook_widget_at(ei, 5, 1, -1.0, False)
    assert_true(to_str(app.wins[ei].buf.line(5)).startswith("shader = \"phong\"  # @param"))

    # Verify Markdown Preview (`WK_MDPREVIEW`) renders both LaTeX math and fenced ```mermaid diagrams
    var md_path = d + "/arch.md"
    _ = write_file(
        md_path,
        str_bytes(
            "# Energy $E = mc^2$\n\n```mermaid\ngraph LR\n  A[\"Input\"] --> B[\"Kernel\"]\n```\n"
        ),
    )
    app.open_path(md_path)
    app.exec(CM_MD_PREVIEW)
    var has_md_pane = False
    for wi in range(len(app.wins)):
        if app.wins[wi].kind == WK_MDPREVIEW:
            has_md_pane = True
            break
    assert_true(has_md_pane, "CM_MD_PREVIEW opened side-by-side WK_MDPREVIEW pane")
    app.draw()
    var md_scr = _screen_text(app)
    assert_true(md_scr.find("mc²") >= 0, "Superscript rendered in WK_MDPREVIEW")
    assert_true(md_scr.find("Input") >= 0 and md_scr.find("Kernel") >= 0, "Mermaid diagram rendered in WK_MDPREVIEW")
    _clean(d)


def test_p21_e2e_datagrid_window_sort_heatmap_and_csv_export() raises:
    var d = _scratch("datagrid")
    var csv_path = d + "/metrics.csv"
    _ = write_file(
        csv_path,
        str_bytes("kernel,tflops,loss\nwgmma_fp8,620.5,0.21\nsgemm_f32,48.2,0.89\nhgemm_bf16,312.0,NaN\n"),
    )
    var app = App()
    app.cwd = d
    app.scr.resize(120, 36)
    app.open_path(csv_path)
    app.exec(CM_CELL_DATAGRID)
    var top_i = app.top()
    assert_equal(app.wins[top_i].kind, WK_DATAGRID)
    assert_true(app.datagrid.heatmap_mode)
    app.draw()
    var dg_scr = _screen_text(app)
    assert_true(dg_scr.find("wgmma_fp8") >= 0)
    assert_true(dg_scr.find("tflops") >= 0)

    # Move right to `tflops` column and press 's' to sort ascending, then 's' again for descending
    app.handle_key(KEY_RIGHT)
    app.handle_key(115)  # 's'
    assert_equal(app.datagrid.sort_col, 1)
    assert_true(app.datagrid.sort_asc)
    app.handle_key(115)  # 's' -> descending
    assert_false(app.datagrid.sort_asc)

    # Press 'e' to export sorted CSV
    app.handle_key(101)  # 'e'
    var exported = d + "/datagrid_export.csv"
    assert_true(path_exists(exported))
    var exp_txt = bytes_to_str(read_file(exported))
    assert_true(exp_txt.find("620.5") < exp_txt.find("312.0"))

    # Esc closes WK_DATAGRID
    app.handle_key(KEY_ESC)
    assert_true(app.datagrid_index() < 0)
    _clean(d)


def test_p21_e2e_imgview_scrubber_gif89a_export_and_ipykernel_dialog() raises:
    var d = _scratch("gif")
    # Write 2 tiny valid PNG files via Python or minimal 1x1 PNG bytes
    var p1 = d + "/f0.png"
    var p2 = d + "/f1.png"
    _ = run_system(
        "python3 -c \"import zlib,struct;"
        "sig=b'\\x89PNG\\r\\n\\x1a\\n';"
        "ch=lambda t,b: struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff);"
        "ihdr=ch(b'IHDR',struct.pack('>IIBBBBB',4,4,8,2,0,0,0));"
        "raw1=b''.join(b'\\x00'+b'\\xff\\x20\\x40'*4 for _ in range(4));"
        "raw2=b''.join(b'\\x00'+b'\\x20\\xc0\\xff'*4 for _ in range(4));"
        "open(" + shell_quote(p1) + ",'wb').write(sig+ihdr+ch(b'IDAT',zlib.compress(raw1))+ch(b'IEND',b''));"
        "open(" + shell_quote(p2) + ",'wb').write(sig+ihdr+ch(b'IDAT',zlib.compress(raw2))+ch(b'IEND',b''))\""
    )
    assert_true(path_exists(p1) and path_exists(p2))
    var pic1 = png_decode(read_file(p1))
    var pic2 = png_decode(read_file(p2))
    assert_true(pic1.ok and pic2.ok)
    var frames = List[Picture]()
    frames.append(pic1^)
    frames.append(pic2^)
    var gif_raw = encode_gif89a(frames, 12)
    assert_true(len(gif_raw) > 40)
    assert_equal(Int(gif_raw[0]), 71)  # 'G'
    assert_equal(Int(gif_raw[len(gif_raw) - 1]), 0x3B)

    var app = App()
    app.cwd = d
    app.scr.resize(120, 36)
    app.cell_last_plots.append("ANIM|12|" + p1 + "|" + p2)
    app.cell_open_plot_preview(0, "Orbital Anim", 0)
    var iv = app.top()
    assert_equal(app.wins[iv].kind, WK_IMGVIEW)
    app.draw()
    var iv_scr = _screen_text(app)
    assert_true(iv_scr.find("Frame 1/2") >= 0, "Scrubber bar rendered in WK_IMGVIEW")
    assert_true(iv_scr.find("[g GIF]") >= 0, "Save GIF button rendered in WK_IMGVIEW")

    # Press 'g' in WK_IMGVIEW -> opens D_SAVE_GIF, then apply export!
    app.handle_key(103)  # 'g'
    assert_equal(app.dlg.kind, D_SAVE_GIF)
    app.dismiss_dialog()
    var out_gif = d + "/orbit.gif"
    assert_true(app.save_gif_apply(out_gif))
    var saved_bytes = read_file(out_gif)
    assert_true(len(saved_bytes) > 40 and Int(saved_bytes[0]) == 71 and Int(saved_bytes[1]) == 73)

    # Verify CM_CONNECT_KERNEL opens D_CONNECT_KERNEL and sets external_kernel_json
    app.trust_enforced = False
    app.exec(CM_CONNECT_KERNEL)
    assert_equal(app.dlg.kind, D_CONNECT_KERNEL)
    app.dismiss_dialog()
    app.connect_kernel_apply(d + "/kernel-1234.json")
    assert_equal(app.external_kernel_json, d + "/kernel-1234.json")
    _clean(d)


def main() raises:
    var suite = TestSuite()
    suite.test[test_p21_e2e_interactive_notebook_widgets_and_latex_mermaid]()
    suite.test[test_p21_e2e_datagrid_window_sort_heatmap_and_csv_export]()
    suite.test[test_p21_e2e_imgview_scrubber_gif89a_export_and_ipykernel_dialog]()
    suite^.run()
