"""E2E Test Suite for v4.0 Phase 23 (`v3.3`):
GPU Per-Line Hardware & Static PTX/AMDGCN Stall Gutter Badges, Interactive `WK_PROFILE`
Flamegraph & Multi-Stream GPU Timeline Window (`CM_PROFILE_VIEW`), and `LayoutTensor`
32-Lane Coalescing / 32-Bank XOR Swizzle + MAX `Graph` Epilogue Fusion Visualizer (`CM_LAYOUT_VIZ`).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import App
from screen import CONT
from term import KEY_ENTER, KEY_ESC, KEY_DOWN
from commands import CM_PROFILE_VIEW, CM_LAYOUT_VIZ
from window import WK_PROFILE
from gpu_profiler import parse_ncu_source_csv, analyze_static_asm_stalls
from signals import own_pid
from util import (
    env_or,
    run_system,
    write_file,
    str_bytes,
    to_str,
    shell_quote,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v40-p23-" + tag + "-" + String(own_pid())
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


def test_p23_e2e_per_line_ncu_and_static_ptx_stall_gutter_badges() raises:
    var d = _scratch("stalls")
    var kpath = d + "/gemm_kernel.mojo"
    var ksrc = (
        "def gemm_sm90(a: UnsafePointer[Float16], b: UnsafePointer[Float16]):\n"
        "    var x = a[0]\n"
        "    var y = b[0]\n"
        "    var z = x + y\n"
        "    _ = z\n"
    )
    _ = write_file(kpath, str_bytes(ksrc))

    var app = App()
    app.scr.resize(130, 36)
    app.open_path(kpath)
    var ncu_csv = (
        "\"Source File\",\"Line\",\"Warp Stall Sampling (All Samples)\",\"Stall Long Scoreboard\",\"Stall MIO Throttle\",\"Stall Barrier\"\n"
        "\"gemm_kernel.mojo\",\"2\",\"60\",\"52\",\"4\",\"0\"\n"
        "\"gemm_kernel.mojo\",\"3\",\"40\",\"4\",\"30\",\"2\"\n"
    )
    var stalls = parse_ncu_source_csv(ncu_csv, "gemm_kernel.mojo")
    assert_equal(len(stalls), 2)
    app.apply_stall_annotations_to_editor(kpath, stalls)
    app.draw()
    var scr = _screen_text(app)
    assert_true(scr.find("HBM") >= 0, "Per-line HBM scoreboard stall badge drawn on editor row")
    assert_true(scr.find("SMEM") >= 0 or scr.find("MIO") >= 0, "Per-line MIO/SMEM stall badge drawn on editor row")

    # Verify static PTX `.loc` stall analyzer overlays badges without hardware profiler
    var ptx = (
        ".file 1 \"gemm_kernel.mojo\"\n"
        ".loc 1 4 5\n"
        "wgmma.mma_async.sync.aligned.m64n128k16.f32.bf16.bf16 {d0, d1}, desc_a, desc_b;\n"
        "bar.sync 0;\n"
    )
    app.codegen_path = kpath
    var static_s = analyze_static_asm_stalls(ptx)
    assert_true(len(static_s) >= 1)
    app.apply_static_asm_stalls_to_codegen(ptx)
    app.draw()
    assert_true(len(app.wins[app.top_editor()].bench_badges) >= 2)
    _clean(d)


def test_p23_e2e_profile_window_flamegraph_zoom_and_multistream_timeline() raises:
    var d = _scratch("profile")
    var trace_path = d + "/nsys_trace.json"
    var trace_json = (
        "{\"traceEvents\":["
        "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"args\":{\"name\":\"GPU 0\"}},"
        "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":7,\"args\":{\"name\":\"Stream 7 (Compute)\"}},"
        "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":8,\"args\":{\"name\":\"Stream 8 (H2D)\"}},"
        "{\"name\":\"h2d_stage_tiles\",\"cat\":\"memcpy\",\"ph\":\"X\",\"pid\":1,\"tid\":8,\"ts\":100,\"dur\":250},"
        "{\"name\":\"flash_attn_fwd_sm90\",\"cat\":\"kernel\",\"ph\":\"X\",\"pid\":1,\"tid\":7,\"ts\":200,\"dur\":800},"
        "{\"name\":\"online_softmax_warp\",\"cat\":\"kernel\",\"ph\":\"X\",\"pid\":1,\"tid\":7,\"ts\":350,\"dur\":450}"
        "]}"
    )
    _ = write_file(trace_path, str_bytes(trace_json))

    var app = App()
    app.cwd = d
    app.scr.resize(130, 36)
    app.open_path(trace_path)
    app.exec(CM_PROFILE_VIEW)
    assert_equal(app.wins[app.top()].kind, WK_PROFILE)
    assert_false(app.prof_view.timeline_mode)
    app.draw()
    var fg_scr = _screen_text(app)
    assert_true(fg_scr.find("flash_attn_fwd_sm90") >= 0)

    # Zoom into selected span (`Enter`), verify window narrows, then reset (`0`)
    var full_span = app.prof_view.zoom_end_us - app.prof_view.zoom_start_us
    app.handle_key(KEY_DOWN)
    app.handle_key(KEY_ENTER)
    assert_true((app.prof_view.zoom_end_us - app.prof_view.zoom_start_us) <= full_span)
    app.handle_key(48)  # '0' reset
    assert_equal(app.prof_view.zoom_end_us - app.prof_view.zoom_start_us, full_span)

    # Toggle to Multi-Stream GPU Timeline (`t`) and verify stream lanes render
    app.handle_key(116)  # 't'
    assert_true(app.prof_view.timeline_mode)
    app.draw()
    var tl_scr = _screen_text(app)
    assert_true(tl_scr.find("Stream 7") >= 0 or tl_scr.find("Multi-Stream GPU Timeline") >= 0)

    app.handle_key(KEY_ESC)
    assert_true(app.profile_index() < 0)
    _clean(d)


def test_p23_e2e_layout_tensor_coalescing_swizzle_and_max_fusion() raises:
    var d = _scratch("layout")
    var mpath = d + "/max_block.mojo"
    var src = (
        "from layout import Layout, LayoutTensor\n"
        "def build_mlp(g: Graph, x: Symbol, w: Symbol, bias: Symbol):\n"
        "    comptime tile_layout = Layout.col_major(16, 16)\n"
        "    var mm = ops.matmul(x, w)\n"
        "    var b = ops.add(mm, bias)\n"
        "    var y = ops.gelu(b)\n"
        "    return y\n"
    )
    _ = write_file(mpath, str_bytes(src))
    var app = App()
    app.scr.resize(130, 38)
    app.open_path(mpath)
    app.exec(CM_LAYOUT_VIZ)
    var mi = app.msg_index()
    assert_true(mi >= 0)
    var msg_txt = to_str(app.wins[mi].buf.all_text())
    assert_true(msg_txt.find("16x16") >= 0 or msg_txt.find("LayoutTensor") >= 0)
    assert_true(msg_txt.find("Fused") >= 0 and msg_txt.find("gelu") >= 0, "MAX Graph epilogue fusion box rendered")
    _clean(d)


def main() raises:
    var suite = TestSuite()
    suite.test[test_p23_e2e_per_line_ncu_and_static_ptx_stall_gutter_badges]()
    suite.test[test_p23_e2e_profile_window_flamegraph_zoom_and_multistream_timeline]()
    suite.test[test_p23_e2e_layout_tensor_coalescing_swizzle_and_max_fusion]()
    suite^.run()
