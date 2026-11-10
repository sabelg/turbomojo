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
from appstate import App, now_ns, M_NORMAL, M_COMPLETE
from window import WK_MESSAGE
from commands import CM_LSP, CM_NONE, CM_SAVE, CM_NEW, CM_NEXTERR, CM_PREVERR, CM_COMPLETE, CM_UNDO, build_registry
from term import fkey, key_event, KEY_ENTER, KEY_TAB, KEY_UP, KEY_DOWN, KEY_ESC
from signals import own_pid
from util import decode, to_str, str_bytes, bytes_to_str, env_or, run_system, run_capture, getcwd, toolchain_env, which
from config import load_settings, read_text

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
    assert_true(text.find("Problems reported by the language server") == 0, text)
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


def test_dead_server_is_noticed_and_cleaned_up() raises:
    var dir = scratch("dead")
    _ = run_system("printf 'x\\n' > '" + dir + "/a.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.lsp_server = FAKE
    app.lsp_restart_base_ms = 60000                      # keep the restart pending for the test
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    _ = app.lsp.conn.request("die", "")
    run_ticks(app, 1500, False)
    assert_false(app.lsp.active())
    assert_false(app.lsp.conn.proc.running)              # the dead process was reaped
    assert_true(app.status.find("Language server stopped unexpectedly") >= 0, app.status)
    assert_true(app.lsp_restart_due > 0)                 # and it will be brought back
    assert_equal(app.lsp_restart_path, dir + "/a.mojo")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------------------------ capability table
def caps_of(text: String) -> LspCaps:
    return parse_caps(json_parse(text))


def test_capability_table_from_a_full_answer() raises:
    var c = caps_of(
        "{\"textDocumentSync\": {\"openClose\": true, \"change\": 2, \"save\": {\"includeText\": false}},"
        + "\"positionEncoding\": \"utf-16\","
        + "\"completionProvider\": {\"triggerCharacters\": [\".\", \":\"], \"resolveProvider\": true},"
        + "\"hoverProvider\": true, \"signatureHelpProvider\": {\"triggerCharacters\": [\"(\", \",\"]},"
        + "\"definitionProvider\": {}, \"referencesProvider\": true, \"documentHighlightProvider\": false,"
        + "\"renameProvider\": {\"prepareProvider\": true}, \"codeActionProvider\": {\"codeActionKinds\": [\"quickfix\"]},"
        + "\"documentSymbolProvider\": true, \"workspaceSymbolProvider\": null, \"inlayHintProvider\": true,"
        + "\"semanticTokensProvider\": {\"legend\": {\"tokenTypes\": [\"type\", \"function\"], \"tokenModifiers\": [\"readonly\"]}, \"full\": {\"delta\": true}, \"range\": false}}"
    )
    assert_equal(c.sync_kind, SYNC_INCREMENTAL)
    assert_true(c.sync_open_close)
    assert_true(c.sync_save)
    assert_equal(c.position_encoding, "utf-16")
    assert_true(c.completion)
    assert_true(c.completion_resolve)
    assert_equal(len(c.completion_triggers), 2)
    assert_equal(c.completion_triggers[1], ":")
    assert_true(c.hover)
    assert_true(c.signature_help)
    assert_equal(c.signature_triggers[0], "(")
    assert_true(c.definition)                           # an empty options object counts
    assert_true(c.references)
    assert_false(c.document_highlight)                  # false
    assert_true(c.rename)
    assert_true(c.prepare_rename)
    assert_true(c.code_action)
    assert_true(c.document_symbol)
    assert_false(c.workspace_symbol)                    # null
    assert_false(c.formatting)                          # absent
    assert_false(c.folding_range)
    assert_true(c.inlay_hint)
    assert_true(c.semantic_tokens)
    assert_true(c.semantic_full)
    assert_false(c.semantic_range)
    assert_equal(len(c.token_types), 2)
    assert_equal(c.token_types[1], "function")
    assert_equal(c.token_modifiers[0], "readonly")
    var lines = c.describe()
    assert_equal(lines[0], "document sync: incremental, save notifications")
    assert_true(lines[2].find("completion, hover, signature help, go to definition, references, rename") > 0, lines[2])


def test_capability_table_from_short_and_odd_answers() raises:
    var simple = caps_of("{\"textDocumentSync\": 1, \"renameProvider\": true}")
    assert_equal(simple.sync_kind, SYNC_FULL)
    assert_true(simple.sync_open_close)
    assert_false(simple.sync_save)
    assert_true(simple.rename)
    assert_false(simple.prepare_rename)
    assert_false(simple.completion)
    assert_equal(len(simple.completion_triggers), 0)
    var none = caps_of("{}")
    assert_equal(none.sync_kind, SYNC_NONE)
    assert_false(none.hover)
    assert_equal(none.position_encoding, "utf-16")
    assert_equal(none.describe()[2], "features: none")
    var odd = caps_of("{\"textDocumentSync\": 7, \"positionEncoding\": \"utf-8\", \"textDocumentSyncX\": 1}")
    assert_equal(odd.sync_kind, SYNC_NONE)              # an unknown kind is not trusted
    assert_equal(odd.position_encoding, "utf-8")
    var save_false = caps_of("{\"textDocumentSync\": {\"change\": 1, \"save\": false}}")
    assert_false(save_false.sync_save)
    assert_equal(save_false.sync_kind, SYNC_FULL)
    var unparsed = LspCaps()
    assert_false(unparsed.completion)


def test_client_reads_the_table_and_declares_itself() raises:
    var c = LspClient()
    assert_true(c.start(FAKE, "/tmp", "/dev/null", own_pid(), now()))
    assert_equal(c.starts, 1)
    assert_false(c.was_ready)
    _ = pump(c, 5000, True, 0)
    assert_equal(c.state, LSP_READY)
    assert_true(c.was_ready)
    assert_equal(c.table.sync_kind, SYNC_FULL)
    assert_true(c.table.hover)
    assert_true(c.table.completion)
    assert_equal(c.table.completion_triggers[0], ".")
    assert_true(c.table.prepare_rename)
    assert_false(c.table.folding_range)
    c.stop()
    assert_equal(c.state, LSP_STOPPED)
    # a second start is a new run with a fresh table
    assert_true(c.start(FAKE, "/tmp", "/dev/null", own_pid(), now()))
    assert_equal(c.starts, 2)
    assert_false(c.was_ready)
    assert_false(c.table.hover)
    c.stop()


# ------------------------------------------------------- restart on crash
def count_lines(path: String) -> Int:
    var n = 0
    for b in run_capture("cat '" + path + "' 2>/dev/null").out:
        if b == 10:
            n += 1
    return n


def crash_app(dir: String) raises -> App:
    _ = run_system("printf 'has a BUG\\n' > '" + dir + "/a.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.lsp_server = "env FAKE_START_LOG=" + dir + "/starts.log " + FAKE
    app.lsp_restart_base_ms = 100
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    return app^


def test_crashed_server_is_restarted_and_the_file_checked_again() raises:
    var dir = scratch("restart")
    var app = crash_app(dir)
    assert_equal(count_lines(dir + "/starts.log"), 1)
    assert_true(message_text(app).find("found BUG") > 0)
    var uri = path_to_uri(dir + "/a.mojo")
    _ = app.lsp.conn.request("die", "")
    # until the new server has checked the file again (its diagnostics start out empty)
    var t0 = now()
    var back = False
    while not back and now() - t0 < 8000 * MS:
        run_ticks(app, 30, False)
        back = app.lsp.starts == 2 and app.lsp.state == LSP_READY and len(app.lsp.diagnostics(uri)) == 1
    assert_true(back, "restarted and checked again; status: " + app.status)
    assert_equal(count_lines(dir + "/starts.log"), 2)
    assert_equal(app.lsp_path, dir + "/a.mojo")
    assert_equal(len(app.lsp_crashes), 1)
    assert_true(message_text(app).find("found BUG") > 0)
    # editing still reaches the new server
    var ei = app.find_editor(dir + "/a.mojo")
    app.wins[ei].goto(0, 0)
    _ = app.wins[ei].delete_line()
    run_ticks(app, 5000, True)
    assert_true(message_text(app).find("No problems found") > 0, message_text(app))
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_restarts_wait_longer_each_time_and_then_stop() raises:
    var dir = scratch("giveup")
    var app = crash_app(dir)
    var waits = List[Int]()
    for round in range(3):
        _ = app.lsp.conn.request("die", "")
        var t0 = now()
        # until the crash is noticed
        while app.lsp_restart_due == 0 and now() - t0 < 3000 * MS:
            run_ticks(app, 20, False)
        assert_true(app.lsp_restart_due > 0, "round " + String(round) + ": no restart planned")
        waits.append((app.lsp_restart_due - now_ns()) // MS)
        var t1 = now()
        while not (app.lsp.starts == round + 2 and app.lsp.state == LSP_READY) and now() - t1 < 8000 * MS:
            run_ticks(app, 30, False)
        assert_equal(app.lsp.state, LSP_READY, "round " + String(round))
    assert_equal(count_lines(dir + "/starts.log"), 4)
    assert_true(waits[1] > waits[0] and waits[2] > waits[1], "waits " + String(waits[0]) + " " + String(waits[1]) + " " + String(waits[2]))
    # the fourth crash within the minute: no more automatic restarts
    _ = app.lsp.conn.request("die", "")
    run_ticks(app, 1500, False)
    assert_equal(app.lsp_restart_due, 0)
    assert_false(app.lsp.active())
    assert_true(app.status.find("keeps stopping") > 0, app.status)
    assert_equal(count_lines(dir + "/starts.log"), 4)
    # asking again by hand works and resets the allowance
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    assert_equal(app.lsp.state, LSP_READY)
    assert_equal(len(app.lsp_crashes), 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_stopping_by_hand_cancels_a_pending_restart() raises:
    var dir = scratch("cancel")
    var app = crash_app(dir)
    app.lsp_restart_base_ms = 60000                      # long enough to stay pending
    _ = app.lsp.conn.request("die", "")
    var t0 = now()
    while app.lsp_restart_due == 0 and now() - t0 < 3000 * MS:
        run_ticks(app, 20, False)
    assert_true(app.lsp_restart_due > 0)
    # the loop is told when to come back
    assert_true(app.next_timeout_ms(now_ns(), False, 30) <= 60001)
    app.exec(CM_LSP)                                     # the same key: stop
    assert_equal(app.lsp_restart_due, 0)
    assert_false(app.lsp.active())
    run_ticks(app, 300, False)
    assert_equal(count_lines(dir + "/starts.log"), 1)
    _ = run_system("rm -rf '" + dir + "'")


def test_a_server_that_never_starts_is_not_restarted() raises:
    var dir = scratch("nostart")
    _ = run_system("printf 'x\\n' > '" + dir + "/a.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.lsp_server = "sh -c 'exit 3' ignored"
    app.lsp_restart_base_ms = 50
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 1500, False)
    assert_false(app.lsp.active())
    assert_equal(app.lsp_restart_due, 0)
    assert_equal(len(app.lsp_crashes), 0)
    assert_true(app.status.find("Language server") >= 0, app.status)
    _ = run_system("rm -rf '" + dir + "'")


# ----------------------------------------------------------- include paths
def test_include_paths_reach_the_server_and_the_compiler() raises:
    var dir = scratch("inc")
    _ = run_system("mkdir -p '" + dir + "/proj/sub' '" + dir + "/proj/lib dir'")
    with open(dir + "/proj/.turbomojo.toml", "w") as f:
        f.write("[tools]\ninclude_paths = [\"lib dir\", \"/opt/shared\"]\nlsp_server = \"my-lsp\"\n")
    var app = App()
    app.cwd = dir + "/proj/sub"                          # started in a subfolder of the project
    app.project_dir = dir + "/proj"
    app.apply_settings(load_settings("", read_text(dir + "/proj/.turbomojo.toml")))
    assert_equal(len(app.config_warnings), 0)
    assert_equal(len(app.include_paths), 2)
    assert_equal(app.include_paths[0], dir + "/proj/lib dir")      # relative to the project file
    assert_equal(app.include_paths[1], "/opt/shared")
    assert_equal(app.include_flags(), " -I '" + dir + "/proj/lib dir' -I '/opt/shared'")
    var cmd = app.lsp_server_command(dir + "/proj/sub/x.mojo")
    assert_true(cmd.find("my-lsp -I '" + dir + "/proj/sub' -I '" + dir + "/proj/sub' -I '" + dir + "/proj/lib dir' -I '/opt/shared'") >= 0, cmd)
    # none configured: nothing added
    var plain = App()
    assert_equal(plain.include_flags(), "")
    assert_equal(plain.lsp_server, "mojo-lsp-server")
    # a single folder and bad values
    var one = load_settings("[tools]\ninclude_paths = \"src\"\n", "")
    assert_equal(len(one.include_paths), 1)
    var bad = load_settings("[tools]\ninclude_paths = 3\nlsp_server = \"\"\n", "")
    assert_equal(len(bad.include_paths), 0)
    assert_equal(bad.lsp_server, "mojo-lsp-server")
    assert_equal(len(bad.warnings), 2)
    _ = run_system("rm -rf '" + dir + "'")


def test_fake_server_receives_the_include_flags() raises:
    var dir = scratch("incargs")
    var app = crash_app(dir)
    app.lsp_stop()
    var first = bytes_to_str(run_capture("head -1 '" + dir + "/starts.log'").out)
    assert_true(first.find("-I " + dir + " -I " + dir) >= 0, first)
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------------------------- problems in the UI
def test_problems_of_all_files_are_listed_and_marked_in_the_editors() raises:
    var dir = scratch("probs")
    _ = run_system("printf 'ok line\\n  a BUG here\\n' > '" + dir + "/a.mojo'; printf 'x = 1 WARN\\nfine\\nBUG\\n' > '" + dir + "/b.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.lsp_server = FAKE
    app.open_path(dir + "/a.mojo")
    app.open_path(dir + "/b.mojo")
    app.focus(app.find_editor(dir + "/a.mojo"))
    app.exec(CM_LSP)
    var t0 = now()
    while len(app.errs) < 3 and now() - t0 < 8000 * MS:
        run_ticks(app, 30, False)
    var text = message_text(app)
    # the active file first, then the other; one line per problem
    var a_at = text.find(dir + "/a.mojo:2:5: error: found BUG")
    var b_warn = text.find(dir + "/b.mojo:1:7: warning: found WARN")
    var b_err = text.find(dir + "/b.mojo:3:1: error: found BUG")
    assert_true(a_at > 0 and b_warn > a_at and b_err > b_warn, text)
    assert_true(text.find("3 problem(s) in 2 files") > 0, text)
    assert_equal(app.wins[app.msg_index()].title, "Problems")
    assert_equal(len(app.errs), 3)
    # the windows know their problems
    var ai = app.find_editor(dir + "/a.mojo")
    var bi = app.find_editor(dir + "/b.mojo")
    assert_equal(len(app.wins[ai].buf.marks), 1)
    assert_equal(app.wins[ai].buf.marks[0].l1, 1)
    assert_equal(app.wins[ai].buf.marks[0].c1, 4)
    assert_equal(app.wins[ai].buf.marks[0].c2, 7)
    assert_equal(app.wins[ai].buf.marks[0].severity, SEV_ERROR)
    assert_equal(len(app.wins[bi].buf.marks), 2)
    assert_equal(app.wins[bi].buf.mark_severity(0), SEV_WARNING)
    assert_equal(app.wins[bi].buf.mark_severity(1), 0)
    assert_equal(app.wins[bi].buf.mark_severity(2), SEV_ERROR)
    # drawn: underlined range, coloured line number
    app.draw()
    var wx = app.wins[ai].x + 1 + app.wins[ai].gut
    var wy = app.wins[ai].y + 1
    assert_true(app.scr.ul_at(wx + 4, wy + 1) != 0, "the word BUG is underlined")
    assert_true(app.scr.ul_at(wx + 6, wy + 1) != 0)
    assert_equal(app.scr.ul_at(wx + 3, wy + 1), 0)
    assert_equal(app.scr.ul_at(wx + 7, wy + 1), 0)
    assert_equal(app.scr.ul_at(wx + 4, wy), 0)
    assert_equal(app.scr.fg_at(app.wins[ai].x + 3, wy + 1), app.pal.diag_err)     # the "2" of the line number
    assert_true(app.scr.fg_at(app.wins[ai].x + 3, wy) != app.pal.diag_err)
    # the status line explains the problem on the cursor line
    app.wins[ai].goto(1, 0)
    app.status_until = 0
    app.draw()
    var last = to_str(app.scr.row_text(app.scr.h - 1))
    assert_true(last.find("error: found BUG") > 0, last)
    assert_true(last.find("INS") > 0, last)
    app.wins[ai].goto(0, 0)
    app.draw()
    assert_true(to_str(app.scr.row_text(app.scr.h - 1)).find("found BUG") < 0)
    # next problem / previous problem walk the list across files
    app.exec(CM_NEXTERR)
    assert_equal(app.wins[app.top()].path, dir + "/a.mojo")
    assert_equal(app.wins[app.top()].cr, 1)
    app.exec(CM_NEXTERR)
    assert_equal(app.wins[app.top()].path, dir + "/b.mojo")
    assert_equal(app.wins[app.top()].cr, 0)
    assert_equal(app.wins[app.top()].cc, 6)
    app.exec(CM_PREVERR)
    assert_equal(app.wins[app.top()].path, dir + "/a.mojo")
    # stopping the server takes the marks away
    app.lsp_stop()
    assert_equal(len(app.wins[app.find_editor(dir + "/a.mojo")].buf.marks), 0)
    assert_equal(len(app.wins[app.find_editor(dir + "/b.mojo")].buf.marks), 0)
    _ = run_system("rm -rf '" + dir + "'")


def test_problem_marks_follow_edits_until_the_server_answers() raises:
    var dir = scratch("shift")
    _ = run_system("printf 'one\\ntwo BUG\\nthree\\n' > '" + dir + "/a.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.lsp_server = FAKE
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    var i = app.find_editor(dir + "/a.mojo")
    assert_equal(app.wins[i].buf.marks[0].l1, 1)
    _ = app.wins[i].buf.insert(0, 0, decode("new\nlines\n"), 0, 0, 0)     # two lines above
    assert_equal(app.wins[i].buf.marks[0].l1, 3)                           # at once, before any answer
    _ = app.wins[i].buf.delete(0, 0, 1, 0, 0, 0, 0)
    assert_equal(app.wins[i].buf.marks[0].l1, 2)
    _ = app.wins[i].buf.delete(1, 0, 3, 0, 0, 0, 0)                        # the marked line is deleted
    assert_equal(len(app.wins[i].buf.marks), 0)
    # the server's next report is the truth again
    var t0 = now()
    while app.lsp_change_due == 0 and now() - t0 < 1000 * MS:
        run_ticks(app, 20, False)
    run_ticks(app, 1500, False)
    assert_equal(len(app.wins[i].buf.marks), 0)
    assert_true(message_text(app).find("No problems found") > 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_columns_of_problems_after_wide_characters() raises:
    var dir = scratch("wide")
    _ = run_system("printf 'x = \"🔥🔥\" BUG\\n' > '" + dir + "/a.mojo'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.lsp_server = FAKE
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    var i = app.find_editor(dir + "/a.mojo")
    # the server counted each emoji as two units; the editor as one character
    assert_equal(app.wins[i].buf.marks[0].c1, 9)
    assert_equal(app.wins[i].buf.marks[0].c2, 12)
    assert_true(message_text(app).find("a.mojo:1:10: error") > 0, message_text(app))
    app.draw()
    var wx = app.wins[i].x + 1 + app.wins[i].gut
    var wy = app.wins[i].y + 1
    # on screen the emoji are two columns each: "BUG" starts at column 11
    assert_equal(app.scr.ul_at(wx + 10, wy), 0)
    assert_true(app.scr.ul_at(wx + 11, wy) != 0)
    assert_true(app.scr.ul_at(wx + 13, wy) != 0)
    assert_equal(app.scr.ul_at(wx + 14, wy), 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


# --------------------------------------------------------------- completion
def test_completion_results_are_parsed_and_ordered() raises:
    var d = json_parse(
        "{\"isIncomplete\": true, \"items\": ["
        + "{\"label\": \"zeta\", \"sortText\": \"2\", \"kind\": 3, \"detail\": \"def zeta()\", \"documentation\": \"plain doc\"},"
        + "{\"label\": \"alpha\", \"sortText\": \"3\", \"insertText\": \"alpha()\"},"
        + "{\"label\": \"mid\", \"sortText\": \"1\", \"textEdit\": {\"newText\": \"pkg.mid\"}, \"insertText\": \"ignored\", \"filterText\": \"m\","
        + " \"documentation\": {\"kind\": \"markdown\", \"value\": \"**md**\"}},"
        + "{\"kind\": 3},"
        + "{\"label\": \"same\", \"sortText\": \"1\"}]}"
    )
    var lst = parse_completion(d, 0)
    assert_true(lst.incomplete)
    assert_equal(len(lst.items), 4)                     # the one without a label is dropped
    assert_equal(lst.items[0].label, "mid")             # by sort key; equal keys keep their order
    assert_equal(lst.items[1].label, "same")
    assert_equal(lst.items[2].label, "zeta")
    assert_equal(lst.items[3].label, "alpha")
    assert_equal(lst.items[0].insert, "pkg.mid")        # the text edit wins
    assert_equal(lst.items[0].filter, "m")
    assert_equal(lst.items[0].doc, "**md**")
    assert_equal(lst.items[2].insert, "zeta")
    assert_equal(lst.items[2].kind, 3)
    assert_equal(lst.items[2].detail, "def zeta()")
    assert_equal(lst.items[2].doc, "plain doc")
    assert_equal(lst.items[3].insert, "alpha()")
    assert_equal(lst.items[3].sort, "3")
    assert_true(lst.items[2].raw.find("\"label\"") >= 0)
    var arr = parse_completion(json_parse("[{\"label\": \"only\"}]"), 0)
    assert_false(arr.incomplete)
    assert_equal(arr.items[0].sort, "only")             # no sort key: the label
    assert_equal(len(parse_completion(json_parse("null"), 0).items), 0)
    assert_equal(len(parse_completion(json_parse("[]"), 0).items), 0)
    assert_equal(kind_tag(3), "fn ")
    assert_equal(kind_tag(22), "typ")
    assert_equal(kind_tag(6), "var")
    assert_equal(kind_tag(99), "   ")


def comp_app(dir: String, body: String) raises -> App:
    with open(dir + "/a.mojo", "w") as f:
        f.write(body)
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.lsp_server = FAKE
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    return app^


def wait_popup(mut app: App, want: Int):
    """Until the popup shows `want` items (the server's answer has been merged in)."""
    var t0 = now()
    while not (app.mode == M_COMPLETE and len(app.comp_items) >= want) and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)


def labels(app: App) -> String:
    var out = String("")
    for k in range(len(app.comp_items)):
        out += app.comp_items[k] + " "
    return out


def test_server_items_come_first_and_words_follow() raises:
    var dir = scratch("comp1")
    var app = comp_app(dir, "var print_me = 1\nvar probe = 2\npr\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(2, 2)
    app.exec(CM_COMPLETE)
    # at once: the words from the text
    assert_equal(app.mode, M_COMPLETE)
    assert_equal(labels(app), "print_me probe print ")     # words of the text, then keywords
    wait_popup(app, 5)
    # then the server's items in its order (sort keys a, b, e), filtered by "pr",
    # and after them the words it did not offer
    assert_equal(labels(app), "prefix_len print_line Zebra print_me probe print ")
    assert_equal(app.comp_sel, 0)                       # the server's first item is under the bar
    assert_equal(app.comp_kind[0], 6)
    assert_equal(app.comp_kind[3], -1)
    assert_equal(app.comp_detail[1], "def print_line(s: String)")
    assert_true(app.comp_doc[1].find("Prints **s**") >= 0)
    # typing narrows the list without asking again
    app.handle(key_event(105))                          # "i"
    assert_equal(labels(app), "print_line print_me print ")
    var st = server_state(app)
    assert_equal(st.size(st.get(0, "asked")), 1)
    assert_equal(st.int(st.get(st.at(st.get(0, "asked"), 0), "line")), 2)
    assert_equal(st.int(st.get(st.at(st.get(0, "asked"), 0), "character")), 2)
    assert_equal(st.int(st.get(st.at(st.get(0, "asked"), 0), "kind")), 1)
    # Enter takes the selected one
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[i].buf.line(2)), "print_line")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_a_selection_the_user_made_survives_the_server_answer() raises:
    var dir = scratch("compkeep")
    var app = comp_app(dir, "# SLOWCOMPLETE\nvar print_me = 1\nvar probe = 2\npr\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(3, 2)
    app.exec(CM_COMPLETE)
    assert_equal(labels(app), "print_me probe print ")
    app.handle(key_event(KEY_DOWN))                     # the user picks "probe" while waiting
    wait_popup(app, 5)
    assert_equal(app.comp_items[app.comp_sel], "probe")
    app.handle(key_event(KEY_ENTER))
    assert_equal(to_str(app.wins[i].buf.line(3)), "probe")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_item_with_its_own_insert_text_replaces_what_was_typed() raises:
    var dir = scratch("comp2")
    var app = comp_app(dir, "x = prZ\ny = Pa\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(0, 7)
    app.exec(CM_COMPLETE)
    wait_popup(app, 1)
    assert_equal(labels(app), "Zebra ")                 # matched through its filter text
    app.handle(key_event(KEY_ENTER))
    assert_equal(to_str(app.wins[i].buf.line(0)), "x = zebra.Zebra")
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[i].buf.line(0)), "x = prZ")       # one step back
    app.wins[i].goto(1, 6)
    app.exec(CM_COMPLETE)
    wait_popup(app, 1)
    assert_equal(labels(app), "Path ")
    app.handle(key_event(KEY_TAB))
    assert_equal(to_str(app.wins[i].buf.line(1)), "y = Path()")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_trigger_character_opens_the_member_list_and_details_are_fetched() raises:
    var dir = scratch("comp3")
    var app = comp_app(dir, "items\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(0, 5)
    app.handle(key_event(46))                           # "."
    assert_equal(app.mode, M_NORMAL)                    # nothing to show yet
    assert_true(app.comp_waiting)
    wait_popup(app, 3)
    assert_equal(labels(app), "capacity append clear ")
    assert_equal(app.comp_doc[0], "How many items fit before the list grows.")
    var st = server_state(app)
    var asked = st.at(st.get(0, "asked"), 0)
    assert_equal(st.int(st.get(asked, "character")), 6)
    assert_equal(st.int(st.get(asked, "kind")), 2)
    assert_equal(st.str(st.get(asked, "char")), ".")
    # moving to an item without documentation asks the server for it, once
    app.handle(key_event(KEY_DOWN))
    assert_equal(app.comp_items[app.comp_sel], "append")
    var t0 = now()
    while app.comp_doc[1].byte_length() == 0 and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)
    assert_equal(app.comp_doc[1], "Details for append, fetched on request.")
    app.handle(key_event(KEY_UP))
    app.handle(key_event(KEY_DOWN))
    run_ticks(app, 200, False)
    st = server_state(app)
    assert_equal(st.size(st.get(0, "resolved")), 1)
    # typing filters the member list; accepting completes after the dot
    app.handle(key_event(99))                           # "c"
    assert_equal(labels(app), "capacity clear ")
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(to_str(app.wins[i].buf.line(0)), "items.clear")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_late_and_empty_answers() raises:
    var dir = scratch("comp4")
    var app = comp_app(dir, "# SLOWCOMPLETE\nqx\nzz\n")
    var i = app.find_editor(dir + "/a.mojo")
    # the cursor leaves before the answer comes: the answer is dropped
    app.wins[i].goto(1, 2)
    app.exec(CM_COMPLETE)
    assert_true(app.comp_waiting)                       # no word starts with "qx" elsewhere
    assert_equal(app.status, "Asking the language server...")
    app.wins[i].goto(2, 0)
    run_ticks(app, 900, False)
    assert_equal(app.mode, M_NORMAL)
    assert_false(app.comp_waiting)
    # a server with nothing to say
    app.wins[i].buf.load(decode("# NOCOMPLETE\nqq\n"))
    run_ticks(app, 500, False)
    app.wins[i].goto(1, 2)
    app.exec(CM_COMPLETE)
    var t0 = now()
    while app.comp_waiting and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "No completions here")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_server_that_is_still_analysing_is_asked_again() raises:
    var dir = scratch("compbusy")
    var app = comp_app(dir, "# BUSYSERVER\nitems\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(1, 5)
    app.handle(key_event(46))                           # "."
    wait_popup(app, 3)                                  # two refusals, then the list
    assert_equal(labels(app), "capacity append clear ")
    var st = server_state(app)
    assert_equal(st.size(st.get(0, "asked")), 3)
    assert_equal(app.comp_retries, 0)                   # the count starts afresh next time
    app.handle(key_event(KEY_ESC))
    # a real failure is reported, not retried for ever
    app.wins[i].buf.load(decode("# BROKENCOMPLETE\nqx\n"))
    run_ticks(app, 500, False)
    app.wins[i].goto(1, 2)
    app.exec(CM_COMPLETE)
    var t0 = now()
    while app.comp_waiting and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)
    assert_equal(app.status, "Language server: internal error in completion")
    assert_equal(app.mode, M_NORMAL)
    st = server_state(app)
    assert_equal(st.size(st.get(0, "asked")), 4)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_without_a_server_word_completion_is_unchanged() raises:
    var app = App()
    app.scr.resize(100, 30)
    app.exec(CM_NEW)
    var i = app.top()
    app.wins[i].buf.load(decode("alphabet alpine\nal"))
    app.wins[i].goto(1, 2)
    app.exec(CM_COMPLETE)
    assert_equal(app.mode, M_COMPLETE)
    assert_equal(labels(app), "alphabet alpine alias alignof all ")     # then keywords and builtins
    assert_equal(app.comp_kind[0], -1)
    app.handle(key_event(KEY_ENTER))
    assert_equal(to_str(app.wins[i].buf.line(1)), "alphabet")
    # a single candidate is still inserted directly
    app.wins[i].buf.load(decode("unique_word\nuni"))
    app.wins[i].goto(1, 3)
    app.exec(CM_COMPLETE)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[i].buf.line(1)), "unique_word")
    app.wins[i].buf.load(decode("x\n"))
    app.wins[i].goto(1, 0)
    app.exec(CM_COMPLETE)
    assert_equal(app.status, "Type the start of an identifier, then Ctrl-Space")


def test_popup_shows_kinds_details_and_documentation() raises:
    var dir = scratch("comp5")
    var app = comp_app(dir, "pr\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(0, 2)
    app.exec(CM_COMPLETE)
    wait_popup(app, 3)
    app.handle(key_event(KEY_DOWN))                     # print_line: has documentation
    assert_equal(app.comp_items[app.comp_sel], "print_line")
    app.draw()
    var screen = to_str(app.scr.to_text())
    assert_true(screen.find("var prefix_len") > 0, "kind tag before the name")
    assert_true(screen.find("fn  print_line") > 0)
    assert_true(screen.find("def print_line(s: String)") > 0, "the signature beside it")
    var top_rows = String("")
    for y in range(1, 12):
        top_rows += "\n" + to_str(app.scr.row_text(y))
    assert_true(screen.find("Prints **s** and a line break.") > 0, "documentation panel:" + top_rows)
    assert_true(screen.find("print_line(\"hi\")") > 0)
    assert_true(screen.find("```") < 0, "code fences are not shown")
    assert_true(screen.find("Returns nothing.") > 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


# ---------------------------------------------------------- document sync
def server_state(mut app: App) raises -> Json:
    """Ask the fake server what documents it holds (a JSON object: docs, saved, ranged,
    whole)."""
    var id = app.lsp.conn.request("doc_state", "")
    var deadline = now() + 5000 * MS
    while now() < deadline:
        for m in app.lsp.conn.poll():
            if m.id == id:
                return json_subtree(m.doc, m.result())
            var one = List[RpcMessage]()
            one.append(m.copy())
            app.lsp.handle(one)
    raise Error("the fake server did not answer doc_state")


def sync_app(dir: String, incremental: Bool) raises -> App:
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.lsp_server = ("env FAKE_SYNC=2 " if incremental else String("")) + FAKE
    return app^


def settle(mut app: App):
    """Long enough for the debounce and for the edits to reach the server."""
    run_ticks(app, 450, False)


def test_every_open_mojo_file_is_opened_and_closed_on_the_server() raises:
    var dir = scratch("multi")
    _ = run_system("printf 'a\\n' > '" + dir + "/a.mojo'; printf 'b\\n' > '" + dir + "/b.mojo'; printf 'notes\\n' > '" + dir + "/n.txt'")
    var app = sync_app(dir, False)
    app.open_path(dir + "/a.mojo")
    app.open_path(dir + "/n.txt")
    app.open_path(dir + "/b.mojo")
    app.focus(app.find_editor(dir + "/a.mojo"))
    app.exec(CM_LSP)                                     # started for a.mojo
    run_ticks(app, 5000, True)
    var st = server_state(app)
    assert_equal(st.size(st.get(0, "docs")), 2)          # both Mojo files, not the text file
    assert_equal(st.str(st.get(st.get(0, "docs"), path_to_uri(dir + "/a.mojo"))), "a\n")
    assert_equal(st.str(st.get(st.get(0, "docs"), path_to_uri(dir + "/b.mojo"))), "b\n")
    # a file opened later joins, a closed one leaves
    _ = run_system("printf 'c\\n' > '" + dir + "/c.mojo'")
    app.open_path(dir + "/c.mojo")
    app.remove_window(app.find_editor(dir + "/b.mojo"))
    settle(app)
    st = server_state(app)
    assert_equal(st.size(st.get(0, "docs")), 2)
    assert_true(st.has(st.get(0, "docs"), path_to_uri(dir + "/c.mojo")))
    assert_false(st.has(st.get(0, "docs"), path_to_uri(dir + "/b.mojo")))
    # an untitled window and a large one are left alone
    app.exec(1)
    settle(app)
    assert_equal(len(app.lsp.docs), 2)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_edits_in_any_open_file_reach_the_server_after_the_pause() raises:
    var dir = scratch("edits")
    _ = run_system("printf 'one\\n' > '" + dir + "/a.mojo'; printf 'two\\n' > '" + dir + "/b.mojo'")
    var app = sync_app(dir, False)
    app.open_path(dir + "/a.mojo")
    app.open_path(dir + "/b.mojo")
    app.exec(CM_LSP)                                     # b.mojo is the one being checked
    run_ticks(app, 5000, True)
    var ai = app.find_editor(dir + "/a.mojo")
    app.wins[ai].goto(0, 3)
    app.wins[ai].type_char(33, True)                     # edit the file that is NOT being checked
    app.lsp_tick(now_ns())
    assert_true(app.wins[ai].lsp_due > 0)
    assert_true(app.lsp_change_due > 0)                  # the loop will wake up for it
    var st0 = server_state(app)
    assert_equal(st0.str(st0.get(st0.get(0, "docs"), path_to_uri(dir + "/a.mojo"))), "one\n")   # not yet
    settle(app)
    var st = server_state(app)
    assert_equal(st.str(st.get(st.get(0, "docs"), path_to_uri(dir + "/a.mojo"))), "one!\n")
    assert_equal(app.wins[ai].lsp_due, 0)
    assert_equal(app.lsp_change_due, 0)
    assert_equal(st.int(st.get(0, "whole")), 1)          # this server takes whole documents
    assert_equal(st.int(st.get(0, "ranged")), 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_incremental_sync_keeps_the_server_copy_identical() raises:
    var dir = scratch("incr")
    _ = run_system("printf 'def f():\\n    return 1\\n' > '" + dir + "/a.mojo'")
    var app = sync_app(dir, True)
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    assert_equal(app.lsp.table.sync_kind, SYNC_INCREMENTAL)
    var uri = path_to_uri(dir + "/a.mojo")
    var i = app.find_editor(dir + "/a.mojo")
    assert_true(app.wins[i].buf.track)
    # many random edits with characters of every width, sent in several batches
    var pieces: List[String] = ["x", "é", "日本", "🔥", "\n", "  ", "a🔥b\nc", "\t"]
    var seed = 4242
    for round in range(12):
        for _ in range(15):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            var r = (seed >> 8) % app.wins[i].buf.count()
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            var c = (seed >> 8) % (app.wins[i].buf.llen(r) + 1)
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            var what = (seed >> 8) % 10
            if what < 6:
                seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
                _ = app.wins[i].buf.insert(r, c, decode(pieces[(seed >> 8) % len(pieces)]), 0, 0, 0)
            elif what < 8:
                var r2 = min(app.wins[i].buf.count() - 1, r + what - 6)
                var c2 = min(app.wins[i].buf.llen(r2), c + 3)
                if r2 > r or c2 > c:
                    _ = app.wins[i].buf.delete(r, c, r2, c2, 0, 0, 0)
            elif what == 8:
                _ = app.wins[i].buf.undo()
            else:
                _ = app.wins[i].buf.redo()
        settle(app)
        var st = server_state(app)
        var theirs = st.str(st.get(st.get(0, "docs"), uri))
        assert_equal(theirs, to_str(app.wins[i].buf.all_text()), "after batch " + String(round))
    var fin = server_state(app)
    assert_true(fin.int(fin.get(0, "ranged")) > 50, "edits went as ranges")
    assert_equal(fin.int(fin.get(0, "whole")), 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_whole_text_is_sent_when_the_edits_cannot_be_listed() raises:
    var dir = scratch("lost")
    _ = run_system("printf 'x\\n' > '" + dir + "/a.mojo'")
    var app = sync_app(dir, True)
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    var uri = path_to_uri(dir + "/a.mojo")
    var i = app.find_editor(dir + "/a.mojo")
    # more single edits than are remembered
    for k in range(2100):
        _ = app.wins[i].buf.insert(0, 0, decode("y"), 0, 0, 0)
    assert_true(app.wins[i].buf.changes_lost)
    settle(app)
    var st = server_state(app)
    assert_equal(st.str(st.get(st.get(0, "docs"), uri)), to_str(app.wins[i].buf.all_text()))
    assert_equal(st.int(st.get(0, "whole")), 1)
    assert_false(app.wins[i].buf.changes_lost)           # and recording starts again
    # a reload replaces the text: also sent whole
    _ = run_system("printf 'fresh content\\nline 2\\n' > '" + dir + "/a.mojo'")
    app.reload_from_disk(i)
    settle(app)
    st = server_state(app)
    assert_equal(st.str(st.get(st.get(0, "docs"), uri)), "fresh content\nline 2\n")
    # ordinary typing afterwards goes as ranges again
    app.wins[i].goto(0, 0)
    app.wins[i].type_char(35, True)
    settle(app)
    st = server_state(app)
    assert_equal(st.str(st.get(st.get(0, "docs"), uri)), "#fresh content\nline 2\n")
    assert_true(st.int(st.get(0, "ranged")) >= 1)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_save_flushes_pending_edits_and_notifies() raises:
    var dir = scratch("save")
    _ = run_system("printf 'x\\n' > '" + dir + "/a.mojo'")
    var app = sync_app(dir, True)
    app.open_path(dir + "/a.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    var uri = path_to_uri(dir + "/a.mojo")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(0, 1)
    app.wins[i].type_char(121, True)
    app.exec(CM_SAVE)                                    # before the pause is over
    var st = server_state(app)
    assert_equal(st.str(st.get(st.get(0, "docs"), uri)), "xy\n")     # the edit arrived first
    assert_equal(st.size(st.get(0, "saved")), 1)
    assert_equal(st.str(st.at(st.get(0, "saved"), 0)), uri)
    assert_equal(app.wins[i].lsp_due, 0)
    # a server that did not ask for save notifications gets none
    app.lsp_stop()
    var plain = sync_app(dir, False)
    plain.open_path(dir + "/a.mojo")
    plain.exec(CM_LSP)
    run_ticks(plain, 5000, True)
    plain.wins[plain.top()].type_char(122, True)
    plain.exec(CM_SAVE)
    var st2 = server_state(plain)
    assert_equal(st2.size(st2.get(0, "saved")), 0)
    assert_equal(st2.str(st2.get(st2.get(0, "docs"), uri)), "zxy\n")
    plain.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_restart_reopens_every_file() raises:
    var dir = scratch("reopen")
    _ = run_system("printf 'a\\n' > '" + dir + "/a.mojo'; printf 'b\\n' > '" + dir + "/b.mojo'")
    var app = sync_app(dir, True)
    app.lsp_restart_base_ms = 100
    app.open_path(dir + "/a.mojo")
    app.open_path(dir + "/b.mojo")
    app.exec(CM_LSP)
    run_ticks(app, 5000, True)
    var bi = app.find_editor(dir + "/b.mojo")
    app.wins[bi].type_char(33, True)
    settle(app)
    _ = app.lsp.conn.request("die", "")
    var t0 = now()
    while not (app.lsp.starts == 2 and app.lsp.state == LSP_READY and len(app.lsp.docs) == 2) and now() - t0 < 8000 * MS:
        run_ticks(app, 30, False)
    settle(app)
    var st = server_state(app)
    assert_equal(st.size(st.get(0, "docs")), 2)
    assert_equal(st.str(st.get(st.get(0, "docs"), path_to_uri(dir + "/b.mojo"))), "!b\n")
    # and edits after the restart are recorded against the new copy
    app.wins[bi].type_char(63, True)
    settle(app)
    st = server_state(app)
    assert_equal(st.str(st.get(st.get(0, "docs"), path_to_uri(dir + "/b.mojo"))), "!?b\n")
    app.lsp_stop()
    assert_false(app.wins[bi].buf.track)
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


def test_real_server_follows_ranged_edits_from_the_editor() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realsync")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'def main():\\n    var x: Int = \"oops\"\\n    print(x)\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var uri = path_to_uri(path)
    var t0 = now()
    while len(app.lsp.diagnostics(uri)) == 0 and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    assert_equal(len(app.lsp.diagnostics(uri)), 1)
    print("      real server sync: " + app.lsp.table.describe()[0])
    # replace "oops" (with its quotes) by 1, as two ordinary editor operations
    var i = app.find_editor(path)
    _ = app.wins[i].buf.delete(1, 17, 1, 23, 0, 0, 0)
    _ = app.wins[i].buf.insert(1, 17, decode("1"), 0, 0, 0)
    assert_equal(to_str(app.wins[i].buf.line(1)), "    var x: Int = 1")
    t0 = now()
    while len(app.lsp.diagnostics(uri)) > 0 and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    assert_equal(len(app.lsp.diagnostics(uri)), 0)       # the server saw the corrected text
    # and an edit that breaks it again, with a wide character before the place
    _ = app.wins[i].buf.insert(0, 0, decode("# 🔥 note\n"), 0, 0, 0)
    _ = app.wins[i].buf.insert(2, 17, decode("\"no\" + "), 0, 0, 0)
    t0 = now()
    while len(app.lsp.diagnostics(uri)) == 0 and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    var d = app.lsp.diagnostics(uri)
    assert_true(len(d) >= 1, "the new error is reported")
    assert_equal(d[0].line, 2)                           # on the line the editor has it on
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_real_server_completes_members_after_a_dot() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realcomp")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'from std.collections import List\\n\\ndef main():\\n    var items = List[Int]()\\n    items\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    run_ticks(app, 3000, False)                          # let it analyse the file
    print("      real server: " + app.lsp.table.describe()[2])
    var trig = String("")
    for t in app.lsp.table.completion_triggers:
        trig += t + " "
    print("      real server completion triggers: " + trig)
    if not app.lsp.table.completion:
        print("      (the server offers no completion)")
        app.lsp_stop()
        return
    var i = app.find_editor(path)
    app.wins[i].goto(4, 9)
    app.handle(key_event(46))                            # "."
    if not app.comp_waiting and app.mode != M_COMPLETE:
        # "." is not announced as a trigger: ask by hand
        app.exec(CM_COMPLETE)
    t0 = now()
    while app.mode != M_COMPLETE and (app.comp_waiting or app.comp_req_id >= 0 or app.comp_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    var some = String("")
    for k in range(min(8, len(app.comp_items))):
        some += app.comp_items[k] + " "
    print("      real server offered " + String(len(app.comp_items)) + " items: " + some)
    assert_equal(app.mode, M_COMPLETE)
    var has_append = False
    for k in range(len(app.comp_items)):
        if app.comp_items[k] == "append":
            has_append = True
    assert_true(has_append, "List has an append method")
    app.lsp_stop()
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
