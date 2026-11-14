"""Tests for the CPU window: machine code, registers and memory of a stopped program
(src/cpuview.mojo, src/app_debug.mojo). Answers are shaped like Mojo 1.2's debugger
gives them; the debugger is tests/helpers/fake_dap_adapter.py."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from cpuview import *
from dap import *
from term import wait_readable, fkey, key_event, MOD_ALT, KEY_ENTER
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_MEMADDR
from window import WK_CPU
from commands import CM_CPUWIN, build_registry
from config import read_text
from signals import own_pid
from util import to_str, env_or, run_system, decode

comptime MS = 1000000


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-cpu-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def test_numbers_and_bytes() raises:
    assert_equal(address_value("0xAAAAAAAA0F20"), 0xAAAAAAAA0F20)
    assert_equal(address_value("0x0000ffffffffe060"), 0xFFFFFFFFE060)
    assert_equal(address_value(" 0x10 "), 16)
    assert_equal(address_value("1234"), -1)
    assert_equal(address_value("0xZZ"), -1)
    assert_equal(address_value("0x"), -1)
    assert_equal(hex_text(0xFFFFFFFFE480), "0x0000FFFFFFFFE480")
    assert_equal(hex_text(255, 4), "0x00FF")
    var d = base64_decode("KQAAAAAAAAA=")
    assert_equal(len(d), 8)
    assert_equal(Int(d[0]), 41)
    var man = base64_decode("TWFu")
    assert_equal(String(chr(Int(man[0]))) + String(chr(Int(man[1]))) + String(chr(Int(man[2]))), "Man")
    assert_equal(len(base64_decode("TWE=")), 2)
    assert_equal(len(base64_decode("")), 0)
    assert_true(keep_register("x0", "0x0000ffffffffde5c"))
    assert_true(keep_register("x1", "0x0000aaaaaaaaa350 vars`static_string_b65d"))
    assert_true(keep_register("cpsr", "0x80001000"))
    assert_false(keep_register("w0", "0xffffde5c"), "a 32-bit view of x0")
    assert_equal(format_simd_lanes("{0x00 0x00 0x80 0x3f 0x00 0x00 0x00 0x40}", 1), "[1.0, 2.0]")
    assert_equal(format_simd_lanes("{0x2a 0x00 0x00 0x00 0xff 0xff 0xff 0xff}", 2), "[42, -1]")
    assert_equal(format_simd_lanes("{0x01 0x02 0x03 0x04}", 0), "[0x04030201]")


def test_the_window_text() raises:
    var c = CpuView()
    assert_true("\n".join(c.lines()).startswith("Code\n  (no program is stopped)\n\nRegisters"))
    c.ip = "0xAAAA0F24"
    c.code.append(Instr("0xAAAA0F20", "ldr     x8, [sp, #0xf8]          ", "/p/vars.mojo", 18))
    c.code.append(Instr("0xAAAA0F24", "nop                              ", "/p/vars.mojo", 19))
    c.code.append(Instr("0xAAAA0F28", "bl      0xaaaa45b0  ; String::__add__", "", 0))
    var names = List[String]()
    var values = List[String]()
    for x in [("x0", "0x0000000000000001"), ("w0", "0x00000001"), ("sp", "0x0000ffffffffe060"), ("pc", "0x0000aaaaaaaa0f24")]:
        names.append(String(x[0]))
        values.append(String(x[1]))
    c.set_regs(names, values)
    assert_equal(len(c.regs), 3)
    assert_false(c.regs[0].changed, "nothing to compare with yet")
    values[3] = "0x0000aaaaaaaa0f28"
    c.set_regs(names, values)
    assert_true(c.regs[2].changed and not c.regs[0].changed)
    assert_equal(c.register("sp"), 0xFFFFFFFFE060)
    assert_equal(c.register("x9"), -1)
    c.mem_address = 0x1000
    for i in range(20):
        c.mem.append(UInt8(65 + i if i != 3 else 7))
    c.mem_known = 18
    var text = "\n".join(c.lines())
    assert_equal(text, "Code\n    vars.mojo:18\n  0xAAAA0F20  ldr     x8, [sp, #0xf8]\n    vars.mojo:19\n► 0xAAAA0F24  nop\n  0xAAAA0F28  bl      0xaaaa45b0  ; String::__add__\n\nRegisters   (* changed since the last stop)\n  x0    0x0000000000000001  sp    0x0000ffffffffe060 *pc    0x0000aaaaaaaa0f28\n\nMemory at 0x0000000000001000   (G: go to, + / -: next / previous)\n  0000000000001000  41 42 43 07 45 46 47 48 49 4a 4b 4c 4d 4e 4f 50  ABC.EFGHIJKLMNOP\n  0000000000001010  51 52 ?? ??  QR??")


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(130, 40)
    app.cwd = d
    app.debug_adapter = "env FAKE_DAP_SOURCE='" + d + "/vars.mojo' python3 tests/helpers/fake_dap_adapter.py '" + d + "/requests.log'"
    return app^


def cpu_text(app: App) -> String:
    var ci = app.cpuwin_index()
    if ci < 0:
        return "(no CPU window)"
    var s = String("")
    for r in range(app.wins[ci].buf.count()):
        if r > 0:
            s += "\n"
        s += to_str(app.wins[ci].buf.line(r))
    return s


def follow(mut app: App, done: String, timeout_ms: Int = 5000) raises -> String:
    var deadline = Int(perf_counter_ns()) + timeout_ms * MS
    var text = String("")
    while Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.dbg.fd())
        _ = wait_readable(fds, 20)
        app.debug_tick()
        text = cpu_text(app)
        if text.find(done) >= 0:
            return text
    return text


def test_the_cpu_window_at_a_stop() raises:
    var d = scratch("win")
    var src = String("")
    for k in range(1, 13):
        src += "line " + String(k) + "\n"
    put(d + "/vars.mojo", src)
    var app = ide(d)
    app.open_path(d + "/vars.mojo")
    assert_equal(build_registry().find_key(fkey(2) | MOD_ALT), CM_CPUWIN)
    app.exec(CM_CPUWIN)
    assert_true(cpu_text(app).startswith("Code\n  (no program is stopped)"), cpu_text(app))
    app.debug_launch(d + "/build/vars", d + "/vars.mojo")
    var text = follow(app, "Memory at 0x0000FFFFFFFFE060")
    text = follow(app, "0000FFFFFFFFE060  60 61")
    assert_true(text.find("    vars.mojo:5\n► 0x0000AAAA0F20  nop\n") > 0, text)
    assert_true(text.find("  x0    0x0000ffffffffde5c  x1    0x0000aaaaaaaaa350  sp    0x0000ffffffffe060") > 0, text)
    assert_true(text.find("w0") < 0, "32-bit views are left out")
    assert_true(text.find("0000FFFFFFFFE060  60 61 62 63") > 0, text)
    assert_true(text.find("?? ?? ??") > 0, "unreadable bytes are shown as such")
    # F7 in the CPU window: one instruction; the pc is marked as changed
    var ci = app.cpuwin_index()
    app.focus(ci)
    app.handle(key_event(fkey(7)))
    text = follow(app, "► 0x0000AAAA0F24")
    text = follow(app, "*pc")
    assert_true(text.find("► 0x0000AAAA0F24") > 0 and text.find("*pc") > 0, text)
    assert_equal(app.wins[app.top()].kind, WK_CPU, "the keyboard stays in the CPU window")
    assert_true(read_text(d + "/requests.log").find("stepIn {\"granularity\": \"instruction\", \"threadId\": 7}") > 0)
    assert_equal(app.dbg.stop_file, "", "inside a line: no source line to show")
    # memory: + moves on, G goes to an address or a variable
    app.handle(key_event(43))
    text = follow(app, "Memory at 0x0000FFFFFFFFE0E0")
    app.handle(key_event(103))
    assert_equal(app.dlg.kind, D_MEMADDR)
    app.dlg.fields[0].text = decode("0x20")
    app.dialog_button(0)
    text = follow(app, "Memory at 0x0000000000000020")
    assert_true(text.find("0000000000000020  ?? ?? ") > 0, text)
    app.handle(key_event(103))
    app.dlg.fields[0].text = decode("n")
    app.dialog_button(0)
    text = follow(app, "Memory at 0x000000000000FF00")
    assert_true(text.find("Memory at 0x000000000000FF00") > 0, text)
    app.handle(key_event(103))
    app.dlg.fields[0].text = decode("nosuch")
    app.dialog_button(0)
    _ = follow(app, "zzz-never", 400)
    assert_true(app.status.startswith("The debugger does not say where that is"), app.status)
    # the end of the session; Alt-F2 closes the window
    app.debug_end(True)
    assert_true(cpu_text(app).startswith("Code\n  (no program is stopped)"), cpu_text(app))
    app.exec(CM_CPUWIN)
    assert_equal(app.cpuwin_index(), -1)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
