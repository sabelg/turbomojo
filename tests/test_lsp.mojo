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
from appstate import App, now_ns, M_NORMAL, M_COMPLETE, M_HOVER, M_DIALOG, PG_PROBLEMS
from dialog import D_RENAME, D_RENAME_APPLY, D_INFO, D_ACTIONS
from app_nav import plan_edits
from app_lsp import semantic_class
from highlight import C_TEXT, C_TYPE, C_CMT, C_STR, C_DEF, C_PARAM, C_PROP, C_NS
from markdown import md_plain
from window import WK_MESSAGE
from commands import CM_LSP, CM_NONE, CM_SAVE, CM_NEW, CM_NEXTERR, CM_PREVERR, CM_COMPLETE, CM_UNDO, CM_HOVER, CM_SIGNATURE, CM_DEFINITION, CM_REFERENCES, CM_RENAME, CM_ACTIONS, CM_SEMANTIC, CM_HINTS, CM_BACK, CM_FORWARD, CM_GOTO, build_registry
from term import MOD_SHIFT, MOD_ALT, fkey, alt, key_event, KEY_ENTER, KEY_TAB, KEY_UP, KEY_DOWN, KEY_ESC, KEY_PGDN, KEY_LEFT, KEY_HOME
from signals import own_pid
from util import cp_len, decode, to_str, str_bytes, bytes_to_str, env_or, run_system, run_capture, getcwd, toolchain_env, which
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
    for b in frame("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"workspace/someNewThing\",\"params\":{}}"):
        data.append(b)
    # an edit the server wants made is kept for the editor; one without an edit is declined
    for b in frame("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/applyEdit\",\"params\":{\"label\":\"Tidy\",\"edit\":{\"changes\":{}}}}"):
        data.append(b)
    for b in frame("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"workspace/applyEdit\",\"params\":{}}"):
        data.append(b)
    for b in frame("{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":3,\"message\":\"hello from server\"}}"):
        data.append(b)
    c.handle(c.conn.feed(data))
    var sent = frames_sent(c)
    assert_equal(len(sent), 5)
    assert_equal(sent[3], "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"applied\":true}}")
    assert_true(sent[4].find("\"applied\":false") > 0, sent[4])
    assert_equal(len(c.asked_edits), 1)
    assert_equal(c.asked_edits[0], "{\"changes\":{}}")
    assert_equal(c.asked_labels[0], "Tidy")
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
    assert_equal(app.msg_page, PG_PROBLEMS)             # the Problems page of the bottom panel
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
    assert_equal(labels(app), "alphabet alpine alias alignof all alloc ")     # then keywords and builtins
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
    assert_true(screen.find("Prints s and a line break.") > 0, "documentation panel:" + top_rows)
    assert_true(screen.find("**") < 0, "the markup itself is not shown")
    assert_true(screen.find("print_line(\"hi\")") > 0)
    assert_true(screen.find("```") < 0, "code fences are not shown")
    assert_true(screen.find("Returns nothing.") > 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


# -------------------------------------------------------------------- hover
def wait_hover(mut app: App):
    var t0 = now()
    while app.mode != M_HOVER and (app.hover_req_id >= 0 or app.hover_retry_due > 0) and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)


def hover_text(app: App) -> String:
    return md_plain(app.hover_lines)


def test_hover_results_in_every_form() raises:
    var md = json_parse("{\"contents\": {\"kind\": \"markdown\", \"value\": \"**x**\"}}")
    assert_equal(hover_markdown(md, 0), "**x**")
    var plain = json_parse("{\"contents\": \"just text\"}")
    assert_equal(hover_markdown(plain, 0), "just text")
    var marked = json_parse("{\"contents\": {\"language\": \"mojo\", \"value\": \"def f()\"}}")
    assert_equal(hover_markdown(marked, 0), "```mojo\ndef f()\n```")
    var arr = json_parse("{\"contents\": [{\"language\": \"mojo\", \"value\": \"x: Int\"}, \"note\", \"\"]}")
    assert_equal(hover_markdown(arr, 0), "```mojo\nx: Int\n```\n\nnote")
    assert_equal(hover_markdown(json_parse("null"), 0), "")
    assert_equal(hover_markdown(json_parse("{}"), 0), "")
    assert_equal(hover_markdown(json_parse("{\"contents\": []}"), 0), "")


def test_describe_symbol_opens_a_rendered_window() raises:
    var dir = scratch("hover1")
    var app = comp_app(dir, "x = compute(1)\n")
    var i = app.find_editor(dir + "/a.mojo")
    assert_equal(build_registry().find_key(alt(105)), CM_HOVER)
    app.wins[i].goto(0, 6)
    app.handle(key_event(alt(105)))                     # Alt-I
    assert_equal(app.status, "Asking the language server...")
    wait_hover(app)
    assert_equal(app.mode, M_HOVER)
    var t = hover_text(app)
    assert_true(t.startswith("function compute\n"), t)       # the heading, without its marks
    assert_true(t.find("Does important things with care.") > 0, t)      # markup is gone
    assert_true(t.find("def compute(n: Int) -> String") > 0, t)
    assert_true(t.find("**") < 0 and t.find("```") < 0 and t.find("###") < 0, t)
    # drawn below the cursor, with the code in the editor's colours and the link underlined
    app.draw()
    var screen = to_str(app.scr.to_text())
    assert_true(screen.find("function compute") > 0)
    assert_true(screen.find("def compute(n: Int) -> String") > 0)
    var cell = app.wins[i].cursor_cell()
    var found_row = -1
    for y in range(app.scr.h):
        if to_str(app.scr.row_text(y)).find("Does important things") >= 0:
            found_row = y
    assert_true(found_row > cell.r, "the window is below the cursor line")
    var row = to_str(app.scr.row_text(found_row))
    var col = cp_len(String(row[byte=0:row.find("care")]))
    assert_true(app.scr.ul_at(col, found_row) != 0, "the link text is underlined")
    assert_equal(app.scr.fg_at(cp_len(String(row[byte=0:row.find("important")])), found_row), app.pal.doc_bold)
    # Esc closes it and does nothing else
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[i].buf.line(0)), "x = compute(1)")
    # any other key closes it and is then typed as usual
    app.handle(key_event(alt(105)))
    wait_hover(app)
    assert_equal(app.mode, M_HOVER)
    app.handle(key_event(33))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[i].buf.line(0)), "x = co!mpute(1)")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_hover_older_forms_long_texts_and_nothing() raises:
    var dir = scratch("hover2")
    var app = comp_app(dir, "old\nlong\n   \n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(0, 1)
    app.exec(CM_HOVER)
    wait_hover(app)
    assert_equal(hover_text(app), "def old(x: Int) -> Int\n\nPlain words after the code.")
    app.handle(key_event(KEY_ESC))
    # a long text scrolls
    app.wins[i].goto(1, 1)
    app.exec(CM_HOVER)
    wait_hover(app)
    assert_equal(len(app.hover_lines), 42)              # heading, blank, 40 items
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("line 5 of a long") > 0)
    assert_true(to_str(app.scr.to_text()).find("line 30 of a long") < 0)
    app.handle(key_event(KEY_PGDN))
    app.handle(key_event(KEY_PGDN))
    app.handle(key_event(KEY_DOWN))
    assert_equal(app.mode, M_HOVER)
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("line 30 of a long") > 0)
    for _ in range(10):
        app.handle(key_event(KEY_PGDN))
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("line 39 of a long") > 0)     # stops at the end
    app.handle(key_event(KEY_UP))
    assert_equal(app.mode, M_HOVER)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    # nothing under the cursor
    app.wins[i].goto(2, 1)
    app.exec(CM_HOVER)
    wait_hover(app)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "Nothing is known about this place")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_hover_retries_and_is_dropped_when_the_cursor_moves() raises:
    var dir = scratch("hover3")
    var app = comp_app(dir, "# HOVERBUSY\nname other\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(1, 2)
    app.exec(CM_HOVER)
    wait_hover(app)                                     # two refusals, then the answer
    assert_equal(app.mode, M_HOVER)
    assert_true(hover_text(app).find("function name") == 0, hover_text(app))
    app.handle(key_event(KEY_ESC))
    # moving away before the answer: no window pops up later
    app.exec(CM_HOVER)
    app.wins[i].goto(1, 7)
    run_ticks(app, 600, False)
    assert_equal(app.mode, M_NORMAL)
    # without a server the command explains itself
    app.lsp_stop()
    app.exec(CM_HOVER)
    assert_true(app.status.find("Start the language server first") == 0, app.status)
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------------------------------ parameter tip
def wait_sig(mut app: App):
    """Until the question about the call has been answered (or given up)."""
    var t0 = now()
    while (app.sig_req_id >= 0 or app.sig_retry_due > 0) and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)


def type_text(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))


def active_param(app: App) -> String:
    var cps = List[Int]()
    for q in range(app.sigtip.a, app.sigtip.b):
        cps.append(app.sigtip.label[q])
    return to_str(cps)


