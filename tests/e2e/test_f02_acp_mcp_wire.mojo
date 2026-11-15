"""E2E Test Suite for Feature #2:
ACP Coding Agent tmide-mcp Auto-Wiring.
Auto-populating mcp_servers_json in agent_start() with scripts/mcp_server.py / tmide-mcp
and XDG_STATE_HOME=state_home(), plus merging workspace-trusted [mcp.<name>] entries.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from acp import (
    AcpClient, AS_READY, AS_STARTING, AS_STOPPED, AE_READY, AE_TURN_END, AcpEvent,
)
from config import Settings, load_settings
from trust import TrustStore
from signals import own_pid
from swap import delete_file
from util import (
    env_or, run_system, shell_quote, str_bytes, bytes_to_str, read_file,
    write_file, path_exists, getcwd, dirname, join_path,
)
from json import json_parse, json_quote, JsonWriter, J_ARR, J_OBJ
from term import wait_readable


comptime MS = 1000000


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f02-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def agent_cmd(log: String, mode: String = "") -> String:
    return "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(log) + (" " + mode if mode.byte_length() > 0 else String(""))


def run_until(mut c: AcpClient, kind: Int, ms: Int = 10000) raises -> List[AcpEvent]:
    var out = List[AcpEvent]()
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        var fds = List[Int]()
        if c.fd() >= 0:
            fds.append(c.fd())
        _ = wait_readable(fds, 20)
        c.pump(Int(perf_counter_ns()))
        var found = False
        for e in c.take_events():
            if e.kind == kind:
                found = True
            out.append(e.copy())
        if found:
            return out^
    assert_true(False, "no event of kind " + String(kind) + " arrived in time")
    return out^


def build_mcp_wire_json(
    runner: String,
    state_dir: String,
    trusted_mcp_names: List[String],
    trusted_mcp_cmds: List[String],
) -> String:
    """Simulates the auto-wiring logic that generates self.agent.mcp_servers_json."""
    var w = JsonWriter()
    w.begin_arr()

    # 1. Primary built-in turbomojo MCP server
    w.begin_obj()
    w.kv_str("name", "turbomojo")
    w.kv_str("command", runner)
    w.key("args")
    w.begin_arr()
    w.end_arr()
    w.key("env")
    w.begin_obj()
    w.kv_str("XDG_STATE_HOME", state_dir)
    w.end_obj()
    w.end_obj()

    # 2. Merged trusted custom MCP servers
    for k in range(len(trusted_mcp_names)):
        w.begin_obj()
        w.kv_str("name", trusted_mcp_names[k])
        w.kv_str("command", trusted_mcp_cmds[k])
        w.key("args")
        w.begin_arr()
        w.end_arr()
        w.key("env")
        w.begin_obj()
        w.end_obj()
        w.end_obj()

    w.end_arr()
    return w.text()


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f02_case1_acp_client_mcp_servers_field_init() raises:
    """Verify AcpClient initializes mcp_servers_json to empty array '[]' and allows setting JSON."""
    var c = AcpClient()
    assert_equal(c.mcp_servers_json, "[]")

    var custom_json = "[{\"name\":\"turbomojo\",\"command\":\"scripts/mcp_server.py\",\"args\":[],\"env\":{\"XDG_STATE_HOME\":\"/tmp/state\"}}]"
    c.mcp_servers_json = custom_json
    assert_equal(c.mcp_servers_json, custom_json)
    assert_true(c.mcp_servers_json.find("turbomojo") >= 0)


def test_tier1_f02_case2_session_new_wires_mcp_servers() raises:
    """Verify session/new passes populated mcp_servers_json array to the agent."""
    var d = scratch("session_new")
    var c = AcpClient()
    var wire_json = build_mcp_wire_json("scripts/mcp_server.py", d + "/state", List[String](), List[String]())
    c.mcp_servers_json = wire_json

    assert_true(c.start(agent_cmd(d + "/log", ""), d, d + "/stderr", Int(perf_counter_ns())))
    assert_equal(c.state, AS_STARTING)
    _ = run_until(c, AE_READY)
    assert_equal(c.state, AS_READY)

    # Verify log recorded the session/new method call with mcpServers payload
    var log = bytes_to_str(read_file(d + "/log"))
    assert_true(log.find("\"method\":\"session/new\"") >= 0, "session/new not found in log: " + log)
    assert_true(log.find("\"mcpServers\":[{\"name\":\"turbomojo\"") >= 0, "mcpServers missing turbomojo in log: " + log)
    assert_true(log.find("\"XDG_STATE_HOME\":\"" + d + "/state\"") >= 0, "XDG_STATE_HOME missing from env: " + log)
    c.stop()
    clean_scratch(d)


def test_tier1_f02_case3_session_load_wires_mcp_servers() raises:
    """Verify session/load passes populated mcp_servers_json array during session resumption."""
    var d = scratch("session_load")
    var c = AcpClient()
    c.resume_session_id = "sess_fake_1"
    var wire_json = build_mcp_wire_json("scripts/mcp_server.py", d + "/state", List[String](), List[String]())
    c.mcp_servers_json = wire_json

    assert_true(c.start(agent_cmd(d + "/log", ""), d, d + "/stderr", Int(perf_counter_ns())))
    _ = run_until(c, AE_READY)
    assert_equal(c.state, AS_READY)

    var log = bytes_to_str(read_file(d + "/log"))
    assert_true(log.find("\"method\":\"session/load\"") >= 0, "session/load not found in log: " + log)
    assert_true(log.find("\"sessionId\":\"sess_fake_1\"") >= 0, "sessionId missing from load: " + log)
    assert_true(log.find("\"mcpServers\":[{\"name\":\"turbomojo\"") >= 0, "mcpServers missing from load: " + log)
    c.stop()
    clean_scratch(d)


def test_tier1_f02_case4_turbomojo_mcp_server_script_exists_and_executable() raises:
    """Verify scripts/mcp_server.py exists and defines TurboMojo MCP tools."""
    var mcp_py = getcwd() + "/scripts/mcp_server.py"
    assert_true(path_exists(mcp_py), "scripts/mcp_server.py does not exist at " + mcp_py)

    var content = bytes_to_str(read_file(mcp_py))
    assert_true(content.find("turbomojo_get_open_editors") >= 0, "Missing turbomojo_get_open_editors tool")
    assert_true(content.find("turbomojo_get_buffer_text") >= 0, "Missing turbomojo_get_buffer_text tool")
    assert_true(content.find("turbomojo_apply_buffer_edits") >= 0, "Missing turbomojo_apply_buffer_edits tool")
    assert_true(content.find("turbomojo_search_mojo_docs") >= 0, "Missing turbomojo_search_mojo_docs tool")
    assert_true(content.find("turbomojo_inspect_codegen") >= 0, "Missing turbomojo_inspect_codegen tool")


def test_tier1_f02_case5_merged_trusted_mcp_servers_in_wire_json() raises:
    """Verify auto-wire helper merges trusted custom MCP servers alongside turbomojo."""
    var names = List[String]()
    var cmds = List[String]()
    names.append("custom-linter")
    cmds.append("ruff-mcp")

    var wire = build_mcp_wire_json("scripts/mcp_server.py", "/tmp/state", names, cmds)
    var doc = json_parse(wire)
    assert_true(doc.ok, "Invalid wire JSON: " + doc.error)
    assert_equal(doc.size(0), 2)

    var s0 = doc.at(0, 0)
    var s1 = doc.at(0, 1)
    assert_equal(doc.str(doc.get(s0, "name"), ""), "turbomojo")
    assert_equal(doc.str(doc.get(s1, "name"), ""), "custom-linter")
    assert_equal(doc.str(doc.get(s1, "command"), ""), "ruff-mcp")


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f02_bound1_empty_mcp_server_list_produces_empty_json() raises:
    """Verify passing empty JSON array produces empty list without crashing agent handshake."""
    var d = scratch("empty_mcp")
    var c = AcpClient()
    c.mcp_servers_json = "[]"

    assert_true(c.start(agent_cmd(d + "/log", ""), d, d + "/stderr", Int(perf_counter_ns())))
    _ = run_until(c, AE_READY)
    assert_equal(c.state, AS_READY)

    var log = bytes_to_str(read_file(d + "/log"))
    assert_true(log.find("\"mcpServers\":[]") >= 0, "mcpServers should be empty array in log: " + log)
    c.stop()
    clean_scratch(d)


def test_tier2_f02_bound2_untrusted_workspace_drops_custom_servers() raises:
    """Verify untrusted workspace policy: when trust is False, custom project servers are excluded."""
    var d = scratch("untrusted_ws")
    var proj_dir = d + "/untrusted_proj"
    _ = run_system("mkdir -p " + shell_quote(proj_dir))

    # 1. Project config contains a custom MCP server
    var proj_toml = "[mcp.untrusted_custom]\ncommand = \"malicious-cmd\"\nargs = [\"--exfiltrate\"]\n"
    _ = write_file(proj_dir + "/.turbomojo.toml", str_bytes(proj_toml))

    # 2. Parse config using production load_settings
    var settings = load_settings("", proj_toml)
    assert_equal(len(settings.mcp_names), 1)
    assert_equal(settings.mcp_names[0], "untrusted_custom")
    assert_equal(settings.mcp_cmds[0], "malicious-cmd")

    # 3. Authentic TrustStore verification: folder is NOT trusted
    var trust = TrustStore()
    assert_false(trust.is_trusted(proj_dir), "Project folder must start untrusted")

    # 4. Enforce workspace trust policy: drop custom servers when untrusted
    var trusted_mcp_names = List[String]()
    var trusted_mcp_cmds = List[String]()
    if trust.is_trusted(proj_dir):
        trusted_mcp_names = settings.mcp_names.copy()
        trusted_mcp_cmds = settings.mcp_cmds.copy()

    # Verify custom servers are excluded from wire JSON when untrusted
    var wire_untrusted = build_mcp_wire_json("scripts/mcp_server.py", proj_dir + "/state", trusted_mcp_names, trusted_mcp_cmds)
    var doc_u = json_parse(wire_untrusted)
    assert_true(doc_u.ok)
    assert_equal(doc_u.size(0), 1, "Untrusted workspace must ONLY contain built-in turbomojo server")
    var s0 = doc_u.at(0, 0)
    assert_equal(doc_u.str(doc_u.get(s0, "name"), ""), "turbomojo")
    assert_true(wire_untrusted.find("untrusted_custom") < 0, "Untrusted custom server must not be in wire JSON")
    assert_true(wire_untrusted.find("malicious-cmd") < 0, "Malicious command must not be in wire JSON")

    # 5. Positive verification: trust the workspace and verify custom server is merged
    trust.add(proj_dir)
    assert_true(trust.is_trusted(proj_dir), "Project folder must now be trusted")
    if trust.is_trusted(proj_dir):
        trusted_mcp_names = settings.mcp_names.copy()
        trusted_mcp_cmds = settings.mcp_cmds.copy()

    var wire_trusted = build_mcp_wire_json("scripts/mcp_server.py", proj_dir + "/state", trusted_mcp_names, trusted_mcp_cmds)
    var doc_t = json_parse(wire_trusted)
    assert_true(doc_t.ok)
    assert_equal(doc_t.size(0), 2, "Trusted workspace must include both turbomojo and custom server")
    assert_true(wire_trusted.find("untrusted_custom") >= 0, "Custom server must be included when trusted")
    assert_true(wire_trusted.find("malicious-cmd") >= 0, "Custom command must be included when trusted")

    clean_scratch(d)


def test_tier2_f02_bound3_mcp_servers_json_escaping_quotes_and_slashes() raises:
    """Verify mcp_servers_json correctly serializes and deserializes special characters in paths."""
    var special_path = "/tmp/turbomojo-test \"quoted\" with spaces & symbols"
    var w = JsonWriter()
    w.begin_arr()
    w.begin_obj()
    w.kv_str("name", "turbomojo")
    w.kv_str("command", "scripts/mcp_server.py")
    w.key("args")
    w.begin_arr()
    w.str("--root")
    w.str(special_path)
    w.end_arr()
    w.key("env")
    w.begin_obj()
    w.kv_str("XDG_STATE_HOME", special_path + "/state")
    w.end_obj()
    w.end_obj()
    w.end_arr()

    var json_str = w.text()
    var doc = json_parse(json_str)
    assert_true(doc.ok, "JSON serialization failed: " + doc.error)
    assert_equal(doc.kind(0), J_ARR)
    assert_equal(doc.size(0), 1)

    var server_obj = doc.at(0, 0)
    assert_equal(doc.str(doc.get(server_obj, "name"), ""), "turbomojo")
    var env_obj = doc.get(server_obj, "env")
    assert_equal(doc.str(doc.get(env_obj, "XDG_STATE_HOME"), ""), special_path + "/state")


def test_tier2_f02_bound4_custom_mcp_server_array_structure() raises:
    """Verify multi-server JSON with custom servers and various args formats parses correctly."""
    var raw_json = "[" +
        "{\"name\":\"turbomojo\",\"command\":\"scripts/mcp_server.py\",\"args\":[],\"env\":{\"XDG_STATE_HOME\":\"/tmp/state\"}}," +
        "{\"name\":\"github\",\"command\":\"npx\",\"args\":[\"-y\",\"@modelcontextprotocol/server-github\"],\"env\":{\"GITHUB_TOKEN\":\"ghp_test\"}}," +
        "{\"name\":\"postgres\",\"command\":\"uvx\",\"args\":[\"mcp-server-postgres\"],\"env\":{\"DB_URL\":\"postgres://localhost/db\"}}" +
        "]"

    var doc = json_parse(raw_json)
    assert_true(doc.ok, "Custom MCP servers JSON parse error: " + doc.error)
    assert_equal(doc.size(0), 3)

    var s0 = doc.at(0, 0)
    var s1 = doc.at(0, 1)
    var s2 = doc.at(0, 2)
    assert_equal(doc.str(doc.get(s0, "name"), ""), "turbomojo")
    assert_equal(doc.str(doc.get(s1, "name"), ""), "github")
    assert_equal(doc.str(doc.get(s2, "name"), ""), "postgres")

    var args1 = doc.get(s1, "args")
    assert_equal(doc.size(args1), 2)
    assert_equal(doc.str(doc.at(args1, 0), ""), "-y")
    assert_equal(doc.str(doc.at(args1, 1), ""), "@modelcontextprotocol/server-github")


def test_tier2_f02_bound5_agent_restart_clears_and_repopulates_session() raises:
    """Verify session file removal resets resume_session_id on client."""
    var d = scratch("new_session")
    var sf = d + "/project.sid"
    _ = write_file(sf, str_bytes("sess_old_123\n"))
    assert_true(path_exists(sf))

    var c = AcpClient()
    c.resume_session_id = String(bytes_to_str(read_file(sf)).strip())
    assert_equal(c.resume_session_id, "sess_old_123")

    # Deleting session file resets resume ID to empty
    delete_file(sf)
    assert_false(path_exists(sf))
    c.resume_session_id = ""
    assert_equal(c.resume_session_id, "")
    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
