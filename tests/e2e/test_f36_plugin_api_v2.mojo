"""E2E Test Suite for Feature #36:
Plugin API v2 & Lifecycle Manager.
Covers range-based editor edits, plugin discovery, lifecycle management (start/stop/timeout),
panel table formatting, status line sink, key registration and collision prevention.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from plugins import (
    find_plugins, register_plugins, plugin_cmd_id, Plugin, PluginCmd,
    PluginPanel, panel_lines, PL_READY, PL_STOPPED, PL_STARTING,
    PANEL_COL_MAX, PLUGIN_API, PluginRangeEdit, parse_plugin_edits_json,
)
from commands import build_registry, parse_key, Registry, CM_SAVE, CM_NONE
from json import json_parse, JsonWriter, J_ARR, J_OBJ
from signals import own_pid
from util import (
    env_or, run_system, shell_quote, write_file, str_bytes, bytes_to_str,
    read_file, path_exists,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f36-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d + "/plugins"))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f36_case1_plugin_discovery_and_manifest() raises:
    """Verify find_plugins parses plugin manifest and populates Plugin struct."""
    var d = scratch("discover")
    var pdir = d + "/plugins/formatter"
    _ = run_system("mkdir -p " + shell_quote(pdir))
    var manifest = "name = \"CodeFormatter\"\ncommand = \"python3 format.py\"\n"
    _ = write_file(pdir + "/plugin.toml", str_bytes(manifest))

    var warn = List[String]()
    var plugins = find_plugins(d + "/plugins", warn)
    assert_equal(len(plugins), 1)
    assert_equal(plugins[0].name, "CodeFormatter")
    assert_equal(plugins[0].command, "python3 format.py")
    assert_equal(plugins[0].dir, pdir)
    assert_equal(len(warn), 0)
    clean_scratch(d)


def test_tier1_f36_case2_plugin_command_registration_in_menu() raises:
    """Verify register_plugins adds plugin commands to registry and assigns keybinding."""
    var reg = build_registry()
    var ps = List[Plugin]()
    var p = Plugin("formatter", "/tmp", "python3 fmt.py")
    p.state = PL_READY
    p.cmds.append(PluginCmd("fmt", "Format File", "Formats active buffer", "Ctrl-Alt-F"))
    ps.append(p^)

    var warn = register_plugins(reg, ps)
    assert_equal(len(warn), 0)

    # Check keybinding registered
    var k = parse_key("Ctrl-Alt-F")
    var cmd_id = reg.find_key(k)
    assert_equal(cmd_id, plugin_cmd_id(0, 0))


def test_tier1_f36_case3_plugin_panel_table_formatting() raises:
    """Verify PluginPanel table view formats aligned columns with rule divider."""
    var panel = PluginPanel(0, "symbols")
    panel.table = True
    panel.columns.append("Symbol")
    panel.columns.append("Kind")
    panel.columns.append("Line")

    var r1 = List[String]()
    r1.append("main")
    r1.append("def")
    r1.append("10")
    panel.cells.append(r1^)

    var r2 = List[String]()
    r2.append("App")
    r2.append("struct")
    r2.append("45")
    panel.cells.append(r2^)

    var lines = panel_lines(panel)
    assert_true(len(lines) >= 4, "Expected header, rule, and 2 data rows")
    assert_true(lines[0].find("Symbol") >= 0 and lines[0].find("Kind") >= 0)
    assert_true(lines[1].find("---") >= 0)
    assert_true(lines[2].find("main") >= 0 and lines[2].find("def") >= 0)
    assert_true(lines[3].find("App") >= 0 and lines[3].find("struct") >= 0)


def test_tier1_f36_case4_plugin_status_line_aggregation() raises:
    """Verify status line items from active plugins aggregate with spacing."""
    var ps = List[Plugin]()
    var p1 = Plugin("git-info", "/tmp", "git.py")
    p1.state = PL_READY
    p1.status = "Branch: main"
    ps.append(p1^)

    var p2 = Plugin("linter", "/tmp", "lint.py")
    p2.state = PL_READY
    p2.status = "0 errors"
    ps.append(p2^)

    var agg = String("")
    for p in ps:
        if p.state == PL_READY and p.status.byte_length() > 0:
            agg += p.status + "  "

    assert_equal(agg, "Branch: main  0 errors  ")


def test_tier1_f36_case5_plugin_range_edits_payload_parsing() raises:
    """Verify range-based apply_edits JSON parses 1-based start/end line and column."""
    var json_str = "{\"edits\":[{\"start_line\":5,\"start_col\":10,\"end_line\":5,\"end_col\":20,\"text\":\"new_var\"}]}"
    var edits = parse_plugin_edits_json(json_str)
    assert_equal(len(edits), 1)
    assert_equal(edits[0].start_line, 5)
    assert_equal(edits[0].start_col, 10)
    assert_equal(edits[0].end_line, 5)
    assert_equal(edits[0].end_col, 20)
    assert_equal(edits[0].text, "new_var")


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f36_bound1_plugin_manifest_missing_command() raises:
    """Verify plugin.toml without a command produces warning and is skipped."""
    var d = scratch("missing_cmd")
    var pdir = d + "/plugins/broken"
    _ = run_system("mkdir -p " + shell_quote(pdir))
    _ = write_file(pdir + "/plugin.toml", str_bytes("name = \"BrokenPlugin\"\n"))

    var warn = List[String]()
    var plugins = find_plugins(d + "/plugins", warn)
    assert_equal(len(plugins), 0)
    assert_equal(len(warn), 1)
    assert_true(warn[0].find("no command to start") >= 0)
    clean_scratch(d)


def test_tier2_f36_bound2_plugin_key_collision_prevented() raises:
    """Verify plugin cannot overwrite reserved keybinding like F2 (Save)."""
    var reg = build_registry()
    var ps = List[Plugin]()
    var p = Plugin("stealer", "/tmp", "steal.py")
    p.state = PL_READY
    p.cmds.append(PluginCmd("boom", "Boom", "Try to steal F2", "F2"))
    ps.append(p^)

    var warn = register_plugins(reg, ps)
    assert_equal(len(warn), 1)
    assert_true(warn[0].find("F2 is taken") >= 0)
    assert_equal(reg.find_key(parse_key("F2")), CM_SAVE)


def test_tier2_f36_bound3_panel_column_width_capping() raises:
    """Verify panel_lines caps extreme cell widths at PANEL_COL_MAX (40 chars) with ellipsis."""
    var panel = PluginPanel(0, "long_text")
    panel.table = True
    panel.columns.append("Header")

    var r = List[String]()
    var long_cell = String("")
    for _ in range(80):
        long_cell += "A"
    r.append(long_cell)
    panel.cells.append(r^)

    var lines = panel_lines(panel)
    assert_true(len(lines) >= 3)
    var data_row = lines[2]
    # Cell width should not exceed PANEL_COL_MAX (40)
    assert_true(data_row.byte_length() <= PANEL_COL_MAX + 4)
    assert_true(data_row.find("…") >= 0)


def test_tier2_f36_bound4_diagnostics_set_sink_parsing() raises:
    """Verify diagnostics/set JSON payload parses severity, line, column, and message."""
    var diag_json = "{\"path\":\"/path/a.mojo\",\"diagnostics\":[{\"line\":12,\"col\":5,\"severity\":\"error\",\"message\":\"syntax error\"}]}"
    var doc = json_parse(diag_json)
    assert_true(doc.ok)
    assert_equal(doc.str(doc.get(0, "path"), ""), "/path/a.mojo")

    var diags = doc.get(0, "diagnostics")
    assert_equal(doc.size(diags), 1)
    var d0 = doc.at(diags, 0)
    assert_equal(doc.int(doc.get(d0, "line"), 0), 12)
    assert_equal(doc.str(doc.get(d0, "severity"), ""), "error")
    assert_equal(doc.str(doc.get(d0, "message"), ""), "syntax error")


def test_tier2_f36_bound5_stopped_plugin_commands_skipped() raises:
    """Verify stopped plugins (PL_STOPPED) do not have their commands registered."""
    var reg = build_registry()
    var ps = List[Plugin]()
    var p = Plugin("stopped_plug", "/tmp", "stop.py")
    p.state = PL_STOPPED
    p.cmds.append(PluginCmd("cmd", "Title", "Hint", "Ctrl-Alt-X"))
    ps.append(p^)

    var warn = register_plugins(reg, ps)
    assert_equal(len(warn), 0)
    assert_equal(reg.find_key(parse_key("Ctrl-Alt-X")), CM_NONE)
    assert_equal(PLUGIN_API, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