def test_signature_results_in_every_form() raises:
    # labels as text; the general activeParameter
    var d = json_parse("{\"signatures\": [{\"label\": \"f(a: Int, b: Int)\", \"documentation\": \"Adds.\", \"parameters\": [{\"label\": \"a: Int\"}, {\"label\": \"b: Int\", \"documentation\": {\"kind\": \"markdown\", \"value\": \"the *b*\"}}]}], \"activeSignature\": 0, \"activeParameter\": 1}")
    var s = parse_signature(d, 0)
    assert_true(s.ok)
    assert_equal(to_str(s.label), "f(a: Int, b: Int)")
    assert_equal(s.a, 10)
    assert_equal(s.b, 16)
    assert_equal(s.count, 1)
    assert_equal(s.doc, "the *b*")                       # the parameter's own text wins
    # two parameters with the same text: the second is found after the first
    var same = parse_signature(json_parse("{\"signatures\": [{\"label\": \"g(x, x)\", \"parameters\": [{\"label\": \"x\"}, {\"label\": \"x\"}]}], \"activeParameter\": 1}"), 0)
    assert_equal(same.a, 5)
    assert_equal(same.b, 6)
    # offsets count UTF-16 units; the signature's own activeParameter wins
    var off = parse_signature(json_parse("{\"signatures\": [{\"label\": \"h(a)\"}, {\"label\": \"\\ud83d\\ude00(a, b)\", \"activeParameter\": 1, \"parameters\": [{\"label\": [3, 4]}, {\"label\": [6, 7]}]}], \"activeSignature\": 1, \"activeParameter\": 0}"), 0)
    assert_equal(off.index, 1)
    assert_equal(off.count, 2)
    assert_equal(off.a, 5)
    assert_equal(off.b, 6)
    assert_equal(off.label[off.a], 98)                   # "b"
    # no parameters, or an index past the last one: the signature alone
    var none_active = parse_signature(json_parse("{\"signatures\": [{\"label\": \"k()\"}], \"activeParameter\": 3}"), 0)
    assert_true(none_active.ok)
    assert_equal(none_active.a, none_active.b)
    # a label over several lines becomes one line; a bad activeSignature falls back to the first
    var multi = parse_signature(json_parse("{\"signatures\": [{\"label\": \"m(\\n  a\\n)\"}], \"activeSignature\": 7}"), 0)
    assert_equal(to_str(multi.label), "m(   a )")
    assert_equal(multi.index, 0)
    # nothing to show
    assert_false(parse_signature(json_parse("null"), 0).ok)
    assert_false(parse_signature(json_parse("{\"signatures\": []}"), 0).ok)
    assert_false(parse_signature(json_parse("{}"), 0).ok)
    assert_false(parse_signature(json_parse("{\"signatures\": [{\"label\": \"\"}]}"), 0).ok)


