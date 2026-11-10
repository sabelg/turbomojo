"""The Outline window: scanning a file for its symbols, reading the language server's
documentSymbol answer, and the window itself (fake server, and the real mojo-lsp-server
when it is on PATH)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from outline import *
from buffer import TextBuffer
from json import json_parse
from lsp import *
from term import wait_readable, fkey, key_event, MOD_CTRL, KEY_ENTER, KEY_UP, KEY_DOWN, KEY_END
from app import *
from appstate import App, now_ns, M_NORMAL
from window import WK_OUTLINE, WK_EDITOR
from commands import CM_OUTLINE, CM_LSP, CM_NEW, CM_BACK, build_registry
from signals import own_pid
from util import decode, to_str, env_or, run_system, which

comptime FAKE = "python3 tests/helpers/fake_rpc_server.py"
comptime MS = 1000000


def now() -> Int:
    return Int(perf_counter_ns())


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-outline-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def buffer_of(text: String) -> TextBuffer:
    var b = TextBuffer()
    b.load(decode(text))
    return b^


def listed(items: List[OutlineItem]) -> String:
    """Items as "depth:kind:name@row:col" joined by spaces."""
    var s = String("")
    for it in items:
        if s.byte_length() > 0:
            s += " "
        s += String(it.depth) + ":" + String(it.kind) + ":" + it.name + "@" + String(it.row) + ":" + String(it.col)
    return s


def shown(app: App) -> String:
    """The Outline window's lines joined with " | "."""
    var oi = app.outline_index()
    if oi < 0:
        return "(no Outline window)"
    var s = String("")
    for r in range(app.wins[oi].buf.count()):
        if r > 0:
            s += " | "
        s += to_str(app.wins[oi].buf.line(r))
    return s


def settle(mut app: App):
    """Run the event loop's ticks until the outline matches the text in front."""
    var t0 = now()
    while now() - t0 < 5000 * MS:
        var fds = List[Int]()
        if app.lsp.fd() >= 0:
            fds.append(app.lsp.fd())
        _ = wait_readable(fds, 20)
        app.lsp_tick(now_ns())
        app.outline_tick(now_ns())
        var ti = app.top_editor()
        if ti < 0 or not app.lsp.active():
            return
        if app.lsp.state != LSP_READY:
            continue
        if app.outline_req_id < 0 and app.outline_asked_version == app.wins[ti].buf.version and app.wins[ti].lsp_sent_version == app.wins[ti].buf.version:
            return


# -------------------------------------------------------------- the scanner
def test_scan_finds_definitions_and_their_nesting() raises:
    var b = buffer_of("comptime LIMIT = 3\nalias Row = List[Int]\n\nstruct Point:\n    var x: Int\n\n    def __init__(out self):\n        self.x = 0\n\n    def norm(self) -> Int:\n        def helper():\n            pass\n        return 1\n\ntrait Shape:\n    def area(self) -> Int: ...\n\ndef main():\n    comptime inner = 1\n    pass\nfn old_style():\n    pass\n")
    assert_equal(listed(scan_outline(b)), "0:14:LIMIT@0:9 0:14:Row@1:6 0:23:Point@3:7 1:6:__init__@6:8 1:6:norm@9:8 2:12:helper@10:12 0:11:Shape@14:6 1:6:area@15:8 0:12:main@17:4 0:12:old_style@20:3")


def test_scan_ignores_comments_docstrings_and_lookalikes() raises:
    var b = buffer_of("# def commented():\ndef real():\n    \"\"\"Explains.\n\n    def not_this():\n    struct Nor:\n    \"\"\"\n    x = \"def nor_that():\"\n    define = 1\n\ndef  spaced ():\n    '''one line''' \n    def inner(): pass\n\ndef (broken):\n    pass\ndefault = 2\n")
    assert_equal(listed(scan_outline(b)), "0:12:real@1:4 0:12:spaced@10:5 1:12:inner@12:8")
    assert_equal(len(scan_outline(buffer_of(""))), 0)
    assert_equal(len(scan_outline(buffer_of("x = 1\ny = 2\n"))), 0)
    # tabs indent too, and an item after a dedent leaves the nesting
    var t = buffer_of("struct A:\n\tdef m(self): pass\ndef f(): pass\n")
    assert_equal(listed(scan_outline(t)), "0:23:A@0:7 1:6:m@1:5 0:12:f@2:4")


