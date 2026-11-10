"""Sessions: the text form of a session and of the layout tree, and restoring files,
cursors and layout in the application."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from session import *
from layout import Layout, layout_decode
from app import *
from appstate import App, now_ns, M_NORMAL, PG_SEARCH, PG_MESSAGE
from window import WK_EDITOR
from commands import CM_TILED, CM_SPLIT_RIGHT, CM_EXPLORER, CM_OUTLINE, CM_SEARCHRES, CM_NEW
from config import load_settings, read_text
from signals import own_pid
from util import decode, to_str, env_or, run_system


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-session-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def test_layout_tree_as_text() raises:
    var l = Layout()
    for id in range(5):
        l.add(id)
    _ = l.split(True)                                    # ([0 1 2 3*] | [4*]!)
    l.add(7)
    _ = l.split(False)
    _ = l.resize(100)
    assert_equal(l.describe(), "([0 1 2 3*] | ([4*] / [7*]!))")
    var text = l.encode()
    assert_equal(text, "R 500 G 4 3 0 1 2 3 C 400 G 1 0 4 !G 1 0 7")
    var back = layout_decode(text)
    assert_equal(back.describe(), l.describe())
    assert_equal(back.encode(), text)
    # the copy works like the original
    back.remove(7)
    assert_equal(back.describe(), "([0 1 2 3*] | [4*]!)")
    back.add(9)
    assert_equal(back.describe(), "([0 1 2 3*] | [4 9*]!)")
    # one group
    assert_equal(layout_decode("G 2 1 5 6").describe(), "[5 6*]!")
    assert_equal(layout_decode("!G 0 0").describe(), "[]!")


def test_layout_text_that_is_not_a_tree_gives_a_fresh_layout() raises:
    for bad in ["", "X", "G", "G 2 0 1", "R 500 G 1 0 1", "R x G 1 0 1 G 1 0 2", "G 1 0 1 G 1 0 2", "R 500 G 1 0 1 G 1 0 1", "G 1 0 -3", "C 500 G 1 0 1 G 1 0 2 extra"]:
        assert_equal(layout_decode(String(bad)).describe(), "[]!", String(bad))
    # odd but usable: a ratio out of range is brought in, an active index too large is cut,
    # an empty group beside a full one disappears
    assert_equal(layout_decode("R 5 G 1 0 1 G 1 0 2").ratio[layout_decode("R 5 G 1 0 1 G 1 0 2").root], 150)
    assert_equal(layout_decode("G 2 9 1 2").describe(), "[1 2*]!")
    assert_equal(layout_decode("R 500 G 0 0 G 2 0 1 2").describe(), "[1* 2]!")


def sample() -> SessionData:
    var d = SessionData()
    d.root = "/home/me/my project"
    d.tiled = True
    d.layout = "R 500 G 1 0 0 !G 1 0 1"
    d.explorer = True
    d.explorer_w = 28
    d.opened.append("/home/me/my project/src")
    d.outline = True
    d.panel = True
    d.panel_page = 2
    d.panel_h = 9
    var a = SessionFile("/home/me/my project/a b.mojo")
    a.cr = 12
    a.cc = 4
    a.top = 3
    a.x = 0
    a.y = 1
    a.w = 50
    a.h = 20
    var b = SessionFile("/home/me/my project/src/tab\there.mojo")
    b.zoomed = True
    d.files.append(a^)
    d.files.append(b^)
    return d^


def test_session_as_text() raises:
    var d = sample()
    var text = d.encode()
    assert_true(text.startswith("turbomojo-session 1\nroot\t/home/me/my project\ntiled\t1\nlayout\tR 500 G 1 0 0 !G 1 0 1\nexplorer\t28\nopened\t/home/me/my project/src\noutline\t1\npanel\t2 9\nfile\t12 4 3 0 1 50 20 0\t/home/me/my project/a b.mojo\n"), text)
    assert_true(text.endswith("end\n"))
    var got = session_decode(text)
    assert_true(got[1])
    assert_equal(got[0].encode(), text)                  # nothing lost, a tab in a file name included
    assert_equal(got[0].files[1].path, "/home/me/my project/src/tab\there.mojo")
    assert_true(got[0].files[1].zoomed)
    assert_equal(got[0].files[0].cr, 12)
    # a plain session
    var plain = SessionData()
    plain.root = "/p"
    assert_equal(plain.encode(), "turbomojo-session 1\nroot\t/p\ntiled\t0\nend\n")
    assert_true(session_decode(plain.encode())[1])
    assert_false(session_decode(plain.encode())[0].explorer)


def test_damaged_session_files() raises:
    var text = sample().encode()
    # cut off (a crash while writing), another version, not a session at all: refused whole
    assert_false(session_decode(String(text[byte=0:text.byte_length() - 5]))[1])
    assert_false(session_decode("turbomojo-session 2\nroot\t/p\nend\n")[1])
    assert_false(session_decode("")[1])
    assert_false(session_decode("hello\nend\n")[1])
    assert_equal(len(session_decode("hello\nend\n")[0].files), 0)
    # single bad lines are skipped, the rest is used
    var odd = session_decode("turbomojo-session 1\nroot\t/p\nfile\t1 2 3\t/p/short.mojo\nfile\t1 2 x 4 5 6 7 0\t/p/letters.mojo\nfile\t1 2 3 4 5 6 7 0\trelative.mojo\nfile\t1 2 3 4 5 6 7 0\t/p/good.mojo\nnonsense\nunknown\tkey\npanel\t1\nexplorer\tmany\nend\n")
    assert_true(odd[1])
    assert_equal(len(odd[0].files), 1)
    assert_equal(odd[0].files[0].path, "/p/good.mojo")
    assert_false(odd[0].panel)
    assert_false(odd[0].explorer)


# ------------------------------------------------------- in the application
def project(tag: String) raises -> String:
    var d = scratch(tag)
    _ = run_system("mkdir -p '" + d + "/proj/src' '" + d + "/state'")
    var body = String("")
    for k in range(60):
        body += "line " + String(k) + " of the file\n"
    for name in ["a.mojo", "b.mojo", "src/c.mojo"]:
        put(d + "/proj/" + name, body)
    return d


def new_app(d: String) -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d + "/proj"
    app.session_dir = d + "/state/sessions"
    return app^


def where(app: App, name: String) -> String:
    """"cr:cc x,y WxH" of a file's window, "hidden" for a tab that does not show."""
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_EDITOR and app.wins[i].title == name:
            var s = String(app.wins[i].cr) + ":" + String(app.wins[i].cc)
            if app.wins[i].hidden:
                return s + " hidden"
            return s + " " + String(app.wins[i].x) + "," + String(app.wins[i].y) + " " + String(app.wins[i].w) + "x" + String(app.wins[i].h)
    return "(not open)"


