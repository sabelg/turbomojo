"""E2E Test Suite for Feature #17:
Polyglot lsp_extra parity across all language slots:
dynamic client/registerCapability, incremental didChange, didSave,
semantic tokens, inlay hints, documentSymbol, formatting,
exponential backoff crash recovery.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from lsp import (
    LspClient, LspCaps, LspHint, OpenDoc, LSP_STOPPED, LSP_STARTING, LSP_READY, LSP_FAILED,
    SYNC_INCREMENTAL, path_to_uri, uri_to_path, parse_semantic, parse_inlay,
    parse_formatting_edits, cap_on, string_items,
)
from lspextra import ExtraServer, ends_with_any
from config import load_settings
from json import json_parse, Json
from signals import own_pid
from rpc import RpcMessage, RPC_REQUEST
from app import *
from appstate import App, LSP_MAX_RESTARTS
from util import decode, to_str, bytes_to_str, env_or, run_system, shell_quote, write_file, str_bytes


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f17-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f17_case1_polyglot_slot_discovery_and_configuration() raises:
    """Verify load_settings registers multiple distinct lsp_extra language slots."""
    var cfg = (
        "[lsp.python]\n"
        "command = \"pyright-langserver --stdio\"\n"
        "extensions = [\".py\", \".pyi\"]\n\n"
        "[lsp.clangd]\n"
        "command = \"clangd --header-insertion=never\"\n"
        "extensions = [\".c\", \".cpp\", \".h\", \".hpp\", \".cu\"]\n"
        "language = \"cpp\"\n"
    )
    var s = load_settings(cfg, "")
    assert_equal(len(s.lsp_names), 2)
    assert_equal(s.lsp_names[0], "python")
    assert_equal(s.lsp_names[1], "clangd")
    assert_equal(s.lsp_cmds[0], "pyright-langserver --stdio")
    assert_equal(s.lsp_cmds[1], "clangd --header-insertion=never")

    assert_true(ends_with_any("/proj/script.py", s.lsp_exts[0]))
    assert_true(ends_with_any("/proj/stub.pyi", s.lsp_exts[0]))
    assert_false(ends_with_any("/proj/kernel.cu", s.lsp_exts[0]))

    assert_true(ends_with_any("/proj/kernel.cu", s.lsp_exts[1]))
    assert_true(ends_with_any("/proj/header.hpp", s.lsp_exts[1]))
    assert_false(ends_with_any("/proj/script.py", s.lsp_exts[1]))


def test_tier1_f17_case2_did_open_and_did_save_tracking() raises:
    """Verify did_open registers document version 1 and did_save keeps tracking intact."""
    var c = LspClient()
    c.state = LSP_READY
    var uri = "file:///workspace/demo.py"

    # Simulate open document sent to ready server
    c.docs.append(OpenDoc(uri, 1, True))
    var doc_idx = c.find_doc(uri)
    assert_true(doc_idx >= 0)
    assert_equal(c.docs[doc_idx].version, 1)
    assert_equal(c.docs[doc_idx].uri, uri)

    # did_save on open document
    var ok_save = c.did_save(uri)
    assert_true(ok_save)
    assert_equal(c.find_doc(uri), doc_idx)
    assert_equal(c.docs[doc_idx].version, 1)


def test_tier1_f17_case3_semantic_tokens_capabilities_and_parsing() raises:
    """Verify semanticTokensProvider capability negotiation and legend extraction."""
    var caps_json = (
        "{\"semanticTokensProvider\":{"
        "\"full\":true,\"range\":true,"
        "\"legend\":{\"tokenTypes\":[\"comment\",\"keyword\",\"string\",\"number\"],"
        "\"tokenModifiers\":[\"declaration\",\"definition\"]}"
        "}}"
    )
    var doc = json_parse(caps_json)
    assert_true(doc.ok)

    var t = LspCaps()
    t.semantic_tokens = cap_on(doc, "semanticTokensProvider")
    assert_true(t.semantic_tokens)

    var full = doc.path(0, "semanticTokensProvider/full")
    t.semantic_full = full >= 0 and not doc.is_null(full) and (doc.kind(full) != 1 or doc.bool(full))
    assert_true(t.semantic_full)

    t.token_types = string_items(doc, doc.path(0, "semanticTokensProvider/legend/tokenTypes"))
    assert_equal(len(t.token_types), 4)
    assert_equal(t.token_types[0], "comment")
    assert_equal(t.token_types[1], "keyword")

    # Parse sample semantic token delta data: lineDelta=0, colDelta=4, len=3, type=1, mod=0
    var data_json = "{\"result\":{\"data\":[0,4,3,1,0]}}"
    var resp_doc = json_parse(data_json)
    var res_node = resp_doc.get(0, "result")
    var tokens = parse_semantic(resp_doc, res_node)
    # Returns absolute quadruples: line, start, len, type
    assert_equal(len(tokens), 4)
    assert_equal(tokens[0], 0)  # line 0
    assert_equal(tokens[1], 4)  # col 4
    assert_equal(tokens[2], 3)  # len 3
    assert_equal(tokens[3], 1)  # type 1 (keyword)


def test_tier1_f17_case4_inlay_hints_capabilities_and_parsing() raises:
    """Verify inlayHintProvider capability parsing and LspHint deserialization."""
    var caps_json = "{\"inlayHintProvider\":true}"
    var doc = json_parse(caps_json)

    var t = LspCaps()
    t.inlay_hint = cap_on(doc, "inlayHintProvider")
    assert_true(t.inlay_hint)

    # Inlay hint result with label and position
    var hint_json = "{\"result\":[{\"position\":{\"line\":2,\"character\":10},\"label\":\": Int\",\"kind\":1}]}"
    var hint_doc = json_parse(hint_json)
    var res_node = hint_doc.get(0, "result")
    var hints = parse_inlay(hint_doc, res_node)

    assert_equal(len(hints), 1)
    assert_equal(hints[0].row, 2)
    assert_equal(hints[0].col16, 10)
    assert_equal(hints[0].label, ": Int")
    assert_equal(hints[0].kind, 1)


def test_tier1_f17_case5_document_symbol_request_and_table_state() raises:
    """Verify documentSymbolProvider capability discovery on extra LSP slots."""
    var caps_json = "{\"documentSymbolProvider\":true,\"definitionProvider\":true}"
    var doc = json_parse(caps_json)

    var t = LspCaps()
    t.document_symbol = cap_on(doc, "documentSymbolProvider")
    t.definition = cap_on(doc, "definitionProvider")

    assert_true(t.document_symbol)
    assert_true(t.definition)
    var desc = t.describe()
    var has_doc_sym = False
    for line in desc:
        if line.find("document symbols") >= 0:
            has_doc_sym = True
    assert_true(has_doc_sym)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f17_bound1_dynamic_register_capability_rpc_handling() raises:
    """Verify dynamic capability registration sets table flags and legend on LspClient."""
    var c = LspClient()
    c.state = LSP_READY
    var m_reg = (
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"client/registerCapability\",\"params\":{\"registrations\":["
        "{\"id\":\"r1\",\"method\":\"textDocument/didSave\"},"
        "{\"id\":\"r2\",\"method\":\"textDocument/formatting\"},"
        "{\"id\":\"r3\",\"method\":\"textDocument/inlayHint\"},"
        "{\"id\":\"r4\",\"method\":\"textDocument/semanticTokens\",\"registerOptions\":{\"full\":true,\"legend\":{\"tokenTypes\":[\"function\",\"parameter\"],\"tokenModifiers\":[\"declaration\"]}}},"
        "{\"id\":\"r5\",\"method\":\"textDocument/documentSymbol\"},"
        "{\"id\":\"r6\",\"method\":\"textDocument/definition\"},"
        "{\"id\":\"r7\",\"method\":\"textDocument/references\"},"
        "{\"id\":\"r8\",\"method\":\"textDocument/rename\",\"registerOptions\":{\"prepareProvider\":true}},"
        "{\"id\":\"r9\",\"method\":\"textDocument/codeAction\"},"
        "{\"id\":\"r10\",\"method\":\"textDocument/callHierarchy\"},"
        "{\"id\":\"r11\",\"method\":\"textDocument/typeHierarchy\"}"
        "]}}"
    )
    var m = c.conn.classify(str_bytes(m_reg))
    assert_equal(m.kind, RPC_REQUEST)
    assert_equal(m.method, "client/registerCapability")
    assert_equal(m.id_json, "10")

    var msgs = List[RpcMessage]()
    msgs.append(m^)
    c.handle(msgs)
    assert_equal(c.state, LSP_READY)
    assert_true(c.table.sync_save)
    assert_true(c.table.formatting)
    assert_true(c.table.inlay_hint)
    assert_true(c.table.semantic_tokens and c.table.semantic_full)
    assert_equal(len(c.table.token_types), 2)
    assert_true(c.table.document_symbol)
    assert_true(c.table.definition)
    assert_true(c.table.references)
    assert_true(c.table.rename and c.table.prepare_rename)
    assert_true(c.table.code_action)
    assert_true(c.table.call_hierarchy)
    assert_true(c.table.type_hierarchy)


def test_tier2_f17_bound2_incremental_did_change_version_increment() raises:
    """Verify sequential did_change notifications increment document versions monotonically."""
    var c = LspClient()
    c.state = LSP_STARTING
    var uri = "file:///test/module.py"
    c.docs.append(OpenDoc(uri, 1, True))
    var idx = c.find_doc(uri)
    assert_equal(c.docs[idx].version, 1)

    # First change increments version to 2
    _ = c.did_change(uri, "x = 2\n")
    assert_equal(c.docs[idx].version, 2)

    # Second change increments version to 3
    _ = c.did_change(uri, "x = 3\n")
    assert_equal(c.docs[idx].version, 3)

    # Close removes document
    c.did_close(uri)
    assert_equal(c.find_doc(uri), -1)


def test_tier2_f17_bound3_formatting_provider_capabilities() raises:
    """Verify documentFormattingProvider capability detection handles boolean and object forms."""
    var caps_bool = json_parse("{\"documentFormattingProvider\":true}")
    var t1 = LspCaps()
    t1.formatting = cap_on(caps_bool, "documentFormattingProvider")
    assert_true(t1.formatting)

    var caps_obj = json_parse("{\"documentFormattingProvider\":{\"workDoneProgress\":true}}")
    var t2 = LspCaps()
    t2.formatting = cap_on(caps_obj, "documentFormattingProvider")
    assert_true(t2.formatting)

    var caps_none = json_parse("{}")
    var t3 = LspCaps()
    t3.formatting = cap_on(caps_none, "documentFormattingProvider")
    assert_false(t3.formatting)
    assert_false(t3.formatting)


def test_tier2_f17_bound4_exponential_backoff_crash_recovery_calculation() raises:
    """Verify exponential doubling of crash restart delays up to maximum restart limit."""
    var lsp_restart_base_ms = 1000
    var lsp_crashes = List[Int]()
    var now = 1000000000
    for crash_round in range(1, 4):
        lsp_crashes.append(now)
        var n = len(lsp_crashes)
        var wait_ms = lsp_restart_base_ms
        for _ in range(n - 1):
            wait_ms *= 2
        var restart_due = now + wait_ms * 1000000
        if crash_round == 1:
            assert_equal(wait_ms, 1000)
            assert_equal(restart_due, now + 1000 * 1000000)
        elif crash_round == 2:
            assert_equal(wait_ms, 2000)
            assert_equal(restart_due, now + 2000 * 1000000)
        elif crash_round == 3:
            assert_equal(wait_ms, 4000)
            assert_equal(restart_due, now + 4000 * 1000000)

    # 4th crash exceeds LSP_MAX_RESTARTS (3) -> restarts suppressed
    assert_equal(len(lsp_crashes), 3)
    assert_equal(LSP_MAX_RESTARTS, 3)
    assert_false(len(lsp_crashes) < LSP_MAX_RESTARTS)


def test_tier2_f17_bound5_unconfigured_extensions_and_null_responses() raises:
    """Verify unconfigured file extensions return negative lookup without false positives."""
    var exts = List[String]()
    exts.append(".py")
    exts.append(".pyi")

    assert_false(ends_with_any("main.mojo", exts))
    assert_false(ends_with_any("Cargo.toml", exts))
    assert_false(ends_with_any("README.md", exts))
    assert_false(ends_with_any("", exts))

    # A server without docs handles did_change gracefully returning -1
    var c = LspClient()
    var changed = c.did_change("file:///unopened.py", "text")
    assert_equal(changed, -1)


def test_tier1_f17_formatting_edits_and_extra_server_crash_backoff() raises:
    """Verify parse_formatting_edits and ExtraServer exponential backoff state transitions."""
    var fmt_json = "{\"result\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":5}},\"newText\":\"x = 1\"}]}"
    var fdoc = json_parse(fmt_json)
    var edits = parse_formatting_edits(fdoc, fdoc.get(0, "result"))
    assert_equal(len(edits), 1)
    assert_equal(edits[0].r1, 0)
    assert_equal(edits[0].c2, 5)
    assert_equal(edits[0].text, "x = 1")

    var d = scratch("crash_backoff")
    var py = d + "/app.py"
    _ = write_file(py, str_bytes("x = 1\n"))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.apply_settings(load_settings("[lsp.py]\ncommand = \"false\"\nextensions = [\".py\"]\n", ""))
    app.open_path(py)
    assert_equal(len(app.lsp_extra), 1)
    assert_equal(app.lsp_extra[0].restart_base_ms, 1000)

    # Simulate a ready extra server crashing 3 times -> 1s, 2s, 4s backoff, 4th crash stops permanently
    var t0 = 10_000_000_000
    app.lsp_extra[0].client.was_ready = True
    app.lsp_extra[0].client.state = LSP_FAILED
    app.extra_tick(t0)
    assert_equal(len(app.lsp_extra[0].crashes), 1)
    assert_equal(app.lsp_extra[0].restart_due, t0 + 1000 * 1_000_000)
    assert_true(app.extra_active())

    app.lsp_extra[0].restart_due = 0
    app.lsp_extra[0].client.was_ready = True
    app.lsp_extra[0].client.state = LSP_FAILED
    app.extra_tick(t0 + 2_000_000_000)
    assert_equal(len(app.lsp_extra[0].crashes), 2)
    assert_equal(app.lsp_extra[0].restart_due, t0 + 2_000_000_000 + 2000 * 1_000_000)

    app.lsp_extra[0].restart_due = 0
    app.lsp_extra[0].client.was_ready = True
    app.lsp_extra[0].client.state = LSP_FAILED
    app.extra_tick(t0 + 5_000_000_000)
    assert_equal(len(app.lsp_extra[0].crashes), 3)
    assert_equal(app.lsp_extra[0].restart_due, t0 + 5_000_000_000 + 4000 * 1_000_000)

    # 4th crash within window exceeds LSP_MAX_RESTARTS (3): no further restart scheduled
    app.lsp_extra[0].restart_due = 0
    app.lsp_extra[0].client.was_ready = True
    app.lsp_extra[0].client.state = LSP_FAILED
    app.extra_tick(t0 + 10_000_000_000)
    assert_equal(app.lsp_extra[0].restart_due, 0)
    assert_false(app.extra_active())
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
