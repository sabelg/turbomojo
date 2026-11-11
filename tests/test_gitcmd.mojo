"""Tests for commit, branch and blame (src/git.mojo, src/app_gitcmd.mojo): the parsers
on what a real git prints, and the dialogs and the blame window in the IDE against real
repositories in $TMPDIR."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from git import *
from term import wait_readable, key_event, KEY_ENTER, KEY_ESC, KEY_TAB
from app import *
from appstate import App, now_ns, M_NORMAL, M_DIALOG
from dialog import D_GIT_COMMIT, D_GIT_BRANCH, D_INFO
from window import WK_EDITOR, WK_BLAME
from commands import CM_GIT_COMMIT, CM_GIT_BRANCH, CM_GIT_BLAME
from signals import own_pid
from util import (
    env_or, run_system, run_capture, bytes_to_str, write_file, str_bytes, shell_quote, which,
    decode, to_str, read_file, path_exists,
)


def test_dates() raises:
    assert_equal(ymd(0), "1970-01-01")
    assert_equal(ymd(951782400), "2000-02-29")
    assert_equal(ymd(1762819200), "2025-11-11")
    assert_equal(ymd(1704067199), "2023-12-31")


def test_branch_names() raises:
    assert_equal(branch_name_problem("feature/x-1"), "")
    assert_true(branch_name_problem("") != "")
    assert_true(branch_name_problem("a b") != "")
    assert_true(branch_name_problem("-x") != "")
    assert_true(branch_name_problem("a..b") != "")
    assert_true(branch_name_problem("x.lock") != "")
    assert_true(branch_name_problem("what?") != "")
    var b = parse_branches("*main\n feature/x\n old\n")
    assert_equal(len(b[0]), 3)
    assert_equal(b[1], "main")
    assert_equal(b[0][1], "feature/x")


def test_commit_message() raises:
    assert_equal(commit_message("  Fix it ", ""), "Fix it\n")
    assert_equal(commit_message("Fix it", " why \n"), "Fix it\n\nwhy\n")


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-gitcmd-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def git(d: String, args: String) -> Int:
    return run_system("git -C " + shell_quote(d) + " -c user.name=Ada -c user.email=a@a -c init.defaultBranch=work " + args + " >/dev/null 2>&1")


def git_out(d: String, args: String) -> String:
    return String(bytes_to_str(run_capture("git -C " + shell_quote(d) + " " + args + " 2>/dev/null").out).strip())


def repo(tag: String) raises -> String:
    var d = scratch(tag)
    assert_equal(git(d, "init"), 0)
    # who commits in the IDE's tests (git commit there uses the repository's settings)
    assert_equal(git(d, "config user.name Ada"), 0)
    assert_equal(git(d, "config user.email a@a"), 0)
    _ = write_file(d + "/a.mojo", str_bytes("one\ntwo\nthree\n"))
    assert_equal(git(d, "add -A"), 0)
    assert_equal(git(d, "commit -m first"), 0)
    return d


def test_parsers_on_real_output() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("parse")
    _ = write_file(d + "/a.mojo", str_bytes("one\nTWO\nthree\n"))
    assert_equal(run_system("git -C " + shell_quote(d) + " -c user.name=Bob -c user.email=b@b commit -qam 'second: two' >/dev/null"), 0)
    _ = write_file(d + "/edit", str_bytes("zero\none\nTWO\nthree\n"))
    var r = run_capture(blame_script(d, "a.mojo", d + "/edit"))
    assert_equal(r.status, 0)
    assert_false(path_exists(d + "/edit"))          # the text file is removed
    var b = parse_blame(bytes_to_str(r.out))
    assert_equal(len(b), 4)
    assert_true(is_uncommitted(b[0].sha))
    assert_equal(b[0].line, "zero")
    assert_equal(b[1].author, "Ada")
    assert_equal(b[1].summary, "first")
    assert_equal(b[2].author, "Bob")
    assert_equal(b[2].summary, "second: two")
    assert_equal(b[2].line, "TWO")
    assert_true(b[2].time > 1700000000)
    var br = parse_branches(bytes_to_str(run_capture(branches_command(d)).out))
    assert_equal(br[1], "work")
    # staged files in the status
    _ = write_file(d + "/b.mojo", str_bytes("b\n"))
    assert_equal(git(d, "add b.mojo"), 0)
    _ = write_file(d + "/a.mojo", str_bytes("changed, not staged\n"))
    var st = GitStatus()
    st.root = d
    st.parse(bytes_to_str(run_capture(status_command(d)).out))
    assert_equal(len(st.staged), 1)
    assert_equal(st.staged[0], d + "/b.mojo")
    _ = run_system("rm -rf " + shell_quote(d))


# ------------------------------------------------------------ in the IDE
def idle(app: App) -> Bool:
    if app.git_proc.running or app.git_status_due or len(app.git_q_req) > 0:
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
        if not first and idle(app):
            app.draw()
            return
        first = False
        var fds = List[Int]()
        if app.git_fd() >= 0:
            fds.append(app.git_fd())
            _ = wait_readable(fds, 50)
    assert_true(False, "git did not finish")


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    pump(app)
    return app^


def type_text(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))


def test_commit_dialog() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("commit")
    _ = write_file(d + "/a.mojo", str_bytes("one\ntwo\nthree\nfour\n"))
    assert_equal(git(d, "add a.mojo"), 0)
    var app = ide(d)
    app.exec(CM_GIT_COMMIT)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_GIT_COMMIT)
    assert_equal(app.dlg.title, "Commit on work")
    assert_equal(app.dlg.lines[0], "1 file staged: a.mojo")
    assert_false(app.dlg.check_vals[1])               # something is staged: not "all"
    type_text(app, "Add four")
    app.handle(key_event(KEY_TAB))
    type_text(app, "Because three was lonely.")
    app.handle(key_event(KEY_ENTER))
    pump(app)
    assert_equal(git_out(d, "log -1 --format=%s"), "Add four")
    assert_equal(git_out(d, "log -1 --format=%b"), "Because three was lonely.")
    assert_equal(git_out(d, "status --porcelain"), "")
    # nothing to commit: git's own words are shown
    app.exec(CM_GIT_COMMIT)
    assert_true(app.dlg.lines[0].startswith("Nothing is staged"))
    assert_true(app.dlg.check_vals[1])                # then "all" is ticked
    type_text(app, "Empty")
    app.handle(key_event(KEY_ENTER))
    pump(app)
    assert_equal(app.dlg.kind, D_INFO)
    assert_equal(app.dlg.lines[0], "git did not commit:")
    var said = String("")
    for l in app.dlg.lines:
        said += l + "\n"
    assert_true(said.find("nothing to commit") >= 0)
    app.handle(key_event(KEY_ENTER))
    # no summary: refused (unless amending, which keeps the message)
    _ = write_file(d + "/a.mojo", str_bytes("one\n"))
    app.exec(CM_GIT_COMMIT)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(git_out(d, "log -1 --format=%s"), "Add four")
    app.exec(CM_GIT_COMMIT)
    app.dlg.check_vals[0] = True                      # amend
    app.dlg.check_vals[1] = True                      # with every change
    app.handle(key_event(KEY_ENTER))
    pump(app)
    assert_equal(git_out(d, "log -1 --format=%s"), "Add four")
    assert_equal(git_out(d, "rev-list --count HEAD"), "2")
    assert_equal(git_out(d, "show HEAD:a.mojo"), "one")
    _ = run_system("rm -rf " + shell_quote(d))


def test_branch_dialog() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("branch")
    var app = ide(d)
    app.exec(CM_GIT_BRANCH)
    pump(app)
    assert_equal(app.dlg.kind, D_GIT_BRANCH)
    assert_equal(app.dlg.items[0], "* work")
    # a name no branch has: a new branch
    type_text(app, "feature/x")
    app.handle(key_event(KEY_ENTER))
    pump(app)
    assert_equal(git_out(d, "branch --show-current"), "feature/x")
    assert_equal(app.git.branch, "feature/x")
    # back, by choosing it from the list
    app.exec(CM_GIT_BRANCH)
    pump(app)
    type_text(app, "wor")
    assert_equal(app.dlg.items[app.dlg.selected_item()], "  work")
    app.handle(key_event(KEY_ENTER))
    pump(app)
    assert_equal(git_out(d, "branch --show-current"), "work")
    # a name git cannot take: nothing happens
    app.exec(CM_GIT_BRANCH)
    pump(app)
    type_text(app, "a b")
    app.handle(key_event(KEY_ENTER))
    pump(app)
    assert_equal(git_out(d, "branch --show-current"), "work")
    # a switch git refuses (a change that the other branch would overwrite)
    assert_equal(git(d, "switch -q -c other"), 0)
    _ = write_file(d + "/a.mojo", str_bytes("other\n"))
    assert_equal(git(d, "commit -qam other"), 0)
    assert_equal(git(d, "switch -q work"), 0)
    _ = write_file(d + "/a.mojo", str_bytes("local change\n"))
    app.exec(CM_GIT_BRANCH)
    pump(app)
    type_text(app, "other")
    app.handle(key_event(KEY_ENTER))
    pump(app)
    assert_equal(app.dlg.kind, D_INFO)
    assert_equal(app.dlg.lines[0], "git did not switch to other:")
    assert_equal(git_out(d, "branch --show-current"), "work")
    _ = run_system("rm -rf " + shell_quote(d))


def test_blame_window() raises:
    if which("git").byte_length() == 0:
        return
    var d = repo("blame")
    _ = write_file(d + "/a.mojo", str_bytes("one\nTWO\nthree\n"))
    assert_equal(run_system("git -C " + shell_quote(d) + " -c user.name=Bob -c user.email=b@b commit -qam 'Shout two' >/dev/null"), 0)
    var app = ide(d)
    var ei = app.find_editor(d + "/a.mojo")
    app.wins[ei].buf.load(decode("one\nTWO\nnew line\nthree\n"))     # not saved
    app.wins[ei].cr = 1
    app.exec(CM_GIT_BLAME)
    pump(app)
    var bi = app.blame_index()
    assert_true(bi >= 0)
    assert_equal(app.top(), bi)
    assert_equal(app.wins[bi].title, "Blame: a.mojo")
    assert_equal(app.wins[bi].cr, 1)                     # where the editor's cursor was
    var rows = List[String]()
    for r in range(app.wins[bi].buf.count()):
        rows.append(to_str(app.wins[bi].buf.line(r)))
    assert_equal(len(rows), 4)
    assert_true(rows[0].find(" Ada ") > 0 and rows[0].endswith("│ one"))
    assert_true(rows[1].find(" Bob ") > 0 and rows[1].endswith("│ TWO"))
    assert_true(rows[2].startswith("(not committed)") and rows[2].endswith("│ new line"))
    assert_equal(String(app.git_blame_summary()[byte=8:]), "Shout two")
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("Shout two") > 0)
    # Enter: to that line in the editor
    app.wins[bi].cr = 2
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    assert_equal(app.wins[app.top()].cr, 2)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
