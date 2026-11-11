"""Tests for the integrated terminal (src/app_terminal.mojo, src/termkeys.mojo): a shell
and Run in windows at the bottom, keys and paste to the program, scrollback, selection.
Real programs on real ptys."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from std.ffi import external_call
from termkeys import encode_key, paste_bytes
from termsession import *
from term import Event, EV_MOUSE, EV_PASTE, MB_LEFT, MB_WHEEL_UP, wait_readable, fkey, key_event, ctrl, alt, MOD_CTRL, MOD_SHIFT, MOD_ALT, KEY_ENTER, KEY_UP, KEY_LEFT, KEY_PGUP, KEY_PGDN, KEY_ESC, KEY_DELETE, KEY_TAB, KEY_BACKSPACE, KEY_F1, KEY_HOME
from app import *
from appstate import App, M_NORMAL
from window import WK_TERM, WK_EDITOR
from commands import CM_TERMINAL, CM_RUN, build_registry
from config import load_settings, read_text
from signals import own_pid
from util import to_str, env_or, run_system, bytes_to_str, decode

comptime MS = 1000000


def b(s: List[UInt8]) -> String:
    var out = String("")
    for x in s:
        var c = Int(x)
        out += String(chr(c)) if c >= 32 and c < 127 else "<" + String(c) + ">"
    return out


def test_keys_become_bytes() raises:
    assert_equal(b(encode_key(97, False)), "a")
    assert_equal(b(encode_key(0x6F22, False)), "<230><188><162>")
    assert_equal(b(encode_key(ctrl(99), False)), "<3>", "Ctrl-C")
    assert_equal(b(encode_key(ctrl(100), False)), "<4>")
    assert_equal(b(encode_key(alt(98), False)), "<27>b")
    assert_equal(b(encode_key(KEY_ENTER, False)), "<13>")
    assert_equal(b(encode_key(KEY_BACKSPACE, False)), "<127>")
    assert_equal(b(encode_key(KEY_TAB | MOD_SHIFT, False)), "<27>[Z")
    assert_equal(b(encode_key(KEY_UP, False)), "<27>[A")
    assert_equal(b(encode_key(KEY_UP, True)), "<27>OA", "application cursor keys")
    assert_equal(b(encode_key(KEY_LEFT | MOD_CTRL, False)), "<27>[1;5D")
    assert_equal(b(encode_key(KEY_HOME, False)), "<27>[H")
    assert_equal(b(encode_key(KEY_DELETE, False)), "<27>[3~")
    assert_equal(b(encode_key(KEY_PGUP | MOD_SHIFT, False)), "<27>[5;2~")
    assert_equal(b(encode_key(fkey(1), False)), "<27>OP")
    assert_equal(b(encode_key(fkey(5), False)), "<27>[15~")
    assert_equal(b(encode_key(fkey(12) | MOD_CTRL, False)), "<27>[24;5~")
    assert_equal(b(encode_key(KEY_ESC, False)), "<27>")
    var t = decode("a\r\nb\x1bc")
    assert_equal(b(paste_bytes(t, False)), "a<13>b<27>c")
    assert_equal(b(paste_bytes(t, True)), "<27>[200~a<13>bc<27>[201~", "no ESC inside a bracketed paste")


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    return app^


def turn(mut app: App):
    var fds = app.term_fds()
    _ = wait_readable(fds, 20)
    app.term_tick()


def screen_of(mut app: App, which: Int) -> String:
    var s = app.term_take(which)
    var text = s.vt.text()
    app.term_put(which, s^)
    return text


def wait_screen(mut app: App, which: Int, text: String, timeout_ms: Int = 8000) raises -> String:
    var deadline = Int(perf_counter_ns()) + timeout_ms * MS
    var shown = String("")
    while Int(perf_counter_ns()) < deadline:
        turn(app)
        shown = screen_of(app, which)
        if shown.find(text) >= 0:
            return shown
    assert_true(False, "no \"" + text + "\" on the terminal:\n" + shown)
    return shown


def typ(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))


def test_a_shell_in_a_window() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-term-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && echo hi > '" + d + "/file.txt'")
    var app = ide(d)
    app.shell_program = "/bin/sh"               # not the user's shell and its start-up files
    app.exec(1)                                 # a new editor
    assert_equal(build_registry().find_key(fkey(11) | MOD_ALT), CM_TERMINAL)
    app.handle(key_event(fkey(11) | MOD_ALT))
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_TERM)
    assert_true(app.wins[t].title.startswith("Terminal"), app.wins[t].title)
    assert_true(app.tshell.pty.running)
    # what is typed goes to the shell; its output is on the screen; it runs in the project
    typ(app, "echo hello-$((6*7)); pwd; ls")
    app.handle(key_event(KEY_ENTER))
    var shown = wait_screen(app, TS_SHELL, "file.txt")
    assert_true(shown.find("hello-42") >= 0 and shown.find(d) >= 0, shown)
    # Ctrl-K is a key for the program, not the IDE's Ctrl-K prefix; Ctrl-C interrupts
    typ(app, "sleep 30")
    app.handle(key_event(KEY_ENTER))
    _ = wait_screen(app, TS_SHELL, "sleep 30")
    _ = external_call["usleep", Int32](UInt32(400000))     # until sleep itself runs
    app.handle(key_event(ctrl(99)))
    # (what is typed while the interrupt is handled is thrown away by the terminal, as
    # in any terminal: wait for the prompt to come back)
    _ = wait_screen(app, TS_SHELL, "^C")
    var back_at = Int(perf_counter_ns()) + 5000 * MS
    while Int(perf_counter_ns()) < back_at and not String(screen_of(app, TS_SHELL).rstrip()).endswith("$"):
        turn(app)                               # until the shell's prompt "$ " is back
    typ(app, "echo after-interrupt")
    app.handle(key_event(KEY_ENTER))
    _ = wait_screen(app, TS_SHELL, "after-interrupt\n", 5000)
    assert_equal(app.chord, 0)
    # paste goes to the shell
    app.handle(Event(EV_PASTE, 0, 0, 0, 0, False, False, decode("echo pasted-text\n")))
    _ = wait_screen(app, TS_SHELL, "pasted-text\n")
    # the size follows the window
    typ(app, "stty size")
    app.handle(key_event(KEY_ENTER))
    _ = wait_screen(app, TS_SHELL, String(app.wins[t].h - 2) + " " + String(app.wins[t].w - 2))
    # F6 leaves the terminal for the editor; the shell goes on
    app.handle(key_event(fkey(6)))
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    typ(app, "x")
    assert_equal(to_str(app.wins[app.top()].buf.line(0)), "x", "keys are the editor's again")
    # Alt-F12 brings it back; again closes the window; the shell keeps running
    app.handle(key_event(fkey(11) | MOD_ALT))
    assert_equal(app.wins[app.top()].kind, WK_TERM)
    app.handle(key_event(fkey(11) | MOD_ALT))
    assert_equal(app.term_index(TS_SHELL), -1)
    assert_true(app.tshell.pty.running)
    app.handle(key_event(fkey(11) | MOD_ALT))
    shown = wait_screen(app, TS_SHELL, "after-interrupt")
    # the shell ends: the window says so; Enter starts it again
    typ(app, "exit 3")
    app.handle(key_event(KEY_ENTER))
    _ = wait_screen(app, TS_SHELL, "[the program ended with status 3")
    assert_true(app.wins[app.top()].title.endswith("(ended)"))
    app.handle(key_event(KEY_ENTER))
    assert_true(app.tshell.pty.running, "started again")
    var pid = app.tshell.pty.pid
    _ = app.tshell.pty.stop()
    assert_false(Int(external_call["kill", Int32](Int32(pid), Int32(0))) == 0)
    _ = run_system("rm -rf '" + d + "'")


def test_scrollback_and_copy() raises:
    var app = ide(env_or("TMPDIR", "/tmp"))
    app.shell_program = "/bin/sh"
    app.exec(1)
    app.handle(key_event(fkey(11) | MOD_ALT))
    typ(app, "for i in $(seq 1 60); do echo line-$i; done")
    app.handle(key_event(KEY_ENTER))
    _ = wait_screen(app, TS_SHELL, "line-60")
    var t = app.top()
    # Shift-PgUp shows earlier lines; typing returns to the live screen
    app.handle(key_event(KEY_PGUP | MOD_SHIFT))
    var back = screen_of(app, TS_SHELL)
    assert_true(back.find("line-60") < 0 and back.find("line-5\n") >= 0 or back.find("line-50") >= 0, back)
    assert_true(back.find("line-60") < 0, back)
    assert_false(app.tshell.vt.at_bottom())
    app.handle(key_event(KEY_PGDN | MOD_SHIFT))
    assert_true(app.tshell.vt.at_bottom())
    app.handle(Event(EV_MOUSE, 0, 10, app.wins[t].y + 2, MB_WHEEL_UP, True, False, List[Int]()))
    assert_false(app.tshell.vt.at_bottom(), "the wheel scrolls back too")
    typ(app, "e")
    turn(app)
    assert_true(app.tshell.vt.at_bottom(), "typing returns to the live screen")
    app.handle(key_event(KEY_BACKSPACE))
    # a drag selects; letting go copies
    var shown = screen_of(app, TS_SHELL)
    var rows = shown.split("\n")
    var y = -1
    for r in range(len(rows)):
        if String(rows[r]) == "line-60":
            y = r
    assert_true(y > 0, shown)
    var x0 = app.wins[t].x + 1
    var y0 = app.wins[t].y + 1
    app.handle(Event(EV_MOUSE, 0, x0, y0 + y - 1, MB_LEFT, True, False, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, x0 + 6, y0 + y, MB_LEFT, True, True, List[Int]()))
    app.handle(Event(EV_MOUSE, 0, x0 + 6, y0 + y, MB_LEFT, False, False, List[Int]()))
    assert_equal(to_str(app.clipboard), "line-59\nline-60")
    assert_equal(app.status, "Copied from the terminal")
    _ = app.tshell.pty.stop()


def test_run_shows_the_program_in_the_run_window() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-run-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    var app = ide(d)
    app.compiler = "sh " + d + "/fake-mojo.sh"     # stands for `mojo`: `run file` runs a script
    with open(d + "/fake-mojo.sh", "w") as f:
        f.write("shift; printf 'name? '; read n; echo \"hello $n from $(basename $1)\"; exit 4\n")
    with open(d + "/prog.mojo", "w") as f:
        f.write("def main():\n    pass\n")
    app.open_path(d + "/prog.mojo")
    app.exec(CM_RUN)
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_TERM)
    assert_true(app.wins[t].title.startswith("Run - mojo run prog.mojo"), app.wins[t].title)
    _ = wait_screen(app, TS_RUN, "name?")
    # the program reads what is typed: no leaving the IDE for that
    typ(app, "Ada")
    app.handle(key_event(KEY_ENTER))
    var shown = wait_screen(app, TS_RUN, "hello Ada from prog.mojo")
    shown = wait_screen(app, TS_RUN, "ended with status 4")
    # Esc closes the window of an ended program
    app.handle(key_event(KEY_ESC))
    assert_equal(app.term_index(TS_RUN), -1)
    # run again while it waits: the earlier one is ended first
    app.exec(CM_RUN)
    _ = wait_screen(app, TS_RUN, "name?")
    var first = app.trun.pty.pid
    app.focus(app.top_editor())
    app.exec(CM_RUN)
    assert_true(app.status.startswith("The program of the last Run was still running"), app.status)
    assert_false(Int(external_call["kill", Int32](Int32(first), Int32(0))) == 0)
    _ = app.trun.pty.stop()
    # the old way stays as a setting
    assert_true(load_settings("", "").run_in_terminal)
    assert_false(load_settings("[ui]\nrun_in_terminal = false\n", "").run_in_terminal)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
