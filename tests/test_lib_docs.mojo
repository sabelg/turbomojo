"""Tests for the documentation of the libraries a program uses (P11-14): which Mojo
variables hold Python modules, the dotted name at the cursor, what pydoc is asked and
what it says (the real Python and a project's own, faked), F1 / Ctrl-F1 on such a name,
and the language server started in the project's environment, where the Mojo packages
pixi installed are (they come compiled: the server reads them, `mojo doc` cannot)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from pydocs import *
from app import *
from appstate import App, M_NORMAL, M_HOVER, now_ns
from signals import own_pid
from util import env_or, run_system, run_capture, bytes_to_str, decode, to_str


def cps(s: String) -> List[Int]:
    return decode(s)


def test_the_bindings() raises:
    var b = python_bindings("from std.python import Python\nvar np = Python.import_module(\"numpy\")\n  plt = Python.import_module('matplotlib.pyplot')\nvar js: PythonObject = Python.import_module(\"json\")\nvar x = 1\n# Python.import_module(\"nothing\") without a name\nvar np = Python.import_module(\"cupy\")\n")
    assert_equal(len(b), 3)
    assert_equal(b[0].name, "plt")
    assert_equal(b[0].module, "matplotlib.pyplot")
    assert_equal(b[1].name, "js")
    assert_equal(b[2].name, "np")                     # (the later one wins)
    assert_equal(b[2].module, "cupy")


def test_the_name_at_the_cursor() raises:
    var line = cps("    var n = np.linalg.norm(x) + 1")
    assert_equal(dotted_at(line, 13), "np")                 # on np
    assert_equal(dotted_at(line, 17), "np.linalg")          # on linalg
    assert_equal(dotted_at(line, 23), "np.linalg.norm")     # on norm
    assert_equal(dotted_at(line, 26), "np.linalg.norm")     # just after it
    assert_equal(dotted_at(line, 31), "")                   # on "+"
    var b = python_bindings("var np = Python.import_module(\"numpy\")\n")
    assert_equal(python_target("np.linalg.norm", b), "numpy.linalg.norm")
    assert_equal(python_target("np", b), "numpy")
    assert_equal(python_target("npx.zeros", b), "")
    assert_equal(python_target("", b), "")


def test_what_pydoc_says() raises:
    # the real Python (this project's environment has one)
    var r = run_capture(pydoc_command("python3", "json.dumps"))
    var out = bytes_to_str(r.out)
    assert_equal(r.status, 0, out)
    assert_true(out.find("json.dumps") >= 0 and out.find("dumps(") > 0 and out.find("skipkeys") > 0, out)
    var bad = run_capture(pydoc_command("python3", "json.no_such_thing"))
    assert_true(bad.status != 0)
    assert_true(bytes_to_str(bad.out).startswith("pydoc: "), bytes_to_str(bad.out))
    # quotes in a name do not break the command
    assert_true(run_capture(pydoc_command("python3", "it's")).status != 0)
    var md = pydoc_markdown("json.dumps", "a\nb ``` c\n", "python3")
    assert_true(md.startswith("# json.dumps\n") and md.find("b ''' c") > 0 and md.find("pydoc") > 0, md)
    var long = String("")
    for _ in range(PYDOC_MAX_LINES + 10):
        long += "x\n"
    assert_true(pydoc_markdown("m", long, "python3").find("more lines: `python -m pydoc m`") > 0)


def test_f1_on_a_python_name() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-libdocs-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/p/.pixi/envs/default/bin' '" + d + "/loose'")
    # a project whose environment has its own Python (a fake that says which it is)
    _ = run_system("touch '" + d + "/p/pixi.toml' && printf '#!/bin/sh\\necho \"the project python on $3\"\\n' > '" + d + "/p/.pixi/envs/default/bin/python3' && chmod +x '" + d + "/p/.pixi/envs/default/bin/python3'")
    with open(d + "/p/a.mojo", "w") as f:
        f.write("from std.python import Python\ndef main() raises:\n    var np = Python.import_module(\"numpy\")\n    print(np.zeros(3))\n")
    var app = App()
    app.scr.resize(100, 30)
    app.open_path(d + "/p/a.mojo")
    var ai = app.active_editor()
    app.wins[ai].cr = 3
    app.wins[ai].cc = 13                      # on zeros
    assert_true(app.docs_at_cursor(True))
    assert_equal(app.mode, M_HOVER)
    var shown = String("")
    for l in app.hover_lines:
        shown += to_str(l.cps) + "\n"
    assert_true(shown.find("numpy.zeros") >= 0 and shown.find("the project python on numpy.zeros") >= 0, shown)
    # not a Python name: the usual lookup (nothing here)
    app.mode = M_NORMAL
    app.wins[ai].cr = 3
    app.wins[ai].cc = 6                       # on print
    assert_equal(app.docs_python(ai), 0)
    # no project: the Python on PATH, which has json but no such name
    with open(d + "/loose/b.mojo", "w") as f:
        f.write("var js = Python.import_module(\"json\")\njs.dumps(1)\njs.nothing(2)\n")
    app.open_path(d + "/loose/b.mojo")
    ai = app.active_editor()
    app.wins[ai].cr = 1
    app.wins[ai].cc = 4
    assert_equal(app.docs_python(ai), 1)
    app.mode = M_NORMAL
    app.wins[ai].cr = 2
    app.wins[ai].cc = 5
    assert_equal(app.docs_python(ai), -1)
    assert_true(app.status.startswith("Python has no documentation for json.nothing"), app.status)
    assert_false(app.docs_at_cursor(False))   # (F1: the general help instead)
    _ = run_system("rm -rf '" + d + "'")


def test_the_language_server_in_the_projects_environment() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-libdocs2-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/p/.pixi/envs/default/bin' '" + d + "/q'")
    _ = run_system("touch '" + d + "/p/pixi.toml' '" + d + "/q/pixi.toml' && printf '#!/bin/sh\\n' > '" + d + "/p/.pixi/envs/default/bin/mojo-lsp-server' && chmod +x '" + d + "/p/.pixi/envs/default/bin/mojo-lsp-server'")
    var app = App()
    app.pixi_cmd = "sh"                       # (found; the command is only built here)
    var cmd = app.lsp_server_command(d + "/p/a.mojo")
    assert_true(cmd.startswith("bash -c 'eval \"$(sh shell-hook --shell bash --manifest-path"), cmd)
    assert_true(cmd.find("&& exec mojo-lsp-server -I ") > 0, cmd)
    assert_equal(app.lsp_server_command(d + "/q/a.mojo").find("shell-hook"), -1)     # no environment
    app.lsp_server = "/opt/other-lsp"                                                  # a configured one wins
    assert_equal(app.lsp_server_command(d + "/p/a.mojo").find("shell-hook"), -1)
    _ = run_system("rm -rf '" + d + "'")


def test_the_language_server_follows_the_project() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-libdocs3-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/p/.pixi/envs/default/bin' '" + d + "/q/.pixi/envs/default/bin' '" + d + "/loose'")
    # each project's environment has a stand-in server that only stays alive; a fake
    # `pixi shell-hook` puts that environment first on PATH, as the real one does
    for pr in ["p", "q"]:
        var bin = d + "/" + String(pr) + "/.pixi/envs/default/bin"
        _ = run_system("touch '" + d + "/" + String(pr) + "/pixi.toml' && printf '#!/bin/sh\\nexec tail -f /dev/null\\n' > '" + bin + "/mojo-lsp-server' && chmod +x '" + bin + "/mojo-lsp-server'")
    with open(d + "/fake-pixi.sh", "w") as f:
        f.write("[ \"$1\" = shell-hook ] || exit 3\necho \"export PATH='$(dirname \"$5\")/.pixi/envs/default/bin':\\$PATH\"\n")
    for f in ["p/a.mojo", "p/c.mojo", "q/b.mojo", "q/e.mojo", "loose/l.mojo"]:
        with open(d + "/" + String(f), "w") as out:
            out.write("def main():\n    pass\n")
    var app = App()
    app.scr.resize(100, 30)
    app.pixi_cmd = "sh " + d + "/fake-pixi.sh"
    app.tool_env_known = True
    app.tool_env = ""
    app.open_path(d + "/p/a.mojo")
    app.open_path(d + "/p/c.mojo")
    app.open_path(d + "/q/b.mojo")
    app.open_path(d + "/q/e.mojo")
    app.open_path(d + "/loose/l.mojo")
    app.focus(app.find_editor(d + "/p/a.mojo"))
    app.lsp_track(app.active_editor(), now_ns())
    assert_equal(app.lsp.starts, 1)
    assert_equal(app.lsp_env, d + "/p/pixi.toml")
    _ = run_system("sleep 0.5")
    assert_true(app.lsp.conn.proc.running, "the stand-in server did not start")
    # another file of the same project: the same server
    app.focus(app.find_editor(d + "/p/c.mojo"))
    app.lsp_tick(now_ns())
    assert_equal(app.lsp.starts, 1)
    # a file of another project: started again in that one's environment
    app.focus(app.find_editor(d + "/q/b.mojo"))
    app.lsp_tick(now_ns())
    assert_equal(app.lsp.starts, 2)
    assert_equal(app.lsp_env, d + "/q/pixi.toml")
    assert_true(app.lsp.server_cmd.find(d + "/q/pixi.toml") > 0, app.lsp.server_cmd)
    assert_true(app.status.startswith("Language server: started again for q's environment"), app.status)
    _ = run_system("sleep 0.5")
    assert_true(app.lsp.conn.proc.running)
    app.focus(app.find_editor(d + "/q/e.mojo"))
    app.lsp_tick(now_ns())
    assert_equal(app.lsp.starts, 2)
    # a file of no project: the IDE's own server (a stand-in here too)
    app.lsp_server = "tail -f /dev/null #"
    app.focus(app.find_editor(d + "/loose/l.mojo"))
    app.lsp_tick(now_ns())
    assert_equal(app.lsp.starts, 3)
    assert_equal(app.lsp_env, "")
    app.lsp_stop()
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