def test_parameter_tip_follows_the_typing() raises:
    var dir = scratch("sig1")
    var app = comp_app(dir, "first line\nx = compute\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(1, 11)
    type_text(app, "(")
    wait_sig(app)
    assert_true(app.sig_on, "the tip opens after the bracket")
    # (this server also completes after "(": its popup is open below, the tip above)
    assert_equal(app.mode, M_COMPLETE)
    assert_equal(to_str(app.sigtip.label), "compute(n: Int, name: String) -> Bool")
    assert_equal(active_param(app), "n: Int")
    # drawn on the row above the cursor, the parameter picked out
    app.draw()
    var cell = app.wins[i].cursor_cell()
    var row = to_str(app.scr.row_text(cell.r - 1))
    var at = row.find("compute(n: Int, name: String) -> Bool")
    assert_true(at >= 0, row)
    var col = cp_len(String(row[byte=0:at]))
    assert_true(app.scr.ul_at(col + 8, cell.r - 1) != 0, "the parameter is underlined")
    assert_equal(app.scr.fg_at(col + 8, cell.r - 1), app.pal.doc_bold)
    assert_equal(app.scr.ul_at(col + 16, cell.r - 1), 0)
    assert_equal(app.scr.fg_at(col + 16, cell.r - 1), app.pal.doc_fg)
    assert_true(to_str(app.scr.row_text(cell.r)).find("x = compute(") >= 0)      # the line itself stays visible
    # the next argument
    type_text(app, "1")
    wait_sig(app)
    assert_equal(active_param(app), "n: Int")
    type_text(app, ",")
    wait_sig(app)
    assert_true(app.sig_on)
    assert_equal(active_param(app), "name: String")
    # going back over the comma: the first parameter again
    app.handle(key_event(KEY_LEFT))
    wait_sig(app)
    assert_equal(active_param(app), "n: Int")
    # what the server was told about each question
    var st = server_state(app)
    var ctx = st.get(0, "sig_contexts")
    assert_equal(st.size(ctx), 4)
    assert_equal(st.int(st.get(st.at(ctx, 0), "triggerKind"), 0), 2)
    assert_equal(st.str(st.get(st.at(ctx, 0), "triggerCharacter")), "(")
    assert_false(st.bool(st.get(st.at(ctx, 0), "isRetrigger")))
    assert_equal(st.int(st.get(st.at(ctx, 1), "triggerKind"), 0), 3)       # the text changed
    assert_true(st.bool(st.get(st.at(ctx, 1), "isRetrigger")))
    assert_equal(st.str(st.get(st.at(ctx, 2), "triggerCharacter")), ",")
    assert_true(st.bool(st.get(st.at(ctx, 2), "isRetrigger")))
    # leaving the call closes the tip
    app.wins[i].goto(1, 13)
    app.handle(key_event(KEY_HOME))
    wait_sig(app)
    assert_false(app.sig_on)
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("-> Bool") < 0)
    # and nothing is asked any more while the cursor moves about
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_UP))
    assert_equal(app.sig_req_id, -1)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_parameter_tip_closes_with_the_bracket_and_with_esc() raises:
    var dir = scratch("sig2")
    var app = comp_app(dir, "x = compute\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].auto_pairs = False
    app.wins[i].goto(0, 11)
    type_text(app, "(1")
    wait_sig(app)
    assert_true(app.sig_on)
    type_text(app, ")")
    wait_sig(app)
    assert_false(app.sig_on, "the call is complete")
    assert_equal(to_str(app.wins[i].buf.line(0)), "x = compute(1)")
    # Esc takes the tip away and nothing else; the next comma brings it back
    app.wins[i].goto(0, 13)
    app.exec(CM_SIGNATURE)
    wait_sig(app)
    assert_true(app.sig_on)
    app.wins[i].ar = 0
    app.wins[i].ac = 12
    app.wins[i].sel = True
    app.sig_col = 13
    app.handle(key_event(KEY_ESC))
    assert_false(app.sig_on)
    assert_true(app.wins[i].sel, "Esc closed the tip, not the selection")
    app.wins[i].sel = False
    type_text(app, ",")
    wait_sig(app)
    assert_true(app.sig_on)
    assert_equal(active_param(app), "name: String")
    # another window in front: no tip there
    app.exec(CM_NEW)
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("-> Bool") < 0)
    type_text(app, "a")
    assert_false(app.sig_on)
    assert_equal(app.sig_req_id, -1)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_parameter_tip_overloads_offsets_documentation_and_long_signatures() raises:
    var dir = scratch("sig3")
    var app = comp_app(dir, "\n\n\n\nover\noffsets\nwide\n")
    var i = app.find_editor(dir + "/a.mojo")
    assert_equal(build_registry().find_key(alt(112)), CM_SIGNATURE)
    # two signatures: the server picks one; the count is shown
    app.wins[i].goto(4, 4)
    type_text(app, "(")
    wait_sig(app)
    assert_equal(app.sigtip.count, 2)
    assert_equal(app.sigtip.index, 0)
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("1/2 over(a: Int)") > 0)
    type_text(app, "1,")
    wait_sig(app)
    assert_equal(app.sigtip.index, 1)
    assert_equal(active_param(app), "a2: Int")
    app.draw()
    var cell = app.wins[i].cursor_cell()
    # two rows: the signature, then its documentation
    assert_true(to_str(app.scr.row_text(cell.r - 2)).find("2/2 over(a: Int, a2: Int)") > 0, to_str(app.scr.row_text(cell.r - 2)))
    assert_true(to_str(app.scr.row_text(cell.r - 1)).find("The two-argument form.") > 0)
    # offsets given in UTF-16 units, after a character outside the BMP
    app.wins[i].goto(5, 7)
    app.handle(key_event(KEY_LEFT))
    wait_sig(app)
    assert_false(app.sig_on)
    app.wins[i].goto(5, 7)
    type_text(app, "(")
    wait_sig(app)
    assert_equal(active_param(app), "first: Int")
    assert_equal(app.sigtip.doc, "")
    type_text(app, "2,")
    wait_sig(app)
    assert_equal(active_param(app), "second: Int")
    assert_equal(app.sigtip.doc, "The **second** one.")
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("The second one.") > 0)       # rendered, not raw
    # a signature wider than the screen is shown around the parameter being typed
    app.wins[i].goto(6, 4)
    app.handle(key_event(KEY_LEFT))
    wait_sig(app)
    app.wins[i].goto(6, 4)
    type_text(app, "(")
    wait_sig(app)
    app.draw()
    cell = app.wins[i].cursor_cell()
    var row = to_str(app.scr.row_text(cell.r - 1))
    assert_true(row.find("wide(argument_number_0: SomeLongTypeName") > 0, row)
    assert_true(row.find("…") > 0, "cut off on the right")
    type_text(app, "1,2,3,4,5,")
    wait_sig(app)
    assert_equal(active_param(app), "argument_number_5: SomeLongTypeName")
    app.draw()
    cell = app.wins[i].cursor_cell()
    row = to_str(app.scr.row_text(cell.r - 1))
    assert_true(row.find("argument_number_5: SomeLongTypeName") > 0, row)
    assert_true(row.find("wide(") < 0, row)
    var at = cp_len(String(row[byte=0:row.find("argument_number_5")]))
    assert_true(app.scr.ul_at(at, cell.r - 1) != 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_parameter_info_command_retries_and_explains_itself() raises:
    var dir = scratch("sig4")
    var app = comp_app(dir, "# SIGBUSY\nrun(1, 2)\nplain\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(1, 6)
    app.handle(key_event(alt(112)))                     # Alt-P
    wait_sig(app)                                       # two refusals, then the answer
    assert_true(app.sig_on)
    assert_equal(active_param(app), "name: String")
    # outside any call the command says so
    app.wins[i].goto(2, 3)
    app.exec(CM_SIGNATURE)
    wait_sig(app)
    assert_false(app.sig_on)
    assert_equal(app.status, "The cursor is not inside a call")
    # typing a bracket where the server knows nothing stays silent
    app.say("")
    app.wins[i].goto(2, 0)
    type_text(app, "(")
    wait_sig(app)
    assert_false(app.sig_on)
    assert_equal(app.status, "")
    # a server without the feature, and no server at all
    app.lsp.table.signature_help = False
    app.exec(CM_SIGNATURE)
    assert_equal(app.status, "This language server does not describe parameters")
    app.lsp_stop()
    app.exec(CM_SIGNATURE)
    assert_true(app.status.find("Start the language server first") == 0, app.status)
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------------- go to definition, jump list
def wait_def(mut app: App):
    var t0 = now()
    while (app.def_req_id >= 0 or app.def_retry_due > 0) and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)


def at(app: App) -> String:
    """Where the cursor is: file name:row:col (0-based)."""
    var t = app.top()
    return app.wins[t].title + ":" + String(app.wins[t].cr) + ":" + String(app.wins[t].cc)


def test_location_results_in_every_form() raises:
    var one = parse_locations(json_parse("{\"uri\": \"file:///p/a.mojo\", \"range\": {\"start\": {\"line\": 3, \"character\": 7}, \"end\": {\"line\": 3, \"character\": 9}}}"), 0)
    assert_equal(len(one), 1)
    assert_equal(one[0].path, "/p/a.mojo")
    assert_equal(one[0].row, 3)
    assert_equal(one[0].col16, 7)
    # a list, with a repeat and a place that is not a file
    var many = parse_locations(json_parse("[{\"uri\": \"file:///p/a.mojo\", \"range\": {\"start\": {\"line\": 1, \"character\": 0}}}, {\"uri\": \"file:///p/a.mojo\", \"range\": {\"start\": {\"line\": 1, \"character\": 0}}}, {\"uri\": \"untitled:x\", \"range\": {\"start\": {\"line\": 0, \"character\": 0}}}, {\"uri\": \"file:///p/b%20c.mojo\", \"range\": {\"start\": {\"line\": 9, \"character\": 2}}}]"), 0)
    assert_equal(len(many), 2)
    assert_equal(many[1].path, "/p/b c.mojo")
    assert_equal(many[1].row, 9)
    # links: the name's own range is preferred, the whole range is the fallback
    var links = parse_locations(json_parse("[{\"targetUri\": \"file:///p/a.mojo\", \"targetRange\": {\"start\": {\"line\": 4, \"character\": 0}}, \"targetSelectionRange\": {\"start\": {\"line\": 5, \"character\": 8}}}, {\"targetUri\": \"file:///p/b.mojo\", \"targetRange\": {\"start\": {\"line\": 6, \"character\": 1}}}]"), 0)
    assert_equal(len(links), 2)
    assert_equal(links[0].row, 5)
    assert_equal(links[0].col16, 8)
    assert_equal(links[1].row, 6)
    # nothing
    assert_equal(len(parse_locations(json_parse("null"), 0)), 0)
    assert_equal(len(parse_locations(json_parse("[]"), 0)), 0)
    assert_equal(len(parse_locations(json_parse("[{\"uri\": \"file:///p/a.mojo\"}]"), 0)), 0)


def test_go_to_definition_and_back_and_forward() raises:
    var dir = scratch("def1")
    var app = comp_app(dir, "def helper():\n    pass\n\nx = helper()\ny = 2\n")
    var i = app.find_editor(dir + "/a.mojo")
    var reg = build_registry()
    assert_equal(reg.find_key(fkey(12)), CM_DEFINITION)
    assert_equal(reg.find_key(alt(44)), CM_BACK)
    assert_equal(reg.find_key(alt(46)), CM_FORWARD)
    app.wins[i].goto(3, 6)
    app.handle(key_event(fkey(12)))
    assert_equal(app.status, "Asking the language server...")
    wait_def(app)
    assert_equal(at(app), "a.mojo:0:4")                  # on the name, not on "def"
    assert_equal(app.status, "a.mojo:1")
    app.handle(key_event(alt(44)))                      # Alt-,
    assert_equal(at(app), "a.mojo:3:6")
    app.handle(key_event(alt(46)))                      # Alt-.
    assert_equal(at(app), "a.mojo:0:4")
    app.exec(CM_FORWARD)
    assert_equal(app.status, "No later place to go forward to")
    assert_equal(at(app), "a.mojo:0:4")
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:3:6")
    app.exec(CM_BACK)
    assert_equal(app.status, "No earlier place to go back to")
    assert_equal(at(app), "a.mojo:3:6")
    # asking on the definition itself stays there and says so
    app.wins[i].goto(0, 5)
    app.exec(CM_DEFINITION)
    wait_def(app)
    assert_equal(at(app), "a.mojo:0:4")
    assert_equal(app.status, "This is the definition")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_definition_in_another_file_and_several_definitions() raises:
    var dir = scratch("def2")
    with open(dir + "/other.mojo", "w") as f:
        f.write("# other\n\ndef ext():\n    pass\n")
    var app = comp_app(dir, "ext()\nmulti()\n\"\U0001F600\"; def multi(): pass\nif x:\n    def multi(a): pass\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(0, 1)
    app.exec(CM_DEFINITION)
    wait_def(app)
    assert_equal(at(app), "other.mojo:2:4")              # opened, cursor on the name
    assert_equal(app.status, "other.mojo:3")
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:0:1")
    app.exec(CM_FORWARD)
    assert_equal(at(app), "other.mojo:2:4")
    app.exec(CM_BACK)
    # two definitions: listed in the Message window, the first one shown
    app.wins[app.top()].goto(1, 2)
    app.exec(CM_DEFINITION)
    wait_def(app)
    assert_equal(at(app), "a.mojo:2:9")                  # UTF-16 column 10 is character 9 here
    assert_true(app.status.find("Definition 1 of 2") == 0, app.status)
    var mi = app.msg_index()
    assert_true(mi >= 0)
    assert_equal(to_str(app.wins[mi].buf.line(0)), "Definitions")
    assert_equal(to_str(app.wins[mi].buf.line(1)), "a.mojo:3:10: \"\U0001F600\"; def multi(): pass")
    assert_equal(to_str(app.wins[mi].buf.line(2)), "a.mojo:5:9: def multi(a): pass")
    assert_equal(to_str(app.wins[mi].buf.line(3)), "2 places in 1 file")
    app.exec(CM_NEXTERR)
    assert_equal(at(app), "a.mojo:4:8")
    # each of these steps can be undone with Back
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:2:9")
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:1:2")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_definition_not_found_retries_and_moved_cursor() raises:
    var dir = scratch("def3")
    var app = comp_app(dir, "# DEFBUSY\ndef known(): pass\nknown()\nunknown()\ngone()\nweb()\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(2, 2)
    app.exec(CM_DEFINITION)
    wait_def(app)                                       # two refusals, then the answer
    assert_equal(at(app), "a.mojo:1:4")
    app.wins[i].goto(3, 2)
    app.exec(CM_DEFINITION)
    wait_def(app)
    assert_equal(app.status, "No definition found for this place")
    assert_equal(at(app), "a.mojo:3:2")
    app.wins[i].goto(4, 2)
    app.exec(CM_DEFINITION)
    wait_def(app)
    assert_equal(app.status, "The definition is in a file that cannot be opened")
    assert_equal(at(app), "a.mojo:4:2")
    app.wins[i].goto(5, 1)
    app.exec(CM_DEFINITION)
    wait_def(app)
    assert_equal(app.status, "No definition found for this place")
    # the failures left nothing in the jump list
    var before = len(app.jumps)
    assert_equal(before, 1)
    # the cursor moved before the answer came: stay where the user went
    app.wins[i].goto(2, 2)
    app.exec(CM_DEFINITION)
    app.wins[i].goto(5, 0)
    run_ticks(app, 400, False)
    assert_equal(at(app), "a.mojo:5:0")
    assert_equal(len(app.jumps), before)
    # a server without the feature, and no server
    app.lsp.table.definition = False
    app.exec(CM_DEFINITION)
    assert_equal(app.status, "This language server does not find definitions")
    app.lsp_stop()
    app.exec(CM_DEFINITION)
    assert_true(app.status.find("Start the language server first") == 0, app.status)
    _ = run_system("rm -rf '" + dir + "'")


def test_jump_list_rules() raises:
    var dir = scratch("jumps")
    var body = String("")
    for k in range(300):
        body += "line " + String(k) + "\n"
    with open(dir + "/a.mojo", "w") as f:
        f.write(body)
    with open(dir + "/b.mojo", "w") as f:
        f.write(body)
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(dir + "/a.mojo")
    var i = app.find_editor(dir + "/a.mojo")
    # Go to line number is a jump
    app.wins[i].goto(10, 3)
    app.exec(CM_GOTO)
    type_text(app, "200")
    app.handle(key_event(KEY_ENTER))
    assert_equal(at(app), "a.mojo:199:0")
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:10:3")
    # going somewhere new after going back forgets the places ahead
    app.jump_mark()
    app.wins[i].goto(50, 0)
    app.exec(CM_FORWARD)
    assert_equal(app.status, "No later place to go forward to")
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:10:3")
    app.exec(CM_FORWARD)
    assert_equal(at(app), "a.mojo:50:0")
    # across files, and a file closed in between is opened again
    app.jump_mark()
    app.open_path(dir + "/b.mojo")
    app.wins[app.top()].goto(7, 1)
    app.jump_mark()
    app.wins[app.top()].goto(90, 0)
    app.exec(CM_BACK)
    assert_equal(at(app), "b.mojo:7:1")
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:50:0")
    app.exec(CM_FORWARD)
    app.exec(CM_FORWARD)
    assert_equal(at(app), "b.mojo:90:0")
    # a file that no longer exists is skipped
    app.jump_mark()
    app.open_path(dir + "/a.mojo")
    app.wins[app.top()].goto(120, 0)
    var bi = app.find_editor(dir + "/b.mojo")
    app.focus(bi)
    app.close_window(app.top(), 0)
    _ = run_system("rm '" + dir + "/b.mojo'")
    assert_equal(at(app), "a.mojo:120:0")
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:50:0")                 # both b.mojo places were passed over
    # two marks on one line make one entry; the list is bounded
    app.jumps.clear()
    app.jump_at = 0
    app.wins[app.top()].goto(5, 0)
    app.jump_mark()
    app.wins[app.top()].goto(5, 4)
    app.jump_mark()
    assert_equal(len(app.jumps), 1)
    assert_equal(app.jumps[0].col, 4)
    for k in range(150):
        app.wins[app.top()].goto(k, 0)
        app.jump_mark()
    assert_equal(len(app.jumps), 100)
    assert_equal(app.jumps[99].row, 149)
    # an untitled window is never recorded
    app.exec(CM_NEW)
    app.jump_mark()
    assert_equal(len(app.jumps), 100)
    _ = run_system("rm -rf '" + dir + "'")


# -------------------------------------------------------- find references
def wait_ref(mut app: App):
    var t0 = now()
    while (app.ref_req_id >= 0 or app.ref_retry_due > 0) and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)


def msg_lines(app: App) -> String:
    """The Message window's text, lines joined with " | "."""
    var mi = app.msg_index()
    if mi < 0:
        return "(no Message window)"
    var s = String("")
    for r in range(app.wins[mi].buf.count()):
        if r > 0:
            s += " | "
        s += to_str(app.wins[mi].buf.line(r))
    return s


def test_find_references_lists_every_use() raises:
    var dir = scratch("ref1")
    var app = comp_app(dir, "def helper():\n    pass\nx = helper()\n\"\U0001F600\"; helper()\n")
    var i = app.find_editor(dir + "/a.mojo")
    assert_equal(build_registry().find_key(fkey(12) | MOD_SHIFT), CM_REFERENCES)
    app.wins[i].goto(2, 6)
    app.handle(key_event(fkey(12) | MOD_SHIFT))
    assert_equal(app.status, "Asking the language server...")
    wait_ref(app)
    # in the order of the file although the server sent them backwards; columns count characters
    assert_equal(msg_lines(app), "References to helper | a.mojo:1:5: def helper(): | a.mojo:3:5: x = helper() | a.mojo:4:6: \"\U0001F600\"; helper() | 3 places in 1 file")
    assert_true(app.status.find("3 places in 1 file - ") == 0, app.status)
    assert_equal(at(app), "a.mojo:2:6")                  # the cursor stays; the editor keeps the keyboard
    # the list is marked at the use the cursor is on, and Next message goes on from there
    assert_equal(app.wins[app.msg_index()].cr, 2)
    app.exec(CM_NEXTERR)
    assert_equal(at(app), "a.mojo:3:5")
    app.exec(CM_NEXTERR)
    assert_equal(at(app), "a.mojo:0:4")                  # round to the first
    app.exec(CM_PREVERR)
    assert_equal(at(app), "a.mojo:3:5")
    # each step can be taken back
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:0:4")
    app.exec(CM_BACK)
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:2:6")
    # the declaration was asked for
    var st = server_state(app)
    assert_true(st.bool(st.get(st.at(st.get(0, "ref_contexts"), 0), "includeDeclaration")))
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_references_across_files() raises:
    var dir = scratch("ref2")
    with open(dir + "/other.mojo", "w") as f:
        f.write("# other\n    shared(1)\n\nz = shared(shared(2))\n")
    var app = comp_app(dir, "pass\ndef shared(n): pass\n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(1, 10)                              # right after the name
    app.exec(CM_REFERENCES)
    wait_ref(app)
    # this file first, then the other one (read from disk, not opened); leading blanks dropped
    assert_equal(msg_lines(app), "References to shared | a.mojo:2:5: def shared(n): pass | other.mojo:2:5: shared(1) | other.mojo:4:5: z = shared(shared(2)) | other.mojo:4:12: z = shared(shared(2)) | 4 places in 2 files")
    assert_equal(app.find_editor(dir + "/other.mojo"), -1)
    app.exec(CM_NEXTERR)
    assert_equal(at(app), "other.mojo:1:4")
    app.exec(CM_BACK)
    assert_equal(at(app), "a.mojo:1:10")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_references_none_retries_and_moved_cursor() raises:
    var dir = scratch("ref3")
    var app = comp_app(dir, "# REFBUSY\nvalue = 1\nprint(value)\nnowhere\n   \n")
    var i = app.find_editor(dir + "/a.mojo")
    app.wins[i].goto(2, 8)
    app.exec(CM_REFERENCES)
    wait_ref(app)                                       # two refusals, then the answer
    assert_true(msg_lines(app).find("References to value | a.mojo:2:1: value = 1 | a.mojo:3:7: print(value) | 2 places in 1 file") == 0, msg_lines(app))
    var listed = msg_lines(app)
    app.wins[i].goto(3, 2)
    app.exec(CM_REFERENCES)
    wait_ref(app)
    assert_equal(app.status, "No references found for this place")
    app.wins[i].goto(4, 1)
    app.exec(CM_REFERENCES)
    wait_ref(app)
    assert_equal(app.status, "No references found for this place")
    assert_equal(msg_lines(app), listed)                 # the earlier list is still there
    # the cursor moved before the answer came: the answer is dropped
    app.wins[i].goto(3, 2)
    app.say("")
    app.wins[i].goto(2, 8)
    app.exec(CM_REFERENCES)
    app.wins[i].goto(0, 0)
    run_ticks(app, 400, False)
    assert_equal(app.status, "Asking the language server...")
    assert_equal(app.ref_req_id, -1)
    app.lsp.table.references = False
    app.exec(CM_REFERENCES)
    assert_equal(app.status, "This language server does not find references")
    app.lsp_stop()
    app.exec(CM_REFERENCES)
    assert_true(app.status.find("Start the language server first") == 0, app.status)
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------------------------------------ rename
def wait_ren(mut app: App):
    var t0 = now()
    while (app.ren_req_id >= 0 or app.ren_retry_due > 0) and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)


def buf_text(app: App, path: String) -> String:
    """A window's text, lines joined with " | "."""
    var wi = app.find_editor(path)
    if wi < 0:
        return "(not open)"
    var s = String("")
    for r in range(app.wins[wi].buf.count()):
        if r > 0:
            s += " | "
        s += to_str(app.wins[wi].buf.line(r))
    return s


def rename_to(mut app: App, name: String) raises:
    """Run the command, type the new name into the dialog, press Enter, wait."""
    app.exec(CM_RENAME)
    wait_ren(app)
    assert_equal(app.mode, M_DIALOG, app.status)
    assert_equal(app.dlg.kind, D_RENAME)
    type_text(app, name)
    app.handle(key_event(KEY_ENTER))
    wait_ren(app)


def test_workspace_edit_and_prepare_rename_forms() raises:
    var a = parse_workspace_edit(json_parse("{\"changes\": {\"file:///p/a.mojo\": [{\"range\": {\"start\": {\"line\": 1, \"character\": 2}, \"end\": {\"line\": 1, \"character\": 5}}, \"newText\": \"xy\"}, {\"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 0}}, \"newText\": \"\"}], \"file:///p/b.mojo\": [{\"range\": {\"start\": {\"line\": 7, \"character\": 0}, \"end\": {\"line\": 8, \"character\": 1}}, \"newText\": \"q\"}]}}"), 0)
    assert_equal(a.problem, "")
    assert_equal(len(a.files), 2)
    assert_equal(a.count(), 3)
    assert_equal(a.files[0].path, "/p/a.mojo")
    assert_equal(a.files[0].edits[0].c2, 5)
    assert_equal(a.files[0].edits[0].text, "xy")
    assert_equal(a.files[1].edits[0].r2, 8)
    # documentChanges wins over changes; two entries for one file are put together
    var d = parse_workspace_edit(json_parse("{\"changes\": {\"file:///p/zzz.mojo\": []}, \"documentChanges\": [{\"textDocument\": {\"uri\": \"file:///p/a.mojo\", \"version\": 4}, \"edits\": [{\"range\": {\"start\": {\"line\": 1, \"character\": 2}, \"end\": {\"line\": 1, \"character\": 5}}, \"newText\": \"n\"}]}, {\"textDocument\": {\"uri\": \"file:///p/a.mojo\", \"version\": 4}, \"edits\": [{\"range\": {\"start\": {\"line\": 3, \"character\": 0}, \"end\": {\"line\": 3, \"character\": 1}}, \"newText\": \"m\"}]}]}"), 0)
    assert_equal(d.problem, "")
    assert_equal(len(d.files), 1)
    assert_equal(len(d.files[0].edits), 2)
    # what is not done is refused as a whole
    var ops = parse_workspace_edit(json_parse("{\"documentChanges\": [{\"kind\": \"create\", \"uri\": \"file:///p/new.mojo\"}]}"), 0)
    assert_equal(ops.problem, "it wants to create a file")
    var odd = parse_workspace_edit(json_parse("{\"changes\": {\"untitled:1\": [{\"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 0}}, \"newText\": \"x\"}]}}"), 0)
    assert_true(odd.problem.find("not a file") > 0, odd.problem)
    var back = parse_workspace_edit(json_parse("{\"changes\": {\"file:///p/a.mojo\": [{\"range\": {\"start\": {\"line\": 2, \"character\": 5}, \"end\": {\"line\": 2, \"character\": 1}}, \"newText\": \"x\"}]}}"), 0)
    assert_true(back.problem.find("impossible range") > 0, back.problem)
    assert_equal(parse_workspace_edit(json_parse("null"), 0).count(), 0)
    # the Mojo server keys `changes` by plain path instead of URI: taken as the file it means
    var bare = parse_workspace_edit(json_parse("{\"changes\": {\"/p/a b.mojo\": [{\"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}, \"newText\": \"x\"}]}}"), 0)
    assert_equal(bare.problem, "")
    assert_equal(bare.files[0].path, "/p/a b.mojo")
    assert_equal(parse_workspace_edit(json_parse("{}"), 0).count(), 0)
    # prepareRename: a range, a range with a placeholder, "do it yourself", no
    var r1 = parse_prepare_rename(json_parse("{\"start\": {\"line\": 2, \"character\": 4}, \"end\": {\"line\": 2, \"character\": 9}}"), 0)
    assert_true(r1.ok and r1.known)
    assert_equal(r1.c1, 4)
    assert_equal(r1.c2, 9)
    var r2 = parse_prepare_rename(json_parse("{\"range\": {\"start\": {\"line\": 2, \"character\": 4}, \"end\": {\"line\": 2, \"character\": 9}}, \"placeholder\": \"abc\"}"), 0)
    assert_true(r2.ok and r2.known)
    assert_equal(r2.placeholder, "abc")
    var r3 = parse_prepare_rename(json_parse("{\"defaultBehavior\": true}"), 0)
    assert_true(r3.ok)
    assert_false(r3.known)
    assert_false(parse_prepare_rename(json_parse("null"), 0).ok)


def test_edits_are_checked_and_ordered() raises:
    var lines = List[List[Int]]()
    lines.append(decode("ab \U0001F600 cd"))
    lines.append(decode("second"))
    var edits = List[LspEdit]()
    edits.append(LspEdit(0, 0, 0, 2, "X"))
    edits.append(LspEdit(1, 0, 1, 6, "Y\r\nZ"))
    edits.append(LspEdit(0, 6, 0, 8, "W"))               # "cd": UTF-16 6..8 is characters 5..7
    edits.append(LspEdit(2, 0, 2, 0, "end"))             # the line after the last: the very end
    var plan = plan_edits(lines, edits)
    assert_equal(len(plan), 4)
    assert_equal(plan[0].r1, 1)                          # last place first
    assert_equal(plan[0].c1, 6)
    assert_equal(to_str(plan[0].text), "end")
    assert_equal(to_str(plan[1].text), "Y\nZ")           # CR dropped
    assert_equal(plan[2].c1, 5)
    assert_equal(plan[2].c2, 7)
    assert_equal(plan[3].c2, 2)
    # touching edits are fine, overlapping ones are not
    var touch = List[LspEdit]()
    touch.append(LspEdit(0, 0, 0, 2, "X"))
    touch.append(LspEdit(0, 2, 0, 3, "Y"))
    assert_equal(len(plan_edits(lines, touch)), 2)
    var over = List[LspEdit]()
    over.append(LspEdit(0, 0, 0, 2, "X"))
    over.append(LspEdit(0, 1, 0, 3, "Y"))
    var said = String("")
    try:
        _ = plan_edits(lines, over)
    except e:
        said = String(e)
    assert_equal(said, "two edits overlap")
    var far = List[LspEdit]()
    far.append(LspEdit(2, 1, 2, 2, "X"))
    said = ""
    try:
        _ = plan_edits(lines, far)
    except e:
        said = String(e)
    assert_equal(said, "an edit lies beyond the end of the text")


def test_rename_in_one_file_is_one_undo_step() raises:
    var dir = scratch("ren1")
    var app = comp_app(dir, "def helper():\n    pass\nx = helper() + helper()\n")
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    assert_equal(build_registry().find_key(fkey(2) | MOD_SHIFT), CM_RENAME)
    app.wins[i].goto(2, 6)
    app.handle(key_event(fkey(2) | MOD_SHIFT))
    assert_equal(app.status, "Asking the language server...")
    wait_ren(app)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_RENAME)
    assert_equal(app.dlg.field_text(0), "helper")        # the present name is offered
    type_text(app, "assist")                            # typing replaces it
    app.handle(key_event(KEY_ENTER))
    wait_ren(app)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(buf_text(app, path), "def assist(): |     pass | x = assist() + assist() | ")
    assert_equal(app.status, "Renamed helper to assist: 3 changes in 1 file")
    assert_equal(at(app), "a.mojo:2:6")                  # still on the name
    assert_true(app.wins[i].buf.modified)
    assert_equal(msg_lines(app), "Rename helper to assist | a.mojo:1:5: def helper(): | a.mojo:3:5: x = helper() + helper() | a.mojo:3:16: x = helper() + helper() | 3 places in 1 file")
    # the server is told about the new text
    run_ticks(app, 600, False)
    var st = server_state(app)
    assert_true(st.str(st.get(st.get(0, "docs"), path_to_uri(path))).find("x = assist() + assist()") > 0)
    # one Undo takes all of it back
    app.exec(CM_UNDO)
    assert_equal(buf_text(app, path), "def helper(): |     pass | x = helper() + helper() | ")
    # a shorter name before the cursor on its line moves the cursor with the text
    app.wins[i].goto(2, 21)                              # in the second helper()
    rename_to(app, "h")
    assert_equal(buf_text(app, path), "def h(): |     pass | x = h() + h() | ")
    assert_equal(at(app), "a.mojo:2:11")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_rename_across_files_asks_first() raises:
    var dir = scratch("ren2")
    with open(dir + "/other.mojo", "w") as f:
        f.write("# other\nshared(1)\nz = shared(shared(2))\n")
    var app = comp_app(dir, "pass\ndef shared(n): pass\n")
    var path = dir + "/a.mojo"
    var other = dir + "/other.mojo"
    var i = app.find_editor(path)
    app.wins[i].goto(1, 6)
    rename_to(app, "common")
    # nothing is changed before the answer to the question
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_RENAME_APPLY)
    assert_equal(app.dlg.lines[0], "Rename shared to common:")
    assert_equal(app.dlg.lines[1], "4 changes in 2 files (listed in the Message window)")
    assert_equal(app.dlg.lines[2], "1 file will be opened; nothing is saved until you save")
    assert_equal(buf_text(app, path), "pass | def shared(n): pass | ")
    assert_equal(app.find_editor(other), -1)
    assert_true(msg_lines(app).find("Rename shared to common | a.mojo:2:5: def shared(n): pass | other.mojo:2:1: shared(1) | ") == 0, msg_lines(app))
    # Cancel (Esc): still nothing
    app.handle(key_event(KEY_ESC))
    assert_equal(app.status, "Rename cancelled - nothing was changed")
    assert_equal(buf_text(app, path), "pass | def shared(n): pass | ")
    assert_equal(app.find_editor(other), -1)
    # again, and Apply
    rename_to(app, "common")
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "Renamed shared to common: 4 changes in 2 files - not saved yet")
    assert_equal(buf_text(app, path), "pass | def common(n): pass | ")
    assert_equal(buf_text(app, other), "# other | common(1) | z = common(common(2)) | ")
    assert_equal(at(app), "a.mojo:1:6")                  # back in the window the rename started in
    assert_true(app.wins[app.find_editor(other)].buf.modified)
    assert_equal(read_text(other), "# other\nshared(1)\nz = shared(shared(2))\n")       # the disk is untouched
    # each file has its own undo step
    app.focus(app.find_editor(other))
    app.exec(CM_UNDO)
    assert_equal(buf_text(app, other), "# other | shared(1) | z = shared(shared(2)) | ")
    assert_equal(buf_text(app, path), "pass | def common(n): pass | ")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_rename_refusals_and_bad_answers_change_nothing() raises:
    var dir = scratch("ren3")
    var body = "fixed = 1\nbad = 2\nvalue = 3\nmover = 4\nclash = 5\nfar = 6\nnothing = 7\n   \n"
    var app = comp_app(dir, body)
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    var before = buf_text(app, path)
    app.wins[i].goto(0, 2)
    app.exec(CM_RENAME)
    wait_ren(app)
    assert_equal(app.status, "This cannot be renamed")
    assert_equal(app.mode, M_NORMAL)
    app.wins[i].goto(7, 1)
    app.exec(CM_RENAME)
    wait_ren(app)
    assert_equal(app.status, "This cannot be renamed")
    app.wins[i].goto(1, 1)
    app.exec(CM_RENAME)
    wait_ren(app)
    assert_equal(app.status, "Language server: cannot rename this")
    # the same name, an empty name, a name the server refuses
    app.wins[i].goto(2, 1)
    rename_to(app, "value")
    assert_equal(app.status, "The name was not changed")
    rename_to(app, "  ")
    assert_equal(app.status, "The name was not changed")
    rename_to(app, "1bad")
    assert_equal(app.status, "Language server: invalid name")
    # answers that cannot be applied
    app.wins[i].goto(3, 1)
    rename_to(app, "m2")
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_INFO)
    assert_equal(app.dlg.lines[0], "The server's answer cannot be applied: it wants to rename a file")
    app.handle(key_event(KEY_ENTER))
    app.wins[i].goto(4, 1)
    rename_to(app, "c2")
    assert_equal(app.dlg.lines[0], "The server's answer cannot be applied: two edits overlap")
    app.handle(key_event(KEY_ENTER))
    app.wins[i].goto(5, 1)
    rename_to(app, "f2")
    assert_equal(app.dlg.lines[0], "The server's answer cannot be applied: an edit lies beyond the end of the text")
    app.handle(key_event(KEY_ENTER))
    app.wins[i].goto(6, 1)
    rename_to(app, "n2")
    assert_equal(app.status, "The server found nothing to rename")
    assert_equal(buf_text(app, path), before)
    assert_false(app.wins[i].buf.modified)
    # a server that renames but does not answer "can this be renamed": the word at the cursor
    app.lsp.table.prepare_rename = False
    app.wins[i].goto(2, 5)                               # right after "value"
    app.exec(CM_RENAME)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.field_text(0), "value")
    app.handle(key_event(KEY_ESC))
    app.wins[i].goto(7, 1)
    app.exec(CM_RENAME)
    assert_equal(app.status, "There is no name at the cursor to rename")
    app.lsp.table.rename = False
    app.exec(CM_RENAME)
    assert_equal(app.status, "This language server does not rename symbols")
    app.lsp_stop()
    app.exec(CM_RENAME)
    assert_true(app.status.find("Start the language server first") == 0, app.status)
    _ = run_system("rm -rf '" + dir + "'")


