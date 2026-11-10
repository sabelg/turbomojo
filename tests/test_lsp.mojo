"""Tests for the language-server client (src/lsp.mojo) and its use in the IDE.

Three layers: pure functions; the client against tests/helpers/fake_rpc_server.py; and the
real mojo-lsp-server when it is on PATH (scripts/check.sh puts the pixi environment there).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from lsp import *
from rpc import *
from json import json_parse
from term import wait_readable
from app import *
from appstate import App, now_ns, M_NORMAL
from window import WK_MESSAGE
from commands import CM_LSP, CM_NONE, build_registry
from term import fkey
from signals import own_pid
from util import decode, to_str, str_bytes, bytes_to_str, env_or, run_system, run_capture, getcwd, toolchain_env, which

comptime FAKE = "python3 tests/helpers/fake_rpc_server.py"
comptime MS = 1000000


def now() -> Int:
    return Int(perf_counter_ns())


def pump(mut c: LspClient, timeout_ms: Int, until_ready: Bool, until_updates: Int) -> List[String]:
    """Poll the client until it is ready / has produced N diagnostic updates, or time out.
    Returns the URIs updated meanwhile."""
    var updates = List[String]()
    var deadline = now() + timeout_ms * MS
    while now() < deadline:
        var fds = List[Int]()
        fds.append(c.fd())
        _ = wait_readable(fds, 20)
        c.poll()
        for u in c.take_updated():
            updates.append(u)
        if c.state == LSP_FAILED:
            break
        if until_ready and c.state == LSP_READY and len(updates) >= until_updates:
            break
        if not until_ready and len(updates) >= until_updates:
            break
    return updates^


def have_real_server() -> Bool:
    return run_system("command -v mojo-lsp-server >/dev/null 2>&1") == 0


# ------------------------------------------------------------ pure helpers
def test_uri_conversion() raises:
    assert_equal(path_to_uri("/home/u/a.mojo"), "file:///home/u/a.mojo")
    assert_equal(path_to_uri("/p/with space/ü.mojo"), "file:///p/with%20space/%C3%BC.mojo")
    assert_equal(path_to_uri("/a/b#c?d"), "file:///a/b%23c%3Fd")
    assert_equal(uri_to_path("file:///home/u/a.mojo"), "/home/u/a.mojo")
    assert_equal(uri_to_path("file:///p/with%20space/%C3%BC.mojo"), "/p/with space/ü.mojo")
    assert_equal(uri_to_path("file:///a%2fb"), "/a/b")              # lower-case hex accepted
    assert_equal(uri_to_path("untitled:Untitled-1"), "")
    for p in ["/x/y.mojo", "/tmp/a b/c%d.mojo", "/日本/🔥.mojo"]:
        assert_equal(uri_to_path(path_to_uri(String(p))), String(p))


def test_utf16_columns() raises:
    var ascii = decode("hello")
    assert_equal(col_to_utf16(ascii, 3), 3)
    assert_equal(utf16_to_col(ascii, 3), 3)
    assert_equal(utf16_to_col(ascii, 99), 5)
    # 🔥 is one codepoint but two UTF-16 units; 日 is one of each
    var line = decode("a🔥b日c")
    assert_equal(col_to_utf16(line, 0), 0)
    assert_equal(col_to_utf16(line, 1), 1)
    assert_equal(col_to_utf16(line, 2), 3)       # after the emoji
    assert_equal(col_to_utf16(line, 3), 4)
    assert_equal(col_to_utf16(line, 5), 6)
    assert_equal(utf16_to_col(line, 0), 0)
    assert_equal(utf16_to_col(line, 1), 1)
    assert_equal(utf16_to_col(line, 2), 1)       # inside the surrogate pair -> the emoji
    assert_equal(utf16_to_col(line, 3), 2)
    assert_equal(utf16_to_col(line, 4), 3)
    assert_equal(utf16_to_col(line, 6), 5)
    for col in range(len(line) + 1):
        assert_equal(utf16_to_col(line, col_to_utf16(line, col)), col)


def test_diagnostic_line_format() raises:
    var d = Diag(26, 4, 26, 7, SEV_ERROR, "cannot convert\nmore detail")
    assert_equal(diagnostic_line("/p/a.mojo", decode("a🔥bcdef"), d), "/p/a.mojo:27:4: error: cannot convert")
    var w = Diag(0, 0, 0, 1, SEV_WARNING, "unused")
    assert_equal(diagnostic_line("/p/a.mojo", decode("x"), w), "/p/a.mojo:1:1: warning: unused")
    var h = Diag(2, 1, 2, 2, SEV_HINT, "consider this")
    assert_equal(diagnostic_line("f", List[Int](), h), "f:3:1: note: consider this")


# --------------------------------------------------- client without a process
def frames_sent(c: LspClient) -> List[String]:
    """Bodies of the messages queued for the server."""
    var f = Framer()
    f.feed(c.conn.proc.outbox)
    var out = List[String]()
    var body = List[UInt8]()
    while f.next(body):
        out.append(bytes_to_str(body))
    return out^


def test_documents_opened_before_ready_are_sent_after_initialize() raises:
    var c = LspClient()
    c.state = LSP_STARTING                       # as after start(), but with no process
    c.init_id = c.conn.request("initialize", "{}")
    assert_true(c.did_open("file:///a.mojo", "first"))
    assert_true(c.did_open("file:///b.mojo", "second"))
    assert_false(c.did_open("file:///a.mojo", "again"))      # already open
    assert_equal(c.did_change("file:///a.mojo", "first, edited"), -1)   # still queued
    assert_equal(len(frames_sent(c)), 1)                     # only initialize so far
    var reply = frame("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":true,\"foldingRangeProvider\":false,\"completionProvider\":{}},\"serverInfo\":{\"name\":\"srv\"}}}")
    c.handle(c.conn.feed(reply))
    assert_equal(c.state, LSP_READY)
    assert_equal(c.server_name, "srv")
    assert_true(c.supports("hoverProvider"))
    assert_true(c.supports("completionProvider"))
    assert_false(c.supports("foldingRangeProvider"))
    assert_false(c.supports("documentFormattingProvider"))
    var sent = frames_sent(c)
    assert_equal(len(sent), 4)                               # + initialized + 2 didOpen
    assert_equal(json_parse(sent[1]).str(json_parse(sent[1]).get(0, "method")), "initialized")
    var o1 = json_parse(sent[2])
    assert_equal(o1.str(o1.get(0, "method")), "textDocument/didOpen")
    assert_equal(o1.str(o1.path(0, "params/textDocument/uri")), "file:///a.mojo")
    assert_equal(o1.str(o1.path(0, "params/textDocument/text")), "first, edited")
    assert_equal(o1.str(o1.path(0, "params/textDocument/languageId")), "mojo")
    var o2 = json_parse(sent[3])
    assert_equal(o2.str(o2.path(0, "params/textDocument/text")), "second")
    # now changes go out with increasing versions
    assert_equal(c.did_change("file:///a.mojo", "v2"), 2)
    assert_equal(c.did_change("file:///a.mojo", "v3"), 3)
    assert_equal(c.did_change("file:///zzz.mojo", "x"), -1)  # not open
    var ch = json_parse(frames_sent(c)[5])
    assert_equal(ch.int(ch.path(0, "params/textDocument/version")), 3)
    assert_equal(ch.str(ch.path(0, "params/contentChanges/0/text")), "v3")


def test_publish_diagnostics_is_stored_per_document() raises:
    var c = LspClient()
    c.state = LSP_READY
    var msg = frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a.mojo\",\"version\":4,\"diagnostics\":[{\"range\":{\"start\":{\"line\":2,\"character\":5},\"end\":{\"line\":2,\"character\":9}},\"severity\":2,\"message\":\"careful\"},{\"range\":{\"start\":{\"line\":7,\"character\":0},\"end\":{\"line\":8,\"character\":1}},\"message\":\"no severity given\"}]}}")
    c.handle(c.conn.feed(msg))
    var d = c.diagnostics("file:///a.mojo")
    assert_equal(len(d), 2)
    assert_equal(d[0].line, 2)
    assert_equal(d[0].ch, 5)
    assert_equal(d[0].end_ch, 9)
    assert_equal(d[0].severity, SEV_WARNING)
    assert_equal(d[0].message, "careful")
    assert_equal(d[1].severity, SEV_ERROR)                   # default when omitted
    assert_equal(d[1].end_line, 8)
    assert_equal(len(c.diagnostics("file:///other.mojo")), 0)
    var up = c.take_updated()
    assert_equal(len(up), 1)
    assert_equal(len(c.take_updated()), 0)
    # a later empty list clears them
    c.handle(c.conn.feed(frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a.mojo\",\"diagnostics\":[]}}")))
    assert_equal(len(c.diagnostics("file:///a.mojo")), 0)
    assert_equal(len(c.take_updated()), 1)


def test_server_requests_are_answered() raises:
    var c = LspClient()
    c.state = LSP_READY
    var data = frame("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"client/registerCapability\",\"params\":{}}")
    for b in frame("{\"jsonrpc\":\"2.0\",\"id\":\"cfg\",\"method\":\"workspace/configuration\",\"params\":{\"items\":[{},{},{}]}}"):
        data.append(b)
    for b in frame("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"workspace/applyEdit\",\"params\":{}}"):
        data.append(b)
    for b in frame("{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":3,\"message\":\"hello from server\"}}"):
        data.append(b)
    c.handle(c.conn.feed(data))
    var sent = frames_sent(c)
    assert_equal(len(sent), 3)
    assert_equal(sent[0], "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":null}")
    assert_equal(sent[1], "{\"jsonrpc\":\"2.0\",\"id\":\"cfg\",\"result\":[null,null,null]}")
    var refused = json_parse(sent[2])
    assert_equal(refused.int(refused.path(0, "error/code")), -32601)
    assert_equal(c.log[0], "hello from server")


def test_failed_initialize() raises:
    var c = LspClient()
    c.state = LSP_STARTING
    c.init_id = c.conn.request("initialize", "{}")
    c.handle(c.conn.feed(frame("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32002,\"message\":\"bad root\"}}")))
    assert_equal(c.state, LSP_FAILED)
    assert_true(c.last_error.find("bad root") >= 0)
    assert_false(c.active())


# ------------------------------------------------------- against the fake server
def test_full_session_with_fake_server() raises:
    var c = LspClient()
    assert_true(c.start(FAKE, "/proj", "/dev/null", own_pid(), now()))
    assert_equal(c.state, LSP_STARTING)
    assert_true(c.did_open("file:///proj/a.mojo", "ok line\nx = BUG here\n🔥🔥 WARN\n"))
    var up = pump(c, 5000, True, 1)
    assert_equal(c.state, LSP_READY)
    assert_equal(c.server_name, "fake-lsp")
    assert_equal(len(up), 1)
    assert_equal(up[0], "file:///proj/a.mojo")
    var d = c.diagnostics("file:///proj/a.mojo")
    assert_equal(len(d), 2)
    assert_equal(d[0].line, 1)
    assert_equal(d[0].ch, 4)
    assert_equal(d[0].severity, SEV_ERROR)
    assert_equal(d[1].line, 2)
    assert_equal(d[1].ch, 5)                    # two emoji = 4 UTF-16 units, then a space
    assert_equal(d[1].severity, SEV_WARNING)
    # in editor columns the warning starts after 2 emoji + space = column 3
    assert_equal(utf16_to_col(decode("🔥🔥 WARN"), d[1].ch), 3)
    assert_equal(c.log[len(c.log) - 1], "checked v1")
    # fix the bug: diagnostics shrink
    assert_equal(c.did_change("file:///proj/a.mojo", "ok line\nx = fine\n"), 2)
    up = pump(c, 5000, False, 1)
    assert_equal(len(up), 1)
    assert_equal(len(c.diagnostics("file:///proj/a.mojo")), 0)
    # the server's own requests were answered the way it expects
    var id = c.conn.request("client_replies", "")
    var got = False
    var deadline = now() + 5000 * MS
    while not got and now() < deadline:
        for m in c.conn.poll():
            if m.id == id:
                got = True
                assert_true(m.doc.is_null(m.doc.path(m.result(), "900/result")))
                assert_equal(m.doc.size(m.doc.path(m.result(), "901/result")), 2)
                assert_equal(m.doc.int(m.doc.path(m.result(), "902/error/code")), -32601)
    assert_true(got)
    c.did_close("file:///proj/a.mojo")
    assert_equal(c.find_doc("file:///proj/a.mojo"), -1)
    c.stop()
    assert_equal(c.state, LSP_STOPPED)
    assert_false(c.conn.proc.running)


def test_server_that_cannot_start_or_dies() raises:
    var c = LspClient()
    assert_true(c.start("/no/such/language-server", "/proj", "/dev/null", own_pid(), now()))
    _ = pump(c, 3000, True, 0)
    assert_equal(c.state, LSP_FAILED)
    assert_true(c.last_error.byte_length() > 0)
    c.stop()
    var d = LspClient()
    assert_true(d.start(FAKE, "/proj", "/dev/null", own_pid(), now()))
    _ = pump(d, 5000, True, 0)
    assert_equal(d.state, LSP_READY)
    _ = d.conn.request("die", "")
    _ = pump(d, 3000, True, 99)
    assert_equal(d.state, LSP_FAILED)
    d.stop()


# ------------------------------------------------------------ in the IDE
def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-lsptest-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def run_ticks(mut app: App, ms: Int, want_latency: Bool):
    """Drive the IDE's language-server tick for a while, as the event loop would."""
    var deadline = now() + ms * MS
    app.lsp_last_latency_ms = -1
    while now() < deadline:
        var fds = List[Int]()
        if app.lsp.fd() >= 0:
            fds.append(app.lsp.fd())
        _ = wait_readable(fds, 20)
        app.lsp_tick(now_ns())
        if want_latency and app.lsp_last_latency_ms >= 0:
            return


