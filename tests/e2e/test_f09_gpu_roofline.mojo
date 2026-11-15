"""E2E Test Suite for Feature #9: Single-Kernel GPU Roofline Deep Dive.
Covers Tier 1 (5 Happy Path tests), Tier 2 (5 Boundary/Corner tests), and App integration.
"""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from std.math import abs
from gpuinfo import (
    classify_kernel_bound, parse_ncu_csv_output, parse_ncu_source_stall_lines,
    filter_valid_source_stall_lines, check_profiler_permissions,
    build_roofline_cli_command, format_roofline_report,
)
from app import *
from appstate import App, JOB_ROOFLINE
from util import str_bytes, to_str
from harness import ScratchDir, make_test_app


# ---------------------------------------------------------------------------
# Tier 1 Tests: Happy Path
# ---------------------------------------------------------------------------

def test_tier1_f09_ncu_csv_metric_extraction() raises:
    """Tier 1: Extract SM compute, DRAM bandwidth, occupancy, and registers per thread."""
    var csv_text = (
        "\"ID\",\"Kernel Name\",\"Metric Name\",\"Metric Value\"\n"
        "\"0\",\"matmul_tiled_kernel\",\"sm__throughput.avg.pct_of_peak_sustained_elapsed\",\"82.4\"\n"
        "\"0\",\"matmul_tiled_kernel\",\"gpu__dram_throughput.avg.pct_of_peak_sustained_elapsed\",\"41.2\"\n"
        "\"0\",\"matmul_tiled_kernel\",\"sm__warps_active.avg.pct_of_peak_sustained_active\",\"68.0\"\n"
        "\"0\",\"matmul_tiled_kernel\",\"launch__registers_per_thread\",\"32\"\n"
    )
    var items = parse_ncu_csv_output(csv_text)
    assert_equal(len(items), 1)
    var k = items[0].copy()
    assert_equal(k.kernel_name, "matmul_tiled_kernel")
    assert_true(abs(k.sm_compute_pct - 82.4) < 0.01)
    assert_true(abs(k.dram_bw_pct - 41.2) < 0.01)
    assert_true(abs(k.occupancy_pct - 68.0) < 0.01)
    assert_equal(k.registers_per_thread, 32)


def test_tier1_f09_ncu_warp_stall_breakdown() raises:
    """Tier 1: Parse and classify warp stall reasons."""
    var csv_text = (
        "\"ID\",\"Kernel Name\",\"Metric Name\",\"Metric Value\"\n"
        "\"0\",\"flash_attn_kernel\",\"smsp__warp_issue_stalled_long_scoreboard\",\"45.0\"\n"
        "\"0\",\"flash_attn_kernel\",\"smsp__warp_issue_stalled_wait\",\"25.0\"\n"
        "\"0\",\"flash_attn_kernel\",\"smsp__warp_issue_stalled_barrier\",\"15.0\"\n"
    )
    var items = parse_ncu_csv_output(csv_text)
    assert_equal(len(items), 1)
    var stalls = items[0].stalls.copy()
    assert_equal(len(stalls), 3)
    assert_equal(stalls[0].reason, "Long Scoreboard")
    assert_true(abs(stalls[0].pct - 45.0) < 0.01)
    assert_equal(stalls[1].reason, "Wait")
    assert_equal(stalls[2].reason, "Barrier")


def test_tier1_f09_roofline_bound_classification() raises:
    """Tier 1: Roofline classification into Compute-Bound, Memory-Bound, and Latency-Bound."""
    assert_equal(classify_kernel_bound(88.0, 30.0, 75.0), "Compute-Bound")
    assert_equal(classify_kernel_bound(25.0, 92.0, 60.0), "Memory-Bound")
    assert_equal(classify_kernel_bound(15.0, 18.0, 22.0), "Latency-Bound")


