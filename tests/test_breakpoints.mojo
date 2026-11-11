"""Tests for breakpoints (src/breakpoints.mojo) and how the IDE shows, keeps and sends
them (src/app_debug.mojo). The debugger is tests/helpers/fake_dap_adapter.py; what it
answers follows the real mojo-lldb-dap (see the journal)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from breakpoints import *
from dap import *
from json import json_parse
from term import Event, EV_MOUSE, MB_LEFT, wait_readable, fkey, key_event, MOD_CTRL, KEY_ENTER, KEY_DOWN
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_BREAKPOINT, D_BPFUNC, D_BREAKPOINTS
from commands import CM_BP_TOGGLE, CM_BP_EDIT, CM_BP_FUNC, CM_BP_LIST, CM_BP_CLEAR, build_registry
from config import read_text
from signals import own_pid
from util import to_str, env_or, run_system, bytes_to_str, path_exists, decode

comptime MS = 1000000


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-bp-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def lines_of(bps: Breakpoints, path: String) -> String:
    var s = String("")
    for k in bps.of_file(path):
        if s.byte_length() > 0:
            s += " "
        s += String(bps.items[k].line)
    return s


# ------------------------------------------------------------- the list
def test_toggling_and_order() raises:
    var b = Breakpoints()
    assert_true(b.toggle("/p/b.mojo", 20))
    assert_true(b.toggle("/p/a.mojo", 7))
    assert_true(b.toggle("/p/b.mojo", 3))
    assert_true(b.add_function("fib"))
    assert_false(b.add_function("fib"), "one per function")
    assert_false(b.add_function(""))
    assert_equal(lines_of(b, "/p/b.mojo"), "3 20")
    assert_equal(len(b.files()), 2)
    var shown = List[String]()
    for k in b.ordered():
        shown.append(b.items[k].describe())
    assert_equal(" | ".join(shown), "b.mojo:3 | b.mojo:20 | a.mojo:7 | fib()")
    assert_false(b.toggle("/p/b.mojo", 20), "the second toggle removes it")
    assert_equal(lines_of(b, "/p/b.mojo"), "3")
    assert_equal(b.find("/p/a.mojo", 7), 0)
    assert_equal(b.find("/p/a.mojo", 8), -1)


def test_what_a_breakpoint_looks_like() raises:
    var b = Breakpoint("/p/a.mojo", 4)
    assert_equal(b.look(), 1)
    b.condition = "i == 3"
    b.hit = "2"
    b.log = "i is {i}"
    assert_equal(b.look(), 3)
    assert_equal(b.describe(), "a.mojo:4  when i == 3  hits 2  log \"i is {i}\"")
    b.enabled = False
    assert_equal(b.look(), 2)
    assert_true(b.describe().endswith("(off)"))
    b.enabled = True
    b.verified = BV_NOT
    assert_equal(b.look(), 4)
    assert_true(b.describe().endswith("(not placed by the debugger)"))
    var moved = Breakpoint("/p/a.mojo", 99)
    moved.verified = BV_OK
    moved.actual = 100
    assert_equal(moved.describe(), "a.mojo:99  (the debugger uses line 100)")


def test_the_list_is_kept_in_a_file() raises:
    var b = Breakpoints()
    _ = b.toggle("/p/my dir/a.mojo", 12)
    _ = b.toggle("/p/x.mojo", 5)
    _ = b.add_function("Counter.bump")
    b.items[0].condition = "s == \"a\tb\" \\ ok"
    b.items[0].log = "two\nlines"
    b.items[1].enabled = False
    b.items[1].hit = "3"
    b.items[0].verified = BV_NOT        # what a debugger said is not kept
    var text = b.encode()
    assert_equal(text, "turbomojo breakpoints 1\nS\t1\t12\t/p/my dir/a.mojo\ts == \"a\\tb\" \\\\ ok\t\ttwo\\nlines\nS\t0\t5\t/p/x.mojo\t\t3\t\nF\t1\t0\tCounter.bump\t\t\t\n")
    var c = Breakpoints()
    c.decode(text)
    assert_equal(c.encode(), text)
    assert_equal(c.items[0].condition, "s == \"a\tb\" \\ ok")
    assert_equal(c.items[0].log, "two\nlines")
    assert_false(c.items[1].enabled)
    assert_equal(c.items[0].verified, BV_UNKNOWN)
    # nonsense is left out, a file of another kind is not read at all
    var d = Breakpoints()
    d.decode("turbomojo breakpoints 1\nS\t1\tx\t/p/a.mojo\t\t\t\nS\t1\t0\t/p/a.mojo\t\t\t\nS\t1\t3\t\t\t\t\nQ\t1\t3\t/p\t\t\t\nS\t1\t3\t/p/a.mojo\t\t\t\nS\t1\t3\t/p/a.mojo\t\t\t\ntoo\tfew\n")
    assert_equal(len(d.items), 1)
    d.decode("something else\nS\t1\t3\t/p/a.mojo\t\t\t\n")
    assert_equal(len(d.items), 0)


def test_breakpoints_follow_their_lines() raises:
    var b = Breakpoints()
    _ = b.toggle("/p/a.mojo", 3)
    _ = b.toggle("/p/a.mojo", 8)
    _ = b.toggle("/p/a.mojo", 9)
    var rows = List[Int]()
    rows.append(4)
    rows.append(9)
    rows.append(10)
    assert_true(b.set_rows("/p/a.mojo", rows))
    assert_equal(lines_of(b, "/p/a.mojo"), "5 10 11")
    assert_false(b.set_rows("/p/a.mojo", rows), "nothing changed")
    # two that meet on one line become one
    var met = List[Int]()
    met.append(4)
    met.append(9)
    met.append(9)
    assert_true(b.set_rows("/p/a.mojo", met))
    assert_equal(lines_of(b, "/p/a.mojo"), "5 10")
    # a row list that does not fit is ignored
    var wrong = List[Int]()
    wrong.append(1)
    assert_false(b.set_rows("/p/a.mojo", wrong))


def test_requests_and_answers() raises:
    var b = Breakpoints()
    _ = b.toggle("/p/a.mojo", 12)
    _ = b.toggle("/p/a.mojo", 4)
    _ = b.toggle("/p/a.mojo", 30)
    b.items[0].condition = "by == 7"
    b.items[0].hit = "5"
    b.items[2].log = "x={x}"
    _ = b.toggle("/p/a.mojo", 40)
    b.items[3].enabled = False          # not sent
    var req = json_parse(b.source_request("/p/a.mojo"))
    assert_equal(req.dump(), "{\"source\":{\"name\":\"a.mojo\",\"path\":\"/p/a.mojo\"},\"breakpoints\":[{\"line\":4},{\"line\":12,\"condition\":\"by == 7\",\"hitCondition\":\"5\"},{\"line\":30,\"logMessage\":\"x={x}\"}]}")
    assert_equal(b.source_request("/p/none.mojo"), "{\"source\":{\"name\":\"none.mojo\",\"path\":\"/p/none.mojo\"},\"breakpoints\":[]}")
    _ = b.add_function("fib")
    b.items[4].hit = "3"
    assert_equal(b.function_request(), "{\"breakpoints\":[{\"name\":\"fib\",\"hitCondition\":\"3\"}]}")
    # the answers come in the order of the request
    var ok = List[Bool]()
    ok.append(True)
    ok.append(False)
    ok.append(True)
    var lines = List[Int]()
    lines.append(4)
    lines.append(0)
    lines.append(31)
    var ids = List[Int]()
    ids.append(1)
    ids.append(2)
    ids.append(3)
    b.apply_report("/p/a.mojo", ok, lines, ids)
    assert_equal(b.items[1].verified, BV_OK)       # line 4
    assert_equal(b.items[0].verified, BV_NOT)      # line 12
    assert_equal(b.items[2].actual, 31)
    assert_equal(b.items[3].verified, BV_UNKNOWN, "a switched-off one was not sent")
    b.apply_change(2, True, 13)
    assert_equal(b.items[0].verified, BV_OK)
    assert_equal(b.items[0].actual, 13)
    b.forget_debugger()
    assert_equal(b.items[0].verified, BV_UNKNOWN)
    assert_equal(b.items[0].id, -1)


# ------------------------------------------------------------- in the IDE
def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.debug_adapter = "python3 tests/helpers/fake_dap_adapter.py '" + d + "/requests.log'"
    return app^


def row_text(mut app: App, y: Int) -> String:
    app.draw()
    var t = to_str(app.scr.to_text())
    var rows = t.split("\n")
    return String(rows[y]) if y < len(rows) else String("")


def settle(mut app: App, until_off: Bool) raises:
    var deadline = Int(perf_counter_ns()) + 5000 * MS
    while Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.dbg.fd())
        _ = wait_readable(fds, 20)
        app.debug_tick()
        if until_off and not app.dbg.active():
            return
        if not until_off and app.dbg.stop_line > 0:
            return


def test_gutter_shows_breakpoints_and_a_click_sets_them() raises:
    var d = scratch("gut")
    var text = String("")
    for k in range(1, 21):
        text += "line " + String(k) + "\n"
    put(d + "/a.mojo", text)
    var app = ide(d)
    app.open_path(d + "/a.mojo")
    var t = app.top_editor()
    app.wins[t].goto(2, 0)
    assert_equal(build_registry().find_key(fkey(8) | MOD_CTRL), CM_BP_TOGGLE)
    app.handle(key_event(fkey(8) | MOD_CTRL))
    assert_equal(app.status, "Breakpoint set on line 3")
    assert_equal(lines_of(app.bps, d + "/a.mojo"), "3")
    var y = app.wins[t].y + 3                   # the window's third text row
    var shown = row_text(app, y)
    assert_true(shown.find("●  3 line 3") >= 0 or shown.find("● 3 line 3") >= 0, shown)
    assert_true(row_text(app, y - 1).find("●") < 0)
    # a click on a line number sets one there; a click on the sign removes it
    var wx = app.wins[t].x
    app.handle(Event(EV_MOUSE, 0, wx + 2, app.wins[t].y + 6, MB_LEFT, True, False, List[Int]()))
    assert_equal(lines_of(app.bps, d + "/a.mojo"), "3 6")
    app.handle(Event(EV_MOUSE, 0, wx + 1, y, MB_LEFT, True, False, List[Int]()))
    assert_equal(lines_of(app.bps, d + "/a.mojo"), "6")
    assert_equal(app.wins[t].cr, 2, "a click in the gutter does not move the cursor")
    # off, or not placed: an outline
    app.bps.items[0].enabled = False
    app.bp_changed(d + "/a.mojo")
    assert_true(row_text(app, app.wins[t].y + 6).find("○") >= 0)
    _ = run_system("rm -rf '" + d + "'")


def test_breakpoints_move_with_edits_and_are_kept() raises:
    var d = scratch("edit")
    put(d + "/a.mojo", "a\nb\nc\nd\ne\nf\n")
    var app = ide(d)
    app.bp_enable(d + "/state")
    app.open_path(d + "/a.mojo")
    var t = app.top_editor()
    app.wins[t].goto(3, 0)
    app.exec(CM_BP_TOGGLE)                      # on "d"
    app.wins[t].goto(5, 0)
    app.exec(CM_BP_TOGGLE)                      # on "f"
    var kept = app.bp_file()
    assert_true(path_exists(kept))
    assert_equal(read_text(kept), "turbomojo breakpoints 1\nS\t1\t4\t" + d + "/a.mojo\t\t\t\nS\t1\t6\t" + d + "/a.mojo\t\t\t\n")
    # two lines typed above: both move down
    app.wins[t].goto(1, 0)
    app.wins[t].newline(False)
    app.wins[t].newline(False)
    app.draw()
    assert_equal(lines_of(app.bps, d + "/a.mojo"), "6 8")
    # the line "d" and the one before it deleted: its breakpoint goes to the line left
    _ = app.wins[t].buf.delete_raw(4, 0, 6, 0)
    app.draw()
    assert_equal(lines_of(app.bps, d + "/a.mojo"), "5 6", to_str(app.wins[t].buf.all_text()))
    # a new IDE in the same project has them again; closing it saved the moves
    app.bp_sync()               # what closing the IDE does
    app.bp_save()
    var again = ide(d)
    again.bp_enable(d + "/state")
    assert_equal(lines_of(again.bps, d + "/a.mojo"), "5 6")
    again.open_path(d + "/a.mojo")
    again.draw()
    var t2 = again.top_editor()
    assert_equal(len(again.wins[t2].buf.bps), 2)
    # removing them all removes the file
    again.exec(CM_BP_CLEAR)
    assert_equal(again.status, "Removed 2 breakpoints")
    assert_false(path_exists(kept))
    _ = run_system("rm -rf '" + d + "'")


def test_condition_dialog_and_function_breakpoints() raises:
    var d = scratch("dlg")
    put(d + "/a.mojo", "def fib(n: Int) -> Int:\n    return n\n")
    var app = ide(d)
    app.open_path(d + "/a.mojo")
    var t = app.top_editor()
    app.wins[t].goto(1, 4)
    app.exec(CM_BP_EDIT)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_BREAKPOINT)
    app.dlg.fields[0].text = decode("n > 3")
    app.dlg.fields[2].text = decode("n={n}")
    app.dialog_button(0)
    assert_equal(len(app.bps.items), 1, "the dialog set one where there was none")
    assert_equal(app.bps.items[0].describe(), "a.mojo:2  when n > 3  log \"n={n}\"")
    assert_true(row_text(app, app.wins[t].y + 2).find("◆") >= 0)
    # function breakpoint: the word at the cursor is offered
    app.wins[t].goto(0, 5)
    app.exec(CM_BP_FUNC)
    assert_equal(app.dlg.kind, D_BPFUNC)
    assert_equal(app.dlg.field_text(0), "fib")
    app.dialog_button(0)
    assert_equal(app.status, "Breakpoint set on the function fib")
    app.exec(CM_BP_FUNC)
    app.dialog_button(0)
    assert_equal(app.status, "There is a breakpoint on fib() already")
    # the list: switch off, delete
    app.exec(CM_BP_LIST)
    assert_equal(app.dlg.kind, D_BREAKPOINTS)
    assert_equal(len(app.dlg.items), 2)
    assert_true(app.dlg.items[0].startswith("◆ a.mojo:2"))
    assert_equal(app.dlg.items[1], "● fib()")
    app.dlg.list_sel = 1
    app.dialog_button(2)
    assert_equal(app.dlg.items[1], "○ fib()  (off)")
    app.dialog_button(3)
    assert_equal(len(app.bps.items), 1)
    _ = run_system("rm -rf '" + d + "'")


def test_the_debugger_gets_the_breakpoints_and_stops_there() raises:
    var d = scratch("dbg")
    var text = String("")
    for k in range(1, 121):
        text += "line " + String(k) + "\n"
    put(d + "/bp.mojo", text)
    var app = ide(d)
    app.open_path(d + "/bp.mojo")
    var t = app.top_editor()
    for line in [7, 99, 1500]:
        app.wins[t].goto(line - 1 if line < 121 else 0, 0)
        if line == 1500:
            _ = app.bps.toggle(d + "/bp.mojo", 1500)     # a line the debugger refuses
            app.bp_changed(d + "/bp.mojo")
        else:
            app.exec(CM_BP_TOGGLE)
    app.bps.items[0].log = "seven {x}"
    _ = app.bps.add_function("fib")
    _ = app.bps.add_function("nosuch")
    app.bp_changed("")
    app.wins[t].goto(0, 0)
    app.debug_launch(d + "/build/bp", d + "/bp.mojo")
    settle(app, False)
    assert_equal(app.dbg.state, DS_STOPPED)
    assert_equal(app.wins[app.top_editor()].cr, 6, "the editor is on the stop's line")
    # what the debugger answered is in the list
    assert_equal(app.bps.items[0].verified, BV_OK)
    assert_equal(app.bps.items[1].actual, 100)
    assert_equal(app.bps.items[2].verified, BV_NOT)
    assert_equal(app.bps.items[3].verified, BV_OK)
    assert_equal(app.bps.items[4].verified, BV_NOT)
    # the message of the log point is in the program's output
    assert_true(bytes_to_str(app.dbg.output).find("seven {x}\n") >= 0, bytes_to_str(app.dbg.output))
    # a breakpoint set while the program is stopped goes to the debugger at once
    app.wins[app.top_editor()].goto(19, 0)
    app.exec(CM_BP_TOGGLE)
    var deadline = Int(perf_counter_ns()) + 3000 * MS
    while Int(perf_counter_ns()) < deadline and app.bps.items[app.bps.find(d + "/bp.mojo", 20)].verified == BV_UNKNOWN:
        var fds = List[Int]()
        fds.append(app.dbg.fd())
        _ = wait_readable(fds, 20)
        app.debug_tick()
    assert_equal(app.bps.items[app.bps.find(d + "/bp.mojo", 20)].verified, BV_OK)
    app.debug_end(True)
    assert_equal(app.bps.items[0].verified, BV_UNKNOWN, "the session is over")
    var log = read_text(d + "/requests.log")
    assert_true(log.find("setBreakpoints {\"breakpoints\": [{\"line\": 7, \"logMessage\": \"seven {x}\"}, {\"line\": 99}, {\"line\": 1500}], \"source\": {\"name\": \"bp.mojo\", \"path\": \"" + d + "/bp.mojo\"}}") > 0, log)
    assert_true(log.find("setFunctionBreakpoints {\"breakpoints\": [{\"name\": \"fib\"}, {\"name\": \"nosuch\"}]}") > 0, log)
    assert_true(log.find("{\"line\": 20}") > 0, log)
    # configuration comes before configurationDone
    assert_true(log.find("setFunctionBreakpoints") < log.find("configurationDone"))
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
