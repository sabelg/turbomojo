"""E2E Test Suite for Feature #15:
Post-Mortem Core Dumps & Live PID Attach (`tests/e2e/test_f15_core_dump_live_pid.mojo`).
Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from json import json_parse
from dap import (
    DS_OFF, DS_STOPPED,
    CoreDumpEntry, StackFrame, StepResult, CoreDumpSession,
    build_core_dump_attach_request, build_live_pid_attach_request,
    build_live_pid_detach_request, build_exception_filters_request,
    parse_coredumpctl_line, extract_faulting_address_from_description,
)


# ===========================================================================
# Tier 1: Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f15_case1_core_dump_attach_request_format() raises:
    """Verify formatting of DAP attach request for post-mortem core dump."""
    var req = build_core_dump_attach_request("/build/app", "/tmp/core.1234")
    var doc = json_parse(req)
    assert_true(doc.ok)
    assert_equal(doc.str(doc.get(0, "command"), ""), "attach")
    var args = doc.get(0, "arguments")
    assert_equal(doc.str(doc.get(args, "program"), ""), "/build/app")
    assert_equal(doc.str(doc.get(args, "coreFile"), ""), "/tmp/core.1234")


def test_tier1_f15_case2_core_dump_post_mortem_inspection() raises:
    """Verify simulated core dump attach populates stack frames and registers for inspection."""
    var session = CoreDumpSession()
    session.attach_core("/build/app", "/tmp/core.1234", True)
    assert_true(session.is_post_mortem)
    assert_equal(session.state, DS_STOPPED)
    assert_equal(session.stop_reason, "signal")

    # Add stack frames reported from core dump
    session.frames.append(StackFrame(1, "crash_handler()", 42, "/src/app.mojo"))
    session.frames.append(StackFrame(2, "main()", 100, "/src/main.mojo"))
    session.stop_line = session.frames[0].line

    assert_equal(len(session.frames), 2)
    assert_equal(session.stop_line, 42)
    assert_equal(session.frames[0].source_path, "/src/app.mojo")


def test_tier1_f15_case3_live_pid_attach_request_and_stop() raises:
    """Verify live process PID attach request and subsequent stop state."""
    var req = build_live_pid_attach_request(54321)
    var doc = json_parse(req)
    assert_true(doc.ok)
    assert_equal(doc.str(doc.get(0, "command"), ""), "attach")
    var args = doc.get(0, "arguments")
    assert_equal(doc.int(doc.get(args, "pid"), 0), 54321)

    var session = CoreDumpSession()
    session.attach_pid(54321, True)
    assert_false(session.is_post_mortem)
    assert_equal(session.pid, 54321)
    assert_equal(session.state, DS_STOPPED)


def test_tier1_f15_case4_live_pid_clean_detach_without_killing() raises:
    """Verify detaching from a live process preserves the target process (terminateDebuggee=false)."""
    var req = build_live_pid_detach_request()
    var doc = json_parse(req)
    assert_true(doc.ok)
    assert_equal(doc.str(doc.get(0, "command"), ""), "disconnect")
    var args = doc.get(0, "arguments")
    assert_false(doc.bool(doc.get(args, "terminateDebuggee"), True))
    assert_false(doc.bool(doc.get(args, "restart"), True))


def test_tier1_f15_case5_exception_and_signal_filters_configuration() raises:
    """Verify configuration of exception and signal stop filters via setExceptionBreakpoints."""
    var filters = List[String]()
    filters.append("uncaughtExceptions")
    filters.append("signal_SIGSEGV")
    filters.append("signal_SIGABRT")

    var req = build_exception_filters_request(filters)
    var doc = json_parse(req)
    assert_true(doc.ok)
    assert_equal(doc.str(doc.get(0, "command"), ""), "setExceptionBreakpoints")
    var args = doc.get(0, "arguments")
    var arr = doc.get(args, "filters")
    assert_equal(doc.size(arr), 3)
    assert_equal(doc.str(doc.at(arr, 0), ""), "uncaughtExceptions")
    assert_equal(doc.str(doc.at(arr, 1), ""), "signal_SIGSEGV")
    assert_equal(doc.str(doc.at(arr, 2), ""), "signal_SIGABRT")


# ===========================================================================
# Tier 2: Boundary, Edge & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f15_bound1_core_dump_resume_disallowed() raises:
    """Verify that resume() and stepping commands are safely blocked in post-mortem mode."""
    var session = CoreDumpSession()
    session.attach_core("/build/app", "/tmp/core.1234", True)

    assert_false(session.can_step())
    assert_false(session.can_resume())

    var res_resume = session.resume()
    assert_false(res_resume.ok)
    assert_equal(res_resume.message, "Cannot step in a core dump")
    assert_equal(session.state, DS_STOPPED)

    var res_step = session.step("next")
    assert_false(res_step.ok)
    assert_equal(res_step.message, "Cannot step in a core dump")
    assert_equal(session.state, DS_STOPPED)


def test_tier2_f15_bound2_invalid_core_dump_file_handling() raises:
    """Handle non-existent, truncated, or incompatible core dump file."""
    var session = CoreDumpSession()
    session.attach_core("/build/app", "/tmp/corrupt.core", False, "Invalid or truncated core file")

    assert_equal(session.state, DS_OFF)
    assert_false(session.is_post_mortem)
    assert_equal(session.error_msg, "Invalid or truncated core file")


def test_tier2_f15_bound3_attach_to_nonexistent_or_permission_denied_pid() raises:
    """Verify error handling when attaching to an invalid PID or permission-denied process."""
    var session = CoreDumpSession()
    session.attach_pid(999999, False, "Operation not permitted")

    assert_equal(session.state, DS_OFF)
    assert_equal(session.pid, 999999)
    assert_equal(session.error_msg, "Operation not permitted")


def test_tier2_f15_bound4_coredumpctl_output_parsing_and_selection() raises:
    """Verify parsing of coredumpctl list --no-legend tabular output."""
    var sample_line = "Wed 2026-11-14 17:00:00 UTC 12345 1000 1000 SIGSEGV /home/user/app /var/lib/systemd/coredump/core.app.12345"
    var entry = parse_coredumpctl_line(sample_line)

    assert_equal(entry.pid, 12345)
    assert_equal(entry.uid, 1000)
    assert_equal(entry.gid, 1000)
    assert_equal(entry.signal_name, "SIGSEGV")
    assert_equal(entry.exe, "/home/user/app")
    assert_equal(entry.core_path, "/var/lib/systemd/coredump/core.app.12345")
    assert_true(entry.timestamp.find("2026-11-14") >= 0)


def test_tier2_f15_bound5_signal_stop_with_null_pointer_sigsegv() raises:
    """Simulate a crash caused by null pointer dereference (SIGSEGV) and extract faulting address."""
    var desc = "signal SIGSEGV: address access violation (0x0)"
    var addr = extract_faulting_address_from_description(desc)
    assert_equal(addr, "0x0")

    var session = CoreDumpSession()
    session.attach_core("/build/app", "/tmp/core.null", True)
    session.stop_description = desc
    assert_equal(session.stop_reason, "signal")
    assert_true(session.stop_description.find("SIGSEGV") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
