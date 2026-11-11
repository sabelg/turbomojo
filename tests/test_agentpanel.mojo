"""Tests for the agent panel (src/agentchat.mojo, src/app_agent.mojo): the conversation
model, mentions, and the panel in the IDE talking to the scripted ACP agent
(tests/helpers/fake_acp_agent.py)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from agentchat import *
from acp import AS_READY, AS_FAILED
from term import wait_readable, key_event, KEY_ENTER, KEY_ESC, KEY_BACKSPACE, KEY_PGUP, ctrl, fkey, MOD_CTRL, MOD_SHIFT
from app import *
from appstate import App, now_ns, M_NORMAL, M_DIALOG
from window import WK_EDITOR, WK_AGENT
from commands import CM_AGENT, CM_AGENT_MENTION
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, decode, to_str, getcwd, read_file, bytes_to_str

comptime MS = 1000000


def test_conversation_model() raises:
    var c = AgentChat()
    c.user("Fix the bug")
    c.chunk(CE_AGENT, "I will ")
    c.chunk(CE_AGENT, "look.")
    assert_equal(len(c.entries), 2)
    assert_equal(c.entries[1].text, "I will look.")
    var places = List[String]()
    places.append("/p/a.mojo:3")
    c.tool("t1", "Read a.mojo", "pending", places)
    var diffs = List[String]()
    diffs.append("/p/a.mojo")
    c.tool_update("t1", "", "completed", "3 lines", diffs)
    c.tool_update("t1", "", "", "", diffs)           # a diff named twice is listed once
    assert_equal(c.entries[2].status, "completed")
    assert_equal(len(c.entries[2].detail), 2)
    var plan = List[String]()
    plan.append("[pending] Fix it")
    c.plan(plan)
    plan[0] = "[completed] Fix it"
    c.plan(plan)                                     # replaces the plan just shown
    assert_equal(len(c.entries), 4)
    c.chunk(CE_AGENT, "Done.")
    var md = c.markdown("Fake Agent")
    assert_true(md.startswith("**You**\n\nFix the bug\n\n**Fake Agent**\n\nI will look."), md)
    assert_true(md.find("- ✓ Read a.mojo *(completed)*\n  - `/p/a.mojo:3`\n  - `changes /p/a.mojo`\n  - 3 lines") > 0, md)
    assert_true(md.find("**Plan**\n\n- ✓ Fix it") > 0, md)
    assert_equal(md.find("**Fake Agent**", 30), -1)  # one heading for the agent's turn
    assert_true(md.endswith("Done."))
    # a turn that ends leaves no call running
    c.tool("t2", "Run tests", "in_progress", List[String]())
    c.cancel_open_tools()
    assert_equal(c.entries[len(c.entries) - 1].status, "cancelled")
    # thinking is quoted
    c.chunk(CE_THOUGHT, "hmm\nwell")
    assert_true(c.markdown("").endswith("> *thinking*\n> hmm\n> well"))


def test_mentions() raises:
    var m = find_mentions("explain @src/a.mojo:2-3, and @b.mojo. Not mail@x.y or @ alone; @c.mojo:7")
    assert_equal(len(m), 3)
    assert_equal(m[0].path, "src/a.mojo")
    assert_equal(m[0].first, 2)
    assert_equal(m[0].last, 3)
    assert_equal(m[1].path, "b.mojo")
    assert_equal(m[1].first, 0)
    assert_equal(m[2].first, 7)
    assert_equal(m[2].last, 7)
    assert_equal(find_mentions("@x:9-2")[0].first, 0)  # backwards: the whole file
    assert_equal(lines_of("a\nb\nc\nd\n", 2, 3), "b\nc\n")
    assert_equal(lines_of("a\nb\n", 0, 0), "a\nb\n")
    assert_equal(mime_for("x.mojo"), "text/x-mojo")


# ------------------------------------------------------------ in the IDE
def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-agentpanel-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def agent_cmd(log: String, mode: String) -> String:
    return "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(log) + (" " + mode if mode.byte_length() > 0 else String(""))


def pump(mut app: App, until: String, idle: Bool = True, ms: Int = 10000) raises:
    """Run the agent's part of the event loop until the conversation has `until` (and,
    with `idle`, the turn is over)."""
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        var fds = List[Int]()
        if app.agent.fd() >= 0:
            fds.append(app.agent.fd())
        _ = wait_readable(fds, 20)
        app.agent_tick(now_ns())
        if app.chat.markdown(app.agent.agent_name).find(until) >= 0 and not (idle and app.agent.busy()):
            app.draw()
            return
    assert_true(False, "the conversation never had \"" + until + "\":\n" + app.chat.markdown(app.agent.agent_name))


def type_text(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))


def screen(app: App) -> String:
    return to_str(app.scr.to_text())


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.project_dir = d
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    print(1)\n    print(2)\n"))
    app.open_path(d + "/a.mojo")
    return app^


def test_panel_talks_to_the_agent() raises:
    var d = scratch("talk")
    var app = ide(d)
    app.agent_command = agent_cmd(d + "/log", "")
    assert_equal(app.reg.find_key(fkey(11) | MOD_CTRL), CM_AGENT)
    app.handle(key_event(fkey(11) | MOD_CTRL))
    var ai = app.agent_index()
    assert_true(ai >= 0)
    assert_equal(app.top(), ai)
    assert_equal(app.wins[ai].x + app.wins[ai].w, 120)        # at the right edge
    var ei = app.find_editor(d + "/a.mojo")
    assert_equal(app.wins[ei].x + app.wins[ei].w, app.wins[ai].x)   # the editor made room
    pump(app, "Connected to Fake Agent")
    assert_equal(app.agent.state, AS_READY)
    # a prompt typed in the panel; the answer streams in and is shown
    type_text(app, "hello")
    app.draw()
    assert_true(screen(app).find("› hello") > 0)
    app.handle(key_event(KEY_ENTER))
    assert_equal(len(app.agent_input), 0)
    pump(app, "Hello")
    var s = screen(app)
    assert_true(s.find("You") > 0 and s.find("Hello") > 0, s)
    assert_true(s.find("thinking") > 0, s)
    assert_equal(app.wins[app.agent_index()].title, "Fake Agent")     # (not working any more)
    # tool calls and the plan
    type_text(app, "tool")
    app.handle(key_event(KEY_ENTER))
    pump(app, "Reading a.mojo *(completed)*")
    # a permission request is refused for now, and said so
    type_text(app, "perm")
    app.handle(key_event(KEY_ENTER))
    pump(app, "told: selected reject")
    assert_true(app.chat.markdown("").find("The agent asked to Write b.mojo: refused") > 0)
    # Esc stops a turn that runs; another Esc goes back to the editor
    type_text(app, "slow")
    app.handle(key_event(KEY_ENTER))
    pump(app, "tick 1", False)
    app.handle(key_event(KEY_ESC))
    pump(app, "*stopped*")
    assert_false(app.agent.busy())
    app.handle(key_event(KEY_ESC))
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    # Ctrl-F11 from the editor: to the panel; from the panel: it closes (the agent stays)
    app.handle(key_event(fkey(11) | MOD_CTRL))
    assert_equal(app.wins[app.top()].kind, WK_AGENT)
    app.handle(key_event(fkey(11) | MOD_CTRL))
    assert_equal(app.agent_index(), -1)
    assert_equal(app.agent.state, AS_READY)
    ei = app.find_editor(d + "/a.mojo")
    assert_equal(app.wins[ei].w, 120)
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_mentions_send_the_editors_text() raises:
    var d = scratch("mention")
    var app = ide(d)
    app.agent_command = agent_cmd(d + "/log", "")
    var ei = app.find_editor(d + "/a.mojo")
    # an unsaved change, then lines 2-3 selected and mentioned with Shift-F11
    app.wins[ei].buf.load(decode("def main():\n    print(10)\n    print(2)\n"))
    app.wins[ei].ar = 1
    app.wins[ei].ac = 0
    app.wins[ei].cr = 3
    app.wins[ei].cc = 0
    app.wins[ei].sel = True
    assert_equal(app.reg.find_key(fkey(11) | MOD_SHIFT), CM_AGENT_MENTION)
    app.handle(key_event(fkey(11) | MOD_SHIFT))
    assert_equal(app.wins[app.top()].kind, WK_AGENT)
    assert_equal(to_str(app.agent_input), "@a.mojo:2-3 ")
    pump(app, "Connected")
    type_text(app, "explain")
    app.handle(key_event(KEY_ENTER))
    pump(app, "got resource")
    var md = app.chat.markdown("")
    assert_true(md.find("got resource file://" + d + "/a.mojo#L2-L3 (text/x-mojo):     print(10)\n    print(2)\n|") > 0, md)
    # a file that does not exist is left as text
    type_text(app, "and @nothere.mojo")
    app.handle(key_event(KEY_ENTER))
    pump(app, "you said: and @nothere.mojo")
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_the_agent_is_put_in_its_asking_mode() raises:
    var d = scratch("mode")
    var app = ide(d)
    app.agent_command = agent_cmd(d + "/log", "")
    app.exec(CM_AGENT)
    pump(app, "Mode: Manual")
    assert_equal(app.agent.mode, "default")
    assert_true(app.chat.markdown("").find("Connected to Fake Agent") >= 0 and app.chat.markdown("").find("mode Auto") > 0)
    var log = bytes_to_str(read_file(d + "/log"))
    assert_true(log.find("\"method\":\"session/set_mode\",\"params\":{\"sessionId\":\"sess_fake_1\",\"modeId\":\"default\"}") > 0, log)
    app.agent.stop()
    # tools.agent_mode = "": the agent's own mode stays
    var app2 = ide(d)
    app2.agent_command = agent_cmd(d + "/log2", "")
    app2.agent_mode = ""
    app2.exec(CM_AGENT)
    pump(app2, "Connected")
    assert_equal(app2.agent.mode, "auto")
    assert_true(bytes_to_str(read_file(d + "/log2")).find("set_mode") < 0)
    app2.agent.stop()
    # a mode the agent does not have
    var app3 = ide(d)
    app3.agent_command = agent_cmd(d + "/log3", "")
    app3.agent_mode = "turbo"
    app3.exec(CM_AGENT)
    pump(app3, "The agent has no mode \"turbo\"")
    app3.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_without_an_agent() raises:
    var d = scratch("none")
    var app = ide(d)
    app.agent_command = ""
    app.exec(CM_AGENT)
    assert_true(app.chat.markdown("").find("No agent is set up") >= 0)
    assert_false(app.agent.active())
    type_text(app, "hello")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "No agent is set up (tools.agent)")
    # an agent that is not there: said in the conversation
    app.agent_command = "/nonexistent/agent-program"
    app.handle(key_event(KEY_ENTER))
    pump(app, "The agent is not running")
    assert_equal(app.agent.state, AS_FAILED)
    # in a folder that is not trusted the question comes first
    var app2 = ide(d)
    app2.agent_command = agent_cmd(d + "/log", "")
    app2.trust_enforced = True
    app2.exec(CM_AGENT)
    assert_equal(app2.mode, M_DIALOG)
    assert_false(app2.agent.active())
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
