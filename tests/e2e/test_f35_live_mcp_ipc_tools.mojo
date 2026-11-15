"""E2E Test Suite for Feature #35:
4 Live MCP & IPC Tools:
- turbomojo_lsp_query (warm LSP definition, references, hover)
- turbomojo_symbol_search (symbol index queries)
- turbomojo_capture_screen (SVG/text live frame capture)
- turbomojo_git_diff (buffer-aware unified diff)
and the underlying atomic file-queue IPC engine.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from screen import Screen
from gitdiff import Side, side_hunks, unified, with_hunk, DiffRow, DR_NEW, DR_OLD, DR_SAME
from svgshot import screen_svg
from ipc import parse_file_loc, FileLoc
from json import json_parse, json_quote, JsonWriter, J_ARR, J_OBJ
from swap import write_bytes_atomic, delete_file, pid_alive
from signals import own_pid
from util import (
    env_or, run_system, run_capture, shell_quote, str_bytes, bytes_to_str, read_file,
    write_file, path_exists, getcwd, decode, to_str,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f35-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def run_mcp_call(method: String, params_json: String) -> String:
    """Dispatches a genuine JSON-RPC 2.0 call to the TurboMojo MCP server scripts/mcp_server.py."""
    var scratch_req = "/tmp/turbomojo-mcp-req-" + String(own_pid()) + ".json"
    var msg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"" + method + "\",\"params\":" + params_json + "}\n"
    _ = write_file(scratch_req, str_bytes(msg))
    var cmd = "cat " + shell_quote(scratch_req) + " | python3 scripts/mcp_server.py"
    var res = run_capture(cmd)
    delete_file(scratch_req)
    return String(bytes_to_str(res.out).strip())


def run_mcp_tool(name: String, args_json: String) -> String:
    """Invokes a specific tool on scripts/mcp_server.py via standard tools/call protocol."""
    var params = "{\"name\":\"" + name + "\",\"arguments\":" + args_json + "}"
    return run_mcp_call("tools/call", params)


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f35_case1_mcp_server_tools_list() raises:
    """Verify MCP tools/list returns all registered TurboMojo production tools."""
    var resp_str = run_mcp_call("tools/list", "{}")
    var doc = json_parse(resp_str)
    assert_true(doc.ok, "Invalid JSON-RPC response: " + doc.error)

    var res = doc.get(0, "result")
    var tools = doc.get(res, "tools")
    assert_true(doc.size(tools) >= 13, "Expected at least 13 tools registered in MCP server")

    var found_cap = False
    var found_sym = False
    var found_diff = False
    var found_lsp = False

    for k in range(doc.size(tools)):
        var t = doc.at(tools, k)
        var name = doc.str(doc.get(t, "name"), "")
        if name == "turbomojo_capture_screen":
            found_cap = True
        elif name == "turbomojo_symbol_search":
            found_sym = True
        elif name == "turbomojo_git_diff":
            found_diff = True
        elif name == "turbomojo_lsp_query":
            found_lsp = True

    assert_true(found_cap, "turbomojo_capture_screen must be registered in TOOLS")
    assert_true(found_sym, "turbomojo_symbol_search must be registered in TOOLS")
    assert_true(found_diff, "turbomojo_git_diff must be registered in TOOLS")
    assert_true(found_lsp, "turbomojo_lsp_query must be registered in TOOLS")


def test_tier1_f35_case2_turbomojo_capture_screen_text_and_svg() raises:
    """Verify turbomojo_capture_screen tool execution and Screen/SVG rendering."""
    # 1. MCP tool invocation
    var resp_str = run_mcp_tool("turbomojo_capture_screen", "{\"format\":\"text\"}")
    var doc = json_parse(resp_str)
    assert_true(doc.ok)
    var res = doc.get(0, "result")
    assert_false(doc.bool(doc.get(res, "isError"), True))

    # 2. Production Screen plain text capture
    var scr = Screen(80, 24)
    _ = scr.text(0, 0, "[TurboMojo Header] main.mojo", 0xFFFFFF, 0x000000)
    _ = scr.text(0, 1, "[Status: Ready]", 0x00FF00, 0x000000)
    var scr_txt = to_str(scr.to_text())
    assert_true(scr_txt.find("TurboMojo Header") >= 0)
    assert_true(scr_txt.find("main.mojo") >= 0)
    assert_true(scr_txt.find("Status: Ready") >= 0)

    # 3. Production SVG vector capture
    var svg_out = screen_svg(scr, 0xFFFFFF, 0x000000, "TurboMojo Test")
    assert_true(svg_out.startswith("<svg"))
    assert_true(svg_out.find("</svg>") >= 0)


def test_tier1_f35_case3_turbomojo_git_diff_tool() raises:
    """Verify turbomojo_git_diff compares live buffer text against disk content."""
    var d = scratch("git_diff_tool")
    var file_path = d + "/example.mojo"
    _ = write_file(file_path, str_bytes("fn old_name():\n    pass\n"))

    var buffer_text = "def new_name():\n    pass\n"
    var args = "{\"path\":" + json_quote(file_path) + ",\"buffer_text\":" + json_quote(buffer_text) + "}"
    var resp_str = run_mcp_tool("turbomojo_git_diff", args)

    var doc = json_parse(resp_str)
    assert_true(doc.ok)
    var res = doc.get(0, "result")
    assert_false(doc.bool(doc.get(res, "isError"), True))

    var content = doc.get(res, "content")
    var item0 = doc.at(content, 0)
    var txt = doc.str(doc.get(item0, "text"), "")

    var inner_doc = json_parse(txt)
    assert_true(inner_doc.ok)
    assert_true(inner_doc.bool(inner_doc.get(0, "ok"), False))
    assert_equal(inner_doc.int(inner_doc.get(0, "hunks"), 0), 1)

    var diff_str = inner_doc.str(inner_doc.get(0, "diff"), "")
    assert_true(diff_str.find("-fn old_name") >= 0 or diff_str.find("old_name") >= 0)
    assert_true(diff_str.find("+def new_name") >= 0 or diff_str.find("new_name") >= 0)
    clean_scratch(d)


def test_tier1_f35_case4_turbomojo_symbol_search_tool() raises:
    """Verify turbomojo_symbol_search returns matching symbols and file locations."""
    var resp_str = run_mcp_tool("turbomojo_symbol_search", "{\"query\":\"AgentPrompt\"}")
    var doc = json_parse(resp_str)
    assert_true(doc.ok)

    var res = doc.get(0, "result")
    assert_false(doc.bool(doc.get(res, "isError"), True))

    var content = doc.get(res, "content")
    var item0 = doc.at(content, 0)
    var txt = doc.str(doc.get(item0, "text"), "")

    var inner_doc = json_parse(txt)
    assert_true(inner_doc.ok)
    assert_true(inner_doc.bool(inner_doc.get(0, "ok"), False))
    assert_true(inner_doc.int(inner_doc.get(0, "total"), 0) >= 1)

    var syms = inner_doc.get(0, "symbols")
    assert_true(inner_doc.size(syms) >= 1)
    var s0 = inner_doc.at(syms, 0)
    assert_equal(inner_doc.str(inner_doc.get(s0, "name"), ""), "AgentPrompt")
    assert_equal(inner_doc.str(inner_doc.get(s0, "kind"), ""), "struct")
    var file_str = inner_doc.str(inner_doc.get(s0, "file"), "")
    assert_true(file_str.find("agentprompt.mojo") >= 0)


def test_tier1_f35_case5_turbomojo_lsp_query_tool() raises:
    """Verify turbomojo_lsp_query answers queries gracefully."""
    var resp_str = run_mcp_tool("turbomojo_lsp_query", "{\"path\":\"src/agentprompt.mojo\",\"line\":10,\"col\":5,\"query_type\":\"hover\"}")
    var doc = json_parse(resp_str)
    assert_true(doc.ok)

    var res = doc.get(0, "result")
    assert_false(doc.bool(doc.get(res, "isError"), True))

    var content = doc.get(res, "content")
    var item0 = doc.at(content, 0)
    var txt = doc.str(doc.get(item0, "text"), "")

    var inner_doc = json_parse(txt)
    assert_true(inner_doc.ok)
    assert_equal(inner_doc.str(inner_doc.get(0, "path"), ""), "src/agentprompt.mojo")


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f35_bound1_ipc_file_queue_request_response_cycle() raises:
    """Verify atomic file-queue IPC request and response write/read/delete lifecycle."""
    var d = scratch("ipc_cycle")
    var req_path = d + "/req-test1.json"
    var resp_path = d + "/resp-test1.json"

    # 1. Atomically create request
    var req_body = "{\"id\":\"test1\",\"op\":\"ping\"}"
    assert_true(write_bytes_atomic(req_path, str_bytes(req_body + "\n")))
    assert_true(path_exists(req_path))

    # 2. Atomically create response
    var resp_body = "{\"id\":\"test1\",\"ok\":true,\"pid\":" + String(own_pid()) + "}"
    assert_true(write_bytes_atomic(resp_path, str_bytes(resp_body + "\n")))
    assert_true(path_exists(resp_path))

    # 3. Read and parse response
    var read_back = bytes_to_str(read_file(resp_path))
    var doc = json_parse(read_back)
    assert_true(doc.ok)
    assert_equal(doc.str(doc.get(0, "id"), ""), "test1")
    assert_true(doc.bool(doc.get(0, "ok"), False))
    assert_equal(doc.int(doc.get(0, "pid"), 0), own_pid())

    # 4. Clean up queue files
    delete_file(req_path)
    delete_file(resp_path)
    assert_false(path_exists(req_path))
    assert_false(path_exists(resp_path))
    clean_scratch(d)


def test_tier2_f35_bound2_mcp_unknown_tool_error() raises:
    """Verify invoking an unregistered tool produces standard JSON-RPC isError: true."""
    var resp_str = run_mcp_tool("nonexistent_tool_op", "{}")
    var doc = json_parse(resp_str)
    assert_true(doc.ok)

    var res = doc.get(0, "result")
    assert_true(doc.bool(doc.get(res, "isError"), False))

    var content = doc.get(res, "content")
    var item0 = doc.at(content, 0)
    var txt = doc.str(doc.get(item0, "text"), "")
    assert_true(txt.find("Unknown tool") >= 0)


def test_tier2_f35_bound3_mcp_get_buffer_nonexistent_file() raises:
    """Verify get_buffer for missing path returns file not found error."""
    var resp_str = run_mcp_tool("turbomojo_get_buffer_text", "{\"path\":\"/tmp/nonexistent_file_xyz_999.mojo\"}")
    var doc = json_parse(resp_str)
    assert_true(doc.ok)

    var res = doc.get(0, "result")
    var content = doc.get(res, "content")
    var item0 = doc.at(content, 0)
    var txt = doc.str(doc.get(item0, "text"), "")

    var inner_doc = json_parse(txt)
    assert_true(inner_doc.ok)
    assert_false(inner_doc.bool(inner_doc.get(0, "ok"), True))
    assert_true(inner_doc.str(inner_doc.get(0, "error"), "").find("File not found") >= 0)


def test_tier2_f35_bound4_file_loc_parser_boundaries() raises:
    """Verify parse_file_loc correctly extracts path, line, and column coordinates."""
    var loc1 = parse_file_loc("/path/to/file.mojo:42:15")
    assert_equal(loc1.path, "/path/to/file.mojo")
    assert_equal(loc1.line, 42)
    assert_equal(loc1.col, 15)

    var loc2 = parse_file_loc("/path/to/file.mojo:100")
    assert_equal(loc2.path, "/path/to/file.mojo")
    assert_equal(loc2.line, 100)
    assert_equal(loc2.col, 0)

    var loc3 = parse_file_loc("/plain/file.mojo")
    assert_equal(loc3.path, "/plain/file.mojo")
    assert_equal(loc3.line, 0)
    assert_equal(loc3.col, 0)


def test_tier2_f35_bound5_screen_buffer_to_text_grid() raises:
    """Verify Screen text extraction produces clean line grid without escape sequences."""
    var s = Screen(40, 4)
    _ = s.text(0, 0, "Top Line Header", 0xFFFFFF, 0x000000)
    _ = s.text(0, 1, "Second Line Content", 0xAAAAAA, 0x000000)
    _ = s.text(0, 2, "Status: OK", 0x00FF00, 0x000000)

    var row0 = to_str(s.row_text(0))
    var row1 = to_str(s.row_text(1))
    var row2 = to_str(s.row_text(2))

    assert_true(row0.startswith("Top Line Header"))
    assert_true(row1.startswith("Second Line Content"))
    assert_true(row2.startswith("Status: OK"))
    assert_equal(row0.find("\x1b"), -1, "Screen text output must not contain ANSI escapes")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
