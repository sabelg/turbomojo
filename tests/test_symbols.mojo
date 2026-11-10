"""IDE-side symbol features that need no language server: the other uses of the word at
the cursor are highlighted, and an index of the project's symbols with a fuzzy picker."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from symindex import *
from outline import OutlineItem, scan_outline, SK_FUNCTION, SK_STRUCT, SK_METHOD
from buffer import TextBuffer
from window_draw import word_at, word_spans
from window_search import *
from search import make_search
from term import fkey, key_event, MOD_ALT, MOD_SHIFT, KEY_ENTER, KEY_ESC, KEY_DOWN, KEY_RIGHT
from app import *
from appstate import App, now_ns, M_NORMAL, M_DIALOG
from dialog import D_WSYMBOL
from commands import CM_WSYMBOL, CM_BACK, CM_SAVE, CM_NEW, build_registry
from config import load_settings
from signals import own_pid
from util import decode, to_str, cp_len, env_or, run_system


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-symbols-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def project(tag: String) raises -> String:
    """A small project: two Mojo files, one in a folder, plus things to pass over."""
    var d = scratch(tag)
    _ = run_system("mkdir -p '" + d + "/geo' '" + d + "/build' '" + d + "/.hidden'")
    put(d + "/main.mojo", "from geo.shapes import Point\n\ncomptime LIMIT = 3\n\ndef main():\n    pass\n")
    put(d + "/geo/shapes.mojo", "struct Point:\n    var x: Int\n\n    def norm(self) -> Int:\n        return self.x\n\ntrait Shape:\n    def area(self) -> Int: ...\n\ndef make_point() -> Point:\n    return Point()\n")
    put(d + "/geo/fire.🔥", "def lit(): pass\n")
    put(d + "/notes.txt", "def not_code(): pass\n")
    put(d + "/build/generated.mojo", "def generated(): pass\n")
    put(d + "/.hidden/secret.mojo", "def secret(): pass\n")
    put(d + "/.gitignore", "build/\n")
    return d


def names(syms: List[IndexedSymbol]) -> String:
    var s = String("")
    for x in syms:
        if s.byte_length() > 0:
            s += " "
        s += x.name
    return s


def finish(mut idx: SymbolIndex):
    var guard = 0
    while idx.building and guard < 10000:
        idx.step(5)
        guard += 1


# ---------------------------------------------------------------- the index
def test_index_covers_the_projects_mojo_files() raises:
    var d = project("idx1")
    var idx = SymbolIndex()
    assert_false(idx.built)
    idx.start(d)
    assert_true(idx.building)
    finish(idx)
    assert_true(idx.built)
    # this folder's files first, then folders by name; files that are not Mojo, ignored
    # folders (.gitignore) and hidden ones are passed over
    assert_equal(names(idx.syms), "LIMIT main lit Point norm Shape area make_point")
    assert_equal(idx.summary(), "8 symbols in 3 files")
    var norm = idx.syms[4].copy()
    assert_equal(norm.path, d + "/geo/shapes.mojo")
    assert_equal(norm.row, 3)
    assert_equal(norm.col, 8)
    assert_equal(norm.kind, SK_METHOD)
    assert_equal(norm.owner, "Point")
    assert_equal(idx.syms[7].owner, "")                  # after the trait, at top level again
    assert_equal(idx.syms[3].kind, SK_STRUCT)
    _ = run_system("rm -rf '" + d + "'")


def test_index_is_built_in_slices_and_stays_usable() raises:
    var d = project("idx2")
    var idx = SymbolIndex()
    idx.start(d)
    idx.step(0)                                         # one unit of work only
    assert_true(idx.building, "a pass is not done in one unit")
    assert_equal(len(idx.syms), 0)
    finish(idx)
    assert_equal(len(idx.syms), 8)
    # a second pass: the finished index is there until the new one is complete
    put(d + "/extra.mojo", "def extra(): pass\n")
    idx.start(d)
    idx.step(0)
    assert_true(idx.building)
    assert_equal(len(idx.syms), 8)
    finish(idx)
    assert_equal(names(idx.syms), "extra LIMIT main lit Point norm Shape area make_point")
    # one file replaced (as after a save): its old symbols go, the new ones come
    var b = TextBuffer()
    b.load(decode("def renamed(): pass\nstruct Added:\n    def m(self): pass\n"))
    idx.replace_file(d + "/main.mojo", scan_outline(b))
    assert_equal(names(idx.syms), "extra lit Point norm Shape area make_point renamed Added m")
    assert_equal(idx.syms[9].owner, "Added")
    # a folder that does not exist: an empty, finished index
    var none_idx = SymbolIndex()
    none_idx.start(d + "/no_such_folder")
    finish(none_idx)
    assert_true(none_idx.built)
    assert_equal(none_idx.summary(), "0 symbols in 0 files")
    _ = run_system("rm -rf '" + d + "'")


def test_owners_and_file_kinds() raises:
    var b = TextBuffer()
    b.load(decode("def a():\n    def inner(): pass\nstruct S:\n    def m(self):\n        def deep(): pass\ndef z(): pass\n"))
    var own = owners_of(scan_outline(b))
    assert_equal(len(own), 6)
    assert_equal(own[0], "")
    assert_equal(own[1], "a")
    assert_equal(own[2], "")
    assert_equal(own[3], "S")
    assert_equal(own[4], "m")
    assert_equal(own[5], "")
    assert_true(is_mojo_file("/x/a.mojo"))
    assert_true(is_mojo_file("/x/a.🔥"))
    assert_false(is_mojo_file("/x/a.mojo.bak"))
    assert_false(is_mojo_file("/x/mojo"))


# --------------------------------------------------------------- the picker
def shown_items(app: App) -> String:
    var s = String("")
    for k in range(len(app.dlg.shown)):
        if k > 0:
            s += " | "
        var item = app.dlg.items[app.dlg.shown[k]]
        s += String(String(item[byte=0:item.find("  ")]) if item.find("  ") > 0 else item)
    return s


def test_go_to_symbol_in_project() raises:
    var d = project("pick1")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/main.mojo")
    assert_equal(build_registry().find_key(fkey(12) | MOD_ALT), CM_WSYMBOL)
    app.handle(key_event(fkey(12) | MOD_ALT))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_WSYMBOL)
    while app.symidx.building:
        app.symidx_tick()
    assert_equal(len(app.dlg.items), 8)
    assert_equal(app.status, "8 symbols in 3 files")
    # an item says what it is, where it is nested, and where it lives
    var norm = String("")
    for it in app.dlg.items:
        if it.find("norm") >= 0:
            norm = it
    assert_true(norm.startswith("ƒ norm  (Point)"), norm)
    assert_true(norm.endswith(" geo/shapes.mojo:4"), norm)
    # typing narrows the list, best match first
    for c in decode("point"):
        app.handle(key_event(c))
    # (the methods of Point come along: the owner's name counts too)
    assert_equal(shown_items(app), "◆ Point | ƒ norm | ƒ make_point")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    var t = app.top()
    assert_equal(app.wins[t].path, d + "/geo/shapes.mojo")
    assert_equal(app.wins[t].cr, 0)
    assert_equal(app.wins[t].cc, 7)
    assert_equal(app.status, "Point")
    app.exec(CM_BACK)                                    # it was a jump
    assert_equal(app.wins[app.top()].path, d + "/main.mojo")
    # Esc changes nothing
    app.exec(CM_WSYMBOL)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.wins[app.top()].path, d + "/main.mojo")
    _ = run_system("rm -rf '" + d + "'")


def test_picker_knows_unsaved_and_saved_changes() raises:
    var d = project("pick2")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/main.mojo")
    app.exec(CM_WSYMBOL)
    while app.symidx.building:
        app.symidx_tick()
    app.handle(key_event(KEY_ESC))
    # a function typed but not saved is listed (the open window is read, not the disk)
    var i = app.find_editor(d + "/main.mojo")
    app.wins[i].goto(6, 0)
    for c in decode("def unsaved_one(): pass"):
        app.handle(key_event(c))
    app.exec(CM_WSYMBOL)
    for c in decode("unsaved"):
        app.handle(key_event(c))
    assert_equal(shown_items(app), "ƒ unsaved_one")
    app.handle(key_event(KEY_ESC))
    # after saving and closing the window the index itself has it
    app.exec(CM_SAVE)
    var has = False
    for s in app.symidx.syms:
        if s.name == "unsaved_one" and s.path == d + "/main.mojo":
            has = True
    assert_true(has, "saving updates the index")
    # a file removed behind the editor's back: said, not opened
    app.exec(CM_WSYMBOL)
    while app.symidx.building:
        app.symidx_tick()
    _ = run_system("rm '" + d + "/geo/fire.🔥'")
    for c in decode("lit"):
        app.handle(key_event(c))
    # letters in order are enough ("LImiT"); the exact name is first. File names do not count:
    # "shapes.mojo" has l, i, t too, but its symbols are not listed
    assert_equal(shown_items(app), "ƒ lit | = LIMIT")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "fire.🔥 is no longer there")
    assert_equal(app.wins[app.top()].path, d + "/main.mojo")
    _ = run_system("rm -rf '" + d + "'")


def test_picker_fills_in_when_a_slow_pass_finishes() raises:
    var d = scratch("pick3")
    for k in range(40):
        put(d + "/f" + String(k) + ".mojo", "def fn_" + String(k) + "(): pass\n")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.exec(CM_NEW)
    # as if the first slice had no time at all: start the pass by hand
    app.symidx.start(d)
    app.symidx.step(0)
    assert_true(app.symidx.building)
    app.exec(CM_WSYMBOL)
    if app.symidx.building:
        assert_equal(app.status, "Reading the project's files...")
        assert_true(len(app.dlg.items) < 40)
    for c in decode("fn_3"):
        app.handle(key_event(c))
    while app.symidx.building:
        app.symidx_tick()
    assert_equal(len(app.dlg.items), 40)
    assert_equal(app.dlg.field_text(0), "fn_3")          # what was typed is kept
    assert_equal(len(app.dlg.shown), 13)                 # fn_3, fn_30..fn_39, and fn_13, fn_23 (letters in order)
    assert_equal(app.dlg.items[app.dlg.shown[0]].find("ƒ fn_3 "), 0)
    assert_equal(app.status, "40 symbols in 40 files")
    _ = run_system("rm -rf '" + d + "'")


# ------------------------------------------- other uses of the word at the cursor
def test_word_at_and_its_spans() raises:
    assert_equal(to_str(word_at(decode("x = total + 1"), 4)), "total")
    assert_equal(to_str(word_at(decode("x = total + 1"), 9)), "total")           # right after it
    assert_equal(to_str(word_at(decode("x = total + 1"), 6)), "total")
    assert_equal(len(word_at(decode("x = total + 1"), 0)), 0)                    # one letter: too common
    assert_equal(len(word_at(decode("x = total + 1"), 3)), 0)                    # on a blank
    assert_equal(len(word_at(decode("n = 1234"), 6)), 0)                         # a number
    assert_equal(to_str(word_at(decode("größe = 1"), 2)), "größe")
    assert_equal(len(word_at(decode(""), 0)), 0)
    assert_equal(len(word_at(decode("ab"), 99)), 0 if False else 2)              # past the end: the last word
    var sp = word_spans(decode("total = total_x + total; subtotal(total)"), decode("total"))
    assert_equal(len(sp), 6)
    assert_equal(sp[0], 0)
    assert_equal(sp[1], 5)
    assert_equal(sp[2], 18)                              # not total_x
    assert_equal(sp[4], 34)                              # not subtotal
    assert_equal(len(word_spans(decode("abc"), decode("abcd"))), 0)
    assert_equal(len(word_spans(decode(""), decode("ab"))), 0)
    assert_equal(len(word_spans(decode("aaaa"), decode("aa"))), 0)               # only whole words


def bg_of(mut app: App, row: Int, col: Int) -> Int:
    app.draw()
    var t = app.top()
    return app.scr.bg_at(app.wins[t].x + 1 + app.wins[t].gut + col, app.wins[t].y + 1 + row)


def test_other_uses_are_highlighted_in_the_editor() raises:
    var d = scratch("word1")
    put(d + "/a.mojo", "total = 1\nprint(total, subtotal)\ny = total\n")
    var app = App()
    app.scr.resize(80, 24)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    var i = app.find_editor(d + "/a.mojo")
    var p = app.pal.copy()
    assert_true(p.word_bg != p.ed_bg and p.word_bg != p.curline_bg and p.word_bg != p.sel_bg)
    app.wins[i].goto(2, 5)                               # on "total" in the last line
    assert_equal(bg_of(app, 0, 0), p.word_bg)
    assert_equal(bg_of(app, 0, 4), p.word_bg)
    assert_true(bg_of(app, 0, 5) != p.word_bg)           # the blank after it
    assert_equal(bg_of(app, 1, 6), p.word_bg)
    assert_true(bg_of(app, 1, 16) != p.word_bg, "subtotal is another word")
    assert_equal(bg_of(app, 2, 4), p.word_bg)            # the one under the cursor too
    # elsewhere: nothing
    app.wins[i].goto(0, 6)
    assert_true(bg_of(app, 1, 6) != p.word_bg)
    # a selection takes the highlight away (the selection is what matters then)
    app.wins[i].goto(2, 5)
    app.handle(key_event(KEY_RIGHT | MOD_SHIFT))
    assert_true(bg_of(app, 0, 0) != p.word_bg)
    app.handle(key_event(KEY_ESC))
    assert_equal(bg_of(app, 0, 0), p.word_bg)
    # while the matches of a search are shown, they are the only marking
    app.wins[i].set_highlight(make_search(decode("print"), True, False, False))
    assert_true(bg_of(app, 0, 0) != p.word_bg)
    assert_equal(bg_of(app, 1, 0), p.match_bg)
    app.wins[i].clear_highlight()
    assert_equal(bg_of(app, 0, 0), p.word_bg)
    # another window in front: only the active editor shows it
    app.exec(CM_NEW)
    app.draw()
    var behind = app.find_editor(d + "/a.mojo")
    var found = False
    for y in range(app.scr.h):
        for x in range(app.scr.w):
            if app.scr.bg_at(x, y) == p.word_bg:
                found = True
    assert_false(found)
    # the setting turns it off
    app.focus(behind)
    assert_equal(bg_of(app, 0, 0), p.word_bg)
    app.apply_settings(load_settings("[editor]\nhighlight_word = false\n", ""))
    assert_true(bg_of(app, 0, 0) != p.word_bg)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