def test_classic_session_comes_back() raises:
    var d = project("s1")
    var app = new_app(d)
    app.open_path(d + "/proj/a.mojo")
    app.open_path(d + "/proj/src/c.mojo")
    app.open_path(d + "/proj/b.mojo")
    app.wins[app.find_editor(d + "/proj/a.mojo")].goto(40, 7)
    app.wins[app.find_editor(d + "/proj/src/c.mojo")].goto(5, 2)
    var bi = app.find_editor(d + "/proj/b.mojo")
    app.wins[bi].x = 10
    app.wins[bi].y = 3
    app.wins[bi].w = 60
    app.wins[bi].h = 15
    app.exec(CM_SEARCHRES)
    app.focus(app.find_editor(d + "/proj/a.mojo"))
    app.quit()
    assert_false(app.running)
    var files = String("")
    for line in read_text(app.session_path()).split("\n"):
        if String(line).startswith("file\t"):
            files += String(String(line)[byte=String(line).rfind("/") + 1:]) + " "
    assert_equal(files, "c.mojo b.mojo a.mojo ")                 # back to front
    # the next start in the same project
    var again = new_app(d)
    assert_true(again.session_restore())
    assert_equal(again.status, "Session restored: 3 files")
    assert_equal(again.wins[again.top()].title, "a.mojo")        # the one that had the keyboard
    assert_true(where(again, "a.mojo").startswith("40:7 "), where(again, "a.mojo"))
    assert_true(where(again, "c.mojo").startswith("5:2 "), where(again, "c.mojo"))
    assert_equal(where(again, "b.mojo"), "0:0 10,3 60x15")
    assert_true(again.msg_index() >= 0)
    assert_equal(again.msg_page, PG_SEARCH)
    assert_equal(again.explorer_index(), -1)             # it was not open
    # restoring did not count as opening the files (their ranking is the user's doing)
    assert_equal(again.frec.score(d + "/proj/a.mojo", 2000000000), 0)
    _ = run_system("rm -rf '" + d + "'")


