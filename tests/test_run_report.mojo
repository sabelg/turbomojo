"""Tests for the line after Ctrl-F9 (P11-10b): which programs use the GPU, which GPU a
program gets (CUDA_VISIBLE_DEVICES / HIP_VISIBLE_DEVICES), the time, and the line in the
Message window when a run in the Run window ends - with a fake `mojo` on a real pty."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from runreport import *
from gpuinfo import parse_gpus
from termsession import TS_RUN
from term import wait_readable
from app import *
from appstate import App
from commands import CM_RUN
from signals import own_pid
from util import env_or, run_system, to_str

comptime MS = 1000000


def test_which_programs_use_the_gpu() raises:
    assert_true(uses_gpu("from gpu import thread_idx\ndef main(): pass\n"))
    assert_true(uses_gpu("from gpu.host import DeviceContext\n"))
    assert_true(uses_gpu("import gpu\n"))
    assert_true(uses_gpu("from max.tensor import Tensor\n"))
    assert_true(uses_gpu("from std.gpu import thread_idx\n"))
    assert_true(uses_gpu("from layout import TileTensor\n"))
    assert_true(uses_gpu("from std.sys import has_accelerator\n"))
    assert_true(uses_gpu("def main():\n    var ctx = DeviceContext()\n"))
    assert_false(uses_gpu("def main():\n    print(\"hello\")\n"))
    assert_false(uses_gpu("# from gpu import thread_idx, and a DeviceContext, later\ndef main(): pass\n"))
    assert_false(uses_gpu("from gpuinfo import x\nimport maxheap\n"))


def test_which_gpu_and_how_long() raises:
    assert_equal(visible_gpu_index("", ""), 0)
    assert_equal(visible_gpu_index("1", ""), 1)
    assert_equal(visible_gpu_index(" 3,0 ", ""), 3)
    assert_equal(visible_gpu_index("", "2"), 2)
    assert_equal(visible_gpu_index("1", "2"), 1)
    assert_equal(visible_gpu_index("-1", ""), -1)
    assert_equal(visible_gpu_index("GPU-8f1c2a", ""), -1)
    assert_equal(visible_gpu_index(",", ""), -1)
    var g = parse_gpus("nvidia\nNVIDIA A100, 40960 MiB, 570\nNVIDIA H100, 81559 MiB, 570\n")
    assert_equal(run_gpu_name(g, 0), "NVIDIA A100")
    assert_equal(run_gpu_name(g, 1), "NVIDIA H100")
    assert_equal(run_gpu_name(g, 2), "")
    assert_equal(run_gpu_name(g, -1), "")
    assert_equal(duration_text(430 * MS), "430 ms")
    assert_equal(duration_text(2345 * MS), "2.3 s")
    assert_equal(duration_text(72000 * MS), "1 min 12 s")
    assert_equal(run_summary("mojo run a.mojo", 0, 2345 * MS, False, ""), "mojo run a.mojo: ended with status 0 after 2.3 s (compiling included)")
    assert_equal(run_summary("mojo run a.mojo", 1, 500 * MS, True, "NVIDIA GB10"), "mojo run a.mojo: ended with status 1 after 500 ms (compiling included), on the GPU NVIDIA GB10")
    assert_true(run_summary("x", 0, 0, True, "").find("which one is not known") > 0)


def message_text(app: App) -> String:
    var mi = app.msg_index()
    if mi < 0:
        return ""
    return to_str(app.wins[mi].buf.all_text())


def run_and_wait(mut app: App) raises:
    app.exec(CM_RUN)
    var deadline = Int(perf_counter_ns()) + 8000 * MS
    while app.run_t0_ns != 0 and Int(perf_counter_ns()) < deadline:
        var fds = app.term_fds()
        for f in app.gpu_fds():
            fds.append(f)
        _ = wait_readable(fds, 20)
        app.term_tick()
        app.gpu_tick()
    assert_equal(app.run_t0_ns, 0, "the run did not end")


def test_the_line_after_a_run() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-runrep-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.compiler = "sh " + d + "/fake-mojo.sh"      # stands for `mojo`: `run file` runs a script
    with open(d + "/fake-mojo.sh", "w") as f:
        f.write("sleep 0.3; echo ran; exit 3\n")
    app.gpu_query = "echo nvidia; echo 'NVIDIA GB10, [N/A], 615.71.09'"
    # a program without the GPU: status and time; the GPU is not asked
    with open(d + "/plain.mojo", "w") as f:
        f.write("def main():\n    print(1)\n")
    app.open_path(d + "/plain.mojo")
    run_and_wait(app)
    var m = message_text(app)
    assert_true(m.find("mojo run plain.mojo: ended with status 3 after ") >= 0, m)
    assert_true(m.find(" ms (compiling included)") > 0, m)              # 300 ms and a little
    assert_equal(m.find("GPU"), -1)
    assert_false(app.gpu_asked)
    assert_true(app.status.find("ended with status 3") > 0, app.status)
    # a GPU program: the GPU it ran on (asked meanwhile, in the background)
    with open(d + "/kernel.mojo", "w") as f:
        f.write("from gpu.host import DeviceContext\ndef main():\n    pass\n")
    app.open_path(d + "/kernel.mojo")
    run_and_wait(app)
    m = message_text(app)
    assert_true(m.find("mojo run kernel.mojo: ended with status 3") >= 0, m)
    assert_true(m.find(", on the GPU NVIDIA GB10") > 0, m)
    assert_equal(m.find("plain.mojo"), -1)                              # the new run's line only
    assert_equal(app.gpu_status_text(), "")                             # (the status item stays off)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
