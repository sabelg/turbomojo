"""Tests for the ACP client (src/acp.mojo) and the line framing it uses (src/rpc.mojo),
against a scripted agent (tests/helpers/fake_acp_agent.py)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from acp import *
from rpc import Framer, RpcConn, RPC_REQUEST, RPC_NOTIFICATION, RPC_RESPONSE
from term import wait_readable
from signals import own_pid
from util import env_or, run_system, str_bytes, bytes_to_str, read_file, shell_quote, getcwd

comptime MS = 1000000


def now() -> Int:
    return Int(perf_counter_ns())


def test_line_framing() raises:
    var f = Framer()
    f.lines = True
    var body = List[UInt8]()
    f.feed(str_bytes("{\"a\":1}\n\n{\"b\""))
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "{\"a\":1}")
    assert_false(f.next(body))                      # the second is not complete yet
    f.feed(str_bytes(":2}\r\n"))
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "{\"b\":2}")   # the CR is not part of it
    assert_false(f.next(body))
    # a connection with line framing: messages split anywhere still come out whole
    var c = RpcConn()
    c.lines = True
    var got = c.feed(str_bytes("{\"jsonrpc\":\"2.0\",\"method\":\"session/up"))
    assert_equal(len(got), 0)
    got = c.feed(str_bytes("date\",\"params\":{}}\n{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"fs/read_text_file\",\"params\":{}}\n"))
    assert_equal(len(got), 2)
    assert_equal(got[0].kind, RPC_NOTIFICATION)
    assert_equal(got[1].kind, RPC_REQUEST)
    assert_equal(got[1].id_json, "7")


def agent_cmd(log: String, mode: String) -> String:
    return "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(log) + (" " + mode if mode.byte_length() > 0 else String(""))


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-acp-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def run_until(mut c: AcpClient, kind: Int, ms: Int = 10000) raises -> List[AcpEvent]:
    """Pump the client until an event of `kind` came; all events so far."""
    var out = List[AcpEvent]()
    var end = now() + ms * MS
    while now() < end:
        var fds = List[Int]()
        if c.fd() >= 0:
            fds.append(c.fd())
        _ = wait_readable(fds, 20)
        c.pump(now())
        var found = False
        for e in c.take_events():
            if e.kind == kind:
                found = True
            out.append(e.copy())
        if found:
            return out^
    assert_true(False, "no event of kind " + String(kind) + " came")
    return out^


def text_of(events: List[AcpEvent], kind: Int) -> String:
    var s = String("")
    for e in events:
        if e.kind == kind:
            s += e.text
    return s^


def ready(mut c: AcpClient, tag: String) raises -> String:
    """A client with a session open on the fake agent; the scratch folder."""
    var d = scratch(tag)
    assert_true(c.start(agent_cmd(d + "/log", ""), d, d + "/stderr", now()))
    _ = run_until(c, AE_READY)
    return d


def test_start_and_a_turn() raises:
    var d = scratch("turn")
    var c = AcpClient()
    assert_true(c.start(agent_cmd(d + "/log", ""), d, d + "/stderr", now()))
    assert_equal(c.state, AS_STARTING)
    _ = run_until(c, AE_READY)
    assert_equal(c.state, AS_READY)
    assert_equal(c.agent_name, "Fake Agent")
    assert_equal(c.version, 1)
    assert_true(c.load_session)
    assert_true(c.embedded_context)
    assert_false(c.images)
    assert_equal(c.session_id, "sess_fake_1")
    # what we said: version 1, no fs or terminal offered (yet), the folder for the session
    var log = bytes_to_str(read_file(d + "/log"))
    assert_true(log.find("\"protocolVersion\":1") > 0, log)
    assert_true(log.find("\"readTextFile\":false") > 0)
    assert_true(log.find("\"terminal\":false") > 0)
    assert_true(log.find("\"method\":\"session/new\",\"params\":{\"cwd\":\"" + d + "\",\"mcpServers\":[]}") > 0, log)
    # a turn: chunks stream in as events, then the stop reason
    assert_true(c.prompt("hello", now()))
    assert_true(c.busy())
    assert_false(c.prompt("again", now()))          # one turn at a time
    var ev = run_until(c, AE_TURN_END)
    assert_equal(text_of(ev, AE_MESSAGE), "Hello")
    assert_equal(text_of(ev, AE_THOUGHT), "thinking about it")
    assert_equal(ev[len(ev) - 1].stop_reason, "end_turn")
    assert_false(c.busy())
    # text with quotes and line feeds goes as one line of JSON
    assert_true(c.prompt("say \"hi\"\nplease", now()))
    ev = run_until(c, AE_TURN_END)
    assert_equal(text_of(ev, AE_MESSAGE), "you said: say \"hi\"\nplease")
    c.stop()
    assert_equal(c.state, AS_STOPPED)
    _ = run_system("rm -rf " + shell_quote(d))


def test_tool_calls_plans_and_unknown_updates() raises:
    var c = AcpClient()
    var d = ready(c, "tools")
    _ = c.prompt("tool", now())
    var ev = run_until(c, AE_TURN_END)
    assert_equal(ev[0].kind, AE_TOOL)
    assert_equal(ev[0].id, "call_1")
    assert_equal(ev[0].title, "Reading a.mojo")
    assert_equal(ev[0].tool_kind, "read")
    assert_equal(ev[0].status, "pending")
    assert_equal(ev[0].locations[0], "/p/a.mojo:3")
    assert_equal(ev[1].kind, AE_TOOL_UPDATE)
    assert_equal(ev[1].status, "in_progress")
    assert_equal(ev[2].status, "completed")
    assert_equal(ev[2].text, "3 lines")
    assert_equal(ev[2].diffs[0], "/p/a.mojo")
    _ = c.prompt("plan", now())
    ev = run_until(c, AE_TURN_END)
    assert_equal(ev[0].kind, AE_PLAN)
    assert_equal(len(ev[0].entries), 2)
    assert_equal(ev[0].entries[1], "[pending] Fix the bug")
    _ = c.prompt("other", now())
    ev = run_until(c, AE_TURN_END)
    assert_equal(ev[0].kind, AE_OTHER)
    assert_equal(ev[0].kind_name, "available_commands_update")
    c.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_permission_requests_are_answered() raises:
    var c = AcpClient()
    var d = ready(c, "perm")
    _ = c.prompt("perm", now())
    var ev = run_until(c, AE_PERMISSION)
    var p = ev[len(ev) - 1].copy()
    assert_equal(p.id, "call_2")
    assert_equal(p.title, "Write b.mojo")
    assert_equal(len(p.option_ids), 2)
    assert_equal(p.option_kinds[0], "allow_once")
    assert_equal(p.option_names[1], "Reject")
    assert_true(c.answer_permission(p.request, "reject"))
    assert_false(c.answer_permission(p.request, "allow"))     # answered already
    ev = run_until(c, AE_TURN_END)
    assert_equal(text_of(ev, AE_MESSAGE), "told: selected reject")
    # cancelling the turn answers the open request "cancelled"
    _ = c.prompt("perm", now())
    _ = run_until(c, AE_PERMISSION)
    c.cancel()
    ev = run_until(c, AE_TURN_END)
    assert_equal(text_of(ev, AE_MESSAGE), "told: cancelled")
    c.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_cancel_a_running_turn() raises:
    var c = AcpClient()
    var d = ready(c, "cancel")
    _ = c.prompt("slow", now())
    var ev = run_until(c, AE_MESSAGE)
    c.cancel()
    ev = run_until(c, AE_TURN_END)
    assert_equal(ev[len(ev) - 1].stop_reason, "cancelled")
    assert_false(c.busy())
    var log = bytes_to_str(read_file(d + "/log"))
    assert_true(log.find("\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"sess_fake_1\"}") > 0, log)
    # the session goes on
    _ = c.prompt("hello", now())
    ev = run_until(c, AE_TURN_END)
    assert_equal(text_of(ev, AE_MESSAGE), "Hello")
    c.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_requests_not_offered_are_refused() raises:
    var c = AcpClient()
    var d = ready(c, "refuse")
    _ = c.prompt("read", now())
    var ev = run_until(c, AE_TURN_END)
    assert_equal(text_of(ev, AE_MESSAGE), "read refused: -32601")
    assert_equal(c.refused[0], "fs/read_text_file")
    # an error answer to the prompt ends the turn too
    _ = c.prompt("fail", now())
    ev = run_until(c, AE_TURN_END)
    assert_equal(ev[len(ev) - 1].stop_reason, "error")
    assert_equal(ev[len(ev) - 1].text, "the model is unavailable")
    # what the agent logs on stderr goes to the file given, not into the protocol
    _ = c.prompt("noise", now())
    ev = run_until(c, AE_TURN_END)
    assert_equal(text_of(ev, AE_MESSAGE), "you said: noise")
    assert_true(bytes_to_str(read_file(d + "/stderr")).find("a log line on stderr") >= 0)
    c.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_agents_that_do_not_work() raises:
    var d = scratch("bad")
    var c = AcpClient()
    # another protocol version
    _ = c.start(agent_cmd(d + "/log", "v2"), d, "/dev/null", now())
    var ev = run_until(c, AE_FAILED)
    assert_equal(c.state, AS_FAILED)
    assert_true(c.problem.find("ACP version 2") > 0, c.problem)
    # no session (the agent wants a sign-in)
    _ = c.start(agent_cmd(d + "/log", "nosession"), d, "/dev/null", now())
    ev = run_until(c, AE_FAILED)
    assert_true(c.problem.find("Authentication required") > 0, c.problem)
    assert_true(c.problem.find("sign in") > 0)
    # it exits
    _ = c.start(agent_cmd(d + "/log", "die"), d, "/dev/null", now())
    ev = run_until(c, AE_FAILED)
    assert_true(c.problem.find("ended") >= 0, c.problem)
    # not a program at all
    _ = c.start("/nonexistent/agent", d, "/dev/null", now())
    ev = run_until(c, AE_FAILED)
    assert_equal(c.state, AS_FAILED)
    # silent: the start times out (the timeout is checked against the clock given)
    _ = c.start(agent_cmd(d + "/log", "noinit"), d, "/dev/null", now())
    c.started_ns = now() - 31000 * MS
    ev = run_until(c, AE_FAILED)
    assert_true(c.problem.find("did not answer") > 0, c.problem)
    assert_false(c.prompt("hello", now()))
    _ = run_system("rm -rf " + shell_quote(d))


def test_models_thinking_and_session_load() raises:
    var d = scratch("rich")
    var c = AcpClient()
    assert_true(c.start(agent_cmd(d + "/log", "rich"), d, "/dev/null", now()))
    _ = run_until(c, AE_READY)
    assert_false(c.resumed)
    assert_equal(c.current_model, "gemini-3.1-pro")
    assert_equal(len(c.model_ids), 2)
    assert_equal(c.model_name("claude-sonnet-4-6"), "Claude Sonnet 4.6")
    assert_equal(c.thinking, "medium")
    assert_equal(len(c.thinking_ids), 3)
    assert_true(c.set_model("claude-sonnet-4-6", now()))
    var ev = run_until(c, AE_MODEL)
    assert_equal(c.current_model, "claude-sonnet-4-6")
    assert_equal(ev[len(ev) - 1].status, "claude-sonnet-4-6")
    assert_true(c.set_thinking("high", now()))
    ev = run_until(c, AE_THINKING)
    assert_equal(c.thinking, "high")
    assert_equal(ev[len(ev) - 1].status, "high")
    c.stop()
    # session/load replays user & agent chunks before AE_READY
    var c2 = AcpClient()
    c2.resume_session_id = "sess_prev_99"
    assert_true(c2.start(agent_cmd(d + "/log2", "rich"), d, "/dev/null", now()))
    ev = run_until(c2, AE_READY)
    assert_true(c2.resumed)
    assert_equal(c2.session_id, "sess_prev_99")
    assert_equal(text_of(ev, AE_USER), "earlier question")
    assert_equal(text_of(ev, AE_MESSAGE), "earlier answer")
    c2.stop()
    # session/load error falls back automatically to session/new
    var c3 = AcpClient()
    c3.resume_session_id = "sess_missing"
    assert_true(c3.start(agent_cmd(d + "/log3", "rich"), d, "/dev/null", now()))
    _ = run_until(c3, AE_READY)
    assert_false(c3.resumed)
    assert_equal(c3.session_id, "sess_fake_1")
    c3.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