# ---------------------------------------------------- the server's answer
def test_document_symbols_as_a_tree_and_as_a_flat_list() raises:
    var tree = parse_symbols(json_parse("[{\"name\": \"Point\", \"kind\": 23, \"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 5, \"character\": 0}}, \"selectionRange\": {\"start\": {\"line\": 0, \"character\": 7}, \"end\": {\"line\": 0, \"character\": 12}}, \"children\": [{\"name\": \"x\", \"kind\": 8, \"range\": {\"start\": {\"line\": 1, \"character\": 4}}, \"selectionRange\": {\"start\": {\"line\": 1, \"character\": 8}}}, {\"name\": \"norm\", \"kind\": 6, \"range\": {\"start\": {\"line\": 3, \"character\": 4}}, \"children\": [{\"name\": \"deep\", \"kind\": 13, \"selectionRange\": {\"start\": {\"line\": 4, \"character\": 12}}}]}]}, {\"name\": \"main\", \"kind\": 12, \"selectionRange\": {\"start\": {\"line\": 7, \"character\": 4}}}, {\"kind\": 12}, {\"name\": \"nowhere\", \"kind\": 12}]"), 0)
    # the name's own position where given, else the start of the whole; items without a
    # name or a place are left out
    assert_equal(listed(tree), "0:23:Point@0:7 1:8:x@1:8 1:6:norm@3:4 2:13:deep@4:12 0:12:main@7:4")
    var flat = parse_symbols(json_parse("[{\"name\": \"main\", \"kind\": 12, \"location\": {\"uri\": \"file:///a\", \"range\": {\"start\": {\"line\": 7, \"character\": 4}}}}, {\"name\": \"norm\", \"kind\": 6, \"containerName\": \"Point\", \"location\": {\"uri\": \"file:///a\", \"range\": {\"start\": {\"line\": 3, \"character\": 8}}}}, {\"name\": \"Point\", \"kind\": 23, \"location\": {\"uri\": \"file:///a\", \"range\": {\"start\": {\"line\": 0, \"character\": 7}}}}]"), 0)
    # put in file order; a named container means one level in
    assert_equal(listed(flat), "0:23:Point@0:7 1:6:norm@3:8 0:12:main@7:4")
    assert_equal(len(parse_symbols(json_parse("null"), 0)), 0)
    assert_equal(len(parse_symbols(json_parse("[]"), 0)), 0)


def test_outline_lines_and_the_current_item() raises:
    assert_equal(outline_line(OutlineItem("main", SK_FUNCTION, 0, 0, 0)), "ƒ main")
    assert_equal(outline_line(OutlineItem("norm", SK_METHOD, 0, 0, 1)), "  ƒ norm")
    assert_equal(outline_line(OutlineItem("Point", SK_STRUCT, 0, 0, 0)), "◆ Point")
    assert_equal(outline_line(OutlineItem("Shape", SK_INTERFACE, 0, 0, 0)), "◇ Shape")
    assert_equal(outline_line(OutlineItem("LIMIT", SK_CONSTANT, 0, 0, 0)), "= LIMIT")
    assert_equal(outline_line(OutlineItem("x", SK_FIELD, 0, 0, 2)), "    · x")
    assert_equal(outline_line(OutlineItem("odd", 99, 0, 0, 0)), "• odd")
    var items = scan_outline(buffer_of("x = 1\ndef a():\n    pass\nstruct S:\n    def m(self):\n        pass\n"))
    assert_equal(outline_current(items, 0), -1)          # above the first item
    assert_equal(outline_current(items, 1), 0)
    assert_equal(outline_current(items, 2), 0)
    assert_equal(outline_current(items, 3), 1)
    assert_equal(outline_current(items, 5), 2)
    assert_equal(outline_current(items, 500), 2)


# --------------------------------------------------------------- the window
comptime BODY = "comptime LIMIT = 3\n\nstruct Point:\n    var x: Int\n\n    def norm(self) -> Int:\n        return 1\n\ndef main():\n    pass\n"


