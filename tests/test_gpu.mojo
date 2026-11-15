"""Tests for GPU awareness, part a (P11-10a): reading nvidia-smi's and rocm-smi's answers
(also unified memory, several GPUs, a failing driver, none), the lines for --caps and
the status line, and the setting that asks once in the background and shows it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from gpuinfo import *
from codegen import analyze_codegen, format_codegen_header, CG_ASM, CG_LLVM
from term import wait_readable
from app import *
from appstate import App
from commands import CM_GPU_STATUS, CM_GPU_WIN, build_registry
from config import load_settings, read_text
from signals import own_pid
from util import env_or, run_system, to_str


def test_reading_the_answers() raises:
    var gb10 = parse_gpus("nvidia\nNVIDIA GB10, [N/A], 615.71.09\n")   # (this machine: unified memory)
    assert_equal(len(gb10), 1)
    assert_equal(gb10[0].name, "NVIDIA GB10")
    assert_equal(gb10[0].memory, "")
    assert_equal(gb10[0].driver, "615.71.09")
    assert_equal(gpu_line(gb10), "NVIDIA GB10, driver 615.71.09")
    assert_equal(gpu_short(gb10), "GPU GB10")
    var h = parse_gpus("nvidia\nNVIDIA H100 80GB HBM3, 81559 MiB, 570.86.15\nNVIDIA H100 80GB HBM3, 81559 MiB, 570.86.15\n")
    assert_equal(len(h), 2)
    assert_equal(gpu_line(h), "NVIDIA H100 80GB HBM3, 81559 MiB, driver 570.86.15  (the first of 2)")
    assert_equal(gpu_short(h), "GPU H100 80GB HBM3 ×2")
    # a driver that does not answer: no GPU, not a GPU called "NVIDIA-SMI has failed..."
    assert_equal(len(parse_gpus("nvidia\nNVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.\n")), 0)
    var amd = parse_gpus("rocm\ndevice,Card Series,Card Model,Card Vendor\ncard0,AMD Instinct MI300X,0x74a1,Advanced Micro Devices\n")
    assert_equal(len(amd), 1)
    assert_equal(amd[0].name, "AMD Instinct MI300X")
    assert_equal(gpu_short(amd), "GPU Instinct MI300X")
    var none = parse_gpus("none\n")
    assert_equal(len(none), 0)
    assert_true(gpu_line(none).startswith("none found"))
    assert_equal(gpu_short(none), "")
    assert_equal(len(parse_gpus("")), 0)


def wait_gpu(mut app: App) raises:
    var guard = 0
    while app.gpu_fd >= 0 and guard < 200:
        guard += 1
        _ = wait_readable(app.gpu_fds(), 50)
        app.gpu_tick()


def test_the_status_item() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-gpu-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    assert_false(load_settings("", "").gpu_status)
    assert_true(load_settings("[ui]\ngpu_status = true\n", "").gpu_status)
    var app = App()
    app.scr.resize(120, 30)
    app.config_path = d + "/config.toml"
    app.gpu_query = "sleep 0.2; echo nvidia; echo 'NVIDIA H100 80GB HBM3, 81559 MiB, 570.86.15'"
    # off: nothing is asked
    app.gpu_start()
    assert_equal(app.gpu_fd, -1)
    assert_equal(app.gpu_status_text(), "")
    # on: asked in the background - the IDE does not wait for it
    assert_true(build_registry().index_of_name("options.gpuStatus") >= 0)
    app.exec(CM_GPU_STATUS)
    assert_true(app.gpu_fd >= 0)
    assert_equal(app.gpu_status_text(), "")              # (not known yet)
    wait_gpu(app)
    assert_equal(app.gpu_fd, -1)
    assert_equal(app.gpu_status_text(), "GPU H100 80GB HBM3  ")
    assert_true(load_settings(read_text(d + "/config.toml"), "").gpu_status)
    app.draw()
    var bottom = String("")
    for x in range(app.scr.w):
        bottom += chr(app.scr.ch[(app.scr.h - 1) * app.scr.w + x])
    assert_true(bottom.find("GPU H100 80GB HBM3") >= 0, bottom)
    assert_true(CM_GPU_STATUS in app.checked())
    # asked once only
    app.gpu_start()
    assert_equal(app.gpu_fd, -1)
    # off: gone from the status line
    app.exec(CM_GPU_STATUS)
    assert_equal(app.gpu_status_text(), "")
    assert_false(load_settings(read_text(d + "/config.toml"), "").gpu_status)
    # no GPU: no item
    var bare = App()
    bare.gpu_query = "echo none"
    bare.gpu_status_on = True
    bare.gpu_start()
    wait_gpu(bare)
    assert_equal(bare.gpu_status_text(), "")
    _ = run_system("rm -rf '" + d + "'")


def test_telemetry_monitor_and_codegen_inspector() raises:
    var parsed = parse_gpu_samples(
        "nvidia\n0, NVIDIA H100 80GB HBM3, 82, 40960, 81559, 64, 345.2\n__PROCS__\n0000:01:00.0, 4321, mojo, 2048\n"
    )
    assert_equal(len(parsed[0]), 1)
    assert_equal(parsed[0][0].util_pct, 82)
    assert_equal(parsed[0][0].mem_used_mib, 40960)
    assert_equal(parsed[0][0].temp_c, 64)
    assert_equal(len(parsed[1]), 1)
    var hist = List[List[Int]]()
    hist.append([20, 50, 82])
    var mon = "\n".join(format_gpu_monitor(parsed[0], parsed[1], hist))
    assert_true(mon.find("82%") >= 0 and mon.find("40960 / 81559 MiB") >= 0 and mon.find("PID 4321") >= 0, mon)
    # Unit-suffixed nvidia-smi telemetry ("43008 MiB", "61 C", "542.4 W", "2048 MiB") parses cleanly without "W W" or "MiB MiB"
    var parsed_units = parse_gpu_samples(
        "nvidia\n0, NVIDIA RTX PRO 6000, 91 %, 43008 MiB, 97887 MiB, 61 C, 542.4 W\n__PROCS__\n0000:01:00.0, 7788, tmide_bench, 2048 MiB\n"
    )
    assert_equal(len(parsed_units[0]), 1)
    assert_equal(parsed_units[0][0].util_pct, 91)
    assert_equal(parsed_units[0][0].mem_used_mib, 43008)
    assert_equal(parsed_units[0][0].mem_total_mib, 97887)
    assert_equal(parsed_units[0][0].temp_c, 61)
    var mon_units = "\n".join(format_gpu_monitor(parsed_units[0], parsed_units[1], hist))
    assert_true(mon_units.find("43008 / 97887 MiB") >= 0, mon_units)
    assert_true(mon_units.find("Power 542.4 W") >= 0 and mon_units.find("W W") < 0, mon_units)
    assert_true(mon_units.find("2048 MiB") >= 0 and mon_units.find("MiB MiB") < 0, mon_units)
    var app = App()
    app.scr.resize(120, 32)
    app.gpu_mon_query = "echo nvidia; echo '0, NVIDIA GB10, 45, [N/A], [N/A], 52, 28.5'; echo __PROCS__"
    app.exec(CM_GPU_WIN)
    assert_true(app.gpuwin_index() >= 0)
    var guard = 0
    while app.gpu_mon_fd >= 0 and guard < 100:
        guard += 1
        _ = wait_readable(app.gpu_fds(), 30)
        app.gpu_tick()
    var gi = app.gpuwin_index()
    var gtxt = to_str(app.wins[gi].buf.all_text())
    assert_true(gtxt.find("NVIDIA GB10") >= 0 and gtxt.find("45%") >= 0, gtxt)
    var asm_s = analyze_codegen("kernel:\n\t.cfi_startproc\n\tvfmadd213ps %zmm0, %zmm1, %zmm2\n\tvmovups %zmm0, 64(%rsp)\n\tretq\n", CG_ASM)
    assert_equal(asm_s.simd_ops, 1)
    assert_equal(asm_s.spill_ops, 1)
    var hdr = "\n".join(format_codegen_header("k.mojo", CG_ASM, asm_s))
    assert_true(hdr.find("[SIMD]") >= 0 and hdr.find("[SPILL]") >= 0, hdr)
    var ir_s = analyze_codegen("define void @k() {\n  %0 = fadd <8 x float> %a, %b\n  ret void\n}\n", CG_LLVM)
    assert_equal(ir_s.simd_ops, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
