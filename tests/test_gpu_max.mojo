"""Tests for GPU kernel profiler summary parsing, DAP GPU thread/block focus commands, and MAX helpers."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from gpuinfo import parse_kernel_profile
from dbgview import format_gpu_focus_command, parse_xyz_triple
from project import detect_max_project, build_max_commands


def test_parse_nsys_and_rocprof_and_sanitizer() raises:
    var nsys_out = (
        "Generating 'cuda_gpu_kern_sum' stats report\n\n"
        " Time (%)  Total Time (ns)  Instances    Avg (ns)     Med (ns)    Min (ns)   Max (ns)   StdDev (ns)            Name\n"
        " --------  ---------------  ---------  -----------  -----------  ---------  ---------  -----------  --------------------------\n"
        "     75.4        1,508,000         50     30,160.0     30,000.0     29,500     32,000        400.0  matmul_tiled_f16_kernel\n"
        "     24.6          492,000         50      9,840.0      9,800.0      9,600     10,200        120.0  softmax_reduce_kernel\n\n"
    )
    var s1 = parse_kernel_profile(nsys_out)
    assert_true(len(s1) >= 3)
    assert_true(s1[1].find("75%") >= 0)
    assert_true(s1[1].find("matmul_tiled_f16_kernel") >= 0)
    assert_true(s1[2].find("softmax_reduce_kernel") >= 0)

    var roc_out = (
        "\"KernelName\",\"Calls\",\"TotalDurationNs\",\"AverageNs\",\"Percentage\"\n"
        "\"flash_attn_fwd\",32,960000,30000,82.0\n"
    )
    var s2 = parse_kernel_profile(roc_out)
    assert_true(len(s2) >= 2)
    assert_true(s2[1].find("82%") >= 0)
    assert_true(s2[1].find("flash_attn_fwd") >= 0)

    var san_out = (
        "========= COMPUTE-SANITIZER\n"
        "========= ERROR SUMMARY: 0 errors\n"
    )
    var s3 = parse_kernel_profile(san_out)
    assert_true(len(s3) >= 2)
    assert_true(s3[1].find("ERROR SUMMARY: 0 errors") >= 0)


def test_gpu_focus_commands() raises:
    var c = parse_xyz_triple("2, 4, 1")
    assert_equal(c[0], 2)
    assert_equal(c[1], 4)
    assert_equal(c[2], 1)

    assert_equal(
        format_gpu_focus_command("cuda-gdb --interpreter=dap", "1,2,0", "16,4,0"),
        "cuda block (1,2,0) thread (16,4,0)",
    )
    assert_equal(format_gpu_focus_command("rocgdb", "0,0,0", "31"), "lane 31")
    assert_equal(format_gpu_focus_command("mojo-lldb-dap", "0,0,0", "3"), "`thread select 3")


def test_max_project_detection_and_commands() raises:
    assert_true(detect_max_project("[dependencies]\nmax = \"*\"\n", ""))
    assert_true(detect_max_project("", "from max.graph import Graph\n"))
    assert_false(detect_max_project("[dependencies]\npython = \"3.12\"\n", "def main():\n    pass\n"))

    var built = build_max_commands("Qwen/Qwen2.5-7B-Instruct", "/workspace/architectures")
    assert_equal(len(built[0]), 4)
    assert_true(built[1][0].find("max serve --model-path Qwen/Qwen2.5-7B-Instruct --custom-architectures /workspace/architectures") >= 0)
    assert_true(built[1][2].find("max benchmark") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