def test_tiled_session_with_panels_comes_back() raises:
    var d = project("s2")
    var app = new_app(d)
    app.open_path(d + "/proj/a.mojo")
    app.open_path(d + "/proj/b.mojo")
    app.open_path(d + "/proj/src/c.mojo")
    app.exec(CM_TILED)
    app.exec(CM_SPLIT_RIGHT)                             # [a b] | [c]
    app.wins[app.top()].goto(20, 3)
    app.exec(CM_EXPLORER)
    app.ex.toggle(app.ex.row_of(d + "/proj/src"))
    app.focus(app.find_editor(d + "/proj/src/c.mojo"))
    app.exec(CM_OUTLINE)
    app.layout_sync()
    var before_b = where(app, "b.mojo")
    var before_c = where(app, "c.mojo")
    var shape = app.lay.describe()
    app.session_save()
    var again = new_app(d)
    again.exec(CM_TILED)
    assert_true(again.session_restore())
    again.layout_sync()
    assert_equal(len(again.lay.groups()), 2)
    assert_equal(where(again, "a.mojo"), "0:0 hidden")
    assert_equal(where(again, "b.mojo"), before_b)
    assert_equal(where(again, "c.mojo"), before_c)
    assert_equal(again.wins[again.top()].title, "c.mojo")
    assert_true(again.explorer_index() >= 0)
    assert_true(again.ex.is_open(d + "/proj/src"), "the folder is open again")
    assert_true(again.outline_index() >= 0)
    # same shape of the tree (the ids are new ones)
    assert_equal(shape.count("|"), again.lay.describe().count("|"))
    assert_true(again.lay.describe().endswith("]!)"), again.lay.describe())
    # a session saved tiled, started classic: the files and cursors, not the panes
    var classic = new_app(d)
    assert_true(classic.session_restore())
    assert_false(classic.tiled)
    assert_true(where(classic, "c.mojo").startswith("20:3 "), where(classic, "c.mojo"))
    assert_true(where(classic, "a.mojo").find("hidden") < 0)
    _ = run_system("rm -rf '" + d + "'")


def test_what_a_session_leaves_out_and_when_it_is_not_used() raises:
    var d = project("s3")
    var app = new_app(d)
    app.open_path(d + "/proj/a.mojo")
    app.open_path(d + "/proj/b.mojo")
    app.exec(CM_NEW)                                     # an unnamed window is not part of it
    app.session_save()
    assert_equal(read_text(app.session_path()).count("\nfile\t"), 2)
    # a file that is gone is left out, the rest comes back
    _ = run_system("rm '" + d + "/proj/b.mojo'")
    var again = new_app(d)
    assert_true(again.session_restore())
    assert_equal(again.status, "Session restored: 1 file")
    assert_true(again.find_editor(d + "/proj/a.mojo") >= 0)
    assert_equal(again.find_editor(d + "/proj/b.mojo"), -1)
    # another project has another session (here: none)
    var other = new_app(d)
    other.cwd = d + "/proj/src"
    assert_false(other.session_restore())
    assert_equal(len(other.wins), 0)
    # a damaged file is not half used
    var path = app.session_path()
    put(path, String(read_text(path)[byte=0:40]))
    var broken = new_app(d)
    assert_false(broken.session_restore())
    assert_equal(len(broken.wins), 0)
    # nothing is written when sessions are not kept
    var plain = App()
    plain.scr.resize(100, 30)
    plain.cwd = d + "/proj"
    plain.open_path(d + "/proj/a.mojo")
    plain.session_save()
    plain.quit()
    assert_equal(plain.session_path(), "")
    assert_false(plain.session_restore())
    # the setting
    assert_true(load_settings("", "").restore_session)
    assert_false(load_settings("[ui]\nrestore_session = false\n", "").restore_session)
    assert_equal(len(load_settings("[ui]\nrestore_session = false\n", "").warnings), 0)
    _ = run_system("rm -rf '" + d + "'")


def test_session_is_written_now_and_then() raises:
    var d = project("s4")
    var app = new_app(d)
    app.open_path(d + "/proj/a.mojo")
    var t0 = now_ns()
    app.session_checked_ns = t0
    app.session_tick(t0 + 1000000000)                    # a second later: not yet
    assert_equal(read_text(app.session_path()), "")
    app.session_tick(t0 + 31000000000)
    var first = read_text(app.session_path())
    assert_true(first.find("\nfile\t0 0 0 ") > 0, first)
    app.wins[app.top()].goto(9, 1)
    app.session_tick(t0 + 32000000000)
    assert_equal(read_text(app.session_path()), first)
    app.session_tick(t0 + 62000000000)
    assert_true(read_text(app.session_path()).find("\nfile\t9 1 ") > 0, read_text(app.session_path()))
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
