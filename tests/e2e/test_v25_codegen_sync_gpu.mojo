"""E2E Test Suite for v2.5.0 Milestone 4:
Live Source <-> Assembly / PTX / LLVM-IR Cursor Sync & GPU Register Pressure Badges.
"""
from std.testing import assert_equal, assert_true, TestSuite
from std.ffi import external_call
from std.time import perf_counter_ns
from codegen import (
    CG_ASM,
    parse_asm_with_line_tables,
    extract_kernel_resources,
    format_kernel_resource_badge,
)
from window import Window, WK_EDITOR, WK_CODEGEN, RM_OK, RM_WARN
from term import KEY_ENTER
from app import App
from signals import own_pid
from util import env_or, run_system, write_file, str_bytes, to_str


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v25-m4-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def test_v25_m4_01_ptx_ptxas_and_amdgcn_resource_extraction_and_mapping() raises:
    """Parse PTX `.loc` + `// file.mojo:line`, PTX `.reg`/`.shared`, `ptxas info`, and AMDGCN VGPR/LDS."""
    var ptx = (
        ".version 8.4\n"
        ".target sm_90\n"
        ".address_size 64\n"
        ".file 1 \"matmul.mojo\"\n"
        ".visible .entry matmul_tiled(\n"
        "    .param .u64 param_0,\n"
        "    .param .u64 param_1\n"
        ")\n"
        "{\n"
        "    .reg .pred %p<4>;\n"
        "    .reg .f32 %f<16>;\n"
        "    .reg .b32 %r<16>;\n"
        "    .shared .align 16 .f32 tile_a[1024];\n"
        "    .loc 1 8 5\n"
        "    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32 {%f1,%f2,%f3,%f4}, {%r1,%r2}, {%r3}, {%f1,%f2,%f3,%f4};\n"
        "    // matmul.mojo:11\n"
        "    st.global.v4.f32 [%rd1], {%f1, %f2, %f3, %f4};\n"
        "    ret;\n"
        "}\n"
    )
    var corr = parse_asm_with_line_tables(ptx)
    assert_equal(len(corr.def_names), 1)
    assert_equal(corr.def_names[0], "matmul_tiled")
    # Rendered: `matmul_tiled:` (line_map 0), `mma.sync` (8), `st.global.v4` (11), `ret;` (11)
    assert_equal(len(corr.rendered_lines), 4)
    assert_equal(corr.line_map[0], 0)
    assert_equal(corr.line_map[1], 8)
    assert_equal(corr.line_map[2], 11)
    assert_equal(corr.simd_ops, 2)

    var stats = extract_kernel_resources(ptx, CG_ASM)
    assert_equal(len(stats), 1)
    assert_equal(stats[0].name, "matmul_tiled")
    assert_true(stats[0].is_gpu)
    assert_equal(stats[0].regs, 32)
    assert_equal(stats[0].smem_bytes, 4096)
    assert_equal(stats[0].spills, 0)
    assert_equal(format_kernel_resource_badge(stats[0]), "[⚡ 32 regs | 4.0 KB smem | 0 spills]")

    # Verify `ptxas info` + spill detection and AMDGCN `.amdhsa_*` extraction
    var ptxas_and_hip = (
        "ptxas info    : Compiling entry function 'flash_attn' for 'sm_90'\n"
        "ptxas info    : Used 64 registers, 16384 bytes smem, 384 bytes cmem[0]\n"
        "ptxas info    : Function properties for flash_attn\n"
        "    16 bytes stack frame, 8 bytes spill stores, 8 bytes spill loads\n"
        ".amdhsa_kernel gemm_gfx942\n"
        "    .amdhsa_next_free_vgpr 48\n"
        "    .amdhsa_group_segment_fixed_size 8192\n"
    )
    var multi = extract_kernel_resources(ptxas_and_hip, CG_ASM)
    assert_equal(len(multi), 2)
    assert_equal(format_kernel_resource_badge(multi[0]), "[⚡ 64 regs | 16.0 KB smem | 2 spills]")
    assert_equal(format_kernel_resource_badge(multi[1]), "[⚡ 48 regs | 8.0 KB smem | 0 spills]")


