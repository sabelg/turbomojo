"""Tests for Help > Check setup (P11-05): the list's lines for what is there, missing or
could be better (Mojo and its release, pixi, the language server, the debugger, the
docs, the terminal's colours and keys), what Fix does for each, and the first run
showing the list when something is missing."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from setupcheck import *
from caps import COLOR_TRUE, COLOR_256
from term import key_event, KEY_ENTER, KEY_ESC
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_SETUP, D_INFO, D_THEME, D_NEW_PROJECT, D_DOCFETCH
from commands import CM_SETUP, build_registry
from signals import own_pid
from util import env_or, run_system, decode, to_str


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-setup-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def tool(path: String, says: String) raises:
    with open(path, "w") as f:
        f.write("#!/bin/sh\necho '" + says + "'\n")
    _ = run_system("chmod +x '" + path + "'")


def all_there() -> SetupFacts:
    var f = SetupFacts()
    f.mojo_out = "Mojo 1.2.0 (2016d0cd)"
    f.built_with = "Mojo 1.2.0 (2016d0cd)"
    f.pixi = "/x/pixi"
    f.lsp = "/x/mojo-lsp-server"
    f.dap = "/x/mojo-lldb-dap"
    f.docs = True
    f.probed = True
    f.color = COLOR_TRUE
    f.kitty_keys = True
    return f^


def find(items: List[SetupItem], name: String) -> Int:
    for k in range(len(items)):
        if items[k].name == name:
            return k
    return -1


def test_the_lines() raises:
    var ok = setup_items(all_there())
    assert_equal(len(ok), 7)
    for it in ok:
        assert_equal(it.level, SC_OK, it.name + ": " + it.detail)
    assert_false(setup_needs_attention(ok))
    assert_equal(ok[0].detail, "1.2.0")
    # no Mojo: File > New project brings it - when there is pixi
    var f = all_there()
    f.mojo_out = ""
    var a = setup_items(f)
    assert_equal(a[0].level, SC_MISSING)
    assert_equal(a[0].action, SC_FIX_PROJECT)
    assert_true(setup_needs_attention(a))
    f.pixi = ""
    var b = setup_items(f)
    assert_equal(b[0].action, SC_FIX_NONE)
    assert_true(b[0].fix.find("Install pixi") == 0, b[0].fix)
    assert_equal(b[find(b, "pixi")].level, SC_NOTE)
    assert_true(b[find(b, "pixi")].fix.find("pixi.sh/install.sh") >= 0)
    # another release than TurboMojo's: a note, and the compiler setting to fix it
    var m = all_there()
    m.mojo_out = "Mojo 1.3.0 (ab12)"
    var c = setup_items(m)
    assert_equal(c[0].level, SC_NOTE)
    assert_equal(c[0].action, SC_FIX_COMPILER)
    assert_true(c[0].detail.find("1.3.0") == 0 and c[0].detail.find("1.2.0") > 0, c[0].detail)
    # the tools that come with Mojo; the docs (optional)
    var t = all_there()
    t.lsp = ""
    t.dap = ""
    t.docs = False
    var d = setup_items(t)
    assert_equal(d[find(d, "Language server")].level, SC_MISSING)
    assert_equal(d[find(d, "Debugger")].level, SC_MISSING)
    assert_equal(d[find(d, "Debugger")].action, SC_FIX_PROJECT)
    assert_equal(d[find(d, "Documentation")].level, SC_NOTE)
    assert_equal(d[find(d, "Documentation")].action, SC_FIX_DOCS)
    # the terminal: 256 colours and no kitty keys are notes, with tmux's own settings
    var u = all_there()
    u.color = COLOR_256
    u.kitty_keys = False
    u.tmux = True
    var e = setup_items(u)
    assert_equal(e[find(e, "Colours")].level, SC_NOTE)
    assert_true(e[find(e, "Colours")].fix.find("RGB") >= 0)
    assert_true(e[find(e, "Keys")].fix.find("extended-keys") >= 0)
    assert_false(setup_needs_attention(e))         # notes alone: nothing missing
    var n = all_there()
    n.probed = False
    var g = setup_items(n)
    assert_equal(len(g), 6)
    assert_equal(g[5].name, "Terminal")
    # a word, not colour alone
    assert_equal(sc_mark(SC_MISSING), "MISSING")


def an_app(d: String) raises -> App:
    tool(d + "/mojo", "Mojo 1.2.0 (2016d0cd)")
    tool(d + "/lsp", "lsp")
    tool(d + "/dap", "dap")
    tool(d + "/pixi", "pixi")
    var app = App()
    app.scr.resize(110, 30)
    app.cwd = d
    app.compiler = d + "/mojo"
    app.lsp_server = d + "/lsp"
    app.debug_adapter = d + "/dap"
    app.pixi_cmd = d + "/pixi"
    app.doc_home = d + "/docs"
    return app^


def test_the_dialog_and_its_fixes() raises:
    var d = scratch("dialog")
    var app = an_app(d)
    assert_true(build_registry().index_of_name("help.checkSetup") >= 0)
    app.exec(CM_SETUP)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_SETUP)
    assert_equal(len(app.dlg.items), 6)
    assert_true(app.dlg.items[0].startswith("Mojo") and app.dlg.items[0].find("ok") > 0 and app.dlg.items[0].endswith("1.2.0"), app.dlg.items[0])
    assert_true(app.dlg.items[2].find("ok") > 0 and app.dlg.items[2].endswith(d + "/lsp"), app.dlg.items[2])
    assert_true(app.dlg.lines[0].find("Everything") == 0, app.dlg.lines[0])
    # the docs are not there: Fix offers the download
    app.dlg.list_sel = 4
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.dlg.kind, D_DOCFETCH)
    app.handle(key_event(KEY_ESC))
    # no pixi: Fix copies its installer's command and shows it
    app.pixi_cmd = d + "/no-such-pixi"
    app.exec(CM_SETUP)
    assert_true(app.dlg.items[1].find("note") > 0, app.dlg.items[1])
    app.dlg.list_sel = 1
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.dlg.kind, D_INFO)
    assert_true(app.dlg.lines[0].find("pixi.sh/install.sh") >= 0, app.dlg.lines[0])
    assert_equal(to_str(app.clipboard), "curl -fsSL https://pixi.sh/install.sh | sh")
    app.handle(key_event(KEY_ESC))
    # no language server: Fix opens File > New project (pixi install brings it)
    app.pixi_cmd = d + "/pixi"
    app.lsp_server = "no-such-lsp-for-turbomojo"
    app.exec(CM_SETUP)
    assert_true(app.dlg.items[2].find("MISSING") > 0, app.dlg.items[2])
    assert_true(app.dlg.lines[0].find("1 piece missing") == 0, app.dlg.lines[0])
    # Again looks once more: the server is back
    app.lsp_server = d + "/lsp"
    app.dialog_button(1)
    assert_equal(app.dlg.kind, D_SETUP)
    assert_true(app.dlg.items[2].find("ok") > 0, app.dlg.items[2])
    app.lsp_server = "no-such-lsp-for-turbomojo"
    app.dialog_button(1)
    app.dlg.list_sel = 2
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.dlg.kind, D_NEW_PROJECT)
    app.handle(key_event(KEY_ESC))
    # an ok line: nothing to do
    app.exec(CM_SETUP)
    app.dlg.list_sel = 0
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.status.find("nothing to fix") > 0, app.status)
    _ = run_system("rm -rf '" + d + "'")


def test_the_first_run_shows_what_is_missing() raises:
    var d = scratch("first")
    _ = run_system("mkdir -p '" + d + "/proj' && touch '" + d + "/proj/pixi.toml'")
    # a project, no debugger: the theme, then the list
    var app = an_app(d)
    app.cwd = d + "/proj"
    app.debug_adapter = "no-such-dap-for-turbomojo"
    app.config_path = ""
    app.theme_marker = d + "/asked-1"
    assert_true(app.first_run_theme())
    assert_equal(app.dlg.kind, D_THEME)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.dlg.kind, D_SETUP)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    # everything there: only the theme is asked
    var full = an_app(d)
    full.cwd = d + "/proj"
    full.config_path = ""
    full.theme_marker = d + "/asked-2"
    assert_true(full.first_run_theme())
    full.handle(key_event(KEY_ENTER))
    assert_equal(full.mode, M_NORMAL)
    # no project and no Mojo: the theme, the new project; declined - the list
    _ = run_system("mkdir -p '" + d + "/empty'")
    var bare = an_app(d)
    bare.cwd = d + "/empty"
    bare.compiler = "no-such-mojo-for-turbomojo"
    bare.config_path = ""
    bare.theme_marker = d + "/asked-3"
    assert_true(bare.first_run_theme())
    bare.handle(key_event(KEY_ENTER))
    assert_equal(bare.dlg.kind, D_NEW_PROJECT)
    bare.handle(key_event(KEY_ESC))
    assert_equal(bare.mode, M_DIALOG)
    assert_equal(bare.dlg.kind, D_SETUP)
    assert_true(bare.dlg.items[0].find("MISSING") > 0, bare.dlg.items[0])
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
