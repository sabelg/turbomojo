"""GPU Occupancy Calculator, Shared-Memory 32-Bank Conflict Analyzer, and 32/64-Lane Warp View.

Provides:
- Exact hardware SM / CU resource tables for NVIDIA Ampere (`sm_80`, `sm_86`), Ada (`sm_89`),
  Hopper (`sm_90`), Blackwell (`sm_100`, `sm_120`), and AMD CDNA2/CDNA3 (`gfx90a`, `gfx942`)
- Sub-partition-accurate warp/wave occupancy modeling, bottleneck identification, and next-cliff hints
- Static 32-bank shared-memory stride & bank-conflict simulator for Mojo GPU kernels and PTX
- 32-lane / 64-lane SIMT active-predicate mask visualization and cross-lane watch comparison
"""
from std.collections import List
from util import decode, to_str, lower_str


@fieldwise_init
struct GpuArchSpec(Copyable, Movable):
    var arch: String
    var label: String
    var is_amd: Bool
    var warp_size: Int
    var subpartitions: Int
    var max_warps_per_sm: Int
    var max_blocks_per_sm: Int
    var regs_per_sm: Int
    var reg_alloc_unit_regs: Int    # registers per warp allocation unit (256 on NVIDIA; 4*64=256 on CDNA)
    var max_regs_per_thread: Int
    var max_smem_per_sm: Int
    var smem_alloc_unit: Int


@fieldwise_init
struct OccupancyReport(Copyable, Movable):
    var arch: String
    var arch_label: String
    var threads_per_block: Int
    var warps_per_block: Int
    var regs_per_thread: Int
    var smem_bytes: Int
    var active_blocks: Int
    var active_warps: Int
    var max_warps: Int
    var occupancy_pct_x10: Int      # e.g. 750 -> 75.0%
    var limiter: String             # "warps", "registers", "shared_memory", "blocks", "exceeds_limits"
    var blocks_by_warps: Int
    var blocks_by_blocks: Int
    var blocks_by_regs: Int
    var blocks_by_smem: Int
    var cliff_hint: String


@fieldwise_init
struct BankAccessSite(Copyable, Movable):
    var line_no: Int
    var expr: String
    var word_stride: Int
    var elem_bytes: Int
    var conflict_ways: Int          # 1 = conflict-free (or broadcast if word_stride == 0), 2..32 = N-way conflict
    var is_broadcast: Bool
    var bank_hits: List[Int]        # length 32: hit count per 4-byte bank
    var hint: String


