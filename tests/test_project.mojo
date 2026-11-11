"""The project model: finding pixi.toml, reading its tasks, running one."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from project import *
from term import fkey, key_event, wait_readable, MOD_SHIFT, KEY_ENTER, KEY_ESC
from app import *
from appstate import App, M_NORMAL, M_DIALOG, PG_MESSAGE
from dialog import D_TASKS
from window import WK_MESSAGE
from commands import CM_TASKS, CM_TASK_AGAIN, build_registry
from config import read_text
from signals import own_pid
from util import decode, to_str, env_or, run_system, getcwd


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-project-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def listed(tasks: List[PixiTask]) -> String:
    var s = String("")
    for t in tasks:
        if s.byte_length() > 0:
            s += " | "
        s += (t.feature + ":" if t.feature.byte_length() > 0 else String("")) + t.name + "=" + t.cmd
        if len(t.depends) > 0:
            s += " <"
            for d in t.depends:
                s += " " + d
        if t.description.byte_length() > 0:
            s += " (" + t.description + ")"
    return s


def test_find_up() raises:
    var d = scratch("up")
    _ = run_system("mkdir -p '" + d + "/a/b/c' '" + d + "/other'")
    put(d + "/a/pixi.toml", "[tasks]\n")
    assert_equal(find_up(d + "/a/b/c", "pixi.toml"), d + "/a")
    assert_equal(find_up(d + "/a", "pixi.toml"), d + "/a")       # in the folder itself
    assert_equal(find_up(d + "/other", "pixi.toml") == d + "/a", False)
    assert_equal(find_up(d + "/a/b/c", "no_such_file_anywhere.xyz"), "")
    assert_equal(find_up("", "pixi.toml"), "")
    _ = run_system("rm -rf '" + d + "'")


def test_tasks_in_every_written_form() raises:
    var text = "[workspace]\nname = \"demo\"\nchannels = [\"conda-forge\"]\n\n[dependencies]\nbuild = \"1.0\"\n\n[tasks]\n# a comment\nbuild = \"mojo build main.mojo\"\nrun = { cmd = \"./main\", depends-on = [\"build\"] }\n'quoted name' = 'echo \"hi\"'\nlint = { cmd = [\"mblack\", \"--check\", \".\"], description = \"Check the formatting\" }\nall = { depends-on = [\"build\", { task = \"lint\", args = [\"x\"] }] }\nescaped = \"printf \\\"a\\\\n\\\"\"\nwith_env = { cmd = \"env\", env = { A = \"1\", B = \"2\" }, cwd = \"sub\" }\n\n[tasks.docs]\ncmd = \"mojo doc main.mojo\"\ndescription = \"Build the docs\"\ndepends_on = \"build\"\n\n[feature.test.tasks]\ntest = \"mojo test\"\n\n[feature.test.dependencies]\npytest = \"*\"\n\n[environments]\ndefault = [\"test\"]\n"
    var t = parse_pixi_tasks(text)
    assert_equal(listed(t), "build=mojo build main.mojo | run=./main < build | quoted name=echo \"hi\" | lint=mblack --check . (Check the formatting) | all= < build lint | escaped=printf \"a\\n\" | with_env=env | docs=mojo doc main.mojo < build (Build the docs) | test:test=mojo test")
    assert_equal(pixi_project_name(text), "demo")
    # the [dependencies] entry called "build" is not a task
    assert_equal(len(t), 9)


def test_tasks_of_odd_and_empty_files() raises:
    assert_equal(len(parse_pixi_tasks("")), 0)
    assert_equal(len(parse_pixi_tasks("[project]\nname = \"x\"\n")), 0)
    assert_equal(pixi_project_name("[project]\nname = \"x\"\n"), "x")
    assert_equal(pixi_project_name("[tasks]\nname = \"not this\"\n"), "")
    # pyproject.toml style
    var py = parse_pixi_tasks("[tool.pixi.tasks]\nfmt = \"mblack .\"\n[tool.pixi.feature.dev.tasks]\nwatch = \"watch\"\n[tool.other]\nx = \"1\"\n")
    assert_equal(listed(py), "fmt=mblack . | dev:watch=watch")
    # lines that are not understood are passed over, the rest is read
    var odd = parse_pixi_tasks("[tasks]\n= \"no name\"\nok = \"yes\"\nnumber = 5\nbroken = { cmd = \"unclosed\nlast = \"end\"\n[[array.of.tables]]\nnot_a_task = \"x\"\n")
    assert_equal(listed(odd), "ok=yes | number= | broken=unclosed | last=end")
    # this project's own file
    var own = parse_pixi_tasks(read_text(getcwd() + "/pixi.toml"))
    assert_equal(listed(own), "build=mkdir -p build && mojo build -I src src/main.mojo -o build/tmide -Xlinker $CONDA_PREFIX/lib/libghostty-vt.a | run=./build/tmide < build | check=scripts/check.sh | canary=TM_ENV=nightly scripts/check.sh")
    assert_equal(pixi_project_name(read_text(getcwd() + "/pixi.toml")), "turbo-mojo")


# ------------------------------------------------------- in the application
def task_project(tag: String) raises -> String:
    """A project with a pixi.toml, a subfolder, and a stand-in for pixi that says what
    it was asked to run."""
    var d = scratch(tag)
    _ = run_system("mkdir -p '" + d + "/proj/sub'")
    put(d + "/proj/pixi.toml", "[workspace]\nname = \"demo\"\n\n[tasks]\nbuild = \"mojo build main.mojo\"\ntest = { cmd = \"mojo test\", depends-on = [\"build\"] }\nfail = \"false\"\n")
    put(d + "/proj/sub/a.mojo", "one\ntwo\nthree\n")
    put(d + "/fakepixi", "#!/bin/sh\necho \"fake pixi: $* in $(pwd)\"\nif [ \"$2\" = fail ]; then echo 'sub/a.mojo:2:3: error: boom'; exit 3; fi\necho done\n")
    _ = run_system("chmod +x '" + d + "/fakepixi'")
    return d


def wait_job(mut app: App) raises:
    var guard = 0
    while app.job.active and guard < 500:
        guard += 1
        _ = wait_readable([app.job.fd], 20)
        app.poll_job()


def panel(app: App) -> String:
    var mi = app.msg_index()
    if mi < 0:
        return "(closed)"
    var out = String("")
    for r in range(app.wins[mi].buf.count()):
        if r > 0:
            out += " | "
        out += to_str(app.wins[mi].buf.line(r))
    return out


def test_project_is_found_from_a_subfolder() raises:
    var d = task_project("app1")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d + "/proj/sub"                             # started inside the project
    assert_equal(app.pixi_locate(), d + "/proj")
    assert_equal(app.symidx_root(), d + "/proj")         # the project is the whole thing, not this folder
    var outside = App()
    outside.cwd = d                                      # above it: no project
    assert_equal(outside.pixi_locate(), "")
    assert_equal(outside.symidx_root(), d)
    outside.scr.resize(100, 30)
    outside.exec(CM_TASKS)
    assert_equal(outside.mode, M_NORMAL)
    assert_equal(outside.status, "No pixi.toml in this folder or above it")
    put(d + "/pixi.toml", "[workspace]\nname = \"bare\"\n")
    outside.cwd = d + "/"                                # (looked up again for another folder)
    outside.cwd = d
    outside.pixi_for = ""
    outside.exec(CM_TASKS)
    assert_true(outside.status.find("defines no tasks") > 0, outside.status)
    _ = run_system("rm -rf '" + d + "'")


def test_tasks_are_listed_and_run() raises:
    var d = task_project("app2")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d + "/proj/sub"
    app.pixi_cmd = d + "/fakepixi"
    assert_equal(build_registry().find_key(fkey(9) | MOD_SHIFT), CM_TASKS)
    app.handle(key_event(fkey(9) | MOD_SHIFT))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_TASKS)
    assert_equal(app.dlg.title, "Pixi Tasks - demo")
    assert_equal(len(app.dlg.items), 3)
    assert_true(app.dlg.items[0].startswith("build "), app.dlg.items[0])
    assert_true(app.dlg.items[0].endswith("mojo build main.mojo"), app.dlg.items[0])
    assert_true(app.dlg.items[1].endswith("mojo test   (after build)"), app.dlg.items[1])
    # typing narrows; Enter runs the task in the project folder
    for c in decode("te"):
        app.handle(key_event(c))
    assert_equal(len(app.dlg.shown), 1)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.job.active)
    assert_true(app.status.find("Task test is running") == 0, app.status)
    wait_job(app)
    assert_false(app.job.active)
    assert_equal(app.msg_page, PG_MESSAGE)
    var out = panel(app)
    assert_true(out.find("pixi run test   (in " + d + "/proj)") == 0, out)
    assert_true(out.find("fake pixi: run test in " + d + "/proj | done | Task test finished in ") > 0, out)
    assert_true(app.status.find("Task test finished in ") == 0, app.status)
    # again without the list
    app.exec(CM_TASK_AGAIN)
    assert_true(app.job.active)
    # a second task is not started while one runs
    app.run_task("build")
    assert_true(app.status.find("busy") > 0, app.status)
    wait_job(app)
    assert_true(panel(app).find("fake pixi: run test") > 0)
    # the list opens on the task run last
    app.exec(CM_TASKS)
    assert_equal(app.dlg.selected_item(), 1)
    app.handle(key_event(KEY_ESC))
    _ = run_system("rm -rf '" + d + "'")


def test_a_failing_task_shows_its_errors() raises:
    var d = task_project("app3")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d + "/proj/sub"
    app.pixi_cmd = d + "/fakepixi"
    app.run_task("fail")
    wait_job(app)
    assert_true(app.status.find("Task fail failed (exit 3) after ") == 0, app.status)
    assert_true(panel(app).find("sub/a.mojo:2:3: error: boom") > 0, panel(app))
    # the panel has the keyboard, on the first error; Enter goes to it - the path counts
    # from the project folder, not from where the IDE was started
    assert_equal(app.wins[app.top()].kind, WK_MESSAGE)
    assert_equal(len(app.errs), 1)
    assert_equal(app.errs[0].path, d + "/proj/sub/a.mojo")
    app.handle(key_event(KEY_ENTER))
    var t = app.top()
    assert_equal(app.wins[t].path, d + "/proj/sub/a.mojo")
    assert_equal(app.wins[t].cr, 1)
    assert_equal(app.wins[t].cc, 2)
    # with nothing run yet, "Run last task" offers the list
    var fresh = App()
    fresh.scr.resize(100, 30)
    fresh.cwd = d + "/proj"
    fresh.exec(CM_TASK_AGAIN)
    assert_equal(fresh.mode, M_DIALOG)
    assert_equal(fresh.dlg.kind, D_TASKS)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
