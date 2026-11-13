"""End-to-end debugging of the bundled examples with Mojo's real debugger
(mojo-lldb-dap): build, breakpoints, stops, the Debug and CPU windows, watches, the
console, stepping, run to cursor, the end of a session - driven through the IDE's own
commands, as a user would. Nothing here is faked; each run takes about a minute.

The examples are copied to a scratch folder first, so their build output stays out of
the repository."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from std.ffi import external_call
from dap import *
from term import wait_readable, fkey, key_event, MOD_CTRL, MOD_SHIFT, MOD_ALT, KEY_ENTER
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from commands import CM_DEBUG, CM_BP_TOGGLE, CM_RUN_CURSOR, CM_WATCH_ADD, CM_EVALUATE, CM_CPUWIN, CM_BP_EDIT
from config import read_text
from signals import own_pid
from util import to_str, env_or, run_system, bytes_to_str, decode, which

comptime MS = 1000000


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def now() -> Int:
    return Int(perf_counter_ns())


def alive(pid: Int) -> Bool:
    return pid > 0 and Int(external_call["kill", Int32](Int32(pid), Int32(0))) == 0


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(140, 44)
    app.cwd = d
    return app^


def turn(mut app: App) raises:
    """One round of the main loop for the parts that matter here."""
    var fds = List[Int]()
    if app.job.active:
        fds.append(app.job.fd)
    if app.dbg.fd() >= 0:
        fds.append(app.dbg.fd())
    _ = wait_readable(fds, 20)
    app.poll_job()
    app.debug_tick()


def wait_stop(mut app: App, line: Int, what: String, timeout_s: Int = 180) raises:
    """Until the program stopped on `line` and the Debug window shows `what`."""
    var deadline = now() + timeout_s * 1000 * MS
    while now() < deadline:
        turn(app)
        if app.dbg.state == DS_STOPPED and app.dbg.stop_line == line and debug_text(app).find(what) >= 0:
            return
        if not app.dbg.active() and not app.job.active:
            break
    assert_true(False, "no stop at line " + String(line) + " with \"" + what + "\" (" + app.status + "):\n" + debug_text(app) + "\n--- messages:\n" + messages(app))


def wait_for(mut app: App, text: String, timeout_s: Int = 20) raises:
    """Until the Message window shows `text`."""
    var deadline = now() + timeout_s * 1000 * MS
    while now() < deadline:
        turn(app)
        if messages(app).find(text) >= 0:
            return
    assert_true(False, "no \"" + text + "\" in the Message window:\n" + messages(app))


def wait_end(mut app: App, timeout_s: Int = 60) raises:
    var deadline = now() + timeout_s * 1000 * MS
    while now() < deadline and (app.dbg.active() or app.job.active):
        turn(app)
    assert_false(app.dbg.active(), "the session did not end")


def window_text(app: App, kind: Int) -> String:
    for i in range(len(app.wins)):
        if app.wins[i].kind == kind:
            var s = String("")
            for r in range(app.wins[i].buf.count()):
                s += to_str(app.wins[i].buf.line(r)) + "\n"
            return s
    return ""


def debug_text(app: App) -> String:
    return window_text(app, 4)


def messages(app: App) -> String:
    return window_text(app, 1)


def row_of(app: App, text: String) -> Int:
    var di = app.debugwin_index()
    for r in range(app.wins[di].buf.count()):
        if to_str(app.wins[di].buf.line(r)).find(text) >= 0:
            return r
    return -1


def press_in_debug_window(mut app: App, text: String, k: Int) raises:
    app.focus(app.debugwin_index())
    var di = app.debugwin_index()
    var r = row_of(app, text)
    assert_true(r >= 0, "no \"" + text + "\" in the Debug window:\n" + debug_text(app))
    app.wins[di].cr = r
    app.handle(key_event(k))


def goto_line(mut app: App, line: Int):
    app.focus(app.top_editor())
    app.wins[app.top_editor()].goto(line - 1, 0)


def test_the_adapter_is_there() raises:
    """The test needs Mojo's debugger; it comes with the mojo package."""
    assert_true(which("mojo-lldb-dap").byte_length() > 0, "mojo-lldb-dap is not on PATH (run the tests through pixi)")


