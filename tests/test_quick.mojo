"""The palette: files ranked by how often and how lately they were opened, ">" commands,
"@" symbols, "#" project symbols, ":" line."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from frecency import Frecency, frec_weight, FREC_MAX
from symindex import FileIndex
from dialog import Dialog, Field, D_PALETTE
from term import alt, ctrl, key_event, KEY_ENTER, KEY_ESC, KEY_BACKSPACE, KEY_DOWN
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from commands import CM_QUICK, CM_PALETTE, CM_BACK, CM_LINENUM, build_registry
from config import read_text
from signals import own_pid
from util import decode, to_str, env_or, run_system, unix_time, path_exists


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-quick-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def project(tag: String) raises -> String:
    var d = scratch(tag)
    _ = run_system("mkdir -p '" + d + "/src' '" + d + "/docs' '" + d + "/build'")
    put(d + "/main.mojo", "comptime LIMIT = 3\n\ndef main():\n    pass\n\ndef helper():\n    pass\n")
    put(d + "/src/window.mojo", "struct Window:\n    def draw(self): pass\n")
    put(d + "/src/widget.mojo", "def make_widget(): pass\n")
    put(d + "/docs/notes.md", "notes\n")
    put(d + "/README.md", "readme\n")
    put(d + "/build/window.o", "o\n")
    put(d + "/.gitignore", "build/\n")
    return d


# ------------------------------------------------------------------ frecency
def test_frecency_counts_and_ages() raises:
    var f = Frecency()
    var now = 1000000000
    assert_equal(f.score("/p/a", now), 0)
    f.note("/p/a", now - 60)
    assert_equal(f.score("/p/a", now), 100)              # once, just now
    f.note("/p/a", now - 30)
    f.note("/p/a", now - 10)
    assert_equal(f.score("/p/a", now), 300)
    # the same count is worth less as time passes
    assert_equal(f.score("/p/a", now + 5 * 3600), 210)
    assert_equal(f.score("/p/a", now + 3 * 24 * 3600), 150)
    assert_equal(f.score("/p/a", now + 20 * 24 * 3600), 90)
    assert_equal(f.score("/p/a", now + 400 * 24 * 3600), 30)
    # often but long ago is beaten by a few times today
    f.note("/p/b", now)
    f.note("/p/b", now)
    assert_true(f.score("/p/b", now + 3 * 24 * 3600 + 5) > 0)
    for _ in range(30):
        f.note("/p/c", now - 100 * 24 * 3600)
    assert_equal(f.score("/p/c", now), 100)              # counted up to ten times only
    assert_true(f.score("/p/a", now) > f.score("/p/c", now))
    assert_equal(frec_weight(0), 100)
    assert_equal(frec_weight(-5), 100)
    f.forget("/p/c")
    assert_equal(f.score("/p/c", now), 0)
    f.forget("/p/none")


def test_frecency_is_kept_as_text() raises:
    var f = Frecency()
    f.note("/p/with space.mojo", 100)
    f.note("/p/b.mojo", 200)
    f.note("/p/with space.mojo", 300)
    assert_equal(f.encode(), "2 300 /p/with space.mojo\n1 200 /p/b.mojo\n")
    var g = Frecency()
    g.decode_text(f.encode())
    assert_equal(g.encode(), f.encode())
    # damaged lines are passed over, the rest is read
    var h = Frecency()
    h.decode_text("garbage\n3 400 /p/ok.mojo\nx y /p/bad.mojo\n5 500\n-2 600 /p/neg.mojo\n1 700 relative.mojo\n3 400 /p/ok.mojo\n\n")
    assert_equal(h.encode(), "3 400 /p/ok.mojo\n")
    h.decode_text("")
    assert_equal(len(h.paths), 0)
    # the list does not grow without end: the least recently opened go
    var big = Frecency()
    for k in range(FREC_MAX + 20):
        big.note("/p/f" + String(k), k)
    assert_equal(len(big.paths), FREC_MAX)
    assert_equal(big.paths[0], "/p/f" + String(FREC_MAX + 19))
    assert_equal(big.score("/p/f0", 1000), 0)


def test_file_index_lists_the_project() raises:
    var d = project("idx")
    var idx = FileIndex()
    idx.start(d)
    idx.step(0)
    assert_true(idx.building)
    assert_equal(len(idx.files), 0)
    var guard = 0
    while idx.building and guard < 1000:
        idx.step(5)
        guard += 1
    var names = String("")
    for p in idx.files:
        names += String(p[byte=d.byte_length() + 1:]) + " "
    assert_equal(names, "README.md main.mojo docs/notes.md src/widget.mojo src/window.mojo ")       # not build/, not dot files
    _ = run_system("rm -rf '" + d + "'")


def test_list_matching_with_a_set_pattern_and_boosts() raises:
    var d = Dialog(D_PALETTE, "t", 40, 12)
    d.fields.append(Field("x", "whatever is typed"))
    d.list_filter = True
    d.use_pat = True
    d.pat = ""
    var items = List[String]()
    var data = List[Int]()
    for name in ["alpha", "beta", "gamma", "alphabet"]:
        items.append(String(name))
        data.append(len(data))
    d.boost = [0, 50, 500, 0]
    d.set_items(items^, data^)
    # no pattern: everything, the boosted ones first, the rest in their order
    assert_equal(len(d.shown), 4)
    assert_equal(d.shown[0], 2)
    assert_equal(d.shown[1], 1)
    assert_equal(d.shown[2], 0)
    # the pattern is the one that was set, not the field's text
    d.pat = "alph"
    d.refilter()
    assert_equal(len(d.shown), 2)
    d.boost = [0, 0, 0, 900]
    d.refilter()
    assert_equal(d.shown[0], 3)                          # a boost lifts an equal match
    d.pat = "zzz"
    d.refilter()
    assert_equal(len(d.shown), 0)                        # a boost never makes a non-match appear


# --------------------------------------------------------------- the palette
def quick_app(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/main.mojo")
    return app^


def listed(app: App) -> String:
    """The first word of each shown item, joined with spaces."""
    var s = String("")
    for k in range(len(app.dlg.shown)):
        var item = app.dlg.items[app.dlg.shown[k]]
        var cut = item.find("  ")
        s += String(String(item[byte=0:cut]) if cut > 0 else item) + ("|" if k + 1 < len(app.dlg.shown) else "")
    return s


def type_text(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))


def settle(mut app: App):
    while app.fidx.building or app.symidx.building:
        app.quick_tick()
        app.symidx_tick()


def front(app: App) -> String:
    var t = app.top()
    return app.wins[t].title + ":" + String(app.wins[t].cr) + ":" + String(app.wins[t].cc)


def test_files_by_name() raises:
    var d = project("p1")
    var app = quick_app(d)
    assert_equal(build_registry().find_key(alt(103)), CM_QUICK)
    app.handle(key_event(alt(103)))                      # Alt-G
    settle(app)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_PALETTE)
    # nothing typed: the file opened before comes first, then the others
    assert_equal(listed(app), "main.mojo|README.md|notes.md|widget.mojo|window.mojo")
    type_text(app, "wi")
    assert_equal(listed(app), "widget.mojo|window.mojo")
    type_text(app, "n")
    assert_equal(listed(app), "window.mojo")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(front(app), "window.mojo:0:0")
    app.exec(CM_BACK)                                    # it was a jump
    assert_equal(front(app), "main.mojo:0:0")
    # a folder name narrows too; the item says where the file is
    app.exec(CM_QUICK)
    type_text(app, "docs")
    assert_equal(listed(app), "notes.md")
    assert_true(app.dlg.items[app.dlg.shown[0]].endswith(" docs"), app.dlg.items[app.dlg.shown[0]])
    app.handle(key_event(KEY_ESC))
    assert_equal(front(app), "main.mojo:0:0")
    # nothing matches: said, nothing opened
    app.exec(CM_QUICK)
    type_text(app, "qqqq")
    assert_equal(listed(app), "")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "Nothing in the list matches")
    _ = run_system("rm -rf '" + d + "'")


def test_files_opened_often_and_lately_come_first() raises:
    var d = project("p2")
    var app = quick_app(d)
    app.open_path(d + "/src/widget.mojo")
    app.open_path(d + "/src/widget.mojo")
    app.open_path(d + "/docs/notes.md")
    app.exec(CM_QUICK)
    settle(app)
    # widget twice, main and notes once (ties: the order of the project)
    assert_equal(listed(app), "widget.mojo|main.mojo|notes.md|README.md|window.mojo")
    # among files that match equally well the one used more wins
    type_text(app, "w")
    assert_equal(listed(app).find("widget.mojo|window.mojo"), 0)
    app.handle(key_event(KEY_ESC))
    # "name:line" and "name:line:column" open the file there
    app.exec(CM_QUICK)
    type_text(app, "main:6:5")
    assert_equal(listed(app), "main.mojo")
    app.handle(key_event(KEY_ENTER))
    assert_equal(front(app), "main.mojo:5:4")
    # the record survives a restart when it has a file
    var store = d + "/state/opened"
    app.frec_path = store
    app.open_path(d + "/README.md")
    assert_true(read_text(store).find(" " + d + "/README.md\n") > 0, read_text(store))
    var again = Frecency()
    again.decode_text(read_text(store))
    assert_equal(again.paths[0], d + "/README.md")
    assert_true(again.score(d + "/src/widget.mojo", unix_time()) >= 200)
    _ = run_system("rm -rf '" + d + "'")


def test_commands_symbols_and_lines() raises:
    var d = project("p3")
    var app = quick_app(d)
    # Ctrl-P: the same palette, starting with ">"
    assert_equal(build_registry().find_key(ctrl(112)), CM_PALETTE)
    app.handle(key_event(ctrl(112)))
    assert_equal(app.dlg.kind, D_PALETTE)
    assert_equal(app.dlg.field_text(0), ">")
    assert_true(len(app.dlg.shown) > 40, "every command of the menus")
    var was = app.line_numbers
    type_text(app, "line num")
    assert_true(listed(app).find("Options: Line numbers") == 0, listed(app))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.line_numbers, not was)
    # taking the ">" away turns the same palette to files
    app.exec(CM_PALETTE)
    app.handle(key_event(KEY_BACKSPACE))
    settle(app)
    assert_true(listed(app).find("main.mojo") == 0, listed(app))
    # "@": the symbols of the file in front
    type_text(app, "@")
    assert_equal(listed(app), "= LIMIT|ƒ main|ƒ helper")
    type_text(app, "hel")
    assert_equal(listed(app), "ƒ helper")
    app.handle(key_event(KEY_ENTER))
    assert_equal(front(app), "main.mojo:5:4")
    # "#": symbols of the whole project
    app.exec(CM_QUICK)
    type_text(app, "#")
    settle(app)
    type_text(app, "draw")
    assert_true(listed(app).find("ƒ draw") == 0, listed(app))
    app.handle(key_event(KEY_ENTER))
    assert_equal(front(app), "window.mojo:1:8")
    # ":": a line of the file in front
    app.exec(CM_QUICK)
    type_text(app, ":")
    assert_equal(app.dlg.items[0], "Type a line number")
    type_text(app, "2")
    assert_equal(app.dlg.items[0], "Go to line 2 of window.mojo (3 lines)")
    app.handle(key_event(KEY_ENTER))
    assert_equal(front(app), "window.mojo:1:0")
    app.exec(CM_QUICK)
    type_text(app, ":1:5")
    assert_equal(app.dlg.items[0], "Go to line 1, column 5 of window.mojo (3 lines)")
    app.handle(key_event(KEY_ENTER))
    assert_equal(front(app), "window.mojo:0:4")
    app.exec(CM_QUICK)
    type_text(app, ":x")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "No line number was given")
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
