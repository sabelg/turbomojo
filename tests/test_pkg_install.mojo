"""Tests for installing what a program uses (P11-13): reading which library a build's or
run's output says is missing (Mojo's and Python's messages, a module inside a package
that is there, Mojo's and Python's own modules), the package that brings it, and the
IDE's offer - looked up on the project's channels, installed with a yes, then built
again; made a project first where there is none; offered once; nothing without a yes.
A fake `mojo` and a fake `pixi` stand for the real ones."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from pkginstall import *
from term import wait_readable
from app import *
from appstate import App, M_NORMAL, M_DIALOG, now_ns
from dialog import D_PKG
from config import read_text
from signals import own_pid
from util import env_or, run_system, to_str, path_exists, which

comptime MS = 1000000


def test_reading_the_messages() raises:
    # Python, through Python.import_module (as Mojo 1.2 prints it)
    var py = missing_modules("stack trace was not collected.\nUnhandled exception caught during execution: No module named 'numpy'\nmojo: error: execution exited with a non-zero result: 1\n")
    assert_equal(len(py), 1)
    assert_equal(py[0].kind, PK_PYTHON)
    assert_equal(py[0].module, "numpy")
    # Mojo, with the source line under the message
    var mj = missing_modules("/p/a.mojo:1:6: error: unable to locate module 'max'\nfrom max.gpu.host import DeviceContext\n     ^\n/p/a.mojo:2:6: error: unable to locate module 'max'\nfrom max.tensor import T\n")
    assert_equal(len(mj), 1)                                     # (once)
    assert_equal(mj[0].kind, PK_MOJO)
    assert_equal(mj[0].module, "max")
    # a module inside a package that is there: nothing to install
    assert_equal(len(missing_modules("/p/a.mojo:1:10: error: unable to locate module 'tensor'\nfrom max.tensor import Tensor\n")), 0)
    # Mojo's and Python's own: a broken installation, not a package
    assert_equal(len(missing_modules("a.mojo:1:6: error: unable to locate module 'std'\nfrom std.python import Python\nNo module named 'json'\n")), 0)
    # a dotted Python name: its package; both kinds in one output
    var both = missing_modules("No module named 'yaml.loader'\nb.mojo:3:8: error: unable to locate module 'lightbug_http'\nimport lightbug_http\n")
    assert_equal(len(both), 2)
    assert_equal(both[0].module, "yaml")
    assert_equal(both[1].module, "lightbug_http")
    assert_equal(len(missing_modules("all fine\n")), 0)
    assert_equal(imported_top("from max.gpu.host import DeviceContext"), "max")
    assert_equal(imported_top("  import numpy, os"), "numpy")
    assert_equal(imported_top("var x = 1"), "")


def test_the_packages() raises:
    assert_equal(package_for(PK_PYTHON, "numpy"), "numpy")
    assert_equal(package_for(PK_PYTHON, "yaml"), "pyyaml")
    assert_equal(package_for(PK_PYTHON, "sklearn"), "scikit-learn")
    assert_equal(package_for(PK_PYTHON, "PIL"), "pillow")
    assert_equal(package_for(PK_MOJO, "max"), "max")
    assert_equal(package_for(PK_MOJO, "gpu"), "max")              # (Mojo 1.2: max.gpu)
    assert_true(import_note(PK_MOJO, "gpu").find("max.gpu") > 0)
    assert_equal(import_note(PK_PYTHON, "numpy"), "")
    assert_equal(in_env("cd '/p' && exec mojo run a.mojo", "pixi", "/p/pixi.toml"), "bash -c 'eval \"$(pixi shell-hook --shell bash --manifest-path '\\''/p/pixi.toml'\\'')\" && cd '\\''/p'\\'' && exec mojo run a.mojo'")


def wait_jobs(mut app: App) raises:
    """Until no job runs (a job's end may start the next: search, add, build again)."""
    var deadline = Int(perf_counter_ns()) + 30000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active, "the job did not end")


