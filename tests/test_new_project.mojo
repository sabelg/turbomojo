"""Tests for File > New project (P11-04): the project's files (a pixi.toml with the Modular
channel, Mojo of the release TurboMojo was built with and hello/test tasks; hello.mojo, a
test, .gitignore), the dialog and what it refuses, the IDE moving into the project and
running `pixi install` (a stand-in pixi here), and the first run's welcome offering it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from newproject import np_name_problem, np_platform, np_mojo_spec, np_pixi_toml, np_files
from project import parse_pixi_tasks, pixi_project_name
from term import key_event, wait_readable, KEY_ENTER, KEY_ESC
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_NEW_PROJECT, D_INFO, D_THEME
from window import WK_EDITOR
from commands import CM_NEW, CM_NEW_PROJECT, CM_EXPLORER, build_registry
from config import read_text
from signals import own_pid
from util import to_str, env_or, run_system, getcwd, path_exists, basename


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-newproj-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def go_back(dir: String):
    """The IDE moves into the new project (chdir): the tests go back after."""
    var cz = dir.copy()
    _ = external_call["chdir", Int32](cz.as_c_string_span())


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
        out += (" | " if r > 0 else "") + to_str(app.wins[mi].buf.line(r))
    return out


def fake_pixi(d: String) raises -> String:
    var p = d + "/fakepixi"
    with open(p, "w") as f:
        f.write("#!/bin/sh\necho \"fake pixi: $* in $(pwd)\"\n[ -f pixi.toml ] || exit 4\necho '✔ The default environment has been installed.'\n")
    _ = run_system("chmod +x '" + p + "'")
    return p


def type_text(mut app: App, s: String) raises:
    for c in s.codepoints():
        app.handle(key_event(Int(c)))


def test_names_platforms_and_the_mojo_asked_for() raises:
    assert_equal(np_name_problem("hello-mojo"), "")
    assert_equal(np_name_problem("my_app.2"), "")
    assert_true(np_name_problem("").byte_length() > 0)
    assert_true(np_name_problem("-x").find("start") >= 0)
    assert_true(np_name_problem("has space").find("\" \"") >= 0, np_name_problem("has space"))
    assert_true(np_name_problem("a/b").byte_length() > 0)
    assert_equal(np_platform("Linux x86_64"), "linux-64")
    assert_equal(np_platform("Linux aarch64\n"), "linux-aarch64")
    assert_equal(np_platform("Darwin arm64"), "osx-arm64")
    assert_equal(np_platform("Darwin x86_64"), "osx-64")
    # the release series TurboMojo was built with, so the project's Mojo and the IDE agree
    assert_equal(np_mojo_spec("Mojo 1.2.0 (2016d0cd)"), ">=1.2,<1.3")
    assert_equal(np_mojo_spec("Mojo 1.3.0.dev2026111305 (ab12)"), ">=1.3,<1.4")
    assert_equal(np_mojo_spec(""), "*")
    var toml = np_pixi_toml("demo", "linux-64", ">=1.2,<1.3")
    assert_equal(pixi_project_name(toml), "demo")
    assert_true(toml.find("channels = [\"https://conda.modular.com/max\", \"conda-forge\"]") >= 0, toml)
    assert_true(toml.find("platforms = [\"linux-64\"]") >= 0)
    assert_true(toml.find("[dependencies]\nmojo = \">=1.2,<1.3\"") >= 0, toml)
    var tasks = parse_pixi_tasks(toml)
    assert_equal(len(tasks), 2)
    assert_equal(tasks[0].name + "=" + tasks[0].cmd, "hello=mojo run hello.mojo")
    assert_equal(tasks[1].name + "=" + tasks[1].cmd, "test=mojo run -I . test_hello.mojo")
    var files = np_files("demo", "linux-64", "*")
    assert_equal(len(files), 8)
    assert_equal(files[2] + " " + files[4] + " " + files[6], "hello.mojo test_hello.mojo .gitignore")
    assert_true(files[3].find("def main():") >= 0 and files[3].find("def greeting(") >= 0)
    assert_true(files[5].find("from hello import greeting") >= 0 and files[5].find("TestSuite") >= 0)
    assert_true(files[7].find(".pixi/") >= 0)


def test_a_project_is_made_opened_and_installed() raises:
    var here = getcwd()
    var d = scratch("make")
    _ = run_system("touch '" + d + "/notes.txt'")      # (not empty: the default is a new folder)
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.pixi_cmd = fake_pixi(d)
    app.exec(CM_NEW)                                    # the untouched NONAME00 at start
    app.exec(CM_EXPLORER)
    assert_equal(app.ex.root, d)                        # (the explorer in front, not NONAME00)
    assert_equal(build_registry().index_of_name("file.newProject") >= 0, True)
    app.exec(CM_NEW_PROJECT)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_NEW_PROJECT)
    assert_equal(app.dlg.field_text(0), d + "/hello-mojo")
    app.handle(key_event(KEY_ENTER))
    go_back(here)
    assert_equal(app.mode, M_NORMAL)
    var p = d + "/hello-mojo"
    for f in ["pixi.toml", "hello.mojo", "test_hello.mojo", ".gitignore"]:
        assert_true(path_exists(p + "/" + f), f)
    assert_equal(pixi_project_name(read_text(p + "/pixi.toml")), "hello-mojo")
    # the IDE works in the project now: its tasks are the new project's
    assert_equal(app.cwd, p)
    assert_equal(app.pixi_dir(), p)
    assert_equal(app.ex.root, p)                        # the explorer shows it
    # hello.mojo in front, the test behind it; the empty NONAME window is gone
    assert_equal(app.wins[app.top_editor()].path, p + "/hello.mojo")
    var editors = List[String]()
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_EDITOR:
            editors.append(basename(app.wins[i].path) if app.wins[i].path.byte_length() > 0 else app.wins[i].title)
    assert_equal(len(editors), 2)
    assert_true(editors[0] == "test_hello.mojo" and editors[1] == "hello.mojo", editors[0] + " " + editors[1])
    # pixi install runs there, its output on the Message page
    assert_true(app.job.active)
    assert_true(app.status.find("installing Mojo") >= 0, app.status)
    wait_job(app)
    assert_true(panel(app).find("fake pixi: install in " + p) >= 0, panel(app))
    assert_true(app.status.find("Project ready") == 0, app.status)
    # the next one beside it gets the next free name
    app.cwd = d
    app.exec(CM_NEW_PROJECT)
    assert_equal(app.dlg.field_text(0), d + "/hello-mojo-2")
    app.handle(key_event(KEY_ESC))
    _ = run_system("rm -rf '" + d + "'")


def test_what_is_refused() raises:
    var here = getcwd()
    var d = scratch("refuse")
    _ = run_system("mkdir -p '" + d + "/full' && touch '" + d + "/full/x' '" + d + "/afile'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.pixi_cmd = fake_pixi(d)
    for bad in ["full", "afile", "bad name", "   "]:
        assert_false(app.new_project_create(bad), bad)
        assert_equal(app.mode, M_DIALOG)
        assert_equal(app.dlg.kind, D_INFO)
        app.mode = M_NORMAL
    assert_equal(app.cwd, d)                            # nothing changed
    assert_false(path_exists(d + "/full/pixi.toml"))
    # an empty folder is fine; a failing install says so
    _ = run_system("mkdir -p '" + d + "/empty'")
    app.pixi_cmd = "false"
    assert_true(app.new_project_create("empty"))
    go_back(here)
    wait_job(app)
    assert_true(app.status.find("pixi install failed") == 0, app.status)
    # with no pixi at all: the files are made, and told how to get Mojo
    app.cwd = d
    app.pixi_cmd = "no-such-pixi-for-turbomojo"
    assert_true(app.new_project_create(d + "/nopixi"))
    go_back(here)
    assert_true(path_exists(d + "/nopixi/hello.mojo"))
    assert_equal(app.dlg.kind, D_INFO)
    assert_true(app.dlg.lines[0].find("pixi.sh") >= 0, app.dlg.lines[0])
    assert_false(app.job.active)
    _ = run_system("rm -rf '" + d + "'")


def test_the_welcome_offers_one() raises:
    var here = getcwd()
    var d = scratch("welcome")
    _ = run_system("mkdir -p '" + d + "/state' '" + d + "/empty' '" + d + "/proj' && touch '" + d + "/proj/pixi.toml'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d + "/empty"
    app.pixi_cmd = fake_pixi(d)
    app.config_path = ""
    app.theme_marker = d + "/state/theme-asked"
    assert_true(app.first_run_theme())
    assert_equal(app.dlg.kind, D_THEME)
    app.handle(key_event(KEY_ENTER))                    # a theme is chosen...
    assert_equal(app.mode, M_DIALOG)                    # ... and a project offered,
    assert_equal(app.dlg.kind, D_NEW_PROJECT)
    assert_true(app.dlg.title.find("Welcome") >= 0, app.dlg.title)
    assert_equal(app.dlg.field_text(0), d + "/empty")   # in the (empty) folder itself
    app.handle(key_event(KEY_ESC))                      # no thanks: nothing is made
    assert_equal(app.mode, M_NORMAL)
    assert_false(path_exists(d + "/empty/pixi.toml"))
    go_back(here)
    # where there is a project already, the welcome asks only the theme
    var other = App()
    other.scr.resize(100, 30)
    other.cwd = d + "/proj"
    other.config_path = ""
    other.theme_marker = d + "/state/theme-asked-2"
    assert_true(other.first_run_theme())
    other.handle(key_event(KEY_ESC))
    assert_equal(other.mode, M_NORMAL)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
