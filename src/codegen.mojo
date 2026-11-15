"""Mojo codegen & kernel inspector (`Compile > Inspect generated code`, WK_CODEGEN):
parses `mojo build --emit=asm` and `--emit=llvm` output, strips noisy assembler metadata
directives while keeping function labels and instructions, badges SIMD vector operations
(`[SIMD]`) and register stack spills (`[SPILL]`), and summarizes vectorization density."""
from std.collections import List
from window import WK_EDITOR


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
    out.append("Keys: a = ASM, l = LLVM IR, f = filter def, Enter = jump, r = refresh, Esc = close" + filt)
    var spill_warn = ("  ⚠ " + String(summary.spill_ops) + " stack spill(s)") if summary.spill_ops > 0 else String("  ✓ 0 stack spills")
    out.append("Summary: " + String(summary.total_insns) + " instructions  ·  " + String(summary.simd_ops) + " [SIMD] vector ops" + spill_warn)
    out.append("────────────────────────────────────────────────────────────────────────")
    for l in summary.lines:
        out.append(l)
    if len(summary.lines) == 0:
        out.append("  (no matching functions or instructions emitted)")
    return out^


@fieldwise_init
struct CodegenCorrelation(Copyable, Movable):
    var rendered_lines: List[String]
    var line_map: List[Int]          # 1-based source line for each rendered line (0 if unmapped)
    var simd_ops: Int
    var spill_ops: Int
    var total_insns: Int
    var def_names: List[String]
    var def_start_lines: List[Int]
    var def_end_lines: List[Int]

    def __init__(out self):
        self.rendered_lines = List[String]()
        self.line_map = List[Int]()
        self.simd_ops = 0
        self.spill_ops = 0
        self.total_insns = 0
        self.def_names = List[String]()
        self.def_start_lines = List[Int]()
        self.def_end_lines = List[Int]()


@fieldwise_init
struct DILocInfo(Copyable, Movable):
    var line: Int
    var column: Int
    var inlined_at: Int


def parse_int_after(s: String, key: String) -> Int:
    """Extract integer following key in string s, or -1 if not found."""
    var p = s.find(key)
    if p < 0:
        return -1
    var b = s.as_bytes()
    var i = p + key.byte_length()
    while i < len(b) and (b[i] == 32 or b[i] == 9):
        i += 1
    var val = 0
    var found = False
    while i < len(b):
        var c = b[i]
        if c >= 48 and c <= 57:
            val = val * 10 + Int(c) - 48
            found = True
            i += 1
        else:
            break
    return val if found else -1


def resolve_dilocation_line(id: Int, meta_ids: List[Int], meta_locs: List[DILocInfo]) -> Int:
    for idx in range(len(meta_ids)):
        if meta_ids[idx] == id:
            var loc = meta_locs[idx].copy()
            if loc.inlined_at > 0:
                for j in range(len(meta_ids)):
                    if meta_ids[j] == loc.inlined_at:
                        return meta_locs[j].line
            return loc.line
    return 0


def parse_asm_with_line_tables(raw_asm: String, filter_def: String = "") -> CodegenCorrelation:
    """Parse assembly output with --debug-level=line-tables (.loc directives)."""
    var corr = CodegenCorrelation()
    var want = String(filter_def.strip()).lower()
    var keep_block = want.byte_length() == 0
    var primary_file_id = 1
    var current_source_line = 0
    var has_primary_file = False
    var current_def_idx = -1

    for line_slice in raw_asm.split("\n"):
        var raw_line = String(line_slice)
        var t = String(raw_line.strip())
        if t.byte_length() == 0:
            continue

        # .file directives: identify primary user file vs stdlib/inlined
        if t.startswith(".file"):
            var file_id = parse_int_after(t, ".file")
            if file_id > 0 and not has_primary_file:
                if t.find("std/") < 0:
                    primary_file_id = file_id
                    has_primary_file = True
            continue

        # .loc directives: associate subsequent instructions with source line
        if t.startswith(".loc"):
            var b = t.as_bytes()
            var p = 4  # skip ".loc"
            while p < len(b) and (b[p] == 32 or b[p] == 9):
                p += 1
            var f_id = 0
            while p < len(b) and b[p] >= 48 and b[p] <= 57:
                f_id = f_id * 10 + Int(b[p]) - 48
                p += 1
            while p < len(b) and (b[p] == 32 or b[p] == 9):
                p += 1
            var line_num = 0
            var got_line = False
            while p < len(b) and b[p] >= 48 and b[p] <= 57:
                line_num = line_num * 10 + Int(b[p]) - 48
                got_line = True
                p += 1
            if got_line:
                if f_id == primary_file_id or primary_file_id <= 0:
                    current_source_line = line_num
                else:
                    current_source_line = 0
            continue

        # Skip noisy DWARF directives
        if t.startswith(".cfi_") or t.startswith(".ident") or t.startswith(".size") or t.startswith(".type") or t.startswith(".section") or t.startswith(".text") or t.startswith(".globl") or t.startswith(".p2align"):
            continue

        # Function / block label at column 0
        if not raw_line.startswith(" ") and not raw_line.startswith("\t") and t.endswith(":"):
            var label_name = String(t[byte=0:t.byte_length() - 1])
            if current_def_idx >= 0 and current_def_idx < len(corr.def_end_lines):
                corr.def_end_lines[current_def_idx] = len(corr.rendered_lines)

            if want.byte_length() > 0:
                keep_block = label_name.lower().find(want) >= 0
            else:
                keep_block = True

            if not t.startswith("."):
                corr.def_names.append(label_name)
                corr.def_start_lines.append(len(corr.rendered_lines))
                corr.def_end_lines.append(len(corr.rendered_lines))
                current_def_idx = len(corr.def_names) - 1

            if keep_block and want.byte_length() == 0:
                corr.rendered_lines.append(t)
                corr.line_map.append(0)
            continue

        if not keep_block:
            continue

        var is_comment = t.startswith("#") or t.startswith("//") or t.startswith(";")
        if not is_comment:
            corr.total_insns += 1

        var badge = String("         ")
        if not is_comment and is_spill_instruction(t, CG_ASM):
            corr.spill_ops += 1
            badge = "[SPILL]  "
        elif not is_comment and is_simd_instruction(t, CG_ASM):
            corr.simd_ops += 1
            badge = "[SIMD]   "

        corr.rendered_lines.append(badge + t)
        corr.line_map.append(current_source_line)

    if current_def_idx >= 0 and current_def_idx < len(corr.def_end_lines):
        corr.def_end_lines[current_def_idx] = len(corr.rendered_lines)

    return corr^


