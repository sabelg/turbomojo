"""Folder trust: the list of trusted folders, the question before commands and code of a
folder are run, and the project's own tool commands being held back until then."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from trust import TrustStore
from term import key_event, KEY_ENTER, KEY_ESC
from app import *
from app_exec import trust_needed
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_TRUST, D_TASKS
from commands import CM_TASKS, CM_BUILD, CM_RUN, CM_TEST, CM_FORMAT, CM_LSP, CM_DOCS, CM_TRUST, CM_SAVE, CM_OPEN, CM_FIND, CM_TASK_AGAIN, CM_EXPLORER
from config import read_text
from signals import own_pid
from util import decode, to_str, env_or, run_system, path_exists


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-trust-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def test_trusted_folders() raises:
    var t = TrustStore()
    assert_false(t.is_trusted("/home/me/proj"))
    assert_false(t.is_trusted(""))
    t.add("/home/me/proj")
    assert_true(t.is_trusted("/home/me/proj"))
    assert_true(t.is_trusted("/home/me/proj/src/deep"))          # what is inside it
    assert_false(t.is_trusted("/home/me/proj2"))                 # a neighbour with a similar name
    assert_false(t.is_trusted("/home/me"))                       # not what is above it
    t.add("/home/me/proj")
    t.add("relative/path")
    assert_equal(len(t.roots), 1)
    t.add("/other place/with blanks")
    assert_equal(t.encode(), "/home/me/proj\n/other place/with blanks\n")
    var u = TrustStore()
    u.decode_text("/home/me/proj/\n\nnot a path\n/other place/with blanks\n/home/me/proj\n")
    assert_equal(u.encode(), t.encode())                         # trailing slash and repeats tidied
    # taking it back works on the folder that was trusted, not on one inside it
    assert_false(u.remove("/home/me/proj/src"))
    assert_true(u.is_trusted("/home/me/proj/src"))
    assert_true(u.remove("/home/me/proj"))
    assert_false(u.is_trusted("/home/me/proj/src"))
    assert_false(u.remove("/home/me/proj"))


def test_which_commands_wait_for_trust() raises:
    for c in [CM_BUILD, CM_RUN, CM_TEST, CM_FORMAT, CM_LSP, CM_TASKS, CM_TASK_AGAIN, CM_DOCS]:
        assert_true(trust_needed(c), String(c))
    for c in [CM_SAVE, CM_OPEN, CM_FIND, CM_EXPLORER, CM_TRUST]:
        assert_false(trust_needed(c), String(c))


def project(tag: String) raises -> String:
    var d = scratch(tag)
    _ = run_system("mkdir -p '" + d + "/proj/src' '" + d + "/other' '" + d + "/state'")
    put(d + "/proj/pixi.toml", "[tasks]\nbuild = \"echo built\"\n")
    put(d + "/proj/src/a.mojo", "def main(): pass\n")
    put(d + "/other/pixi.toml", "[tasks]\nx = \"echo x\"\n")
    return d


def new_app(d: String, cwd: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = cwd
    app.trust_enable(d + "/state/trusted")
    return app^


def test_the_question_comes_before_a_task_runs() raises:
    var d = project("ask")
    var app = new_app(d, d + "/proj")
    app.exec(CM_TASKS)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_TRUST)                  # the question, not the task list
    assert_equal(app.dlg.lines[0], "Do you trust the files in this folder?")
    assert_equal(app.dlg.lines[1], "  " + d + "/proj")
    # Enter is "Not now": nothing runs, nothing is recorded, it is asked again next time
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "Not run: the folder is not trusted (Options > Folder trust)")
    assert_false(path_exists(d + "/state/trusted"))
    app.exec(CM_TASKS)
    assert_equal(app.dlg.kind, D_TRUST)
    app.handle(key_event(KEY_ESC))                       # closing it is not a yes either
    assert_equal(app.mode, M_NORMAL)
    assert_false(app.trust_ok())
    # yes: recorded, and what was asked for goes ahead
    app.exec(CM_TASKS)
    app.dialog_button(0)
    assert_equal(read_text(d + "/state/trusted"), d + "/proj\n")
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_TASKS)
    app.handle(key_event(KEY_ESC))
    # from now on no question - also in a later start, also from a folder inside it
    app.exec(CM_TASKS)
    assert_equal(app.dlg.kind, D_TASKS)
    var later = new_app(d, d + "/proj/src")
    later.exec(CM_TASKS)
    assert_equal(later.dlg.kind, D_TASKS)
    # another project is another question
    var other = new_app(d, d + "/other")
    other.exec(CM_TASKS)
    assert_equal(other.dlg.kind, D_TRUST)
    assert_equal(other.dlg.lines[1], "  " + d + "/other")
    _ = run_system("rm -rf '" + d + "'")


def test_without_trust_nothing_is_started() raises:
    var d = project("held")
    var app = new_app(d, d + "/proj")
    app.open_path(d + "/proj/src/a.mojo")
    for c in [CM_BUILD, CM_RUN, CM_TEST, CM_FORMAT, CM_LSP, CM_DOCS]:
        app.exec(c)
        assert_equal(app.mode, M_DIALOG, String(c))
        assert_equal(app.dlg.kind, D_TRUST, String(c))
        app.handle(key_event(KEY_ENTER))
        assert_equal(app.mode, M_NORMAL)
    assert_false(app.job.active)
    assert_false(app.lsp.active())
    # the documentation lookup does not run the compiler on the folder's files either
    assert_equal(len(app.docs_of_file(d + "/proj/src/a.mojo")), 0)
    assert_equal(len(app.doc_files), 0)
    # editing, saving, searching and the explorer need no trust
    app.handle(key_event(120))
    app.exec(CM_SAVE)
    assert_equal(app.mode, M_NORMAL)
    assert_true(read_text(d + "/proj/src/a.mojo").startswith("xdef main"))
    app.exec(CM_EXPLORER)
    assert_true(app.explorer_index() >= 0)
    # where trust is not in use (tests, and by default any App that did not turn it on)
    var plain = App()
    plain.scr.resize(100, 30)
    plain.cwd = d + "/proj"
    assert_true(plain.trust_ok())
    plain.exec(CM_TASKS)
    assert_equal(plain.dlg.kind, D_TASKS)
    plain.handle(key_event(KEY_ESC))
    plain.exec(CM_TRUST)
    assert_equal(plain.status, "Folder trust is not in use here")
    _ = run_system("rm -rf '" + d + "'")


def test_project_tool_commands_wait_for_trust() raises:
    var d = project("tools")
    put(d + "/proj/.turbomojo.toml", "[tools]\ncompiler = \"/somewhere/odd/mojo\"\nlsp_server = \"/somewhere/odd/server --flag\"\n\n[editor]\ntab_width = 3\n")
    var app = new_app(d, d + "/proj")
    app.load_config()
    assert_true(app.compiler != "/somewhere/odd/mojo", app.compiler)
    assert_true(app.lsp_server != "/somewhere/odd/server --flag", app.lsp_server)
    assert_true(app.trust_held)
    assert_equal(app.tab_width, 3)                       # harmless settings of the project do apply
    var said = False
    for w in app.config_warnings:
        if w.find("not trusted") >= 0:
            said = True
    assert_true(said, "the user is told")
    # after a yes they are in use
    app.exec(CM_TRUST)
    assert_equal(app.dlg.kind, D_TRUST)
    app.dialog_button(0)
    assert_equal(app.compiler, "/somewhere/odd/mojo")
    assert_equal(app.lsp_server, "/somewhere/odd/server --flag")
    assert_false(app.trust_held)
    assert_true(app.status.find("This folder is trusted") == 0, app.status)
    # Options > Folder trust on a trusted folder offers to take it back
    app.exec(CM_TRUST)
    assert_equal(app.dlg.lines[0], "This folder is trusted:")
    app.dialog_button(0)                                 # Keep
    assert_true(app.trust_ok())
    app.exec(CM_TRUST)
    app.dialog_button(1)
    assert_false(app.trust_ok())
    assert_equal(app.status, "This folder is not trusted any more")
    assert_equal(read_text(d + "/state/trusted"), "")
    assert_true(app.compiler != "/somewhere/odd/mojo")   # held back again
    # trusted through a folder above: that is where it has to be taken back
    app.trust.add(d)
    app.exec(CM_TRUST)
    app.dialog_button(1)
    assert_true(app.status.find("through a folder above it") > 0, app.status)
    assert_true(app.trust_ok())
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
