"""Mojo codegen & kernel inspector (`Compile > Inspect generated code`, WK_CODEGEN):
parses `mojo build --emit=asm` and `--emit=llvm` output, strips noisy assembler metadata
directives while keeping function labels and instructions, badges SIMD vector operations
(`[SIMD]`) and register stack spills (`[SPILL]`), and summarizes vectorization density."""
from std.collections import List


comptime CG_ASM = 0
comptime CG_LLVM = 1


@fieldwise_init
struct CodegenSummary(Copyable, Movable):
    var lines: List[String]
    var simd_ops: Int
    var spill_ops: Int
    var total_insns: Int


def is_noisy_asm_directive(trimmed: String) -> Bool:
    """Filter uninteresting DWARF/CFI/section directives while keeping labels and code."""
    for p in [
        ".cfi_", ".loc ", ".file ", ".ident", ".addrsig", ".size ", ".type ",
        ".p2align", ".align", ".section", ".text", ".globl", ".local", ".weak",
        ".hidden", ".subsections_via_symbols", ".build_version",
    ]:
        if trimmed.startswith(String(p)):
            return True
    return False


def is_simd_instruction(trimmed: String, mode: Int) -> Bool:
    """Detect x86 AVX/AVX-512, ARM NEON/SVE, PTX/AMDGCN, and LLVM `<N x T>` vector ops."""
    var low = trimmed.lower()
    if mode == CG_LLVM:
        # LLVM IR vector types look like `<4 x float>`, `<8 x i32>`, `shufflevector`, `insertelement`
        if low.find(" x float>") >= 0 or low.find(" x double>") >= 0 or low.find(" x half>") >= 0 or low.find(" x bfloat>") >= 0:
            return True
        if low.find(" x i8>") >= 0 or low.find(" x i16>") >= 0 or low.find(" x i32>") >= 0 or low.find(" x i64>") >= 0:
            return True
        if low.find("shufflevector") >= 0 or low.find("llvm.fma.") >= 0 or low.find("llvm.vector.reduce") >= 0:
            return True
        return False
    # Assembly: x86-64 ymm/zmm/xmm packed ops, AArch64 v0..v31.4s / z0..z31, PTX mma/ld.global.v4, AMDGCN v_mfma/v_pk_
    for tok in [
        "ymm", "zmm", "%ymm", "%zmm",
        "vfmadd", "vfmsub", "vaddps", "vaddpd", "vmulps", "vmulpd", "vsubps", "vdivps",
        "vmaxps", "vminps", "vpadd", "vpmul", "vpermp", "vshufp", "vbroadcast",
        ".4s", ".2d", ".8h", ".16b", "fmla ", "fmls ", "ld1 ", "st1 ",
        "mma.sync", "ld.global.v", "st.global.v", "v_mfma", "v_wmma", "v_pk_fma",
    ]:
        if low.find(String(tok)) >= 0:
            return True
    return False


def is_spill_instruction(trimmed: String, mode: Int) -> Bool:
    """Detect register stack spills and reloads in ASM, PTX, or LLVM IR."""
    var low = trimmed.lower()
    if mode == CG_LLVM:
        return low.find("alloca <") >= 0
    if low.find("spill") >= 0 or low.find("reload") >= 0:
        return True
    # x86 vector spill to stack frame (`vmovups ... (%rsp)` / `[rsp + ...]`) or PTX `.local`
    if (low.startswith("vmov") or low.startswith("movups") or low.startswith("movaps")) and (low.find("rsp") >= 0 or low.find("rbp") >= 0):
        return True
    if (low.startswith("str q") or low.startswith("ldr q") or low.startswith("stp q") or low.startswith("ldp q")) and low.find("sp") >= 0:
        return True
    if low.find("ld.local") >= 0 or low.find("st.local") >= 0:
        return True
    return False


def analyze_codegen(raw: String, mode: Int, filter_fn: String = "") -> CodegenSummary:
    """Format emitted assembly or LLVM IR with `[SIMD]` and `[SPILL]` badges."""
    var out = List[String]()
    var simd_n = 0
    var spill_n = 0
    var insn_n = 0
    var want = String(filter_fn.strip()).lower()
    var keep_block = want.byte_length() == 0
    for line_slice in raw.split("\n"):
        var raw_line = String(line_slice)
        if raw_line.endswith("\r"):
            var trimmed = String(raw_line[byte=0:raw_line.byte_length() - 1])
            raw_line = trimmed
        var t = String(raw_line.strip())
        if t.byte_length() == 0:
            if keep_block and len(out) > 0 and out[len(out) - 1].byte_length() > 0:
                out.append("")
            continue
        if mode == CG_ASM:
            if is_noisy_asm_directive(t):
                continue
            # Function / block label at column 0
            if not raw_line.startswith(" ") and not raw_line.startswith("\t") and t.endswith(":"):
                if want.byte_length() > 0 and not t.startswith("."):
                    keep_block = t.lower().find(want) >= 0
                if keep_block:
                    out.append(raw_line)
                continue
        else:
            if t.startswith("!"):
                continue
            if t.startswith("attributes #") or t.startswith("source_filename") or t.startswith("target datalayout") or t.startswith("target triple"):
                continue
            if t.startswith("define ") or t.startswith("declare "):
                if want.byte_length() > 0:
                    keep_block = t.lower().find(want) >= 0
                if keep_block:
                    out.append(raw_line)
                continue
            if t == "}":
                if keep_block:
                    out.append("}")
                    out.append("")
                if want.byte_length() > 0:
                    keep_block = False
                continue
        if not keep_block:
            continue
        var is_comment = t.startswith("#") or t.startswith("//") or t.startswith(";")
        if not is_comment:
            insn_n += 1
        var badge = String("         ")
        if not is_comment and is_spill_instruction(t, mode):
            spill_n += 1
            badge = "[SPILL]  "
        elif not is_comment and is_simd_instruction(t, mode):
            simd_n += 1
            badge = "[SIMD]   "
        out.append(badge + raw_line)
        if len(out) >= 6000:
            out.append("... (truncated at 6000 lines)")
            break
    return CodegenSummary(out^, simd_n, spill_n, insn_n)


def format_codegen_header(path_label: String, mode: Int, summary: CodegenSummary, filter_fn: String = "") -> List[String]:
    var kind = "Assembly (--emit=asm)" if mode == CG_ASM else "LLVM IR (--emit=llvm)"
    var out = List[String]()
    out.append("Codegen Inspector: " + path_label + "  [" + kind + "]")
    var filt = ("  ·  filter: " + filter_fn) if filter_fn.byte_length() > 0 else String("")
    out.append("Keys: a = ASM, l = LLVM IR, r = refresh, Esc = close" + filt)
    var spill_warn = ("  ⚠ " + String(summary.spill_ops) + " stack spill(s)") if summary.spill_ops > 0 else String("  ✓ 0 stack spills")
    out.append("Summary: " + String(summary.total_insns) + " instructions  ·  " + String(summary.simd_ops) + " [SIMD] vector ops" + spill_warn)
    out.append("────────────────────────────────────────────────────────────────────────")
    for l in summary.lines:
        out.append(l)
    if len(summary.lines) == 0:
        out.append("  (no matching functions or instructions emitted)")
    return out^
