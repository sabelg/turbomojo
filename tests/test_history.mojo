"""Tests for undo history and cursor position kept between sessions."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from filestate import *
from buffer import TextBuffer, UndoRec
from config import load_settings
from app import *
from appstate import App
from commands import CM_SAVE, CM_UNDO, CM_REDO, CM_CLOSE, CM_QUIT
from term import key_event, KEY_ENTER
from signals import own_pid
from util import decode, to_str, str_bytes, bytes_to_str, env_or, run_system, read_file, write_file, path_exists


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-histtest-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def session(dir: String) -> App:
    """A fresh IDE, as after a restart, using the same state directory."""
    var app = App()
    app.scr.resize(80, 25)
    app.history_dir = dir + "/state"
    return app^


def text(app: App) -> String:
    return to_str(app.wins[app.top()].buf.all_text())


def typ(mut app: App, s: String):
    for c in decode(s):
        app.wins[app.top()].type_char(c, True)


# ------------------------------------------------------------------- format
def test_names_and_hash() raises:
    assert_equal(state_name("/home/u/a.mojo"), "%home%u%a.mojo.hist")
    assert_true(state_name("/a/b") != state_name("/a%b"))
    assert_equal(content_hash(str_bytes("abc")), content_hash(str_bytes("abc")))
    assert_true(content_hash(str_bytes("abc")) != content_hash(str_bytes("abd")))
    assert_true(content_hash(str_bytes("")) != content_hash(str_bytes(" ")))
    assert_true(content_hash(str_bytes("ab")) != content_hash(str_bytes("ba")))
    assert_true(content_hash(str_bytes("some longer text to hash")) > 0)


def test_encode_decode_round_trip() raises:
    var b = TextBuffer()
    b.load(decode("abc\n"))
    _ = b.insert(0, 1, decode("X\né🔥"), 0, 1, 7)
    _ = b.delete(1, 0, 1, 1, 1, 2, 8)
    _ = b.insert(0, 0, decode("q"), 0, 0, 9)
    _ = b.undo()
    var data = state_encode(12345, 4, 1, 2, 3, b.undos, b.redos)
    var st = state_decode(data)
    assert_true(st.ok)
    assert_equal(st.hash, 12345)
    assert_equal(st.size, 4)
    assert_equal(st.cr, 1)
    assert_equal(st.cc, 2)
    assert_equal(st.top, 3)
    assert_equal(len(st.undos), 2)
    assert_equal(len(st.redos), 1)
    for i in range(2):
        assert_equal(st.undos[i].kind, b.undos[i].kind)
        assert_equal(st.undos[i].r, b.undos[i].r)
        assert_equal(st.undos[i].c, b.undos[i].c)
        assert_equal(st.undos[i].cr, b.undos[i].cr)
        assert_equal(st.undos[i].cc, b.undos[i].cc)
        assert_equal(st.undos[i].group, b.undos[i].group)
        assert_equal(to_str(st.undos[i].text), to_str(b.undos[i].text))
    assert_equal(to_str(st.redos[0].text), "q")
    # an empty history is valid too
    var empty = state_decode(state_encode(1, 0, 0, 0, 0, List[UndoRec](), List[UndoRec]()))
    assert_true(empty.ok)
    assert_equal(len(empty.undos), 0)


def test_damaged_files_are_rejected() raises:
    var b = TextBuffer()
    b.load(decode("abc"))
    _ = b.insert(0, 0, decode("hello"), 0, 0, 1)
    var good = state_encode(1, 3, 0, 0, 0, b.undos, b.redos)
    assert_true(state_decode(good).ok)
    assert_false(state_decode(List[UInt8]()).ok)
    assert_false(state_decode(str_bytes("something else entirely\n1 2 3")).ok)
    # cut off anywhere: never accepted, never a crash
    for n in range(len(good) - 1):
        var part = List[UInt8]()
        for k in range(n):
            part.append(good[k])
        assert_false(state_decode(part).ok, "truncated at " + String(n) + " was accepted")
    # letters where numbers belong, negative counts, absurd sizes
    assert_false(state_decode(str_bytes("turbomojo-history 1\nx 3 0 0 0\nundo 0\nredo 0\nend\n")).ok)
    assert_false(state_decode(str_bytes("turbomojo-history 1\n1 3 0 0 0\nundo -1\nredo 0\nend\n")).ok)
    assert_false(state_decode(str_bytes("turbomojo-history 1\n1 3 0 0 0\nundo 999999999\nredo 0\nend\n")).ok)
    assert_false(state_decode(str_bytes("turbomojo-history 1\n1 3 0 0 0\nundo 1\n7 0 0 0 0 1 0\nredo 0\nend\n")).ok)   # bad kind
    assert_false(state_decode(str_bytes("turbomojo-history 1\n1 3 0 0 0\nundo 1\n1 0 0 0 0 1 2 65\nredo 0\nend\n")).ok)  # text too short
    assert_false(state_decode(str_bytes("turbomojo-history 1\n1 3 0 0 0\nundo 1\n1 0 0 0 0 1 1 99999999\nredo 0\nend\n")).ok)
    assert_false(state_decode(str_bytes("turbomojo-history 2\n1 3 0 0 0\nundo 0\nredo 0\nend\n")).ok)    # other version


def test_very_long_histories_are_trimmed_at_a_group_boundary() raises:
    var undos = List[UndoRec]()
    for i in range(STATE_MAX_RECORDS + 10):
        # groups of three records each
        undos.append(UndoRec(1, 0, 0, decode("x"), 0, 0, 1 + i // 3))
    var redos = List[UndoRec]()
    redos.append(UndoRec(1, 0, 0, decode("r"), 0, 0, 99999))
    var st = state_decode(state_encode(1, 1, 0, 0, 0, undos, redos))
    assert_true(st.ok)
    assert_true(len(st.undos) <= STATE_MAX_RECORDS)
    assert_true(len(st.undos) > STATE_MAX_RECORDS - 5)
    assert_equal(len(st.redos), 0)                      # redo makes no sense on a cut history
    # the oldest kept record starts a group
    var first_group = st.undos[0].group
    var n = 0
    for u in st.undos:
        if u.group == first_group:
            n += 1
    assert_equal(n, 3)


# ---------------------------------------------------------------- sessions
def test_undo_survives_a_restart() raises:
    var d = scratch("undo")
    var path = d + "/a.txt"
    with open(path, "w") as f:
        f.write("one\ntwo\n")
    var app = session(d)
    app.open_path(path)
    app.wins[app.top()].goto(1, 3)
    typ(app, " and a half")
    app.wins[app.top()].break_group()
    app.wins[app.top()].goto(0, 0)
    typ(app, "# ")
    app.exec(CM_SAVE)
    assert_equal(bytes_to_str(read_file(path)), "# one\ntwo and a half\n")
    # ---- next session
    var later = session(d)
    later.open_path(path)
    assert_equal(text(later), "# one\ntwo and a half\n")
    assert_false(later.wins[later.top()].buf.modified)
    assert_equal(later.wins[later.top()].cr, 0)        # the cursor is where it was
    assert_equal(later.wins[later.top()].cc, 2)
    later.exec(CM_UNDO)
    assert_equal(text(later), "one\ntwo and a half\n")
    later.exec(CM_UNDO)
    assert_equal(text(later), "one\ntwo\n")
    later.exec(CM_REDO)
    assert_equal(text(later), "one\ntwo and a half\n")
    # new typing after a restored history is its own undo step
    typ(later, "!")
    later.exec(CM_UNDO)
    assert_equal(text(later), "one\ntwo and a half\n")
    _ = run_system("rm -rf '" + d + "'")


def test_history_is_dropped_when_the_file_changed_meanwhile() raises:
    var d = scratch("changed")
    var path = d + "/a.txt"
    with open(path, "w") as f:
        f.write("abc\n")
    var app = session(d)
    app.open_path(path)
    typ(app, "X")
    app.exec(CM_SAVE)
    # another program rewrites the file: same size, different content
    with open(path, "w") as f:
        f.write("Yabc\n")
    var later = session(d)
    later.open_path(path)
    assert_equal(text(later), "Yabc\n")
    assert_equal(len(later.wins[later.top()].buf.undos), 0)
    assert_equal(later.wins[later.top()].cc, 0)
    later.exec(CM_UNDO)                                 # nothing to undo: the text stays
    assert_equal(text(later), "Yabc\n")
    _ = run_system("rm -rf '" + d + "'")


def test_cursor_position_is_remembered_on_close_and_quit() raises:
    var d = scratch("cursor")
    var body = String("")
    for i in range(200):
        body += "line " + String(i) + "\n"
    with open(d + "/a.txt", "w") as f:
        f.write(body)
    with open(d + "/b.txt", "w") as f:
        f.write(body)
    var app = session(d)
    app.open_path(d + "/a.txt")
    app.wins[app.top()].goto(150, 3)
    app.exec(CM_CLOSE)                                  # closing remembers
    app.open_path(d + "/b.txt")
    app.wins[app.top()].goto(77, 1)
    app.exec(CM_QUIT)                                   # so does quitting
    assert_false(app.running)
    var later = session(d)
    later.open_path(d + "/a.txt")
    assert_equal(later.wins[later.top()].cr, 150)
    assert_equal(later.wins[later.top()].cc, 3)
    later.draw()
    var cell = later.wins[later.top()].cursor_cell()
    assert_true(cell.r > 0, "the remembered line is scrolled into view")
    later.open_path(d + "/b.txt")
    assert_equal(later.wins[later.top()].cr, 77)
    _ = run_system("rm -rf '" + d + "'")


def test_unsaved_changes_do_not_overwrite_the_history() raises:
    var d = scratch("discard")
    var path = d + "/a.txt"
    with open(path, "w") as f:
        f.write("abc\n")
    var app = session(d)
    app.open_path(path)
    typ(app, "1")
    app.exec(CM_SAVE)                                   # history: one step, file "1abc"
    typ(app, "2")
    # the window goes away without saving (as after "No" in the save question)
    app.remove_window(app.top())
    var later = session(d)
    later.open_path(path)
    assert_equal(text(later), "1abc\n")
    later.exec(CM_UNDO)
    assert_equal(text(later), "abc\n")                  # the saved state's history, not the discarded edit
    _ = run_system("rm -rf '" + d + "'")


def test_nothing_is_written_when_the_feature_is_off() raises:
    var d = scratch("off")
    var path = d + "/a.txt"
    with open(path, "w") as f:
        f.write("abc\n")
    var app = App()
    app.scr.resize(80, 25)                              # history_dir stays empty
    app.open_path(path)
    typ(app, "x")
    app.exec(CM_SAVE)
    assert_false(path_exists(d + "/state"))
    var s = load_settings("[editor]\npersistent_undo = false\n", "")
    assert_false(s.persistent_undo)
    assert_true(load_settings("", "").persistent_undo)
    _ = run_system("rm -rf '" + d + "'")


def test_a_damaged_history_file_is_ignored() raises:
    var d = scratch("damaged")
    var path = d + "/a.txt"
    with open(path, "w") as f:
        f.write("abc\n")
    var app = session(d)
    app.open_path(path)
    typ(app, "x")
    app.exec(CM_SAVE)
    var hist = app.history_file(app.top())
    assert_true(path_exists(hist))
    assert_true(write_file(hist, str_bytes("turbomojo-history 1\ngarbage in here")))
    var later = session(d)
    later.open_path(path)
    assert_equal(text(later), "xabc\n")
    assert_equal(len(later.wins[later.top()].buf.undos), 0)
    typ(later, "y")
    later.exec(CM_SAVE)                                 # and it is replaced by a good one
    assert_true(state_decode(read_file(hist)).ok)
    _ = run_system("rm -rf '" + d + "'")


def test_latin1_and_bom_files_keep_their_history_too() raises:
    var d = scratch("enc")
    _ = run_system("printf 'caf\\351\\n' > '" + d + "/l.txt'")
    var app = session(d)
    app.open_path(d + "/l.txt")
    app.wins[app.top()].goto(0, 4)
    typ(app, "s")
    app.exec(CM_SAVE)
    var later = session(d)
    later.open_path(d + "/l.txt")
    assert_equal(to_str(later.wins[later.top()].buf.line(0)), "cafés")
    later.exec(CM_UNDO)
    assert_equal(to_str(later.wins[later.top()].buf.line(0)), "café")
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
