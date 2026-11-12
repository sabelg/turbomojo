"""Tests for hyperlinks on file:line references (P10-07, src/links.mojo,
src/app_links.mojo, Screen.link): references found in a row and what is not one; the
link's URI from the format, its path percent-encoded; the renderer sends OSC 8 where
links begin and end, again only when they change, never when switched off, and a cell
drawn over loses its link; in the IDE the Message window's rows link to their places
(a search hit, a build error) and other references when the file exists; the agent
panel's references to existing files are links; the settings."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from links import *
from screen import Screen
from app import *
from appstate import App, ErrLoc
from config import load_settings
from commands import CM_NEW, CM_AGENT
from signals import own_pid
from util import decode, to_str, str_bytes, bytes_to_str, write_file, run_system, shell_quote, env_or, cp_len


def refs(s: String) -> List[FileRef]:
    return find_refs(decode(s))


def test_finding_references() raises:
    var a = refs("src/a.mojo:12:5: error: use of unknown name")
    assert_equal(len(a), 1)
    assert_equal(a[0].path, "src/a.mojo")
    assert_equal(a[0].line, 12)
    assert_equal(a[0].col, 5)
    assert_equal(a[0].start, 0)
    assert_equal(a[0].end, 15)
    var b = refs("see `a.mojo:3` and /tmp/b.py:10.")
    assert_equal(len(b), 2)
    assert_equal(b[0].path, "a.mojo")
    assert_equal(b[0].col, 0)
    assert_equal(b[1].path, "/tmp/b.py")
    assert_equal(b[1].end, cp_len("see `a.mojo:3` and /tmp/b.py:10"))
    # not references: a time, a port, a URL, a word before a colon
    assert_equal(len(refs("at 12:30, localhost:8080, http://x.org:80/a, note: 3")), 1)   # (only x.org:80)
    assert_equal(len(refs("no colon a.mojo 12")), 0)
    var c = refs("crème/é.mojo:7")
    assert_equal(len(c), 1)
    assert_equal(c[0].path, "crème/é.mojo")
    assert_equal(c[0].end, 14)


def test_the_uri() raises:
    assert_equal(percent_encode_path("/tmp/a b/é.mojo"), "/tmp/a%20b/%C3%A9.mojo")
    assert_equal(link_uri("", "box", "/p/a.mojo", 3, 0), "file://box/p/a.mojo")
    assert_equal(link_uri("vscode://file{path}:{line}:{column}", "box", "/p/a b.mojo", 3, 7), "vscode://file/p/a%20b.mojo:3:7")
    assert_true(host_name().byte_length() > 0)


def test_the_renderer() raises:
    var s = Screen(30, 2)
    _ = s.text(0, 0, "see a.mojo:3 now", 0xFFFFFF, 0)
    s.link(4, 0, 8, "file://h/a.mojo")
    assert_equal(s.link_at(4, 0), "file://h/a.mojo")
    assert_equal(s.link_at(3, 0), "")
    var out = List[UInt8]()
    s.render(out)
    var esc = bytes_to_str(out)
    var on = esc.find("\x1b]8;;file://h/a.mojo\x1b\\a.mojo:3")
    var off = esc.find("\x1b]8;;\x1b\\ now")
    assert_true(on > 0 and off > on, esc)
    # the same frame again: nothing is sent
    _ = s.text(0, 0, "see a.mojo:3 now", 0xFFFFFF, 0)
    s.link(4, 0, 8, "file://h/a.mojo")
    var again = List[UInt8]()
    s.render(again)
    assert_true(bytes_to_str(again).find("]8;") < 0, bytes_to_str(again))
    # the same text without its link: the cells are sent again, outside any link
    _ = s.text(0, 0, "see a.mojo:3 now", 0xFFFFFF, 0)
    var plain = List[UInt8]()
    s.render(plain)
    assert_true(bytes_to_str(plain).find("a.mojo:3") > 0)
    assert_true(bytes_to_str(plain).find("]8;;file") < 0)
    # switched off: never sent
    var t = Screen(30, 1)
    t.hyperlinks = False
    _ = t.text(0, 0, "a.mojo:3", 0xFFFFFF, 0)
    t.link(0, 0, 8, "file://h/a.mojo")
    var none = List[UInt8]()
    t.render(none)
    assert_true(bytes_to_str(none).find("]8;") < 0)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-links-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def find_on_screen(app: App, text: String) -> Tuple[Int, Int]:
    for y in range(app.scr.h):
        var row = to_str(app.scr.row_text(y))
        var at = row.find(text)
        if at >= 0:
            return (cp_len(String(row[byte=0:at])), y)
    return (-1, -1)


def test_the_message_window() raises:
    var d = scratch("msg")
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    pritn(1)\n"))
    _ = write_file(d + "/b.mojo", str_bytes("x\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.link_host = "box"
    var out = d + "/a.mojo:2:5: error: use of unknown declaration 'pritn'\n    pritn(1)\nnote: like b.mojo:1 and gone.mojo:4\n"
    _ = app.fill_messages("Building a.mojo", str_bytes(out), "Build failed")
    app.draw()
    var at = find_on_screen(app, "a.mojo:2:5")
    assert_true(at[1] >= 0, to_str(app.scr.to_text()))
    var uri = app.scr.link_at(at[0] + 2, at[1])
    assert_equal(uri, "file://box" + percent_encode_path(d) + "/a.mojo")
    assert_equal(app.scr.link_at(at[0] + cp_len("a.mojo:2:5") + 3, at[1]), "")     # the message itself is not
    var b = find_on_screen(app, "b.mojo:1")
    assert_equal(app.scr.link_at(b[0], b[1]), "file://box" + percent_encode_path(d) + "/b.mojo")
    var g = find_on_screen(app, "gone.mojo:4")
    assert_equal(app.scr.link_at(g[0], g[1]), "")                                     # no such file
    # an editor's format with the line and column
    app.apply_settings(load_settings("[ui]\nhyperlink_format = \"vscode://file{path}:{line}:{column}\"\n", ""))
    app.link_host = "box"
    app.draw()
    at = find_on_screen(app, "a.mojo:2:5")
    assert_equal(app.scr.link_at(at[0], at[1]), "vscode://file" + percent_encode_path(d) + "/a.mojo:2:5")
    # switched off
    app.apply_settings(load_settings("[ui]\nhyperlinks = false\n", ""))
    app.draw()
    at = find_on_screen(app, "a.mojo:2:5")
    var esc = List[UInt8]()
    app.scr.render(esc)
    assert_true(bytes_to_str(esc).find("]8;;file") < 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_agent_panel() raises:
    var d = scratch("agent")
    _ = write_file(d + "/a.mojo", str_bytes("x\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.link_host = "box"
    app.agent_command = "sleep 20"                  # (never answers: the panel shows the chat only)
    app.exec(CM_AGENT)
    assert_true(app.agent_index() >= 0)
    app.chat.note("The bug is at a.mojo:1 (not in nothere.mojo:9)")
    app.draw()
    var at = find_on_screen(app, "a.mojo:1")
    assert_true(at[1] >= 0, to_str(app.scr.to_text()))
    assert_equal(app.scr.link_at(at[0], at[1]), "file://box" + percent_encode_path(d) + "/a.mojo")
    var n = find_on_screen(app, "nothere.mojo:9")
    assert_equal(app.scr.link_at(n[0], n[1]), "")
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_settings() raises:
    var s = load_settings("", "")
    assert_true(s.hyperlinks)
    assert_equal(s.hyperlink_format, "file://{host}{path}")
    var bad = load_settings("[ui]\nhyperlink_format = \"file://x\"\n", "")
    assert_equal(" | ".join(bad.warnings), "ui.hyperlink_format must contain {path}")
    assert_equal(bad.hyperlink_format, "file://{host}{path}")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
