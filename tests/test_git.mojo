"""Tests for the line diff (src/linediff.mojo) and the git model (src/git.mojo). The
status parser is fed what a real git prints; the commands are run against a real
repository made under $TMPDIR."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.random import random_ui64, seed
from linediff import *
from git import *
from signals import own_pid
from term import wait_readable, key_event, KEY_ENTER, KEY_END, ctrl
from app import *
from appstate import App, now_ns
from window import WK_EDITOR, WK_EXPLORER
from commands import CM_EXPLORER
from buffer import TextBuffer
from util import to_str, read_file
from util import env_or, run_system, run_capture, bytes_to_str, write_file, str_bytes, shell_quote, which, decode


def hashes(s: String) -> List[UInt64]:
    return text_hashes(decode(s))


def apply(old: List[UInt64], new: List[UInt64], hunks: List[Hunk]) raises -> List[UInt64]:
    """The old lines with the hunks done to them (the new lines taken from `new`)."""
    var out = List[UInt64]()
    var at = 0
    for h in hunks:
        assert_true(h.a >= at, "hunks are in order and do not overlap")
        for k in range(at, h.a):
            out.append(old[k])
        for k in range(h.b, h.b + h.lb):
            out.append(new[k])
        at = h.a + h.la
    for k in range(at, len(old)):
        out.append(old[k])
    return out^


def test_hash_ignores_carriage_return() raises:
    assert_equal(line_hash(decode("abc\r")), line_hash(decode("abc")))
    assert_true(line_hash(decode("abc")) != line_hash(decode("abd")))
    assert_equal(len(hashes("a\nb\n")), 2)
    assert_equal(len(hashes("a\nb")), 2)
    assert_equal(len(hashes("a\n\nb\n")), 3)


def test_simple_edits() raises:
    var old = hashes("a\nb\nc\nd\n")
    assert_equal(len(diff_lines(old, old)), 0)
    var ins = diff_lines(old, hashes("a\nb\nX\nc\nd\n"))
    assert_equal(len(ins), 1)
    assert_true(ins[0] == Hunk(2, 0, 2, 1))
    var rm = diff_lines(old, hashes("a\nc\nd\n"))
    assert_equal(len(rm), 1)
    assert_true(rm[0] == Hunk(1, 1, 1, 0))
    var ch = diff_lines(old, hashes("a\nB\nc\nD\n"))
    assert_equal(len(ch), 2)
    assert_true(ch[0] == Hunk(1, 1, 1, 1))
    assert_true(ch[1] == Hunk(3, 1, 3, 1))
    # everything new, everything gone
    assert_true(diff_lines(List[UInt64](), old)[0] == Hunk(0, 0, 0, 4))
    assert_true(diff_lines(old, List[UInt64]())[0] == Hunk(0, 4, 0, 0))


def test_moved_block_is_one_removal_and_one_insertion() raises:
    # the shortest edit keeps the longer run in place
    var h = diff_lines(hashes("x\na\nb\nc\n"), hashes("a\nb\nc\nx\n"))
    assert_equal(len(h), 2)
    assert_true(h[0] == Hunk(0, 1, 0, 0))
    assert_true(h[1] == Hunk(4, 0, 3, 1))


def test_random_diffs_rebuild_the_new_text() raises:
    seed(7)
    for trial in range(300):
        var old = List[UInt64]()
        var n = Int(random_ui64(0, 40))
        for _ in range(n):
            old.append(random_ui64(0, 5))
        # a new text made by random edits of the old one
        var new = old.copy()
        for _ in range(Int(random_ui64(0, 8))):
            var op = random_ui64(0, 2)
            var at = Int(random_ui64(0, UInt64(len(new))))
            if op == 0:
                new.insert(at, random_ui64(0, 7))
            elif op == 1 and len(new) > 0 and at < len(new):
                _ = new.pop(at)
            elif len(new) > 0 and at < len(new):
                new[at] = random_ui64(0, 7)
        var hunks = diff_lines(old, new)
        var got = apply(old, new, hunks)
        assert_equal(len(got), len(new), "trial " + String(trial))
        for k in range(len(new)):
            assert_equal(got[k], new[k], "trial " + String(trial))
        # with a tiny limit the result is still a correct (if coarse) diff
        var coarse = apply(old, new, diff_lines(old, new, 1))
        assert_equal(len(coarse), len(new))


def test_line_marks() raises:
    var old = hashes("a\nb\nc\nd\n")
    var m = line_marks(diff_lines(old, hashes("a\nX\nb\nC\nd\n")), 5)
    assert_equal(Int(m[0]), LM_NONE)
    assert_equal(Int(m[1]), LM_ADDED)
    assert_equal(Int(m[2]), LM_NONE)
    assert_equal(Int(m[3]), LM_CHANGED)
    m = line_marks(diff_lines(old, hashes("a\nd\n")), 2)
    assert_equal(Int(m[0]), LM_NONE)
    assert_equal(Int(m[1]), LM_DELETED_ABOVE)
    m = line_marks(diff_lines(old, hashes("a\nb\n")), 2)
    assert_equal(Int(m[1]), LM_DELETED_BELOW)
    # nothing left at all: no line to put a mark on
    assert_equal(len(line_marks(diff_lines(old, List[UInt64]()), 0)), 0)


comptime STATUS = "# branch.oid 1f2e3d\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +0 -0\0"
    + "1 .M N... 100644 100644 100644 aaa aaa src/a.mojo\0"
    + "1 A. N... 000000 100644 100644 000 bbb src/new dir/b c.mojo\0"
    + "2 R. N... 100644 100644 100644 ccc ccc R100 docs/moved.md\0docs/old.md\0"
    + "1 .D N... 100644 100644 000000 ddd ddd gone.txt\0"
    + "u UU N... 100644 100644 100644 100644 e1 e2 e3 src/clash.mojo\0"
    + "? notes.txt\0"
    + "? build/\0"
    + "! ignored.log\0"


def test_status_is_parsed() raises:
    var st = GitStatus()
    st.root = "/r"
    st.parse(STATUS)
    assert_equal(st.branch, "main")
    assert_equal(st.code_of("/r/src/a.mojo"), GS_MODIFIED)
    assert_equal(st.code_of("/r/src/new dir/b c.mojo"), GS_ADDED)
    assert_equal(st.code_of("/r/docs/moved.md"), GS_RENAMED)
    assert_equal(st.code_of("/r/docs/old.md"), GS_NONE)
    assert_equal(st.code_of("/r/gone.txt"), GS_DELETED)
    assert_equal(st.code_of("/r/src/clash.mojo"), GS_CONFLICT)
    assert_equal(st.code_of("/r/notes.txt"), GS_UNTRACKED)
    assert_equal(st.code_of("/r/ignored.log"), GS_NONE)
    # a folder nothing in which is tracked, and what is in it
    assert_equal(st.code_of("/r/build"), GS_UNTRACKED)
    assert_equal(st.code_of("/r/build/x/y.o"), GS_UNTRACKED)
    assert_equal(st.code_of("/r/buildings"), GS_NONE)
    # folders: the most urgent thing in them
    assert_equal(st.code_of("/r/src"), GS_CONFLICT)
    assert_equal(st.code_of("/r/src/new dir"), GS_ADDED)
    assert_equal(st.code_of("/r/docs"), GS_RENAMED)
    assert_equal(st.code_of("/r"), GS_NONE)
    assert_equal(st.changed_count(), 6)
    assert_equal(status_letter(GS_MODIFIED), "M")
    assert_equal(status_letter(GS_UNTRACKED), "U")
    assert_equal(status_letter(GS_NONE), "")
    # read again: nothing of before is left
    st.parse("# branch.head (detached)\0")
    assert_equal(st.branch, "(detached)")
    assert_equal(st.code_of("/r/src/a.mojo"), GS_NONE)
    assert_equal(st.code_of("/r/build/x"), GS_NONE)


def test_paths() raises:
    assert_equal(rel_to("/r", "/r/a/b.mojo"), "a/b.mojo")
    assert_equal(rel_to("/r", "/rx/b.mojo"), "")
    assert_equal(rel_to("/r/", "/r/b.mojo"), "b.mojo")
    assert_equal(rel_to("", "/r/b.mojo"), "")


def scratch() -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-git-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d + "/sub/deeper"))
    return d


def git(d: String, args: String) -> Int:
    return run_system("git -C " + shell_quote(d) + " -c user.name=t -c user.email=t@t -c init.defaultBranch=work " + args + " >/dev/null 2>&1")


def test_real_repository() raises:
    if which("git").byte_length() == 0:
        print("    (git is not installed: skipped)")
        return
    var d = scratch()
    assert_equal(find_repo(d + "/sub"), "")
    assert_equal(git(d, "init"), 0)
    assert_equal(find_repo(d + "/sub/deeper"), d)
    assert_equal(find_repo(d), d)
    _ = write_file(d + "/a.txt", str_bytes("one\ntwo\nthree\n"))
    _ = write_file(d + "/sub/deeper/b.txt", str_bytes("b\n"))
    assert_equal(git(d, "add -A"), 0)
    assert_equal(git(d, "commit -m first"), 0)
    _ = write_file(d + "/a.txt", str_bytes("one\n2\nthree\nfour\n"))
    _ = write_file(d + "/new.txt", str_bytes("n\n"))
    var r = run_capture(status_command(d))
    assert_equal(r.status, 0)
    var st = GitStatus()
    st.root = d
    st.parse(bytes_to_str(r.out))
    assert_equal(st.branch, "work")
    assert_equal(st.code_of(d + "/a.txt"), GS_MODIFIED)
    assert_equal(st.code_of(d + "/new.txt"), GS_UNTRACKED)
    assert_equal(st.code_of(d + "/sub/deeper/b.txt"), GS_NONE)
    assert_equal(st.code_of(d + "/sub"), GS_NONE)
    # the index's version of a file: what the markers compare with
    var b = run_capture(base_command(d, "a.txt"))
    assert_equal(b.status, 0)
    assert_equal(bytes_to_str(b.out), "one\ntwo\nthree\n")
    var marks = line_marks(diff_lines(text_hashes(decode(bytes_to_str(b.out))), hashes("one\n2\nthree\nfour\n")), 4)
    assert_equal(Int(marks[1]), LM_CHANGED)
    assert_equal(Int(marks[3]), LM_ADDED)
    # a file git does not have: the command fails (no markers)
    assert_true(run_capture(base_command(d, "new.txt") + " 2>/dev/null").status != 0)
    _ = run_system("rm -rf " + shell_quote(d))


# ------------------------------------------------------------ in the IDE
def git_idle(app: App) -> Bool:
    if app.git_proc.running or app.git_status_due:
        return False
    for w in app.wins:
        if w.kind == WK_EDITOR and (w.buf.git_state == GB_UNKNOWN or w.buf.git_state == GB_ASKED):
            return False
    return True


def pump(mut app: App) raises:
    """Run git's part of the event loop until it has nothing more to do."""
    app.git_checked_ns = 0          # look at the index now
    var end = now_ns() + 15000 * 1000000
    var first = True
    while now_ns() < end:
        app.git_tick(now_ns())
        if not first and git_idle(app):
            app.draw()
            return
        first = False
        var fds = List[Int]()
        if app.git_fd() >= 0:
            fds.append(app.git_fd())
            _ = wait_readable(fds, 50)
    assert_true(False, "git did not finish")