def test_rename_placeholder_document_changes_and_retries() raises:
    var dir = scratch("ren4")
    var app = comp_app(dir, "# DOCCHANGES RENBUSY\nph = 1\nprint(ph, \"\U0001F600\", ph)\n")
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    app.wins[i].goto(1, 0)
    app.exec(CM_RENAME)
    wait_ren(app)
    assert_equal(app.dlg.field_text(0), "placeholder_name")      # what the server proposes
    type_text(app, "q")
    app.handle(key_event(KEY_ENTER))
    wait_ren(app)                                       # refused twice, then answered
    assert_equal(buf_text(app, path), "# DOCCHANGES RENBUSY | q = 1 | print(q, \"\U0001F600\", q) | ")
    var st = server_state(app)
    assert_equal(st.size(st.get(0, "renames")), 3)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_rename_is_dropped_when_the_text_changed_meanwhile() raises:
    var dir = scratch("ren5")
    var app = comp_app(dir, "# RENSLOW\nname = 1\nprint(name)\n")
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    app.wins[i].goto(1, 2)
    app.exec(CM_RENAME)
    wait_ren(app)
    type_text(app, "label")
    app.handle(key_event(KEY_ENTER))
    run_ticks(app, 200, False)
    assert_true(app.ren_req_id >= 0, "the server is still thinking")
    # an edit far from the cursor while waiting
    _ = app.wins[i].buf.insert(2, 0, decode("# "), 1, 2, app.wins[i].new_group())
    _ = app.lsp.conn.request("release", "")
    wait_ren(app)
    assert_equal(app.status, "The text changed while the server was working - try again")
    assert_equal(buf_text(app, path), "# RENSLOW | name = 1 | # print(name) | ")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------------------------------ code actions
