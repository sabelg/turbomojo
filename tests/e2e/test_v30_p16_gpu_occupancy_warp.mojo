"""E2E Test Suite for v3.0 Phase 16 (v2.7):
GPU Occupancy Modeling, 32-Bank Shared-Memory Conflict Analyzer, and 32/64-Lane SIMT Warp View.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import App
from window import Window, WK_CODEGEN, WK_DEBUG
from screen import CONT
from codegen import CG_ASM
from dap import DS_STOPPED
from dbgview import FrameRow
from dialog import D_NONE, D_GPU_LANE
from commands import CM_GPU_OCCUPANCY, CM_DEBUG_GPU_LANE
from gpu_occupancy import (
    gpu_arch_spec,
    compute_gpu_occupancy,
    simulate_32_banks,
    analyze_smem_bank_conflicts,
    parse_warp_lane_mask,
    format_warp_lane_strip,
    format_warp_watch_values,
)
from signals import own_pid
from util import env_or, run_system, write_file, str_bytes, bytes_to_str, to_str


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v30-p16-" + tag + "-" + String(own_pid())
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


def test_p16_01_sm_cu_occupancy_tables_and_cliffs() raises:
    """Exact hardware SM/CU occupancy calculation across NVIDIA Ampere/Ada/Hopper/Blackwell and AMD CDNA2/3."""
    var h100 = gpu_arch_spec("NVIDIA H100 80GB HBM3")
    assert_equal(h100.arch, "sm_90")
    assert_equal(h100.max_warps_per_sm, 64)

    # 32 regs/thread, 4 KB smem, 256 threads (8 warps) on H100 -> 64/64 warps = 100.0%
    var occ_full = compute_gpu_occupancy("sm_90", 32, 4096, 256)
    assert_equal(occ_full.occupancy_pct_x10, 1000)
    assert_equal(occ_full.active_warps, 64)

    # 65 regs/thread on H100 drops register-limited residency -> cliff hint recommends <=64 regs
    var occ_cliff = compute_gpu_occupancy("sm_90", 65, 4096, 256)
    assert_true(occ_cliff.occupancy_pct_x10 < 1000)
    assert_equal(occ_cliff.limiter, "registers")
    assert_true(occ_cliff.cliff_hint.find("64") >= 0, occ_cliff.cliff_hint)

    # Blackwell sm_100 / GB10 and AMD MI300X gfx942 (Wave64)
    var b200 = gpu_arch_spec("sm_100")
    assert_equal(b200.warp_size, 32)
    var mi300 = compute_gpu_occupancy("gfx942", 48, 8192, 256)
    assert_equal(mi300.arch, "gfx942")
    assert_equal(mi300.warps_per_block, 4)  # 256 / 64-lane wavefront
    assert_true(mi300.occupancy_pct_x10 > 0)


def test_p16_02_smem_32_bank_conflict_analyzer_and_app_cmd() raises:
    """Static 32-bank stride simulator + CM_GPU_OCCUPANCY report & clickable warning lines."""
    var b1 = simulate_32_banks(1, 4)
    assert_equal(b1.conflict_ways, 1)
    assert_false(b1.is_broadcast)

    var b2 = simulate_32_banks(2, 4)
    assert_equal(b2.conflict_ways, 2)

    var b32 = simulate_32_banks(32, 4)
    assert_equal(b32.conflict_ways, 32)

    var b0 = simulate_32_banks(0, 4)
    assert_true(b0.is_broadcast)
    assert_equal(b0.conflict_ways, 1)

    var d = _scratch("occ")
    try:
        var kpath = d + "/transpose_kernel.mojo"
        var ksrc = (
            "def transpose_tile(tid: Int):\n"
            "    var linear = smem[tid + 1]\n"
            "    var conflicted = smem[tid * 32]\n"
            "    var two_way = smem[2 * tid]\n"
        )
        assert_true(write_file(kpath, str_bytes(ksrc)))
        var sites = analyze_smem_bank_conflicts(ksrc)
        assert_equal(len(sites), 3)
        assert_equal(sites[0].conflict_ways, 1)
        assert_equal(sites[1].conflict_ways, 32)
        assert_equal(sites[2].conflict_ways, 2)

        var app = App()
        app.cwd = d
        app.gpu_item = "GPU H100 80GB"
        app.scr.resize(110, 34)
        app.open_path(kpath)
        app.exec(CM_GPU_OCCUPANCY)
        var mi = app.msg_index()
        assert_true(mi >= 0)
        var msg_txt = bytes_to_str(app.wins[mi].buf.to_bytes())
        assert_true(msg_txt.find("Theoretical Occupancy") >= 0)
        assert_true(msg_txt.find("32-way CONFLICT") >= 0)
        assert_true(msg_txt.find("2-way CONFLICT") >= 0)
        assert_true(len(app.errs) >= 2)
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_p16_03_codegen_header_and_kernel_badge_occupancy() raises:
    """Codegen inspector header and GPU kernel badges include theoretical occupancy % when host GPU is known."""
    var d = _scratch("cgocc")
    try:
        var src_p = d + "/gemm.mojo"
        var ptx_p = d + "/gemm.ptx"
        assert_true(write_file(src_p, str_bytes("def gemm_kernel():\n    pass\n")))
        var ptx = (
            ".version 8.0\n"
            ".target sm_90\n"
            ".visible .entry gemm_kernel() {\n"
            "    .reg .f32 %f<32>;\n"
            "    .shared .align 16 .b8 smem[4096];\n"
            "    // gemm.mojo:2\n"
            "    fma.rn.f32 %f1, %f2, %f3, %f4;\n"
            "    ret;\n"
            "}\n"
        )
        assert_true(write_file(ptx_p, str_bytes(ptx)))
        var app = App()
        app.cwd = d
        app.gpu_item = "GPU H100"
        app.scr.resize(120, 32)
        app.open_path(src_p)
        var cg_win = Window(WK_CODEGEN, "Codegen: gemm.mojo", "", 60, 1, 60, 28, app.free_number())
        app.wins.append(cg_win^)
        app.codegen_mode = CG_ASM
        app.codegen_path = src_p
        app.codegen_out_file = ptx_p
        app.finish_codegen(0)

        var ci = app.codegen_index()
        assert_true(ci >= 0)
        var cg_hdr = to_str(app.wins[ci].buf.line(0))
        assert_true(cg_hdr.find("Occupancy:") >= 0, cg_hdr)

        var ei = app.find_editor(src_p)
        assert_true(ei >= 0 and len(app.wins[ei].bench_badges) >= 1)
        assert_true(app.wins[ei].bench_badges[0].find("% occ") >= 0, app.wins[ei].bench_badges[0])
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_p16_04_debugger_warp_lane_strip_and_cross_lane_watches() raises:
    """32-lane / 64-lane SIMT active-predicate mask strip and cross-lane scalar watch comparison in WK_DEBUG."""
    var parsed32 = parse_warp_lane_mask("0x0000ffff", 32)
    assert_equal(parsed32[1], 32)
    var strip = format_warp_lane_strip(parsed32[0], 32, 3)
    assert_true(strip.find("Warp32 [16/32 50%]") >= 0, strip)
    assert_true(strip.find("▣") >= 0 and strip.find("□") >= 0)
    assert_true(strip.find("SIMT divergence") >= 0)

    var vals = List[String]()
    vals.append("1.0")
    vals.append("NaN")
    vals.append("1.0")
    var wline = format_warp_watch_values("acc", vals, 0)
    assert_true(wline.find("NaN/Inf at L1") >= 0, wline)

    var app = App()
    app.scr.resize(110, 32)
    app.dbg.state = DS_STOPPED
    app.dview.frames.append(FrameRow(1, "gemm_kernel", "gemm.mojo", 12))
    app.debugwin_toggle()
    app.exec(CM_DEBUG_GPU_LANE)
    assert_equal(app.dlg.kind, D_GPU_LANE)
    app.dlg.kind = D_NONE
    app.gpu_lane_apply("0,0,0", "5,0,0", "0x00ff00ff")
    app.dview.set_warp_watch("acc", vals)
    app.debugwin_show()
    app.draw()
    var scr = _screen_text(app)
    assert_true(scr.find("SIMT Warp Lanes") >= 0, scr)
    assert_true(scr.find("Warp32 [16/32 50%]") >= 0, scr)
    assert_true(scr.find("NaN/Inf at L1") >= 0, scr)


def main() raises:
    var suite = TestSuite()
    suite.test[test_p16_01_sm_cu_occupancy_tables_and_cliffs]()
    suite.test[test_p16_02_smem_32_bank_conflict_analyzer_and_app_cmd]()
    suite.test[test_p16_03_codegen_header_and_kernel_badge_occupancy]()
    suite.test[test_p16_04_debugger_warp_lane_strip_and_cross_lane_watches]()
    suite^.run()
