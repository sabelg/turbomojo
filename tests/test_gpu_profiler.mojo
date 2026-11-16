"""Unit tests for Phase 23 `gpu_profiler`: per-line stall attribution (`ncu`, `rocprof`, static PTX/AMDGCN),
interactive `ProfileView` flamegraph & multi-stream GPU timeline, `LayoutTensor` coalescing & XOR swizzle
simulator, and Modular MAX `Graph` kernel fusion visualizer."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from gpu_profiler import (
    LineStallAnnotation,
    parse_ncu_source_csv,
    parse_rocprof_trace_lines,
    analyze_static_asm_stalls,
    ProfileSpan,
    ProfileView,
    parse_chrome_trace_json,
    parse_folded_stacks,
    LayoutVizReport,
    analyze_layout_tensor,
    parse_layout_from_mojo_source,
    render_max_graph_fusion,
)


def test_ncu_source_csv_stalls() raises:
    var csv = (
        "==PROF== Connected to process 9182\n"
        + "\"Source File\",\"Line\",\"Warp Stall Sampling (All)\",\"Stall Long Scoreboard\","
        + "\"MIO Throttle\",\"Stall Barrier\",\"Stall Math Pipe Throttle\",\"Stall Branch Resolving\",\"Instructions Executed\"\n"
        + "\"\",\"\",\"sample\",\"sample\",\"sample\",\"sample\",\"sample\",\"sample\",\"inst\"\n"
        + "\"/ws/kernels/matmul.mojo\",\"24\",\"250\",\"220\",\"10\",\"0\",\"20\",\"0\",\"4096\"\n"
        + "\"/ws/kernels/matmul.mojo\",\"24\",\"175\",\"160\",\"5\",\"0\",\"10\",\"0\",\"2048\"\n"
        + "\"/ws/kernels/matmul.mojo\",\"31\",\"180\",\"10\",\"150\",\"20\",\"0\",\"0\",\"8192\"\n"
        + "\"/ws/kernels/matmul.mojo\",\"38\",\"245\",\"5\",\"10\",\"20\",\"210\",\"0\",\"16384\"\n"
        + "\"/ws/kernels/matmul.mojo\",\"45\",\"100\",\"0\",\"5\",\"85\",\"10\",\"0\",\"1024\"\n"
        + "\"/ws/kernels/matmul.mojo\",\"52\",\"50\",\"0\",\"0\",\"0\",\"5\",\"45\",\"512\"\n"
        + "\"/ws/kernels/other.mojo\",\"10\",\"900\",\"900\",\"0\",\"0\",\"0\",\"0\",\"1024\"\n"
    )
    var stalls = parse_ncu_source_csv(csv, "matmul.mojo")
    # Total samples in matmul.mojo = (250+175) + 180 + 245 + 100 + 50 = 425 + 180 + 245 + 100 + 50 = 1000
    assert_equal(len(stalls), 5)

    # Line 24: 425 / 1000 = 42.5% -> 425, HBM / Long Scoreboard, high severity (2), "▓ 42% HBM"
    assert_equal(stalls[0].line_no, 24)
    assert_equal(stalls[0].samples, 425)
    assert_equal(stalls[0].stall_pct_x10, 425)
    assert_equal(stalls[0].dominant_reason, "HBM / Long Scoreboard")
    assert_equal(stalls[0].pipe_tag, "HBM")
    assert_equal(stalls[0].severity, 2)
    assert_equal(stalls[0].gutter_badge, "▓ 42% HBM")

    # Line 31: 180 / 1000 = 18.0% -> 180, Shared / MIO Throttle, medium severity (1), "▒ 18% MIO"
    assert_equal(stalls[1].line_no, 31)
    assert_equal(stalls[1].stall_pct_x10, 180)
    assert_equal(stalls[1].dominant_reason, "Shared / MIO Throttle")
    assert_equal(stalls[1].pipe_tag, "SMEM")
    assert_equal(stalls[1].severity, 1)
    assert_equal(stalls[1].gutter_badge, "▒ 18% MIO")

    # Line 38: 245 / 1000 = 24.5% -> 245, Math Pipe Throttle -> TENSOR, medium severity (1)
    assert_equal(stalls[2].line_no, 38)
    assert_equal(stalls[2].stall_pct_x10, 245)
    assert_equal(stalls[2].dominant_reason, "Math Pipe Throttle")
    assert_equal(stalls[2].pipe_tag, "TENSOR")
    assert_equal(stalls[2].severity, 1)

    # Line 45: 100 / 1000 = 10.0% -> 100, Barrier Sync -> SYNC, low severity (0)
    assert_equal(stalls[3].line_no, 45)
    assert_equal(stalls[3].dominant_reason, "Barrier Sync")
    assert_equal(stalls[3].pipe_tag, "SYNC")
    assert_equal(stalls[3].severity, 0)

    # Line 52: 50 / 1000 = 5.0% -> 50, Branch Divergence -> ALU, low severity (0)
    assert_equal(stalls[4].line_no, 52)
    assert_equal(stalls[4].dominant_reason, "Branch Divergence")
    assert_equal(stalls[4].pipe_tag, "ALU")
    assert_equal(stalls[4].severity, 0)


def test_rocprof_trace_lines() raises:
    var roc_csv = (
        "Line,Instruction,SQ_WAIT_CNT,VMEM,LDS,S_BARRIER,MFMA\n"
        + "14,global_load_dwordx4,50,50,0,0,0\n"
        + "22,ds_read_b128,20,0,20,0,0\n"
        + "27,s_barrier,10,0,0,10,0\n"
        + "30,v_mfma_f32_16x16x16f16,20,0,0,0,20\n"
    )
    var res = parse_rocprof_trace_lines(roc_csv)
    assert_equal(len(res), 4)
    assert_equal(res[0].line_no, 14)
    assert_equal(res[0].stall_pct_x10, 500)
    assert_equal(res[0].dominant_reason, "HBM / Long Scoreboard")
    assert_equal(res[0].pipe_tag, "HBM")
    assert_equal(res[0].severity, 2)

    assert_equal(res[1].line_no, 22)
    assert_equal(res[1].dominant_reason, "Shared / MIO Throttle")
    assert_equal(res[1].pipe_tag, "SMEM")

    assert_equal(res[2].line_no, 27)
    assert_equal(res[2].dominant_reason, "Barrier Sync")
    assert_equal(res[2].pipe_tag, "SYNC")

    assert_equal(res[3].line_no, 30)
    assert_equal(res[3].dominant_reason, "Math Pipe Throttle")
    assert_equal(res[3].pipe_tag, "TENSOR")

    # Also test key=value trace format emitted by rocprof ATT / text trace
    var roc_kv = (
        "gemm.mojo:12 SQ_WAIT_CNT=60 VMEM=55 LDS=5\n"
        + "gemm.mojo:19 MFMA=40\n"
    )
    var res_kv = parse_rocprof_trace_lines(roc_kv)
    assert_equal(len(res_kv), 2)
    assert_equal(res_kv[0].line_no, 12)
    assert_equal(res_kv[0].pipe_tag, "HBM")
    assert_equal(res_kv[1].line_no, 19)
    assert_equal(res_kv[1].pipe_tag, "TENSOR")


def test_static_asm_stalls_ptx_and_amdgcn() raises:
    var ptx = (
        ".version 8.4\n"
        + ".target sm_90a\n"
        + ".visible .entry gemm_sm90() {\n"
        + "  .loc 1 15 4\n"
        + "  ld.global.nc.v4.f32 {%f1, %f2, %f3, %f4}, [%rd1];\n"
        + "  cp.async.cg.shared.global [%r2], [%rd2], 16;\n"
        + "  .loc 1 21 4\n"
        + "  bar.sync 0;\n"
        + "  .loc 1 25 8\n"
        + "  ld.shared.b32 %r5, [%r2];\n"
        + "  .loc 1 29 8\n"
        + "  wgmma.mma_async.sync.aligned.m64n128k16.f32.f16.f16 {%f10, %f11}, descA, descB;\n"
        + "  mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32 {%f12}, {%r6}, {%r7}, {%f12};\n"
        + "  ret;\n"
        + "}\n"
    )
    var ptx_stalls = analyze_static_asm_stalls(ptx)
    assert_equal(len(ptx_stalls), 4)
    assert_equal(ptx_stalls[0].line_no, 15)
    assert_equal(ptx_stalls[0].pipe_tag, "HBM")
    assert_equal(ptx_stalls[1].line_no, 21)
    assert_equal(ptx_stalls[1].pipe_tag, "SYNC")
    assert_equal(ptx_stalls[2].line_no, 25)
    assert_equal(ptx_stalls[2].pipe_tag, "SMEM")
    assert_equal(ptx_stalls[3].line_no, 29)
    assert_equal(ptx_stalls[3].pipe_tag, "TENSOR")

    var amdgcn = (
        "gemm_gfx942:\n"
        + "  global_load_dwordx4 v[0:3], v[4:5], off\n"
        + "  s_waitcnt vmcnt(0)\n"
        + "  ds_write_b128 v6, v[0:3]\n"
        + "  s_waitcnt lgkmcnt(0)\n"
        + "  s_barrier\n"
        + "  v_mfma_f32_32x32x8f16 a[0:15], v[8:9], v[10:11], a[0:15]\n"
        + "  s_endpgm\n"
    )
    var gcn_stalls = analyze_static_asm_stalls(amdgcn)
    assert_equal(len(gcn_stalls), 6)
    assert_equal(gcn_stalls[0].line_no, 2)
    assert_equal(gcn_stalls[0].pipe_tag, "HBM")
    assert_equal(gcn_stalls[1].line_no, 3)
    assert_equal(gcn_stalls[1].pipe_tag, "HBM")
    assert_equal(gcn_stalls[2].line_no, 4)
    assert_equal(gcn_stalls[2].pipe_tag, "SMEM")
    assert_equal(gcn_stalls[3].line_no, 5)
    assert_equal(gcn_stalls[3].pipe_tag, "SMEM")
    assert_equal(gcn_stalls[4].line_no, 6)
    assert_equal(gcn_stalls[4].pipe_tag, "SYNC")
    assert_equal(gcn_stalls[5].line_no, 7)
    assert_equal(gcn_stalls[5].pipe_tag, "TENSOR")


def test_profile_view_chrome_trace_and_controls() raises:
    var trace_json = (
        "{\"traceEvents\":["
        + "{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":1,\"tid\":7,\"args\":{\"name\":\"Stream 7 (Compute)\"}},"
        + "{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":1,\"tid\":8,\"args\":{\"name\":\"Stream 8 (H2D/Memcpy)\"}},"
        + "{\"ph\":\"B\",\"name\":\"step_forward\",\"cat\":\"cpu\",\"pid\":0,\"tid\":0,\"ts\":0.0},"
        + "{\"ph\":\"B\",\"name\":\"launch_matmul\",\"cat\":\"cpu\",\"pid\":0,\"tid\":0,\"ts\":100.0},"
        + "{\"ph\":\"E\",\"name\":\"launch_matmul\",\"cat\":\"cpu\",\"pid\":0,\"tid\":0,\"ts\":300.0},"
        + "{\"ph\":\"E\",\"name\":\"step_forward\",\"cat\":\"cpu\",\"pid\":0,\"tid\":0,\"ts\":1000.0},"
        + "{\"ph\":\"X\",\"name\":\"H2D_weights\",\"cat\":\"memcpy\",\"pid\":1,\"tid\":8,\"ts\":50.0,\"dur\":150.0},"
        + "{\"ph\":\"X\",\"name\":\"matmul_sm90\",\"cat\":\"kernel\",\"pid\":1,\"tid\":7,\"ts\":200.0,\"dur\":642.0}"
        + "]}"
    )
    var pv = parse_chrome_trace_json("MAX Trace", trace_json)
    assert_equal(len(pv.spans), 4)
    assert_equal(pv.min_start_us, 0.0)
    assert_equal(pv.max_end_us, 1000.0)
    assert_equal(pv.total_dur_us, 1000.0)

    # Check B/E nesting depth and self_us on CPU Host lane (`step_forward` dur=1000, child `launch_matmul` dur=200 -> self=800)
    assert_equal(pv.spans[0].name, "step_forward")
    assert_equal(pv.spans[0].depth, 0)
    assert_equal(pv.spans[0].dur_us, 1000.0)
    assert_equal(pv.spans[0].self_us, 800.0)

    var found_launch = False
    var matmul_idx = -1
    for i in range(len(pv.spans)):
        if pv.spans[i].name == "launch_matmul":
            found_launch = True
            assert_equal(pv.spans[i].depth, 1)
            assert_equal(pv.spans[i].dur_us, 200.0)
            assert_equal(pv.spans[i].self_us, 200.0)
        elif pv.spans[i].name == "matmul_sm90":
            matmul_idx = i
            assert_equal(pv.spans[i].stream_name, "Stream 7 (Compute)")
    assert_true(found_launch)
    assert_true(matmul_idx >= 0)

    # Search match %: "matmul" matches `launch_matmul` [100..300] and `matmul_sm90` [200..842]
    # Union is [100..842] = 742 us out of 1000 us -> 74.2% (742), NOT 200+642=842!
    pv.set_search("matmul")
    assert_equal(pv.matched_pct_x10, 742)

    # Exact single-kernel search "matmul_sm90" -> 642 us / 1000 us = 64.2% (642)
    pv.set_search("matmul_sm90")
    assert_equal(pv.matched_pct_x10, 642)

    # Render in Flamegraph mode
    var fg_txt = "\n".join(pv.render_lines(100, 12))
    assert_true(fg_txt.find("[Flamegraph]") >= 0, fg_txt)
    assert_true(fg_txt.find("[Match: 64.2%") >= 0, fg_txt)
    assert_true(fg_txt.find("matmul_sm90") >= 0, fg_txt)
    assert_true(fg_txt.find("Selected:") >= 0, fg_txt)

    # Toggle to Multi-Stream GPU Timeline mode and render
    pv.toggle_mode()
    assert_true(pv.timeline_mode)
    var tl_txt = "\n".join(pv.render_lines(100, 12))
    assert_true(tl_txt.find("[GPU Timeline]") >= 0, tl_txt)
    assert_true(tl_txt.find("Stream 7 (Compute)") >= 0, tl_txt)
    assert_true(tl_txt.find("Stream 8 (H2D/Memcpy)") >= 0, tl_txt)
    assert_true(tl_txt.find("│") >= 0, tl_txt)

    # Zoom into `matmul_sm90` -> window becomes [200, 842], match % for "matmul_sm90" becomes 100.0% (1000)!
    pv.selected_idx = matmul_idx
    pv.zoom_into_selected()
    assert_equal(pv.zoom_start_us, 200.0)
    assert_equal(pv.zoom_end_us, 842.0)
    assert_equal(pv.matched_pct_x10, 1000)

    # Zoom out pops stack back to [0, 1000]
    pv.zoom_out()
    assert_equal(pv.zoom_start_us, 0.0)
    assert_equal(pv.zoom_end_us, 1000.0)
    assert_equal(pv.matched_pct_x10, 642)

    # Zoom by factor 0.5 halves window width to 500 us, zoom_reset restores full range
    pv.zoom_by_factor(0.5)
    assert_equal(pv.zoom_end_us - pv.zoom_start_us, 500.0)
    pv.zoom_reset()
    assert_equal(pv.zoom_start_us, 0.0)
    assert_equal(pv.zoom_end_us, 1000.0)


def test_folded_stacks_and_benchmark_tables() raises:
    var folded = (
        "# Flamegraph folded stacks\n"
        + "main;run_kernel;load_smem 180\n"
        + "main;run_kernel;matmul_tile 420\n"
        + "main;epilogue 400\n"
    )
    var fv = parse_folded_stacks("Folded CPU/GPU", folded)
    assert_equal(fv.total_dur_us, 1000.0)
    assert_true(len(fv.spans) >= 4)
    fv.set_search("matmul_tile")
    assert_equal(fv.matched_pct_x10, 420)

    var bench_tbl = (
        "| name | met (ms) | iters |\n"
        + "|---|---|---|\n"
        + "| gemm/naive | 1.5 | 50 |\n"
        + "| gemm/swizzled | 0.5 | 200 |\n"
    )
    var bv = parse_folded_stacks("Mojo Bench", bench_tbl)
    assert_equal(bv.total_dur_us, 2000.0)
    assert_true(len(bv.spans) >= 3)


def test_layout_tensor_coalescing_and_swizzle() raises:
    # 1. Row-major 16x16 FP32: 128B coalesced (1 sector/warp = 100%), 1-way conflict-free across 32 banks
    var row_rep = analyze_layout_tensor(16, 16, 16, 1, 4, 16, 0)
    assert_equal(row_rep.global_transactions_per_warp, 1)
    assert_equal(row_rep.coalescing_efficiency_pct, 100)
    assert_equal(row_rep.smem_bank_conflicts, 1)
    var diag_joined = "\n".join(row_rep.diagram_lines)
    assert_true(diag_joined.find("T00->B00") >= 0 and diag_joined.find("T31->B31") >= 0, diag_joined)

    # 2. Column-major 32x32 FP32 (unswizzled): 16 global 128B sectors, 16-way bank conflict
    var col_rep = analyze_layout_tensor(32, 32, 1, 32, 4, 16, 0)
    assert_equal(col_rep.global_transactions_per_warp, 16)
    assert_true(col_rep.coalescing_efficiency_pct < 20)
    assert_equal(col_rep.smem_bank_conflicts, 16)
    assert_true(col_rep.recommended_swizzle.find("Swizzle") >= 0)
    assert_true(col_rep.recommended_swizzle.find("+1") >= 0)

    # 3. Same Column-major 32x32 FP32 with 4-bit XOR bank swizzle -> 1-way conflict-free!
    var swz_rep = analyze_layout_tensor(32, 32, 1, 32, 4, 16, 4)
    assert_equal(swz_rep.smem_bank_conflicts, 1)

    # 4. Full 32-lane strided column access (`thread_cols = 32`) unswizzled = 32-way -> `swizzle_bits = 5` = 1-way!
    var col32 = analyze_layout_tensor(32, 32, 1, 32, 4, 32, 0)
    assert_equal(col32.global_transactions_per_warp, 32)
    assert_equal(col32.smem_bank_conflicts, 32)
    var col32_swz = analyze_layout_tensor(32, 32, 1, 32, 4, 32, 5)
    assert_equal(col32_swz.smem_bank_conflicts, 1)


def test_parse_layout_from_source_and_max_graph_fusion() raises:
    var src_col = "comptime tile_layout = Layout.col_major(32, 32)\nvar tile = LayoutTensor[DType.float32, tile_layout](ptr)\n"
    var r_col = parse_layout_from_mojo_source(src_col)
    assert_equal(r_col.shape_r, 32)
    assert_equal(r_col.shape_c, 32)
    assert_equal(r_col.stride_r, 1)
    assert_equal(r_col.stride_c, 32)
    assert_equal(r_col.elem_bytes, 4)
    assert_true(r_col.smem_bank_conflicts > 1)

    var src_tup = "var t = LayoutTensor[BFloat16, Layout(IntTuple(16, 32), IntTuple(33, 1))](smem_ptr)\n"
    var r_tup = parse_layout_from_mojo_source(src_tup)
    assert_equal(r_tup.shape_r, 16)
    assert_equal(r_tup.shape_c, 32)
    assert_equal(r_tup.stride_r, 33)
    assert_equal(r_tup.stride_c, 1)
    assert_equal(r_tup.elem_bytes, 2)
    assert_equal(r_tup.smem_bank_conflicts, 1)

    # Fallback 16x16 Float16 demo when no Layout is present
    var r_def = parse_layout_from_mojo_source("def add_one(x: Int) -> Int:\n    return x + 1\n")
    assert_equal(r_def.shape_r, 16)
    assert_equal(r_def.shape_c, 16)
    assert_equal(r_def.elem_bytes, 2)

    # MAX Graph Fusion Visualizer
    var max_src = (
        "with Graph(\"transformer_mlp\") as g:\n"
        + "    var mm = ops.matmul(x, w_gate)\n"
        + "    var biased = ops.add(mm, bias)\n"
        + "    var act = ops.gelu(biased)\n"
        + "    var normed = ops.layer_norm(act, gamma, beta)\n"
        + "    var probs = ops.softmax(normed)\n"
    )
    var fusion_lines = render_max_graph_fusion(max_src)
    var fusion_txt = "\n".join(fusion_lines)
    assert_true(fusion_txt.find("╭─ Fused Epilogue Kernel: matmul + bias_add + gelu ─") >= 0, fusion_txt)
    assert_true(fusion_txt.find("2 HBM round-trip(s) saved") >= 0, fusion_txt)
    assert_true(fusion_txt.find("layer_norm") >= 0 and fusion_txt.find("softmax") >= 0, fusion_txt)


def test_edge_cases_top_array_and_bracket_swizzle() raises:
    # Top-level JSON array (PyTorch Kineto / rocprof array format) with string tid
    var arr_json = (
        "[{\"ph\":\"X\",\"name\":\"wgmma_f16\",\"cat\":\"kernel\",\"pid\":0,\"tid\":\"Stream 0 (Compute)\",\"ts\":10.0,\"dur\":4800.0},"
        + "{\"ph\":\"X\",\"name\":\"H2D_input\",\"cat\":\"memcpy\",\"pid\":0,\"tid\":\"Stream 1 (H2D/Memcpy)\",\"ts\":0.0,\"dur\":1200.0}]"
    )
    var pv_arr = parse_chrome_trace_json("Kineto Array", arr_json)
    assert_equal(len(pv_arr.spans), 2)
    assert_equal(pv_arr.min_start_us, 0.0)
    assert_equal(pv_arr.max_end_us, 4810.0)
    pv_arr.toggle_mode()
    var arr_tl = "\n".join(pv_arr.render_lines(96, 10))
    assert_true(arr_tl.find("wgmma_f16") >= 0 and arr_tl.find("4.8ms") >= 0, arr_tl)

    # `std.benchmark` console colon report
    var console_bench = "Benchmark report:\nbench_rope_f16: 120.0 us (1000 iters)\nbench_attn_f16: 380.0 us (500 iters)\n"
    var pv_cb = parse_folded_stacks("Console Bench", console_bench)
    assert_equal(pv_cb.total_dur_us, 500.0)
    pv_cb.set_search("bench_attn_f16")
    assert_equal(pv_cb.matched_pct_x10, 760)
    pv_cb.set_search("")
    assert_equal(pv_cb.matched_pct_x10, 0)

    # Parameterized `Layout.col_major[32, 32]` + `Swizzle[4, 3, 3]` + `Float64`
    var swz_src = "var s = Swizzle[4, 3, 3]()\nvar t = LayoutTensor[Float32, Layout.col_major[32, 32]]()\n"
    var swz_parsed = parse_layout_from_mojo_source(swz_src)
    assert_equal(swz_parsed.swizzle_bits, 4)
    assert_equal(swz_parsed.smem_bank_conflicts, 1)

    var fp64_row = analyze_layout_tensor(16, 16, 16, 1, 8, 16, 0)
    assert_equal(fp64_row.global_transactions_per_warp, 2)
    assert_equal(fp64_row.coalescing_efficiency_pct, 100)
    assert_equal(fp64_row.smem_bank_conflicts, 1)

    # Empty inputs never raise or crash
    assert_equal(len(parse_ncu_source_csv("")), 0)
    assert_equal(len(parse_rocprof_trace_lines("")), 0)
    assert_equal(len(analyze_static_asm_stalls("")), 0)
    assert_equal(len(parse_chrome_trace_json("empty", "").spans), 0)
    assert_equal(len(parse_folded_stacks("empty", "").spans), 0)
    var empty_fusion = "\n".join(render_max_graph_fusion("def noop(): pass\n"))
    assert_true(empty_fusion.find("no `ops.*`") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