def outline_app(dir: String, body: String) raises -> App:
    with open(dir + "/a.mojo", "w") as f:
        f.write(body)
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(dir + "/a.mojo")
    return app^


def test_outline_window_without_a_server() raises:
    var dir = scratch("win1")
    var app = outline_app(dir, BODY)
    var path = dir + "/a.mojo"
    assert_equal(build_registry().find_key(fkey(12) | MOD_CTRL), CM_OUTLINE)
    assert_equal(app.wins[app.find_editor(path)].w, 100)
    app.handle(key_event(fkey(12) | MOD_CTRL))
    var oi = app.outline_index()
    assert_true(oi >= 0)
    assert_equal(shown(app), "= LIMIT | ◆ Point |   ƒ norm | ƒ main")
    # at the right edge; the editor made room and keeps the keyboard
    var ei = app.find_editor(path)
    assert_equal(app.wins[oi].x + app.wins[oi].w, 100)
    assert_equal(app.wins[ei].x + app.wins[ei].w, app.wins[oi].x)
    assert_equal(app.top(), ei)
    app.draw()
    var screen = to_str(app.scr.to_text())
    assert_true(screen.find(" Outline ") > 0)
    assert_true(screen.find("◆ Point") > 0)
    assert_true(screen.find("struct Point:") > 0)
    # the symbol the cursor is in is the marked line
    app.wins[ei].goto(6, 8)
    app.outline_tick(now_ns())
    assert_equal(app.wins[oi].cr, 2)
    app.wins[ei].goto(9, 0)
    app.outline_tick(now_ns())
    assert_equal(app.wins[oi].cr, 3)
    # typing a new function shows up
    app.wins[ei].goto(10, 0)
    for c in decode("def added(): pass"):
        app.handle(key_event(c))
    app.outline_tick(now_ns())
    assert_equal(shown(app), "= LIMIT | ◆ Point |   ƒ norm | ƒ main | ƒ added")
    # Enter in the Outline window goes to the symbol and hands the keyboard back
    app.focus(app.outline_index())
    assert_equal(app.wins[app.top()].kind, WK_OUTLINE)
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_UP))
    assert_equal(app.wins[app.top()].cr, 1)
    app.handle(key_event(KEY_ENTER))
    var t = app.top()
    assert_equal(app.wins[t].kind, WK_EDITOR)
    assert_equal(app.wins[t].cr, 2)
    assert_equal(app.wins[t].cc, 7)                      # on the name
    assert_equal(app.status, "Point")
    app.exec(CM_BACK)                                    # it was a jump
    assert_equal(app.wins[app.top()].cr, 10)
    # typing in the Outline window does not change it or the file
    var before = to_str(app.wins[app.find_editor(path)].buf.line(0))
    app.focus(app.outline_index())
    app.handle(key_event(120))
    assert_equal(shown(app), "= LIMIT | ◆ Point |   ƒ norm | ƒ main | ƒ added")
    assert_equal(to_str(app.wins[app.find_editor(path)].buf.line(0)), before)
    app.focus(app.find_editor(path))
    # the same command closes it; the editor gets its width back
    app.exec(CM_OUTLINE)
    assert_equal(app.outline_index(), -1)
    assert_equal(app.wins[app.find_editor(path)].w, 100)
    _ = run_system("rm -rf '" + dir + "'")


def test_outline_follows_the_window_in_front() raises:
    var dir = scratch("win2")
    var app = outline_app(dir, BODY)
    with open(dir + "/b.mojo", "w") as f:
        f.write("def other():\n    pass\n")
    app.exec(CM_OUTLINE)
    assert_equal(shown(app), "= LIMIT | ◆ Point |   ƒ norm | ƒ main")
    # another file opened while the outline shows: beside it, and listed
    app.open_path(dir + "/b.mojo")
    app.outline_tick(now_ns())
    var bi = app.find_editor(dir + "/b.mojo")
    var oi = app.outline_index()
    assert_true(app.wins[bi].x + app.wins[bi].w <= app.wins[oi].x, "the new window does not cover the outline")
    assert_equal(shown(app), "ƒ other")
    app.focus(app.find_editor(dir + "/a.mojo"))
    app.outline_tick(now_ns())
    assert_equal(shown(app), "= LIMIT | ◆ Point |   ƒ norm | ƒ main")
    # a new, empty file
    app.exec(CM_NEW)
    app.outline_tick(now_ns())
    assert_equal(shown(app), "(no symbols)")
    app.handle(key_event(KEY_ENTER))                     # nothing to go to: just a new line in the editor
    for c in decode("def fresh(): pass"):
        app.handle(key_event(c))
    app.outline_tick(now_ns())
    assert_equal(shown(app), "ƒ fresh")
    _ = run_system("rm -rf '" + dir + "'")