def test_tier1_f09_source_level_stall_attribution() raises:
    """Tier 1: Attributing stall counts and reasons to specific source lines."""
    var source_csv = (
        "Source Line, Stall Reason, Stall Count\n"
        "45, Long Scoreboard, 120.0\n"
        "50, Wait, 20.0\n"
    )
    var lines = parse_ncu_source_stall_lines(source_csv)
    assert_equal(len(lines), 2)
    assert_equal(lines[0][0], 45)
    assert_equal(lines[0][1], "Long Scoreboard")
    assert_true(abs(lines[0][2] - 120.0) < 0.1)

    assert_equal(lines[1][0], 50)
    assert_equal(lines[1][1], "Wait")
    assert_true(abs(lines[1][2] - 20.0) < 0.1)


def test_tier1_f09_build_deepdive_command_nvidia() raises:
    """Tier 1: Command generation for NVIDIA ncu profiling with -O3 and line tables."""
    var cmd = build_roofline_cli_command("ncu", "mojo", "gemm.mojo", "build/gemm", "/tmp/prof.csv")
    assert_true(cmd.find("mojo build -O3 --debug-level=line-tables 'gemm.mojo' -o 'build/gemm'") >= 0)
    assert_true(cmd.find("ncu --csv --set basic --page raw 'build/gemm' > '/tmp/prof.csv'") >= 0)


# ---------------------------------------------------------------------------
# Tier 2 Tests: Boundary & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f09_ncu_unified_memory_missing_dram_counter() raises:
    """Tier 2: Unified memory architecture where DRAM bandwidth is reported as N/A."""
    var csv_text = (
        "\"ID\",\"Kernel Name\",\"Metric Name\",\"Metric Value\"\n"
        "\"0\",\"jetson_kernel\",\"sm__throughput.avg.pct_of_peak_sustained_elapsed\",\"75.0\"\n"
        "\"0\",\"jetson_kernel\",\"gpu__dram_throughput.avg.pct_of_peak_sustained_elapsed\",\"N/A\"\n"
        "\"0\",\"jetson_kernel\",\"sm__warps_active.avg.pct_of_peak_sustained_active\",\"50.0\"\n"
    )
    var items = parse_ncu_csv_output(csv_text)
    assert_equal(len(items), 1)
    assert_equal(items[0].dram_bw_pct, -1.0)
    assert_equal(items[0].bound_classification, "Compute-Bound")


def test_tier2_f09_rocprofv3_csv_parsing() raises:
    """Tier 2: AMD rocprofv3 CSV format parsing."""
    var roc_csv = (
        "\"KernelName\",\"VALUUtilization\",\"VRAMBandwidth\",\"WavefrontOccupancy\",\"VGPRs\"\n"
        "\"matmul_gfx942\",\"78.5\",\"52.3\",\"64.0\",\"48\"\n"
    )
    var items = parse_ncu_csv_output(roc_csv)
    assert_equal(len(items), 1)
    var k = items[0].copy()
    assert_equal(k.kernel_name, "matmul_gfx942")
    assert_true(abs(k.sm_compute_pct - 78.5) < 0.01)
    assert_true(abs(k.dram_bw_pct - 52.3) < 0.01)
    assert_true(abs(k.occupancy_pct - 64.0) < 0.01)
    assert_equal(k.registers_per_thread, 48)
    assert_equal(k.bound_classification, "Compute-Bound")


def test_tier2_f09_profiler_permission_denied_error() raises:
    """Tier 2: Detects missing GPU counter permissions and gives modprobe remediation."""
    var err = "ERR_NVGPUCTRPERM: Permission denied to access GPU performance counters.\n"
    var msg = check_profiler_permissions(err)
    assert_true(msg.byte_length() > 0)
    assert_true(msg.find("NVreg_RestrictProfilingToAdminUsers=0") >= 0)


