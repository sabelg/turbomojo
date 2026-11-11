"""Tests for the Debug window: the call stack and the variables of a stopped program
(src/dbgview.mojo, src/app_debug.mojo). Values are shaped like Mojo 1.2's debugger shows
them; the debugger is tests/helpers/fake_dap_adapter.py."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from dbgview import *
from dap import *
from term import wait_readable, fkey, key_event, MOD_CTRL, MOD_SHIFT, KEY_ENTER, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_DELETE
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_SETVALUE, D_WATCH, D_EVALUATE
from window import WK_DEBUG
from commands import CM_DEBUGWIN, CM_WATCH_ADD, CM_EVALUATE, build_registry
from config import read_text
from signals import own_pid
from util import to_str, env_or, run_system, decode

comptime MS = 1000000
comptime IDX = "__mlir_type.`!kgen.scalar<index>`"


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-dv-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def hexes(b: List[UInt8]) -> String:
    var s = String("")
    for x in b:
        var digits = "0123456789abcdef"
        s += String(digits[byte=Int(x) // 16:Int(x) // 16 + 1]) + String(digits[byte=Int(x) % 16:Int(x) % 16 + 1])
    return s


# ------------------------------------------------------------- values
def test_values_and_types_read_like_mojo() raises:
    assert_equal(nice_value("0400000000000000  4"), "4")
    assert_equal(nice_value("0000000000000440  2.5"), "2.5")
    assert_equal(nice_value("01 True"), "True")
    assert_equal(nice_value("e026cdaaaaaa0000  187649986733792"), "187649986733792")
    assert_equal(nice_value("\"mojo\""), "\"mojo\"")
    assert_equal(nice_value("(size 4)[0, 1, 4, 9]"), "(size 4)[0, 1, 4, 9]")
    assert_equal(nice_value("Point"), "Point")
    assert_equal(nice_value("0x0000aaaaaaaaa360 109"), "0x0000aaaaaaaaa360 109", "a pointer stays")
    assert_equal(nice_value("abc def"), "abc def", "an odd number of hex digits is not raw bytes")
    assert_equal(nice_type(IDX), "Int")
    assert_equal(nice_type("__mlir_type.`!kgen.scalar<bool>`"), "Bool")
    assert_equal(nice_type("__mlir_type.`!kgen.scalar<f64>`"), "Float64")
    assert_equal(nice_type("__mlir_type.si64"), "Int64")
    assert_equal(nice_type("__mlir_type.ui8"), "UInt8")
    assert_equal(nice_type("__mlir_type.i1"), "Bool")
    assert_equal(nice_type("__mlir_type.`!kgen.pointer<scalar<ui8>>`"), "`!kgen.pointer<scalar<ui8>>`")
    assert_equal(nice_type("Point"), "Point")
    assert_equal(scalar_kind("String"), "")


def test_values_become_bytes() raises:
    var e = encode_value(IDX, "41")
    assert_equal(e[1], "")
    assert_equal(hexes(e[0]), "2900000000000000")
    assert_equal(hexes(encode_value(IDX, "-2")[0]), "feffffffffffffff")
    assert_equal(hexes(encode_value("__mlir_type.`!kgen.scalar<f64>`", "-1.25")[0]), "000000000000f4bf")
    assert_equal(hexes(encode_value("__mlir_type.`!kgen.scalar<f32>`", "2.5")[0]), "00002040")
    assert_equal(hexes(encode_value("__mlir_type.`!kgen.scalar<bool>`", "False")[0]), "00")
    assert_equal(hexes(encode_value("__mlir_type.`!kgen.scalar<bool>`", "true")[0]), "01")
    assert_equal(hexes(encode_value("__mlir_type.si8", "-128")[0]), "80")
    assert_equal(encode_value("__mlir_type.si8", "128")[1], "128 does not fit in Int8")
    assert_equal(encode_value("__mlir_type.ui8", "-1")[1], "-1 does not fit in UInt8")
    assert_equal(encode_value(IDX, "4.5")[1], "not a whole number: 4.5")
    assert_equal(encode_value("__mlir_type.`!kgen.scalar<bool>`", "yes")[1], "a Bool is True or False")
    assert_equal(encode_value("String", "x")[1], "values of type String cannot be set here")
    var b = List[UInt8]()
    assert_equal(base64(b), "")
    b.append(41)
    for _ in range(7):
        b.append(0)
    assert_equal(base64(b), "KQAAAAAAAAA=")
    var abc = List[UInt8]()
    for c in "Man".as_bytes():
        abc.append(c)
    assert_equal(base64(abc), "TWFu")
    _ = abc.pop()
    assert_equal(base64(abc), "TWE=")
    assert_equal(address_in("(*( (!kgen.scalar<index> *)0x50353fe04008))"), "0x50353fe04008")
    assert_equal(address_in("p.x"), "")


def test_the_tree_opens_closes_and_remembers() raises:
    var v = DebugView()
    v.frames.append(FrameRow(1, "a::work(...)", "/p/a.mojo", 5))
    v.frames.append(FrameRow(2, "std::print(...)", "", 9))
    var top = List[VarNode]()
    top.append(VarNode("n", IDX, "0400000000000000  4", 4, "0xFF00", "n", 0, ""))
    top.append(VarNode("p", "Point", "Point", 8, "", "p", 0, ""))
    v.put_children("", top^)
    assert_equal(v.nodes[0].path, "n")
    assert_false(v.nodes[0].has_children(), "a scalar's [0] child is not offered")
    assert_true(v.nodes[0].settable())
    assert_true(v.nodes[1].has_children())
    var shown = v.lines()
    assert_equal("\n".join(shown), "Call stack\n► a::work(...)   a.mojo:5\n  std::print(...)   (no source)\n\nVariables of a::work(...)\n  n = 4   Int\n▸ p: Point")
    assert_equal(v.rows_kind[1], VK_FRAME)
    assert_equal(v.rows_kind[5], VK_VAR)
    assert_equal(v.rows_index[6], 1)
    # opening p
    v.mark_open(1)
    var kids = List[VarNode]()
    kids.append(VarNode("x", IDX, "0400000000000000  4", 14, "", "p.x", 0, ""))
    v.put_children("p", kids^)
    assert_equal(v.nodes[2].path, "p\tx")
    assert_equal(v.nodes[2].depth, 1)
    assert_false(v.nodes[2].settable(), "the debugger does not say where a field is")
    assert_true("\n".join(v.lines()).endswith("▾ p: Point\n    x = 4   Int"))
    # after a step everything is asked for again: p opens by itself
    var again = List[VarNode]()
    again.append(VarNode("n", IDX, "0500000000000000  5", 4, "0xFF00", "n", 0, ""))
    again.append(VarNode("p", "Point", "Point", 8, "", "p", 0, ""))
    v.nodes.clear()
    v.put_children("", again^)
    var want = v.wanted()
    assert_equal(len(want), 1)
    assert_equal(v.nodes[want[0]].name, "p")
    # closing forgets it (and what was open inside)
    v.nodes[1].open = True
    v.close(1)
    assert_equal(len(v.opened), 0)
    assert_equal(len(v.wanted()), 0)
    # an answer for a node that is gone is dropped
    v.put_children("q", List[VarNode]())
    assert_equal(len(v.nodes), 2)
    var empty = DebugView()
    empty.put_children("", List[VarNode]())
    assert_true("\n".join(empty.lines()).endswith("Variables\n  (no variables)"))


# ------------------------------------------------------------- in the IDE
def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.debug_adapter = "env FAKE_DAP_SOURCE='" + d + "/vars.mojo' python3 tests/helpers/fake_dap_adapter.py '" + d + "/requests.log'"
    return app^


def follow(mut app: App, done: String, timeout_ms: Int = 5000) raises -> String:
    """Let the IDE follow the session until the Debug window shows `done`."""
    var deadline = Int(perf_counter_ns()) + timeout_ms * MS
    var text = String("")
    while Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.dbg.fd())
        _ = wait_readable(fds, 20)
        app.debug_tick()
        text = window_text(app)
        if text.find(done) >= 0:
            return text
    return text


def window_text(app: App) -> String:
    var di = app.debugwin_index()
    if di < 0:
        return "(no Debug window)"
    var s = String("")
    for r in range(app.wins[di].buf.count()):
        if r > 0:
            s += "\n"
        s += to_str(app.wins[di].buf.line(r))
    return s


def row_of(app: App, text: String) -> Int:
    var di = app.debugwin_index()
    for r in range(app.wins[di].buf.count()):
        if to_str(app.wins[di].buf.line(r)).find(text) >= 0:
            return r
    return -1


def press_at(mut app: App, text: String, k: Int) raises:
    var di = app.debugwin_index()
    app.focus(di)
    di = app.debugwin_index()
    var r = row_of(app, text)
    assert_true(r >= 0, "no line with " + text + ":\n" + window_text(app))
    app.wins[di].cr = r
    app.handle(key_event(k))


def test_the_debug_window_shows_stack_and_variables() raises:
    var d = scratch("win")
    var src = String("")
    for k in range(1, 13):
        src += "line " + String(k) + "\n"
    put(d + "/vars.mojo", src)
    var app = ide(d)
    app.open_path(d + "/vars.mojo")
    assert_equal(build_registry().find_key(fkey(3) | MOD_CTRL), CM_DEBUGWIN)
    app.debug_launch(d + "/build/vars", d + "/vars.mojo")
    var text = follow(app, "flag = True")
    assert_equal(text, "Call stack\n► vars::work(...)   vars.mojo:5\n  vars::main()   vars.mojo:9\n  std::builtin::_startup::__mojo_main_prototype(...)   (no source)\n\nVariables of vars::work(...)\n  n = 4   Int\n  flag = True   Bool\n▸ p: Point\n▸ items = (size 2)[0, 1]   List")
    assert_true(app.debugwin_index() >= 0, "the first stop opened the window")
    # open p and items
    press_at(app, "p: Point", KEY_ENTER)
    text = follow(app, "x = 4")
    press_at(app, "items =", KEY_RIGHT)
    text = follow(app, "[1] = 1")
    assert_true(text.endswith("▾ p: Point\n    x = 4   Int\n    y = 2.5   Float64\n▾ items = (size 2)[0, 1]   List\n    [0] = 0   Int\n    [1] = 1   Int"), text)
    # ← closes
    press_at(app, "items =", KEY_LEFT)
    assert_true(window_text(app).endswith("▸ items = (size 2)[0, 1]   List"), window_text(app))
    # set a value: n = 41, written as memory; the variables are read again
    press_at(app, "n = 4", KEY_ENTER)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_SETVALUE)
    assert_equal(app.dlg.field_text(0), "4")
    app.dlg.fields[0].text = decode("41")
    app.dialog_button(0)
    text = follow(app, "n = 41")
    assert_true(text.find("n = 41   Int") > 0, text)
    text = follow(app, "▾ p: Point\n    x = 4")         # (its children are asked for again)
    assert_true(text.find("▾ p: Point\n    x = 4") > 0, "p stays open:\n" + text)
    assert_true(read_text(d + "/requests.log").find("writeMemory {\"data\": \"KQAAAAAAAAA=\", \"memoryReference\": \"0xFF00\"}") > 0)
    # a field cannot be set: the window says why, nothing is written
    press_at(app, "x = 4", 61)
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.status.startswith("The debugger does not say where x is"), app.status)
    press_at(app, "p: Point", 61)
    assert_true(app.status.startswith("Only numbers and Bools can be set (p is a Point)"), app.status)
    # a bad value is refused before anything is sent
    press_at(app, "flag = True", KEY_ENTER)
    app.dlg.fields[0].text = decode("perhaps")
    app.dialog_button(0)
    assert_equal(app.status, "Not set: a Bool is True or False")
    # the caller's frame: its line is shown, its variables listed
    press_at(app, "vars::main()", KEY_ENTER)
    text = follow(app, "r = 7")
    assert_true(text.find("► vars::main()") > 0 and text.find("Variables of vars::main()\n  r = 7   Int") > 0, text)
    var t = app.top_editor()
    assert_equal(app.wins[t].cr, 8)
    assert_equal(app.wins[app.top()].kind, WK_DEBUG, "the keyboard stays in the Debug window")
    # a frame without a source: nothing to show, but its variables are asked for
    press_at(app, "__mojo_main_prototype", KEY_ENTER)
    # a step: the window says the program runs, then shows the new stop, p open again
    app.focus(app.top_editor())
    app.handle(key_event(fkey(8)))
    text = follow(app, "vars.mojo:6")
    text = follow(app, "x = 4")
    assert_true(text.find("► vars::work(...)   vars.mojo:6") > 0 and text.find("▾ p: Point\n    x = 4") > 0, text)
    # the end of the session
    app.debug_end(True)
    assert_true(window_text(app).endswith("Variables\n  (no program is being debugged)"), window_text(app))
    # Ctrl-F3 closes and opens it
    app.exec(CM_DEBUGWIN)
    assert_equal(app.debugwin_index(), -1)
    app.exec(CM_DEBUGWIN)
    assert_true(app.debugwin_index() >= 0)
    _ = run_system("rm -rf '" + d + "'")


def test_watch_and_console_texts() raises:
    assert_equal(watch_text("n", True, "0400000000000000  4", IDX, ""), "n = 4   Int")
    assert_equal(watch_text("p", True, "Point", "Point", ""), "p: Point")
    assert_equal(watch_text("n + 1", False, "", "", "error: invalid value object"), "n + 1: cannot be evaluated (only names and fields: a, a.b)")
    assert_equal(watch_text("q", False, "", "", "no frame"), "q: no frame")
    assert_equal(console_command(":frame variable"), "`frame variable")
    assert_equal(console_result("(String)  = \"mojo\""), "\"mojo\"   String")
    assert_equal(console_result("(__mlir_type.`!kgen.scalar<index>`)  = 8"), "8   Int")
    assert_equal(console_result("(Point) p = (x = 4, y = 2.5)\n(String) s = 1"), "(Point) p = (x = 4, y = 2.5)\n(String) s = 1")
    assert_equal(console_command("  p.x "), "p.x")
    var v = DebugView()
    v.watches.append("n")
    v.watches.append("p.x")
    v.watch_shown.append("n = 4   Int")
    var text = "\n".join(v.lines())
    assert_true(text.find("\n\nWatches\n  n = 4   Int\n  p.x: ?\n\nVariables") > 0, text)
    assert_equal(v.rows_kind[4], VK_WATCH)
    assert_equal(v.rows_index[5], 1)


def test_watches_and_evaluate_in_the_ide() raises:
    var d = scratch("watch")
    var src = String("")
    for k in range(1, 13):
        src += "line " + String(k) + "\n"
    put(d + "/vars.mojo", src)
    var app = ide(d)
    app.bp_enable(d + "/state")
    app.open_path(d + "/vars.mojo")
    # watches can be set before anything runs
    app.handle(key_event(fkey(7) | MOD_CTRL))
    assert_equal(app.dlg.kind, D_WATCH)
    app.dlg.fields[0].text = decode("n")
    app.dialog_button(0)
    assert_true(app.debugwin_index() >= 0, "adding a watch shows the Debug window")
    for w in ["p.x", "n + 1", "p"]:
        app.exec(CM_WATCH_ADD)
        app.dlg.fields[0].text = decode(w)
        app.dialog_button(0)
    app.exec(CM_WATCH_ADD)
    app.dlg.fields[0].text = decode("n")
    app.dialog_button(0)
    assert_equal(app.status, "n is watched already")
    assert_equal(read_text(app.watches_file()), "n\np.x\nn + 1\np\n")
    # at the stop they are evaluated
    app.debug_launch(d + "/build/vars", d + "/vars.mojo")
    var text = follow(app, "p: Point\n\nVariables")
    assert_true(text.find("Watches\n  n = 4   Int\n  p.x = 4   Int\n  n + 1: cannot be evaluated (only names and fields: a, a.b)\n  p: Point\n") > 0, text)
    # Del removes a watch; Enter changes one
    press_at(app, "n + 1:", KEY_DELETE)
    assert_true(window_text(app).find("n + 1") < 0)
    press_at(app, "p.x = 4", KEY_ENTER)
    assert_equal(app.dlg.kind, D_WATCH)
    assert_equal(app.dlg.field_text(0), "p.x")
    app.dlg.fields[0].text = decode("p")
    app.dialog_button(0)
    assert_equal(app.status, "p is watched already")
    press_at(app, "p.x = 4", KEY_ENTER)
    app.dlg.fields[0].text = decode("p.y")
    app.dialog_button(0)
    assert_equal(read_text(app.watches_file()), "n\np.y\np\n")
    # Evaluate (Ctrl-F4): a name; a debugger command after ':'; something it cannot do
    app.handle(key_event(fkey(4) | MOD_CTRL))
    assert_equal(app.dlg.kind, D_EVALUATE)
    app.dlg.fields[0].text = decode("n")
    app.dialog_button(0)
    assert_true(app.dlg.lines[0] == "(asking the debugger...)")
    _ = follow(app, "zzz-never", 400)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_EVALUATE)
    assert_equal(app.dlg.lines[0], "4   Int")
    app.dlg.fields[0].text = decode(":frame variable")
    app.dialog_button(0)
    _ = follow(app, "zzz-never", 400)
    assert_equal(" | ".join(app.dlg.lines), "(__mlir_type.`!kgen.scalar<index>`) n = 4 | (Point) p = (x = 4, y = 2.5)")
    app.dlg.fields[0].text = decode("n * 2")
    app.dialog_button(0)
    _ = follow(app, "zzz-never", 400)
    assert_equal(app.dlg.lines[0], "cannot be evaluated: Mojo's debugger knows names and fields (a, a.b), not expressions")
    # Watch from the dialog adds the expression
    app.dlg.fields[0].text = decode("p.x")
    app.dialog_button(1)
    assert_equal(app.mode, M_NORMAL)
    # the transcript is in the Message window
    var mi = app.msg_index()
    var msgs = String("")
    for r in range(app.wins[mi].buf.count()):
        msgs += to_str(app.wins[mi].buf.line(r)) + "\n"
    assert_true(msgs.find("> n\n4   Int\n> :frame variable\n(__mlir_type.`!kgen.scalar<index>`) n = 4\n(Point) p = (x = 4, y = 2.5)\n> n * 2\ncannot be evaluated") >= 0, msgs)
    # while it runs, the watches say so; Evaluate says to stop first
    app.focus(app.top_editor())
    app.handle(key_event(fkey(5) | MOD_SHIFT))      # continue: the fake ends the program
    _ = follow(app, "zzz-never", 400)
    app.exec(CM_EVALUATE)
    app.dlg.fields[0].text = decode("n")
    app.dialog_button(0)
    assert_equal(app.dlg.lines[0], "The program has to be stopped first (a breakpoint, F4, Shift-F5 pauses).")
    app.mode = M_NORMAL
    # a new IDE in the project has the watches again
    var again = ide(d)
    again.bp_enable(d + "/state")
    assert_equal(", ".join(again.dview.watches), "n, p.y, p, p.x")
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