def test_v25_m4_02_live_bidirectional_cursor_sync_and_editor_gpu_badges() raises:
    """Editor <-> Codegen cursor sync updates row highlights & scrolls without stealing focus, and attaches GPU badges."""
    var dir = _scratch("sync")
    var src_p = dir + "/matmul.mojo"
    var ptx_p = dir + "/matmul.ptx"
    var mojo_src = (
        "from std.memory import UnsafePointer\n"  # 1 (row 0)
        "\n"                                      # 2 (row 1)
        "def matmul_tiled(n: Int):\n"             # 3 (row 2) <- badge attaches here!
        "    var acc = n * 2\n"                   # 4 (row 3)
        "    acc += 4\n"                          # 5 (row 4)
        "    var out = acc * 3\n"                 # 6 (row 5)
        "    _ = out\n"                           # 7 (row 6)
    )
    var ptx_raw = (
        ".version 8.4\n"
        ".target sm_90\n"
        ".file 1 \"matmul.mojo\"\n"
        ".visible .entry _ZN6matmul12matmul_tiledE(\n"
        "    .param .u64 p0\n"
        ")\n"
        "{\n"
        "    .reg .f32 %f<16>;\n"
        "    .reg .b32 %r<16>;\n"
        "    .shared .align 16 .b8 smem_buf[4096];\n"
        "    .loc 1 4 5\n"
        "    mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32 {%f1,%f2,%f3,%f4}, {%r1,%r2}, {%r3}, {%f1,%f2,%f3,%f4};\n"
        "    .loc 1 6 5\n"
        "    st.local.f32 [%rd2], %f1;\n"
        "    ld.global.v4.f32 {%f5,%f6,%f7,%f8}, [%rd1];\n"
        "    ret;\n"
        "}\n"
    )
    _ = write_file(src_p, str_bytes(mojo_src))
    _ = write_file(ptx_p, str_bytes(ptx_raw))

    var app = App()
    app.scr.resize(120, 32)
    app.cwd = dir
    app.open_path(src_p)
    var ei = app.find_editor(src_p)
    app.wins[ei].cr = 3  # 1-based line 4

    var cg_win = Window(WK_CODEGEN, "Codegen: matmul.mojo", "", 60, 1, 60, 28, app.free_number())
    app.wins.append(cg_win^)
    app.codegen_mode = CG_ASM
    app.codegen_path = src_p
    app.codegen_out_file = ptx_p
    app.finish_codegen(0)

    # 1. Verify inline GPU resource badge attached to `def matmul_tiled` (row 2)
    ei = app.find_editor(src_p)
    assert_equal(len(app.wins[ei].bench_badge_rows), 1)
    assert_equal(app.wins[ei].bench_badge_rows[0], 2)
    assert_equal(app.wins[ei].bench_badges[0], "[⚡ 32 regs | 4.0 KB smem | 1 spill]")

    # 2. Focus editor and move cursor from row 3 (line 4) to row 5 (line 6) -> Codegen syncs live without stealing focus!
    app.focus(ei)
    ei = app.find_editor(src_p)
    app.wins[ei].cr = 5
    app.draw()
    assert_equal(app.wins[app.top()].kind, WK_EDITOR, "Focus must stay on WK_EDITOR during live cursor sync")
    var ci = app.codegen_index()
    assert_true(ci >= 0)
    assert_equal(app.codegen_line_map[app.wins[ci].cr], 6)
    # Row with `st.local` keeps RM_WARN (`[SPILL]`), next row (`ld.global.v4`) is RM_OK
    assert_equal(app.wins[ci].row_marks[app.wins[ci].cr], RM_WARN)
    assert_equal(app.wins[ci].row_marks[app.wins[ci].cr + 1], RM_OK)

    # 3. Focus Codegen and move cursor up to `mma.sync` (line 4) -> Editor cursor live-tracks to row 3!
    var mma_row = -1
    for r in range(len(app.codegen_line_map)):
        if app.codegen_line_map[r] == 4:
            mma_row = r
            break
    assert_true(mma_row > 0)
    app.focus(ci)
    ci = app.codegen_index()
    app.wins[ci].cr = mma_row
    app.draw()
    ei = app.find_editor(src_p)
    assert_equal(app.wins[ei].cr, 3, "Moving cursor in WK_CODEGEN must live-track WK_EDITOR row")

    # Pressing Enter in WK_CODEGEN transfers focus back to WK_EDITOR at row 3
    assert_true(app.codegen_key(KEY_ENTER))
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)
    assert_equal(app.wins[app.top()].cr, 3)

    _ = run_system("rm -rf '" + dir + "'")


def test_v25_m4_03_live_compiler_codegen_open_and_cpu_simd_badge() raises:
    """Real `app.codegen_open()` runs `mojo build --debug-level=line-tables --emit=asm` and attaches badges."""
    var dir = _scratch("live_cg")
    var src_p = dir + "/vec_kern.mojo"
    var src = (
        "@export\n"
        "def scale_simd(n: Int) abi(\"C\") -> Float32:\n"
        "    var v = SIMD[DType.float32, 8](1.0)\n"
        "    for i in range(n):\n"
        "        v = v * 2.5 + Float32(i)\n"
        "    return v.reduce_add()\n"
        "\n"
        "def main():\n"
        "    print(scale_simd(64))\n"
    )
    _ = write_file(src_p, str_bytes(src))

    var app = App()
    app.scr.resize(120, 32)
    app.cwd = dir
    app.open_path(src_p)
    app.codegen_open()

    var deadline = Int(perf_counter_ns()) + 45_000_000_000
    while app.aux_job.active and Int(perf_counter_ns()) < deadline:
        app.poll_aux_job()
        _ = external_call["usleep", Int32](UInt32(20000))

    var ci = app.codegen_index()
    assert_true(ci >= 0)
    assert_true(len(app.codegen_line_map) > 5, "Expected populated codegen_line_map from live mojo build")
    var cg_txt = to_str(app.wins[ci].buf.all_text())
    assert_true(cg_txt.find(".debug_info") < 0 and cg_txt.find(".byte\t") < 0, "DWARF data sections must be stripped from Codegen pane")
    var ei = app.find_editor(src_p)
    assert_true(len(app.wins[ei].bench_badges) >= 1, "Expected inline codegen resource badge on scale_simd")
    assert_true(app.wins[ei].bench_badges[0].find("⚡") >= 0, app.wins[ei].bench_badges[0])

    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
