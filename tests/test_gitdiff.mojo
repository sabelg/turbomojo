"""Tests for the diff view and the change commands (src/gitdiff.mojo,
src/app_gitdiff.mojo): the model on fixed and random texts (checked by `git apply`),
and staging, unstaging and reverting in the IDE against a real repository in $TMPDIR."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.random import random_ui64, seed
from linediff import *
from gitdiff import *
from git import *
from term import wait_readable, key_event, KEY_ENTER, KEY_ESC, KEY_TAB
from app import *
from appstate import App, now_ns
from window import WK_EDITOR, WK_DIFF
from commands import CM_GIT_DIFF, CM_GIT_STAGE, CM_GIT_REVERT, CM_GIT_NEXT, CM_GIT_PREV, CM_UNDO
from signals import own_pid
from util import (
    env_or, run_system, run_capture, bytes_to_str, write_file, str_bytes, shell_quote, which,
    decode, to_str, read_file,
)


def side(s: String) -> Side:
    return Side.of(s)


def test_sides() raises:
    assert_equal(len(side("a\nb\n").lines), 2)
    assert_true(side("a\nb\n").eol)
    assert_false(side("a\nb").eol)
    assert_equal(side("a\nb").text(), "a\nb")
    assert_equal(side("a\nb\n").text(), "a\nb\n")
    assert_equal(side("a\r\nb\r\n").lines[0], "a")
    assert_equal(len(side("").lines), 0)
    assert_equal(side("").text(), "")
    assert_equal(len(side("\n").lines), 1)        # one empty line
    assert_equal(side("\n").text(), "\n")
    # only the final line feed differs: the last line counts as changed
    var h = side_hunks(side("a\nb"), side("a\nb\n"))
    assert_equal(len(h), 1)
    assert_true(h[0] == Hunk(1, 1, 1, 1))


def test_unified_rows() raises:
    var old = side("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n")
    var new = side("1\n2\nthree\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n15\n16\nend\n")
    var h = side_hunks(old, new)
    assert_equal(len(h), 3)
    var rows = unified(old, new, h)
    var text = List[String]()
    for r in rows:
        text.append(r.text)
    assert_equal(text[0], "@@ -1,6 +1,6 @@")
    assert_equal(text[3], "-3")
    assert_equal(text[4], "+three")
    # the second and third changes are close: their context is not shown twice
    var seen_13 = 0
    for t in text:
        if t == " 13":
            seen_13 += 1
    assert_equal(seen_13, 1)
    # each row knows its change and the new side's line
    assert_equal(rows[4].hunk, 0)
    assert_equal(rows[4].new_line, 2)
    assert_equal(rows[len(rows) - 1].text, "+end")
    assert_equal(rows[len(rows) - 1].new_line, 15)
    assert_equal(len(unified(old, old, side_hunks(old, old))), 0)


def test_hunk_at_line() raises:
    var h = side_hunks(side("a\nb\nc\nd\n"), side("a\nB\nc\n"))
    # b -> B (line 1); d removed at the end (counts for the last line)
    assert_equal(hunk_at_line(h, 0), -1)
    assert_equal(hunk_at_line(h, 1), 0)
    assert_equal(hunk_at_line(h, 2), 1)
    assert_equal(hunk_at_line(h, 3), 1)


def random_text(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += String(Int(random_ui64(0, 6))) + "\n"
    return s^


def edited(text: String) -> String:
    var lines = List[String]()
    for l in Side.of(text).lines:
        lines.append(l)
    for _ in range(Int(random_ui64(1, 6))):
        var at = Int(random_ui64(0, UInt64(len(lines))))
        var op = random_ui64(0, 2)
        if op == 0:
            lines.insert(at, "n" + String(Int(random_ui64(0, 9))))
        elif at < len(lines):
            if op == 1:
                _ = lines.pop(at)
            else:
                lines[at] = "c" + lines[at]
    var s = String("")
    for l in lines:
        s += l + "\n"
    return s^


def test_staging_hunk_by_hunk_reaches_the_new_text() raises:
    seed(11)
    for trial in range(200):
        var old = side(random_text(Int(random_ui64(0, 25))))
        var new = side(edited(old.text()))
        var hunks = side_hunks(old, new)
        # staging every change, one after another (each time against the new index)
        var index = old.copy()
        for _ in range(len(hunks)):
            var hs = side_hunks(index, new)
            if len(hs) == 0:
                break
            index = with_hunk(index, new, hs[0])
        assert_equal(index.text(), new.text(), "stage, trial " + String(trial))
        # undoing every change from the new side (revert / unstage) reaches the old
        var back = new.copy()
        for _ in range(len(hunks) + 1):
            var hs = side_hunks(old, back)
            if len(hs) == 0:
                break
            back = without_hunk(old, back, hs[len(hs) - 1])
        assert_equal(back.text(), old.text(), "revert, trial " + String(trial))
        # staging one change leaves exactly the others
        if len(hunks) > 1:
            var one = with_hunk(old, new, hunks[0])
            assert_equal(len(side_hunks(one, new)), len(hunks) - 1, "trial " + String(trial))


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-gitdiff-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def git(d: String, args: String) -> Int:
    return run_system("git -C " + shell_quote(d) + " -c user.name=t -c user.email=t@t -c init.defaultBranch=work " + args + " >/dev/null 2>&1")


def git_out(d: String, args: String) -> String:
    return bytes_to_str(run_capture("git -C " + shell_quote(d) + " " + args + " 2>/dev/null").out)


def test_unified_output_is_a_patch_git_applies() raises:
    if which("git").byte_length() == 0:
        return
    seed(5)
    var d = scratch("apply")
    for trial in range(25):
        var old = side(random_text(Int(random_ui64(1, 30))))
        var new = side(edited(old.text()))
        var rows = unified(old, new, side_hunks(old, new))
        if len(rows) == 0:
            continue
        var patch = String("--- a/f\n+++ b/f\n")
        for r in rows:
            patch += r.text + "\n"
        _ = write_file(d + "/f", str_bytes(old.text()))
        _ = write_file(d + "/p", str_bytes(patch))
        assert_equal(run_system("cd " + shell_quote(d) + " && git apply --unidiff-zero p 2>&1 >/dev/null"), 0, "trial " + String(trial) + "\n" + patch)
        assert_equal(bytes_to_str(read_file(d + "/f")), new.text(), "trial " + String(trial))
    _ = run_system("rm -rf " + shell_quote(d))


# ------------------------------------------------------------ in the IDE
def git_idle(app: App) -> Bool:
    if app.git_proc.running or app.git_status_due or len(app.git_q_req) > 0:
        return False
    if app.gd_head_state == GB_ASKED:
        return False
    for w in app.wins:
        if w.kind == WK_EDITOR and (w.buf.git_state == GB_UNKNOWN or w.buf.git_state == GB_ASKED):
            return False
    return True


def pump(mut app: App) raises:
    app.git_checked_ns = 0
    var end = now_ns() + 15000 * 1000000
    var first = True
    while now_ns() < end:
        app.git_tick(now_ns())
        app.draw()
        if not first and git_idle(app):
            app.draw()
            return
        first = False
        var fds = List[Int]()
        if app.git_fd() >= 0:
            fds.append(app.git_fd())
            _ = wait_readable(fds, 50)
    assert_true(False, "git did not finish")


comptime BASE = "def main():\n    print(1)\n    print(2)\n    print(3)\n    print(4)\n    print(5)\n    print(6)\n    print(7)\n    print(8)\n    print(9)\n"
comptime EDITED = "def main():\n    print(10)\n    print(2)\n    print(3)\n    print(4)\n    print(5)\n    print(6)\n    print(7)\n    print(8)\n    print(90)\n"


def repo(tag: String) raises -> String:
    var d = scratch(tag)
    assert_equal(git(d, "init"), 0)
    _ = write_file(d + "/a.mojo", str_bytes(BASE))
    assert_equal(git(d, "add -A"), 0)
    assert_equal(git(d, "commit -m first"), 0)
    return d


def ide(d: String, path: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(path)
    pump(app)
    return app^


def shown(app: App) -> List[String]:
    var di = app.gd_index()
    var out = List[String]()
    for r in range(app.wins[di].buf.count()):
        out.append(to_str(app.wins[di].buf.line(r)))
    return out^


def find_row(app: App, text: String) -> Int:
    var rows = shown(app)
    for k in range(len(rows)):
        if rows[k] == text:
            return k
    return -1


def test_stage_and_unstage_one_change_in_the_diff_view() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("stage")
    var app = ide(d, d + "/a.mojo")
    var ei = app.find_editor(d + "/a.mojo")
    app.wins[ei].buf.load(decode(EDITED))         # two changes, far apart (not saved)
    app.exec(CM_GIT_DIFF)
    var di = app.gd_index()
    assert_true(di >= 0)
    assert_equal(app.top(), di)
    assert_equal(app.wins[di].title, "Changes: a.mojo")
    var rows = shown(app)
    assert_equal(rows[0], "@@ -1,5 +1,5 @@")
    assert_true(find_row(app, "-    print(1)") > 0)
    assert_true(find_row(app, "+    print(90)") > 0)
    # it starts on the first change; S stages that one only
    assert_equal(rows[app.wins[di].cr], "-    print(1)")
    app.handle(key_event(83))
    pump(app)
    var cached = git_out(d, "diff --cached")
    assert_true(cached.find("+    print(10)") > 0)
    assert_true(cached.find("print(90)") < 0)
    # the gutter and the view now show only the other change
    ei = app.find_editor(d + "/a.mojo")
    var c = app.git_counts(ei)
    assert_equal(c[1], 1)
    assert_equal(find_row(app, "+    print(10)"), -1)
    assert_true(find_row(app, "+    print(90)") > 0)
    # the file on disk was not touched (the buffer is not saved)
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")), BASE)
    # Tab: what is staged; U unstages it again
    app.handle(key_event(KEY_TAB))
    pump(app)
    di = app.gd_index()
    assert_equal(app.wins[di].title, "Staged: a.mojo")
    var r10 = find_row(app, "+    print(10)")
    assert_true(r10 > 0)
    assert_equal(find_row(app, "+    print(90)"), -1)
    app.wins[di].cr = r10
    app.handle(key_event(85))
    pump(app)
    assert_equal(git_out(d, "diff --cached"), "")
    assert_true(find_row(app, "(nothing staged)") == 0)
    # Esc closes the view
    app.handle(key_event(KEY_ESC))
    assert_equal(app.gd_index(), -1)
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    _ = run_system("rm -rf " + shell_quote(d))


def test_revert_and_navigate_from_the_editor() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("revert")
    var app = ide(d, d + "/a.mojo")
    var ei = app.find_editor(d + "/a.mojo")
    app.wins[ei].buf.load(decode(EDITED))
    app.wins[ei].cr = 5
    app.exec(CM_GIT_NEXT)
    assert_equal(app.wins[ei].cr, 9)
    app.exec(CM_GIT_NEXT)
    assert_equal(app.wins[ei].cr, 9)                # no more below
    app.exec(CM_GIT_PREV)
    assert_equal(app.wins[ei].cr, 1)
    # no change at the cursor: nothing happens
    app.wins[ei].cr = 4
    app.exec(CM_GIT_REVERT)
    assert_equal(to_str(app.wins[ei].buf.all_text()), EDITED)
    # revert the last change: that line is as in the index again, the other stays
    app.wins[ei].cr = 9
    app.exec(CM_GIT_REVERT)
    var t = to_str(app.wins[ei].buf.all_text())
    assert_true(t.find("print(90)") < 0)
    assert_true(t.find("print(9)\n") > 0)
    assert_true(t.find("print(10)") > 0)
    # one undo step brings it back
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[ei].buf.all_text()), EDITED)
    # Stage change from the editor, on the first change
    app.wins[ei].cr = 1
    app.exec(CM_GIT_STAGE)
    pump(app)
    assert_true(git_out(d, "diff --cached").find("+    print(10)") > 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_unstaging_a_new_files_only_change_removes_it_from_the_index() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("newfile")
    _ = write_file(d + "/new.mojo", str_bytes("def main():\n    pass\n"))
    assert_equal(git(d, "add new.mojo"), 0)
    var app = ide(d, d + "/new.mojo")
    app.exec(CM_GIT_DIFF)
    app.handle(key_event(KEY_TAB))
    pump(app)
    assert_true(find_row(app, "+def main():") > 0)
    app.wins[app.gd_index()].cr = find_row(app, "+def main():")
    app.handle(key_event(85))
    pump(app)
    assert_equal(git_out(d, "ls-files new.mojo"), "")
    assert_true(path_exists(d + "/new.mojo"))       # only out of the index
    _ = run_system("rm -rf " + shell_quote(d))


def test_enter_goes_to_the_line() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("enter")
    var app = ide(d, d + "/a.mojo")
    var ei = app.find_editor(d + "/a.mojo")
    app.wins[ei].buf.load(decode(EDITED))
    app.exec(CM_GIT_DIFF)
    var di = app.gd_index()
    app.wins[di].cr = find_row(app, "+    print(90)")
    app.handle(key_event(KEY_ENTER))
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_EDITOR)
    assert_equal(app.wins[t].cr, 9)
    # an untracked file: nothing to show, and the reason is said
    _ = write_file(d + "/u.mojo", str_bytes("x\n"))
    app.open_path(d + "/u.mojo")
    pump(app)
    var n = len(app.wins)
    app.exec(CM_GIT_DIFF)
    assert_equal(len(app.wins), n)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
