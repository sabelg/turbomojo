"""Tests for interactive notebook widgets, DataGrid/heatmap, GIF89a LZW encoder, LaTeX/Mermaid, and ipykernel bridge (src/nb_widgets.mojo)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.python import Python
from buffer import TextBuffer
from png import Picture, png_decode
from util import decode, read_file, write_file, cp_len
from nb_widgets import (
    WIDGET_SLIDER,
    WIDGET_BOOL,
    WIDGET_SELECT,
    NbWidget,
    DataGridColStats,
    DataGridState,
    parse_cell_widgets,
    format_widget_bar,
    step_widget_value,
    set_widget_ratio,
    rewrite_widget_line,
    parse_delimited_grid,
    encode_gif89a,
    gif_lzw_decompress,
    save_png_frames_as_gif,
    render_latex_inline,
    render_mermaid_diagram,
    build_ipykernel_bridge_daemon,
)


def _buf_from_text(s: String) -> TextBuffer:
    var b = TextBuffer()
    b.load(decode(s))
    return b^


def _abs_f64(x: Float64) -> Float64:
    return -x if x < 0.0 else x


# ---------------------------------------------------------------------------
# 1. Interactive Notebook Parameter Widgets (`NbWidget`)
# ---------------------------------------------------------------------------

def test_parse_and_format_widgets_mojo_and_python() raises:
    var src = (
        "# %% Simulation Params\n"
        "    var lr: Float64 = 0.01  # @param {type:\"slider\", min:0.0, max:1.0, step:0.05}\n"
        "steps = 32  # @param {type:\"slider\", min:4, max:128, step:4}\n"
        "use_shadows = True  # @param {type:\"boolean\"}\n"
        "mode = \"phong\"  # @param [\"flat\", \"phong\", \"ray\"]\n"
        "# @interact x=(0, 10, 1)\n"
        "x = 4\n"
    )
    var buf = _buf_from_text(src)
    var ws = parse_cell_widgets(buf, 0, buf.count() - 1)
    assert_equal(len(ws), 5)

    # 0: Mojo float slider
    assert_equal(ws[0].line_row, 1)
    assert_equal(ws[0].var_name, "lr")
    assert_equal(ws[0].kind, WIDGET_SLIDER)
    assert_false(ws[0].is_int)
    assert_true(_abs_f64(ws[0].num_val - 0.01) < 1e-9)
    assert_true(_abs_f64(ws[0].min_val - 0.0) < 1e-9)
    assert_true(_abs_f64(ws[0].max_val - 1.0) < 1e-9)
    assert_true(_abs_f64(ws[0].step_val - 0.05) < 1e-9)

    # 1: Python int slider
    assert_equal(ws[1].line_row, 2)
    assert_equal(ws[1].var_name, "steps")
    assert_equal(ws[1].kind, WIDGET_SLIDER)
    assert_true(ws[1].is_int)
    assert_equal(Int(ws[1].num_val), 32)
    assert_equal(Int(ws[1].min_val), 4)
    assert_equal(Int(ws[1].max_val), 128)
    assert_equal(Int(ws[1].step_val), 4)
    var sbar = format_widget_bar(ws[1], 18)
    assert_true(sbar.startswith("⚙ steps: [◀ "))
    assert_true(sbar.find("●") >= 0)
    assert_true(sbar.endswith(" ▶] 32"))

    # 2: Boolean checkbox
    assert_equal(ws[2].line_row, 3)
    assert_equal(ws[2].var_name, "use_shadows")
    assert_equal(ws[2].kind, WIDGET_BOOL)
    assert_true(ws[2].bool_val)
    assert_equal(format_widget_bar(ws[2]), "⚙ use_shadows: [✓ ON]")

    # 3: Select / dropdown
    assert_equal(ws[3].line_row, 4)
    assert_equal(ws[3].var_name, "mode")
    assert_equal(ws[3].kind, WIDGET_SELECT)
    assert_equal(ws[3].str_val, "phong")
    assert_equal(len(ws[3].options), 3)
    assert_equal(format_widget_bar(ws[3]), "⚙ mode: [◀ phong ▾ ▶] (2/3)")

    # 4: `# @interact x=(0, 10, 1)` paired with `x = 4`
    assert_equal(ws[4].line_row, 6)
    assert_equal(ws[4].var_name, "x")
    assert_equal(ws[4].kind, WIDGET_SLIDER)
    assert_true(ws[4].is_int)
    assert_equal(Int(ws[4].num_val), 4)
    assert_equal(Int(ws[4].min_val), 0)
    assert_equal(Int(ws[4].max_val), 10)
    assert_equal(Int(ws[4].step_val), 1)


def test_step_ratio_and_rewrite_widget_line() raises:
    var orig_mojo = "    var lr: Float64 = 0.01  # @param {type:\"slider\", min:0.0, max:1.0, step:0.05}"
    var orig_int = "steps = 32  # @param {type:\"slider\", min:4, max:128, step:4}"
    var orig_bool = "  var use_shadows: Bool = True   # @param {type:\"boolean\"}"
    var orig_sel = "mode = '#hex'  # @param ['#hex', 'rgb', 'hsl']"

    var buf = _buf_from_text(orig_mojo + "\n" + orig_int + "\n" + orig_bool + "\n" + orig_sel + "\n")
    var ws = parse_cell_widgets(buf, 0, 3)
    assert_equal(len(ws), 4)

    var w_lr = ws[0].copy()
    set_widget_ratio(w_lr, 0.25)
    assert_true(_abs_f64(w_lr.num_val - 0.25) < 1e-9)
    step_widget_value(w_lr, 1)
    assert_true(_abs_f64(w_lr.num_val - 0.3) < 1e-9)
    assert_equal(
        rewrite_widget_line(orig_mojo, w_lr),
        "    var lr: Float64 = 0.3  # @param {type:\"slider\", min:0.0, max:1.0, step:0.05}",
    )
    set_widget_ratio(w_lr, 5.0)  # Clamp above 1.0
    assert_equal(
        rewrite_widget_line(orig_mojo, w_lr),
        "    var lr: Float64 = 1.0  # @param {type:\"slider\", min:0.0, max:1.0, step:0.05}",
    )

    var w_steps = ws[1].copy()
    step_widget_value(w_steps, -2)
    assert_equal(Int(w_steps.num_val), 24)
    assert_equal(
        rewrite_widget_line(orig_int, w_steps),
        "steps = 24  # @param {type:\"slider\", min:4, max:128, step:4}",
    )
    step_widget_value(w_steps, -100)  # Clamp at min=4
    assert_equal(Int(w_steps.num_val), 4)

    var w_bool = ws[2].copy()
    step_widget_value(w_bool, 1)
    assert_false(w_bool.bool_val)
    assert_equal(format_widget_bar(w_bool), "⚙ use_shadows: [  OFF]")
    assert_equal(
        rewrite_widget_line(orig_bool, w_bool),
        "  var use_shadows: Bool = False   # @param {type:\"boolean\"}",
    )

    # Ensure `#` inside string literal `'#hex'` is NOT mistaken for comment start!
    var w_sel = ws[3].copy()
    assert_equal(w_sel.str_val, "#hex")
    step_widget_value(w_sel, 1)
    assert_equal(w_sel.str_val, "rgb")
    assert_equal(
        rewrite_widget_line(orig_sel, w_sel),
        "mode = 'rgb'  # @param ['#hex', 'rgb', 'hsl']",
    )
    step_widget_value(w_sel, 2)  # Wraps around (1 + 2) % 3 == 0 -> '#hex'
    assert_equal(w_sel.str_val, "#hex")


# ---------------------------------------------------------------------------
# 2. Virtualized DataGrid & 2D Tensor Heatmap State (`DataGridState`)
# ---------------------------------------------------------------------------

def test_datagrid_csv_sort_filter_heatmap_and_export() raises:
    var csv = (
        "kernel,latency_ms,tflops\n"
        "\"matmul, fp16\",2.5,120.0\n"
        "flash_attn,10.0,310.5\n"
        "layernorm,0.5,NaN\n"
        "softmax,1.25,85.0\n"
        "diverged_op,Inf,-Inf\n"
    )
    var grid = parse_delimited_grid("GPU Kernels", csv)
    assert_equal(grid.title, "GPU Kernels")
    assert_equal(len(grid.headers), 3)
    assert_equal(grid.headers[0], "kernel")
    assert_equal(grid.headers[1], "latency_ms")
    assert_equal(grid.headers[2], "tflops")
    assert_equal(len(grid.rows), 5)
    assert_equal(grid.rows[0][0], "matmul, fp16")

    # Stats & 8-bin sparkline
    assert_false(grid.col_stats[0].is_numeric)
    assert_true(grid.col_stats[1].is_numeric)
    assert_equal(grid.col_stats[1].count, 4)
    assert_equal(grid.col_stats[1].nan_count, 1)  # Inf
    assert_true(_abs_f64(grid.col_stats[1].min_val - 0.5) < 1e-9)
    assert_true(_abs_f64(grid.col_stats[1].max_val - 10.0) < 1e-9)
    assert_equal(cp_len(grid.col_stats[1].sparkline), 8)

    assert_true(grid.col_stats[2].is_numeric)
    assert_equal(grid.col_stats[2].count, 3)
    assert_equal(grid.col_stats[2].nan_count, 2)  # NaN and -Inf

    # Numeric sort on `tflops` (col 2): ascending -> -Inf, 85.0, 120.0, 310.5, then NaN at bottom!
    grid.sort_by_column(2)
    assert_true(grid.sort_asc)
    assert_equal(grid.rows[grid.filtered_indices[0]][0], "diverged_op")  # -Inf
    assert_equal(grid.rows[grid.filtered_indices[1]][0], "softmax")      # 85.0
    assert_equal(grid.rows[grid.filtered_indices[2]][0], "matmul, fp16") # 120.0
    assert_equal(grid.rows[grid.filtered_indices[3]][0], "flash_attn")   # 310.5
    assert_equal(grid.rows[grid.filtered_indices[4]][0], "layernorm")    # NaN pushed to bottom!

    # Toggle sort on col 2 -> descending -> 310.5, 120.0, 85.0, -Inf, and NaN STILL at bottom!
    grid.sort_by_column(2)
    assert_false(grid.sort_asc)
    assert_equal(grid.rows[grid.filtered_indices[0]][0], "flash_attn")
    assert_equal(grid.rows[grid.filtered_indices[1]][0], "matmul, fp16")
    assert_equal(grid.rows[grid.filtered_indices[4]][0], "layernorm")

    # Heatmap RGB checks
    assert_false(grid.heatmap_cell_rgb(0, 2)[0])  # Off when heatmap_mode == False
    grid.heatmap_mode = True
    assert_false(grid.heatmap_cell_rgb(0, 0)[0])  # String column -> False
    var hi_rgb = grid.heatmap_cell_rgb(0, 2)      # 310.5 (max)
    var lo_rgb = grid.heatmap_cell_rgb(2, 2)      # 85.0 (min)
    var nan_rgb = grid.heatmap_cell_rgb(4, 2)     # NaN -> crimson (170, 35, 55)
    var inf_rgb = grid.heatmap_cell_rgb(3, 2)     # -Inf -> crimson (170, 35, 55)
    assert_true(hi_rgb[0])
    assert_true(lo_rgb[0])
    assert_true(hi_rgb[1] > lo_rgb[1])            # Warmer/brighter red channel at max vs min
    assert_equal(nan_rgb[0], True)
    assert_equal(nan_rgb[1], 170)
    assert_equal(nan_rgb[2], 35)
    assert_equal(nan_rgb[3], 55)
    assert_equal(inf_rgb[1], 170)
    assert_equal(inf_rgb[2], 35)
    assert_equal(inf_rgb[3], 55)

    # Summary table rendering
    var summary = grid.render_summary_lines(80, 12)
    var joined = "\n".join(summary)
    assert_true(joined.find("tflops ▼") >= 0)
    assert_true(joined.find("[heatmap]") >= 0)
    assert_true(joined.find("NaN/Inf") >= 0)

    # Case-insensitive filter + RFC-4180 CSV export round-trip
    grid.set_filter("MATMUL")
    assert_equal(len(grid.filtered_indices), 1)
    var exported = grid.export_csv()
    assert_true(exported.find("\"matmul, fp16\",2.5,120.0") >= 0)
    var reimported = parse_delimited_grid("Reimported", exported)
    assert_equal(len(reimported.rows), 1)
    assert_equal(reimported.rows[0][0], "matmul, fp16")


def test_datagrid_json_objects_and_2d_matrix() raises:
    var js = "[{\"name\": \"a\", \"score\": 12}, {\"name\": \"b\", \"score\": 99, \"extra\": \"ok\"}]"
    var g_json = parse_delimited_grid("JSON", js)
    assert_equal(len(g_json.headers), 3)
    assert_equal(g_json.headers[0], "name")
    assert_equal(g_json.headers[1], "score")
    assert_equal(g_json.headers[2], "extra")
    assert_equal(len(g_json.rows), 2)
    assert_equal(g_json.rows[0][2], "")
    assert_equal(g_json.rows[1][1], "99")
    assert_equal(g_json.rows[1][2], "ok")

    var mat = "[[1.0, 2.0, 3.0], [4.0, NaN, 6.0]]"
    var g_mat = parse_delimited_grid("Tensor2D", mat)
    assert_equal(len(g_mat.headers), 3)
    assert_equal(g_mat.headers[0], "c0")
    assert_equal(len(g_mat.rows), 2)
    assert_true(g_mat.col_stats[1].is_numeric)
    assert_equal(g_mat.col_stats[1].nan_count, 1)


# ---------------------------------------------------------------------------
# 3. Pure-Mojo Animated GIF89a Multi-Frame Encoder (`encode_gif89a`)
# ---------------------------------------------------------------------------

def _make_test_pic(w: Int, h: Int, phase: Int) -> Picture:
    var p = Picture()
    p.ok = True
    p.w = w
    p.h = h
    p.rgba = List[UInt8](length=w * h * 4, fill=255)
    for y in range(h):
        for x in range(w):
            var off = (y * w + x) * 4
            if x == y:
                # Diagonal greyscale ramp to exercise the 40-step greyscale palette entries
                var g = UInt8(((x * 7 + phase * 19) * 255) // max(1, w * 7 + 60))
                p.rgba[off] = g
                p.rgba[off + 1] = g
                p.rgba[off + 2] = g
            else:
                p.rgba[off] = UInt8(((x * 37 + phase * 53) % 6) * 51)
                p.rgba[off + 1] = UInt8(((y * 29 + phase * 17) % 6) * 51)
                p.rgba[off + 2] = UInt8((((x + y) * 13 + phase * 41) % 6) * 51)
    return p^


def test_encode_gif89a_multiframe_and_lzw_roundtrip() raises:
    var frames = List[Picture]()
    frames.append(_make_test_pic(32, 24, 0))
    frames.append(_make_test_pic(32, 24, 1))
    frames.append(_make_test_pic(32, 24, 2))

    var gif = encode_gif89a(frames, fps=10, loop_count=3)
    assert_true(len(gif) > 820)

    # Check GIF89a header + Logical Screen Descriptor
    assert_equal(Int(gif[0]), 0x47)  # 'G'
    assert_equal(Int(gif[1]), 0x49)  # 'I'
    assert_equal(Int(gif[2]), 0x46)  # 'F'
    assert_equal(Int(gif[3]), 0x38)  # '8'
    assert_equal(Int(gif[4]), 0x39)  # '9'
    assert_equal(Int(gif[5]), 0x61)  # 'a'
    assert_equal(Int(gif[6]) | (Int(gif[7]) << 8), 32)
    assert_equal(Int(gif[8]) | (Int(gif[9]) << 8), 24)
    assert_equal(Int(gif[10]), 0xF7)  # GCT flag + 256 colors
    assert_equal(Int(gif[len(gif) - 1]), 0x3B)  # Trailer

    # After 13-byte header + 768-byte GCT = offset 781: Netscape 2.0 Application Extension
    var pos = 13 + 768
    assert_equal(Int(gif[pos]), 0x21)
    assert_equal(Int(gif[pos + 1]), 0xFF)
    assert_equal(Int(gif[pos + 2]), 0x0B)
    var app_id = String("")
    for k in range(11):
        app_id += chr(Int(gif[pos + 3 + k]))
    assert_equal(app_id, "NETSCAPE2.0")
    assert_equal(Int(gif[pos + 16]) | (Int(gif[pos + 17]) << 8), 3)  # loop_count = 3
    pos += 19

    # Walk and LZW-decompress all 3 frames!
    for fi in range(3):
        # GCE (8 bytes)
        assert_equal(Int(gif[pos]), 0x21)
        assert_equal(Int(gif[pos + 1]), 0xF9)
        var delay_cs = Int(gif[pos + 4]) | (Int(gif[pos + 5]) << 8)
        assert_equal(delay_cs, 10)  # 100 // 10 fps = 10 cs
        pos += 8

        # Image Descriptor (10 bytes)
        assert_equal(Int(gif[pos]), 0x2C)
        var iw = Int(gif[pos + 5]) | (Int(gif[pos + 6]) << 8)
        var ih = Int(gif[pos + 7]) | (Int(gif[pos + 8]) << 8)
        assert_equal(iw, 32)
        assert_equal(ih, 24)
        pos += 10

        var dec = gif_lzw_decompress(gif, pos)
        assert_true(dec[0])
        assert_equal(len(dec[1]), 32 * 24)
        pos = dec[2]

        # Reconstruct RGB from GCT and verify exact pixel colors on non-diagonal cube pixels!
        for y in range(24):
            for x in range(32):
                if x != y:
                    var pal_idx = Int(dec[1][y * 32 + x])
                    var pr = gif[13 + pal_idx * 3]
                    var pg = gif[13 + pal_idx * 3 + 1]
                    var pb = gif[13 + pal_idx * 3 + 2]
                    var off = (y * 32 + x) * 4
                    assert_equal(pr, frames[fi].rgba[off])
                    assert_equal(pg, frames[fi].rgba[off + 1])
                    assert_equal(pb, frames[fi].rgba[off + 2])

    assert_equal(pos, len(gif) - 1)
    assert_equal(Int(gif[pos]), 0x3B)


def test_encode_gif89a_dictionary_reset_over_4096_codes() raises:
    # High-entropy 110x110 = 12,100-pixel frame that overflows the 4096-entry LZW dictionary
    # multiple times, testing 9->10->11->12-bit code growth and Clear-code resets!
    var big = Picture()
    big.ok = True
    big.w = 110
    big.h = 110
    big.rgba = List[UInt8](length=110 * 110 * 4, fill=255)
    var state = 1234567
    for i in range(110 * 110):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        var cidx = state % 216
        var r6 = cidx // 36
        var g6 = (cidx // 6) % 6
        var b6 = cidx % 6
        big.rgba[i * 4] = UInt8(r6 * 51)
        big.rgba[i * 4 + 1] = UInt8(g6 * 51)
        big.rgba[i * 4 + 2] = UInt8(b6 * 51)

    var single = List[Picture]()
    single.append(big^)
    var gif = encode_gif89a(single, fps=15)
    # Single-frame GIF has no 19-byte Netscape extension: 13 + 768 + 8 (GCE) + 10 (ImgDesc) = 799
    var dec = gif_lzw_decompress(gif, 799)
    assert_true(dec[0])
    assert_equal(len(dec[1]), 110 * 110)
    assert_equal(dec[2], len(gif) - 1)

    state = 1234567
    for i in range(110 * 110):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        var expected_idx = state % 216
        var got_idx = Int(dec[1][i])
        # Cube color could map to greyscale ramp if r6==g6==b6, so compare actual RGB from GCT!
        var er = (expected_idx // 36) * 51
        var eg = ((expected_idx // 6) % 6) * 51
        var eb = (expected_idx % 6) * 51
        assert_equal(Int(gif[13 + got_idx * 3]), er)
        assert_equal(Int(gif[13 + got_idx * 3 + 1]), eg)
        assert_equal(Int(gif[13 + got_idx * 3 + 2]), eb)


def test_save_png_frames_as_gif_disk_roundtrip() raises:
    # Generate two valid tiny PNG files via Python zlib/struct and run `save_png_frames_as_gif`
    var py = Python.import_module("builtins")
    var ns = Python.dict()
    var mk_png_py = (
        "import struct, zlib\n"
        "def write_rgb_png(path, r, g, b):\n"
        "    w, h = 4, 4\n"
        "    raw = b''.join(b'\\x00' + bytes([r, g, b]) * w for _ in range(h))\n"
        "    def chunk(tag, body):\n"
        "        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)\n"
        "    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)\n"
        "    data = b'\\x89PNG\\r\\n\\x1a\\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')\n"
        "    with open(path, 'wb') as fh:\n"
        "        fh.write(data)\n"
        "write_rgb_png('/tmp/tm_nbw_f0.png', 255, 0, 0)\n"
        "write_rgb_png('/tmp/tm_nbw_f1.png', 0, 204, 51)\n"
    )
    _ = py.exec(mk_png_py, ns)

    var paths = List[String]()
    paths.append("/tmp/tm_nbw_f0.png")
    paths.append("/tmp/tm_nbw_f1.png")
    var out_gif = "/tmp/tm_nbw_out.gif"
    assert_true(save_png_frames_as_gif(paths, out_gif, fps=12))

    var written = read_file(out_gif)
    assert_true(len(written) > 800)
    assert_equal(Int(written[0]), 0x47)
    assert_equal(Int(written[len(written) - 1]), 0x3B)
    _ = png_decode(read_file("/tmp/tm_nbw_f0.png"))


# ---------------------------------------------------------------------------
# 4. Inline LaTeX Math & Fenced Mermaid Renderer
# ---------------------------------------------------------------------------

def test_render_latex_inline() raises:
    var line = "Loss $\\mathcal{L} = \\frac{1}{n} \\sum_{i=0}^{n} (y_i - \\hat{x}_i)^2$ with `code $x^2 + \\alpha$` intact!"
    var rendered = render_latex_inline(line)
    assert_true(rendered.find("(1)/(n)") >= 0)
    assert_true(rendered.find("∑ᵢ₌₀ⁿ") >= 0)
    assert_true(rendered.find("yᵢ") >= 0)
    assert_true(rendered.find(")²") >= 0)
    # Code span MUST stay untouched!
    assert_true(rendered.find("`code $x^2 + \\alpha$`") >= 0)

    var syms = render_latex_inline("$$\\forall x \\in \\mathbb{R}, \\nabla f(x) \\approx 0 \\Rightarrow \\Delta \\theta \\leq \\epsilon \\pm \\infty$$")
    assert_equal(syms, "∀ x ∈ ℝ, ∇ f(x) ≈ 0 ⇒ Δ θ ≤ ε ± ∞")

    var more = render_latex_inline("$A^T \\cdot B \\neq \\sqrt{x^2 + 1}$")
    assert_equal(more, "Aᵀ · B ≠ √(x² + 1)")


def test_render_mermaid_diagram_lr_and_td() raises:
    var lr_src = (
        "```mermaid\n"
        "flowchart LR\n"
        "    A[\"Source\"] --> B[\"Compile\"] -->|IR| C[\"GPU Kernel\"]\n"
        "```\n"
    )
    var lr_lines = render_mermaid_diagram(lr_src)
    assert_true(len(lr_lines) >= 3)
    var lr_joined = "\n".join(lr_lines)
    assert_true(lr_joined.find("╭") >= 0 and lr_joined.find("╮") >= 0)
    assert_true(lr_joined.find("╰") >= 0 and lr_joined.find("╯") >= 0)
    assert_true(lr_joined.find("Source") >= 0)
    assert_true(lr_joined.find("Compile") >= 0)
    assert_true(lr_joined.find("GPU Kernel") >= 0)
    assert_true(lr_joined.find("───▶") >= 0)
    assert_true(lr_joined.find("── IR ──▶") >= 0)

    var td_src = (
        "graph TD\n"
        "    In[\"Load CSV\"] --> Clean[\"Filter NaN\"]\n"
        "    Clean -->|valid| Plot[\"Render Sixel\"]\n"
    )
    var td_lines = render_mermaid_diagram(td_src)
    var td_joined = "\n".join(td_lines)
    assert_true(td_joined.find("Load CSV") >= 0)
    assert_true(td_joined.find("Filter NaN") >= 0)
    assert_true(td_joined.find("Render Sixel") >= 0)
    assert_true(td_joined.find("│") >= 0)
    assert_true(td_joined.find("▼") >= 0)
    assert_true(td_joined.find("valid") >= 0)


# ---------------------------------------------------------------------------
# 5. Optional External Jupyter `ipykernel` Client Bridge
# ---------------------------------------------------------------------------

def test_build_ipykernel_bridge_daemon() raises:
    var script = build_ipykernel_bridge_daemon("/tmp/kernel-12345.json")
    assert_true(script.find("BlockingKernelClient") >= 0)
    assert_true(script.find("/tmp/kernel-12345.json") >= 0)
    assert_true(script.find("RUN ") >= 0)
    assert_true(script.find("__TM_RUN__ ") >= 0)
    assert_true(script.find("__TM_PLOT__") >= 0)
    assert_true(script.find("__TM_CELL_END_") >= 0)
    assert_true(script.find("jupyter_client") >= 0 and script.find("pyzmq") >= 0)

    # Verify generated Python script compiles cleanly with zero syntax errors!
    var py = Python.import_module("builtins")
    _ = py.compile(script, "<ipykernel_bridge>", "exec")

    # Also test path escaping with single quotes and live wire-protocol execution
    var script_escaped = build_ipykernel_bridge_daemon("/tmp/user's_nonexistent_kernel_99999.json")
    _ = py.compile(script_escaped, "<ipykernel_bridge_escaped>", "exec")

    var ns = Python.dict()
    ns["bridge_src"] = script_escaped
    var mock_proto_py = (
        "import io, sys\n"
        "saved_in, saved_out = sys.stdin, sys.stdout\n"
        "sys.stdin = io.StringIO('RUN 7 1 /tmp/nb.py\\nprint(42)\\n')\n"
        "out_buf = io.StringIO()\n"
        "sys.stdout = out_buf\n"
        "try:\n"
        "    exec(compile(bridge_src, '<bridge>', 'exec'), {'__name__': '__main__'})\n"
        "finally:\n"
        "    sys.stdin, sys.stdout = saved_in, saved_out\n"
        "wire_out = out_buf.getvalue()\n"
    )
    _ = py.exec(mock_proto_py, ns)
    var wire_out = String(ns["wire_out"])
    assert_true(wire_out.find("Error:") >= 0)
    assert_true(wire_out.find("__TM_CELL_END_7_1__") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
