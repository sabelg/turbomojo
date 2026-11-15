"""E2E Test Suite for Feature #7: Bidirectional Codegen Line Correlation.
Covers Tier 1 (5 Happy Path tests), Tier 2 (5 Boundary/Corner tests), and App integration.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from codegen import (
    CodegenCorrelation, parse_asm_with_line_tables, parse_llvm_with_line_tables,
    find_source_line_for_codegen, find_codegen_lines_for_source,
    resolve_codegen_enter_jump, CG_ASM,
)
from window import Window, WK_EDITOR, WK_CODEGEN
from term import KEY_ENTER
from app import *
from appstate import App
from harness import ScratchDir, make_test_app


# ---------------------------------------------------------------------------
# Tier 1 Tests: Happy Path
# ---------------------------------------------------------------------------

def test_tier1_f07_asm_loc_parsing_and_line_mapping() raises:
    """Tier 1: ASM .loc line parsing, .loc stripping, and SIMD/spill badges."""
    var raw_asm = (
        ".file 1 \"kernel.mojo\"\n"
        ".loc 1 12 5\n"
        "vfmadd213ps %zmm0, %zmm1, %zmm2\n"
        ".loc 1 13 5\n"
        "vmovups %zmm0, 64(%rsp)\n"
    )
    var corr = parse_asm_with_line_tables(raw_asm)
    assert_equal(len(corr.rendered_lines), 2)
    assert_equal(corr.line_map[0], 12)
    assert_equal(corr.line_map[1], 13)
    assert_equal(corr.simd_ops, 1)
    assert_equal(corr.spill_ops, 1)
    assert_equal(corr.total_insns, 2)
    assert_true(corr.rendered_lines[0].startswith("[SIMD]   "))
    assert_true(corr.rendered_lines[1].startswith("[SPILL]  "))


def test_tier1_f07_llvm_dbg_dilocation_parsing() raises:
    """Tier 1: LLVM IR !dbg / !DILocation line mapping and metadata stripping."""
    var raw_llvm = (
        "%3 = fadd <8 x float> %1, %2, !dbg !15\n"
        "%4 = fmul <8 x float> %3, %2, !dbg !16\n"
        "!15 = !DILocation(line: 42, column: 5, scope: !7)\n"
        "!16 = !DILocation(line: 43, column: 5, scope: !7)\n"
    )
    var corr = parse_llvm_with_line_tables(raw_llvm)
    assert_equal(len(corr.rendered_lines), 2)
    assert_equal(corr.line_map[0], 42)
    assert_equal(corr.line_map[1], 43)
    assert_equal(corr.simd_ops, 2)
    assert_equal(corr.total_insns, 2)
    assert_true(corr.rendered_lines[0].startswith("[SIMD]   "))


def test_tier1_f07_bidirectional_correlation_lookup() raises:
    """Tier 1: Symmetric bidirectional line lookup between codegen and source."""
    var corr = CodegenCorrelation()
    corr.line_map.append(10)
    corr.line_map.append(10)
    corr.line_map.append(11)
    corr.line_map.append(11)
    corr.line_map.append(11)
    corr.line_map.append(12)
    corr.line_map.append(13)
    corr.line_map.append(14)
    corr.line_map.append(15)
    corr.line_map.append(15)

    assert_equal(find_source_line_for_codegen(corr, 3), 11)
    var matches = find_codegen_lines_for_source(corr, 11)
    assert_equal(len(matches), 3)
    assert_equal(matches[0], 2)
    assert_equal(matches[1], 3)
    assert_equal(matches[2], 4)


def test_tier1_f07_enter_jump_to_source_navigation() raises:
    """Tier 1: Enter on mapped codegen line switches to Editor at source row."""
    var corr = CodegenCorrelation()
    for _ in range(5):
        corr.line_map.append(10)
    corr.line_map.append(28)  # Index 5 maps to line 28

    var res = resolve_codegen_enter_jump(corr, 5, WK_CODEGEN, 0)
    assert_true(res[2])                 # did_jump == True
    assert_equal(res[0], WK_EDITOR)     # switched to editor
    assert_equal(res[1], 27)            # 0-based row (line 28 - 1)


def test_tier1_f07_filter_to_enclosing_def() raises:
    """Tier 1: Filter assembly output to only the enclosing def."""
    var raw_asm = (
        "matmul:\n"
        "    vfmadd213ps %zmm0, %zmm1, %zmm2\n"
        "    vfmadd213ps %zmm3, %zmm4, %zmm5\n"
        "    vfmadd213ps %zmm6, %zmm7, %zmm8\n"
        "    vmovups %zmm0, (%rdi)\n"
        "    retq\n"
        "softmax:\n"
        "    vaddps %zmm0, %zmm1, %zmm2\n"
        "    vsubps %zmm3, %zmm4, %zmm5\n"
        "    vmulps %zmm6, %zmm7, %zmm8\n"
        "    vdivps %zmm0, %zmm1, %zmm2\n"
        "    retq\n"
    )
    var corr = parse_asm_with_line_tables(raw_asm, "matmul")
    assert_equal(corr.total_insns, 5)
    assert_equal(len(corr.rendered_lines), 5)
    for l in corr.rendered_lines:
        assert_false(l.find("softmax") >= 0)


# ---------------------------------------------------------------------------
# Tier 2 Tests: Boundary & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f07_asm_multiple_files_and_interleaved_loc() raises:
    """Tier 2: Interleaved .loc from stdlib files does not map to user source lines."""
    var raw_asm = (
        ".file 1 \"user.mojo\"\n"
        ".file 2 \"std/math.mojo\"\n"
        ".loc 1 10 2\n"
        "vfmadd213ps %zmm0, %zmm1, %zmm2\n"
        ".loc 2 55 4\n"
        "vaddps %zmm3, %zmm4, %zmm5\n"
        ".loc 1 11 2\n"
        "vmovups %zmm0, (%rax)\n"
    )
    var corr = parse_asm_with_line_tables(raw_asm)
    assert_equal(len(corr.rendered_lines), 3)
    assert_equal(corr.line_map[0], 10)
    assert_equal(corr.line_map[1], 0)   # file 2 inlined stdlib mapped to 0
    assert_equal(corr.line_map[2], 11)


def test_tier2_f07_llvm_inlined_dilocation_scope() raises:
    """Tier 2: Resolves outer callsite line for inlined !DILocation scope."""
    var raw_llvm = (
        "%1 = fadd float %a, %b, !dbg !18\n"
        "!18 = !DILocation(line: 18, scope: !5, inlinedAt: !20)\n"
        "!20 = !DILocation(line: 95, scope: !2)\n"
    )
    var corr = parse_llvm_with_line_tables(raw_llvm)
    assert_equal(len(corr.rendered_lines), 1)
    assert_equal(corr.line_map[0], 95)


def test_tier2_f07_enter_on_unmapped_header_or_label() raises:
    """Tier 2: Enter on unmapped label or header preserves editor cursor."""
    var corr = CodegenCorrelation()
    corr.rendered_lines.append("matmul:")
    corr.line_map.append(0)

    var res = resolve_codegen_enter_jump(corr, 0, WK_CODEGEN, 15)
    assert_false(res[2])                # did_jump == False
    assert_equal(res[0], WK_CODEGEN)    # remained in WK_CODEGEN
    assert_equal(res[1], 15)            # cursor preserved


def test_tier2_f07_empty_or_malformed_codegen_output() raises:
    """Tier 2: Empty or malformed codegen output does not crash."""
    var corr1 = parse_asm_with_line_tables("")
    assert_equal(corr1.total_insns, 0)
    assert_equal(len(corr1.rendered_lines), 0)
    assert_equal(len(corr1.line_map), 0)

    var corr2 = parse_llvm_with_line_tables("error: compilation failed\naborted\n")
    assert_equal(corr2.total_insns, 2)
    assert_equal(corr2.line_map[0], 0)
    assert_equal(corr2.line_map[1], 0)


def test_tier2_f07_filter_nonexistent_def() raises:
    """Tier 2: Filtering on a non-existent def returns empty instruction list."""
    var raw_asm = (
        "matmul:\n"
        "    vfmadd213ps %zmm0, %zmm1, %zmm2\n"
        "    retq\n"
    )
    var corr = parse_asm_with_line_tables(raw_asm, "nonexistent_kernel")
    assert_equal(corr.total_insns, 0)
    assert_equal(len(corr.rendered_lines), 0)


def test_app_f07_finish_codegen_and_enter_jump() raises:
    """App integration: finish_codegen populates header-aligned codegen_line_map and Enter jumps."""
    var s = ScratchDir.create("f07_app")
    var src_path = s.path + "/kern.mojo"
    s.write("kern.mojo", "def alpha():\n    pass\n\ndef beta():\n    var x = 1\n    _ = x\n")
    var asm_path = s.path + "/kern.s"
    s.write(
        "kern.s",
        ".file 1 \"kern.mojo\"\n"
        "beta:\n"
        "    .loc 1 5 5\n"
        "    vfmadd213ps %zmm0, %zmm1, %zmm2\n",
    )

    var app = make_test_app(s)
    app.open_path(src_path)
    var ei = app.find_editor(src_path)
    app.wins[ei].cr = 4

    var cg_win = Window(WK_CODEGEN, "Codegen: kern.mojo", "", 40, 1, 60, 20, app.free_number())
    app.wins.append(cg_win^)
    app.codegen_mode = CG_ASM
    app.codegen_path = src_path
    app.codegen_out_file = asm_path
    app.finish_codegen(0)

    var ci = app.codegen_index()
    assert_true(ci >= 0)
    assert_equal(len(app.codegen_line_map), app.wins[ci].buf.count())
    # 4 header lines (0..3) + label "beta:" (4) -> row 5 maps to source line 5
    assert_equal(app.codegen_line_map[0], 0)
    assert_equal(app.codegen_line_map[4], 0)
    assert_equal(app.codegen_line_map[5], 5)

    # Move cursor in WK_CODEGEN to row 5 and press Enter -> jumps to WK_EDITOR row 4 (0-based)
    app.wins[ei].cr = 0
    app.focus(ci)
    ci = app.codegen_index()
    app.wins[ci].cr = 5
    assert_true(app.codegen_key(KEY_ENTER))
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    assert_equal(app.wins[app.top()].cr, 4)

    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
