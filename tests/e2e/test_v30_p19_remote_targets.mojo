"""E2E Test Suite for v3.0 Phase 19 (v2.10):
Remote Compute Targets (`[target.<name>]` SSH, Docker, Apptainer, Slurm), Status Pill,
Transparent `with_env` Dispatch & Path Remapping, and Multi-GPU / Slurm / Container Topology in `WK_GPU`.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from std.time import perf_counter_ns
from app import App
from screen import CONT
from commands import CM_SELECT_TARGET, CM_GPU_WIN
from dialog import D_SELECT_TARGET
from remote_target import (
    parse_compute_targets,
    wrap_target_command,
    remap_remote_output_paths,
    target_status_pill,
)
from gpuinfo import (
    parse_nvidia_topo_matrix,
    parse_squeue_rows,
    parse_cgroup_memory_slice,
    format_cluster_topology_section,
)
from signals import own_pid
from util import env_or, run_system, write_file, str_bytes, bytes_to_str, to_str


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v30-p19-" + tag + "-" + String(own_pid())
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


def test_p19_01_target_toml_wrappers_picker_pill_and_path_remap() raises:
    """Parse SSH/Docker/Apptainer/Slurm targets, switch via CM_SELECT_TARGET, render status pill,
    wrap `with_env`, and remap remote compiler diagnostics back to local files."""
    var d = _scratch("targets")
    try:
        var cfg = (
            '[target]\nactive = "h100-ssh"\n\n'
            '[target.h100-ssh]\nkind = "ssh"\nhost = "10.0.0.42"\nuser = "ubuntu"\nport = 2222\nremote_dir = "/remote/work/proj"\n\n'
            '[target.max-docker]\nkind = "docker"\nimage = "modular/max:latest"\nremote_dir = "/workspace"\ngpus = 2\n\n'
            '[target.hpc-sif]\nkind = "apptainer"\nimage = "/opt/mojo_gpu.sif"\nremote_dir = "/work"\n\n'
            '[target.cluster-a100]\nkind = "slurm"\npartition = "gpu-a100"\ngpus = 4\nremote_dir = "/scratch/proj"\n'
        )
        assert_true(write_file(d + "/.turbomojo.toml", str_bytes(cfg)))
        var src_p = d + "/kernel.mojo"
        assert_true(write_file(src_p, str_bytes("def main():\n    print(1)\n")))

        var parsed = parse_compute_targets(cfg)
        assert_equal(parsed[0], "h100-ssh")
        assert_equal(len(parsed[1]), 5)  # local + 4 configured targets

        var app = App()
        app.cwd = d
        app.scr.resize(120, 30)
        app.load_config()
        app.open_path(src_p)
        assert_equal(app.active_target_name, "h100-ssh")

        # Verify status bar renders `[target:ssh:...]` pill
        app.status_until = 0
        app.draw()
        var scr = _screen_text(app)
        assert_true(scr.find("[target:ssh:") >= 0, scr)

        # Verify `with_env` transparently wraps command with rsync + ssh!
        var wrapped_ssh = app.with_env(src_p, "mojo build " + src_p)
        assert_true(wrapped_ssh.find("rsync") >= 0, wrapped_ssh)
        assert_true(wrapped_ssh.find("2222") >= 0, wrapped_ssh)
        assert_true(wrapped_ssh.find("/remote/work/proj/kernel.mojo") >= 0, wrapped_ssh)

        # Verify remote error path remapping in `fill_messages` maps `/remote/work/proj/kernel.mojo:2:5:` -> `d/kernel.mojo`
        var rem_diag = "/remote/work/proj/kernel.mojo:2:5: error: unknown symbol 'bad'\n"
        _ = app.fill_messages("Remote Build", str_bytes(rem_diag), "Failed")
        assert_equal(len(app.errs), 1)
        assert_equal(app.errs[0].path, src_p)
        assert_equal(app.errs[0].row, 2)

        # Open target picker (`CM_SELECT_TARGET`) and switch to `cluster-a100` (Slurm) & `max-docker`
        app.exec(CM_SELECT_TARGET)
        assert_equal(app.dlg.kind, D_SELECT_TARGET)
        app.select_target_apply("cluster-a100")
        var wrapped_slurm = app.with_env(src_p, "mojo run " + src_p)
        assert_true(wrapped_slurm.find("srun") >= 0 and wrapped_slurm.find("gpu-a100") >= 0, wrapped_slurm)
        assert_true(target_status_pill(app.active_compute_target()).find("[target:slurm:") >= 0)

        app.select_target_apply("max-docker")
        var wrapped_docker = app.with_env(src_p, "mojo build " + src_p)
        assert_true(wrapped_docker.find("docker run") >= 0 and wrapped_docker.find("modular/max:latest") >= 0, wrapped_docker)

        app.select_target_apply("hpc-sif")
        var wrapped_sif = wrap_target_command(app.active_compute_target(), d, "mojo run " + src_p, True)
        assert_true(wrapped_sif.find("apptainer exec --nv") >= 0, wrapped_sif)
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_p19_02_multi_gpu_nvlink_topology_slurm_queue_and_cgroup_in_wk_gpu() raises:
    """WK_GPU parses and displays NVLink/PCIe topology matrices, Slurm squeue jobs, and container RAM slices."""
    var topo_sample = (
        "\tGPU0\tGPU1\tGPU2\tGPU3\tCPU Affinity\n"
        "GPU0\t X \tNV18\tNV18\tPIX\t0-31\n"
        "GPU1\tNV18\t X \tPIX\tNV18\t0-31\n"
    )
    var topo_lines = parse_nvidia_topo_matrix(topo_sample)
    assert_true(len(topo_lines) >= 2)

    var sq_sample = (
        "     JOBID    PARTITION               NAME    STATE       TIME  NODES NODELIST(REASON)\n"
        "    984120     gpu-h100        mojo_train  RUNNING      14:22      2 dgx-node[01-02]\n"
        "    984125     gpu-h100         max_bench  PENDING       0:00      1 (Resources)\n"
    )
    var jobs = parse_squeue_rows(sq_sample)
    assert_equal(len(jobs), 2)
    assert_equal(jobs[0].name, "mojo_train")

    # 16 GiB / 64 GiB cgroup slice
    var cg_str = parse_cgroup_memory_slice("17179869184", "68719476736")
    assert_true(cg_str.find("16.0") >= 0 and cg_str.find("64.0") >= 0, cg_str)

    var sec = format_cluster_topology_section(topo_sample, sq_sample, "17179869184", "68719476736")
    var joined = "\n".join(sec)
    assert_true(joined.find("NV18") >= 0)
    assert_true(joined.find("mojo_train") >= 0)
    assert_true(joined.find("64.0 GiB") >= 0)

    # Verify live WK_GPU polling renders both GPU samples and cluster topology section
    var app = App()
    app.scr.resize(120, 36)
    app.gpu_mon_query = (
        "printf 'nvidia\\n0, NVIDIA H100, 92, 40960, 81559, 64, 520.0\\n__PROCS__\\n"
        "__TOPO__\\n\tGPU0\tGPU1\\nGPU0\t X \tNV18\\nGPU1\tNV18\t X \\n"
        "__SQUEUE__\\nJOBID PARTITION NAME STATE TIME NODES NODELIST\\n5501 gpu mojo_job RUNNING 02:15 1 node01\\n"
        "__CGROUP__\\n8589934592\\n34359738368\\n'"
    )
    app.exec(CM_GPU_WIN)
    var t0 = Int(perf_counter_ns())
    while app.gpu_mon_fd >= 0 and (Int(perf_counter_ns()) - t0 < 5_000_000_000):
        app.gpu_tick()
        _ = external_call["usleep", Int32](UInt32(10000))
    var gi = app.gpuwin_index()
    assert_true(gi >= 0)
    var gtxt = bytes_to_str(app.wins[gi].buf.to_bytes())
    assert_true(gtxt.find("NV18") >= 0, gtxt)
    assert_true(gtxt.find("mojo_job") >= 0, gtxt)


def main() raises:
    var suite = TestSuite()
    suite.test[test_p19_01_target_toml_wrappers_picker_pill_and_path_remap]()
    suite.test[test_p19_02_multi_gpu_nvlink_topology_slurm_queue_and_cgroup_in_wk_gpu]()
    suite^.run()
