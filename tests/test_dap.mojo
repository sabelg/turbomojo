"""Tests for the debug adapter client (src/dap.mojo) and Run > Debug (src/app_debug.mojo).

The sessions talk to tests/helpers/fake_dap_adapter.py (needs python3): a scripted adapter
whose behaviour follows what the real mojo-lldb-dap was seen to do (see the journal)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from std.ffi import external_call
from dap import *
from rpc import frame
from term import wait_readable, fkey, key_event, MOD_SHIFT, MOD_CTRL
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from app_exec import trust_needed
from commands import CM_DEBUG, CM_CANCEL, CM_RUN, build_registry
from config import load_settings, read_text
from signals import own_pid
from util import to_str, env_or, run_system, bytes_to_str, path_exists, str_bytes

comptime MS = 1000000


def now() -> Int:
    return Int(perf_counter_ns())


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-dap-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def adapter(d: String, mode: String = "") -> String:
    return "python3 tests/helpers/fake_dap_adapter.py '" + d + "/requests.log' " + mode


def names(events: List[Int]) -> String:
    var words = ["?", "output", "running", "stopped", "located", "exited", "ended", "failed"]
    var s = String("")
    for e in events:
        if s.byte_length() > 0:
            s += " "
        s += String(words[e])
    return s


def run_until(mut s: DebugSession, last: Int, timeout_ms: Int = 5000) -> String:
    """Pump the session until the event `last` was seen (or the time is up); what
    happened, in order, without the repeats of "output"."""
    var seen = List[Int]()
    var deadline = now() + timeout_ms * MS
    var done = False
    while not done and now() < deadline:
        var fds = List[Int]()
        fds.append(s.fd())
        _ = wait_readable(fds, 20)
        for e in s.pump():
            if e == DE_OUTPUT and len(seen) > 0 and seen[len(seen) - 1] == DE_OUTPUT:
                continue
            seen.append(e)
            if e == last:
                done = True
    return names(seen)


def alive(pid: Int) -> Bool:
    return Int(external_call["kill", Int32](Int32(pid), Int32(0))) == 0


def gone_soon(pid: Int) -> Bool:
    for _ in range(200):
        if not alive(pid):
            return True
        _ = external_call["usleep", Int32](UInt32(10000))
    return False


def one(mut c: DapConn, json: String) -> DapMessage:
    var ms = c.feed(frame(json))
    if len(ms) == 0:
        return DapMessage()
    return ms[0].copy()


# ------------------------------------------------------------- the messages
def test_messages_are_told_apart() raises:
    var c = DapConn()
    # requests are numbered and remembered until their answer comes
    assert_equal(c.request_body("initialize", "{\"clientID\":\"x\"}"), "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{\"clientID\":\"x\"}}")
    assert_equal(c.request_body("threads", ""), "{\"seq\":2,\"type\":\"request\",\"command\":\"threads\"}")
    assert_true(c.is_pending(1) and c.is_pending(2))
    var r = one(c, "{\"seq\":9,\"type\":\"response\",\"request_seq\":1,\"success\":true,\"command\":\"initialize\",\"body\":{\"supportsLogPoints\":true}}")
    assert_equal(r.kind, DAP_RESPONSE)
    assert_equal(r.name, "initialize")
    assert_true(r.success)
    assert_true(r.doc.bool(r.doc.get(r.body(), "supportsLogPoints")))
    assert_false(c.is_pending(1))
    # a failed answer: the adapter's longer explanation is the message; an answer
    # without a command gets the name of what was asked
    var f = one(c, "{\"seq\":10,\"type\":\"response\",\"request_seq\":2,\"success\":false,\"message\":\"failed\",\"body\":{\"error\":{\"id\":3,\"format\":\"no threads yet\"}}}")
    assert_equal(f.name, "threads")
    assert_false(f.success)
    assert_equal(f.message, "no threads yet")
    var plain = one(c, "{\"seq\":11,\"type\":\"response\",\"request_seq\":77,\"success\":false,\"command\":\"next\",\"message\":\"not stopped\"}")
    assert_equal(plain.message, "not stopped")
    var e = one(c, "{\"seq\":12,\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"reason\":\"step\",\"threadId\":4}}")
    assert_equal(e.kind, DAP_EVENT)
    assert_equal(e.name, "stopped")
    assert_equal(e.doc.int(e.doc.get(e.body(), "threadId")), 4)
    var q = one(c, "{\"seq\":13,\"type\":\"request\",\"command\":\"runInTerminal\",\"arguments\":{\"args\":[\"a\"]}}")
    assert_equal(q.kind, DAP_REQUEST)
    assert_equal(q.seq, 13)
    assert_true(q.arguments() > 0)
    # what is not a DAP message is counted and dropped
    assert_equal(c.invalid, 0)
    assert_equal(one(c, "[1,2]").kind, DAP_INVALID)
    assert_equal(one(c, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}").kind, DAP_INVALID)
    assert_equal(one(c, "{\"seq\":14,\"type\":\"event\"}").kind, DAP_INVALID)
    assert_equal(one(c, "{\"type\":\"request\",\"command\":\"x\"}").kind, DAP_INVALID)
    assert_equal(c.invalid, 4)
    # two messages in one read, the second split
    var both = frame("{\"seq\":1,\"type\":\"event\",\"event\":\"a\"}")
    var second = frame("{\"seq\":2,\"type\":\"event\",\"event\":\"b\"}")
    for k in range(10):
        both.append(second[k])
    assert_equal(len(c.feed(both)), 1)
    var rest = List[UInt8]()
    for k in range(10, len(second)):
        rest.append(second[k])
    var late = c.feed(rest)
    assert_equal(len(late), 1)
    assert_equal(late[0].name, "b")


def test_arguments_are_split_like_a_shell_does() raises:
    assert_equal(" | ".join(split_arguments("one two   three")), "one | two | three")
    assert_equal(" | ".join(split_arguments("  --name \"Ada Lovelace\" 'single \"kept\"' ")), "--name | Ada Lovelace | single \"kept\"")
    assert_equal(" | ".join(split_arguments("a\\ b \"q\\\"uote\" pre'fix'post")), "a b | q\"uote | prefixpost")
    assert_equal(len(split_arguments("")), 0)
    assert_equal(len(split_arguments("   ")), 0)
    var empty = split_arguments("x \"\" y")
    assert_equal(len(empty), 3)
    assert_equal(empty[1], "")
    assert_equal(" | ".join(split_arguments("tab\there héllo")), "tab | here | héllo")


def test_requests_carry_what_the_adapter_needs() raises:
    var args = List[String]()
    args.append("a b")
    args.append("--x")
    assert_equal(launch_arguments("/p/build/hello.debug", "/p", args), "{\"program\":\"/p/build/hello.debug\",\"cwd\":\"/p\",\"args\":[\"a b\",\"--x\"],\"stopOnEntry\":false}")
    var init = initialize_arguments()
    assert_true(init.find("\"linesStartAt1\":true") > 0 and init.find("\"pathFormat\":\"path\"") > 0)
    assert_true(init.find("\"supportsRunInTerminalRequest\":false") > 0)


def test_adapter_command_loads_the_mojo_plugin() raises:
    var d = scratch("cmd")
    _ = run_system("mkdir -p '" + d + "/env/bin' '" + d + "/env/lib' && touch '" + d + "/env/bin/mojo-lldb-dap'")
    # the adapter script needs CONDA_PREFIX; without the plugin nothing more is added
    assert_equal(adapter_command(d + "/env/bin/mojo-lldb-dap"), "env CONDA_PREFIX='" + d + "/env' '" + d + "/env/bin/mojo-lldb-dap'")
    _ = run_system("touch '" + d + "/env/lib/libMojoLLDB.so'")
    assert_equal(adapter_command(d + "/env/bin/mojo-lldb-dap"), "env CONDA_PREFIX='" + d + "/env' '" + d + "/env/bin/mojo-lldb-dap' --pre-init-command 'plugin load " + d + "/env/lib/libMojoLLDB.so'")
    assert_equal(adapter_command(""), "")
    _ = run_system("rm -rf '" + d + "'")


# ------------------------------------------------------------- sessions
def test_a_program_runs_to_its_end() raises:
    var d = scratch("run")
    var s = DebugSession()
    s.config_cmds.append("setBreakpoints")
    s.config_args.append("{\"source\":{\"path\":\"/p/a.mojo\"},\"breakpoints\":[{\"line\":4}]}")
    var args = List[String]()
    args.append("first")
    args.append("second arg")
    assert_false(s.active())
    assert_equal(s.fd(), -1)
    assert_true(s.begin(adapter(d), "/p/build/exit3", "/p", args))
    assert_true(s.active())
    assert_false(s.begin(adapter(d), "/p/build/exit3", "/p", args), "one session at a time")
    assert_equal(run_until(s, DE_ENDED), "running output exited ended")
    assert_equal(bytes_to_str(s.output), "args: first | second arg\na line on stderr\n")
    assert_true(s.exited)
    assert_equal(s.exit_code, 3)
    assert_equal(" | ".join(s.console), "Welcome to fake debugging\n")
    # what the adapter said it can do - at the start and later
    assert_true(s.supports("supportsConfigurationDoneRequest") and s.supports("supportsConditionalBreakpoints"))
    assert_true(s.supports("supportsRestartRequest"))
    assert_false(s.supports("supportsStepBack"))
    s.finish()
    assert_false(s.active())
    # the conversation, in the order the protocol asks for: the configuration
    # (breakpoints) between the adapter's "initialized" and configurationDone
    var log = read_text(d + "/requests.log").split("\n")
    assert_true(String(log[0]).startswith("initialize {"))
    assert_equal(String(log[1]), "launch {\"args\": [\"first\", \"second arg\"], \"cwd\": \"/p\", \"program\": \"/p/build/exit3\", \"stopOnEntry\": false}")
    assert_equal(String(log[2]), "setBreakpoints {\"breakpoints\": [{\"line\": 4}], \"source\": {\"path\": \"/p/a.mojo\"}}")
    assert_equal(String(log[3]), "setExceptionBreakpoints {\"filters\": []}")
    assert_equal(String(log[4]), "configurationDone {}")
    assert_equal(String(log[5]), "disconnect {\"terminateDebuggee\": true}")
    # the session can be used again
    assert_true(s.begin(adapter(d), "/p/build/exit3", "/p", List[String]()))
    assert_equal(len(s.output), 0)
    assert_false(s.exited)
    assert_equal(run_until(s, DE_ENDED), "running output exited ended")
    assert_equal(bytes_to_str(s.output), "args: \na line on stderr\n")
    s.finish()
    _ = run_system("rm -rf '" + d + "'")


def test_a_stop_is_located_and_continued() raises:
    var d = scratch("stop")
    var s = DebugSession()
    assert_false(s.resume(), "nothing to continue")
    assert_true(s.begin(adapter(d), "/p/build/stop", "/p", List[String]()))
    assert_equal(run_until(s, DE_LOCATED), "running output stopped located")
    assert_equal(s.state, DS_STOPPED)
    assert_equal(s.stop_reason, "breakpoint")
    assert_equal(s.stop_text, "breakpoint 1.1")
    assert_equal(s.stop_thread, 7)
    assert_equal(s.stop_file, "/src/stop.mojo")
    assert_equal(s.stop_line, 12)
    assert_equal(s.stop_func, "stop::main()")
    assert_true(s.resume())
    assert_equal(run_until(s, DE_ENDED), "running output exited ended")
    assert_equal(s.stop_file, "", "running again: no stop to show")
    assert_equal(s.exit_code, 0)
    assert_equal(bytes_to_str(s.output), "before the stop\nafter the stop\n")
    s.finish()
    var log = read_text(d + "/requests.log")
    assert_true(log.find("stackTrace {\"levels\": 1, \"startFrame\": 0, \"threadId\": 7}") > 0, log)
    assert_true(log.find("continue {\"threadId\": 7}") > 0, log)
    _ = run_system("rm -rf '" + d + "'")


def test_failures_end_the_session_with_a_reason() raises:
    var d = scratch("fail")
    var s = DebugSession()
    assert_true(s.begin(adapter(d), "/p/build/nostart", "/p", List[String]()))
    assert_equal(run_until(s, DE_FAILED), "failed")
    assert_equal(s.error, "The program could not be started: no such file: nostart")
    s.finish()
    # the adapter goes away while the session is being set up
    var gone = DebugSession()
    assert_true(gone.begin(adapter(d, "die"), "/p/build/exit3", "/p", List[String]()))
    assert_equal(run_until(gone, DE_FAILED), "failed")
    assert_equal(gone.error, "The debug adapter ended before the program was started")
    gone.finish()
    assert_false(gone.active())
    # no adapter at all
    var none = DebugSession()
    assert_false(none.begin("", "/p/build/exit3", "/p", List[String]()))
    assert_equal(none.error, "The debug adapter could not be started")
    assert_false(none.active())
    none.finish()
    _ = run_system("rm -rf '" + d + "'")


def test_ending_a_session_ends_the_program() raises:
    var d = scratch("end")
    # the adapter does what it is asked
    var s = DebugSession()
    assert_true(s.begin(adapter(d), "/p/build/forever", "/p", List[String]()))
    assert_equal(run_until(s, DE_OUTPUT), "running output")
    var pid = s.pid
    assert_true(pid > 1 and alive(pid))
    s.finish()
    assert_true(gone_soon(pid), "the program was ended through the adapter")
    # an adapter that ignores the request: it is stopped, and the program it left
    # behind is killed
    var deaf = DebugSession()
    assert_true(deaf.begin(adapter(d, "deaf"), "/p/build/forever", "/p", List[String]()))
    assert_equal(run_until(deaf, DE_OUTPUT), "running output")
    var pid2 = deaf.pid
    assert_true(pid2 > 1 and alive(pid2))
    var t0 = now()
    deaf.finish()
    assert_true((now() - t0) // MS < 3000, "ending does not hang")
    assert_true(gone_soon(pid2), "the program does not outlive the session")
    assert_false(deaf.active())
    _ = run_system("rm -rf '" + d + "'")


def test_requests_of_the_adapter_are_declined() raises:
    var d = scratch("ask")
    var s = DebugSession()
    assert_true(s.begin(adapter(d, "ask"), "/p/build/exit3", "/p", List[String]()))
    assert_equal(run_until(s, DE_ENDED), "running output exited ended")
    s.finish()
    var log = read_text(d + "/requests.log")
    assert_true(log.find("response runInTerminal {\"message\": \"not supported\", \"success\": false}") > 0, log)
    _ = run_system("rm -rf '" + d + "'")


# ------------------------------------------------------------- in the IDE
def ide(d: String, mode: String = "") raises -> App:
    var app = App()
    app.scr.resize(110, 30)
    app.cwd = d
    app.debug_adapter = "env FAKE_DAP_SOURCE='" + d + "/stop.mojo' " + adapter(d, mode)
    return app^


def settle(mut app: App, until_off: Bool, timeout_ms: Int = 5000) raises:
    """Let the IDE follow the session until it is over (or, for a session that goes
    on, until the program stopped or wrote something)."""
    var deadline = now() + timeout_ms * MS
    while now() < deadline:
        var fds = List[Int]()
        fds.append(app.dbg.fd())
        _ = wait_readable(fds, 20)
        app.debug_tick()
        if until_off and not app.dbg.active():
            return
        if not until_off and (app.dbg.stop_line > 0 or (app.dbg.state == DS_RUNNING and len(app.dbg.output) > 0)):
            return


def messages(app: App) -> String:
    var mi = app.msg_index()
    if mi < 0:
        return "(no message window)"
    var s = String("")
    for r in range(app.wins[mi].buf.count()):
        if r > 0:
            s += "\n"
        s += to_str(app.wins[mi].buf.line(r))
    return s


def screen(mut app: App) -> String:
    """The screen once the passing status message is gone (it covers the indicators)."""
    if app.mode == M_NORMAL:
        app.status_until = 0
    app.draw()
    return to_str(app.scr.to_text())


def test_debug_shows_the_program_output_and_how_it_ended() raises:
    var d = scratch("ide1")
    put(d + "/exit3.mojo", "def main():\n    pass\n")
    var app = ide(d)
    app.open_path(d + "/exit3.mojo")
    app.run_args = "one \"two words\""
    app.debug_launch(d + "/build/exit3", d + "/exit3.mojo")
    assert_true(app.dbg.active())
    assert_true(screen(app).find("DEBUG:starting") > 0, screen(app))
    settle(app, True)
    assert_false(app.dbg.active())
    assert_equal(messages(app), "Debugging " + d + "/exit3.mojo\nargs: one | two words\na line on stderr\nProgram exited with status 3")
    assert_equal(app.status, "Program exited with status 3")
    assert_true(screen(app).find("DEBUG:") < 0)
    # the program is started in the folder of its source
    assert_true(read_text(d + "/requests.log").find("\"cwd\": \"" + d + "\"") > 0)
    _ = run_system("rm -rf '" + d + "'")


def test_debug_goes_to_the_line_a_program_stops_at() raises:
    var d = scratch("ide2")
    put(d + "/stop.mojo", "# a program\n" * 20)
    put(d + "/other.mojo", "def main():\n    pass\n")
    var app = ide(d)
    app.open_path(d + "/other.mojo")
    app.debug_launch(d + "/build/stop", d + "/other.mojo")
    settle(app, False)
    assert_equal(app.dbg.state, DS_STOPPED)
    var t = app.top_editor()
    assert_equal(app.wins[t].path, d + "/stop.mojo")
    assert_equal(app.wins[t].cr, 11)
    assert_true(app.status.startswith("Stopped: breakpoint 1.1 at stop.mojo:12 in stop::main()"), app.status)
    assert_true(messages(app).endswith("before the stop\nStopped: breakpoint 1.1 at stop.mojo:12 in stop::main()  (Shift-F5 continues, Ctrl-F2 ends)"), messages(app))
    assert_true(screen(app).find("DEBUG:stopped") > 0)
    # Debug again lets it continue
    assert_equal(build_registry().find_key(fkey(5) | MOD_SHIFT), CM_DEBUG)
    app.handle(key_event(fkey(5) | MOD_SHIFT))
    assert_equal(app.status, "Continuing other.mojo")
    settle(app, True)
    assert_true(messages(app).endswith("before the stop\nafter the stop\nProgram exited with status 0"), messages(app))
    _ = run_system("rm -rf '" + d + "'")


def test_ctrl_f2_ends_a_program_being_debugged() raises:
    var d = scratch("ide3")
    put(d + "/forever.mojo", "def main():\n    pass\n")
    var app = ide(d)
    app.open_path(d + "/forever.mojo")
    app.debug_launch(d + "/build/forever", d + "/forever.mojo")
    settle(app, False)
    assert_equal(app.dbg.state, DS_RUNNING)
    var pid = app.dbg.pid
    assert_true(alive(pid))
    assert_true(screen(app).find("DEBUG:running") > 0)
    # Debug while it runs changes nothing
    app.exec(CM_DEBUG)
    assert_true(app.status.startswith("A program is being debugged - Ctrl-F2 ends it"), app.status)
    assert_true(app.dbg.active())
    app.handle(key_event(fkey(2) | MOD_CTRL))
    assert_false(app.dbg.active())
    assert_true(gone_soon(pid))
    assert_equal(app.status, "Debugging ended - the program was stopped")
    assert_true(messages(app).endswith("started\nDebugging ended - the program was stopped"), messages(app))
    # the Message window keeps the newest line in view
    var mi = app.msg_index()
    assert_equal(app.wins[mi].cr, app.wins[mi].buf.count() - 1)
    # with nothing to end, Ctrl-F2 says so as before
    app.handle(key_event(fkey(2) | MOD_CTRL))
    assert_equal(app.status, "Nothing to cancel")
    _ = run_system("rm -rf '" + d + "'")


def test_debug_explains_what_went_wrong() raises:
    var d = scratch("ide4")
    put(d + "/nostart.mojo", "def main():\n    pass\n")
    var app = ide(d)
    app.open_path(d + "/nostart.mojo")
    app.debug_launch(d + "/build/nostart", d + "/nostart.mojo")
    settle(app, True)
    assert_false(app.dbg.active())
    assert_equal(app.mode, M_DIALOG)
    assert_true(screen(app).find("The program could not be started: no such file: nostart") > 0, screen(app))
    # no adapter installed: said before anything is built
    var bare = App()
    bare.scr.resize(110, 30)
    bare.cwd = d
    bare.debug_adapter = "no-such-debug-adapter"
    bare.open_path(d + "/nostart.mojo")
    assert_equal(bare.debug_adapter_command(), "")
    bare.debug_command()
    assert_equal(bare.mode, M_DIALOG)
    assert_true(screen(bare).find("The debug adapter was not found: no-such-debug-adapter") > 0, screen(bare))
    assert_false(bare.job.active)
    # debugging runs the folder's code: it waits for the folder to be trusted
    assert_true(trust_needed(CM_DEBUG))
    # the setting
    assert_equal(load_settings("", "").debug_adapter, "mojo-lldb-dap")
    assert_equal(load_settings("[tools]\ndebug_adapter = \"/opt/x/bin/mojo-lldb-dap\"\n", "").debug_adapter, "/opt/x/bin/mojo-lldb-dap")
    assert_equal(" | ".join(load_settings("[tools]\ndebug_adapter = 3\n", "").warnings), "tools.debug_adapter must be a non-empty string")
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