def gutter(app: App, i: Int, row: Int) -> String:
    """The gutter's marker column on a row of window i's text ('' if no column)."""
    var w = app.wins[i].copy()
    if w.buf.git_state != GB_KNOWN:
        return ""
    var y = w.y + 1 + row - w.top
    var x = w.x + w.gut - 1
    var line = to_str(app.scr.to_text()).split("\n")[y]
    var cps = decode(String(line))
    return to_str([cps[x]]) if x < len(cps) else String("")


def repo(tag: String) raises -> String:
    var d = scratch() + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d + "/sub"))
    assert_equal(git(d, "init"), 0)
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    print(1)\n    print(2)\n    print(3)\n"))
    _ = write_file(d + "/sub/b.txt", str_bytes("b\n"))
    assert_equal(git(d, "add -A"), 0)
    assert_equal(git(d, "commit -m first"), 0)
    return d


def test_gutter_shows_changes_since_the_index() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("gutter")
    # on disk: line 2 changed, one added at the end
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    print(10)\n    print(2)\n    print(3)\n    print(4)\n"))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    var i = app.find_editor(d + "/a.mojo")
    var gut_before = app.wins[i].gutter_for(True)
    pump(app)
    assert_equal(app.wins[i].buf.git_state, GB_KNOWN)
    assert_equal(app.wins[i].gutter_for(True), gut_before + 1)   # a column for the markers
    assert_equal(gutter(app, i, 0), " ")
    assert_equal(gutter(app, i, 1), "~")
    assert_equal(gutter(app, i, 2), " ")
    assert_equal(gutter(app, i, 4), "+")
    var c = app.git_counts(i)
    assert_equal(c[0], 1)
    assert_equal(c[1], 1)
    # an edit shows at once (the markers follow the text, not the file on disk)
    app.wins[i].cr = 2
    app.handle(key_event(KEY_END))
    app.handle(key_event(KEY_ENTER))
    for ch in decode("x = 1"):
        app.handle(key_event(ch))
    app.draw()
    assert_equal(gutter(app, i, 3), "+")
    assert_equal(gutter(app, i, 5), "+")
    # removing a line of the index's version
    app.wins[i].buf.load(decode("def main():\n    print(1)\n    print(3)\n"))
    app.draw()
    assert_equal(gutter(app, i, 2), "‾")
    # what is on disk goes into the index (as `git add` in a terminal would): asked again
    app.wins[i].buf.load(decode(bytes_to_str(read_file(d + "/a.mojo"))))
    assert_equal(git(d, "add a.mojo"), 0)
    pump(app)
    assert_equal(app.wins[i].buf.git_state, GB_KNOWN)
    c = app.git_counts(i)
    assert_equal(c[0] + c[1] + c[2], 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_files_outside_git_have_no_markers() raises:
    var d = scratch() + "-plain"
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/x.mojo", str_bytes("def main():\n    pass\n"))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/x.mojo")
    var i = app.find_editor(d + "/x.mojo")
    var g = app.wins[i].gutter_for(True)
    pump(app)
    assert_equal(app.wins[i].buf.git_state, GB_NONE)
    assert_equal(app.wins[i].gutter_for(True), g)
    assert_equal(app.git.root, "")
    _ = run_system("rm -rf " + shell_quote(d))
    if which("git").byte_length() == 0:
        return
    # in a repository but not tracked: no markers either
    var r = repo("untracked")
    _ = write_file(r + "/new.mojo", str_bytes("def main():\n    pass\n"))
    app = App()
    app.scr.resize(100, 30)
    app.cwd = r
    app.open_path(r + "/new.mojo")
    i = app.find_editor(r + "/new.mojo")
    pump(app)
    assert_equal(app.wins[i].buf.git_state, GB_NONE)
    _ = run_system("rm -rf " + shell_quote(r))