def built(app: App) -> Bool:
    """The build after the install succeeded: its result box, or the status line."""
    if app.mode == M_DIALOG and app.dlg.title == "Compiling":
        for l in app.dlg.lines:
            if l.find("~Success~") >= 0:
                return True
    return app.status.find("Build succeeded") >= 0


def setup(d: String) raises -> App:
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/proj' '" + d + "/loose'")
    # mojo: a build fails while the file imports a library not "installed" in its folder
    with open(d + "/fake-mojo.sh", "w") as f:
        f.write("[ \"$1\" = build ] || exit 9\nsrc=$2\nlib=$(sed -n 's/^from \\([a-z_]*\\).*/\\1/p' \"$src\" | head -1)\nif [ -n \"$lib\" ] && [ ! -f \"$(dirname $src)/installed-$lib\" ]; then\n  echo \"$src:1:6: error: unable to locate module '$lib'\"\n  sed -n 1p \"$src\"\n  echo 'mojo: error: failed to parse the provided Mojo source module'\n  exit 1\nfi\necho built; exit 0\n")
    # pixi: `search NAME` knows mylib only; `add NAME` marks it installed
    with open(d + "/fake-pixi.sh", "w") as f:
        f.write("echo \"pixi $*\" >> " + d + "/pixi.log\ncase \"$1\" in\n  search) if [ \"$2\" = mylib ]; then echo 'mylib-1.0-h0_0'; exit 0; fi; echo \"Error: No packages found matching '$2'\"; exit 1 ;;\n  add) touch \"installed-$2\"; echo \"Added $2\"; exit 0 ;;\nesac\nexit 7\n")
    with open(d + "/proj/pixi.toml", "w") as f:
        f.write("[workspace]\nname = \"proj\"\nchannels = [\"conda-forge\"]\nplatforms = [\"linux-64\"]\n\n[dependencies]\n")
    var app = App()
    app.scr.resize(110, 34)
    app.cwd = d
    app.compiler = "sh " + d + "/fake-mojo.sh"
    app.pixi_cmd = "sh " + d + "/fake-pixi.sh"
    return app^


def test_offer_install_and_build_again() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-pkg-" + String(own_pid())
    var app = setup(d)
    with open(d + "/proj/prog.mojo", "w") as f:
        f.write("from mylib import thing\ndef main():\n    pass\n")
    app.open_path(d + "/proj/prog.mojo")
    # a language server running (a stand-in that only stays alive): an install restarts
    # it, so it sees the new package (P11-14)
    app.tool_env_known = True
    app.tool_env = ""
    app.lsp_server = "tail -f /dev/null #"
    app.lsp_track(app.top_editor(), now_ns())
    assert_equal(app.lsp.starts, 1)
    app.build()
    wait_jobs(app)                                              # the build, then the search
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_PKG)
    assert_true(app.dlg.lines[0].find("prog.mojo uses mylib, which is not installed") >= 0, app.dlg.lines[0])
    assert_true(app.dlg.lines[1].find("mylib (a Mojo package) is on the project's channels") >= 0, app.dlg.lines[1])
    assert_false(path_exists(d + "/proj/installed-mylib"))      # (nothing yet)
    app.dialog_button(0)                                        # Install
    wait_jobs(app)                                              # pixi add, then the build again
    assert_true(path_exists(d + "/proj/installed-mylib"))
    var log = read_text(d + "/pixi.log")
    assert_true(log.find("pixi search mylib") >= 0 and log.find("pixi add mylib") > 0, log)
    assert_true(built(app), app.status)
    assert_equal(app.lsp.starts, 2)
    assert_true(app.lsp.active())
    app.lsp_stop()
    # a library on no channel: said so, nothing offered or added
    with open(d + "/proj/other.mojo", "w") as f:
        f.write("from ghostlib import x\ndef main():\n    pass\n")
    app.open_path(d + "/proj/other.mojo")
    app.build()
    wait_jobs(app)
    assert_true(app.status.startswith("No package ghostlib on the project's channels"), app.status)
    assert_false(path_exists(d + "/proj/installed-ghostlib"))
    # offered once a session: the same failure again asks nothing
    app.mode = M_NORMAL
    app.build()
    wait_jobs(app)
    assert_equal(read_text(d + "/pixi.log").count("search ghostlib"), 1)
    _ = run_system("rm -rf '" + d + "'")