def wait_act(mut app: App):
    var t0 = now()
    while (app.act_req_id >= 0 or app.act_retry_due > 0) and now() - t0 < 5000 * MS:
        run_ticks(app, 20, False)


def offered(app: App) -> String:
    """The lines of the open Quick Fix list, joined with " | "."""
    var s = String("")
    for k in range(len(app.dlg.items)):
        if k > 0:
            s += " | "
        s += app.dlg.items[k]
    return s


def test_code_action_answers_in_every_form() raises:
    var d = json_parse("[{\"title\": \"Run it\", \"command\": \"x.run\", \"arguments\": [1, \"a\"]}, {\"title\": \"Refactor\", \"kind\": \"refactor.inline\", \"disabled\": {\"reason\": \"no\"}}, {\"title\": \"Fix B\", \"kind\": \"quickfix\", \"edit\": {\"changes\": {}}, \"command\": {\"title\": \"t\", \"command\": \"x.after\"}}, {\"title\": \"Fix A\", \"kind\": \"quickfix\", \"isPreferred\": true, \"edit\": null}, {\"kind\": \"quickfix\"}]")
    var a = parse_code_actions(d, 0)
    assert_equal(len(a), 4)                              # the one without a title is left out
    # the preferred one first, then fixes, then the rest in the server's order
    assert_equal(a[0].title, "Fix A")
    assert_true(a[0].preferred)
    assert_equal(a[0].edit_json, "")                     # null is "no edit yet"
    assert_equal(a[1].title, "Fix B")
    assert_true(a[1].edit_json.byte_length() > 0)
    assert_equal(a[1].command, "x.after")
    assert_equal(a[2].title, "Run it")                   # a bare command
    assert_equal(a[2].command, "x.run")
    assert_equal(a[2].args_json, "[1,\"a\"]")
    assert_equal(a[3].disabled, "no")
    assert_equal(len(parse_code_actions(json_parse("null"), 0)), 0)
    assert_equal(len(parse_code_actions(json_parse("[]"), 0)), 0)


