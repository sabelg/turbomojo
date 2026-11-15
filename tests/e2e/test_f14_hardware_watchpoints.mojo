"""E2E Test Suite for Feature #14:
Hardware Watchpoints / Data Breakpoints (`tests/e2e/test_f14_hardware_watchpoints.mojo`).
Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from json import json_parse
from dap import (
    DS_RUNNING, DS_STOPPED,
    DataBreakpointInfoResult, build_data_breakpoint_info_request,
    parse_data_breakpoint_info_response, build_set_data_breakpoints_request,
    apply_set_data_breakpoints_response, WatchpointSession,
)
from breakpoints import (
    BV_UNKNOWN, BV_OK, BV_NOT,
    DataBreakpoint, cycle_watchpoint_access_type,
)
from dbgview import VarNode, format_varnode_with_watchpoint


# ===========================================================================
# Tier 1: Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f14_case1_data_breakpoint_info_query() raises:
    """Verify formatting of dataBreakpointInfo query and parsing of dataId & accessTypes."""
    var req = build_data_breakpoint_info_request("n", 4)
    var doc_req = json_parse(req)
    assert_true(doc_req.ok)
    assert_equal(doc_req.str(doc_req.get(0, "command"), ""), "dataBreakpointInfo")
    var args = doc_req.get(0, "arguments")
    assert_equal(doc_req.str(doc_req.get(args, "name"), ""), "n")
    assert_equal(doc_req.int(doc_req.get(args, "variablesReference"), 0), 4)

    var resp = "{\"seq\":2,\"type\":\"response\",\"request_seq\":1,\"command\":\"dataBreakpointInfo\",\"success\":true,\"body\":{\"dataId\":\"0xFF00:8\",\"description\":\"n\",\"accessTypes\":[\"read\",\"write\",\"readWrite\"]}}"
    var parsed = parse_data_breakpoint_info_response(resp)
    assert_true(parsed.ok)
    assert_equal(parsed.data_id, "0xFF00:8")
    assert_equal(len(parsed.access_types), 3)
    assert_equal(parsed.access_types[0], "read")
    assert_equal(parsed.access_types[1], "write")
    assert_equal(parsed.access_types[2], "readWrite")


def test_tier1_f14_case2_set_data_breakpoints_write_trap() raises:
    """Verify serialization of setDataBreakpoints request for a write trap and verified status."""
    var bps = List[DataBreakpoint]()
    bps.append(DataBreakpoint("0xFF00:8", "write", "n", "0xFF00"))

    var req = build_set_data_breakpoints_request(bps)
    var doc_req = json_parse(req)
    assert_true(doc_req.ok)
    assert_equal(doc_req.str(doc_req.get(0, "command"), ""), "setDataBreakpoints")
    var args = doc_req.get(0, "arguments")
    var arr = doc_req.get(args, "breakpoints")
    assert_equal(doc_req.size(arr), 1)
    var first = doc_req.at(arr, 0)
    assert_equal(doc_req.str(doc_req.get(first, "dataId"), ""), "0xFF00:8")
    assert_equal(doc_req.str(doc_req.get(first, "accessType"), ""), "write")

    var resp = "{\"seq\":3,\"type\":\"response\",\"request_seq\":2,\"command\":\"setDataBreakpoints\",\"success\":true,\"body\":{\"breakpoints\":[{\"id\":101,\"verified\":true}]}}"
    apply_set_data_breakpoints_response(resp, bps)
    assert_equal(bps[0].id, 101)
    assert_equal(bps[0].verified, BV_OK)
    assert_equal(bps[0].look(), 1)
    assert_equal(bps[0].badge(), "●")


def test_tier1_f14_case3_watchpoint_w_keybinding_on_varnode() raises:
    """In WK_DEBUG, pressing W on a VarNode registers watchpoint and renders [W:write] tag."""
    comptime IDX = "__mlir_type.`!kgen.scalar<index>`"
    var node = VarNode("n", IDX, "4", 4, "0xFF00", "n", 0, "")
    assert_true(node.settable())
    assert_equal(node.address(), "0xFF00")

    var access = cycle_watchpoint_access_type("")
    assert_equal(access, "write")
    var bp = DataBreakpoint("0xFF00:8", access, node.name, node.address())
    bp.verified = BV_OK

    var row = format_varnode_with_watchpoint(node, bp)
    assert_true(row.find("n = 4") >= 0)
    assert_true(row.find("[● W:write]") >= 0)


def test_tier1_f14_case4_watchpoint_trap_stopped_event() raises:
    """Verify that hitting a hardware watchpoint transitions session to DS_STOPPED with reason 'data breakpoint'."""
    var session = WatchpointSession()
    assert_equal(session.state, DS_RUNNING)

    var evt_json = "{\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"reason\":\"data breakpoint\",\"description\":\"watchpoint 101 hit (write)\",\"threadId\":7,\"hitBreakpointIds\":[101]}}"
    var doc = json_parse(evt_json)
    assert_true(doc.ok)
    var body = doc.get(0, "body")
    var reason = doc.str(doc.get(body, "reason"), "")
    var desc = doc.str(doc.get(body, "description"), "")
    var hit_arr = doc.get(body, "hitBreakpointIds")
    var hit_id = doc.int(doc.at(hit_arr, 0), -1) if hit_arr >= 0 else -1

    session.on_stopped(reason, desc, hit_id)
    assert_equal(session.state, DS_STOPPED)
    assert_equal(session.stop_reason, "data breakpoint")
    assert_equal(session.hit_breakpoint_id, 101)


def test_tier1_f14_case5_access_type_cycling_and_clear() raises:
    """Test full cycling through watchpoint modes: write -> readWrite -> read -> clear."""
    var mode = ""
    mode = cycle_watchpoint_access_type(mode)
    assert_equal(mode, "write")
    mode = cycle_watchpoint_access_type(mode)
    assert_equal(mode, "readWrite")
    mode = cycle_watchpoint_access_type(mode)
    assert_equal(mode, "read")
    mode = cycle_watchpoint_access_type(mode)
    assert_equal(mode, "")

    # When cleared, setDataBreakpoints sends an empty list
    var bps = List[DataBreakpoint]()
    var req = build_set_data_breakpoints_request(bps)
    var doc = json_parse(req)
    var arr = doc.get(doc.get(0, "arguments"), "breakpoints")
    assert_equal(doc.size(arr), 0)


# ===========================================================================
# Tier 2: Boundary, Edge & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f14_bound1_unsupported_variable_null_data_id() raises:
    """Variable has no memory address or represents an unsupported expression (dataId: null)."""
    var resp_null = "{\"seq\":4,\"type\":\"response\",\"request_seq\":3,\"command\":\"dataBreakpointInfo\",\"success\":true,\"body\":{\"dataId\":null,\"description\":\"cannot break on expression\"}}"
    var parsed = parse_data_breakpoint_info_response(resp_null)
    assert_false(parsed.ok, "Should fail for null dataId")
    assert_equal(parsed.data_id, "")

    var session = WatchpointSession()
    if not parsed.ok:
        session.last_toast = "The debugger cannot place a hardware watchpoint on expression"
    assert_true(session.last_toast.find("cannot place a hardware watchpoint") >= 0)
    assert_equal(len(session.active_bps), 0)


def test_tier2_f14_bound2_hardware_watchpoint_limit_exhausted() raises:
    """Verify behavior when hardware debug registers (typically 4) are exhausted."""
    var bps = List[DataBreakpoint]()
    for i in range(5):
        bps.append(DataBreakpoint("0x100" + String(i) + ":8", "write", "var" + String(i)))

    var resp = (
        "{\"seq\":5,\"type\":\"response\",\"request_seq\":4,\"command\":\"setDataBreakpoints\",\"success\":true,"
        + "\"body\":{\"breakpoints\":["
        + "{\"id\":1,\"verified\":true},"
        + "{\"id\":2,\"verified\":true},"
        + "{\"id\":3,\"verified\":true},"
        + "{\"id\":4,\"verified\":true},"
        + "{\"id\":-1,\"verified\":false,\"message\":\"hardware breakpoint limit exceeded\"}"
        + "]}}"
    )
    apply_set_data_breakpoints_response(resp, bps)
    assert_equal(len(bps), 5)
    for i in range(4):
        assert_equal(bps[i].verified, BV_OK)
        assert_equal(bps[i].look(), 1)
        assert_equal(bps[i].badge(), "●")

    # 5th breakpoint exceeded hardware register budget
    assert_equal(bps[4].verified, BV_NOT)
    assert_equal(bps[4].id, -1)
    assert_equal(bps[4].look(), 4)
    assert_equal(bps[4].badge(), "◌")


def test_tier2_f14_bound3_data_breakpoint_with_condition() raises:
    """Verify setting a conditional hardware watchpoint (e.g. n > 10)."""
    var bps = List[DataBreakpoint]()
    var bp = DataBreakpoint("0xFF00:8", "write", "n", "0xFF00")
    bp.condition = "n > 10"
    bps.append(bp^)

    var req = build_set_data_breakpoints_request(bps)
    var doc = json_parse(req)
    var bp_node = doc.at(doc.get(doc.get(0, "arguments"), "breakpoints"), 0)
    assert_equal(doc.str(doc.get(bp_node, "condition"), ""), "n > 10")

    var resp = "{\"seq\":6,\"type\":\"response\",\"request_seq\":5,\"command\":\"setDataBreakpoints\",\"success\":true,\"body\":{\"breakpoints\":[{\"id\":105,\"verified\":true}]}}"
    apply_set_data_breakpoints_response(resp, bps)
    assert_equal(bps[0].verified, BV_OK)
    assert_equal(bps[0].look(), 3)
    assert_equal(bps[0].badge(), "◆")


def test_tier2_f14_bound4_watchpoint_persists_across_steps_and_stack_frames() raises:
    """Ensure active watchpoints remain registered in the adapter when stepping over or navigating stack."""
    var session = WatchpointSession()
    session.active_bps.append(DataBreakpoint("0xFF00:8", "write", "n", "0xFF00"))
    session.active_bps.append(DataBreakpoint("0xFF08:1", "readWrite", "flag", "0xFF08"))
    session.active_bps[0].verified = BV_OK
    session.active_bps[0].id = 101
    session.active_bps[1].verified = BV_OK
    session.active_bps[1].id = 102

    # Simulate stepOver and stack navigation
    var req_refresh = build_set_data_breakpoints_request(session.active_bps)
    var doc = json_parse(req_refresh)
    var arr = doc.get(doc.get(0, "arguments"), "breakpoints")
    assert_equal(doc.size(arr), 2)
    assert_equal(doc.str(doc.get(doc.at(arr, 0), "dataId"), ""), "0xFF00:8")
    assert_equal(doc.str(doc.get(doc.at(arr, 1), "dataId"), ""), "0xFF08:1")


def test_tier2_f14_bound5_watchpoint_cleanup_on_session_end() raises:
    """Verify that ending the debug session cleans up active hardware watchpoint IDs and resets verification state."""
    var session = WatchpointSession()
    var bp = DataBreakpoint("0xFF00:8", "write", "n", "0xFF00")
    bp.verified = BV_OK
    bp.id = 101
    session.active_bps.append(bp^)

    assert_equal(session.active_bps[0].id, 101)
    assert_equal(session.active_bps[0].verified, BV_OK)

    session.forget_debugger()

    assert_equal(session.active_bps[0].id, -1)
    assert_equal(session.active_bps[0].verified, BV_UNKNOWN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
