"""Tests for side-by-side split diff view (`v` toggle) and Git merge-conflict navigator/actions."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from linediff import diff_lines, text_hashes
from gitdiff import Side, side_by_side, DR_HEADER, DR_SPLIT_CHG, DR_NEW
from app_gitdiff import find_conflict_blocks
from git import GB_KNOWN
from app import *
from appstate import App
from window import WK_DIFF
from commands import (
    CM_GIT_DIFF, CM_CONFLICT_NEXT, CM_CONFLICT_OURS, CM_CONFLICT_THEIRS, CM_CONFLICT_BOTH, CM_UNDO,
)
from term import key_event
from signals import own_pid
from util import decode, to_str, env_or, run_system, write_file, str_bytes, shell_quote


def test_side_by_side_diff_builder_and_toggle() raises:
    var old_txt = "alpha\nbeta\ngamma\ndelta\n"
    var new_txt = "alpha\nBETA_MOD\nEXTRA\ngamma\ndelta\n"
    var old_s = Side.of(old_txt)
    var new_s = Side.of(new_txt)
    var hunks = diff_lines(text_hashes(decode(old_txt)), text_hashes(decode(new_txt)))
    var rows = side_by_side(old_s, new_s, hunks, 90)
    assert_true(len(rows) >= 4)
    assert_equal(rows[0].kind, DR_HEADER)
    assert_true(rows[0].text.find("[split]") > 0)
    var saw_paired = False
    var saw_added = False
    for r in rows:
        if r.kind == DR_SPLIT_CHG and r.text.find(" │ ") > 0:
            saw_paired = True
        if r.kind == DR_NEW and r.text.find("EXTRA") > 0:
            saw_added = True
    assert_true(saw_paired and saw_added)

    # Toggle `v` inside live WK_DIFF window
    var d = env_or("TMPDIR", "/tmp") + "/tm-sbs-" + String(own_pid())
    _ = run_system(
        "rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d)
        + " && cd " + shell_quote(d) + " && git init -q && git config user.email t@t && git config user.name t"
    )
    var f = d + "/main.mojo"
    _ = write_file(f, str_bytes("var a = 1\nvar b = 2\n"))
    _ = run_system("cd " + shell_quote(d) + " && git add main.mojo && git commit -qm init")

    var app = App()
    app.scr.resize(110, 30)
    app.cwd = d
    app.project_dir = d
    app.git_ok = True
    app.open_path(f)
    var ei = app.find_editor(f)
    app.wins[ei].buf.load(decode("var a = 1\nvar b = 99\n"))
    app.wins[ei].buf.git_state = GB_KNOWN
    app.wins[ei].buf.git_base_text = "var a = 1\nvar b = 2\n"
    app.wins[ei].buf.git_base = text_hashes(decode("var a = 1\nvar b = 2\n"))

    app.exec(CM_GIT_DIFF)
    var di = app.gd_index()
    assert_true(di >= 0 and app.wins[app.top()].kind == WK_DIFF)
    assert_false(app.gd_side_by_side)
    app.handle(key_event(118))  # 'v' toggles side-by-side split view
    assert_true(app.gd_side_by_side)
    assert_true(app.wins[di].title.find("[split]") >= 0)
    assert_true(to_str(app.wins[di].buf.line(1)).find(" │ ") > 0)
    app.handle(key_event(118))  # 'v' back to unified
    assert_false(app.gd_side_by_side)

    _ = run_system("rm -rf " + shell_quote(d))


def test_merge_conflict_navigator_and_resolutions_2way_and_diff3() raises:
    var d = env_or("TMPDIR", "/tmp") + "/tm-conf-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var f = d + "/conf.mojo"
    var content = (
        "var top = 0\n"
        "<<<<<<< HEAD\n"
        "var x = 10\n"
        "||||||| base\n"
        "var x = 1\n"
        "=======\n"
        "var x = 20\n"
        ">>>>>>> feature\n"
        "var mid = 5\n"
        "<<<<<<< HEAD\n"
        "var y = 1\n"
        "=======\n"
        "var y = 2\n"
        ">>>>>>> feature\n"
    )
    _ = write_file(f, str_bytes(content))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.open_path(f)
    var ei = app.find_editor(f)

    var blocks = find_conflict_blocks(app.wins[ei].buf)
    assert_equal(len(blocks), 2)
    assert_equal(blocks[0].anc_row, 3)  # diff3 `|||||||` marker parsed cleanly!

    # Jump to first conflict and Accept Ours (ignores diff3 base section!)
    app.wins[ei].goto(0, 0)
    app.exec(CM_CONFLICT_NEXT)
    assert_equal(app.wins[ei].cr, 1)
    app.exec(CM_CONFLICT_OURS)
    assert_equal(to_str(app.wins[ei].buf.line(1)), "var x = 10")
    assert_equal(len(find_conflict_blocks(app.wins[ei].buf)), 1)

    # Undo restores the entire conflict block in 1 step; then test Accept Theirs
    app.exec(CM_UNDO)
    assert_equal(len(find_conflict_blocks(app.wins[ei].buf)), 2)
    app.wins[ei].goto(1, 0)
    app.exec(CM_CONFLICT_THEIRS)
    assert_equal(to_str(app.wins[ei].buf.line(1)), "var x = 20")

    # Jump to remaining conflict and Accept Both
    app.exec(CM_CONFLICT_NEXT)
    app.exec(CM_CONFLICT_BOTH)
    assert_equal(len(find_conflict_blocks(app.wins[ei].buf)), 0)
    var final_txt = to_str(app.wins[ei].buf.all_text())
    assert_true(final_txt.find("var y = 1\nvar y = 2\n") >= 0, final_txt)

    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