def test_git_waits_for_folder_trust() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("trust")
    _ = write_file(d + "/a.mojo", str_bytes("changed\n"))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.trust_enforced = True          # (and nothing is trusted)
    app.open_path(d + "/a.mojo")
    app.exec(CM_EXPLORER)
    var i = app.find_editor(d + "/a.mojo")
    var xi = app.explorer_index()
    pump(app)
    assert_false(app.git_proc.running)
    assert_equal(app.wins[i].buf.git_state, GB_NONE)
    assert_equal(String(to_str(app.wins[xi].buf.line(1)).strip()), "a.mojo")
    assert_equal(app.wins[xi].title, "Files")
    # trusted: markers and colours come
    app.trust.add(d)
    pump(app)
    assert_equal(app.wins[i].buf.git_state, GB_KNOWN)
    assert_equal(String(to_str(app.wins[xi].buf.line(1)).strip()), "a.mojo  M")
    # and go when the trust is taken back
    _ = app.trust.remove(d)
    pump(app)
    assert_equal(app.wins[i].buf.git_state, GB_NONE)
    assert_equal(String(to_str(app.wins[xi].buf.line(1)).strip()), "a.mojo")
    _ = run_system("rm -rf " + shell_quote(d))


def test_explorer_shows_git_status() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("explorer")
    _ = write_file(d + "/sub/b.txt", str_bytes("b changed\n"))
    _ = write_file(d + "/new.txt", str_bytes("n\n"))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    app.exec(CM_EXPLORER)
    var xi = app.explorer_index()
    pump(app)
    var rows = List[String]()
    for r in range(app.wins[xi].buf.count()):
        rows.append(String(to_str(app.wins[xi].buf.line(r)).strip()))
    assert_equal(rows[0], "▸ sub  •")
    assert_equal(rows[1], "a.mojo")
    assert_equal(rows[2], "new.txt  U")
    assert_equal(app.wins[xi].git_rows[0], GS_MODIFIED)
    assert_equal(app.wins[xi].git_rows[2], GS_UNTRACKED)
    assert_equal(app.wins[xi].title, "Files (work)")
    # in a folder that is opened, the file itself
    app.ex.toggle(0)
    app.explorer_show()
    assert_equal(String(to_str(app.wins[xi].buf.line(1)).strip()), "b.txt  M")
    # committed: the marks go
    assert_equal(git(d, "add -A"), 0)
    assert_equal(git(d, "commit -m second"), 0)
    pump(app)
    for r in range(app.wins[xi].buf.count()):
        assert_equal(app.wins[xi].git_rows[r], GS_NONE)
    var screen = to_str(app.scr.to_text())
    assert_true(screen.find("Files (work)") > 0, screen)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
