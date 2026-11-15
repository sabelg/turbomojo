"""E2E Test Suite for Feature #20: User & Workspace Snippets & $TM_* Vars.
Covers Tier 1 (5 Happy Path tests) and Tier 2 (5 Boundary/Corner tests).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from snippets import (
    SnippetTemplate, SnippetStop, SnippetExpansion, expand_snippet_full, stop_rank,
    load_toml_snippets, load_vscode_snippets, expand_variables, expand_choice_and_tabstops,
)
from toml import toml_parse, TomlDoc
from json import json_parse, Json, J_STR, J_ARR, J_OBJ
from buffer import TextBuffer, Pos
from app import *
from appstate import App, M_NORMAL, M_COMPLETE
from signals import own_pid
from util import decode, to_str, env_or, run_system, shell_quote, str_bytes, bytes_to_str, write_file, read_file, path_exists


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f20-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


# ---------------------------------------------------------------------------
# Tier 1: Isolated Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f20_case1_load_user_toml_snippets() raises:
    """Load snippets from a user TOML configuration file."""
    var d = scratch("t1_c1")
    var toml_file = d + "/snippets.toml"
    var content = (
        "[bench]\n"
        "trigger = \"bench\"\n"
        "label = \"Benchmark Scaffold\"\n"
        "detail = \"std.benchmark runner\"\n"
        "body = \"from std.benchmark import run\\ndef test_bench():\\n    $0\"\n"
        "doc = \"Scaffolds a benchmark test.\"\n\n"
        "[kernel]\n"
        "trigger = \"kernel\"\n"
        "label = \"GPU Kernel\"\n"
        "detail = \"MAX GPU kernel\"\n"
        "body = \"from max.gpu import global_idx\\n$0\"\n"
        "doc = \"GPU kernel scaffold.\"\n"
    )
    _ = write_file(toml_file, str_bytes(content))
    var snips = load_toml_snippets(toml_file)
    assert_equal(len(snips), 2)
    
    var found_bench = False
    var found_kernel = False
    for i in range(len(snips)):
        if snips[i].trigger == "bench":
            found_bench = True
            assert_equal(snips[i].label, "Benchmark Scaffold")
            assert_true(snips[i].body.find("from std.benchmark") >= 0)
        elif snips[i].trigger == "kernel":
            found_kernel = True
            assert_equal(snips[i].label, "GPU Kernel")
            assert_true(snips[i].body.find("from max.gpu") >= 0)
    assert_true(found_bench and found_kernel)
    _ = run_system("rm -rf " + shell_quote(d))


def test_tier1_f20_case2_load_workspace_vscode_code_snippets() raises:
    """Load snippets from a workspace .vscode/*.code-snippets JSON file."""
    var d = scratch("t1_c2")
    var json_file = d + "/mojo.code-snippets"
    var content = (
        "{\n"
        "  \"Log Debug\": {\n"
        "    \"prefix\": \"logd\",\n"
        "    \"body\": [\n"
        "      \"print(\\\"DEBUG: \\\", ${1:val})\",\n"
        "      \"$0\"\n"
        "    ],\n"
        "    \"description\": \"Print debug output\"\n"
        "  }\n"
        "}\n"
    )
    _ = write_file(json_file, str_bytes(content))
    var snips = load_vscode_snippets(json_file)
    assert_equal(len(snips), 1)
    assert_equal(snips[0].trigger, "logd")
    assert_equal(snips[0].label, "Log Debug")
    assert_equal(snips[0].body, "print(\"DEBUG: \", ${1:val})\n$0")
    assert_equal(snips[0].doc, "Print debug output")
    _ = run_system("rm -rf " + shell_quote(d))


def test_tier1_f20_case3_choice_tabstop_expansion_defaults() raises:
    """Verify choice tabstop ${1|opt1,opt2|} expands to first choice with valid span."""
    var raw = "var dtype = DType.${1|float32,float16,bfloat16|}\nvar target = \"${2|cpu,gpu|}\"\n$0"
    var exp = expand_choice_and_tabstops(raw)
    assert_equal(exp.text, "var dtype = DType.float32\nvar target = \"cpu\"\n")
    assert_equal(len(exp.stops), 3)
    # Stop 1 covers "float32"
    assert_equal(exp.stops[0].num, 1)
    assert_equal(exp.stops[0].start, 18)
    assert_equal(exp.stops[0].end, 25)
    # Stop 2 covers "cpu"
    assert_equal(exp.stops[1].num, 2)
    assert_equal(exp.stops[2].num, 0)


def test_tier1_f20_case4_tm_variable_context_expansion() raises:
    """Verify $TM_* contextual editor variables are substituted correctly."""
    var raw = "// File: $TM_FILENAME (stem: $TM_FILENAME_BASE) at line $TM_LINE_NUMBER (idx: $TM_LINE_INDEX)"
    var expanded = expand_variables(raw, "matrix_ops.mojo", 42, "", "")
    assert_equal(expanded, "// File: matrix_ops.mojo (stem: matrix_ops) at line 42 (idx: 41)")


def test_tier1_f20_case5_clipboard_expansion_and_stop_sequencing() raises:
    """Verify $CLIPBOARD variable insertion alongside snippet tabstops."""
    var raw = "var initial = $CLIPBOARD\nvar ${1:name} = initial\n$0"
    var with_vars = expand_variables(raw, "main.mojo", 1, "", "100.5")
    assert_equal(with_vars, "var initial = 100.5\nvar ${1:name} = initial\n$0")
    var exp = expand_choice_and_tabstops(with_vars)
    assert_equal(exp.text, "var initial = 100.5\nvar name = initial\n")
    assert_equal(len(exp.stops), 2)
    assert_equal(exp.stops[0].num, 1)
    assert_equal(exp.stops[0].num, 1)


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f20_bound1_empty_and_missing_snippet_files() raises:
    """Missing or empty snippet file returns empty list safely."""
    var empty_toml = load_toml_snippets("/nonexistent/path/snippets.toml")
    assert_equal(len(empty_toml), 0)
    
    var d = scratch("t2_b1")
    var empty_file = d + "/empty.code-snippets"
    _ = write_file(empty_file, str_bytes(""))
    var empty_vscode = load_vscode_snippets(empty_file)
    assert_equal(len(empty_vscode), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_tier2_f20_bound2_malformed_toml_and_json_graceful_handling() raises:
    """Corrupted syntax in snippet files does not crash."""
    var d = scratch("t2_b2")
    var bad_toml = d + "/bad.toml"
    _ = write_file(bad_toml, str_bytes("[broken\ntrigger = \"foo\n"))
    var snips_toml = load_toml_snippets(bad_toml)
    # Parser reports problem and returns empty list gracefully
    assert_equal(len(snips_toml), 0)
    
    var bad_json = d + "/bad.code-snippets"
    _ = write_file(bad_json, str_bytes("{\"snippet\": {\"prefix\": \"f\", \"body\": [}"))
    var snips_json = load_vscode_snippets(bad_json)
    assert_equal(len(snips_json), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def test_tier2_f20_bound3_choice_single_item_and_empty_choice() raises:
    """Choice tabstop with single option and empty choice."""
    var raw = "var x = ${1|only|}\nvar y = ${2||}\n$0"
    var exp = expand_choice_and_tabstops(raw)
    assert_equal(exp.text, "var x = only\nvar y = \n")
    assert_equal(len(exp.stops), 3)
    assert_equal(exp.stops[0].start, 8)
    assert_equal(exp.stops[0].end, 12)
    assert_equal(exp.stops[1].start, 21)
    assert_equal(exp.stops[1].end, 21)


def test_tier2_f20_bound4_escaped_variables_and_unknown_tm_vars() raises:
    """Escaped \\$TM_FILENAME is not expanded; unknown variables stay untouched."""
    var raw = "echo \"\\$TM_FILENAME = $TM_FILENAME, other: $TM_UNKNOWN, clip: \\$CLIPBOARD\""
    var expanded = expand_variables(raw, "test.mojo", 5, "", "val")
    assert_equal(expanded, "echo \"$TM_FILENAME = test.mojo, other: $TM_UNKNOWN, clip: $CLIPBOARD\"")


def test_tier2_f20_bound5_multiline_clipboard_and_indentation() raises:
    """Multi-line clipboard expansion preserves snippet structure and indentation."""
    var raw = "def compute():\n    var block = \"\"\"\n    $CLIPBOARD\n    \"\"\"\n    $0"
    var clip = "alpha: 1\nbeta: 2"
    var with_clip = expand_variables(raw, "calc.mojo", 1, "", clip)
    var exp = expand_choice_and_tabstops(with_clip, "    ")
    assert_true(exp.text.find("alpha: 1\n    beta: 2") >= 0)
    assert_true(len(exp.stops) >= 1)
    assert_equal(exp.stops[0].num, 0)


def test_tier1_f20_app_workspace_snippets_in_completion_and_tm_vars() raises:
    """Verify App.ensure_user_snippets wires .vscode/*.code-snippets into M_COMPLETE and expands $TM_* + choices."""
    var d = scratch("app_ws_snips")
    _ = run_system("mkdir -p " + shell_quote(d + "/.vscode"))
    var vs_snips = (
        "{\n"
        "  \"Header Log\": {\n"
        "    \"prefix\": \"hdrlog\",\n"
        "    \"body\": [\n"
        "      \"# $TM_FILENAME ($TM_FILENAME_BASE) L$TM_LINE_NUMBER/$TM_LINE_INDEX clip=$CLIPBOARD\",\n"
        "      \"var ${1:dt} = DType.${2|float32,float16|} # ${1:dt}\",\n"
        "      \"$0\"\n"
        "    ],\n"
        "    \"description\": \"Context header + mirrored choice snippet\"\n"
        "  }\n"
        "}\n"
    )
    _ = write_file(d + "/.vscode/project.code-snippets", str_bytes(vs_snips))
    var src_p = d + "/kernel_ops.mojo"
    _ = write_file(src_p, str_bytes("# top\nhdrl\n"))

    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.project_dir = d
    app.clipboard = decode("OK42")
    app.open_path(src_p)
    var ei = app.find_editor(src_p)
    app.wins[ei].goto(1, 4)

    app.start_complete()
    assert_equal(app.mode, M_COMPLETE)
    var found = -1
    for i in range(len(app.comp_items)):
        if app.comp_items[i] == "Header Log":
            found = i
            break
    assert_true(found >= 0)
    app.comp_sel = found
    app.comp_accept(ei)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[ei].buf.line(1)), "# kernel_ops.mojo (kernel_ops) L2/1 clip=OK42")
    assert_equal(to_str(app.wins[ei].buf.line(2)), "var dt = DType.float32 # dt")
    # Mirrored $1 created 2 cursors on line 2 (`dt` and `# dt`), and Tab jumps to $2 (`float32`) shifted properly
    assert_equal(len(app.wins[ei].extra), 1)
    for ch in decode("elem_t"):
        app.wins[ei].multi(OP_TYPE, ch, True, False, List[Int]())
    assert_equal(to_str(app.wins[ei].buf.line(2)), "var elem_t = DType.float32 # elem_t")
    assert_true(app.snip_jump(ei, False))
    assert_equal(app.wins[ei].cr, 2)
    assert_equal(app.wins[ei].ac, 19)
    assert_equal(app.wins[ei].cc, 26)
    _ = run_system("rm -rf " + shell_quote(d))


# ---------------------------------------------------------------------------
# Test Runner
# ---------------------------------------------------------------------------

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