def message_text(app: App) -> String:
    var mi = app.msg_index()
    if mi < 0:
        return ""
    return to_str(app.wins[mi].buf.all_text())


def test_command_is_registered_on_f7() raises:
    var r = build_registry()
    assert_equal(r.find_key(fkey(7)), CM_LSP)
    assert_equal(r.key_label(CM_LSP), "F7")


def test_untitled_buffer_is_refused() raises:
    var app = App()
    app.scr.resize(100, 30)
    app.exec(1)                                  # CM_NEW
    app.exec(CM_LSP)
    assert_false(app.lsp.active())
    assert_true(app.status.find("Save the file first") >= 0)


def test_ide_shows_live_diagnostics_from_a_server() raises:
    var dir = scratch("ide")
    _ = run_system("printf 'line one\\nhas a BUG\\n' > '" + dir + "/a.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    _ = run_system("true")
    # use the fake server instead of mojo-lsp-server
    var path = dir + "/a.mojo"
    app.open_path(path)
    var i = app.top()
    assert_true(app.lsp.start(FAKE, dir, "/dev/null", own_pid(), now_ns()))
    app.lsp_track(i, now_ns())
    run_ticks(app, 5000, True)
    assert_true(app.lsp_last_latency_ms >= 0, "diagnostics arrived")
    var text = message_text(app)
    assert_true(text.find("Language server diagnostics for " + path) == 0)
    assert_true(text.find(path + ":2:7: error: found BUG") > 0, text)
    assert_true(text.find("    second line of detail") > 0)
    assert_true(text.find("1 problem(s)") > 0)
    # the diagnostics are navigable like compiler errors
    assert_equal(len(app.errs), 1)
    assert_equal(app.errs[0].row, 2)
    assert_equal(app.errs[0].col, 7)
    # focus stays in the editor
    assert_equal(app.wins[app.top()].path, path)
    # edit: remove the bug; after the debounce the server is told and the list empties
    var ei = app.find_editor(path)
    app.wins[ei].goto(1, 0)
    _ = app.wins[ei].delete_line()
    var edited_at = now()
    run_ticks(app, 5000, True)
    var waited = (now() - edited_at) // MS
    assert_true(waited >= 300, "the change is held back for the 300 ms debounce, waited " + String(waited))
    assert_true(waited < 3000)
    assert_true(message_text(app).find("No problems found") > 0)
    assert_equal(len(app.errs), 0)
    # the command on the same file stops the server
    app.exec(CM_LSP)
    assert_false(app.lsp.active())
    assert_false(app.lsp.conn.proc.running)
    _ = run_system("rm -rf '" + dir + "'")


def test_closing_the_tracked_window_closes_the_document() raises:
    var dir = scratch("close")
    _ = run_system("printf 'x\\n' > '" + dir + "/a.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(dir + "/a.mojo")
    assert_true(app.lsp.start(FAKE, dir, "/dev/null", own_pid(), now_ns()))
    app.lsp_track(app.top(), now_ns())
    run_ticks(app, 5000, True)
    app.remove_window(app.find_editor(dir + "/a.mojo"))
    run_ticks(app, 300, False)
    assert_equal(app.lsp_path, "")
    var id = app.lsp.conn.request("closed_docs", "")
    var seen = False
    var deadline = now() + 5000 * MS
    while not seen and now() < deadline:
        for m in app.lsp.conn.poll():
            if m.id == id:
                seen = True
                assert_equal(m.doc.size(m.result()), 1)
    assert_true(seen)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_dead_server_is_reported_once_and_cleaned_up() raises:
    var dir = scratch("dead")
    _ = run_system("printf 'x\\n' > '" + dir + "/a.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(dir + "/a.mojo")
    assert_true(app.lsp.start(FAKE, dir, "/dev/null", own_pid(), now_ns()))
    app.lsp_track(app.top(), now_ns())
    run_ticks(app, 5000, True)
    _ = app.lsp.conn.request("die", "")
    run_ticks(app, 1500, False)
    assert_false(app.lsp.active())
    assert_false(app.lsp.conn.proc.running)
    assert_true(app.status.find("Language server") >= 0)
    assert_true(app.lsp_reported_failure)
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------------------- the real mojo-lsp-server
def test_real_server_reports_a_type_error() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("real")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'def main():\\n    var x: Int = \"oops\"\\n    print(x)\\n' > '" + path + "'")
    var app = App()
    app.cwd = dir
    var c = LspClient()
    # the IDE's own command line, including the toolchain environment it works out
    assert_true(c.start(app.lsp_server_command(path), dir, "/dev/null", own_pid(), now()))
    var uri = path_to_uri(path)
    _ = c.did_open(uri, bytes_to_str(run_capture("cat '" + path + "'").out))
    var up = pump(c, 30000, True, 1)
    assert_equal(c.state, LSP_READY)
    assert_equal(c.server_name, "mojo-lsp-server")
    assert_true(c.supports("hoverProvider"))
    assert_true(c.supports("definitionProvider"))
    assert_false(c.supports("documentFormattingProvider"))   # as found in the roadmap research
    assert_false(c.supports("foldingRangeProvider"))
    assert_equal(len(up), 1)
    var d = c.diagnostics(uri)
    assert_true(len(d) >= 1, "the type error is reported")
    assert_equal(d[0].line, 1)
    assert_equal(d[0].severity, SEV_ERROR)
    assert_true(d[0].message.find("cannot implicitly convert") >= 0, d[0].message)
    # fix it and the error goes away
    _ = c.did_change(uri, "def main():\n    var x: Int = 1\n    print(x)\n")
    _ = pump(c, 30000, False, 1)
    assert_equal(len(c.diagnostics(uri)), 0)
    c.stop()
    assert_false(c.conn.proc.running)
    _ = run_system("rm -rf '" + dir + "'")


def test_toolchain_environment_prefix() raises:
    var dir = scratch("toolenv")
    _ = run_system("mkdir -p '" + dir + "/pfx/bin' '" + dir + "/pfx/share/max' '" + dir + "/bare/bin'")
    # already configured: nothing to add
    assert_equal(toolchain_env("/some/modular/home", dir + "/pfx/bin/mojo"), "")
    # derived from the tool's location
    assert_equal(toolchain_env("", dir + "/pfx/bin/mojo"), "env MODULAR_HOME='" + dir + "/pfx/share/max' ")
    # no share/max next to it, or tool not found: nothing we can do
    assert_equal(toolchain_env("", dir + "/bare/bin/mojo"), "")
    assert_equal(toolchain_env("", ""), "")
    assert_equal(which("sh").byte_length() > 0, True)
    assert_equal(which("definitely-not-a-program-xyz"), "")
    assert_equal(which(""), "")
    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