def test_no_project_and_not_now() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-pkg2-" + String(own_pid())
    var app = setup(d)
    with open(d + "/loose/a.mojo", "w") as f:
        f.write("from mylib import thing\ndef main():\n    pass\n")
    with open(d + "/loose/b.mojo", "w") as f:
        f.write("from otherlib import thing\ndef main():\n    pass\n")
    # Not now: nothing is written or installed
    app.open_path(d + "/loose/b.mojo")
    app.build()
    wait_jobs(app)
    assert_equal(app.dlg.kind, D_PKG)
    assert_true(app.dlg.lines[1].find("There is no pixi project here") >= 0, app.dlg.lines[1])
    app.dialog_button(1)
    assert_false(path_exists(d + "/loose/pixi.toml"))
    assert_false(path_exists(d + "/pixi.log"))
    # Make project and install
    app.open_path(d + "/loose/a.mojo")
    app.build()
    wait_jobs(app)
    assert_equal(app.dlg.kind, D_PKG)
    app.dialog_button(0)
    wait_jobs(app)
    var toml = read_text(d + "/loose/pixi.toml")
    assert_true(toml.find("[workspace]") >= 0 and toml.find("mojo = ") > 0, toml)
    assert_true(path_exists(d + "/loose/installed-mylib"))
    assert_true(built(app), app.status)
    _ = run_system("rm -rf '" + d + "'")


def test_after_a_failed_run() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-pkg4-" + String(own_pid())
    var app = setup(d)
    with open(d + "/proj/py.mojo", "w") as f:
        f.write("from std.python import Python\ndef main() raises:\n    var np = Python.import_module('mylib')\n")
    app.open_path(d + "/proj/py.mojo")
    app.run_file = d + "/proj/py.mojo"
    app.run_label = "py.mojo"
    app.run_t0_ns = Int(perf_counter_ns())
    app.run_report(1, "Unhandled exception caught during execution: No module named 'mylib'\n")
    wait_jobs(app)
    assert_equal(app.dlg.kind, D_PKG)
    assert_true(app.dlg.lines[1].find("mylib (a Python package)") >= 0, app.dlg.lines[1])
    assert_true(app.dlg.lines[2].find("then run again?") >= 0, app.dlg.lines[2])
    # a run that ended well asks nothing
    app.mode = M_NORMAL
    app.run_t0_ns = Int(perf_counter_ns())
    app.run_report(0, "No module named 'other'\n")
    assert_false(app.job.active)
    _ = run_system("rm -rf '" + d + "'")


def test_builds_run_in_the_projects_environment() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-pkg3-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/p/.pixi/envs/default/bin' '" + d + "/bare'")
    _ = run_system("touch '" + d + "/p/pixi.toml' '" + d + "/bare/pixi.toml' && printf '#!/bin/sh\\n' > '" + d + "/p/.pixi/envs/default/bin/mojo' && chmod +x '" + d + "/p/.pixi/envs/default/bin/mojo'")
    var app = App()
    app.pixi_cmd = "sh"                   # (any program that is there: the commands are only built)
    app.compiler = "mojo"
    assert_equal(app.env_manifest(d + "/p/a.mojo"), d + "/p/pixi.toml")
    assert_equal(app.mojo_for(d + "/p/a.mojo"), "mojo")
    assert_true(app.with_env(d + "/p/a.mojo", "mojo run a.mojo").startswith("bash -c 'eval \"$(sh shell-hook --shell bash --manifest-path"))
    assert_equal(app.env_manifest(d + "/bare/a.mojo"), "")          # no environment yet
    assert_equal(app.with_env(d + "/bare/a.mojo", "x"), "x")
    assert_equal(app.env_manifest(d + "/elsewhere/a.mojo"), "")
    app.compiler = "/opt/my/mojo"                                    # a configured compiler wins
    assert_equal(app.env_manifest(d + "/p/a.mojo"), "")
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
