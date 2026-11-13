"""Tests for swap files: format, periodic writing, clean-up and recovery."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from swap import *
from app import *
from appstate import App, now_ns, M_NORMAL, M_DIALOG
from dialog import D_RECOVER
from commands import CM_NEW
from term import KEY_ESC
from signals import own_pid
from util import decode, to_str, str_bytes, bytes_to_str, env_or, run_system, run_capture, path_exists

comptime SEC = 1000000000


def scratch(tag: String) -> String:
    return env_or("TMPDIR", "/tmp") + "/turbomojo-swaptest-" + String(own_pid()) + "-" + tag


def dead_pid() raises -> Int:
    """The id of a process that has already exited."""
    var r = run_capture("sh -c 'echo $$'")
    return atol(String(bytes_to_str(r.out).strip()))


def make(tag: String) raises -> App:
    var app = App()
    app.scr.resize(80, 25)
    app.recovery_dir = scratch(tag)
    app.swap_enabled = True
    _ = run_system("rm -rf '" + app.recovery_dir + "'")
    return app^


def cleanup(app: App):
    _ = run_system("rm -rf '" + app.recovery_dir + "'")


def typ(mut app: App, i: Int, s: String):
    for c in decode(s):
        app.wins[i].type_char(c, True)


# ------------------------------------------------------------------- format
def test_swap_names() raises:
    assert_equal(swap_name("/home/u/a.mojo", "a.mojo", 7, 1), "%home%u%a.mojo.swp")
    assert_equal(swap_name("/x/50%.txt", "t", 7, 1), "%x%50%%.txt.swp")
    assert_equal(swap_name("", "NONAME00.mojo", 123, 4), "untitled-123-4.swp")
    # different files never share a swap file
    assert_true(swap_name("/a/b", "", 1, 1) != swap_name("/a%b", "", 1, 1))


def test_encode_decode_roundtrip() raises:
    var content = str_bytes("def f():\r\n\tpass  \n日本語 🔥\n---\nnot a header\n")
    var data = swap_encode("/p/a.mojo", "a.mojo", 4242, "2026-11-10 04:30:00", content)
    var info = swap_decode(data)
    assert_true(info.ok)
    assert_equal(info.path, "/p/a.mojo")
    assert_equal(info.title, "a.mojo")
    assert_equal(info.pid, 4242)
    assert_equal(info.time, "2026-11-10 04:30:00")
    assert_equal(bytes_to_str(info.content), "def f():\r\n\tpass  \n日本語 🔥\n---\nnot a header\n")


def test_decode_rejects_other_files() raises:
    assert_false(swap_decode(str_bytes("")).ok)
    assert_false(swap_decode(str_bytes("just some text\n")).ok)
    assert_false(swap_decode(str_bytes("TURBOMOJO-SWAP 1\npath: /a\npid: 5\n")).ok)       # no separator
    assert_false(swap_decode(str_bytes("TURBOMOJO-SWAP 1\npath: /a\n---\nx")).ok)          # no pid
    assert_false(swap_decode(str_bytes("TURBOMOJO-SWAP 9\npid: 5\n---\nx")).ok)            # other version
    assert_true(swap_decode(str_bytes("TURBOMOJO-SWAP 1\npid: 5\n---\n")).ok)              # empty buffer is fine


def test_atomic_write_and_read() raises:
    var dir = scratch("io")
    _ = run_system("mkdir -p '" + dir + "'")
    var p = dir + "/f.bin"
    var data = List[UInt8]()
    for i in range(300):
        data.append(UInt8(i % 256))
    assert_true(write_bytes_atomic(p, data))
    var back = read_bytes(p)
    assert_equal(len(back), 300)
    assert_equal(Int(back[255]), 255)
    assert_equal(Int(back[256]), 0)
    assert_false(path_exists(p + ".tmp"), "temporary file must not be left behind")
    assert_true(write_bytes_atomic(p, List[UInt8]()))      # overwrite with empty
    assert_equal(len(read_bytes(p)), 0)
    assert_false(write_bytes_atomic(dir + "/no/such/dir/f", data))
    assert_equal(len(read_bytes(dir + "/missing")), 0)
    delete_file(p)
    assert_false(path_exists(p))
    _ = run_system("rm -rf '" + dir + "'")


def test_pid_alive() raises:
    assert_true(pid_alive(own_pid()))
    assert_false(pid_alive(dead_pid()))
    assert_false(pid_alive(0))
    assert_false(pid_alive(-5))


# ------------------------------------------------------------ periodic write
def test_nothing_is_swapped_for_unmodified_buffers() raises:
    var app = make("clean")
    app.exec(CM_NEW)
    var now = now_ns()
    app.swap_tick(now)
    app.swap_tick(now + 10 * SEC)
    assert_equal(app.swap_due, 0)
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)
    cleanup(app)


def test_swap_is_written_two_seconds_after_a_change() raises:
    var app = make("timing")
    app.exec(CM_NEW)
    typ(app, 0, "hello")
    var now = now_ns()
    app.swap_tick(now)                               # notices the change, starts the clock
    assert_true(app.swap_due > now)
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)
    app.swap_tick(now + 1 * SEC)                     # too early
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)
    app.swap_tick(now + 2 * SEC + 1)                 # due
    var files = list_swap_files(app.recovery_dir)
    assert_equal(len(files), 1)
    assert_equal(bytes_to_str(swap_decode(read_bytes(files[0])).content), "hello\n")
    assert_equal(app.swap_due, 0)
    # the loop is told to wake up for the deadline
    typ(app, 0, "!")
    app.swap_tick(now + 3 * SEC)
    # ...never later than the deadline (in tests the 250 ms resize fallback is shorter)
    assert_true(app.next_timeout_ms(now + 3 * SEC, False, 30) <= 2001)
    # in the running IDE, where signals arrive on a descriptor, the swap deadline decides
    _ = app.sig.open()
    var t = app.next_timeout_ms(now + 3 * SEC, False, 30)
    app.sig.close()
    assert_true(t <= 2001 and t >= 1900, "timeout " + String(t))
    cleanup(app)


def test_unchanged_buffer_is_not_rewritten_and_edits_are() raises:
    var app = make("rewrite")
    app.exec(CM_NEW)
    typ(app, 0, "one")
    var now = now_ns()
    app.swap_tick(now)
    app.swap_tick(now + 3 * SEC)
    var v = app.wins[0].swap_version
    assert_equal(v, app.wins[0].buf.version)
    app.swap_tick(now + 4 * SEC)
    app.swap_tick(now + 9 * SEC)
    assert_equal(app.swap_due, 0)                    # nothing new: no write scheduled
    typ(app, 0, " two")
    app.swap_tick(now + 10 * SEC)
    app.swap_tick(now + 13 * SEC)
    var files = list_swap_files(app.recovery_dir)
    assert_equal(len(files), 1)                      # same file, new content
    assert_equal(bytes_to_str(swap_decode(read_bytes(files[0])).content), "one two\n")
    cleanup(app)


def test_swapping_is_off_unless_enabled() raises:
    var app = make("off")
    app.swap_enabled = False
    app.exec(CM_NEW)
    typ(app, 0, "x")
    var now = now_ns()
    app.swap_tick(now)
    app.swap_tick(now + 5 * SEC)
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)
    cleanup(app)


# ------------------------------------------------------------------ clean-up
def test_saving_removes_the_swap_file() raises:
    var app = make("save")
    _ = run_system("mkdir -p '" + app.recovery_dir + "/work'")
    var path = app.recovery_dir + "/work/a.mojo"
    app.open_path(path)
    var t = app.top()
    typ(app, t, "x = 1")
    assert_equal(app.write_all_swaps(), 1)
    assert_equal(len(list_swap_files(app.recovery_dir)), 1)
    assert_true(app.save_window(t, 0))
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)
    assert_equal(app.wins[t].swap_file, "")
    cleanup(app)


def test_closing_a_window_removes_its_swap_file() raises:
    var app = make("close")
    app.exec(CM_NEW)
    typ(app, 0, "discard me")
    _ = app.write_all_swaps()
    assert_equal(len(list_swap_files(app.recovery_dir)), 1)
    app.remove_window(0)                             # what "No" in the save prompt does
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)
    cleanup(app)


def test_undo_back_to_saved_state_drops_swap_on_next_tick() raises:
    var app = make("tick-clean")
    app.exec(CM_NEW)
    typ(app, 0, "x")
    _ = app.write_all_swaps()
    app.wins[0].buf.modified = False                 # as after a save
    app.swap_tick(now_ns())
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)
    cleanup(app)


def test_untitled_buffer_keeps_one_swap_file_when_windows_reorder() raises:
    var app = make("reorder")
    app.exec(CM_NEW)
    app.exec(CM_NEW)
    typ(app, 0, "a")
    typ(app, 1, "b")
    assert_equal(app.write_all_swaps(), 2)
    app.focus(0)                                     # changes the window order
    typ(app, 0, "!")
    typ(app, 1, "!")
    assert_equal(app.write_all_swaps(), 2)
    assert_equal(len(list_swap_files(app.recovery_dir)), 2)
    cleanup(app)


# ------------------------------------------------------------------ recovery
def plant(app: App, name: String, path: String, title: String, pid: Int, content: String) -> String:
    _ = run_system("mkdir -p '" + app.recovery_dir + "'")
    var f = app.recovery_dir + "/" + name
    _ = write_bytes_atomic(f, swap_encode(path, title, pid, "2026-11-10 04:00:00", str_bytes(content)))
    return f


def test_only_swaps_of_dead_processes_are_orphans() raises:
    var app = make("orphans")
    var dead = dead_pid()
    _ = plant(app, "untitled-1-1.swp", "", "NONAME00.mojo", dead, "lost work\n")
    _ = plant(app, "untitled-2-1.swp", "", "other.mojo", own_pid(), "owned by a running IDE\n")
    _ = run_system("printf 'garbage' > '" + app.recovery_dir + "/junk.swp'")
    _ = run_system("printf 'x' > '" + app.recovery_dir + "/notes.txt'")
    var found = app.find_orphan_swaps()
    assert_equal(len(found), 1)
    assert_true(found[0].endswith("untitled-1-1.swp"))
    cleanup(app)


def test_no_dialog_when_there_is_nothing_to_recover() raises:
    var app = make("nothing")
    app.offer_recovery()
    assert_equal(app.mode, M_NORMAL)
    cleanup(app)


def test_recover_restores_buffers_as_modified() raises:
    var app = make("recover")
    var dead = dead_pid()
    _ = run_system("mkdir -p '" + app.recovery_dir + "/work'")
    var real = app.recovery_dir + "/work/a.mojo"
    _ = run_system("printf 'old line\\n' > '" + real + "'")
    var f1 = plant(app, swap_name(real, "a.mojo", dead, 1), real, "a.mojo", dead, "new line\nmore\n")
    var f2 = plant(app, "untitled-9-1.swp", "", "NONAME03.mojo", dead, "scratch\n")
    app.offer_recovery()
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_RECOVER)
    assert_equal(len(app.pending_swaps), 2)
    app.dialog_button(0)                             # Recover
    assert_equal(app.mode, M_NORMAL)
    assert_equal(len(app.wins), 2)
    var i = app.find_editor(real)
    assert_true(i >= 0)
    assert_equal(to_str(app.wins[i].buf.all_text()), "new line\nmore\n")
    assert_true(app.wins[i].buf.modified)
    var j = 1 - i
    assert_equal(app.wins[j].title, "NONAME03.mojo")
    assert_equal(app.wins[j].path, "")
    assert_equal(to_str(app.wins[j].buf.all_text()), "scratch\n")
    assert_true(app.wins[j].buf.modified)
    # the file on disk was not touched, and the old swap files are gone
    assert_equal(bytes_to_str(run_capture("cat '" + real + "'").out), "old line\n")
    assert_false(path_exists(f1))
    assert_false(path_exists(f2))
    # the recovered buffers are protected again by the normal cycle
    var now = now_ns()
    app.swap_tick(now)
    app.swap_tick(now + 3 * SEC)
    assert_equal(len(list_swap_files(app.recovery_dir)), 2)
    cleanup(app)


def test_recover_into_a_file_that_is_already_open() raises:
    var app = make("already-open")
    var dead = dead_pid()
    _ = run_system("mkdir -p '" + app.recovery_dir + "/work'")
    var real = app.recovery_dir + "/work/a.mojo"
    _ = run_system("printf 'on disk\\n' > '" + real + "'")
    app.open_path(real)                              # e.g. named on the command line
    _ = plant(app, swap_name(real, "a.mojo", dead, 1), real, "a.mojo", dead, "unsaved version\n")
    app.offer_recovery()
    app.dialog_button(0)
    assert_equal(len(app.wins), 1)                   # no duplicate window
    assert_equal(to_str(app.wins[0].buf.all_text()), "unsaved version\n")
    assert_true(app.wins[0].buf.modified)
    cleanup(app)


def test_recover_reuses_the_empty_startup_window() raises:
    var app = make("reuse")
    var dead = dead_pid()
    app.exec(CM_NEW)                                 # what the IDE does when started bare
    _ = plant(app, "untitled-1-1.swp", "", "NONAME00.mojo", dead, "first\n")
    _ = plant(app, "untitled-1-2.swp", "", "NONAME01.mojo", dead, "second\n")
    app.offer_recovery()
    app.dialog_button(0)
    assert_equal(len(app.wins), 2)                   # not 3: the empty window was reused
    var texts = List[String]()
    for i in range(2):
        texts.append(to_str(app.wins[i].buf.all_text()))
        assert_true(app.wins[i].buf.modified)
    assert_true("first\n" in texts)
    assert_true("second\n" in texts)
    cleanup(app)


def test_discard_deletes_and_later_keeps() raises:
    var app = make("discard")
    var dead = dead_pid()
    var f = plant(app, "untitled-1-1.swp", "", "x.mojo", dead, "data\n")
    app.offer_recovery()
    app.dialog_button(2)                             # Later
    assert_true(path_exists(f))
    assert_equal(len(app.wins), 0)
    app.offer_recovery()                             # asked again next time
    assert_equal(app.dlg.kind, D_RECOVER)
    app.dialog_key(KEY_ESC)                          # Esc behaves like Later
    assert_true(path_exists(f))
    app.offer_recovery()
    app.dialog_button(1)                             # Discard
    assert_false(path_exists(f))
    assert_equal(len(app.wins), 0)
    app.offer_recovery()
    assert_equal(app.mode, M_NORMAL)                 # nothing left to offer
    cleanup(app)


def test_clean_exit_removes_own_swaps_but_not_others() raises:
    var app = make("exit")
    var dead = dead_pid()
    var other = plant(app, "untitled-1-1.swp", "", "x.mojo", dead, "someone else's\n")
    app.exec(CM_NEW)
    typ(app, 0, "mine")
    _ = app.write_all_swaps()
    assert_equal(len(list_swap_files(app.recovery_dir)), 2)
    app.clean_swaps_on_exit()
    assert_equal(len(list_swap_files(app.recovery_dir)), 1)
    assert_true(path_exists(other))
    cleanup(app)



# ------------------------------------------------------------ large-file mode
def test_large_file_mode_turns_off_snapshots_but_not_emergency_save() raises:
    var app = make("large")
    var dir = scratch("large-src")
    _ = run_system("mkdir -p '" + dir + "'")
    var body = String("")
    for i in range(100):
        body += "line number " + String(i) + " of the big file\n"
    with open(dir + "/big.txt", "w") as f:
        f.write(body)
    with open(dir + "/small.txt", "w") as f:
        f.write("tiny\n")
    app.large_file_bytes = 1000
    app.open_path(dir + "/small.txt")
    assert_false(app.wins[app.top()].buf.large)
    app.open_path(dir + "/big.txt")
    var i = app.top()
    assert_true(app.wins[i].buf.large)
    assert_true(app.status.find("large-file mode") >= 0, app.status)
    assert_equal(app.wins[i].buf.count(), 101)
    assert_equal(to_str(app.wins[i].buf.line(99)), "line number 99 of the big file")
    typ(app, i, "edit")
    var now = now_ns()
    app.swap_tick(now)
    app.swap_tick(now + 5 * SEC)
    assert_equal(len(list_swap_files(app.recovery_dir)), 0)   # no periodic snapshot
    assert_equal(app.swap_due, 0)                             # and no timer kept running
    assert_equal(app.write_all_swaps(), 1)                    # a crash still saves the work
    assert_equal(len(list_swap_files(app.recovery_dir)), 1)
    _ = run_system("rm -rf '" + dir + "'")
    cleanup(app)


def test_file_at_the_limit_is_not_large() raises:
    var app = make("limit")
    var dir = scratch("limit-src")
    _ = run_system("mkdir -p '" + dir + "'")
    with open(dir + "/a.txt", "w") as f:
        f.write("0123456789")
    app.large_file_bytes = 10
    app.open_path(dir + "/a.txt")
    assert_false(app.wins[app.top()].buf.large)
    app.large_file_bytes = 9
    app.open_path(dir + "/a.txt")                             # already open: just focused
    assert_false(app.wins[app.top()].buf.large)
    _ = run_system("rm -rf '" + dir + "'")
    cleanup(app)


def test_a_long_path_keeps_the_files_name() raises:
    """(found by CI, whose checkout is deep: the name was cut off at the box's edge)"""
    var app = make("longpath")
    app.scr.resize(80, 25)
    var dead = dead_pid()
    var deep = app.recovery_dir + "/a-rather-long-folder-name/another-long-folder-name/and-one-more-level"
    _ = run_system("mkdir -p '" + deep + "'")
    var real = deep + "/the_file.mojo"
    _ = run_system("printf 'x\\n' > '" + real + "'")
    _ = plant(app, swap_name(real, "the_file.mojo", dead, 1), real, "the_file.mojo", dead, "y\n")
    app.offer_recovery()
    assert_equal(app.dlg.kind, D_RECOVER)
    var line = app.dlg.lines[2]
    assert_true(line.find("the_file.mojo") > 0, line)
    assert_true(line.find("…") > 0, line)
    assert_true(len(decode(line)) <= app.dlg.w - 4, line)
    # under the folder the IDE works in: shown from there
    app.mode = M_NORMAL
    app.cwd = app.recovery_dir + "/a-rather-long-folder-name/another-long-folder-name"
    app.offer_recovery()
    assert_true(app.dlg.lines[2].startswith("  and-one-more-level/the_file.mojo   "), app.dlg.lines[2])
    cleanup(app)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