def test_quick_fix_list_and_applying_a_fix() raises:
    var dir = scratch("act1")
    var app = comp_app(dir, "x = 1\ny = typo BUG\nz = 3\n")
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    run_ticks(app, 600, False)                          # the problem on line 2 has been reported
    assert_equal(build_registry().find_key(KEY_ENTER | MOD_ALT), CM_ACTIONS)
    app.wins[i].goto(1, 2)
    app.handle(key_event(KEY_ENTER | MOD_ALT))
    assert_equal(app.status, "Asking the language server...")
    wait_act(app)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_ACTIONS)
    assert_equal(offered(app), "Change 'typo' to 'type' | Add a comment | Extract to a function  (nothing is selected) | Organise imports")
    # the server was told the place and given back its own report of the problem there
    var st = server_state(app)
    var asked = st.at(st.get(0, "actions_asked"), 0)
    assert_equal(st.int(st.path(asked, "range/start/line"), -1), 1)
    assert_equal(st.int(st.path(asked, "range/start/character"), -1), 2)
    assert_equal(st.size(st.get(asked, "codes")), 1)
    assert_equal(st.str(st.at(st.get(asked, "codes"), 0)), "E1")
    # Enter takes the first (preferred) one
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(buf_text(app, path), "x = 1 | y = type BUG | z = 3 | ")
    assert_equal(app.status, "Applied: Change 'typo' to 'type': 1 change in 1 file")
    app.exec(CM_UNDO)
    assert_equal(buf_text(app, path), "x = 1 | y = typo BUG | z = 3 | ")
    # an action that cannot be used says why and changes nothing
    app.exec(CM_ACTIONS)
    wait_act(app)
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "Not available: nothing is selected")
    assert_equal(buf_text(app, path), "x = 1 | y = typo BUG | z = 3 | ")
    # Esc closes the list
    app.exec(CM_ACTIONS)
    wait_act(app)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(buf_text(app, path), "x = 1 | y = typo BUG | z = 3 | ")
    # a selection is sent as the range
    app.wins[i].goto(1, 0)
    app.wins[i].ar = 1
    app.wins[i].ac = 8
    app.wins[i].sel = True
    app.exec(CM_ACTIONS)
    wait_act(app)
    app.handle(key_event(KEY_ESC))
    st = server_state(app)
    asked = st.at(st.get(0, "actions_asked"), st.size(st.get(0, "actions_asked")) - 1)
    assert_equal(st.int(st.path(asked, "range/start/character"), -1), 0)
    assert_equal(st.int(st.path(asked, "range/end/character"), -1), 8)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_actions_that_run_a_server_command() raises:
    var dir = scratch("act2")
    var app = comp_app(dir, "y = typo\nz = both\n")
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    # a bare command: the server answers with an edit of its own
    app.wins[i].goto(0, 1)
    app.exec(CM_ACTIONS)
    wait_act(app)
    for _ in range(3):
        app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "Running: Organise imports")
    run_ticks(app, 600, False)
    assert_equal(buf_text(app, path), "# organised | y = typo | z = both | ")
    assert_equal(app.status, "Applied: Organise imports: 1 change in 1 file")
    var st = server_state(app)
    assert_equal(st.str(st.get(st.at(st.get(0, "executed"), 0), "command")), "fake.organise")
    assert_true(st.bool(st.get(st.at(st.get(0, "client_answers"), 0), "applied")))
    # an action with an edit and a command: the edit first, then the command
    app.wins[i].goto(2, 5)
    app.exec(CM_ACTIONS)
    wait_act(app)
    assert_equal(offered(app), "Finish and organise")
    app.handle(key_event(KEY_ENTER))
    assert_equal(buf_text(app, path), "# organised | y = typo | z = done | ")
    run_ticks(app, 600, False)
    assert_equal(buf_text(app, path), "# organised | # organised | y = typo | z = done | ")
    st = server_state(app)
    assert_equal(st.size(st.get(0, "executed")), 2)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_action_resolved_on_demand_and_across_files() raises:
    var dir = scratch("act3")
    with open(dir + "/other.mojo", "w") as f:
        f.write("wide = 1\n")
    var app = comp_app(dir, "a = lazy\nprint(wide)\n")
    var path = dir + "/a.mojo"
    var other = dir + "/other.mojo"
    var i = app.find_editor(path)
    # the edit is fetched only when the action is chosen
    app.wins[i].goto(0, 0)
    app.exec(CM_ACTIONS)
    wait_act(app)
    assert_equal(offered(app), "Make it eager")
    var st = server_state(app)
    assert_equal(st.int(st.get(0, "resolved_actions"), -1), 0)
    app.handle(key_event(KEY_ENTER))
    wait_act(app)
    assert_equal(buf_text(app, path), "a = eager | print(wide) | ")
    assert_equal(app.status, "Applied: Make it eager: 1 change in 1 file")
    # an action that changes another file asks first, like a rename
    app.wins[i].goto(1, 7)
    app.exec(CM_ACTIONS)
    wait_act(app)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_RENAME_APPLY)
    assert_equal(app.dlg.lines[0], "Rename wide everywhere:")
    assert_equal(app.dlg.lines[1], "2 changes in 2 files (listed in the Message window)")
    assert_equal(buf_text(app, path), "a = eager | print(wide) | ")
    app.handle(key_event(KEY_ESC))
    assert_equal(app.status, "Quick fix cancelled - nothing was changed")
    assert_equal(app.find_editor(other), -1)
    app.exec(CM_ACTIONS)
    wait_act(app)
    app.handle(key_event(KEY_ENTER))
    app.handle(key_event(KEY_ENTER))
    assert_equal(buf_text(app, path), "a = eager | print(broad) | ")
    assert_equal(buf_text(app, other), "broad = 1 | ")
    assert_equal(app.status, "Applied: Rename wide everywhere: 2 changes in 2 files - not saved yet")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_no_actions_retries_and_missing_server() raises:
    var dir = scratch("act4")
    var app = comp_app(dir, "# ACTBUSY\nplain = 1\nnullanswer\nempty = 2\ny = typo\n")
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    var before = buf_text(app, path)
    app.wins[i].goto(4, 0)
    app.exec(CM_ACTIONS)
    wait_act(app)                                       # refused twice, then answered
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.status, "4 actions offered")
    app.handle(key_event(KEY_ESC))
    app.wins[i].goto(1, 0)
    app.exec(CM_ACTIONS)
    wait_act(app)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "No quick fixes or actions here")
    app.wins[i].goto(2, 0)
    app.exec(CM_ACTIONS)
    wait_act(app)
    assert_equal(app.status, "No quick fixes or actions here")
    app.wins[i].goto(3, 0)
    app.exec(CM_ACTIONS)
    wait_act(app)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "Quick fix: the server sent no changes")
    # the cursor moved before the list came: no list
    app.wins[i].goto(4, 0)
    app.exec(CM_ACTIONS)
    app.wins[i].goto(0, 0)
    run_ticks(app, 400, False)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(buf_text(app, path), before)
    app.lsp.table.code_action = False
    app.exec(CM_ACTIONS)
    assert_equal(app.status, "This language server offers no quick fixes")
    app.lsp_stop()
    app.exec(CM_ACTIONS)
    assert_true(app.status.find("Start the language server first") == 0, app.status)
    _ = run_system("rm -rf '" + dir + "'")


