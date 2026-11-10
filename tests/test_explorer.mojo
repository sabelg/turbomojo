"""The file explorer: its tree model and the file operations."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from explorer import *
from term import ctrl, key_event, KEY_ENTER, KEY_ESC, KEY_DOWN, KEY_UP, KEY_LEFT, KEY_RIGHT, KEY_DELETE, KEY_HOME
from app import *
from appstate import App, now_ns, M_NORMAL, M_DIALOG
from dialog import D_EX_NAME, D_EX_DELETE
from window import WK_EDITOR, WK_EXPLORER
from commands import CM_EXPLORER, CM_TILED, CM_BACK, CM_MESSAGE, build_registry
from signals import own_pid
from util import decode, to_str, env_or, run_system, path_exists, is_dir, bytes_to_str, read_file


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-explorer-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def project(tag: String) raises -> String:
    var d = scratch(tag)
    _ = run_system("mkdir -p '" + d + "/src/deep' '" + d + "/docs' '" + d + "/build' '" + d + "/.git' '" + d + "/.github' '" + d + "/empty'")
    put(d + "/README.md", "readme\n")
    put(d + "/main.mojo", "def main(): pass\n")
    put(d + "/src/b.mojo", "b\n")
    put(d + "/src/a.mojo", "a\n")
    put(d + "/src/deep/x.mojo", "x\n")
    put(d + "/docs/guide.md", "guide\n")
    put(d + "/build/out.o", "o\n")
    put(d + "/.gitignore", "build/\n*.o\n")
    put(d + "/.git/config", "c\n")
    return d


def lines(t: ExplorerTree) -> String:
    var s = String("")
    for k in range(len(t.rows)):
        if k > 0:
            s += " | "
        s += String(t.line(k).strip())
    return s


def test_only_open_folders_are_listed() raises:
    var d = project("tree1")
    var t = ExplorerTree()
    t.set_root(d)
    # folders first, then files, each by name; ignored and hidden things left out
    assert_equal(lines(t), "▸ docs | ▸ empty | ▸ src | README.md | main.mojo")
    assert_equal(t.rows[0].depth, 0)
    t.toggle(2)                                          # open src
    assert_equal(lines(t), "▸ docs | ▸ empty | ▾ src | ▸ deep | a.mojo | b.mojo | README.md | main.mojo")
    assert_equal(t.rows[3].depth, 1)
    assert_equal(t.line(4), "    a.mojo")
    assert_equal(t.line(3), "  ▸ deep")
    t.toggle(3)
    assert_equal(lines(t), "▸ docs | ▸ empty | ▾ src | ▾ deep | x.mojo | a.mojo | b.mojo | README.md | main.mojo")
    assert_equal(t.rows[4].path, d + "/src/deep/x.mojo")
    assert_equal(t.parent_row(4), 3)
    assert_equal(t.parent_row(3), 2)
    assert_equal(t.parent_row(2), -1)
    # closing a folder hides what is in it; opening it again shows its open folders as they were
    t.toggle(2)
    assert_equal(lines(t), "▸ docs | ▸ empty | ▸ src | README.md | main.mojo")
    t.toggle(2)
    assert_equal(lines(t), "▸ docs | ▸ empty | ▾ src | ▾ deep | x.mojo | a.mojo | b.mojo | README.md | main.mojo")
    t.toggle(1)                                          # an empty folder opens to nothing
    assert_equal(lines(t), "▸ docs | ▾ empty | ▾ src | ▾ deep | x.mojo | a.mojo | b.mojo | README.md | main.mojo")
    t.toggle(8)                                          # a file: nothing happens
    assert_equal(len(t.rows), 9)
    _ = run_system("rm -rf '" + d + "'")


def test_ignored_files_can_be_shown_and_changes_on_disk_are_picked_up() raises:
    var d = project("tree2")
    var t = ExplorerTree()
    t.set_root(d)
    t.show_all = True
    t.rebuild()
    # everything but the repository's own folder
    assert_equal(lines(t), "▸ .github | ▸ build | ▸ docs | ▸ empty | ▸ src | .gitignore | README.md | main.mojo")
    t.show_all = False
    t.rebuild()
    assert_equal(lines(t), "▸ docs | ▸ empty | ▸ src | README.md | main.mojo")
    # new and removed files appear after a rebuild; a removed open folder is forgotten
    t.toggle(2)
    put(d + "/src/new.mojo", "n\n")
    _ = run_system("rm '" + d + "/main.mojo' && rm -rf '" + d + "/docs'")
    t.rebuild()
    assert_equal(lines(t), "▸ empty | ▾ src | ▸ deep | a.mojo | b.mojo | new.mojo | README.md")
    _ = run_system("rm -rf '" + d + "/src'")
    t.rebuild()
    assert_equal(lines(t), "▸ empty | README.md")
    assert_equal(len(t.opened), 0)
    # a root that does not exist is an empty tree
    var none_t = ExplorerTree()
    none_t.set_root(d + "/nowhere")
    assert_equal(len(none_t.rows), 0)
    _ = run_system("rm -rf '" + d + "'")


def test_reveal_opens_the_way_to_a_file() raises:
    var d = project("tree3")
    var t = ExplorerTree()
    t.set_root(d)
    var k = t.reveal(d + "/src/deep/x.mojo")
    assert_equal(lines(t), "▸ docs | ▸ empty | ▾ src | ▾ deep | x.mojo | a.mojo | b.mojo | README.md | main.mojo")
    assert_equal(k, 4)
    assert_equal(t.reveal(d + "/main.mojo"), 8)
    assert_equal(t.reveal(d + "/build/out.o"), -1)       # ignored: not shown
    assert_equal(t.reveal("/somewhere/else.mojo"), -1)
    assert_equal(t.reveal(d + "/src/gone.mojo"), -1)
    # where something new would go
    assert_equal(t.folder_for(3), d + "/src/deep")       # an open folder: into it
    assert_equal(t.folder_for(4), d + "/src/deep")       # a file: beside it
    assert_equal(t.folder_for(0), d)                     # a closed folder: beside it
    assert_equal(t.folder_for(-1), d)
    _ = run_system("rm -rf '" + d + "'")


def test_creating_and_moving() raises:
    var d = project("ops1")
    assert_equal(make_file(d + "/src", "c.mojo"), "")
    assert_true(path_exists(d + "/src/c.mojo"))
    assert_equal(len(read_file(d + "/src/c.mojo")), 0)
    assert_equal(make_file(d + "/src", "c.mojo"), "c.mojo exists already")
    assert_equal(make_file(d + "/src", ""), "A name is needed")
    assert_equal(make_file(d + "/src", "a/b"), "A name cannot contain a slash or a line break")
    assert_equal(make_file(d + "/src", ".."), "That name is taken by the system")
    assert_equal(make_file(d + "/no_such", "x"), "Cannot create x")
    assert_equal(make_folder(d, "pkg"), "")
    assert_true(is_dir(d + "/pkg"))
    assert_equal(make_folder(d, "pkg"), "pkg exists already")
    assert_equal(make_folder(d, "README.md"), "README.md exists already")
    # rename, and move into a folder; a name with blanks and quotes
    assert_equal(move_path(d + "/src/a.mojo", d + "/src/it's a file.mojo"), "")
    assert_false(path_exists(d + "/src/a.mojo"))
    assert_equal(bytes_to_str(read_file(d + "/src/it's a file.mojo")), "a\n")
    assert_equal(move_path(d + "/src/b.mojo", d + "/pkg/b.mojo"), "")
    assert_true(path_exists(d + "/pkg/b.mojo"))
    # never over something that exists, never into itself, never from or to nowhere
    assert_equal(move_path(d + "/README.md", d + "/main.mojo"), "main.mojo exists already")
    assert_equal(bytes_to_str(read_file(d + "/main.mojo")), "def main(): pass\n")
    assert_equal(move_path(d + "/src", d + "/src/deep/src"), "A folder cannot be moved into itself")
    assert_equal(move_path(d + "/gone.mojo", d + "/x.mojo"), "gone.mojo is no longer there")
    assert_true(move_path(d + "/README.md", d + "/nowhere/README.md").find("does not exist") > 0)
    # a folder moves with what is in it
    assert_equal(move_path(d + "/src", d + "/pkg/src"), "")
    assert_true(path_exists(d + "/pkg/src/deep/x.mojo"))
    _ = run_system("rm -rf '" + d + "'")


def test_delete_goes_to_the_trash() raises:
    var d = project("ops2")
    var trash = scratch("ops2trash") + "/Trash"
    assert_equal(trash_path(d + "/main.mojo", trash), "")
    assert_false(path_exists(d + "/main.mojo"))
    assert_equal(bytes_to_str(read_file(trash + "/files/main.mojo")), "def main(): pass\n")
    var info = bytes_to_str(read_file(trash + "/info/main.mojo.trashinfo"))
    assert_true(info.startswith("[Trash Info]\nPath=" + d + "/main.mojo\nDeletionDate=20"), info)
    # a second file of the same name does not replace the first
    put(d + "/main.mojo", "second\n")
    assert_equal(trash_path(d + "/main.mojo", trash), "")
    assert_equal(bytes_to_str(read_file(trash + "/files/main.mojo")), "def main(): pass\n")
    assert_equal(bytes_to_str(read_file(trash + "/files/main.mojo.2")), "second\n")
    assert_true(path_exists(trash + "/info/main.mojo.2.trashinfo"))
    # a folder goes whole
    assert_equal(trash_path(d + "/src", trash), "")
    assert_false(path_exists(d + "/src"))
    assert_true(path_exists(trash + "/files/src/deep/x.mojo"))
    # refusals: nothing there, no trash folder, the trash inside the victim
    assert_equal(trash_path(d + "/main.mojo", trash), "main.mojo is no longer there")
    assert_equal(trash_path(d + "/README.md", ""), "No trash folder is known (HOME is not set)")
    assert_true(path_exists(d + "/README.md"))
    _ = run_system("mkdir -p '" + d + "/docs/Trash'")
    assert_equal(trash_path(d + "/docs", d + "/docs/Trash"), "The trash folder is inside what would be deleted")
    assert_true(path_exists(d + "/docs/guide.md"))
    assert_true(default_trash_dir().endswith("/Trash") or default_trash_dir() == "")
    _ = run_system("rm -rf '" + d + "' '" + trash + "'")


# --------------------------------------------------------------- the window
def explorer_app(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.trash_dir = d + "-trash/Trash"
    app.open_path(d + "/main.mojo")
    return app^


def shown(app: App) -> String:
    var xi = app.explorer_index()
    if xi < 0:
        return "(no explorer)"
    var s = String("")
    for r in range(app.wins[xi].buf.count()):
        if r > 0:
            s += " | "
        s += String(to_str(app.wins[xi].buf.line(r)).strip())
    return s


def marked(app: App) -> String:
    var xi = app.explorer_index()
    return String(to_str(app.wins[xi].buf.line(app.wins[xi].cr)).strip())


def type_text(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))


def front(app: App) -> String:
    return app.wins[app.top()].title


def test_explorer_window_at_the_left() raises:
    var d = project("win1")
    var app = explorer_app(d)
    assert_equal(build_registry().find_key(ctrl(101)), CM_EXPLORER)
    app.handle(key_event(ctrl(101)))                     # Ctrl-E
    var xi = app.explorer_index()
    assert_true(xi >= 0)
    assert_equal(app.top(), xi)                          # it has the keyboard
    assert_equal(app.wins[xi].x, 0)
    assert_equal(app.wins[xi].w, 25)
    assert_equal(shown(app), "▸ docs | ▸ empty | ▸ src | README.md | main.mojo")
    assert_equal(marked(app), "main.mojo")               # the file being edited
    # the editor made room
    var ei = app.find_editor(d + "/main.mojo")
    assert_equal(app.wins[ei].x, 25)
    assert_equal(app.wins[ei].w, 75)
    app.draw()
    var screen = to_str(app.scr.to_text())
    assert_true(screen.find(" Files ") > 0)
    assert_true(screen.find("▸ src") > 0)
    assert_true(screen.find("def main(): pass") > 0)
    # Esc: back to the editor; Ctrl-E from there: into the explorer; from inside: close
    app.handle(key_event(KEY_ESC))
    assert_equal(front(app), "main.mojo")
    app.exec(CM_EXPLORER)
    assert_equal(app.wins[app.top()].kind, WK_EXPLORER)
    app.exec(CM_EXPLORER)
    assert_equal(app.explorer_index(), -1)
    ei = app.find_editor(d + "/main.mojo")
    assert_equal(app.wins[ei].x, 0)
    assert_equal(app.wins[ei].w, 100)
    _ = run_system("rm -rf '" + d + "'")


def test_explorer_keys_open_folders_and_files() raises:
    var d = project("win2")
    var app = explorer_app(d)
    app.exec(CM_EXPLORER)
    app.handle(key_event(KEY_HOME))
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_DOWN))
    assert_equal(marked(app), "▸ src")
    app.handle(key_event(KEY_ENTER))
    assert_equal(shown(app), "▸ docs | ▸ empty | ▾ src | ▸ deep | a.mojo | b.mojo | README.md | main.mojo")
    app.handle(key_event(KEY_RIGHT))                     # into the open folder
    assert_equal(marked(app), "▸ deep")
    app.handle(key_event(KEY_RIGHT))                     # opens it
    assert_equal(marked(app), "▾ deep")
    app.handle(key_event(KEY_RIGHT))
    assert_equal(marked(app), "x.mojo")
    app.handle(key_event(KEY_LEFT))                      # from a file: to its folder
    assert_equal(marked(app), "▾ deep")
    app.handle(key_event(KEY_LEFT))                      # closes it
    assert_equal(marked(app), "▸ deep")
    app.handle(key_event(KEY_DOWN))
    assert_equal(marked(app), "a.mojo")
    # Enter on a file opens it and gives it the keyboard; Back returns to the file before
    app.handle(key_event(KEY_ENTER))
    assert_equal(front(app), "a.mojo")
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    assert_true(app.wins[app.top()].x >= 25, "beside the explorer")
    # with the keyboard in an editor the explorer marks that file
    app.explorer_tick(now_ns())
    assert_equal(marked(app), "a.mojo")
    app.focus(app.find_editor(d + "/main.mojo"))
    app.explorer_tick(now_ns())
    assert_equal(marked(app), "main.mojo")
    # letters typed in the explorer do not end up anywhere
    app.focus(app.explorer_index())
    type_text(app, "xyz")
    assert_equal(shown(app).find("xyz"), -1)
    assert_equal(to_str(app.wins[app.find_editor(d + "/main.mojo")].buf.line(0)), "def main(): pass")
    # "." shows what is ignored, again hides it
    type_text(app, ".")
    assert_true(shown(app).find("▸ build") >= 0 and shown(app).find(".gitignore") > 0, shown(app))
    assert_equal(shown(app).find(".git |"), -1)
    type_text(app, ".")
    assert_equal(shown(app).find("build"), -1)
    _ = run_system("rm -rf '" + d + "'")


def test_explorer_creates_renames_and_moves() raises:
    var d = project("win3")
    var app = explorer_app(d)
    app.exec(CM_EXPLORER)
    # n: a new file beside the marked one; it opens for writing
    type_text(app, "n")
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_EX_NAME)
    assert_equal(app.dlg.lines[0], "In .")
    type_text(app, "notes.mojo")
    app.handle(key_event(KEY_ENTER))
    assert_true(path_exists(d + "/notes.mojo"))
    assert_equal(front(app), "notes.mojo")
    assert_true(shown(app).find("notes.mojo") > 0)
    # f: a new folder inside an open folder
    app.focus(app.explorer_index())
    app.wins[app.top()].cr = 2                           # src
    app.handle(key_event(KEY_ENTER))
    type_text(app, "f")
    assert_equal(app.dlg.lines[0], "In src")
    type_text(app, "pkg")
    app.handle(key_event(KEY_ENTER))
    assert_true(is_dir(d + "/src/pkg"))
    assert_equal(app.status, "Created the folder src/pkg")
    assert_equal(marked(app), "▸ pkg")
    # a name that exists: said, nothing done
    type_text(app, "n")
    type_text(app, "a.mojo")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "a.mojo exists already")
    # r: rename an open file - its window follows
    app.open_path(d + "/src/a.mojo")
    app.focus(app.explorer_index())
    app.explorer_tick(now_ns())
    app.wins[app.top()].cr = app.ex.row_of(d + "/src/a.mojo")
    type_text(app, "r")
    assert_equal(app.dlg.field_text(0), "a.mojo")
    type_text(app, "alpha.mojo")                         # typing replaces the old name
    app.handle(key_event(KEY_ENTER))
    assert_true(path_exists(d + "/src/alpha.mojo"))
    assert_false(path_exists(d + "/src/a.mojo"))
    assert_equal(app.status, "Renamed to alpha.mojo")
    assert_equal(marked(app), "alpha.mojo")
    assert_true(app.find_editor(d + "/src/alpha.mojo") >= 0, "the open window has the new name")
    assert_equal(app.wins[app.find_editor(d + "/src/alpha.mojo")].title, "alpha.mojo")
    # m: move it into another folder
    type_text(app, "m")
    assert_equal(app.dlg.field_text(0), "src")
    type_text(app, "src/pkg")
    app.handle(key_event(KEY_ENTER))
    assert_true(path_exists(d + "/src/pkg/alpha.mojo"))
    assert_equal(app.status, "Moved to src/pkg/alpha.mojo")
    assert_equal(marked(app), "alpha.mojo")
    assert_true(app.find_editor(d + "/src/pkg/alpha.mojo") >= 0)
    # out of the project, or into a folder that is not there: refused
    type_text(app, "m")
    type_text(app, "../elsewhere")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "The folder must be inside the project")
    type_text(app, "m")
    type_text(app, "no/such")
    app.handle(key_event(KEY_ENTER))
    assert_true(app.status.find("does not exist") > 0, app.status)
    assert_true(path_exists(d + "/src/pkg/alpha.mojo"))
    # a folder moves with the open files in it
    app.wins[app.top()].cr = app.ex.row_of(d + "/src/pkg")
    type_text(app, "m")
    type_text(app, "docs")
    app.handle(key_event(KEY_ENTER))
    assert_true(path_exists(d + "/docs/pkg/alpha.mojo"))
    assert_true(app.find_editor(d + "/docs/pkg/alpha.mojo") >= 0)
    _ = run_system("rm -rf '" + d + "' '" + d + "-trash'")


def test_explorer_delete_asks_and_uses_the_trash() raises:
    var d = project("win4")
    var app = explorer_app(d)
    app.exec(CM_EXPLORER)
    assert_equal(marked(app), "main.mojo")
    app.handle(key_event(KEY_DELETE))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_EX_DELETE)
    assert_equal(app.dlg.lines[0], "Move main.mojo to the trash?")
    # Enter is the safe answer
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_true(path_exists(d + "/main.mojo"))
    # the other button
    app.handle(key_event(KEY_DELETE))
    app.dialog_button(0)
    assert_false(path_exists(d + "/main.mojo"))
    assert_equal(bytes_to_str(read_file(d + "-trash/Trash/files/main.mojo")), "def main(): pass\n")
    assert_equal(shown(app), "▸ docs | ▸ empty | ▸ src | README.md")
    assert_true(app.status.find("Moved main.mojo to the trash - still open here") == 0, app.status)
    assert_true(app.wins[app.find_editor(d + "/main.mojo")].buf.modified, "its text can be saved back")
    # a folder
    app.wins[app.top()].cr = 2
    app.handle(key_event(KEY_DELETE))
    assert_equal(app.dlg.lines[0], "Move src and everything in it to the trash?")
    app.dialog_button(0)
    assert_false(path_exists(d + "/src"))
    assert_true(path_exists(d + "-trash/Trash/files/src/deep/x.mojo"))
    assert_equal(app.status, "Moved src to the trash")
    _ = run_system("rm -rf '" + d + "' '" + d + "-trash'")


def test_explorer_notices_changes_and_shares_the_screen() raises:
    var d = project("win5")
    var app = explorer_app(d)
    app.exec(CM_EXPLORER)
    # a file made by another program shows up by itself after a moment
    put(d + "/fresh.mojo", "f\n")
    app.explorer_tick(now_ns())
    assert_equal(shown(app).find("fresh.mojo"), -1)      # not read again on every pass
    app.explorer_tick(now_ns() + 3000000000)
    assert_true(shown(app).find("fresh.mojo") > 0, shown(app))
    type_text(app, "u")                                  # and at once on request
    _ = run_system("rm '" + d + "/fresh.mojo'")
    type_text(app, "u")
    assert_equal(shown(app).find("fresh.mojo"), -1)
    # the tiled layout's panes begin where the explorer ends; the bottom panel is below both
    app.exec(CM_TILED)
    app.exec(CM_MESSAGE)
    app.layout_sync()
    var ei = app.find_editor(d + "/main.mojo")
    var xi = app.explorer_index()
    assert_equal(app.wins[ei].x, app.wins[xi].w)
    assert_equal(app.wins[ei].x + app.wins[ei].w, 100)
    assert_equal(app.wins[ei].y + app.wins[ei].h, app.wins[app.msg_index()].y)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