def parse_llvm_with_line_tables(raw_llvm: String, filter_def: String = "") -> CodegenCorrelation:
    """Parse LLVM IR output with !dbg metadata and !DILocation line mapping."""
    var corr = CodegenCorrelation()
    var want = String(filter_def.strip()).lower()
    var keep_block = want.byte_length() == 0

    # Step 1: Collect metadata !DILocation mappings
    var meta_ids = List[Int]()
    var meta_locs = List[DILocInfo]()

    for line_slice in raw_llvm.split("\n"):
        var raw_line = String(line_slice)
        var t = String(raw_line.strip())
        if t.startswith("!") and t.find("!DILocation") >= 0:
            var id = parse_int_after(t, "!")
            var line_no = parse_int_after(t, "line:")
            var col_no = parse_int_after(t, "column:")
            var inlined_at = parse_int_after(t, "inlinedAt: !")
            if id >= 0 and line_no >= 0:
                meta_ids.append(id)
                meta_locs.append(DILocInfo(line_no, col_no, inlined_at))

    # Step 2: Parse instructions and correlate !dbg tags
    for line_slice in raw_llvm.split("\n"):
        var raw_line = String(line_slice)
        var t = String(raw_line.strip())
        if t.byte_length() == 0:
            continue

        # Strip metadata nodes from rendered output
        if t.startswith("!"):
            continue
        if t.startswith("attributes #") or t.startswith("source_filename") or t.startswith("target datalayout") or t.startswith("target triple"):
            continue

        if t.startswith("define ") or t.startswith("declare "):
            if want.byte_length() > 0:
                keep_block = t.lower().find(want) >= 0
            if keep_block and want.byte_length() == 0:
                corr.rendered_lines.append(t)
                corr.line_map.append(0)
            continue

        if t == "}":
            if want.byte_length() > 0:
                keep_block = False
            continue

        if not keep_block:
            continue

        var is_comment = t.startswith(";")
        if not is_comment:
            corr.total_insns += 1

        var src_line = 0
        var dbg_pos = t.find("!dbg !")
        if dbg_pos >= 0:
            var dbg_id = parse_int_after(t, "!dbg !")
            if dbg_id >= 0:
                src_line = resolve_dilocation_line(dbg_id, meta_ids, meta_locs)

        var badge = String("         ")
        if not is_comment and is_spill_instruction(t, CG_LLVM):
            corr.spill_ops += 1
            badge = "[SPILL]  "
        elif not is_comment and is_simd_instruction(t, CG_LLVM):
            corr.simd_ops += 1
            badge = "[SIMD]   "

        corr.rendered_lines.append(badge + t)
        corr.line_map.append(src_line)

    return corr^


def find_source_line_for_codegen(corr: CodegenCorrelation, codegen_line_idx: Int) -> Int:
    """Find the 1-based source line corresponding to a codegen output line index."""
    if codegen_line_idx >= 0 and codegen_line_idx < len(corr.line_map):
        return corr.line_map[codegen_line_idx]
    return 0


def find_codegen_lines_for_source(corr: CodegenCorrelation, source_line: Int) -> List[Int]:
    """Find all codegen line indices corresponding to a 1-based source line."""
    var out = List[Int]()
    if source_line <= 0:
        return out^
    for i in range(len(corr.line_map)):
        if corr.line_map[i] == source_line:
            out.append(i)
    return out^


def resolve_codegen_enter_jump(corr: CodegenCorrelation, codegen_row: Int, current_win: Int, current_cr: Int) -> Tuple[Int, Int, Bool]:
    """Resolve Enter key in Codegen window to jump to corresponding source line in Editor."""
    if codegen_row < 0 or codegen_row >= len(corr.line_map):
        return (current_win, current_cr, False)
    var src_line = corr.line_map[codegen_row]
    if src_line <= 0:
        return (current_win, current_cr, False)
    return (WK_EDITOR, src_line - 1, True)
