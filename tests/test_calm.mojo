"""Tests for calm by default (P10-05): a screen reader means no animation even when
reduced motion is switched off; notices and background events never take the focus,
change the mode or move the terminal's cursor; the agent's questions and proposals,
and a panel a plugin opens by itself, wait for the user (a notice says the key) while
another window is in front or the user is typing; the build's result box and the jump
to the Message window come only to someone who waited for the build; reports that are
not decisions are notices, not boxes."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from term import wait_readable, key_event, KEY_ENTER
from app import *
from appstate import App, now_ns, M_NORMAL, M_DIALOG
from window import WK_EDITOR, WK_AGENT, WK_PANEL
from commands import CM_AGENT, CM_NEW, CM_MESSAGE
from config import load_settings
from notify import NL_INFO, NL_DONE, NL_WARN, NL_ERROR
from json import json_parse
from plugins import Plugin
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, decode, to_str, getcwd

comptime MS = 1000000


def test_a_screen_reader_means_no_animation() raises:
    var app = App()
    app.apply_settings(load_settings("[ui]\nscreen_reader = true\nreduced_motion = false\n", ""))
    assert_true(app.reduce_motion)
    app.apply_settings(load_settings("[ui]\nscreen_reader = false\nreduced_motion = false\n", ""))
    assert_false(app.reduce_motion)


def editor_app() raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode("def main():\n    var x = 1\n"))
    app.wins[app.top()].goto(1, 6)
    app.draw()
    return app^


def notice_shown(app: App, title: String) -> Bool:
    return to_str(app.scr.to_text()).find(title) >= 0


def test_notices_leave_the_focus_and_the_cursor_alone() raises:
    var app = editor_app()
    var top = app.top()
    var cx = app.scr.cx
    var cy = app.scr.cy
    assert_true(app.scr.cvis)
    app.notify(NL_INFO, "Indexing done", "412 symbols")
    app.notify(NL_ERROR, "The language server stopped", "exit 1")
    app.notify(NL_DONE, "Tests passed", "12 tests", True)
    app.draw()
    assert_true(notice_shown(app, "The language server stopped"))     # (the toasts are up)
    assert_equal(app.top(), top)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.scr.cx, cx)
    assert_equal(app.scr.cy, cy)
    assert_true(app.scr.cvis)
    # while typing: held, and still nothing moves; a key goes where it went
    app.handle(key_event(122))                                        # "z" into the editor
    app.draw()
    cx = app.scr.cx
    app.notify(NL_WARN, "The agent has finished", "")
    app.draw()
    assert_false(notice_shown(app, "The agent has finished"))
    assert_equal(app.top(), top)
    assert_equal(app.scr.cx, cx)
    app.handle(key_event(121))
    assert_equal(to_str(app.wins[top].buf.line(1)), "    vazyr x = 1")


def test_who_may_take_the_focus() raises:
    var app = editor_app()
    var ei = app.top()
    assert_false(app.may_take_focus(-1))
    assert_true(app.may_take_focus(ei))
    app.exec(CM_NEW)
    assert_false(app.may_take_focus(ei))                # another window is in front
    app.focus(ei)
    app.typed_ns = now_ns()
    assert_false(app.may_take_focus(ei))                # typing
    # the build: waited for, or typed through
    app.job.t0 = now_ns()
    app.typed_ns = 0
    assert_true(app.waited_for_job())
    app.typed_ns = now_ns()
    assert_false(app.waited_for_job())


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-calm-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def test_the_build_box_only_for_who_waited() raises:
    var d = scratch("build")
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    pass\n"))
    for waited in [True, False]:
        var app = App()
        app.scr.resize(100, 30)
        app.cwd = d
        app.open_path(d + "/a.mojo")
        app.exec(CM_MESSAGE)                            # (a build starts with the Message window)
        app.focus(app.find_editor(d + "/a.mojo"))
        var ei = app.top()
        app.job.path = d + "/a.mojo"
        app.job.t0 = now_ns()
        app.typed_ns = 0 if waited else now_ns()
        app.finish_build(1 << 8, 0.5)                   # failed
        assert_true(len(app.notes.notices) >= 1)
        if waited:
            assert_equal(app.mode, M_DIALOG)            # the "Compiling" box
            assert_equal(app.top(), app.msg_index())    # and the errors behind it
        else:
            assert_equal(app.mode, M_NORMAL)
            assert_equal(app.top(), ei)                 # still in the editor
    _ = run_system("rm -rf " + shell_quote(d))


def test_a_plugin_panel_opened_by_itself_stays_beside() raises:
    var app = editor_app()
    var ei = app.top()
    app.plugins.append(Plugin("quiet", "/nonexistent", "true"))     # (not started: only its name is used)
    var d = json_parse("{\"columns\":[]}")
    app.panel_open(0, "p", "Panel", False, d, d.get(0, "columns"))
    var pw = -1
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_PANEL:
            pw = i
    assert_true(pw >= 0, "no panel")
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    # the answer to the plugin's command the user just ran comes to the front
    app.plugin_asked = 0
    app.plugin_asked_ns = now_ns()
    app.panel_open(0, "p", "Panel", False, d, d.get(0, "columns"))
    assert_equal(app.wins[app.top()].kind, WK_PANEL)
    _ = ei


def md(app: App) -> String:
    return app.chat.markdown(app.agent.agent_name)


def pump(mut app: App, until: String, idle: Bool = True, ms: Int = 10000) raises:
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        var fds = List[Int]()
        if app.agent.fd() >= 0:
            fds.append(app.agent.fd())
        _ = wait_readable(fds, 20)
        app.agent_tick(now_ns())
        if md(app).find(until) >= 0 and not (idle and app.agent.busy()):
            app.draw()
            return
    assert_true(False, "the conversation never had \"" + until + "\":\n" + md(app))


def say(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))


def notice_has(app: App, text: String) -> Bool:
    for n in app.notes.notices:
        if (n.title + " " + n.text).find(text) >= 0:
            return True
    return False


def test_the_agent_waits_for_the_user() raises:
    var d = scratch("agent")
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.project_dir = d
    _ = write_file(d + "/a.mojo", str_bytes("one\n"))
    app.open_path(d + "/a.mojo")
    app.agent_command = "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(d + "/log")
    app.exec(CM_AGENT)
    pump(app, "Connected")
    # asked to run a command while the editor is in front: a notice, not the panel
    say(app, "permrun")
    app.focus(app.find_editor(d + "/a.mojo"))
    var ei = app.top()
    pump(app, "The agent asks to `git status --short`", False)
    assert_equal(app.top(), ei)
    assert_true(notice_has(app, "to answer"), "no notice with the key")
    app.handle(key_event(121))                      # "y" is typed into the editor
    assert_true(to_str(app.wins[ei].buf.line(0)).find("y") >= 0)
    assert_equal(len(app.agent_perms), 1)           # and does not answer the agent
    app.focus(app.agent_index())
    app.handle(key_event(78))                       # N, in the panel
    pump(app, "told: selected no")
    # a proposal while the editor is in front: no diff view comes up under the keys
    say(app, "write " + d + "/a.mojo one\\nTWO\\n")
    app.focus(app.find_editor(d + "/a.mojo"))
    pump(app, "The agent proposes changes to a.mojo", False)
    assert_equal(app.gd_index(), -1)
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    assert_true(notice_has(app, "then Enter, to review it"))
    app.focus(app.agent_index())
    app.handle(key_event(KEY_ENTER))                # Enter in the empty prompt shows it
    assert_true(app.gd_index() >= 0)
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