def test_debugging_hello_end_to_end() raises:
    var d = scratch("hello")
    _ = run_system("cp examples/hello.mojo '" + d + "/hello.mojo'")
    var src = d + "/hello.mojo"
    var app = ide(d)
    app.open_path(src)
    # a breakpoint in Counter.bump (line 12), then Debug
    goto_line(app, 12)
    app.exec(CM_BP_TOGGLE)
    app.handle(key_event(fkey(5) | MOD_SHIFT))
    assert_true(app.job.active, "Debug builds first")
    wait_stop(app, 12, "by = 0   Int")
    assert_true(app.dbg.stop_func.find("bump") >= 0, app.dbg.stop_func)
    assert_equal(app.wins[app.top_editor()].path, src)
    assert_equal(app.wins[app.top_editor()].buf.exec_row, 11)
    var dv = debug_text(app)
    assert_true(dv.find("► hello::Counter::bump(...)   hello.mojo:12") >= 0 and dv.find("hello::main()   hello.mojo:24") >= 0, dv)
    assert_true(dv.find("▸ self: Counter") >= 0, dv)
    # continue: the same breakpoint, the next call
    app.handle(key_event(fkey(5) | MOD_SHIFT))
    wait_stop(app, 12, "by = 1   Int")
    # the struct opens; its field is there
    press_in_debug_window(app, "self: Counter", KEY_ENTER)
    wait_stop(app, 12, "count = 0   Int")
    # remove the breakpoint and run to the print on line 25
    goto_line(app, 12)
    app.exec(CM_BP_TOGGLE)
    assert_equal(len(app.bps.items), 0)
    goto_line(app, 25)
    app.exec(CM_RUN_CURSOR)
    wait_stop(app, 25, "c: Counter")
    # a watch on the field, and the console
    app.exec(CM_WATCH_ADD)
    app.dlg.fields[0].text = decode("c.count")
    app.dialog_button(0)
    wait_stop(app, 25, "c.count = 45   Int")
    app.exec(CM_EVALUATE)
    app.dlg.fields[0].text = decode(":frame variable")
    app.dialog_button(0)
    wait_for(app, "> :frame variable")
    wait_for(app, "count = 45")
    app.mode = M_NORMAL
    # the CPU window at this stop
    app.exec(CM_CPUWIN)
    var deadline = now() + 20000 * MS
    # (the program counter is "pc" on aarch64 and "rip" on x86-64: the adapter's names)
    while now() < deadline and (window_text(app, 5).find("► 0x") < 0 or (window_text(app, 5).find(" pc ") < 0 and window_text(app, 5).find(" rip ") < 0) or window_text(app, 5).find("Memory at 0x") < 0):
        turn(app)
    var cpu = window_text(app, 5)
    assert_true(cpu.find("► 0x") >= 0 and (cpu.find(" pc ") >= 0 or cpu.find(" rip ") >= 0) and cpu.find("hello.mojo:25") >= 0, cpu)
    app.exec(CM_CPUWIN)
    # F8: over the print; its output arrives
    goto_line(app, 25)
    app.handle(key_event(fkey(8)))
    wait_stop(app, 26, "c: Counter")
    wait_for(app, "Hello from Mojo! count = 45")
    # F7 on line 26 goes into fib
    app.handle(key_event(fkey(7)))
    wait_stop(app, 16, "n = 20   Int")
    # Shift-F8 back out
    app.handle(key_event(fkey(8) | MOD_SHIFT))
    var back = now() + 60000 * MS
    while now() < back and not (app.dbg.state == DS_STOPPED and app.dbg.stop_line == 26):
        turn(app)
    assert_equal(app.dbg.stop_line, 26)
    # Ctrl-F2: the program and the debugger are gone
    var pid = app.dbg.pid
    assert_true(alive(pid), "the program runs while it is stopped")
    app.handle(key_event(fkey(2) | MOD_CTRL))
    assert_false(app.dbg.active())
    var gone = now() + 3000 * MS
    while now() < gone and alive(pid):
        _ = external_call["usleep", Int32](UInt32(10000))
    assert_false(alive(pid), "the program was ended with the session")
    assert_equal(app.status, "Debugging ended - the program was stopped")
    assert_equal(app.wins[app.top_editor()].buf.exec_row, -1)
    _ = run_system("rm -rf '" + d + "'")


def test_a_session_runs_to_the_end_and_a_function_breakpoint_stops() raises:
    var d = scratch("fib")
    _ = run_system("cp examples/test_fib.mojo '" + d + "/test_fib.mojo'")
    var src = d + "/test_fib.mojo"
    var app = ide(d)
    app.open_path(src)
    # no breakpoints: the program runs to its end; its TestSuite output is shown
    app.exec(CM_DEBUG)
    wait_end(app, 180)
    var out = messages(app)
    assert_true(out.find("2 tests run: 2 passed") >= 0 or out.find("passed") >= 0, out)
    assert_true(out.find("Program exited with status 0") >= 0, out)
    # a breakpoint on the function fib, from its 5th call on
    _ = app.bps.add_function("fib")
    app.bps.items[0].hit = "5"
    app.bp_changed("")
    app.exec(CM_DEBUG)
    var deadline = now() + 180000 * MS
    while now() < deadline and not (app.dbg.state == DS_STOPPED and app.dbg.stop_line > 0):
        turn(app)
    assert_equal(app.dbg.state, DS_STOPPED)
    assert_true(app.dbg.stop_func.find("fib") >= 0, app.dbg.stop_func)
    assert_true(app.dbg.stop_line >= 5 and app.dbg.stop_line <= 8, String(app.dbg.stop_line))
    # the first stops were passed over: n is no longer the 10 of the first call
    var n_shown = now() + 20000 * MS
    while now() < n_shown and debug_text(app).find("  n = ") < 0:
        turn(app)
    assert_true(debug_text(app).find("  n = 10   Int") < 0 and debug_text(app).find("  n = ") >= 0, debug_text(app))
    assert_equal(app.bps.items[0].verified, 1)
    var pid = app.dbg.pid
    app.debug_end(True)
    var gone = now() + 3000 * MS
    while now() < gone and alive(pid):
        _ = external_call["usleep", Int32](UInt32(10000))
    assert_false(alive(pid))
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