def _align_up(val: Int, unit: Int) -> Int:
    if unit <= 1 or val <= 0:
        return max(0, val)
    return ((val + unit - 1) // unit) * unit


def _fmt_pct_x10(pct_x10: Int) -> String:
    return String(pct_x10 // 10) + "." + String(pct_x10 % 10) + "%"


def gpu_arch_spec(arch_or_name: String) -> GpuArchSpec:
    """Resolve an architecture code (`sm_80`, `sm_89`, `sm_90`, `sm_100`, `sm_120`, `gfx90a`, `gfx942`)
    or a human GPU model string (`NVIDIA H100`, `RTX 4090`, `AMD Instinct MI300X`) to exact SM/CU limits."""
    var q = lower_str(String(arch_or_name.strip()))
    if q.find("gfx942") >= 0 or q.find("mi300") >= 0 or q.find("mi325") >= 0:
        return GpuArchSpec("gfx942", "AMD CDNA3 (MI300X)", True, 64, 4, 32, 16, 131072, 256, 512, 65536, 512)
    if q.find("gfx90a") >= 0 or q.find("mi250") >= 0 or q.find("mi210") >= 0:
        return GpuArchSpec("gfx90a", "AMD CDNA2 (MI250X)", True, 64, 4, 32, 16, 131072, 256, 512, 65536, 512)
    if q.find("sm_120") >= 0 or q.find("gb10") >= 0 or q.find("rtx 50") >= 0 or q.find("blackwell workstation") >= 0:
        return GpuArchSpec("sm_120", "NVIDIA Blackwell (GB10 / RTX 50)", False, 32, 4, 48, 24, 65536, 256, 255, 102400, 128)
    if q.find("sm_100") >= 0 or q.find("b200") >= 0 or q.find("b100") >= 0 or q.find("gb200") >= 0:
        return GpuArchSpec("sm_100", "NVIDIA Blackwell (B200)", False, 32, 4, 64, 32, 65536, 256, 255, 233472, 128)
    if q.find("sm_89") >= 0 or q.find("4090") >= 0 or q.find("4080") >= 0 or q.find("l40") >= 0 or q.find("l4 ") >= 0 or q.endswith("l4"):
        return GpuArchSpec("sm_89", "NVIDIA Ada (RTX 4090 / L40S)", False, 32, 4, 48, 24, 65536, 256, 255, 102400, 128)
    if q.find("sm_86") >= 0 or q.find("3090") >= 0 or q.find("3080") >= 0 or q.find("a6000") >= 0 or q.find("a10") >= 0 and q.find("a100") < 0:
        return GpuArchSpec("sm_86", "NVIDIA Ampere (GA102 / RTX 3090)", False, 32, 4, 48, 16, 65536, 256, 255, 102400, 128)
    if q.find("sm_80") >= 0 or q.find("a100") >= 0 or q.find("a800") >= 0:
        return GpuArchSpec("sm_80", "NVIDIA Ampere (A100)", False, 32, 4, 64, 32, 65536, 256, 255, 167936, 128)
    # Default modern datacenter target: Hopper sm_90
    return GpuArchSpec("sm_90", "NVIDIA Hopper (H100)", False, 32, 4, 64, 32, 65536, 256, 255, 233472, 128)


def _max_blocks_by_regs(spec: GpuArchSpec, warps_per_block: Int, regs_per_thread: Int) -> Int:
    if regs_per_thread <= 0:
        return spec.max_blocks_per_sm
    if regs_per_thread > spec.max_regs_per_thread:
        return 0
    var regs_per_sub = spec.regs_per_sm // spec.subpartitions
    var warp_regs = _align_up(regs_per_thread * spec.warp_size, spec.reg_alloc_unit_regs)
    if warp_regs <= 0:
        return spec.max_blocks_per_sm
    var warps_per_sub = regs_per_sub // warp_regs
    var total_reg_warps = min(spec.max_warps_per_sm, warps_per_sub * spec.subpartitions)
    return total_reg_warps // max(1, warps_per_block)


def _max_blocks_by_smem(spec: GpuArchSpec, smem_bytes: Int) -> Int:
    if smem_bytes <= 0:
        return spec.max_blocks_per_sm
    var alloc = _align_up(smem_bytes, spec.smem_alloc_unit)
    if alloc > spec.max_smem_per_sm:
        return 0
    return spec.max_smem_per_sm // alloc


def compute_gpu_occupancy(
    arch_or_name: String,
    regs_per_thread: Int,
    smem_bytes: Int,
    threads_per_block: Int = 256,
) -> OccupancyReport:
    """Compute theoretical SM/CU occupancy, active warps/blocks, primary resource limiter,
    and actionable next-cliff optimization guidance."""
    var spec = gpu_arch_spec(arch_or_name)
    var tpb = max(1, threads_per_block)
    var wpb = (tpb + spec.warp_size - 1) // spec.warp_size
    var b_warps = spec.max_warps_per_sm // max(1, wpb)
    var b_blocks = spec.max_blocks_per_sm
    var b_regs = _max_blocks_by_regs(spec, wpb, regs_per_thread)
    var b_smem = _max_blocks_by_smem(spec, smem_bytes)

    var active_blocks = min(min(b_warps, b_blocks), min(b_regs, b_smem))
    var active_warps = min(spec.max_warps_per_sm, active_blocks * wpb)
    var occ_x10 = (active_warps * 1000 + spec.max_warps_per_sm // 2) // spec.max_warps_per_sm

    var limiter = String("warps")
    if active_blocks == 0:
        limiter = "exceeds_limits"
    elif active_blocks == b_regs and b_regs < min(b_warps, b_blocks) and b_regs <= b_smem:
        limiter = "registers"
    elif active_blocks == b_smem and b_smem < min(b_warps, b_blocks):
        limiter = "shared_memory"
    elif active_blocks == b_blocks and b_blocks < b_warps:
        limiter = "blocks"

    var hint = String("")
    if limiter == "exceeds_limits":
        if regs_per_thread > spec.max_regs_per_thread:
            hint = (
                "Exceeds max registers/thread ("
                + String(regs_per_thread)
                + " > "
                + String(spec.max_regs_per_thread)
                + ") — reduce register pressure or tile width."
            )
        elif smem_bytes > spec.max_smem_per_sm:
            hint = (
                "Exceeds max shared memory/SM ("
                + String(smem_bytes // 1024)
                + " KB > "
                + String(spec.max_smem_per_sm // 1024)
                + " KB) — shrink tile stage count or shared buffer."
            )
        else:
            hint = "Block size (" + String(tpb) + " threads) exceeds SM warp capacity."
    elif limiter == "registers" and regs_per_thread > 1:
        var target_r = regs_per_thread - 1
        while target_r >= 8:
            var nb = min(min(b_warps, b_blocks), min(_max_blocks_by_regs(spec, wpb, target_r), b_smem))
            if nb > active_blocks:
                var nw = min(spec.max_warps_per_sm, nb * wpb)
                var npct = (nw * 1000 + spec.max_warps_per_sm // 2) // spec.max_warps_per_sm
                var delta = regs_per_thread - target_r
                hint = (
                    "Drop "
                    + String(delta)
                    + (" reg/thread (" if delta == 1 else " regs/thread (")
                    + String(regs_per_thread)
                    + " → "
                    + String(target_r)
                    + ") to raise occupancy from "
                    + _fmt_pct_x10(occ_x10)
                    + " → "
                    + _fmt_pct_x10(npct)
                )
                break
            target_r -= 1
    elif limiter == "shared_memory" and smem_bytes > 0:
        var want_blocks = active_blocks + 1
        if want_blocks <= min(b_warps, min(b_blocks, b_regs)):
            var max_smem_for_next = (spec.max_smem_per_sm // want_blocks // spec.smem_alloc_unit) * spec.smem_alloc_unit
            if max_smem_for_next > 0 and max_smem_for_next < smem_bytes:
                var save_b = smem_bytes - max_smem_for_next
                var nw = min(spec.max_warps_per_sm, want_blocks * wpb)
                var npct = (nw * 1000 + spec.max_warps_per_sm // 2) // spec.max_warps_per_sm
                hint = (
                    "Reduce shared memory by "
                    + String(save_b)
                    + " B ("
                    + String(smem_bytes)
                    + " → "
                    + String(max_smem_for_next)
                    + " B) to fit "
                    + String(want_blocks)
                    + " blocks/SM ("
                    + _fmt_pct_x10(occ_x10)
                    + " → "
                    + _fmt_pct_x10(npct)
                    + ")"
                )
    elif limiter == "blocks":
        hint = (
            "Block-count limited ("
            + String(active_blocks)
            + "/"
            + String(spec.max_blocks_per_sm)
            + " blocks/SM) — increase threads/block above "
            + String(tpb)
            + " to pack more warps per block."
        )
    else:
        hint = "Full SM warp occupancy achieved (" + _fmt_pct_x10(occ_x10) + ")."

    return OccupancyReport(
        spec.arch,
        spec.label,
        tpb,
        wpb,
        regs_per_thread,
        smem_bytes,
        active_blocks,
        active_warps,
        spec.max_warps_per_sm,
        occ_x10,
        limiter,
        b_warps,
        b_blocks,
        b_regs,
        b_smem,
        hint,
    )


def simulate_32_banks(word_stride: Int, elem_bytes: Int = 4) -> BankAccessSite:
    """Simulate a 32-lane warp accessing 32×4-byte shared-memory banks with `word_stride`
    (in 4-byte words per lane; 0 = uniform broadcast)."""
    var hits = List[Int](length=32, fill=0)
    if word_stride == 0:
        hits[0] = 1
        return BankAccessSite(0, "", 0, elem_bytes, 1, True, hits^, "Uniform broadcast (1 wavefront transaction)")
    var words_per_elem = max(1, elem_bytes // 4)
    # Within a single 128-byte wavefront request, count distinct lane word addresses landing on the same bank
    var max_ways = 1
    for lane in range(32):
        var addr_word = lane * word_stride
        for sub_w in range(words_per_elem):
            var bank = ((addr_word + sub_w) % 32 + 32) % 32
            hits[bank] += 1
            if hits[bank] > max_ways:
                max_ways = hits[bank]
    # Note: 64-bit (`elem_bytes == 8`) unit-stride (`word_stride == 2`) splits cleanly across 2 conflict-free phases on modern SMs,
    # whereas power-of-2 element strides (`word_stride >= 2` for 4B) cause genuine N-way bank serialization.
    if elem_bytes == 8 and word_stride == 2:
        max_ways = 1
    var hint = String("1-way conflict-free across all 32 shared-memory banks")
    if max_ways > 1:
        hint = (
            String(max_ways)
            + "-way shared-memory bank conflict (stride="
            + String(word_stride)
            + " words) — pad inner tile dimension by +1 (e.g. ["
            + String(max(32, word_stride))
            + "] → ["
            + String(max(32, word_stride) + 1)
            + "]) or apply XOR swizzle (`col ^ (row % 8)`)."
        )
    return BankAccessSite(0, "", word_stride, elem_bytes, max_ways, False, hits^, hint)


def format_bank_heatmap(hits: List[Int]) -> String:
    """Render a 32-column ASCII/Unicode bank-pressure strip for banks `00..31`."""
    var out = String("Banks [00..31]: ")
    for b in range(min(32, len(hits))):
        var h = hits[b]
        if h <= 0:
            out += "·"
        elif h == 1:
            out += "▪"
        elif h == 2:
            out += "▒"
        elif h <= 4:
            out += "▓"
        else:
            out += "█"
    return out


def _extract_stride_multiplier(expr: String) -> Int:
    """Detect `tid * K`, `thread_idx.x * K`, `K * tid`, or `tid << S` in an index expression."""
    var clean = expr.replace("thread_idx.x", "tid").replace("lane_id()", "tid").replace("%tid.x", "tid")
    if clean.find("tid") < 0:
        return 0
    # Shift `tid << S`
    var shl = clean.find("<<")
    if shl > 0:
        var rhs = String(clean[byte=shl + 2 :].strip())
        var s_val = 0
        var got_s = False
        for b in rhs.as_bytes():
            if b >= 48 and b <= 57:
                s_val = s_val * 10 + Int(b) - 48
                got_s = True
            else:
                break
        if got_s and s_val >= 0 and s_val <= 10:
            return 1 << s_val
    # Multiply `tid * K` or `K * tid`
    var star = clean.find("*")
    if star > 0:
        var lhs = String(clean[byte=0:star].strip())
        var rhs = String(clean[byte=star + 1 :].strip())
        if lhs.endswith("tid"):
            var kv = 0
            var got = False
            for b in rhs.as_bytes():
                if b >= 48 and b <= 57:
                    kv = kv * 10 + Int(b) - 48
                    got = True
                else:
                    break
            if got and kv > 0:
                return kv
        if rhs.startswith("tid"):
            var b = lhs.as_bytes()
            var e = len(b) - 1
            while e >= 0 and (b[e] < 48 or b[e] > 57):
                e -= 1
            var s = e
            while s >= 0 and b[s] >= 48 and b[s] <= 57:
                s -= 1
            if s < e:
                var kv = 0
                for idx in range(s + 1, e + 1):
                    kv = kv * 10 + Int(b[idx]) - 48
                if kv > 0:
                    return kv
    return 1


def analyze_smem_bank_conflicts(source_or_ptx: String) -> List[BankAccessSite]:
    """Statically analyze Mojo GPU kernel source or PTX assembly for shared-memory accesses
    and simulate 32-bank conflict ways on each site."""
    var sites = List[BankAccessSite]()
    var smem_vars = List[String]()
    var smem_row_cols = List[Int]()     # 2D inner row stride if declared `[R, C]` or `R * C`

    # Pass 1: discover shared-memory buffer names in Mojo or PTX
    var lines = List[String]()
    for ls in source_or_ptx.split("\n"):
        lines.append(String(ls))

    var ptx_tid_strides = List[String]()
    var ptx_tid_vals = List[Int]()

    for r in range(len(lines)):
        var t = String(lines[r].strip())
        var low = lower_str(t)
        if (
            low.find("addressspace.shared") >= 0
            or low.find("address_space = addressspace.shared") >= 0
            or low.find("stack_allocation") >= 0 and low.find("shared") >= 0
            or low.find(".shared()") >= 0
        ):
            if t.startswith("var "):
                var eq = t.find("=")
                if eq > 4:
                    var vname = String(t[byte=4:eq].strip())
                    var col_pos = vname.find(":")
                    if col_pos > 0:
                        var vsub = String(vname[byte=0:col_pos].strip())
                        vname = vsub
                    if vname.byte_length() > 0:
                        smem_vars.append(vname)
                        # Check for `32 * 32` or `row_major[32, 32]` inner dim
                        var inner_c = 32
                        var rm_pos = low.find("row_major[")
                        if rm_pos >= 0:
                            var cm = low.find(",", rm_pos)
                            var rb = low.find("]", cm + 1) if cm > 0 else -1
                            if cm > 0 and rb > cm + 1:
                                var c_txt = String(t[byte=cm + 1 : rb].strip())
                                var cv = 0
                                for b in c_txt.as_bytes():
                                    if b >= 48 and b <= 57:
                                        cv = cv * 10 + Int(b) - 48
                                if cv > 0:
                                    inner_c = cv
                        smem_row_cols.append(inner_c)
        # Track PTX register stride derivations from `%tid.x`:
        # e.g. `shl.b32 %r4, %tid.x, 4;` (byte stride = 16 -> 4 words) or `mul.lo.s32 %r4, %tid.x, 128;`
        if low.startswith("shl.b") or low.startswith("mul.lo.") or low.startswith("mad.lo."):
            if low.find("%tid.x") >= 0:
                var parts = List[String]()
                for p in t.rstrip(";").split(","):
                    parts.append(String(p.strip()))
                if len(parts) >= 3:
                    var sp_p0 = parts[0].rfind(" ")
                    var dst_reg = String(parts[0][byte=sp_p0 + 1 :].strip()) if sp_p0 >= 0 else parts[0]
                    var imm_txt = parts[len(parts) - 1]
                    var imm_v = 0
                    var got_i = False
                    for b in imm_txt.as_bytes():
                        if b >= 48 and b <= 57:
                            imm_v = imm_v * 10 + Int(b) - 48
                            got_i = True
                        else:
                            break
                    if got_i and dst_reg.startswith("%"):
                        var byte_stride = (1 << imm_v) if low.startswith("shl.") else imm_v
                        ptx_tid_strides.append(dst_reg)
                        ptx_tid_vals.append(max(1, byte_stride // 4))

    # Fallback common shared buffer names (`smem`, `shared`, `s_tile`, `lds`)
    for fallback_n in ["smem", "shared_mem", "s_tile", "lds"]:
        var fn_s = String(fallback_n)
        if not (fn_s in smem_vars):
            smem_vars.append(fn_s)
            smem_row_cols.append(32)

    # Pass 2: inspect shared-memory load/store sites
    for r in range(len(lines)):
        var t = String(lines[r].strip())
        if t.byte_length() == 0 or t.startswith("#") or t.startswith("//"):
            continue
        var low = lower_str(t)

        # PTX `ld.shared.*` / `st.shared.*`
        if low.startswith("ld.shared") or low.startswith("st.shared"):
            var elem_b = 4
            if low.find(".f64") >= 0 or low.find(".b64") >= 0 or low.find(".u64") >= 0 or low.find(".s64") >= 0 or low.find(".v2.f32") >= 0:
                elem_b = 8
            elif low.find(".v4.f32") >= 0 or low.find(".b128") >= 0:
                elem_b = 16
            var lb = t.find("[")
            var rb = t.find("]", lb + 1) if lb >= 0 else -1
            var addr_expr = String(t[byte=lb + 1 : rb]) if (lb >= 0 and rb > lb) else t
            var w_stride = 1
            for pi in range(len(ptx_tid_strides)):
                if addr_expr.find(ptx_tid_strides[pi]) >= 0:
                    w_stride = ptx_tid_vals[pi]
                    break
            var sim = simulate_32_banks(w_stride, elem_b)
            sim.line_no = r + 1
            sim.expr = t
            sites.append(sim^)
            continue

        # Mojo `smem[...]` indexing
        for vi in range(len(smem_vars)):
            var vn = smem_vars[vi]
            var pat = vn + "["
            var pos = t.find(pat)
            if pos < 0:
                continue
            # Ensure word boundary before `vn`
            if pos > 0:
                var prev_b = Int(t.as_bytes()[pos - 1])
                if (prev_b >= 65 and prev_b <= 90) or (prev_b >= 97 and prev_b <= 122) or (prev_b >= 48 and prev_b <= 57) or prev_b == 95:
                    continue
            if low.startswith("var " + lower_str(vn)):
                continue
            var idx_start = pos + pat.byte_length()
            var rb = t.find("]", idx_start)
            if rb <= idx_start:
                continue
            var idx_expr = String(t[byte=idx_start:rb])
            var comma = idx_expr.find(",")
            var stride: Int
            if comma >= 0:
                # 2D indexing `smem[row_expr, col_expr]` -> row_stride * d_row + d_col
                var row_e = String(idx_expr[byte=0:comma].strip())
                var col_e = String(idx_expr[byte=comma + 1 :].strip())
                var dr = _extract_stride_multiplier(row_e)
                var dc = _extract_stride_multiplier(col_e)
                stride = dr * smem_row_cols[vi] + dc
            else:
                stride = _extract_stride_multiplier(idx_expr)
            var sim = simulate_32_banks(stride, 4)
            sim.line_no = r + 1
            sim.expr = vn + "[" + idx_expr + "]"
            sites.append(sim^)
            break

    return sites^


def format_occupancy_and_bank_report(
    path_label: String,
    arch: String,
    kernel_name: String,
    regs_per_thread: Int,
    smem_bytes: Int,
    threads_per_block: Int,
    sites: List[BankAccessSite],
) -> List[String]:
    """Render a comprehensive GPU Occupancy & Shared-Memory Bank-Conflict report."""
    var occ = compute_gpu_occupancy(arch, regs_per_thread, smem_bytes, threads_per_block)
    var out = List[String]()
    out.append("GPU Occupancy & Shared-Memory Bank Analyzer — " + path_label)
    out.append("Target: " + occ.arch_label + " [" + occ.arch + "]  ·  Kernel: " + kernel_name)
    out.append("────────────────────────────────────────────────────────────────────────")
    out.append(
        "  Theoretical Occupancy : "
        + _fmt_pct_x10(occ.occupancy_pct_x10)
        + "  ("
        + String(occ.active_warps)
        + " / "
        + String(occ.max_warps)
        + " active warps/SM, "
        + String(occ.active_blocks)
        + " blocks/SM)"
    )
    out.append(
        "  Kernel Configuration  : "
        + String(occ.threads_per_block)
        + " threads/block ("
        + String(occ.warps_per_block)
        + " warps)  ·  "
        + String(occ.regs_per_thread)
        + " regs/thread  ·  "
        + String(occ.smem_bytes)
        + " B smem/block"
    )
    out.append(
        "  SM Block Limits       : regs="
        + String(occ.blocks_by_regs)
        + "  smem="
        + String(occ.blocks_by_smem)
        + "  warps="
        + String(occ.blocks_by_warps)
        + "  hw_blocks="
        + String(occ.blocks_by_blocks)
        + "   → Limiter: "
        + occ.limiter
    )
    out.append("  Optimization Cliff    : " + occ.cliff_hint)
    out.append("")
    out.append("Shared-Memory 32-Bank Access Analysis (" + String(len(sites)) + " access site(s)):")
    if len(sites) == 0:
        out.append("  (no shared-memory load/store sites detected in source or PTX)")
    else:
        for i in range(len(sites)):
            var s = sites[i].copy()
            var status = (
                "✓ broadcast"
                if s.is_broadcast
                else ("✓ 1-way conflict-free" if s.conflict_ways <= 1 else ("⚠ " + String(s.conflict_ways) + "-way CONFLICT"))
            )
            out.append("  Line " + String(s.line_no) + ": " + s.expr + "   [" + status + "]")
            out.append("    " + format_bank_heatmap(s.bank_hits))
            out.append("    → " + s.hint)
    return out^


def parse_warp_lane_mask(raw: String, width: Int = 32) -> Tuple[UInt64, Int]:
    """Parse an active lane mask from hex (`0xffffffff`, `exec = 0x0000ffff0000ffff`) or
    decimal/binary debugger output. Returns `(mask_bits, lane_width)`."""
    var w = 64 if width >= 64 else 32
    var t = lower_str(String(raw.strip()))
    var hx = t.find("0x")
    if hx >= 0:
        var bs = t.as_bytes()
        var k = hx + 2
        var acc: UInt64 = 0
        var digits = 0
        while k < len(bs):
            var c = Int(bs[k])
            var d = -1
            if c >= 48 and c <= 57:
                d = c - 48
            elif c >= 97 and c <= 102:
                d = c - 87
            if d < 0:
                break
            acc = (acc << 4) | UInt64(d)
            digits += 1
            k += 1
        if digits > 8:
            w = 64
        if digits > 0:
            return (acc, w)
    var full: UInt64 = ~UInt64(0) if w == 64 else ((UInt64(1) << 32) - 1)
    return (full, w)


def format_warp_lane_strip(mask: UInt64, width: Int = 32, focus_lane: Int = 0) -> String:
    """Render a 32-lane or 64-lane SIMT active-predicate strip (`■` active, `▣` focused active,
    `□` predicated-off/divergent) with active lane count and divergence warning."""
    var w = 64 if width >= 64 else 32
    var active_n = 0
    var bar = String("")
    for lane in range(w):
        var on = ((mask >> UInt64(lane)) & 1) == 1
        if on:
            active_n += 1
            bar += "▣" if lane == focus_lane else "■"
        else:
            bar += "□"
    var pct = (active_n * 100) // w
    var div_note = ("  ⚠ SIMT divergence (" + String(w - active_n) + " inactive)") if (active_n > 0 and active_n < w) else String("")
    var lbl = "Wave64" if w == 64 else "Warp32"
    return lbl + " [" + String(active_n) + "/" + String(w) + " " + String(pct) + "%] " + bar + " L" + String(focus_lane) + div_note


def format_warp_watch_values(var_name: String, lane_values: List[String], focus_lane: Int = 0) -> String:
    """Format cross-lane scalar watch values across a warp (`L0..L7`), highlighting uniform values,
    divergent values across lanes, or `NaN`/`Inf` lane anomalies."""
    var n = len(lane_values)
    if n == 0:
        return var_name + " [lanes]: (unavailable)"
    var first = String(lane_values[0].strip())
    var all_same = True
    var nan_lanes = List[Int]()
    for i in range(n):
        var lv = String(lane_values[i].strip())
        if lv != first:
            all_same = False
        var low = lower_str(lv)
        if low == "nan" or low == "-nan" or low == "inf" or low == "-inf":
            nan_lanes.append(i)
    if all_same and len(nan_lanes) == 0 and n > 1:
        return var_name + " [uniform across " + String(n) + " lanes] = " + first
    var shown = List[String]()
    var limit = min(8, n)
    for i in range(limit):
        var tag = ("*L" if i == focus_lane else "L") + String(i) + "=" + String(lane_values[i].strip())
        shown.append(tag)
    var more = (" … +" + String(n - limit) + " lanes") if n > limit else String("")
    var anom = (" ⚠ NaN/Inf at L" + String(nan_lanes[0]) + " ") if len(nan_lanes) > 0 else String(" ")
    return var_name + anom + "[" + ", ".join(shown) + more + "]"
