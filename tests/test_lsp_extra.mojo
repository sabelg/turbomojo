"""Tests for language servers for other languages by configuration (P8-03,
src/lspextra.mojo, src/app_lspextra.mojo), with a real non-Mojo server: ruff's
(`ruff server`, a project dependency). The settings; F7 on a Python file starting it;
its problems underlined and on the Problems page, following an edit; Describe symbol
asked of it; F7 again stopping it; Mojo files left to the Mojo server."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from config import load_settings
from lspextra import ends_with_any
from term import wait_readable
from commands import CM_LSP, CM_HOVER
from app import *
from appstate import App, now_ns, M_HOVER
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, which, decode, to_str

comptime MS = 1000000
comptime RUFF = "[lsp.python]\ncommand = \"ruff server\"\nextensions = [\".py\", \".pyi\"]\n"


def test_the_settings() raises:
    var s = load_settings(RUFF, "")
    assert_equal(len(s.lsp_names), 1)
    assert_equal(s.lsp_names[0], "python")
    assert_equal(s.lsp_cmds[0], "ruff server")
    assert_equal(len(s.lsp_exts[0]), 2)
    assert_equal(s.lsp_langs[0], "python")                          # the name by default
    assert_equal(len(s.warnings), 0, "\n".join(s.warnings))
    # the project's file wins; mistakes are said
    var p = load_settings(RUFF, "[lsp.python]\ncommand = \"pylsp\"\nextensions = [\".py\"]\nlanguage = \"python\"\n")
    assert_equal(p.lsp_cmds[0], "pylsp")
    var bad = load_settings("[lsp.toml]\ncommand = \"taplo lsp stdio\"\n[lsp.md]\ncomand = \"x\"\nextensions = [\".md\"]\n", "")
    assert_equal(len(bad.lsp_names), 0)
    var w = "\n".join(bad.warnings)
    assert_true(w.find("lsp.toml needs a command and extensions") >= 0, w)
    assert_true(w.find("unknown setting lsp.md.comand") >= 0, w)
    assert_true(ends_with_any("/a/b.pyi", s.lsp_exts[0]))
    assert_false(ends_with_any("/a/b.mojo", s.lsp_exts[0]))


def pump(mut app: App, ms: Int):
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        _ = wait_readable(app.extra_fds(), 20)
        app.extra_tick(now_ns())


def problems_text(app: App) -> String:
    var s = String("")
    for p in app.problems_collect():
        s += p.path + ":" + String(p.line) + ": " + p.message + "\n"
    return s^


def test_a_real_python_server() raises:
    if which("ruff").byte_length() == 0:
        print("      (skipped: ruff is not on PATH)")
        return
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-lspextra-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/x.py", str_bytes("import os\n\nprint(1)\n"))
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    pass\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.apply_settings(load_settings(RUFF, ""))
    assert_equal(app.extra_for(d + "/x.py"), 0)
    assert_equal(app.extra_for(d + "/a.mojo"), -1)                   # Mojo: the Mojo server
    app.open_path(d + "/x.py")
    app.exec(CM_LSP)                                                 # F7: its own server
    assert_true(app.lsp_extra[0].client.active())
    assert_false(app.lsp.active())
    for _ in range(200):
        pump(app, 50)
        if problems_text(app).find("os") >= 0:
            break
    var t = problems_text(app)
    assert_true(t.find(d + "/x.py:1: ") >= 0 and t.find("`os`") > 0, t)
    var ei = app.find_editor(d + "/x.py")
    assert_true(len(app.wins[ei].buf.marks) >= 1)                    # underlined
    assert_equal(app.wins[ei].buf.marks[0].l1, 0)
    app.status_until = 0                                            # (after the "checking" message)
    app.draw()
    assert_true(to_str(app.scr.row_text(app.scr.h - 1)).find("LSP") >= 0)
    # an edit: the new problem comes after the pause
    app.wins[ei].buf.load(decode("import os\nimport sys\n\nprint(1)\n"))
    for _ in range(200):
        pump(app, 50)
        if problems_text(app).find("`sys`") >= 0:
            break
    assert_true(problems_text(app).find("`sys`") >= 0, problems_text(app))
    # Describe symbol is asked of it (ruff describes the rule of a noqa comment)
    assert_true(app.lsp_extra[0].client.table.hover)                  # (ruff's server describes rules)
    if True:
        app.wins[ei].buf.load(decode("import os  # noqa: F401\n"))
        pump(app, 600)
        app.wins[ei].goto(0, 21)
        app.exec(CM_HOVER)
        assert_equal(app.hover_srv, 0)
        for _ in range(100):
            pump(app, 50)
            if app.mode == M_HOVER:
                break
        assert_equal(app.mode, M_HOVER, app.status)
        app.mode = 0
    # F7 again: stopped, the marks go
    app.focus(app.find_editor(d + "/x.py"))
    app.exec(CM_LSP)
    assert_false(app.lsp_extra[0].client.active())
    assert_equal(len(app.wins[app.find_editor(d + "/x.py")].buf.marks), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