def test_outline_from_the_language_server() raises:
    var dir = scratch("srv1")
    var app = outline_app(dir, "\"\U0001F600\"; var count = 1\nstruct Point:\n    var x: Int\n    def norm(self): pass\ndef main(): pass\n")
    var path = dir + "/a.mojo"
    app.lsp_server = FAKE
    app.exec(CM_LSP)
    app.exec(CM_OUTLINE)
    # at once: what the scan finds (it does not list variables and fields)
    assert_equal(shown(app), "◆ Point |   ƒ norm | ƒ main")
    settle(app)
    # then the server's list, which knows more
    assert_equal(shown(app), "= count | ◆ Point |   · x |   ƒ norm | ƒ main")
    assert_true(app.outline_from_server)
    # the server's column counts UTF-16 units: after the emoji it is one less in characters
    app.focus(app.outline_index())
    app.wins[app.top()].cr = 0
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.wins[app.top()].cr, 0)
    assert_equal(app.wins[app.top()].cc, 9)              # the server said 10
    # an edit: asked again, and the new symbol appears
    var ei = app.find_editor(path)
    app.wins[ei].goto(4, 16)
    app.handle(key_event(KEY_ENTER))
    for c in decode("def late(): pass"):
        app.handle(key_event(c))
    settle(app)
    assert_equal(shown(app), "= count | ◆ Point |   · x |   ƒ norm | ƒ main | ƒ late")
    app.lsp_stop()
    # without the server the scan takes over again on the next change
    app.handle(key_event(32))
    app.outline_tick(now_ns())
    assert_equal(shown(app), "◆ Point |   ƒ norm | ƒ main | ƒ late")
    _ = run_system("rm -rf '" + dir + "'")


def test_outline_keeps_the_scan_when_the_server_has_nothing() raises:
    var dir = scratch("srv2")
    var app = outline_app(dir, "# NOSYMBOLS\ndef only(): pass\n")
    app.lsp_server = FAKE
    app.exec(CM_LSP)
    app.exec(CM_OUTLINE)
    settle(app)
    assert_equal(shown(app), "ƒ only")
    assert_false(app.outline_from_server)
    app.lsp_stop()
    # a flat answer, out of order
    var dir2 = scratch("srv3")
    var app2 = outline_app(dir2, "# FLATSYMBOLS\nstruct Box:\n    def open(self): pass\ndef main(): pass\n")
    app2.lsp_server = FAKE
    app2.exec(CM_LSP)
    app2.exec(CM_OUTLINE)
    settle(app2)
    assert_true(app2.outline_from_server)
    assert_equal(shown(app2), "◆ Box |   ƒ open | ƒ main")
    app2.lsp_stop()
    _ = run_system("rm -rf '" + dir + "' '" + dir2 + "'")


def test_real_server_outline() raises:
    if which("mojo-lsp-server").byte_length() == 0:
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("real")
    var app = outline_app(dir, "struct Point:\n    var x: Int\n\n    def norm(self) -> Int:\n        return self.x\n\ndef twice(n: Int) -> Int:\n    return n * 2\n\ndef main():\n    print(twice(4))\n")
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        _ = wait_readable([app.lsp.fd()], 50)
        app.lsp_tick(now_ns())
    app.exec(CM_OUTLINE)
    t0 = now()
    while not app.outline_from_server and now() - t0 < 8000 * MS:
        settle(app)
        app.outline_asked_version = -1                  # ask again: the server may still be reading
    print("      real server outline (" + ("from the server" if app.outline_from_server else "from the scan") + "): " + shown(app))
    assert_true(shown(app).find("Point") >= 0)
    assert_true(shown(app).find("twice") >= 0)
    assert_true(shown(app).find("main") >= 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