def test_tier2_f09_multiple_kernels_in_single_profile() raises:
    """Tier 2: Profile containing metrics for multiple distinct kernels."""
    var csv_text = (
        "\"ID\",\"Kernel Name\",\"Metric Name\",\"Metric Value\"\n"
        "\"0\",\"fused_attention\",\"sm__throughput.avg.pct_of_peak_sustained_elapsed\",\"85.0\"\n"
        "\"0\",\"fused_attention\",\"gpu__dram_throughput.avg.pct_of_peak_sustained_elapsed\",\"30.0\"\n"
        "\"1\",\"layernorm\",\"sm__throughput.avg.pct_of_peak_sustained_elapsed\",\"20.0\"\n"
        "\"1\",\"layernorm\",\"gpu__dram_throughput.avg.pct_of_peak_sustained_elapsed\",\"80.0\"\n"
        "\"2\",\"projection\",\"sm__throughput.avg.pct_of_peak_sustained_elapsed\",\"15.0\"\n"
        "\"2\",\"projection\",\"gpu__dram_throughput.avg.pct_of_peak_sustained_elapsed\",\"15.0\"\n"
    )
    var items = parse_ncu_csv_output(csv_text)
    assert_equal(len(items), 3)
    assert_equal(items[0].kernel_name, "fused_attention")
    assert_equal(items[0].bound_classification, "Compute-Bound")

    assert_equal(items[1].kernel_name, "layernorm")
    assert_equal(items[1].bound_classification, "Memory-Bound")

    assert_equal(items[2].kernel_name, "projection")
    assert_equal(items[2].bound_classification, "Latency-Bound")


def test_tier2_f09_source_lines_beyond_buffer_count() raises:
    """Tier 2: Out-of-range line numbers from inlined headers are filtered safely."""
    var raw_stalls = List[Tuple[Int, String, Float64]]()
    raw_stalls.append((10, "Wait", 50.0))
    raw_stalls.append((9999, "Barrier", 200.0))

    var filtered = filter_valid_source_stall_lines(raw_stalls, 50)
    assert_equal(len(filtered), 1)
    assert_equal(filtered[0][0], 10)


def test_app_f09_finish_gpu_roofline_and_permissions() raises:
    """App integration: format_roofline_report and finish_gpu_roofline report & ERR_NVGPUCTRPERM."""
    var s = ScratchDir.create("f09_app")
    var src_path = s.path + "/gemm.mojo"
    s.write("gemm.mojo", "def gemm():\n    pass\n    pass\n    pass\n")
    var csv_path = s.path + "/prof.csv"
    s.write(
        "prof.csv",
        "\"ID\",\"Kernel Name\",\"Metric Name\",\"Metric Value\"\n"
        "\"0\",\"gemm_k\",\"sm__throughput.avg.pct_of_peak_sustained_elapsed\",\"84.0\"\n"
        "\"0\",\"gemm_k\",\"gpu__dram_throughput.avg.pct_of_peak_sustained_elapsed\",\"35.0\"\n"
        "\"0\",\"gemm_k\",\"sm__warps_active.avg.pct_of_peak_sustained_active\",\"70.0\"\n"
        "\"0\",\"gemm_k\",\"launch__registers_per_thread\",\"32\"\n",
    )
    s.write("prof.csv.src", "Source Line, Stall Reason, Stall Count\n2, Long Scoreboard, 90.0\n999, Wait, 10.0\n")

    var app = make_test_app(s)
    app.open_path(src_path)
    app.job.kind = JOB_ROOFLINE
    app.job.path = src_path
    app.job.exe = csv_path
    app.finish_gpu_roofline(0)

    var mi = app.msg_index()
    assert_true(mi >= 0)
    var msg_txt = to_str(app.wins[mi].buf.all_text())
    assert_true(msg_txt.find("Compute-Bound") >= 0)
    assert_true(msg_txt.find("gemm.mojo:2:1: stall Long Scoreboard") >= 0)

    # Also verify format_roofline_report directly and permission remediation
    var parsed = parse_ncu_csv_output(
        "\"ID\",\"Kernel Name\",\"Metric Name\",\"Metric Value\"\n"
        "\"0\",\"k1\",\"sm__throughput.avg.pct_of_peak_sustained_elapsed\",\"90.0\"\n"
    )
    var rep = "\n".join(format_roofline_report(parsed[0]))
    assert_true(rep.find("Kernel Roofline: k1") >= 0)

    app.job.kind = JOB_ROOFLINE
    app.job.path = src_path
    app.job.exe = ""
    app.job.data = str_bytes("ERR_NVGPUCTRPERM: Permission denied\n")
    app.finish_gpu_roofline(256)
    assert_true(app.status.find("NVreg_RestrictProfilingToAdminUsers=0") >= 0)

    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