# ------------------------------------- semantic colours and inlay hints
def wait_decor(mut app: App):
    """Until the colours and hints for the present text have arrived."""
    var t0 = now()
    while now() - t0 < 5000 * MS:
        run_ticks(app, 30, False)
        var busy = app.sem_req_id >= 0 or app.hint_req_id >= 0
        for i in range(len(app.wins)):
            if app.lsp_wants(i) and ((app.semantic_on and app.wins[i].sem_version != app.wins[i].buf.version) or (app.hints_on and app.wins[i].hint_version != app.wins[i].buf.version)):
                busy = True
        if not busy:
            return


def fg_of(mut app: App, row: Int, word: String) -> Int:
    """The text colour of the first character of `word` on a file row, as drawn."""
    app.draw()
    var t = app.top()
    var y = app.wins[t].y + 1 + row - app.wins[t].top
    var text = to_str(app.scr.row_text(y))
    var at = text.find(word)
    if at < 0:
        return -1
    return app.scr.fg_at(cp_len(String(text[byte=0:at])), y)


def test_semantic_and_inlay_answers() raises:
    # relative positions made absolute: line, start, length, type
    var t = parse_semantic(json_parse("{\"resultId\": \"1\", \"data\": [0, 4, 5, 2, 0,  0, 6, 1, 1, 0,  2, 3, 4, 0, 0,  0, 5, 2, 3, 1]}"), 0)
    assert_equal(len(t), 16)
    var want = [0, 4, 5, 2, 0, 10, 1, 1, 2, 3, 4, 0, 2, 8, 2, 3]
    for k in range(16):
        assert_equal(t[k], want[k])
    assert_equal(len(parse_semantic(json_parse("{\"data\": [0, 4, 5]}"), 0)), 0)             # not groups of five
    assert_equal(len(parse_semantic(json_parse("{\"data\": [0, -4, 5, 0, 0]}"), 0)), 0)
    assert_equal(len(parse_semantic(json_parse("null"), 0)), 0)
    assert_equal(len(parse_semantic(json_parse("{}"), 0)), 0)
    var h = parse_inlay(json_parse("[{\"position\": {\"line\": 2, \"character\": 7}, \"label\": \": Int\", \"kind\": 1}, {\"position\": {\"line\": 3, \"character\": 0}, \"label\": [{\"value\": \"n\"}, {\"value\": \":\", \"tooltip\": \"x\"}]}, {\"label\": \"lost\"}, {\"position\": {\"line\": 1, \"character\": 1}, \"label\": \"\"}]"), 0)
    assert_equal(len(h), 2)
    assert_equal(h[0].row, 2)
    assert_equal(h[0].col16, 7)
    assert_equal(h[0].label, ": Int")
    assert_equal(h[0].kind, 1)
    assert_equal(h[1].label, "n:")
    assert_equal(h[1].kind, 0)
    assert_equal(len(parse_inlay(json_parse("null"), 0)), 0)
    # token types this editor has colours for
    assert_equal(semantic_class("parameter"), C_PARAM)
    assert_equal(semantic_class("method"), C_DEF)
    assert_equal(semantic_class("class"), C_TYPE)
    assert_equal(semantic_class("property"), C_PROP)
    assert_equal(semantic_class("namespace"), C_NS)
    assert_equal(semantic_class("variable"), -1)         # the lexer's colour stays
    assert_equal(semantic_class("somethingNew"), -1)


def test_semantic_colours_are_laid_over_the_lexer() raises:
    var dir = scratch("sem1")
    var app = comp_app(dir, "x = compute(arg_one, mod.field)\n# compute(arg_two) \"\U0001F600\" Thing\ny = \"\U0001F600\" + helper(Thing, weird_one)\n")
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    wait_decor(app)
    assert_true(len(app.wins[i].buf.sem) > 0, "colours arrived")
    var p = app.pal.copy()
    assert_equal(fg_of(app, 0, "compute"), p.syn[C_DEF])         # a call: the lexer alone has no colour for it
    assert_equal(fg_of(app, 0, "arg_one"), p.syn[C_PARAM])
    assert_equal(fg_of(app, 0, "mod"), p.syn[C_NS])
    assert_equal(fg_of(app, 0, "field"), p.syn[C_PROP])
    # the server also sent tokens inside the comment: the comment stays a comment
    assert_equal(fg_of(app, 1, "compute"), p.syn[C_CMT])
    assert_equal(fg_of(app, 1, "Thing"), p.syn[C_CMT])
    # columns after a character outside the BMP are right
    assert_equal(fg_of(app, 2, "helper"), p.syn[C_DEF])
    assert_equal(fg_of(app, 2, "Thing"), p.syn[C_TYPE])
    assert_equal(fg_of(app, 2, "(Thing"), p.syn[7])               # the bracket before it is a symbol
    # a token type without a colour here leaves the lexer's
    assert_equal(fg_of(app, 2, "weird_one"), p.syn[C_TEXT])
    # typing a line above: the colours move with the text at once, before any answer
    app.wins[i].goto(0, 0)
    type_text(app, "q")
    app.handle(key_event(KEY_ENTER))
    assert_equal(fg_of(app, 1, "compute"), p.syn[C_DEF])
    assert_equal(fg_of(app, 1, "arg_one"), p.syn[C_PARAM])
    assert_equal(fg_of(app, 3, "helper"), p.syn[C_DEF])
    # and they are asked for again once the server has the new text
    var st = server_state(app)
    var asked = st.int(st.get(0, "sem_asked"), 0)
    wait_decor(app)
    st = server_state(app)
    assert_true(st.int(st.get(0, "sem_asked"), 0) > asked, "asked again after the edit")
    assert_equal(fg_of(app, 1, "arg_one"), p.syn[C_PARAM])
    # nothing is asked while nothing changes
    asked = st.int(st.get(0, "sem_asked"), 0)
    run_ticks(app, 500, False)
    st = server_state(app)
    assert_equal(st.int(st.get(0, "sem_asked"), 0), asked)
    # Options > Semantic colours off: the lexer's colours; on: back
    app.exec(CM_SEMANTIC)
    assert_equal(app.status, "Semantic colours off")
    assert_equal(fg_of(app, 1, "compute"), p.syn[C_TEXT])
    run_ticks(app, 300, False)
    assert_equal(len(app.wins[i].buf.sem), 0)
    app.exec(CM_SEMANTIC)
    wait_decor(app)
    assert_equal(fg_of(app, 1, "compute"), p.syn[C_DEF])
    # the server gone: its colours go too
    app.lsp_stop()
    assert_equal(fg_of(app, 1, "compute"), p.syn[C_TEXT])
    _ = run_system("rm -rf '" + dir + "'")


