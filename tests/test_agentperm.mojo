"""Tests for the permission prompts and the session's allow list (P6-04,
src/app_agent.mojo, src/app_agentsvc.mojo) with the scripted agent."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from agentsvc import allow_key, option_of
from acp import AS_READY, AS_STOPPED
from term import wait_readable, key_event, KEY_ENTER, KEY_ESC
from app import *
from appstate import App, now_ns
from window import WK_EDITOR, WK_AGENT
from commands import CM_AGENT
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, decode, to_str, getcwd, read_file, bytes_to_str, path_exists

comptime MS = 1000000


def test_allow_keys() raises:
    assert_equal(allow_key("execute", "`git status --short`"), "execute:git status --short")
    assert_equal(allow_key("execute", "echo hi"), "execute:echo hi")
    assert_true(allow_key("execute", "git push") != allow_key("execute", "git status --short"))
    assert_equal(allow_key("edit", "Write b.mojo"), "edit")
    assert_equal(allow_key("", "x"), "other")
    var kinds = List[String]()
    kinds.append("allow_once")
    kinds.append("reject_once")
    var ids = List[String]()
    ids.append("a")
    ids.append("r")
    assert_equal(option_of(kinds, ids, "reject_once"), "r")
    assert_equal(option_of(kinds, ids, "allow_always"), "")


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-agentperm-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def md(app: App) -> String:
    return app.chat.markdown(app.agent.agent_name)


def pump(mut app: App, until: String, idle: Bool = True, ms: Int = 10000) raises:
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        var fds = List[Int]()
        if app.agent.fd() >= 0:
            fds.append(app.agent.fd())
        for f in app.agent_term_fds():
            fds.append(f)
        _ = wait_readable(fds, 20)
        app.agent_tick(now_ns())
        if md(app).find(until) >= 0 and not (idle and app.agent.busy()):
            app.draw()
            return
    assert_true(False, "the conversation never had \"" + until + "\":\n" + md(app))


def count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + 1)
    return n


def say(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.project_dir = d
    _ = write_file(d + "/a.mojo", str_bytes("one\n"))
    app.open_path(d + "/a.mojo")
    app.agent_command = "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(d + "/log")
    app.exec(CM_AGENT)
    pump(app, "Connected")
    return app^


def test_permission_prompts() raises:
    var d = scratch("prompt")
    var app = ide(d)
    # asked in the panel; the prompt gives way to the question; typing is not taken
    say(app, "permrun")
    pump(app, "The agent asks to `git status --short` (execute)", False)
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("Allow `git status") > 0)
    app.handle(key_event(120))
    assert_equal(len(app.agent_input), 0)
    app.handle(key_event(121))                      # Y: once
    pump(app, "told: selected yes")
    assert_true(md(app).find("Allowed once: `git status --short`") > 0)
    # once is once: asked again
    say(app, "permrun")
    pump(app, "The agent asks to `git status --short`", False)
    assert_equal(count(md(app), "The agent asks to `git status --short`"), 2)
    app.handle(key_event(97))                       # A: for this session
    pump(app, "Allowed for this session: execute:git status --short")
    # now answered without a question, with the allow-once option
    say(app, "permrun")
    pump(app, "Allowed (this session): `git status --short`")
    assert_equal(count(md(app), "The agent asks to `git status --short`"), 2)
    assert_equal(count(md(app), "told: selected yes"), 3)
    # another kind is still asked; Esc while it waits stops the turn and cancels it
    say(app, "perm")
    pump(app, "The agent asks to Write b.mojo (edit)", False)
    app.handle(key_event(KEY_ESC))
    pump(app, "told: cancelled")
    assert_equal(len(app.agent_perms), 0)
    # a new session allows nothing
    app.agent.stop()
    app.chat.clear()                                # (so the waits below see only the new session)
    app.agent_start()
    pump(app, "Mode: Manual")
    assert_equal(len(app.agent_allowed), 0)
    say(app, "permrun")
    pump(app, "The agent asks to `git status --short`", False)
    app.handle(key_event(78))                       # N
    pump(app, "told: selected no")
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_commands_and_writes_allowed_for_the_session() raises:
    var d = scratch("allow")
    var app = ide(d)
    say(app, "run echo first")
    pump(app, "A always (this session)", False)
    app.handle(key_event(97))                       # A: run it, and this command from now on
    pump(app, "exit 0 truncated False: first")
    say(app, "run echo first")
    pump(app, "Running (allowed this session): `echo first`")      # no question this time
    assert_equal(count(md(app), "exit 0 truncated False: first"), 2)
    say(app, "run echo second")                      # another command: asked
    pump(app, "The agent wants to run `echo second`", False)
    app.handle(key_event(110))
    pump(app, "run refused")
    # S in the proposal view: this write and the later ones go in
    say(app, "write " + d + "/a.mojo two\\n")
    pump(app, "proposes changes to a.mojo", False)
    assert_true(app.gd_proposal)
    app.handle(key_event(115))
    pump(app, "write: ok")
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")), "two\n")
    say(app, "write " + d + "/a.mojo three\\n")
    pump(app, "Writing (allowed this session): a.mojo")
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")), "three\n")
    assert_false(app.gd_proposal)
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_agent_stops_when_trust_goes() raises:
    var d = scratch("trust")
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.project_dir = d
    app.trust_enforced = True
    app.trust.add(d)
    app.agent_command = "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(d + "/log")
    app.exec(CM_AGENT)
    pump(app, "Connected")
    _ = app.trust.remove(d)
    app.agent_tick(now_ns())
    assert_equal(app.agent.state, AS_STOPPED)
    assert_true(md(app).find("The agent was stopped: the folder is not trusted any more") > 0)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
