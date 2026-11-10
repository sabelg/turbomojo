"""Tests for external change detection (src/watch.mojo, src/app_watch.mojo)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from watch import FileSig, file_sig, Watcher
from term import wait_readable, KEY_ESC
from app import *
from appstate import App, now_ns, M_NORMAL, M_DIALOG
from dialog import D_CHANGED, D_FIND
from commands import CM_FIND, CM_NEW
from signals import own_pid
from util import decode, to_str, env_or, run_system, run_capture, bytes_to_str, path_exists


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-watchtest-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    # shield from any .editorconfig above the temp dir
    _ = run_system("printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def put(path: String, content: String):
    _ = run_system("printf '%s' '" + content + "' > '" + path + "'")


def cat(path: String) -> String:
    return bytes_to_str(run_capture("cat '" + path + "'").out)


def opened(dir: String, content: String) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    put(dir + "/a.mojo", content)
    app.open_path(dir + "/a.mojo")
    return app^


def text(app: App) -> String:
    return to_str(app.wins[0].buf.all_text())


# --------------------------------------------------------------- signatures
def test_signature_of_missing_and_existing_files() raises:
    var dir = scratch("sig")
    assert_false(file_sig(dir + "/nope").exists)
    assert_false(file_sig("").exists)
    put(dir + "/f", "hello")
    var a = file_sig(dir + "/f")
    assert_true(a.exists)
    assert_equal(a.size, 5)
    assert_true(a.mtime_s > 1700000000, "mtime looks like a real timestamp")
    assert_true(a.same(file_sig(dir + "/f")))
    put(dir + "/f", "hello!")
    var b = file_sig(dir + "/f")
    assert_equal(b.size, 6)
    assert_false(a.same(b))
    assert_false(a.same(FileSig()))
    assert_true(FileSig().same(FileSig()))
    _ = run_system("rm -rf '" + dir + "'")


def test_same_size_rewrite_changes_the_signature() raises:
    var dir = scratch("mtime")
    put(dir + "/f", "aaaa")
    var a = file_sig(dir + "/f")
    _ = run_system("sleep 0.05")
    put(dir + "/f", "bbbb")
    assert_false(a.same(file_sig(dir + "/f")), "modification time must tell them apart")
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------------------------------------ inotify
def test_watcher_wakes_on_changes_in_a_watched_directory() raises:
    var dir = scratch("inotify")
    var w = Watcher()
    assert_true(w.open())
    assert_true(w.watch_dir(dir))
    assert_true(w.watch_dir(dir))            # twice is fine
    assert_equal(len(w.dirs), 1)
    var fds = List[Int]()
    fds.append(w.fd)
    assert_equal(wait_readable(fds, 0), 0)
    assert_false(w.drain())
    put(dir + "/new.txt", "x")
    assert_equal(wait_readable(fds, 1000), 1)
    assert_true(w.drain())
    assert_equal(wait_readable(fds, 0), 0)   # drained
    _ = run_system("mv '" + dir + "/new.txt' '" + dir + "/renamed.txt'")
    assert_equal(wait_readable(fds, 1000), 1)
    _ = w.drain()
    _ = run_system("rm '" + dir + "/renamed.txt'")
    assert_equal(wait_readable(fds, 1000), 1)
    w.close()
    assert_false(w.active())
    _ = run_system("rm -rf '" + dir + "'")


def test_directories_registered_before_opening_are_watched_after() raises:
    var dir = scratch("early")
    var w = Watcher()
    assert_false(w.watch_dir(dir))           # not open yet: remembered
    assert_true(w.open())
    var fds = List[Int]()
    fds.append(w.fd)
    put(dir + "/f", "x")
    assert_equal(wait_readable(fds, 1000), 1)
    w.close()
    _ = run_system("rm -rf '" + dir + "'")


def test_watching_a_missing_directory_fails_quietly() raises:
    var w = Watcher()
    _ = w.open()
    assert_false(w.watch_dir("/no/such/dir/anywhere"))
    w.close()


# ------------------------------------------------------------ in the editor
def test_unmodified_buffer_reloads_silently_and_can_be_undone() raises:
    var dir = scratch("reload")
    var app = opened(dir, "one\ntwo\nthree\n")
    app.wins[0].cr = 2
    app.wins[0].cc = 3
    assert_false(app.disk_changed(0))
    put(dir + "/a.mojo", "ONE\nTWO\n")
    assert_true(app.disk_changed(0))
    app.check_external_changes()
    assert_equal(app.mode, M_NORMAL)                 # no question asked
    assert_equal(text(app), "ONE\nTWO\n")
    assert_false(app.wins[0].buf.modified)
    assert_equal(app.wins[0].cr, 2)                  # same line kept (now the last one)
    assert_equal(app.wins[0].cc, 0)                  # column clamped to the shorter line
    assert_false(app.disk_changed(0))
    app.wins[0].undo()                               # the reload is one undo step
    assert_equal(text(app), "one\ntwo\nthree\n")
    _ = run_system("rm -rf '" + dir + "'")


def test_touch_without_content_change_does_nothing() raises:
    var dir = scratch("touch")
    var app = opened(dir, "same\n")
    _ = run_system("sleep 0.05; touch '" + dir + "/a.mojo'")
    assert_true(app.disk_changed(0))
    var version = app.wins[0].buf.version
    app.check_external_changes()
    assert_equal(app.wins[0].buf.version, version)   # buffer untouched
    assert_equal(app.mode, M_NORMAL)
    assert_false(app.disk_changed(0))
    _ = run_system("rm -rf '" + dir + "'")


def test_modified_buffer_asks_and_keep_is_remembered() raises:
    var dir = scratch("ask-keep")
    var app = opened(dir, "base\n")
    app.wins[0].type_char(120, True)                 # unsaved change: "xbase"
    put(dir + "/a.mojo", "theirs\n")
    app.check_external_changes()
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_CHANGED)
    assert_equal(app.dlg.focus_button(), 1)          # default is the non-destructive choice
    app.dialog_button(1)                             # Keep my version
    assert_equal(text(app), "xbase\n")
    assert_true(app.wins[0].buf.modified)
    app.check_external_changes()
    assert_equal(app.mode, M_NORMAL)                 # not asked again for the same change
    assert_true(app.save_window(0, 0))               # and saving now overwrites
    assert_equal(cat(dir + "/a.mojo"), "xbase\n")
    _ = run_system("rm -rf '" + dir + "'")


def test_modified_buffer_reload_takes_the_disk_version() raises:
    var dir = scratch("ask-reload")
    var app = opened(dir, "base\n")
    app.wins[0].type_char(120, True)
    put(dir + "/a.mojo", "theirs\n")
    app.check_external_changes()
    app.dialog_button(0)                             # Reload from disk
    assert_equal(text(app), "theirs\n")
    assert_false(app.wins[0].buf.modified)
    app.wins[0].undo()                               # my version is still one undo away
    assert_equal(text(app), "xbase\n")
    _ = run_system("rm -rf '" + dir + "'")


def test_question_waits_while_another_dialog_is_open() raises:
    var dir = scratch("defer")
    var app = opened(dir, "base\n")
    app.wins[0].type_char(120, True)
    app.exec(CM_FIND)
    assert_equal(app.dlg.kind, D_FIND)
    put(dir + "/a.mojo", "theirs\n")
    app.check_external_changes()
    assert_equal(app.dlg.kind, D_FIND)               # the Find dialog is not replaced
    assert_true(app.watch_recheck)
    app.dialog_key(KEY_ESC)
    app.watch_tick(now_ns(), False)                  # next loop pass
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_CHANGED)
    _ = run_system("rm -rf '" + dir + "'")


def test_deleted_file_keeps_the_buffer_as_unsaved() raises:
    var dir = scratch("deleted")
    var app = opened(dir, "precious\n")
    _ = run_system("rm '" + dir + "/a.mojo'")
    app.check_external_changes()
    assert_equal(app.mode, M_NORMAL)
    assert_equal(text(app), "precious\n")
    assert_true(app.wins[0].buf.modified)
    assert_true(app.save_window(0, 0))               # saving puts it back
    assert_equal(cat(dir + "/a.mojo"), "precious\n")
    assert_false(app.disk_changed(0))
    _ = run_system("rm -rf '" + dir + "'")


def test_own_save_is_not_an_external_change() raises:
    var dir = scratch("own")
    var app = opened(dir, "a\n")
    app.wins[0].type_char(120, True)
    assert_true(app.save_window(0, 0))
    assert_false(app.disk_changed(0))
    app.check_external_changes()
    assert_equal(app.mode, M_NORMAL)
    assert_equal(text(app), "xa\n")
    _ = run_system("rm -rf '" + dir + "'")


def test_save_asks_instead_of_overwriting_an_unnoticed_change() raises:
    var dir = scratch("save-ask")
    var app = opened(dir, "base\n")
    app.wins[0].type_char(120, True)
    put(dir + "/a.mojo", "theirs\n")                 # changed, and no check has run yet
    assert_false(app.save_window(0, 0))
    assert_equal(app.dlg.kind, D_CHANGED)
    assert_equal(cat(dir + "/a.mojo"), "theirs\n")   # nothing was overwritten
    _ = run_system("rm -rf '" + dir + "'")


def test_atomic_replace_is_detected() raises:
    # many tools save by writing a new file and renaming it over the old one
    var dir = scratch("rename")
    var app = opened(dir, "old\n")
    put(dir + "/tmp", "replaced\n")
    _ = run_system("mv '" + dir + "/tmp' '" + dir + "/a.mojo'")
    app.check_external_changes()
    assert_equal(text(app), "replaced\n")
    _ = run_system("rm -rf '" + dir + "'")


def test_untitled_buffers_are_never_considered_changed() raises:
    var app = App()
    app.scr.resize(80, 25)
    app.exec(CM_NEW)
    assert_false(app.disk_changed(0))
    app.check_external_changes()
    assert_equal(app.mode, M_NORMAL)


def test_opening_a_file_watches_its_directory() raises:
    var dir = scratch("register")
    var app = opened(dir, "x\n")
    assert_true(dir in app.watch.dirs)
    assert_false(app.watch.active())                 # only opened by run()
    _ = run_system("rm -rf '" + dir + "'")


def test_fallback_polling_is_scheduled_without_inotify() raises:
    var app = App()
    app.show_clock = False
    app.watch_enabled = True                         # as in the running IDE, inotify closed
    var now = now_ns()
    app.watch_due = now + 500 * 1000000
    var t = app.next_timeout_ms(now, False, 30)
    assert_true(t <= 250, "resize fallback or watch deadline, whichever is first")
    _ = app.sig.open()
    t = app.next_timeout_ms(now, False, 30)
    app.sig.close()
    assert_true(t >= 400 and t <= 501, "got " + String(t))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