def test_semantic_colours_are_asked_again_after_a_refusal() raises:
    var dir = scratch("sem2")
    var app = comp_app(dir, "# SEMBUSY\nx = compute(1)\n")
    var i = app.find_editor(dir + "/a.mojo")
    var t0 = now()
    while len(app.wins[i].buf.sem) == 0 and now() - t0 < 5000 * MS:
        run_ticks(app, 50, False)
    assert_equal(fg_of(app, 1, "compute"), app.pal.syn[C_DEF])
    var st = server_state(app)
    assert_equal(st.int(st.get(0, "sem_asked"), 0), 3)   # refused twice, then answered
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_inlay_hints_after_the_line() raises:
    var dir = scratch("hint1")
    var app = comp_app(dir, "var total = 4\nx = call(total, \"n\")\nplain = 1\n")
    var path = dir + "/a.mojo"
    var i = app.find_editor(path)
    wait_decor(app)
    assert_equal(len(app.wins[i].buf.hints), 3)
    app.draw()
    var y0 = app.wins[i].y + 1
    assert_true(to_str(app.scr.row_text(y0)).find("var total = 4  ◂ total: Int") > 0, to_str(app.scr.row_text(y0)))
    assert_true(to_str(app.scr.row_text(y0 + 1)).find("x = call(total, \"n\")  ◂ count: total, name: \"n\"") > 0, to_str(app.scr.row_text(y0 + 1)))
    assert_true(to_str(app.scr.row_text(y0 + 2)).find("◂") < 0)
    # drawn as a note, not as text: in the comment colour, and not part of the file
    var row = to_str(app.scr.row_text(y0))
    assert_equal(app.scr.fg_at(cp_len(String(row[byte=0:row.find("◂")])), y0), app.pal.syn[C_CMT])
    assert_equal(to_str(app.wins[i].buf.line(0)), "var total = 4")
    # editing a line hides its note until the server has answered for the new text
    app.wins[i].goto(0, 13)
    type_text(app, "2")
    app.draw()
    assert_true(to_str(app.scr.row_text(y0)).find("◂") < 0)
    assert_true(to_str(app.scr.row_text(y0 + 1)).find("◂ count: total") > 0)
    wait_decor(app)
    app.draw()
    assert_true(to_str(app.scr.row_text(y0)).find("var total = 42  ◂ total: Int") > 0)
    # Options > Inlay hints
    app.exec(CM_HINTS)
    assert_equal(app.status, "Inlay hints off")
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("◂") < 0)
    var st = server_state(app)
    var asked = st.int(st.get(0, "hints_asked"), 0)
    type_text(app, "1")
    run_ticks(app, 600, False)
    st = server_state(app)
    assert_equal(st.int(st.get(0, "hints_asked"), 0), asked)     # off means not asked either
    app.exec(CM_HINTS)
    wait_decor(app)
    app.draw()
    assert_true(to_str(app.scr.row_text(y0)).find("◂ total: Int") > 0)
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
    for _ in range(2100):
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


def test_real_server_describes_a_symbol() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realhover")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'def twice(n: Int) -> Int:\\n    \"\"\"Returns n times two.\"\"\"\\n    return n * 2\\n\\ndef main():\\n    print(twice(4))\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    run_ticks(app, 2000, False)
    var i = app.find_editor(path)
    app.wins[i].goto(5, 12)                              # on "twice" in the call
    app.exec(CM_HOVER)
    t0 = now()
    while app.mode != M_HOVER and (app.hover_req_id >= 0 or app.hover_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    var t = md_plain(app.hover_lines)
    var shown = String("")
    for c in decode(t):
        shown += " / " if c == 10 else to_str([c])
    print("      real server hover: " + shown)
    assert_equal(app.mode, M_HOVER)
    assert_true(t.find("twice") >= 0, t)
    assert_true(t.find("Returns n times two.") >= 0, t)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_real_server_parameter_tip() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realsig")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'def scale(value: Int, factor: Int) -> Int:\\n    return value * factor\\n\\ndef main():\\n    print(scale)\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    run_ticks(app, 2000, False)
    var trig = String("")
    for t in app.lsp.table.signature_triggers:
        trig += t + " "
    print("      real server signature help: " + ("yes" if app.lsp.table.signature_help else "no") + ", triggers: " + trig)
    if not app.lsp.table.signature_help:
        app.lsp_stop()
        return
    var i = app.find_editor(path)
    app.wins[i].goto(4, 15)                              # after "scale"
    type_text(app, "(3, ")
    t0 = now()
    while (app.sig_req_id >= 0 or app.sig_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    print("      real server tip: " + to_str(app.sigtip.label) + "  [" + active_param(app) + "]")
    assert_true(app.sig_on)
    assert_true(to_str(app.sigtip.label).find("scale") >= 0)
    assert_true(active_param(app).find("factor") >= 0, active_param(app))
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_real_server_goes_to_a_definition() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realdef")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'def twice(n: Int) -> Int:\\n    return n * 2\\n\\ndef main():\\n    print(twice(4))\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    run_ticks(app, 2000, False)
    var i = app.find_editor(path)
    app.wins[i].goto(4, 12)                              # on "twice" in the call
    app.exec(CM_DEFINITION)
    t0 = now()
    while (app.def_req_id >= 0 or app.def_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    print("      real server definition: " + at(app) + "  (" + app.status + ")")
    assert_equal(at(app), "t.mojo:0:4")
    app.exec(CM_BACK)
    assert_equal(at(app), "t.mojo:4:12")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_real_server_finds_references() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realref")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'def twice(n: Int) -> Int:\\n    return n * 2\\n\\ndef main():\\n    print(twice(4))\\n    print(twice(5))\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    run_ticks(app, 2000, False)
    var i = app.find_editor(path)
    app.wins[i].goto(4, 12)                              # on "twice" in the first call
    app.exec(CM_REFERENCES)
    t0 = now()
    while (app.ref_req_id >= 0 or app.ref_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    print("      real server references: " + msg_lines(app))
    assert_true(msg_lines(app).find("References to twice | ") == 0, app.status)
    assert_true(msg_lines(app).find("t.mojo:5:11: print(twice(4))") > 0)
    assert_true(msg_lines(app).find("t.mojo:6:11: print(twice(5))") > 0)
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_real_server_renames_a_local_variable() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realren")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'def twice(n: Int) -> Int:\\n    var total = n * 2\\n    return total\\n\\ndef main():\\n    print(twice(4))\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    run_ticks(app, 2000, False)
    print("      real server rename: " + ("yes" if app.lsp.table.rename else "no") + ", asks first: " + ("yes" if app.lsp.table.prepare_rename else "no"))
    var i = app.find_editor(path)
    app.wins[i].goto(2, 13)                              # on "total" in the return
    app.exec(CM_RENAME)
    t0 = now()
    while (app.ren_req_id >= 0 or app.ren_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    assert_equal(app.mode, M_DIALOG, app.status)
    assert_equal(app.dlg.field_text(0), "total")
    type_text(app, "result")
    app.handle(key_event(KEY_ENTER))
    t0 = now()
    while (app.ren_req_id >= 0 or app.ren_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    print("      real server rename result: " + app.status)
    assert_equal(buf_text(app, path), "def twice(n: Int) -> Int: |     var result = n * 2 |     return result |  | def main(): |     print(twice(4)) | ")
    # this server (Mojo 1.2) renames local variables only; a function is refused with
    # its own message and nothing changes
    var before = buf_text(app, path)
    run_ticks(app, 1500, False)
    app.wins[i].goto(5, 12)                              # on "twice" in the call
    app.exec(CM_RENAME)
    type_text(app, "double")
    app.handle(key_event(KEY_ENTER))
    t0 = now()
    while (app.ren_req_id >= 0 or app.ren_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    print("      real server on renaming a function: " + app.status)
    assert_equal(app.mode, M_NORMAL)
    if buf_text(app, path) == before:
        assert_true(app.status.find("Language server: ") == 0, app.status)
    else:
        # a newer server that can do it: every use must have changed
        assert_true(buf_text(app, path).find("twice") < 0, buf_text(app, path))
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_real_server_answers_a_code_action_request() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realact")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'def twice(n: Int) -> Int:\\n    return m * 2\\n\\ndef main():\\n    print(twice(4))\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    run_ticks(app, 3000, False)
    var i = app.find_editor(path)
    assert_true(len(app.wins[i].buf.marks) > 0, "the unknown name is reported")
    app.wins[i].goto(1, 11)                              # on the unknown "m"
    app.exec(CM_ACTIONS)
    t0 = now()
    while (app.act_req_id >= 0 or app.act_retry_due > 0) and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    # Mojo 1.2 advertises code actions but offers none for this error; either outcome
    # is a proper answer, an error message from the server is not
    if app.mode == M_DIALOG:
        print("      real server offers: " + offered(app))
        assert_equal(app.dlg.kind, D_ACTIONS)
    else:
        print("      real server code actions: " + app.status)
        assert_equal(app.status, "No quick fixes or actions here")
    app.lsp_stop()
    _ = run_system("rm -rf '" + dir + "'")


def test_real_server_semantic_colours() raises:
    if not have_real_server():
        print("      (skipped: mojo-lsp-server is not on PATH)")
        return
    var dir = scratch("realsem")
    var path = dir + "/t.mojo"
    _ = run_system("printf 'struct Point:\\n    var x: Int\\n\\ndef twice(n: Int) -> Int:\\n    return n * 2\\n\\ndef main():\\n    print(twice(4))\\n' > '" + path + "'")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(path)
    app.exec(CM_LSP)
    var t0 = now()
    while app.lsp.state != LSP_READY and now() - t0 < 30000 * MS:
        run_ticks(app, 50, False)
    t0 = now()
    while len(app.wins[app.find_editor(path)].buf.sem) == 0 and now() - t0 < 10000 * MS:
        run_ticks(app, 50, False)
    var i = app.find_editor(path)                        # (the Message window may have opened meanwhile)
    app.focus(i)
    i = app.find_editor(path)
    var legend = String("")
    for t in app.lsp.table.token_types:
        legend += t + " "
    print("      real server token types: " + legend)
    print("      real server tokens: " + String(len(app.wins[i].buf.sem) // 4) + ", inlay hints: " + String(len(app.wins[i].buf.hints)))
    assert_true(len(app.wins[i].buf.sem) > 0, "the real server sent semantic tokens")
    var p = app.pal.copy()
    # (Mojo 1.2 reports parameters as plain "variable", so they keep the text colour)
    assert_equal(fg_of(app, 4, "n *"), p.syn[C_TEXT])
    assert_equal(fg_of(app, 1, "x:"), p.syn[C_PROP])             # a field
    assert_equal(fg_of(app, 0, "Point"), p.syn[C_TYPE])
    assert_equal(fg_of(app, 7, "twice"), p.syn[C_DEF])           # the call
    assert_equal(fg_of(app, 3, "Int"), p.syn[C_TYPE])
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
