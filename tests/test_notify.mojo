"""Tests for toasts and the notification centre (src/notify.mojo, src/app_notify.mojo)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from notify import *
from term import wait_readable, key_event, KEY_ENTER, KEY_ESC, Event, EV_MOUSE, MB_LEFT, fkey, MOD_SHIFT
from app import *
from appstate import App, now_ns, M_DIALOG, M_NORMAL
from dialog import D_NOTICES
from window import WK_EDITOR
from commands import CM_NOTICES, CM_BUILD, CM_AGENT
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, decode, to_str, getcwd

comptime MS = 1000000


def test_the_model() raises:
    var c = NotifyCenter()
    var t0 = 1000 * MS
    c.add(NL_INFO, "one", "", t0, "10:00")
    c.add(NL_ERROR, "two", "bad", t0 + 1 * MS, "10:00")
    c.add(NL_DONE, "three", "", t0 + 2 * MS, "10:00")
    c.add(NL_DONE, "four", "", t0 + 3 * MS, "10:00")
    var shown = c.toasts(t0 + 10 * MS)
    assert_equal(len(shown), 3)                     # at most three, newest first
    assert_equal(c.notices[shown[0]].title, "four")
    assert_equal(c.notices[shown[2]].title, "two")
    assert_equal(c.unread, 4)
    # after 5 s only the error is left (errors stay 10 s)
    shown = c.toasts(t0 + 6000 * MS)
    assert_equal(len(shown), 1)
    assert_equal(c.notices[shown[0]].title, "two")
    assert_equal(c.next_change_ns(t0 + 6000 * MS), t0 + 1 * MS + TOAST_ERROR_MS * MS)
    assert_equal(len(c.toasts(t0 + 12000 * MS)), 0)
    assert_equal(c.next_change_ns(t0 + 12000 * MS), 0)
    # the same message soon again: shown again, kept once
    c.add(NL_DONE, "four", "", t0 + 4000 * MS, "10:00")
    assert_equal(len(c.notices), 4)
    assert_equal(len(c.toasts(t0 + 8000 * MS)), 2)     # it, and the error (10 s)
    c.dismiss_all()
    assert_equal(len(c.toasts(t0 + 8000 * MS)), 0)
    for k in range(150):
        c.add(NL_INFO, "n" + String(k), "", t0, "10:00")
    assert_equal(len(c.notices), NOTICES_KEPT)
    assert_equal(c.notices[0].title, "n50")


def screen(app: App) -> String:
    return to_str(app.scr.to_text())


def test_toasts_on_the_screen() raises:
    var app = App()
    app.scr.resize(100, 30)
    app.notify(NL_DONE, "Build succeeded", "hello.mojo in 2.1 s")
    app.notify(NL_ERROR, "Tests failed", "Tests: 3 passed, 1 failed")
    app.draw()
    var s = screen(app)
    assert_true(s.find("✓ Build succeeded") > 0, s)
    assert_true(s.find("✗ Tests failed") > 0)
    var lines = s.split("\n")
    # at the top right: the newest first, under the menu bar
    assert_true(String(lines[2]).find("✗ Tests failed") > 50, String(lines[2]))
    # the loop wakes when a toast is due to go
    assert_true(app.next_timeout_ms(now_ns(), False, 60) <= TOAST_ERROR_MS + 1)
    # a click takes one away
    var y = app.toast_y0[0] + 1
    app.handle(Event(EV_MOUSE, 0, 95, y, MB_LEFT, True, False, List[Int]()))
    app.draw()
    s = screen(app)
    assert_true(s.find("Tests failed") < 0)
    assert_true(s.find("Build succeeded") > 0)
    # the centre: Shift-F10 lists them; opening it takes the toasts away
    assert_equal(app.reg.find_key(fkey(10) | MOD_SHIFT), CM_NOTICES)
    app.handle(key_event(fkey(10) | MOD_SHIFT))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_NOTICES)
    assert_equal(app.dlg.items[0], "  (nothing is running)")
    assert_true(app.dlg.items[1].find("✗ Tests failed - Tests: 3 passed, 1 failed") > 0)
    assert_true(app.dlg.items[2].find("✓ Build succeeded - hello.mojo") > 0)
    assert_equal(app.notes.unread, 0)
    app.handle(key_event(KEY_ESC))
    app.draw()
    assert_true(screen(app).find("Build succeeded") < 0)
    # Clear all
    app.exec(CM_NOTICES)
    app.dlg.focus = app.dlg.button_focus_index(1)
    app.handle(key_event(KEY_ENTER))
    assert_equal(len(app.notes.notices), 0)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-notify-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def wait_job(mut app: App) raises:
    var deadline = Int(perf_counter_ns()) + 240000 * MS
    while app.job.active and Int(perf_counter_ns()) < deadline:
        var fds = List[Int]()
        fds.append(app.job.fd)
        _ = wait_readable(fds, 50)
        app.poll_job()
    assert_false(app.job.active)


def test_a_build_tells_how_it_went() raises:
    var d = scratch("build")
    _ = write_file(d + "/bad.mojo", str_bytes("def main():\n    pritn(1)\n"))
    var app = App()
    app.scr.resize(110, 32)
    app.cwd = d
    app.open_path(d + "/bad.mojo")
    app.exec(CM_BUILD)
    # while it runs it is listed (and counted on the status line)
    assert_true(app.running_tasks()[0].startswith("Building"), app.running_tasks()[0])
    app.draw()
    assert_true(to_str(app.scr.row_text(app.scr.h - 1)).find("⟳1") > 0, to_str(app.scr.row_text(app.scr.h - 1)))
    wait_job(app)
    var n = len(app.notes.notices)
    assert_true(n >= 1)
    assert_equal(app.notes.notices[n - 1].title, "Build failed")
    assert_equal(app.notes.notices[n - 1].level, NL_ERROR)
    assert_equal(app.notes.notices[n - 1].text, "bad.mojo: 1 error(s)")
    assert_equal(len(app.running_tasks()), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def pump(mut app: App, until: String, idle: Bool = True) raises:
    var end = Int(perf_counter_ns()) + 10000 * MS
    while Int(perf_counter_ns()) < end:
        var fds = List[Int]()
        if app.agent.fd() >= 0:
            fds.append(app.agent.fd())
        _ = wait_readable(fds, 20)
        app.agent_tick(now_ns())
        if app.chat.markdown("").find(until) >= 0 and not (idle and app.agent.busy()):
            return
    assert_true(False, "never: " + until)


def test_the_agent_tells_when_you_are_elsewhere() raises:
    var d = scratch("agent")
    var app = App()
    app.scr.resize(110, 32)
    app.cwd = d
    app.project_dir = d
    _ = write_file(d + "/a.mojo", str_bytes("x\n"))
    app.open_path(d + "/a.mojo")
    app.agent_command = "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(d + "/log")
    app.exec(CM_AGENT)
    pump(app, "Connected")
    # a turn ending while the panel is in front: no toast
    for c in decode("hello"):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))
    pump(app, "Hello")
    var before = len(app.notes.notices)
    # sent, then back to the editor: the end of the turn is told
    for c in decode("slow"):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))
    pump(app, "tick 1", False)
    assert_true("Fake Agent is working" in app.running_tasks())
    app.focus(app.find_editor(d + "/a.mojo"))
    app.agent.cancel()
    pump(app, "*stopped*")
    assert_equal(len(app.notes.notices), before + 1)
    assert_equal(app.notes.notices[before].title, "Fake Agent has finished")
    # a permission asked while you are elsewhere
    app.focus(app.agent_index())
    for c in decode("perm"):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))
    app.focus(app.find_editor(d + "/a.mojo"))
    pump(app, "The agent asks to Write b.mojo", False)
    var last = app.notes.notices[len(app.notes.notices) - 1].copy()
    assert_equal(last.title, "The agent asks for permission")
    assert_equal(last.level, NL_WARN)
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
