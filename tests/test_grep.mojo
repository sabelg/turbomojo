"""Tests for Find in files: the incremental folder search (src/grep.mojo) and the
command, dialog and Message-window results in the app."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from grep import FileSearch, Hit, MAX_HITS, sort_names, is_binary
from search import make_search, Search
from app import *
from appstate import App, now_ns, M_NORMAL, M_DIALOG
from window import WK_EDITOR, WK_MESSAGE
from dialog import D_FINDFILES, D_INFO
from commands import CM_NEW, CM_FINDFILES, CM_CANCEL, CM_AGAIN, CM_NEXTERR, build_registry
from term import key_event, KEY_ENTER, KEY_ESC, KEY_DOWN, fkey, alt, MOD_SHIFT
from signals import own_pid
from util import decode, to_str, env_or, run_system, str_bytes


def tree(tag: String) raises -> String:
    """A small project folder with the things a search has to cope with."""
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-greptest-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "/src/deep' '" + d + "/.hidden' '" + d + "/out' '" + d + "/node_modules/pkg' '" + d + "/docs'")
    with open(d + "/main.mojo", "w") as f:
        f.write("def main():\n    needle = 1\n    print(needle)\n")
    with open(d + "/src/a.mojo", "w") as f:
        f.write("# no match here\n\tvar Needle = 2  # NEEDLE again\n")
    with open(d + "/src/deep/b.txt", "w") as f:
        f.write("first\r\nthe needle in a CRLF file\r\nlast without newline needle")
    with open(d + "/docs/readme.md", "w") as f:
        f.write("haystack only\n")
    with open(d + "/.hidden/x.txt", "w") as f:
        f.write("needle in a hidden folder\n")
    with open(d + "/.env", "w") as f:
        f.write("needle in a hidden file\n")
    with open(d + "/out/gen.txt", "w") as f:
        f.write("needle in an ignored folder\n")
    with open(d + "/node_modules/pkg/i.js", "w") as f:
        f.write("needle in node_modules\n")
    with open(d + "/debug.log", "w") as f:
        f.write("needle in an ignored extension\n")
    with open(d + "/keep.tmp", "w") as f:
        f.write("needle kept: the rule for it is too complex to be used\n")
    with open(d + "/.gitignore", "w") as f:
        f.write("# comment\nout/\n*.log\n\n!keep.log\nsrc/*.tmp\n")
    _ = run_system("printf 'needle\\000binary' > '" + d + "/blob.bin'")
    _ = run_system("printf 'caf\\351 needle\\n' > '" + d + "/latin1.txt'")       # not UTF-8
    _ = run_system("ln -s . '" + d + "/loop'")                                    # a folder link to itself
    _ = run_system("ln -s ../main.mojo '" + d + "/src/link.mojo'")                # a file link
    return d


def remove(d: String):
    _ = run_system("rm -rf '" + d + "'")


def run(root: String, s: Search) -> FileSearch:
    var fs = FileSearch()
    fs.start(root, s)
    var guard = 0
    while not fs.done() and guard < 100000:
        fs.step(1)
        guard += 1
    return fs^


def listing(fs: FileSearch) -> String:
    """Hits as "relative/path:row:col" separated by spaces."""
    var out = String("")
    var skip = fs.root.byte_length() + 1
    for i in range(len(fs.hits)):
        var p = fs.hits[i].path
        out += String(p[byte=skip:]) + ":" + String(fs.hits[i].row) + ":" + String(fs.hits[i].col) + " "
    return out


# ------------------------------------------------------------------ searcher
def test_finds_matches_in_order_and_skips_what_it_should() raises:
    var d = tree("basic")
    var fs = run(d, make_search(decode("needle"), True, False, False))
    var got = listing(fs)
    assert_true(got.find("main.mojo:2:5 main.mojo:3:11 ") >= 0, got)
    assert_true(got.find("src/deep/b.txt:2:5 src/deep/b.txt:3:22 ") >= 0, got)   # CRLF and no final newline
    assert_true(got.find("latin1.txt:1:6 ") >= 0, got)                           # invalid UTF-8 still searched
    assert_true(got.find("keep.tmp:1:1 ") >= 0, got)
    assert_true(got.find("src/link.mojo:2:5 ") >= 0, got)                        # a link to a file is a file
    assert_true(got.find("hidden") < 0 and got.find(".env") < 0, got)
    assert_true(got.find("out/") < 0 and got.find("node_modules") < 0 and got.find("debug.log") < 0, got)
    assert_true(got.find("blob.bin") < 0 and got.find("loop/") < 0, got)
    assert_true(got.find("src/a.mojo") < 0, got)                                 # case sensitive
    assert_equal(len(fs.hits), 8)
    assert_equal(fs.files_matched, 5)
    assert_equal(fs.files_skipped, 1)                                            # the binary file
    assert_equal(fs.files_done, 7)                                               # incl. readme.md and a.mojo
    assert_false(fs.truncated)
    assert_equal(fs.summary(), "8 matching lines in 5 files (7 searched, 1 binary or too large)")
    remove(d)


def test_order_is_files_first_then_subfolders_by_name() raises:
    var d = tree("order")
    var fs = run(d, make_search(decode("needle"), True, False, False))
    var got = listing(fs)
    var a = got.find("keep.tmp")
    var b = got.find("latin1.txt")
    var c = got.find("main.mojo:2")
    var e = got.find("src/link.mojo")
    var f = got.find("src/deep/b.txt")
    assert_true(a >= 0 and a < b and b < c and c < e and e < f, got)
    remove(d)


def test_hit_text_and_columns() raises:
    var d = tree("text")
    var fs = run(d, make_search(decode("needle"), False, False, False))
    var seen = False
    for i in range(len(fs.hits)):
        if fs.hits[i].path.endswith("src/a.mojo"):
            seen = True
            assert_equal(fs.hits[i].row, 2)
            assert_equal(fs.hits[i].col, 6)                        # after the tab: "var Needle"
            assert_equal(fs.hits[i].text, "var Needle = 2  # NEEDLE again")   # one hit per line
    assert_true(seen)
    assert_equal(len(fs.hits), 9)                                  # the eight, plus a.mojo
    remove(d)


def test_options_and_regex() raises:
    var d = tree("opts")
    var word = run(d, make_search(decode("need"), True, True, False))
    assert_equal(len(word.hits), 0)
    var rx = run(d, make_search(decode("^\\s+print\\((\\w+)\\)"), True, False, True))
    assert_equal(listing(rx), "main.mojo:3:1 src/link.mojo:3:1 ")
    var bad = FileSearch()
    bad.start(d, make_search(decode("(x"), True, False, True))
    assert_true(bad.done())                                        # nothing to do for a broken pattern
    assert_equal(len(bad.hits), 0)
    remove(d)


def test_search_proceeds_in_small_steps_and_can_be_cancelled() raises:
    var d = tree("steps")
    for i in range(40):
        with open(d + "/docs/n" + String(i) + ".txt", "w") as f:
            f.write("needle " + String(i) + "\n")
    var fs = FileSearch()
    fs.start(d, make_search(decode("needle"), True, False, False))
    fs.step(0)                                                     # one unit of work
    assert_false(fs.done())
    var steps = 1
    while not fs.done() and steps < 10:
        fs.step(0)
        steps += 1
    assert_false(fs.done(), "ten steps cannot cover fifty files")
    var so_far = len(fs.hits)
    fs.cancel()
    assert_true(fs.done())
    fs.step(5)
    assert_equal(len(fs.hits), so_far)                             # nothing more after cancelling
    assert_true(fs.summary().endswith(" - cancelled"), fs.summary())
    var full = run(d, make_search(decode("needle"), True, False, False))
    assert_equal(len(full.hits), 48)                               # 8 + 40
    remove(d)


def test_stops_at_the_hit_limit() raises:
    var d = tree("limit")
    _ = run_system("yes 'needle again' | head -n 6000 > '" + d + "/many.txt'")
    var fs = run(d, make_search(decode("needle again"), True, False, False))
    assert_equal(len(fs.hits), MAX_HITS)
    assert_true(fs.truncated)
    assert_true(fs.summary().endswith(" - stopped after 5000"), fs.summary())
    remove(d)


def test_large_files_are_skipped() raises:
    var d = tree("big")
    _ = run_system("yes 'needle filler line for a big file' | head -c 6000000 > '" + d + "/huge.txt'")
    var fs = run(d, make_search(decode("needle"), True, False, False))
    assert_true(listing(fs).find("huge.txt") < 0)
    assert_equal(fs.files_skipped, 2)
    remove(d)


def test_missing_folder_gives_no_hits() raises:
    var fs = run("/nonexistent/turbomojo/folder", make_search(decode("x"), True, False, False))
    assert_true(fs.done())
    assert_equal(len(fs.hits), 0)
    assert_equal(fs.summary(), "0 matching lines in 0 files (0 searched)")


def test_helpers() raises:
    var names: List[String] = ["b", "a", "C", "ab", "a"]
    sort_names(names)
    assert_equal(names[0], "C")
    assert_equal(names[1], "a")
    assert_equal(names[2], "a")
    assert_equal(names[3], "ab")
    assert_equal(names[4], "b")
    assert_false(is_binary(str_bytes("plain text")))
    var z: List[UInt8] = [65, 0, 66]
    assert_true(is_binary(z))


# ----------------------------------------------------------------------- app
def make(root: String) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = root
    app.exec(CM_NEW)
    return app^


def keys(mut app: App, s: String) raises:
    for c in decode(s):
        app.handle(key_event(c))


def finish(mut app: App):
    var guard = 0
    while app.fsearch.active and guard < 100000:
        app.fsearch_tick(now_ns() + guard * 1000000000)
        guard += 1


def msg(app: App) -> String:
    var mi = app.msg_index()
    return to_str(app.wins[mi].buf.all_text()) if mi >= 0 else String("(no message window)")


def test_command_has_a_key_and_a_menu_entry() raises:
    var r = build_registry()
    assert_equal(r.find_key(fkey(3) | MOD_SHIFT), CM_FINDFILES)


def test_find_in_files_fills_the_message_window() raises:
    var d = tree("app")
    var app = make(d)
    app.exec(CM_FINDFILES)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_FINDFILES)
    assert_equal(app.dlg.lines[0], "Folder: " + d)
    keys(app, "print")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_true(app.fsearch.active)
    assert_true(msg(app).startswith("Searching for \"print\" in " + d + " ..."), msg(app))
    # the loop is asked to come straight back while the search runs
    assert_equal(app.next_timeout_ms(now_ns(), False, 30), 1)
    finish(app)
    assert_false(app.fsearch.active)
    assert_equal(
        msg(app),
        "Search for \"print\" in " + d + "\nmain.mojo:3:5: print(needle)\nsrc/link.mojo:3:5: print(needle)\n2 matching lines in 2 files (7 searched, 1 binary or too large)",
    )
    assert_equal(app.status, "2 matching lines in 2 files (7 searched, 1 binary or too large)")
    # the Message window is in front with the cursor on the first hit
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_MESSAGE)
    assert_equal(app.wins[t].cr, 1)
    remove(d)


def test_enter_on_a_hit_opens_the_file_at_the_match() raises:
    var d = tree("jump")
    var app = make(d)
    app.exec(CM_FINDFILES)
    keys(app, "needle")
    app.handle(key_event(alt(105)))                 # case sensitive
    app.handle(key_event(KEY_ENTER))
    finish(app)
    var mi = app.top()
    assert_equal(app.wins[mi].kind, WK_MESSAGE)
    # third line of the list: main.mojo:2:5
    app.wins[mi].cr = 3
    assert_true(to_str(app.wins[mi].buf.line(3)).startswith("main.mojo:2:5: needle = 1"), to_str(app.wins[mi].buf.line(3)))
    app.handle(key_event(KEY_ENTER))
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_EDITOR)
    assert_equal(app.wins[t].path, d + "/main.mojo")
    assert_equal(to_str(app.wins[t].selected_text()), "needle")
    assert_equal(app.wins[t].cr, 1)
    assert_equal(app.wins[t].cc, 10)
    assert_true(app.wins[t].hs_on)                  # the other matches in the file are marked
    app.exec(CM_AGAIN)                              # Ctrl+L goes on inside this file
    assert_equal(app.wins[t].cr, 2)
    app.exec(CM_NEXTERR)                            # Alt-F8 walks the hit list
    var t2 = app.top()
    assert_equal(app.wins[t2].path, d + "/main.mojo")
    assert_equal(app.wins[t2].cr, 2)
    remove(d)


def test_no_match_and_bad_pattern() raises:
    var d = tree("none")
    var app = make(d)
    app.exec(CM_FINDFILES)
    keys(app, "zzzzzz")
    app.handle(key_event(KEY_ENTER))
    finish(app)
    assert_equal(app.status, "0 matching lines in 0 files (7 searched, 1 binary or too large)")
    assert_equal(len(app.errs), 0)
    app.exec(CM_FINDFILES)
    app.handle(key_event(alt(120)))                 # regular expression
    keys(app, "(")                                  # field still holds "zzzzzz"
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_INFO)
    assert_true(app.dlg.lines[0].startswith("Pattern error: "), app.dlg.lines[0])
    assert_false(app.fsearch.active)
    remove(d)


def test_cancel_stops_the_search_and_says_so() raises:
    var d = tree("cancel")
    for i in range(60):
        with open(d + "/docs/n" + String(i) + ".txt", "w") as f:
            f.write("needle " + String(i) + "\n")
    var app = make(d)
    app.exec(CM_FINDFILES)
    keys(app, "needle")
    app.handle(key_event(KEY_ENTER))
    assert_true(app.fsearch.active)
    app.exec(CM_CANCEL)
    assert_false(app.fsearch.active)
    assert_true(msg(app).endswith(" - cancelled"), msg(app))
    assert_true(app.status.endswith(" - cancelled"), app.status)
    remove(d)


def test_escape_in_the_dialog_starts_nothing() raises:
    var d = tree("esc")
    var app = make(d)
    app.exec(CM_FINDFILES)
    keys(app, "needle")
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    assert_false(app.fsearch.active)
    assert_equal(app.msg_index(), -1)
    remove(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
