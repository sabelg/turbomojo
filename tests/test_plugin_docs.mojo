"""Tests that docs/PLUGINS.md (P8-04) says what the plugin host does: every JSON example
parses and is JSON-RPC 2.0; every method it documents is one the host sends or answers
(src/app_plugins.mojo), and every method the host answers is documented; the minimal
plugin on the page, taken from it as it is, works as a plugin."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from json import json_parse
from term import wait_readable
from app import *
from appstate import App, now_ns
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, read_file, str_bytes, bytes_to_str, getcwd, decode, which

comptime MS = 1000000


def page() raises -> String:
    return bytes_to_str(read_file(getcwd() + "/docs/PLUGINS.md"))


def blocks(text: String, lang: String) -> List[String]:
    var out = List[String]()
    var parts = text.split("```" + lang + "\n")
    for k in range(1, len(parts)):
        var p = String(parts[k])
        out.append(String(p[byte=0:p.find("```")]))
    return out^


def headings_between(text: String, start: String, stop: String) -> List[String]:
    """The ### headings of a section: the method names."""
    var out = List[String]()
    var a = text.find("## " + start)
    var b = text.find("## " + stop)
    for raw in String(text[byte=a:b]).split("\n"):
        var l = String(raw)
        if l.startswith("### "):
            var name = String(l[byte=4:])
            var sp = name.find(" ")
            out.append(String(name[byte=0:sp]) if sp > 0 else name)
    return out^


def test_the_json_examples() raises:
    var js = blocks(page(), "json")
    assert_true(len(js) >= 14, String(len(js)))
    for j in js:
        var doc = json_parse(j)
        assert_equal(doc.str(doc.get(0, "jsonrpc"), ""), "2.0", j)
        assert_true(doc.has(0, "method") or doc.has(0, "result"), j)


def test_the_methods_are_the_hosts() raises:
    var host = bytes_to_str(read_file(getcwd() + "/src/app_plugins.mojo"))
    var to_ide = headings_between(page(), "Messages to TurboMojo", "Errors")
    var from_ide = headings_between(page(), "Messages from TurboMojo", "Messages to TurboMojo")
    assert_equal(len(to_ide), 10, "\n".join(to_ide))
    assert_equal(len(from_ide), 6, "\n".join(from_ide))
    for m in to_ide:
        assert_true(host.find("m.method == \"" + m + "\"") >= 0, "documented but not answered: " + m)
    for m in from_ide:
        assert_true(host.find("\"" + m + "\"") >= 0, "documented but never sent: " + m)
    # and the other way round: every method the host answers is documented
    var k = host.find("m.method == \"")
    while k >= 0:
        var rest = String(host[byte=k + 13:])
        var name = String(rest[byte=0:rest.find("\"")])
        assert_true(name in to_ide, "answered but not documented: " + name)
        k = host.find("m.method == \"", k + 13)


def test_the_minimal_plugin_works() raises:
    if which("python3").byte_length() == 0:
        return
    var py = blocks(page(), "python")
    assert_equal(len(py), 1)
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-plugindoc-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d + "/plugins/lines"))
    _ = write_file(d + "/plugins/lines/plugin.py", str_bytes(py[0]))
    _ = write_file(d + "/plugins/lines/plugin.toml", str_bytes("name = \"lines\"\ncommand = \"python3 plugin.py\"\n"))
    _ = write_file(d + "/a.txt", str_bytes("one\ntwo\nthree\n"))
    var app = App()
    app.scr.resize(100, 30)
    app.plugins_dir = d + "/plugins"
    app.plugins_start()
    var id = -1
    for _ in range(200):
        var end = Int(perf_counter_ns()) + 50 * MS
        while Int(perf_counter_ns()) < end:
            _ = wait_readable(app.plugin_fds(), 20)
            app.plugins_tick(now_ns())
        for c in app.reg.cmds:
            if c.name == "plugin.lines.lines":
                id = c.id
        if id > 0:
            break
    assert_true(id > 0, "the page's plugin did not register its command")
    app.open_path(d + "/a.txt")
    app.exec(id)
    for _ in range(100):
        var end = Int(perf_counter_ns()) + 50 * MS
        while Int(perf_counter_ns()) < end:
            _ = wait_readable(app.plugin_fds(), 20)
            app.plugins_tick(now_ns())
        if app.status == "3 lines":
            break
    assert_equal(app.status, "3 lines")
    app.plugins_stop()
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
