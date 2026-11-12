"""Tests for the plugin host (P8-01, src/plugins.mojo, src/app_plugins.mojo) with the
example plugin (examples/plugins/wordcount) and three that misbehave
(tests/helpers/plugins: one dies, one never answers, one has no command): commands in
the ≡ menu with free keys only, events and the status item, the editor requests, and a
dead or silent plugin stopped while the IDE goes on."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from plugins import *
from notify import NL_WARN
from term import key_event, wait_readable, ctrl, alt, MOD_CTRL, MOD_ALT
from commands import build_registry, parse_key, CM_SAVE
from config import load_settings
from app import *
from appstate import App, now_ns
from signals import own_pid
from util import env_or, run_system, run_capture, shell_quote, write_file, str_bytes, bytes_to_str, getcwd, decode, to_str

comptime MS = 1000000


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-plugins-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d + "/plugins"))
    return d


def install(d: String, src: String):
    _ = run_system("cp -r " + shell_quote(getcwd() + "/" + src) + " " + shell_quote(d + "/plugins/"))


def test_finding_and_registering() raises:
    var d = scratch("find")
    install(d, "examples/plugins/wordcount")
    install(d, "tests/helpers/plugins/broken")
    var warn = List[String]()
    var ps = find_plugins(d + "/plugins", warn)
    assert_equal(len(ps), 1)
    assert_equal(ps[0].name, "wordcount")
    assert_equal(ps[0].command, "python3 plugin.py")
    assert_equal(len(warn), 1)
    assert_true(warn[0].find("broken/plugin.toml: no command to start") >= 0, warn[0])
    var none = List[String]()
    assert_equal(len(find_plugins(d + "/nothing-here", none)), 0)
    # registering: the ≡ menu, a free key, not a taken one
    ps[0].state = PL_READY
    ps[0].cmds.append(PluginCmd("a", "Do ~a~", "", "Ctrl-Alt-W"))
    ps[0].cmds.append(PluginCmd("b", "Do b", "", "F2"))
    var reg = build_registry()
    var w = register_plugins(reg, ps)
    assert_equal(len(w), 1)
    assert_true(w[0].startswith("plugin wordcount: F2 is taken"), w[0])
    assert_equal(reg.find_key(parse_key("Ctrl-Alt-W")), plugin_cmd_id(0, 0))
    assert_equal(reg.find_key(parse_key("F2")), CM_SAVE)              # not taken away
    assert_equal(reg.layout[len(reg.layout) - 1].menu, 0)
    _ = run_system("rm -rf " + shell_quote(d))


def pump(mut app: App, ms: Int):
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        _ = wait_readable(app.plugin_fds(), 20)
        app.plugins_tick(now_ns())


def menu_has(app: App, label: String) -> Bool:
    for it in app.menus[0].items:
        if it.label == label:
            return True
    return False


def notice_has(app: App, text: String) -> Bool:
    for n in app.notes.notices:
        if (n.title + ": " + n.text).find(text) >= 0:
            return True
    return False


def test_the_example_plugin_and_the_bad_ones() raises:
    var d = scratch("app")
    install(d, "examples/plugins/wordcount")
    install(d, "tests/helpers/plugins/crasher")
    install(d, "tests/helpers/plugins/silent")
    _ = write_file(d + "/a.txt", str_bytes("one two three\nfour\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.plugins_dir = d + "/plugins"
    app.plugins_start()
    assert_equal(len(app.plugins), 3)
    for _ in range(200):
        pump(app, 50)
        if menu_has(app, "Count ~w~ords") and menu_has(app, "Crash now"):
            break
    assert_true(menu_has(app, "Count ~w~ords"), "the example plugin's commands are in the ≡ menu")
    assert_true(menu_has(app, "Insert today's ~d~ate"))
    assert_true(notice_has(app, "F2 is taken, so Crash now has no key"))
    # an event: the status item follows the file
    app.open_path(d + "/a.txt")
    for _ in range(100):
        pump(app, 50)
        if app.plugins_status() == "4 words  ":
            break
    assert_equal(app.plugins_status(), "4 words  ")
    app.status_until = 0                                            # (after the "Loaded" message)
    app.draw()
    assert_true(to_str(app.scr.row_text(app.scr.h - 1)).find("4 words") > 0)
    # its command, by its key: it asks for the text and notifies
    app.handle(key_event(parse_key("Ctrl-Alt-W")))
    for _ in range(100):
        pump(app, 50)
        if notice_has(app, "Word count: 4 words, 2 lines in a.txt"):
            break
    assert_true(notice_has(app, "Word count: 4 words, 2 lines in a.txt"))
    # editor/insert: the date at the cursor
    var today = String(bytes_to_str(run_capture("date +%F").out).strip())
    for k in range(len(app.reg.cmds)):
        if app.reg.cmds[k].name == "plugin.wordcount.date":
            app.exec(app.reg.cmds[k].id)
    for _ in range(100):
        pump(app, 50)
        if to_str(app.wins[app.top()].buf.all_text()).startswith(today):
            break
    assert_true(to_str(app.wins[app.top()].buf.all_text()).startswith(today + "one two"), to_str(app.wins[app.top()].buf.all_text()))
    # the silent one: stopped when it has not answered in time
    app.plugins_tick(now_ns() + (PLUGIN_INIT_MS + 1000) * MS)
    assert_true(notice_has(app, "Plugin silent stopped: it did not answer within 10 s"))
    # the crasher dies on its command: stopped, its item gone, the IDE and the others go on
    var crash_id = -1
    for k in range(len(app.reg.cmds)):
        if app.reg.cmds[k].name == "plugin.crasher.boom":
            crash_id = app.reg.cmds[k].id
    assert_true(crash_id > 0)
    app.exec(crash_id)
    for _ in range(100):
        pump(app, 50)
        if not menu_has(app, "Crash now"):
            break
    assert_false(menu_has(app, "Crash now"))
    assert_true(notice_has(app, "Plugin crasher stopped: it ended"))
    app.exec(crash_id)
    assert_equal(app.status, "The plugin crasher is not running (it ended)")
    assert_true(menu_has(app, "Count ~w~ords"))                        # the others still there
    app.draw()
    app.plugins_stop()
    assert_equal(len(app.plugin_fds()), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_switched_off() raises:
    var d = scratch("off")
    install(d, "examples/plugins/wordcount")
    var app = App()
    app.apply_settings(load_settings("[tools]\nplugins = false\n", ""))
    app.plugins_dir = d + "/plugins"
    app.plugins_start()
    assert_equal(len(app.plugins), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
