"""E2E Test Suite for Feature #16:
Interleaved Source + Disassembly Stepping in WK_CPU (`tests/e2e/test_f16_disasm_stepping.mojo`).
Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from json import json_parse, JsonWriter
from cpuview import (
    Instr, hex_text,
    InstructionBreakpoint, JumpTarget, SourceMap,
    toggle_instruction_breakpoint, handle_enter_key_on_instruction, render_interleaved_cpu_lines,
)
from dap import (
    build_disassemble_request, parse_disassemble_response, build_set_instruction_breakpoints_request,
)


# ===========================================================================
# Tier 1: Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f16_case1_disassemble_fetch_96_instructions() raises:
    """Verify that disassemble request asks for 96 instructions and populates code list."""
    var req = build_disassemble_request("0xAAAA0F20", -8, 96)
    var doc = json_parse(req)
    assert_true(doc.ok)
    assert_equal(doc.str(doc.get(0, "command"), ""), "disassemble")
    var args = doc.get(0, "arguments")
    assert_equal(doc.int(doc.get(args, "instructionCount"), 0), 96)
    assert_equal(doc.str(doc.get(args, "memoryReference"), ""), "0xAAAA0F20")

    # Generate synthetic response with 96 instruction objects
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_bool("success", True)
    jw.key("body")
    jw.begin_obj()
    jw.key("instructions")
    jw.begin_arr()
    for i in range(96):
        jw.begin_obj()
        jw.kv_str("address", hex_text(0xAAAA0000 + i * 4))
        jw.kv_str("instruction", "nop")
        jw.end_obj()
    jw.end_arr()
    jw.end_obj()
    jw.end_obj()

    var instructions = parse_disassemble_response(jw.text())
    assert_equal(len(instructions), 96)
    assert_equal(instructions[0].address, hex_text(0xAAAA0000))
    assert_equal(instructions[95].address, hex_text(0xAAAA0000 + 95 * 4))


def test_tier1_f16_case2_interleaved_source_line_rendering() raises:
    """Verify that disassembly renders actual Mojo source lines on file/line transitions."""
    var code = List[Instr]()
    code.append(Instr("0xAAAA0F20", "mov x0, #42", "/home/user/vars.mojo", 5))
    code.append(Instr("0xAAAA0F24", "str x0, [sp, #8]", "/home/user/vars.mojo", 5))
    code.append(Instr("0xAAAA0F28", "bl 0xAAAA0100", "/home/user/vars.mojo", 6))

    var src = SourceMap()
    src.put("/home/user/vars.mojo:5", "var x = 42")
    src.put("/home/user/vars.mojo:6", "print(x)")

    var ibps = List[InstructionBreakpoint]()
    var lines = render_interleaved_cpu_lines(code, "0xAAAA0F20", ibps, src)

    # Line transition 5 should interleave the source code
    assert_true(lines[0].find("vars.mojo:5: var x = 42") >= 0)
    assert_true(lines[1].find("► 0xAAAA0F20  mov x0, #42") >= 0)
    assert_true(lines[2].find("  0xAAAA0F24  str x0, [sp, #8]") >= 0)
    # Line transition 6
    assert_true(lines[3].find("vars.mojo:6: print(x)") >= 0)
    assert_true(lines[4].find("  0xAAAA0F28  bl 0xAAAA0100") >= 0)


def test_tier1_f16_case3_instruction_breakpoint_toggle_b_key() raises:
    """In WK_CPU, pressing b on an instruction toggles an instruction breakpoint."""
    var ibps = List[InstructionBreakpoint]()
    var added = toggle_instruction_breakpoint(ibps, "0xAAAA0F24")
    assert_true(added)
    assert_equal(len(ibps), 1)
    assert_equal(ibps[0].address, "0xAAAA0F24")
    assert_true(ibps[0].verified)

    var req = build_set_instruction_breakpoints_request(ibps)
    var doc = json_parse(req)
    assert_true(doc.ok)
    assert_equal(doc.str(doc.get(0, "command"), ""), "setInstructionBreakpoints")
    var arr = doc.get(doc.get(0, "arguments"), "breakpoints")
    assert_equal(doc.size(arr), 1)
    assert_equal(doc.str(doc.get(doc.at(arr, 0), "instructionReference"), ""), "0xAAAA0F24")


def test_tier1_f16_case4_instruction_breakpoint_gutter_badge() raises:
    """Verify rendering of instruction breakpoint badge (●) distinct from current IP marker (►)."""
    var code = List[Instr]()
    code.append(Instr("0xAAAA0F20", "mov x0, #42", "/home/user/vars.mojo", 5))
    code.append(Instr("0xAAAA0F24", "str x0, [sp, #8]", "/home/user/vars.mojo", 5))

    var ibps = List[InstructionBreakpoint]()
    ibps.append(InstructionBreakpoint("0xAAAA0F24", True, 101))

    var src = SourceMap()
    var lines = render_interleaved_cpu_lines(code, "0xAAAA0F20", ibps, src)

    var found_ip = False
    var found_bp = False
    for i in range(len(lines)):
        if lines[i].find("► 0xAAAA0F20") >= 0:
            found_ip = True
        if lines[i].find("● 0xAAAA0F24") >= 0:
            found_bp = True

    assert_true(found_ip, "Current IP marker ► missing")
    assert_true(found_bp, "Instruction breakpoint badge ● missing")


def test_tier1_f16_case5_enter_jump_to_source_file_and_line() raises:
    """Pressing KEY_ENTER on instruction with valid path & line resolves editor jump location."""
    var ins = Instr("0xAAAA0F28", "bl 0xAAAA0100", "/home/user/vars.mojo", 18)
    var target = handle_enter_key_on_instruction(ins)

    assert_true(target.ok)
    assert_equal(target.path, "/home/user/vars.mojo")
    assert_equal(target.line, 18)
    assert_equal(target.editor_row, 17) # 0-based editor row
    assert_equal(target.error_message, "")


# ===========================================================================
# Tier 2: Boundary, Edge & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f16_bound1_enter_on_instruction_without_source() raises:
    """Pressing KEY_ENTER on instruction without source location safely rejects jump."""
    var ins = Instr("0x7FFFF7DC0000", "ret", "", 0) # e.g. libc stub
    var target = handle_enter_key_on_instruction(ins)

    assert_false(target.ok)
    assert_equal(target.error_message, "No source line for this instruction")
    assert_equal(target.path, "")


def test_tier2_f16_bound2_multiple_instruction_breakpoints_sync() raises:
    """Setting multiple instruction breakpoints and toggling one off preserves remaining ones."""
    var ibps = List[InstructionBreakpoint]()
    _ = toggle_instruction_breakpoint(ibps, "0xAAAA0F20")
    _ = toggle_instruction_breakpoint(ibps, "0xAAAA0F28")
    assert_equal(len(ibps), 2)

    # Toggle 0xAAAA0F20 off
    var added = toggle_instruction_breakpoint(ibps, "0xAAAA0F20")
    assert_false(added)
    assert_equal(len(ibps), 1)
    assert_equal(ibps[0].address, "0xAAAA0F28")

    var req = build_set_instruction_breakpoints_request(ibps)
    var doc = json_parse(req)
    var arr = doc.get(doc.get(0, "arguments"), "breakpoints")
    assert_equal(doc.size(arr), 1)
    assert_equal(doc.str(doc.get(doc.at(arr, 0), "instructionReference"), ""), "0xAAAA0F28")


def test_tier2_f16_bound3_instruction_stepping_updates_source_correlation() raises:
    """Stepping by instruction advances IP and updates current instruction marker and line."""
    var code = List[Instr]()
    code.append(Instr("0xAAAA0F20", "mov x0, #42", "/home/user/vars.mojo", 5))
    code.append(Instr("0xAAAA0F24", "str x0, [sp, #8]", "/home/user/vars.mojo", 5))

    var src = SourceMap()
    src.put("/home/user/vars.mojo:5", "var x = 42")
    var ibps = List[InstructionBreakpoint]()

    # Step 1: at 0xAAAA0F20
    var lines1 = render_interleaved_cpu_lines(code, "0xAAAA0F20", ibps, src)
    assert_true(lines1[1].startswith("► 0xAAAA0F20"))
    assert_true(lines1[2].startswith("  0xAAAA0F24"))

    # Step 2: instruction stepped to 0xAAAA0F24
    var lines2 = render_interleaved_cpu_lines(code, "0xAAAA0F24", ibps, src)
    assert_true(lines2[1].startswith("  0xAAAA0F20"))
    assert_true(lines2[2].startswith("► 0xAAAA0F24"))


def test_tier2_f16_bound4_missing_or_unreadable_source_file_fallback() raises:
    """Missing or unreadable source file falls back to printing path:line without panic."""
    var code = List[Instr]()
    code.append(Instr("0xAAAA0F30", "ldr x1, [sp, #16]", "/nonexistent/missing.mojo", 12))

    var src = SourceMap() # empty source map
    var ibps = List[InstructionBreakpoint]()
    var lines = render_interleaved_cpu_lines(code, "0xAAAA0F30", ibps, src)

    assert_equal(len(lines), 2)
    assert_equal(lines[0], "    missing.mojo:12")
    assert_true(lines[1].find("► 0xAAAA0F30  ldr x1, [sp, #16]") >= 0)


def test_tier2_f16_bound5_disassemble_at_page_boundary_partial_response() raises:
    """Disassembly near memory boundary returns partial list (e.g. 24 items) safely."""
    var code = List[Instr]()
    for i in range(24):
        code.append(Instr(hex_text(0x7FFF0000 + i * 4), "nop", "", 0))

    var src = SourceMap()
    var ibps = List[InstructionBreakpoint]()
    var lines = render_interleaved_cpu_lines(code, hex_text(0x7FFF0000), ibps, src)

    assert_equal(len(lines), 24)
    assert_true(lines[0].startswith("► " + hex_text(0x7FFF0000)))
    assert_true(lines[23].startswith("  " + hex_text(0x7FFF0000 + 23 * 4)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
