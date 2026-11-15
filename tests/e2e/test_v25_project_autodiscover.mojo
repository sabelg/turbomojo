"""E2E Test Suite for v2.5.0 Milestone 1:
Zero-Config Per-File Project & `src/` Include Root Auto-Discovery.
"""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from project import discover_mojo_project_root, discover_auto_include_dirs
from app import App
from commands import CM_RUN_CELL
from signals import own_pid
from util import (
    env_or, run_system, write_file, str_bytes, to_str, path_exists,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v25-m1-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def test_v25_m1_01_discover_project_and_src_roots() raises:
    """Walks upward to find .git, pixi.toml, mojoproject.toml, .turbomojo.toml, src/, and __init__.mojo."""
    var base = _scratch("roots")
    var rc = base + "/home_sim/rollercoaster"
    var eng = base + "/home_sim/engine"
    var pkgonly = base + "/home_sim/standalone_ws/my_pkg/sub"
    var loose = base + "/home_sim/loose"
    _ = run_system(
        "mkdir -p '" + rc + "/.git' '" + rc + "/src/assets' '"
        + eng + "/src/gpu' '" + pkgonly + "' '" + loose + "'"
    )
    _ = write_file(eng + "/mojoproject.toml", str_bytes("[project]\nname = \"engine\"\n"))
    _ = write_file(base + "/home_sim/standalone_ws/my_pkg/__init__.mojo", str_bytes(""))
    _ = write_file(pkgonly + "/__init__.mojo", str_bytes(""))
    _ = write_file(rc + "/src/assets/image.mojo", str_bytes("def ok(): pass\n"))
    _ = write_file(eng + "/src/gpu/kernel.mojo", str_bytes("def ok(): pass\n"))
    _ = write_file(pkgonly + "/ops.mojo", str_bytes("def ok(): pass\n"))
    _ = write_file(loose + "/scratch.mojo", str_bytes("def ok(): pass\n"))

    assert_equal(discover_mojo_project_root(rc + "/src/assets/image.mojo"), rc)
    assert_equal(discover_mojo_project_root(eng + "/src/gpu/kernel.mojo"), eng)
    assert_equal(discover_mojo_project_root(pkgonly + "/ops.mojo"), base + "/home_sim/standalone_ws")
    assert_equal(discover_mojo_project_root(loose + "/scratch.mojo"), "")

    var rc_inc = discover_auto_include_dirs(rc + "/src/assets/image.mojo")
    assert_true(len(rc_inc) >= 2)
    assert_equal(rc_inc[0], rc + "/src")
    assert_equal(rc_inc[1], rc)

    _ = run_system("rm -rf '" + base + "'")


def test_v25_m1_02_lsp_command_and_subproject_config_includes() raises:
    """Injects per-file auto-discovered `src/` AND subproject `.turbomojo.toml` include_paths."""
    var base = _scratch("lspcmd")
    var home_sim = base + "/home_sim"
    var rc = home_sim + "/rollercoaster"
    _ = run_system("mkdir -p '" + rc + "/.git' '" + rc + "/src/assets' '" + rc + "/vendor/ext'")
    _ = write_file(rc + "/.turbomojo.toml", str_bytes("[tools]\ninclude_paths = [\"vendor/ext\"]\n"))
    var img = rc + "/src/assets/image.mojo"
    _ = write_file(img, str_bytes("def main(): pass\n"))

    var app = App()
    app.cwd = home_sim
    app.lsp_server = "my-lsp"
    var cmd = app.lsp_server_command(img)
    assert_true(cmd.find("-I '" + rc + "/src/assets'") >= 0, cmd)
    assert_true(cmd.find("-I '" + home_sim + "'") >= 0, cmd)
    assert_true(cmd.find("-I '" + rc + "/vendor/ext'") >= 0, cmd)
    assert_true(cmd.find("-I '" + rc + "/src'") >= 0, cmd)
    assert_true(cmd.find("-I '" + rc + "'") >= 0, cmd)

    _ = run_system("rm -rf '" + base + "'")


def test_v25_m1_03_warm_lsp_pool_follows_subproject_roots() raises:
    """Switching between two sibling subprojects under a parent cwd swaps via warm `lsp_pool`."""
    var base = _scratch("pool")
    var home_sim = base + "/home_sim"
    var p1 = home_sim + "/proj_alpha"
    var p2 = home_sim + "/proj_beta"
    var loose = home_sim + "/loose"
    _ = run_system(
        "mkdir -p '" + p1 + "/.git' '" + p1 + "/src/sub' '"
        + p2 + "/.git' '" + p2 + "/src/sub' '" + loose + "'"
    )
    var f1 = p1 + "/src/sub/a.mojo"
    var f1b = p1 + "/src/b.mojo"
    var f2 = p2 + "/src/sub/c.mojo"
    var fl = loose + "/l.mojo"
    for fp in [f1, f1b, f2, fl]:
        _ = write_file(String(fp), str_bytes("def main():\n    pass\n"))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = home_sim
    app.tool_env_known = True
    app.tool_env = ""
    app.lsp_server = "tail -f /dev/null #"

    assert_equal(app.lsp_env_key(f1), "root:" + p1)
    assert_equal(app.lsp_env_key(f1b), "root:" + p1)
    assert_equal(app.lsp_env_key(f2), "root:" + p2)
    assert_equal(app.lsp_env_key(fl), "")

    app.open_path(f1)
    app.open_path(f1b)
    app.open_path(f2)
    app.open_path(fl)

    app.focus(app.find_editor(f1))
    app.lsp_track(app.active_editor(), Int(perf_counter_ns()))
    _ = run_system("sleep 0.2")
    assert_equal(app.lsp.starts, 1)
    assert_equal(app.lsp_env, "root:" + p1)

    # Another file in proj_alpha keeps the same server without restarting
    app.focus(app.find_editor(f1b))
    app.lsp_tick(Int(perf_counter_ns()))
    assert_equal(app.lsp.starts, 1)

    # Switching to proj_beta parks proj_alpha in lsp_pool and starts proj_beta
    app.focus(app.find_editor(f2))
    app.lsp_tick(Int(perf_counter_ns()))
    _ = run_system("sleep 0.2")
    assert_equal(app.lsp.starts, 2)
    assert_equal(app.lsp_env, "root:" + p2)
    assert_equal(len(app.lsp_pool), 1)
    assert_equal(app.lsp_pool_keys[0], "root:" + p1)

    # Switching back to proj_alpha hits warm lsp_pool without incrementing starts!
    app.focus(app.find_editor(f1))
    app.lsp_tick(Int(perf_counter_ns()))
    assert_equal(app.lsp.starts, 2)
    assert_equal(app.lsp_env, "root:" + p1)

    app.lsp_stop()
    for pk in range(len(app.lsp_pool)):
        app.lsp_pool[pk].stop()
    _ = run_system("rm -rf '" + base + "'")


def test_v25_m1_04_real_compiler_build_and_cell_kernel_resolve_nested_src() raises:
    """Real `App.build()` and `# %%` cell execution resolve `from core import ...`
    inside `rollercoaster/src/assets/image.mojo` when `app.cwd` is the parent folder."""
    var base = _scratch("realbuild")
    var home_sim = base + "/home_sim"
    var rc = home_sim + "/rollercoaster"
    _ = run_system("mkdir -p '" + rc + "/.git' '" + rc + "/src/assets'")
    _ = write_file(rc + "/src/core.mojo", str_bytes("comptime CORE_MAGIC = 1337\n"))
    _ = write_file(rc + "/src/platform.mojo", str_bytes("def platform_tag() -> String:\n    return \"coaster-ok\"\n"))
    var img = rc + "/src/assets/image.mojo"
    var code = (
        "from core import CORE_MAGIC\n"
        "from platform import platform_tag\n\n"
        "def main():\n"
        "    print(platform_tag(), CORE_MAGIC)\n"
    )
    _ = write_file(img, str_bytes(code))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = home_sim
    app.open_path(img)

    # 1. Real `App.build()`
    app.build()
    var deadline = Int(perf_counter_ns()) + 25_000_000_000
    while app.job.active and Int(perf_counter_ns()) < deadline:
        app.poll_job()
        _ = run_system("sleep 0.05")
    assert_true(not app.job.active, "build job timed out")
    assert_true(path_exists(rc + "/src/assets/build/image"), "expected compiled binary from nested src/ import")

    # 2. Real persistent `# %%` Mojo cell kernel execution with top-level notebook cell
    var nb_path = rc + "/src/assets/nb_check.mojo"
    var nb_code = (
        "from core import CORE_MAGIC\n"
        "from platform import platform_tag\n"
        "# %% Verify nested imports\n"
        "print(platform_tag(), CORE_MAGIC)\n"
    )
    _ = write_file(nb_path, str_bytes(nb_code))
    app.open_path(nb_path)
    var ei = app.find_editor(nb_path)
    app.focus(ei)
    ei = app.top_editor()
    app.wins[ei].goto(3, 0)
    app.exec(CM_RUN_CELL)
    deadline = Int(perf_counter_ns()) + 25_000_000_000
    while (app.cell_k_active or app.job.active) and Int(perf_counter_ns()) < deadline:
        app.cell_kernel_tick()
        app.poll_job()
        _ = run_system("sleep 0.05")
    app.cell_kernels_stop()

    var mi = app.msg_index()
    assert_true(mi >= 0)
    var msg_txt = String("")
    for r in range(app.wins[mi].buf.count()):
        msg_txt += to_str(app.wins[mi].buf.line(r)) + "\n"
    assert_true(msg_txt.find("coaster-ok 1337") >= 0, msg_txt)

    _ = run_system("rm -rf '" + base + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
