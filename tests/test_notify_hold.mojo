"""Tests for toasts that wait for a pause (P7-12, src/notify.mojo, src/app_notify.mojo):
held while the editor has the keys, delivered at a pause, after a save or with the
user's own job (which comes at once and first); a screen reader hears them then."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from notify import *
from term import key_event
from commands import CM_NEW, CM_SAVE
from config import load_settings
from app import *
from appstate import App, now_ns
from signals import own_pid
from util import env_or, run_system, shell_quote, decode, to_str

comptime MS = 1000000


def test_the_model() raises:
    var c = NotifyCenter()
    var t0 = 1000 * MS
    c.add_held(NL_DONE, "The agent has finished", "", t0, "10:00", False, True)
    assert_equal(len(c.toasts(t0)), 0)                     # held
    assert_equal(c.held_count(), 1)
    c.add_held(NL_ERROR, "Build failed", "x: 1 error(s)", t0 + MS, "10:00", True, True)
    assert_equal(len(c.toasts(t0 + MS)), 1)                # the user's own job: at once
    var later = t0 + 60000 * MS                            # long after its own toast time
    var got = c.release(later)
    assert_equal(len(got), 1)
    var shown = c.toasts(later)
    assert_equal(len(shown), 1)                            # the build's toast is over; the held one starts now
    assert_equal(c.notices[shown[0]].title, "The agent has finished")
    assert_equal(c.held_count(), 0)
    # the user's own job is listed first
    var d = NotifyCenter()
    d.add_held(NL_INFO, "Other", "", t0, "", False, False)
    d.add_held(NL_DONE, "Tests", "3 passed", t0 + MS, "", True, False)
    d.add_held(NL_INFO, "Newest other", "", t0 + 2 * MS, "", False, False)
    var order = d.toasts(t0 + 3 * MS)
    assert_equal(d.notices[order[0]].title, "Tests")
    assert_equal(d.notices[order[1]].title, "Newest other")
    # a held toast dismissed meanwhile does not come back
    var e = NotifyCenter()
    e.add_held(NL_INFO, "x", "", t0, "", False, True)
    e.dismiss(0)
    assert_equal(len(e.release(t0 + MS)), 0)


def typing_app(extra: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    if extra.byte_length() > 0:
        app.apply_settings(load_settings(extra, ""))
    app.exec(CM_NEW)
    app.handle(key_event(97))                              # types "a"
    return app^


def toast_titles(app: App) -> String:
    var s = String("")
    for k in app.notes.toasts(now_ns()):
        s += app.notes.notices[k].title + "|"
    return s^


def test_held_while_typing_and_given_at_a_pause() raises:
    var app = typing_app("")
    app.notify(NL_DONE, "The agent has finished", "")
    assert_equal(toast_titles(app), "")
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("The agent has finished") < 0)
    app.notes_tick(now_ns())                               # still typing
    assert_equal(toast_titles(app), "")
    app.notes_tick(app.typed_ns + (TYPING_PAUSE_MS + 1) * MS)     # a pause
    assert_equal(toast_titles(app), "The agent has finished|")
    # the user's own job: at once, and it brings the held ones
    app.handle(key_event(98))
    app.notify(NL_INFO, "Language server", "restarted")
    app.notify(NL_ERROR, "Build failed", "x.mojo: 1 error(s)", True)
    var t = toast_titles(app)
    assert_true(t.startswith("Build failed|"), t)
    assert_true(t.find("Language server|") > 0, t)


def test_a_save_is_a_pause() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-hold-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = typing_app("")
    app.wins[app.top()].path = d + "/x.mojo"
    app.handle(key_event(98))
    app.notify(NL_DONE, "The agent has finished", "")
    assert_equal(toast_titles(app), "")
    app.exec(CM_SAVE)
    app.notes_tick(now_ns())
    assert_equal(toast_titles(app), "The agent has finished|")
    _ = run_system("rm -rf " + shell_quote(d))


def test_a_screen_reader_hears_them_at_the_pause() raises:
    var app = typing_app("[ui]\nscreen_reader = true\n")
    app.say("")
    app.notify(NL_DONE, "The agent has finished", "")
    assert_equal(app.status, "")                           # not while typing
    app.notes_tick(app.typed_ns + (TYPING_PAUSE_MS + 1) * MS)
    assert_equal(app.status, "The agent has finished")
    # not typing: at once, as before
    var quiet = App()
    quiet.apply_settings(load_settings("[ui]\nscreen_reader = true\n", ""))
    quiet.notify(NL_DONE, "Tests", "3 passed")
    assert_equal(quiet.status, "Tests: 3 passed")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
