"""GPU Per-Line Stall Mapper, Interactive Flamegraph / Multi-Stream Timeline, and LayoutTensor Visualizer.

Provides:
- Per-line hardware warp/wave stall & pipe throughput attribution (`LineStallAnnotation`) from
  NVIDIA Nsight Compute (`ncu --csv --page source`), AMD `rocprof` / `rocprofv3`, and zero-hardware
  static PTX / AMDGCN instruction analysis
- Interactive terminal Flamegraph / Icicle & Multi-Stream GPU Timeline (`ProfileSpan`, `ProfileView`)
  for Chrome Trace JSON (`nsys`, Modular MAX profiler, PyTorch Kineto, `rocprof`), Brendan Gregg
  folded stacks, and `std.benchmark` summary tables
- `LayoutTensor` 32-lane warp memory coalescing, 32-bank shared-memory XOR swizzle simulator, and
  Modular MAX `Graph` epilogue fusion boundary visualizer
"""
from std.collections import List
from json import json_parse, Json, J_ARR, J_OBJ, J_STR, J_NUM
from util import bytes_to_str, lower_str, pad_right, basename


# ---------------------------------------------------------------------------
# Numeric & String Helpers
# ---------------------------------------------------------------------------

def _parse_int_clean(raw: String, fallback: Int = 0) -> Int:
    """Parse an integer token, stripping quotes, commas, and trailing units."""
    var s = String(raw.strip())
    if s.byte_length() >= 2 and (
        (s.startswith("\"") and s.endswith("\"")) or (s.startswith("'") and s.endswith("'"))
    ):
        var unq = String(s[byte=1 : s.byte_length() - 1].strip())
        s = unq
    if s.byte_length() == 0:
        return fallback
    var neg = False
    var idx = 0
    var bs = s.as_bytes()
    if Int(bs[0]) == 45:
        neg = True
        idx = 1
    elif Int(bs[0]) == 43:
        idx = 1
    var acc = 0
    var got = False
    while idx < len(bs):
        var c = Int(bs[idx])
        if c >= 48 and c <= 57:
            acc = acc * 10 + (c - 48)
            got = True
        elif c == 44:  # ',' thousands separator
            pass
        elif c == 46:  # '.' decimal point -> truncate fractional part
            break
        else:
            break
        idx += 1
    if not got:
        return fallback
    return -acc if neg else acc


def _parse_float_clean(raw: String, fallback: Float64 = 0.0) -> Float64:
    """Parse a floating-point token, stripping quotes, commas, and trailing units."""
    var s = String(raw.strip())
    if s.byte_length() >= 2 and (
        (s.startswith("\"") and s.endswith("\"")) or (s.startswith("'") and s.endswith("'"))
    ):
        var unq = String(s[byte=1 : s.byte_length() - 1].strip())
        s = unq
    if s.byte_length() == 0:
        return fallback
    var low = lower_str(s)
    if low == "n/a" or low == "nan" or low == "[n/a]":
        return fallback
    var bs = s.as_bytes()
    var idx = 0
    var neg = False
    if Int(bs[0]) == 45:
        neg = True
        idx = 1
    elif Int(bs[0]) == 43:
        idx = 1
    var int_part: Float64 = 0.0
    var frac_part: Float64 = 0.0
    var div: Float64 = 10.0
    var in_frac = False
    var got = False
    while idx < len(bs):
        var c = Int(bs[idx])
        if c >= 48 and c <= 57:
            got = True
            if not in_frac:
                int_part = int_part * 10.0 + Float64(c - 48)
            else:
                frac_part += Float64(c - 48) / div
                div *= 10.0
        elif c == 46 and not in_frac:
            in_frac = True
        elif c == 44:
            pass
        else:
            break
        idx += 1
    if not got:
        return fallback
    var val = int_part + frac_part
    return -val if neg else val


def _csv_split_row(line: String) -> List[String]:
    """Split a CSV row respecting double quotes."""
    var out = List[String]()
    var cur = List[UInt8]()
    var in_quotes = False
    var bs = line.as_bytes()
    var i = 0
    while i < len(bs):
        var c = bs[i]
        if c == 34:
            if in_quotes and i + 1 < len(bs) and bs[i + 1] == 34:
                cur.append(34)
                i += 2
                continue
            in_quotes = not in_quotes
        elif c == 44 and not in_quotes:
            out.append(String(bytes_to_str(cur).strip()))
            cur.clear()
        else:
            cur.append(c)
        i += 1
    out.append(String(bytes_to_str(cur).strip()))
    return out^


def _fmt_pct_x10(pct_x10: Int) -> String:
    var clamped = max(0, pct_x10)
    return String(clamped // 10) + "." + String(clamped % 10) + "%"


def _fmt_1dp(val: Float64) -> String:
    var neg = val < 0.0
    var v = -val if neg else val
    var scaled = Int(v * 10.0 + 0.5)
    var whole = scaled // 10
    var frac = scaled % 10
    return ("-" if neg else "") + String(whole) + "." + String(frac)


def _fmt_us(us: Float64) -> String:
    """Compact human duration string (`850.0us`, `4.8ms`, `1.2s`)."""
    var a = -us if us < 0.0 else us
    if a >= 1000000.0:
        return _fmt_1dp(us / 1000000.0) + "s"
    if a >= 1000.0:
        return _fmt_1dp(us / 1000.0) + "ms"
    return _fmt_1dp(us) + "us"


def _pad2(n: Int) -> String:
    var v = max(0, n)
    if v < 10:
        return "0" + String(v)
    return String(v)


# ---------------------------------------------------------------------------
# 1. Per-Line Hardware Stall & Pipe Throughput Mapper (`LineStallAnnotation`)
# ---------------------------------------------------------------------------

@fieldwise_init
struct LineStallAnnotation(Copyable, Movable):
    var line_no: Int
    var samples: Int
    var stall_pct_x10: Int
    var dominant_reason: String
    var pipe_tag: String
    var severity: Int
    var gutter_badge: String


@fieldwise_init
struct _LineBucket(Copyable, Movable):
    var line_no: Int
    var total_samples: Int
    var hbm_stalls: Int
    var mio_stalls: Int
    var barrier_stalls: Int
    var math_stalls: Int
    var branch_stalls: Int
    var inst_executed: Int
    var has_tensor_op: Bool


def _severity_for_pct_x10(stall_pct_x10: Int) -> Int:
    if stall_pct_x10 >= 350:
        return 2
    if stall_pct_x10 >= 150:
        return 1
    return 0


def _badge_short_tag(dominant_reason: String, pipe_tag: String) -> String:
    if dominant_reason == "HBM / Long Scoreboard":
        return "HBM"
    if dominant_reason == "Shared / MIO Throttle":
        return "MIO"
    if dominant_reason == "Barrier Sync":
        return "SYNC"
    if dominant_reason == "Math Pipe Throttle":
        return pipe_tag
    if dominant_reason == "Branch Divergence":
        return "DIV"
    return pipe_tag


def _make_gutter_badge(
    stall_pct_x10: Int,
    severity: Int,
    dominant_reason: String,
    pipe_tag: String,
) -> String:
    var glyph = String("░")
    if severity >= 2:
        glyph = "▓"
    elif severity == 1:
        glyph = "▒"
    elif stall_pct_x10 <= 0:
        glyph = "·"
    var pct_int = stall_pct_x10 // 10
    var tag = _badge_short_tag(dominant_reason, pipe_tag)
    return glyph + " " + String(pct_int) + "% " + tag


def _find_or_add_bucket(mut buckets: List[_LineBucket], line_no: Int) -> Int:
    for i in range(len(buckets)):
        if buckets[i].line_no == line_no:
            return i
    buckets.append(_LineBucket(line_no, 0, 0, 0, 0, 0, 0, 0, False))
    return len(buckets) - 1


def _finalize_buckets(mut buckets: List[_LineBucket]) -> List[LineStallAnnotation]:
    # Insertion-sort buckets by ascending line_no
    for i in range(1, len(buckets)):
        var cur = buckets[i].copy()
        var j = i - 1
        while j >= 0 and buckets[j].line_no > cur.line_no:
            buckets[j + 1] = buckets[j].copy()
            j -= 1
        buckets[j + 1] = cur^

    var grand_total = 0
    for i in range(len(buckets)):
        var b = buckets[i].copy()
        var sum_reasons = b.hbm_stalls + b.mio_stalls + b.barrier_stalls + b.math_stalls + b.branch_stalls
        var eff = max(b.total_samples, sum_reasons)
        buckets[i].total_samples = eff
        grand_total += eff

    var out = List[LineStallAnnotation]()
    for i in range(len(buckets)):
        var b = buckets[i].copy()
        var pct_x10 = 0
        if grand_total > 0 and b.total_samples > 0:
            pct_x10 = (b.total_samples * 1000 + grand_total // 2) // grand_total

        var best_val = 0
        var reason = String("No Stall")
        var pipe = String("ALU")
        if b.has_tensor_op:
            pipe = "TENSOR"

        if b.hbm_stalls > best_val:
            best_val = b.hbm_stalls
            reason = "HBM / Long Scoreboard"
            pipe = "HBM"
        if b.mio_stalls > best_val:
            best_val = b.mio_stalls
            reason = "Shared / MIO Throttle"
            pipe = "SMEM"
        if b.barrier_stalls > best_val:
            best_val = b.barrier_stalls
            reason = "Barrier Sync"
            pipe = "SYNC"
        if b.math_stalls > best_val:
            best_val = b.math_stalls
            reason = "Math Pipe Throttle"
            pipe = "TENSOR" if b.has_tensor_op else "TENSOR"
        if b.branch_stalls > best_val:
            best_val = b.branch_stalls
            reason = "Branch Divergence"
            pipe = "ALU"

        # If total_samples > 0 in CSV without breakdown columns, attribute to HBM if >0 else No Stall
        if best_val == 0 and b.total_samples > 0:
            reason = "HBM / Long Scoreboard"
            pipe = "HBM"

        var sev = _severity_for_pct_x10(pct_x10)
        if reason == "No Stall":
            sev = 0
        var badge = _make_gutter_badge(pct_x10, sev, reason, pipe)
        out.append(LineStallAnnotation(b.line_no, b.total_samples, pct_x10, reason, pipe, sev, badge))
    return out^


def _matches_target_file(cell_file: String, target_filter: String) -> Bool:
    var tf = String(target_filter.strip())
    if tf.byte_length() == 0:
        return True
    var cf = String(cell_file.strip())
    if cf.byte_length() == 0:
        return True
    var cf_low = lower_str(cf)
    var tf_low = lower_str(tf)
    if cf_low == tf_low or cf_low.endswith("/" + tf_low) or cf_low.find(tf_low) >= 0:
        return True
    return lower_str(basename(cf)) == lower_str(basename(tf))


def _classify_reason_text(
    reason_raw: String,
    count: Int,
    mut b: _LineBucket,
):
    var low = lower_str(reason_raw)
    if low.find("long_scoreboard") >= 0 or low.find("long scoreboard") >= 0 or low.find("hbm") >= 0 or low.find("dram") >= 0 or low.find("vmem") >= 0:
        b.hbm_stalls += count
    elif (
        low.find("short_scoreboard") >= 0
        or low.find("short scoreboard") >= 0
        or low.find("mio") >= 0
        or low.find("shared") >= 0
        or low.find("lds") >= 0
        or low.find("lg_throttle") >= 0
    ):
        b.mio_stalls += count
    elif low.find("barrier") >= 0 or low.find("membar") >= 0 or low.find("sync") >= 0:
        b.barrier_stalls += count
    elif low.find("math_pipe") >= 0 or low.find("math pipe") >= 0 or low.find("tensor") >= 0 or low.find("mma") >= 0 or low.find("mfma") >= 0:
        b.math_stalls += count
        if low.find("tensor") >= 0 or low.find("mma") >= 0 or low.find("mfma") >= 0:
            b.has_tensor_op = True
    elif low.find("branch") >= 0 or low.find("diverg") >= 0:
        b.branch_stalls += count


def parse_ncu_source_csv(csv_text: String, target_file_Filter: String = "") -> List[LineStallAnnotation]:
    """Parse NVIDIA Nsight Compute `ncu --csv --page source` output into sorted per-line stall annotations."""
    var buckets = List[_LineBucket]()
    if csv_text.byte_length() == 0:
        return List[LineStallAnnotation]()

    var col_file = -1
    var col_line = -1
    var col_samples = -1
    var col_long_sb = -1
    var col_mio = List[Int]()
    var col_barrier = -1
    var col_math = -1
    var col_branch = -1
    var col_inst = -1
    var col_reason = -1
    var col_source_txt = -1
    var has_header = False

    for line_slice in csv_text.split("\n"):
        var raw = String(line_slice)
        var trimmed = String(raw.strip())
        if trimmed.byte_length() == 0 or trimmed.startswith("==PROF==") or trimmed.startswith("==WARNING==") or trimmed.startswith("#"):
            continue
        var cells = _csv_split_row(trimmed)
        if len(cells) < 2:
            continue

        if not has_header:
            # Check if this row is the CSV column header
            var found_line_hdr = -1
            for c_idx in range(len(cells)):
                var h = lower_str(cells[c_idx])
                if h == "line" or h == "line no" or h == "line number" or h == "source line" or h == "lineno":
                    found_line_hdr = c_idx
                    break
            if found_line_hdr >= 0:
                col_line = found_line_hdr
                for c_idx in range(len(cells)):
                    var h = lower_str(cells[c_idx])
                    if c_idx == col_line:
                        continue
                    if h == "source file" or h == "file" or h == "filepath" or h == "path":
                        col_file = c_idx
                    elif (
                        h.find("warp stall sampling") >= 0
                        or h.find("smsp__pcsamp_sample_count") >= 0
                        or h == "stall samples"
                        or h == "samples"
                        or h == "total samples"
                    ):
                        if col_samples < 0:
                            col_samples = c_idx
                    elif h.find("long scoreboard") >= 0 or h.find("long_scoreboard") >= 0:
                        col_long_sb = c_idx
                    elif (
                        h.find("short scoreboard") >= 0
                        or h.find("short_scoreboard") >= 0
                        or h.find("mio throttle") >= 0
                        or h.find("mio_throttle") >= 0
                        or h.find("lg throttle") >= 0
                    ):
                        col_mio.append(c_idx)
                    elif h.find("barrier") >= 0 or h.find("membar") >= 0:
                        col_barrier = c_idx
                    elif h.find("math pipe") >= 0 or h.find("math_pipe") >= 0 or h.find("tensor") >= 0:
                        col_math = c_idx
                    elif h.find("branch") >= 0 or h.find("diverg") >= 0:
                        col_branch = c_idx
                    elif h.find("instructions executed") >= 0 or h.find("inst_executed") >= 0:
                        col_inst = c_idx
                    elif h == "stall reason" or h == "reason":
                        col_reason = c_idx
                    elif h == "source" or h == "instruction" or h == "sass" or h == "ptx":
                        col_source_txt = c_idx
                has_header = True
                continue

        if has_header:
            if col_line < 0 or col_line >= len(cells):
                continue
            var ln = _parse_int_clean(cells[col_line], -1)
            if ln <= 0:
                # Skip secondary units row in ncu CSVs (e.g. `"", "", "sample", ...`)
                continue
            if col_file >= 0 and col_file < len(cells):
                if not _matches_target_file(cells[col_file], target_file_Filter):
                    continue
            var bi = _find_or_add_bucket(buckets, ln)
            if col_samples >= 0 and col_samples < len(cells):
                buckets[bi].total_samples += max(0, _parse_int_clean(cells[col_samples], 0))
            if col_long_sb >= 0 and col_long_sb < len(cells):
                buckets[bi].hbm_stalls += max(0, _parse_int_clean(cells[col_long_sb], 0))
            for m_idx in range(len(col_mio)):
                var mc = col_mio[m_idx]
                if mc >= 0 and mc < len(cells):
                    buckets[bi].mio_stalls += max(0, _parse_int_clean(cells[mc], 0))
            if col_barrier >= 0 and col_barrier < len(cells):
                buckets[bi].barrier_stalls += max(0, _parse_int_clean(cells[col_barrier], 0))
            if col_math >= 0 and col_math < len(cells):
                var mv = max(0, _parse_int_clean(cells[col_math], 0))
                buckets[bi].math_stalls += mv
                if mv > 0:
                    buckets[bi].has_tensor_op = True
            if col_branch >= 0 and col_branch < len(cells):
                buckets[bi].branch_stalls += max(0, _parse_int_clean(cells[col_branch], 0))
            if col_inst >= 0 and col_inst < len(cells):
                buckets[bi].inst_executed += max(0, _parse_int_clean(cells[col_inst], 0))
            if col_reason >= 0 and col_reason < len(cells):
                var r_cnt = max(0, _parse_int_clean(cells[col_samples], 0)) if (col_samples >= 0 and col_samples < len(cells)) else 1
                _classify_reason_text(cells[col_reason], r_cnt, buckets[bi])
            if col_source_txt >= 0 and col_source_txt < len(cells):
                var sl = lower_str(cells[col_source_txt])
                if sl.find("mma") >= 0 or sl.find("wgmma") >= 0 or sl.find("hmma") >= 0:
                    buckets[bi].has_tensor_op = True
        else:
            # Headerless compact CSV fallback: `line,reason,samples` or `file,line,reason,samples`
            if len(cells) >= 3:
                var l0 = _parse_int_clean(cells[0], -1)
                if l0 > 0:
                    var cnt = max(0, _parse_int_clean(cells[2], 0))
                    var bi = _find_or_add_bucket(buckets, l0)
                    buckets[bi].total_samples += cnt
                    _classify_reason_text(cells[1], cnt, buckets[bi])
                elif len(cells) >= 4:
                    var l1 = _parse_int_clean(cells[1], -1)
                    if l1 > 0 and _matches_target_file(cells[0], target_file_Filter):
                        var cnt = max(0, _parse_int_clean(cells[3], 0))
                        var bi = _find_or_add_bucket(buckets, l1)
                        buckets[bi].total_samples += cnt
                        _classify_reason_text(cells[2], cnt, buckets[bi])

    return _finalize_buckets(buckets)


def _extract_kv_int(line_upper: String, key: String) -> Int:
    """Extract `KEY=123` or `KEY: 123` from an uppercase trace line (-1 if absent)."""
    for sep in ["=", ":"]:
        var pat = key + String(sep)
        var pos = line_upper.find(pat)
        if pos >= 0:
            var after = String(line_upper[byte=pos + pat.byte_length() :].strip())
            return _parse_int_clean(after, -1)
    return -1


def parse_rocprof_trace_lines(text: String) -> List[LineStallAnnotation]:
    """Parse AMD `rocprof` / `rocprofv3` source & instruction stall counters
    (`SQ_WAIT_CNT`, `VMEM`, `LDS`, `S_BARRIER`, `MFMA` Tensor ops)."""
    var buckets = List[_LineBucket]()
    if text.byte_length() == 0:
        return List[LineStallAnnotation]()

    var csv_mode = False
    var col_line = -1
    var col_sq_wait = -1
    var col_vmem = -1
    var col_lds = -1
    var col_barrier = -1
    var col_mfma = -1
    var col_branch = -1
    var col_inst = -1

    for line_slice in text.split("\n"):
        var raw = String(line_slice)
        var trimmed = String(raw.strip())
        if trimmed.byte_length() == 0 or trimmed.startswith("#"):
            continue

        var up = trimmed.upper()
        # Detect CSV header if comma-separated with counter names
        if not csv_mode and trimmed.find(",") >= 0 and (
            up.find("SQ_WAIT") >= 0 or up.find("VMEM") >= 0 or up.find("LDS") >= 0 or up.find("MFMA") >= 0 or up.find("S_BARRIER") >= 0
        ):
            var hcells = _csv_split_row(trimmed)
            var found_l = -1
            for ci in range(len(hcells)):
                var hc = hcells[ci].upper()
                if hc == "LINE" or hc == "LINE_NO" or hc == "SOURCE_LINE" or hc == "LINENO":
                    found_l = ci
                    break
            if found_l >= 0:
                csv_mode = True
                col_line = found_l
                for ci in range(len(hcells)):
                    var hc = hcells[ci].upper()
                    if hc.find("SQ_WAIT") >= 0:
                        col_sq_wait = ci
                    elif hc.find("VMEM") >= 0:
                        col_vmem = ci
                    elif hc.find("LDS") >= 0:
                        col_lds = ci
                    elif hc.find("BARRIER") >= 0:
                        col_barrier = ci
                    elif hc.find("MFMA") >= 0 or hc.find("WMMA") >= 0:
                        col_mfma = ci
                    elif hc.find("BRANCH") >= 0:
                        col_branch = ci
                    elif hc == "INSTRUCTION" or hc == "INST" or hc == "ASM":
                        col_inst = ci
                continue

        if csv_mode:
            var cells = _csv_split_row(trimmed)
            if col_line < 0 or col_line >= len(cells):
                continue
            var ln = _parse_int_clean(cells[col_line], -1)
            if ln <= 0:
                continue
            var bi = _find_or_add_bucket(buckets, ln)
            var sq_w = max(0, _parse_int_clean(cells[col_sq_wait], 0)) if (col_sq_wait >= 0 and col_sq_wait < len(cells)) else 0
            var vm = max(0, _parse_int_clean(cells[col_vmem], 0)) if (col_vmem >= 0 and col_vmem < len(cells)) else 0
            var lds = max(0, _parse_int_clean(cells[col_lds], 0)) if (col_lds >= 0 and col_lds < len(cells)) else 0
            var bar = max(0, _parse_int_clean(cells[col_barrier], 0)) if (col_barrier >= 0 and col_barrier < len(cells)) else 0
            var mfma = max(0, _parse_int_clean(cells[col_mfma], 0)) if (col_mfma >= 0 and col_mfma < len(cells)) else 0
            var br = max(0, _parse_int_clean(cells[col_branch], 0)) if (col_branch >= 0 and col_branch < len(cells)) else 0

            # If SQ_WAIT_CNT exceeds explicit sub-counter breakdown, attribute residual wait cycles to LDS or VMEM
            var inst_up = cells[col_inst].upper() if (col_inst >= 0 and col_inst < len(cells)) else String("")
            var known_sum = vm + lds + bar + mfma + br
            if sq_w > known_sum:
                var rem = sq_w - known_sum
                if inst_up.find("DS_") >= 0 or inst_up.find("LGKMCNT") >= 0:
                    lds += rem
                elif inst_up.find("MFMA") >= 0:
                    mfma += rem
                elif inst_up.find("BARRIER") >= 0:
                    bar += rem
                else:
                    vm += rem
            buckets[bi].hbm_stalls += vm
            buckets[bi].mio_stalls += lds
            buckets[bi].barrier_stalls += bar
            buckets[bi].math_stalls += mfma
            buckets[bi].branch_stalls += br
            if mfma > 0 or inst_up.find("MFMA") >= 0:
                buckets[bi].has_tensor_op = True
            var sum_c = vm + lds + bar + mfma + br
            buckets[bi].total_samples += max(sq_w, sum_c)
            continue

        # Free-form / key=value / `file.mojo:42 ...` / `line 42 | ...` rocprof trace lines
        var ln = -1
        if up.startswith("LINE "):
            ln = _parse_int_clean(String(trimmed[byte=5:]), -1)
        else:
            # Look for `<file>:<line>` or leading integer
            var colon = trimmed.find(":")
            if colon > 0:
                var after_c = String(trimmed[byte=colon + 1 :].strip())
                var cand = _parse_int_clean(after_c, -1)
                var before_c = String(trimmed[byte=0:colon].strip())
                if cand > 0 and (before_c.find(".") >= 0 or lower_str(before_c) == "line"):
                    ln = cand
            if ln <= 0:
                ln = _parse_int_clean(trimmed, -1)
        if ln <= 0:
            continue

        var sq_v = max(0, _extract_kv_int(up, "SQ_WAIT_CNT"))
        var vm_v = max(0, _extract_kv_int(up, "VMEM"))
        var lds_v = max(0, _extract_kv_int(up, "LDS"))
        var bar_v = max(0, _extract_kv_int(up, "S_BARRIER"))
        if bar_v == 0:
            bar_v = max(0, _extract_kv_int(up, "BARRIER"))
        var mfma_v = max(0, _extract_kv_int(up, "MFMA"))
        var stalls_v = max(0, _extract_kv_int(up, "STALLS"))
        if stalls_v == 0:
            stalls_v = max(0, _extract_kv_int(up, "SAMPLES"))

        # Handle pipe/space-delimited keyword lines when no explicit `=N` per counter
        if vm_v == 0 and lds_v == 0 and bar_v == 0 and mfma_v == 0:
            var weight = max(sq_v, stalls_v)
            if weight == 0 and trimmed.find(",") >= 0:
                var cparts = _csv_split_row(trimmed)
                if len(cparts) >= 2:
                    weight = max(0, _parse_int_clean(cparts[1], 0))
            if weight <= 0:
                weight = 10
            if up.find("MFMA") >= 0 or up.find("V_MFMA") >= 0:
                mfma_v = weight
            elif up.find("S_BARRIER") >= 0 or up.find("BARRIER") >= 0:
                bar_v = weight
            elif up.find("LDS") >= 0 or up.find("DS_READ") >= 0 or up.find("DS_WRITE") >= 0 or up.find("LGKMCNT") >= 0:
                lds_v = weight
            elif up.find("VMEM") >= 0 or up.find("SQ_WAIT_CNT") >= 0 or up.find("GLOBAL_LOAD") >= 0 or up.find("VMCNT") >= 0:
                vm_v = weight
        else:
            var known_kv = vm_v + lds_v + bar_v + mfma_v
            if sq_v > known_kv:
                var diff = sq_v - known_kv
                if up.find("LDS") >= 0 and vm_v == 0 and lds_v > 0:
                    lds_v += diff
                elif up.find("MFMA") >= 0 and mfma_v > 0 and vm_v == 0:
                    mfma_v += diff
                elif up.find("BARRIER") >= 0 and bar_v > 0 and vm_v == 0:
                    bar_v += diff
                else:
                    vm_v += diff

        var total_row = vm_v + lds_v + bar_v + mfma_v
        if total_row <= 0 and sq_v <= 0:
            continue
        var bi = _find_or_add_bucket(buckets, ln)
        buckets[bi].hbm_stalls += vm_v
        buckets[bi].mio_stalls += lds_v
        buckets[bi].barrier_stalls += bar_v
        buckets[bi].math_stalls += mfma_v
        if mfma_v > 0 or up.find("MFMA") >= 0:
            buckets[bi].has_tensor_op = True
        buckets[bi].total_samples += max(sq_v, total_row)

    return _finalize_buckets(buckets)


def _parse_loc_directive(trimmed: String) -> Int:
    """Parse `.loc <file_id> <line_no> [col]` and return `<line_no>` (>0) or -1."""
    if not trimmed.startswith(".loc"):
        return -1
    var toks = List[String]()
    var cur = String("")
    for ch in trimmed.codepoint_slices():
        var s = String(ch)
        if s == " " or s == "\t":
            if cur.byte_length() > 0:
                toks.append(cur)
                cur = ""
        else:
            cur += s
    if cur.byte_length() > 0:
        toks.append(cur)
    if len(toks) >= 3 and toks[0] == ".loc":
        return _parse_int_clean(toks[2], -1)
    return -1


def analyze_static_asm_stalls(asm_text: String) -> List[LineStallAnnotation]:
    """Zero-hardware static PTX & AMDGCN instruction hotspot analyzer for `WK_CODEGEN`.

    Tracks `.loc` debug line directives (falling back to 1-based assembly line numbers when
    absent) and weights PTX (`ld.global`, `st.global`, `cp.async`, `ld.shared`, `st.shared`,
    `bar.sync`, `mma.sync`, `wgmma`) and AMDGCN (`global_load`, `ds_read`, `ds_write`,
    `s_waitcnt vmcnt`, `s_waitcnt lgkmcnt`, `s_barrier`, `v_mfma`) instructions.
    """
    var buckets = List[_LineBucket]()
    if asm_text.byte_length() == 0:
        return List[LineStallAnnotation]()

    var cur_loc_line = 0
    var asm_line_no = 0

    for line_slice in asm_text.split("\n"):
        asm_line_no += 1
        var raw = String(line_slice)
        var trimmed = String(raw.strip())
        if trimmed.byte_length() == 0 or trimmed.startswith("//") or trimmed.startswith(";") or trimmed.startswith("#"):
            continue

        var loc_ln = _parse_loc_directive(trimmed)
        if loc_ln > 0:
            cur_loc_line = loc_ln
            continue

        # Skip labels and assembler directives
        if trimmed.startswith(".") or trimmed.endswith(":"):
            continue

        # Strip trailing comments (`//` or `;` in AMDGCN, keeping PTX trailing `;` statement terminator)
        var clean = trimmed
        var slash_cm = clean.find("//")
        if slash_cm >= 0:
            var sub = String(clean[byte=0:slash_cm].strip())
            clean = sub
        if clean.byte_length() == 0:
            continue

        var low = lower_str(clean)
        # Strip PTX predicate guard `@%p1 ` or `@!%p0 ` while noting predicated branches
        var has_pred = False
        if low.startswith("@"):
            has_pred = True
            var sp = low.find(" ")
            var tb = low.find("\t")
            var cut = sp
            if tb >= 0 and (cut < 0 or tb < cut):
                cut = tb
            if cut > 0:
                var rest_low = String(low[byte=cut + 1 :].strip())
                low = rest_low

        var hbm_w = 0
        var smem_w = 0
        var sync_w = 0
        var tensor_w = 0
        var div_w = 0

        # PTX global memory ops
        if (
            low.startswith("ld.global")
            or low.startswith("ld.volatile.global")
            or low.startswith("ld.weak.global")
            or low.startswith("st.global")
            or low.startswith("st.weak.global")
            or low.startswith("atom.global")
            or low.startswith("red.global")
        ):
            hbm_w = 40
        # PTX async copy / shared memory ops
        elif (
            low.startswith("cp.async")
            or low.startswith("ld.shared")
            or low.startswith("st.shared")
            or low.startswith("ldmatrix")
            or low.startswith("atom.shared")
        ):
            smem_w = 22
        # PTX barriers
        elif (
            low.startswith("bar.sync")
            or low.startswith("bar.arrive")
            or low.startswith("barrier.sync")
            or low.startswith("mbarrier.")
        ):
            sync_w = 28
        # PTX Tensor Core ops
        elif (
            low.startswith("mma.sync")
            or low.startswith("wgmma")
            or low.startswith("tcgen05.mma")
            or low.startswith("wmma.mma")
        ):
            tensor_w = 32
        # PTX divergent branch
        elif has_pred and low.startswith("bra") and not low.startswith("bra.uni"):
            div_w = 15
        # AMDGCN global / buffer VMEM ops
        elif (
            low.startswith("global_load")
            or low.startswith("global_store")
            or low.startswith("buffer_load")
            or low.startswith("buffer_store")
            or low.startswith("flat_load")
            or low.startswith("flat_store")
        ):
            hbm_w = 38
        # AMDGCN LDS shared memory ops
        elif low.startswith("ds_read") or low.startswith("ds_write") or low.startswith("ds_bpermute"):
            smem_w = 22
        # AMDGCN s_waitcnt vmcnt / lgkmcnt
        elif low.startswith("s_waitcnt"):
            var has_vm = low.find("vmcnt(") >= 0
            var has_lgkm = low.find("lgkmcnt(") >= 0
            if has_vm and has_lgkm:
                hbm_w = 35
                smem_w = 15
            elif has_vm:
                hbm_w = 42
            elif has_lgkm:
                smem_w = 24
        # AMDGCN barrier
        elif low.startswith("s_barrier"):
            sync_w = 28
        # AMDGCN Matrix Core MFMA / WMMA
        elif low.startswith("v_mfma") or low.startswith("v_wmma") or low.startswith("v_smfmac"):
            tensor_w = 32
        # AMDGCN SIMT branch / exec mask divergence
        elif low.startswith("s_cbranch_execz") or low.startswith("s_cbranch_vcc") or low.startswith("s_and_saveexec"):
            div_w = 15

        var row_total = hbm_w + smem_w + sync_w + tensor_w + div_w
        if row_total <= 0:
            continue

        var target_ln = cur_loc_line if cur_loc_line > 0 else asm_line_no
        var bi = _find_or_add_bucket(buckets, target_ln)
        buckets[bi].hbm_stalls += hbm_w
        buckets[bi].mio_stalls += smem_w
        buckets[bi].barrier_stalls += sync_w
        buckets[bi].math_stalls += tensor_w
        buckets[bi].branch_stalls += div_w
        if tensor_w > 0:
            buckets[bi].has_tensor_op = True
        buckets[bi].total_samples += row_total

    return _finalize_buckets(buckets)


# ---------------------------------------------------------------------------
# 2. Interactive Flamegraph & Multi-Stream GPU Timeline (`ProfileView`)
# ---------------------------------------------------------------------------

@fieldwise_init
struct ProfileSpan(Copyable, Movable):
    var name: String
    var category: String
    var stream_name: String
    var depth: Int
    var start_us: Float64
    var dur_us: Float64
    var self_us: Float64


@fieldwise_init
struct ProfileView(Copyable, Movable):
    var title: String
    var spans: List[ProfileSpan]
    var total_dur_us: Float64
    var min_start_us: Float64
    var max_end_us: Float64
    var zoom_start_us: Float64
    var zoom_end_us: Float64
    var zoom_stack_s: List[Float64]
    var zoom_stack_e: List[Float64]
    var selected_idx: Int
    var timeline_mode: Bool
    var search_query: String
    var matched_pct_x10: Int

    def __init__(out self, title: String = "GPU Profile"):
        self.title = title
        self.spans = List[ProfileSpan]()
        self.total_dur_us = 0.0
        self.min_start_us = 0.0
        self.max_end_us = 0.0
        self.zoom_start_us = 0.0
        self.zoom_end_us = 0.0
        self.zoom_stack_s = List[Float64]()
        self.zoom_stack_e = List[Float64]()
        self.selected_idx = -1
        self.timeline_mode = False
        self.search_query = ""
        self.matched_pct_x10 = 0

    def _recompute_search_match(mut self):
        var q = lower_str(String(self.search_query.strip()))
        if q.byte_length() == 0 or len(self.spans) == 0:
            self.matched_pct_x10 = 0
            return
        var win_s = self.zoom_start_us
        var win_e = self.zoom_end_us
        var win_dur = win_e - win_s
        if win_dur <= 0.0:
            self.matched_pct_x10 = 0
            return

        # Collect clipped [s, e] intervals of matching spans and take their union
        # so nested parent+child matches are never double-counted (>100%).
        var iv_s = List[Float64]()
        var iv_e = List[Float64]()
        for i in range(len(self.spans)):
            var sp = self.spans[i].copy()
            if lower_str(sp.name).find(q) < 0 and lower_str(sp.category).find(q) < 0:
                continue
            var s = sp.start_us if sp.start_us > win_s else win_s
            var e_raw = sp.start_us + sp.dur_us
            var e = e_raw if e_raw < win_e else win_e
            if e > s:
                iv_s.append(s)
                iv_e.append(e)

        if len(iv_s) == 0:
            self.matched_pct_x10 = 0
            return

        # Sort intervals by start ascending
        for i in range(1, len(iv_s)):
            var ks = iv_s[i]
            var ke = iv_e[i]
            var j = i - 1
            while j >= 0 and iv_s[j] > ks:
                iv_s[j + 1] = iv_s[j]
                iv_e[j + 1] = iv_e[j]
                j -= 1
            iv_s[j + 1] = ks
            iv_e[j + 1] = ke

        var union_us: Float64 = 0.0
        var cur_s = iv_s[0]
        var cur_e = iv_e[0]
        for i in range(1, len(iv_s)):
            if iv_s[i] <= cur_e:
                if iv_e[i] > cur_e:
                    cur_e = iv_e[i]
            else:
                union_us += cur_e - cur_s
                cur_s = iv_s[i]
                cur_e = iv_e[i]
        union_us += cur_e - cur_s

        var pct = Int((union_us * 1000.0) / win_dur + 0.5)
        if pct > 1000:
            pct = 1000
        self.matched_pct_x10 = max(0, pct)

    def zoom_into_selected(mut self):
        """Push current zoom window onto stack and zoom into `spans[selected_idx]`."""
        if self.selected_idx < 0 or self.selected_idx >= len(self.spans):
            return
        var sp = self.spans[self.selected_idx].copy()
        if sp.dur_us <= 0.0:
            return
        self.zoom_stack_s.append(self.zoom_start_us)
        self.zoom_stack_e.append(self.zoom_end_us)
        self.zoom_start_us = sp.start_us
        self.zoom_end_us = sp.start_us + sp.dur_us
        self._recompute_search_match()

    def zoom_out(mut self):
        """Pop previous zoom window from stack, or widen by 2x if stack is empty."""
        if len(self.zoom_stack_s) > 0 and len(self.zoom_stack_e) > 0:
            self.zoom_start_us = self.zoom_stack_s.pop()
            self.zoom_end_us = self.zoom_stack_e.pop()
            self._recompute_search_match()
            return
        self.zoom_by_factor(2.0)

    def zoom_reset(mut self):
        """Reset zoom window to full `[min_start_us, max_end_us]` trace span."""
        self.zoom_stack_s.clear()
        self.zoom_stack_e.clear()
        self.zoom_start_us = self.min_start_us
        self.zoom_end_us = self.max_end_us
        self._recompute_search_match()

    def zoom_by_factor(mut self, factor: Float64):
        """Scale visible window duration by `factor` (`0.5` zooms in 2x; `2.0` zooms out 2x)."""
        if factor <= 0.0 or self.max_end_us <= self.min_start_us:
            return
        var cur_dur = self.zoom_end_us - self.zoom_start_us
        if cur_dur <= 0.0:
            cur_dur = self.max_end_us - self.min_start_us
        var full_dur = self.max_end_us - self.min_start_us
        var new_dur = cur_dur * factor
        if new_dur < 0.001:
            new_dur = 0.001
        if new_dur >= full_dur:
            self.zoom_start_us = self.min_start_us
            self.zoom_end_us = self.max_end_us
            self._recompute_search_match()
            return

        if factor < 1.0:
            self.zoom_stack_s.append(self.zoom_start_us)
            self.zoom_stack_e.append(self.zoom_end_us)

        var center = (self.zoom_start_us + self.zoom_end_us) * 0.5
        if self.selected_idx >= 0 and self.selected_idx < len(self.spans):
            var sel = self.spans[self.selected_idx].copy()
            var sel_mid = sel.start_us + sel.dur_us * 0.5
            if sel_mid >= self.zoom_start_us and sel_mid <= self.zoom_end_us:
                center = sel_mid

        var ns = center - new_dur * 0.5
        var ne = ns + new_dur
        if ns < self.min_start_us:
            ns = self.min_start_us
            ne = ns + new_dur
        if ne > self.max_end_us:
            ne = self.max_end_us
            ns = max(self.min_start_us, ne - new_dur)
        self.zoom_start_us = ns
        self.zoom_end_us = ne
        self._recompute_search_match()

    def set_search(mut self, query: String):
        """Highlight matching spans and update `matched_pct_x10` across the visible window."""
        self.search_query = String(query.strip())
        self._recompute_search_match()

    def toggle_mode(mut self):
        """Toggle between Flamegraph/Icicle mode (`False`) and Multi-Stream Timeline (`True`)."""
        self.timeline_mode = not self.timeline_mode

    def select_next(mut self):
        if len(self.spans) == 0:
            return
        self.selected_idx = (self.selected_idx + 1) % len(self.spans)

    def select_prev(mut self):
        if len(self.spans) == 0:
            return
        self.selected_idx = (self.selected_idx - 1 + len(self.spans)) % len(self.spans)

    def render_lines(self, width: Int, height: Int) -> List[String]:
        """Render terminal Flamegraph/Icicle bars or Multi-Stream GPU Timeline lanes."""
        var w = max(40, width)
        var h = max(6, height)
        var out = List[String]()

        var mode_lbl = "[GPU Timeline]" if self.timeline_mode else "[Flamegraph]"
        var win_s = self.zoom_start_us
        var win_e = self.zoom_end_us
        var win_dur = win_e - win_s
        var range_lbl = _fmt_us(win_s) + ".." + _fmt_us(win_e) + " (" + _fmt_us(max(0.0, win_dur)) + ")"
        var match_lbl = String("")
        if self.search_query.byte_length() > 0:
            match_lbl = "  [Match: " + _fmt_pct_x10(self.matched_pct_x10) + " '" + self.search_query + "']"
        out.append(pad_right(mode_lbl + " " + self.title + "  " + range_lbl + match_lbl, w))

        # Time ruler header
        out.append(_render_time_ruler(win_s, win_e, w))

        var body_h = max(1, h - 4)
        if len(self.spans) == 0 or win_dur <= 0.0:
            out.append(pad_right("  (no profile spans in trace)", w))
        elif not self.timeline_mode:
            var fg_lines = _render_flamegraph_rows(
                self.spans,
                win_s,
                win_e,
                w,
                body_h,
                self.selected_idx,
                lower_str(self.search_query),
            )
            for i in range(len(fg_lines)):
                out.append(fg_lines[i])
        else:
            var tl_lines = _render_timeline_rows(
                self.spans,
                win_s,
                win_e,
                w,
                body_h,
                self.selected_idx,
                lower_str(self.search_query),
            )
            for i in range(len(tl_lines)):
                out.append(tl_lines[i])

        while len(out) < h - 2:
            out.append(pad_right("", w))

        # Footer rule + selected frame inspector
        var rule = String("")
        for _ in range(w):
            rule += "─"
        out.append(rule)

        if self.selected_idx >= 0 and self.selected_idx < len(self.spans):
            var sel = self.spans[self.selected_idx].copy()
            var tot_pct_x10 = Int((sel.dur_us * 1000.0) / max(0.001, self.total_dur_us) + 0.5)
            var detail = (
                "Selected: "
                + sel.name
                + " ["
                + sel.stream_name
                + "]  dur="
                + _fmt_us(sel.dur_us)
                + " ("
                + _fmt_pct_x10(tot_pct_x10)
                + ")  self="
                + _fmt_us(sel.self_us)
            )
            out.append(pad_right(detail, w))
        else:
            out.append(pad_right("Selected: (none)  ·  Enter: zoom  0: reset  t: timeline/flamegraph  /: search", w))
        return out^


def _render_time_ruler(win_s: Float64, win_e: Float64, width: Int) -> String:
    var cells = List[String](length=width, fill="─")
    if width >= 4:
        cells[0] = "├"
        cells[width - 1] = "┤"
    var dur = max(0.0, win_e - win_s)
    var ticks = 4
    for t in range(ticks + 1):
        var col = (t * (width - 1)) // ticks
        var ts_lbl = "+" + _fmt_us((dur * Float64(t)) / Float64(ticks))
        if t == 0:
            ts_lbl = _fmt_us(win_s)
        var bs = ts_lbl.as_bytes()
        var start_c = col
        if start_c + len(bs) > width:
            start_c = max(0, width - len(bs))
        if col > 0 and col < width - 1:
            cells[col] = "┼"
        for k in range(len(bs)):
            if start_c + k < width:
                var ch_b = List[UInt8]()
                ch_b.append(bs[k])
                cells[start_c + k] = bytes_to_str(ch_b)
    var out = String("")
    for i in range(width):
        out += cells[i]
    return out


def _format_flame_bar(
    name: String,
    pct_x10: Int,
    bar_w: Int,
    is_selected: Bool,
    is_matched: Bool,
) -> String:
    if bar_w <= 0:
        return ""
    if bar_w == 1:
        return "│"
    if bar_w == 2:
        return "[]"
    var prefix = "*" if is_matched else (">" if is_selected else "")
    var core = prefix + name + " (" + _fmt_pct_x10(pct_x10) + ")"
    var inner_w = bar_w - 2
    var fill_ch = "█" if (is_matched or is_selected or inner_w >= core.byte_length() + 2) else "▓"
    if inner_w >= core.byte_length() + 2:
        var pad_total = inner_w - (core.byte_length() + 2)
        var pad_l = pad_total // 2
        var pad_r = pad_total - pad_l
        var s = String("[")
        for _ in range(pad_l):
            s += fill_ch
        s += " " + core + " "
        for _ in range(pad_r):
            s += fill_ch
        s += "]"
        return s
    # Compact label when bar is narrower than full core text
    var short_txt = prefix + name
    if short_txt.byte_length() > inner_w:
        var cut = String(short_txt[byte=0:inner_w])
        return "[" + cut + "]"
    var rem = inner_w - short_txt.byte_length()
    var s = "[" + short_txt
    for _ in range(rem):
        s += "█"
    return s + "]"


def _render_flamegraph_rows(
    spans: List[ProfileSpan],
    win_s: Float64,
    win_e: Float64,
    width: Int,
    max_rows: Int,
    selected_idx: Int,
    query_low: String,
) -> List[String]:
    var out = List[String]()
    var win_dur = win_e - win_s
    if win_dur <= 0.0:
        return out^

    var max_depth = 0
    for i in range(len(spans)):
        if spans[i].depth > max_depth:
            max_depth = spans[i].depth

    var depth_limit = min(max_depth + 1, max_rows)
    for d in range(depth_limit):
        var row_cells = List[String](length=width, fill=" ")
        for i in range(len(spans)):
            if spans[i].depth != d:
                continue
            var sp = spans[i].copy()
            var s = sp.start_us if sp.start_us > win_s else win_s
            var e_raw = sp.start_us + sp.dur_us
            var e = e_raw if e_raw < win_e else win_e
            if e <= s:
                continue
            var c0 = Int(((s - win_s) / win_dur) * Float64(width))
            var c1 = Int(((e - win_s) / win_dur) * Float64(width) + 0.999)
            c0 = max(0, min(width - 1, c0))
            c1 = max(c0 + 1, min(width, c1))
            var bw = c1 - c0
            var pct_x10 = Int(((e - s) * 1000.0) / win_dur + 0.5)
            var matched = query_low.byte_length() > 0 and (
                lower_str(sp.name).find(query_low) >= 0 or lower_str(sp.category).find(query_low) >= 0
            )
            var bar = _format_flame_bar(sp.name, pct_x10, bw, i == selected_idx, matched)
            var cps = List[String]()
            for ch in bar.codepoint_slices():
                cps.append(String(ch))
            for k in range(min(bw, len(cps))):
                if c0 + k < width:
                    row_cells[c0 + k] = cps[k]
        var line = String("")
        for k in range(width):
            line += row_cells[k]
        out.append(line)
    return out^


def _render_timeline_rows(
    spans: List[ProfileSpan],
    win_s: Float64,
    win_e: Float64,
    width: Int,
    max_rows: Int,
    selected_idx: Int,
    query_low: String,
) -> List[String]:
    var out = List[String]()
    var win_dur = win_e - win_s
    if win_dur <= 0.0:
        return out^

    var streams = List[String]()
    for i in range(len(spans)):
        var sn = spans[i].stream_name
        if not (sn in streams):
            streams.append(sn)

    var gutter_w = min(22, max(10, width // 4))
    var track_w = max(10, width - gutter_w - 3)
    var limit = min(len(streams), max_rows)

    for si in range(limit):
        var sname = streams[si]
        var track = List[String](length=track_w, fill="─")
        # Draw shallower spans first so nested spans or later kernels overlay cleanly
        for i in range(len(spans)):
            if spans[i].stream_name != sname:
                continue
            var sp = spans[i].copy()
            var s = sp.start_us if sp.start_us > win_s else win_s
            var e_raw = sp.start_us + sp.dur_us
            var e = e_raw if e_raw < win_e else win_e
            if e <= s:
                continue
            var c0 = Int(((s - win_s) / win_dur) * Float64(track_w))
            var c1 = Int(((e - win_s) / win_dur) * Float64(track_w) + 0.999)
            c0 = max(0, min(track_w - 1, c0))
            c1 = max(c0 + 1, min(track_w, c1))
            var bw = c1 - c0
            var matched = query_low.byte_length() > 0 and lower_str(sp.name).find(query_low) >= 0
            var mark = "*" if matched else (">" if i == selected_idx else "")
            var tok = "[" + mark + sp.name + " " + _fmt_us(sp.dur_us) + "]"
            if bw < tok.byte_length():
                var short_tok = "[" + mark + sp.name + "]"
                if bw >= short_tok.byte_length():
                    tok = short_tok
                elif bw >= 3:
                    var cut_n = String(sp.name[byte=0 : min(sp.name.byte_length(), bw - 2)])
                    tok = "[" + cut_n + "]"
                elif bw == 2:
                    tok = "[]"
                else:
                    tok = "▮"
            var cps = List[String]()
            for ch in tok.codepoint_slices():
                cps.append(String(ch))
            for k in range(bw):
                if c0 + k < track_w:
                    if k < len(cps) - 1:
                        track[c0 + k] = cps[k]
                    elif k == bw - 1 and len(cps) >= 2:
                        track[c0 + k] = "]"
                    else:
                        track[c0 + k] = "█"
        var track_str = String("")
        for k in range(track_w):
            track_str += track[k]
        out.append(pad_right(sname, gutter_w) + " │ " + track_str)
    return out^


def _json_id_str(doc: Json, node: Int, key: String, fallback: String) -> String:
    var f = doc.get(node, key)
    if f < 0:
        return fallback
    if doc.kind(f) == J_STR:
        return doc.str(f, fallback)
    if doc.kind(f) == J_NUM:
        return String(doc.int(f, 0))
    return fallback


def _default_stream_label(pid_s: String, tid_s: String, cat: String, name: String) -> String:
    var tl = lower_str(tid_s)
    if tl.startswith("stream") or tl.startswith("cpu") or tl.startswith("gpu"):
        return tid_s
    var cl = lower_str(cat)
    var nl = lower_str(name)
    if cl.find("memcpy") >= 0 or cl.find("mem") >= 0 or nl.find("memcpy") >= 0 or nl.find("h2d") >= 0 or nl.find("d2h") >= 0:
        return "Stream " + tid_s + " (H2D/Memcpy)"
    if cl.find("cpu") >= 0 or cl.find("host") >= 0 or cl.find("runtime") >= 0 or cl.find("driver") >= 0:
        return "CPU Host"
    if cl.find("kernel") >= 0 or cl.find("gpu") >= 0 or cl.find("cuda") >= 0 or cl.find("rocm") >= 0 or cl.find("max") >= 0:
        return "Stream " + tid_s + " (Compute)"
    if pid_s == "0" and tid_s == "0":
        return "CPU Host"
    return "Stream " + tid_s


@fieldwise_init
struct _RawEvent(Copyable, Movable):
    var name: String
    var cat: String
    var lane_key: String
    var stream_name: String
    var start_us: Float64
    var dur_us: Float64


@fieldwise_init
struct _OpenBegin(Copyable, Movable):
    var name: String
    var cat: String
    var lane_key: String
    var start_us: Float64


def _build_profile_view_from_events(title: String, mut raw_events: List[_RawEvent]) -> ProfileView:
    var view = ProfileView(title)
    if len(raw_events) == 0:
        return view^

    # Insertion-sort raw events by start_us ascending, then dur_us descending (outer parent before inner child)
    for i in range(1, len(raw_events)):
        var cur = raw_events[i].copy()
        var j = i - 1
        while j >= 0 and (
            raw_events[j].start_us > cur.start_us
            or (raw_events[j].start_us == cur.start_us and raw_events[j].dur_us < cur.dur_us)
        ):
            raw_events[j + 1] = raw_events[j].copy()
            j -= 1
        raw_events[j + 1] = cur^

    # Compute nesting depth and self_us per stream lane
    var lane_keys = List[String]()
    var lane_stacks = List[List[Int]]()

    var min_s = raw_events[0].start_us
    var max_e = raw_events[0].start_us + raw_events[0].dur_us

    for i in range(len(raw_events)):
        var ev = raw_events[i].copy()
        if ev.start_us < min_s:
            min_s = ev.start_us
        if ev.start_us + ev.dur_us > max_e:
            max_e = ev.start_us + ev.dur_us

        var li = -1
        for k in range(len(lane_keys)):
            if lane_keys[k] == ev.lane_key:
                li = k
                break
        if li < 0:
            lane_keys.append(ev.lane_key)
            lane_stacks.append(List[Int]())
            li = len(lane_keys) - 1

        # Pop completed ancestors on this lane
        while len(lane_stacks[li]) > 0:
            var top_idx = lane_stacks[li][len(lane_stacks[li]) - 1]
            var top_end = view.spans[top_idx].start_us + view.spans[top_idx].dur_us
            if top_end <= ev.start_us + 1e-6:
                _ = lane_stacks[li].pop()
            else:
                break

        var depth = len(lane_stacks[li])
        var cur_idx = len(view.spans)
        view.spans.append(
            ProfileSpan(ev.name, ev.cat, ev.stream_name, depth, ev.start_us, ev.dur_us, ev.dur_us)
        )
        if depth > 0:
            var parent_idx = lane_stacks[li][depth - 1]
            var new_self = view.spans[parent_idx].self_us - ev.dur_us
            view.spans[parent_idx].self_us = 0.0 if new_self < 0.0 else new_self
        lane_stacks[li].append(cur_idx)

    view.min_start_us = min_s
    view.max_end_us = max_e
    view.total_dur_us = max(0.0, max_e - min_s)
    view.zoom_start_us = min_s
    view.zoom_end_us = max_e
    view.selected_idx = 0
    return view^


def parse_chrome_trace_json(title: String, json_text: String) -> ProfileView:
    """Parse Chrome Trace Event Format (`{"traceEvents": [...]}` or `[...]`) from `nsys`,
    Modular MAX profiler, PyTorch Kineto, or `rocprof`, supporting `ph: "X"` complete events,
    `ph: "B"`/`"E"` begin/end stacks per `(pid, tid)`, and `ph: "M"` stream metadata."""
    var empty = ProfileView(title)
    if json_text.byte_length() == 0:
        return empty^
    var doc = json_parse(json_text)
    if not doc.ok:
        return empty^

    var arr_node = -1
    if doc.kind(0) == J_ARR:
        arr_node = 0
    elif doc.kind(0) == J_OBJ:
        arr_node = doc.get(0, "traceEvents")
        if arr_node < 0:
            arr_node = doc.get(0, "events")
    if arr_node < 0 or doc.kind(arr_node) != J_ARR:
        return empty^

    var meta_keys = List[String]()
    var meta_names = List[String]()
    var n_ev = doc.size(arr_node)

    # Pass 1: collect thread_name metadata if present
    for idx in range(n_ev):
        var ev = doc.at(arr_node, idx)
        if doc.kind(ev) != J_OBJ:
            continue
        var ph = doc.str(doc.get(ev, "ph"), "")
        if ph == "M" and doc.str(doc.get(ev, "name"), "") == "thread_name":
            var pid_s = _json_id_str(doc, ev, "pid", "0")
            var tid_s = _json_id_str(doc, ev, "tid", "0")
            var tname = doc.str(doc.path(ev, "args/name"), "")
            if tname.byte_length() > 0:
                meta_keys.append(pid_s + ":" + tid_s)
                meta_names.append(tname)

    # Pass 2: collect complete ("X") and matched ("B"/"E") events
    var raw_events = List[_RawEvent]()
    var open_b = List[_OpenBegin]()

    for idx in range(n_ev):
        var ev = doc.at(arr_node, idx)
        if doc.kind(ev) != J_OBJ:
            continue
        var ph = doc.str(doc.get(ev, "ph"), "")
        var pid_s = _json_id_str(doc, ev, "pid", "0")
        var tid_s = _json_id_str(doc, ev, "tid", "0")
        var lane_key = pid_s + ":" + tid_s
        var name = doc.str(doc.get(ev, "name"), "span")
        var cat = doc.str(doc.get(ev, "cat"), "gpu")
        var ts = doc.float(doc.get(ev, "ts"), 0.0)

        var stream_lbl = String("")
        for mk in range(len(meta_keys)):
            if meta_keys[mk] == lane_key:
                stream_lbl = meta_names[mk]
                break
        if stream_lbl.byte_length() == 0:
            stream_lbl = _default_stream_label(pid_s, tid_s, cat, name)

        if ph == "X":
            var dur = max(0.0, doc.float(doc.get(ev, "dur"), 0.0))
            raw_events.append(_RawEvent(name, cat, lane_key, stream_lbl, ts, dur))
        elif ph == "B":
            open_b.append(_OpenBegin(name, cat, lane_key, ts))
        elif ph == "E":
            # Pop matching top-of-stack begin event on the same (pid, tid) lane
            var match_i = -1
            var k = len(open_b) - 1
            while k >= 0:
                if open_b[k].lane_key == lane_key:
                    match_i = k
                    break
                k -= 1
            if match_i >= 0:
                var beg = open_b[match_i].copy()
                _ = open_b.pop(match_i)
                var dur = max(0.0, ts - beg.start_us)
                var s_lbl = stream_lbl
                if s_lbl.byte_length() == 0:
                    s_lbl = _default_stream_label(pid_s, tid_s, beg.cat, beg.name)
                raw_events.append(_RawEvent(beg.name, beg.cat, lane_key, s_lbl, beg.start_us, dur))

    return _build_profile_view_from_events(title, raw_events)


def _unit_to_us(val: Float64, unit_raw: String) -> Float64:
    var u = lower_str(String(unit_raw.strip()))
    if u.startswith("ps"):
        return val * 0.000001
    if u.startswith("ns"):
        return val * 0.001
    if u.startswith("us") or u.startswith("µs"):
        return val
    if u.startswith("ms"):
        return val * 1000.0
    if u == "s" or u.startswith("sec"):
        return val * 1000000.0
    return val


@fieldwise_init
struct _FoldedEntry(Copyable, Movable):
    var stack_key: String
    var frames: List[String]
    var weight_us: Float64


def parse_folded_stacks(title: String, text: String) -> ProfileView:
    """Parse Brendan Gregg folded stack lines (`main;run_kernel;matmul_tile 420`) AND
    `std.benchmark` console / markdown summary tables into hierarchical `ProfileSpan` trees."""
    var entries = List[_FoldedEntry]()
    if text.byte_length() == 0:
        return ProfileView(title)

    var table_unit = String("ms")
    for line_slice in text.split("\n"):
        var raw = String(line_slice)
        var t = String(raw.strip())
        if t.byte_length() == 0 or t.startswith("#") or t.startswith("Benchmark report:") or t.startswith("Running"):
            continue

        # 1. `std.benchmark` Markdown pipe table (`| name | met (ms) | iters |`)
        if t.startswith("|") and t.endswith("|"):
            var inner = String(t[byte=1 : t.byte_length() - 1])
            var pcells = List[String]()
            for p in inner.split("|"):
                pcells.append(String(p.strip()))
            if len(pcells) >= 2:
                var c0_low = lower_str(pcells[0])
                if c0_low.startswith("---") or c0_low == "name" or c0_low == "benchmark":
                    var hdr_low = lower_str(pcells[1])
                    if hdr_low.find("(ns)") >= 0:
                        table_unit = "ns"
                    elif hdr_low.find("(us)") >= 0 or hdr_low.find("(µs)") >= 0:
                        table_unit = "us"
                    elif hdr_low.find("(ms)") >= 0:
                        table_unit = "ms"
                    elif hdr_low.find("(s)") >= 0:
                        table_unit = "s"
                    continue
                var val = _parse_float_clean(pcells[1], -1.0)
                if val > 0.0 and pcells[0].byte_length() > 0:
                    var dur_us = _unit_to_us(val, table_unit)
                    var frames = List[String]()
                    frames.append("std.benchmark")
                    for seg in pcells[0].split("/"):
                        var fs = String(seg.strip())
                        if fs.byte_length() > 0:
                            frames.append(fs)
                    entries.append(_FoldedEntry(";".join(frames), frames^, dur_us))
            continue

        # 2. `std.benchmark` console report line (`bench_matmul: 250.0 us (500 iters)`)
        var colon = t.find(":")
        if colon > 0 and t.find(";") < 0:
            var bname = String(t[byte=0:colon].strip())
            var rest = String(t[byte=colon + 1 :].strip())
            var rparts = List[String]()
            for rp in rest.split(" "):
                var rps = String(rp.strip())
                if rps.byte_length() > 0:
                    rparts.append(rps)
            if len(rparts) >= 2:
                var bval = _parse_float_clean(rparts[0], -1.0)
                if bval > 0.0:
                    var dur_us = _unit_to_us(bval, rparts[1])
                    var frames = List[String]()
                    frames.append("std.benchmark")
                    for seg in bname.split("/"):
                        var fs = String(seg.strip())
                        if fs.byte_length() > 0:
                            frames.append(fs)
                    entries.append(_FoldedEntry(";".join(frames), frames^, dur_us))
                    continue

        # 3. Standard Brendan Gregg folded stack (`frame0;frame1;frame2 420`)
        var bs = t.as_bytes()
        var split_idx = len(bs) - 1
        while split_idx > 0 and bs[split_idx] != 32 and bs[split_idx] != 9:
            split_idx -= 1
        if split_idx <= 0:
            continue
        var stack_part = String(t[byte=0:split_idx].strip())
        var count_part = String(t[byte=split_idx + 1 :].strip())
        var weight = _parse_float_clean(count_part, -1.0)
        if weight <= 0.0 or stack_part.byte_length() == 0:
            continue
        var frames = List[String]()
        for seg in stack_part.split(";"):
            var fs = String(seg.strip())
            if fs.byte_length() > 0:
                frames.append(fs)
        if len(frames) == 0:
            continue
        var key = ";".join(frames)
        # Merge identical stack keys while preserving first-seen prefix order
        var merged = False
        for ei in range(len(entries)):
            if entries[ei].stack_key == key:
                entries[ei].weight_us += weight
                merged = True
                break
        if not merged:
            entries.append(_FoldedEntry(key, frames^, weight))

    if len(entries) == 0:
        return ProfileView(title)

    # Group common prefixes cleanly by sorting lexicographically when non-adjacent prefixes repeat
    for i in range(1, len(entries)):
        var cur = entries[i].copy()
        var j = i - 1
        while j >= 0 and entries[j].stack_key > cur.stack_key:
            entries[j + 1] = entries[j].copy()
            j -= 1
        entries[j + 1] = cur^

    # Build hierarchical spans across x-axis cursor `cursor_us`
    var raw_events = List[_RawEvent]()
    var open_names = List[String]()
    var open_starts = List[Float64]()
    var cursor_us: Float64 = 0.0

    for ei in range(len(entries)):
        var ent = entries[ei].copy()
        var lcp = 0
        var max_lcp = min(len(open_names), len(ent.frames))
        while lcp < max_lcp and open_names[lcp] == ent.frames[lcp]:
            lcp += 1
        # Close frames deeper than lcp
        while len(open_names) > lcp:
            var nm = open_names.pop()
            var st = open_starts.pop()
            raw_events.append(_RawEvent(nm, "stack", "0:0", "Aggregated Stacks", st, cursor_us - st))
        # Open new frames from lcp..len(ent.frames)-1
        for d in range(lcp, len(ent.frames)):
            open_names.append(ent.frames[d])
            open_starts.append(cursor_us)
        cursor_us += ent.weight_us

    while len(open_names) > 0:
        var nm = open_names.pop()
        var st = open_starts.pop()
        raw_events.append(_RawEvent(nm, "stack", "0:0", "Aggregated Stacks", st, cursor_us - st))

    return _build_profile_view_from_events(title, raw_events)


# ---------------------------------------------------------------------------
# 3. `LayoutTensor` Coalescing, XOR Swizzle & MAX `Graph` Fusion Visualizer
# ---------------------------------------------------------------------------

@fieldwise_init
struct LayoutVizReport(Copyable, Movable):
    var shape_r: Int
    var shape_c: Int
    var stride_r: Int
    var stride_c: Int
    var elem_bytes: Int
    var swizzle_bits: Int
    var global_transactions_per_warp: Int
    var coalescing_efficiency_pct: Int
    var smem_bank_conflicts: Int
    var recommended_swizzle: String
    var diagram_lines: List[String]


def _count_warp_smem_conflicts(
    byte_addrs: List[Int],
    elem_bytes: Int,
    swizzle_bits: Int,
    bank_bit_shift: Int,
) -> Tuple[Int, List[Int], List[Int]]:
    """Simulate 32-bank shared-memory conflicts for a 32-lane warp.

    Two lanes accessing the exact same 4-byte bank word (`word_id = byte_addr // 4`) merge/broadcast
    in 1 cycle; distinct `word_id`s mapping to the same bank serialize into N-way bank conflicts.
    Returns `(max_conflict_ways, lane_banks[32], bank_hit_counts[32])`.
    """
    var mask = ((1 << swizzle_bits) - 1) if swizzle_bits > 0 else 0
    var lane_banks = List[Int](length=32, fill=0)
    var total_bank_hits = List[Int](length=32, fill=0)

    # 64-bit/128-bit accesses split into 128-byte wavefront phases on GPU SMs
    var lanes_per_phase = 32
    if elem_bytes >= 16:
        lanes_per_phase = 8
    elif elem_bytes >= 8:
        lanes_per_phase = 16

    var max_ways = 1
    var phase_start = 0
    while phase_start < 32:
        var phase_end = min(32, phase_start + lanes_per_phase)
        var bank_words = List[List[Int]]()
        for _ in range(32):
            bank_words.append(List[Int]())

        for lane in range(phase_start, phase_end):
            var addr = max(0, byte_addrs[lane])
            var word_id = addr // 4
            var raw_bank = (addr >> 2) & 31
            var xor_val = ((addr >> 7) & mask) << bank_bit_shift if swizzle_bits > 0 else 0
            var bank = (raw_bank ^ xor_val) & 31
            lane_banks[lane] = bank
            if not (word_id in bank_words[bank]):
                bank_words[bank].append(word_id)
                total_bank_hits[bank] += 1
            if len(bank_words[bank]) > max_ways:
                max_ways = len(bank_words[bank])
        phase_start += lanes_per_phase

    return (max_ways, lane_banks^, total_bank_hits^)


def _choose_bank_shift(byte_addrs: List[Int], elem_bytes: Int, swizzle_bits: Int) -> Int:
    """Choose the bit offset within the 5-bit bank index (`0 .. 5 - swizzle_bits`) for XOR swizzling,
    mirroring `Swizzle[B, M, S]` base alignment (preferring `0` when tied, i.e. `bank ^ ((addr >> 7) & mask)`)."""
    if swizzle_bits <= 0:
        return 0
    var sb = min(5, swizzle_bits)
    var best_shift = 0
    var best_ways = 99
    for sh in range(0, 5 - sb + 1):
        var res = _count_warp_smem_conflicts(byte_addrs, elem_bytes, sb, sh)
        if res[0] < best_ways:
            best_ways = res[0]
            best_shift = sh
    return best_shift


def analyze_layout_tensor(
    shape_r: Int,
    shape_c: Int,
    stride_r: Int,
    stride_c: Int,
    elem_bytes: Int = 4,
    thread_cols: Int = 16,
    swizzle_bits: Int = 0,
) -> LayoutVizReport:
    """Simulate a 32-lane warp accessing a `LayoutTensor` tile for global 128B L1/HBM cacheline
    coalescing, 32-bank shared-memory conflicts, and XOR bank swizzling."""
    var eb = max(1, elem_bytes)
    var tcols = max(1, thread_cols)
    var sbits = max(0, min(5, swizzle_bits))

    var byte_addrs = List[Int](length=32, fill=0)
    var unique_sectors = List[Int]()
    for lane in range(32):
        var r = lane // tcols
        var c = lane % tcols
        var addr = (r * stride_r + c * stride_c) * eb
        byte_addrs[lane] = addr
        var sec = addr // 128 if addr >= 0 else -1
        if not (sec in unique_sectors):
            unique_sectors.append(sec)

    var global_tx = max(1, min(32, len(unique_sectors)))
    var ideal_tx = max(1, min(32, (32 * eb + 127) // 128))
    var coal_pct = min(100, max(1, (ideal_tx * 100) // global_tx))

    var b_shift = _choose_bank_shift(byte_addrs, eb, sbits)
    var sim = _count_warp_smem_conflicts(byte_addrs, eb, sbits, b_shift)
    var conflicts = sim[0]
    var lane_banks = sim[1].copy()
    var bank_hits = sim[2].copy()

    var rec = String("1-way conflict-free across 32 shared-memory banks")
    if sbits > 0 and conflicts <= 1:
        rec = "1-way conflict-free with Swizzle(" + String(sbits) + ", " + String(2 + b_shift) + ", 3)"
    elif conflicts > 1:
        var best_b = 3
        var best_m = 2
        for cand_b in range(1, 6):
            var c_sh = _choose_bank_shift(byte_addrs, eb, cand_b)
            var c_sim = _count_warp_smem_conflicts(byte_addrs, eb, cand_b, c_sh)
            if c_sim[0] <= 1:
                best_b = cand_b
                best_m = 2 + c_sh
                break
        var pad_sr = (stride_r + 1) if stride_r >= stride_c else stride_r
        var pad_sc = (stride_c + 1) if stride_c > stride_r else stride_c
        rec = (
            "Apply XOR Swizzle("
            + String(best_b)
            + ", "
            + String(best_m)
            + ", 3) or pad inner stride +1: Layout(IntTuple("
            + String(shape_r)
            + ", "
            + String(shape_c)
            + "), IntTuple("
            + String(pad_sr)
            + ", "
            + String(pad_sc)
            + "))"
        )

    var diag = List[String]()
    diag.append(
        "LayoutTensor Tile ["
        + String(shape_r)
        + "×"
        + String(shape_c)
        + "]  stride=("
        + String(stride_r)
        + ", "
        + String(stride_c)
        + ")  elem="
        + String(eb)
        + "B  swizzle_bits="
        + String(sbits)
    )
    diag.append(
        "  Global HBM/L1 Coalescing : "
        + String(global_tx)
        + " × 128B sector transaction(s)/warp  ("
        + String(coal_pct)
        + "% efficiency)"
    )
    var smem_tag = "✓ 1-way conflict-free" if conflicts <= 1 else ("⚠ " + String(conflicts) + "-way bank conflict")
    diag.append("  Shared-Memory 32-Bank    : " + smem_tag)
    diag.append("  Warp Lane -> Bank & 128B Cacheline Mapping (T00..T31 -> B00..B31):")

    # Render 4 rows × 8 lanes showing T00..T31 -> B00..B31@C<sector>
    for row_grp in range(4):
        var line = String("    ")
        for sub in range(8):
            var lane = row_grp * 8 + sub
            var sec_idx = max(0, byte_addrs[lane]) // 128
            var cell = "T" + _pad2(lane) + "->B" + _pad2(lane_banks[lane]) + "@C" + String(sec_idx)
            line += cell + ("  " if sub < 7 else "")
        diag.append(line)

    var strip = String("  Bank Pressure [B00..B31] : ")
    for b in range(32):
        var h = bank_hits[b]
        if h <= 0:
            strip += "·"
        elif h == 1:
            strip += "▪"
        elif h == 2:
            strip += "▒"
        elif h <= 4:
            strip += "▓"
        else:
            strip += "█"
    diag.append(strip)
    diag.append("  Recommendation           : " + rec)

    return LayoutVizReport(
        shape_r,
        shape_c,
        stride_r,
        stride_c,
        eb,
        sbits,
        global_tx,
        coal_pct,
        conflicts,
        rec,
        diag^,
    )


def _extract_two_ints(inside: String) -> Tuple[Bool, Int, Int]:
    var comma = inside.find(",")
    if comma <= 0:
        return (False, 0, 0)
    var a = _parse_int_clean(String(inside[byte=0:comma]), -1)
    var b = _parse_int_clean(String(inside[byte=comma + 1 :]), -1)
    if a > 0 and b > 0:
        return (True, a, b)
    return (False, 0, 0)


def parse_layout_from_mojo_source(src: String) -> LayoutVizReport:
    """Extract `Layout.row_major(M, N)`, `Layout.col_major(M, N)`, or
    `Layout(IntTuple(M, N), IntTuple(sr, sc))` + dtype byte width from Mojo source,
    falling back to a `16×16 Float16` default demo when none is found."""
    var elem_b = 4
    var found_dtype = False
    if src.find("Float64") >= 0 or src.find("float64") >= 0 or src.find("Int64") >= 0 or src.find("UInt64") >= 0:
        elem_b = 8
        found_dtype = True
    elif (
        src.find("Float16") >= 0
        or src.find("float16") >= 0
        or src.find("BFloat16") >= 0
        or src.find("bfloat16") >= 0
        or src.find("Int16") >= 0
    ):
        elem_b = 2
        found_dtype = True
    elif src.find("Float32") >= 0 or src.find("float32") >= 0 or src.find("Int32") >= 0:
        elem_b = 4
        found_dtype = True
    elif src.find("Float8") >= 0 or src.find("float8") >= 0 or src.find("Int8") >= 0 or src.find("UInt8") >= 0:
        elem_b = 1
        found_dtype = True

    var swz_bits = 0
    for sw_pat in ["Swizzle(", "Swizzle["]:
        var sp = src.find(String(sw_pat))
        if sp >= 0:
            var after_sw = String(src[byte=sp + String(sw_pat).byte_length() :])
            var sb = _parse_int_clean(after_sw, 0)
            if sb > 0 and sb <= 5:
                swz_bits = sb
                break

    # 1. Check `Layout.row_major(M, N)` / `Layout.row_major[M, N]`
    for pat in ["Layout.row_major(", "Layout.row_major["]:
        var p = src.find(String(pat))
        if p >= 0:
            var close_ch = ")" if String(pat).endswith("(") else "]"
            var start = p + String(pat).byte_length()
            var end = src.find(close_ch, start)
            if end > start:
                var pair = _extract_two_ints(String(src[byte=start:end]))
                if pair[0]:
                    var mr = pair[1]
                    var nc = pair[2]
                    var tc = min(16, max(1, nc))
                    return analyze_layout_tensor(mr, nc, nc, 1, elem_b, tc, swz_bits)

    # 2. Check `Layout.col_major(M, N)` / `Layout.col_major[M, N]`
    for pat in ["Layout.col_major(", "Layout.col_major["]:
        var p = src.find(String(pat))
        if p >= 0:
            var close_ch = ")" if String(pat).endswith("(") else "]"
            var start = p + String(pat).byte_length()
            var end = src.find(close_ch, start)
            if end > start:
                var pair = _extract_two_ints(String(src[byte=start:end]))
                if pair[0]:
                    var mr = pair[1]
                    var nc = pair[2]
                    var tc = min(16, max(1, nc))
                    return analyze_layout_tensor(mr, nc, 1, mr, elem_b, tc, swz_bits)

    # 3. Check `Layout(IntTuple(M, N), IntTuple(sr, sc))`
    var lp = src.find("Layout(")
    if lp >= 0:
        var it1 = src.find("IntTuple(", lp)
        if it1 >= 0:
            var s1 = it1 + 9
            var e1 = src.find(")", s1)
            if e1 > s1:
                var shp = _extract_two_ints(String(src[byte=s1:e1]))
                if shp[0]:
                    var mr = shp[1]
                    var nc = shp[2]
                    var sr = nc
                    var sc = 1
                    var it2 = src.find("IntTuple(", e1 + 1)
                    if it2 >= 0:
                        var s2 = it2 + 9
                        var e2 = src.find(")", s2)
                        if e2 > s2:
                            var st = _extract_two_ints(String(src[byte=s2:e2]))
                            if st[0]:
                                sr = st[1]
                                sc = st[2]
                    var tc = min(16, max(1, nc))
                    return analyze_layout_tensor(mr, nc, sr, sc, elem_b, tc, swz_bits)

    # Helpful 16×16 Float16 default demo when no Layout call was found
    var demo_eb = elem_b if found_dtype else 2
    return analyze_layout_tensor(16, 16, 16, 1, demo_eb, 16, swz_bits)


@fieldwise_init
struct _GraphOp(Copyable, Movable):
    var raw_op: String
    var display_op: String
    var kind: Int          # 0 = compute anchor (matmul/conv), 1 = elementwise epilogue, 2 = reduction/norm
    var line_no: Int
    var src_line: String


def _classify_max_op(op_name: String, line_text: String, prev_was_gemm: Bool) -> Tuple[Int, String]:
    var low = lower_str(op_name)
    if low == "matmul" or low == "bmm" or low == "conv2d" or low == "qmatmul":
        return (0, low)
    if (
        low == "layer_norm"
        or low == "rms_norm"
        or low == "softmax"
        or low == "log_softmax"
        or low == "reduce_sum"
        or low == "reduce_max"
        or low == "mean"
    ):
        return (2, low)
    if low == "add" and (prev_was_gemm or lower_str(line_text).find("bias") >= 0):
        return (1, "bias_add")
    return (1, low)


def render_max_graph_fusion(src: String) -> List[String]:
    """Scan Modular MAX `Graph` / `ops.` chains and render fused kernel boundary boxes
    (`╭─ Fused Epilogue Kernel: matmul + bias_add + gelu ─╮`) with saved HBM round-trip counts."""
    var ops_found = List[_GraphOp]()
    var graph_name = String("MAX Graph")

    var line_no = 0
    for line_slice in src.split("\n"):
        line_no += 1
        var raw = String(line_slice)
        var t = String(raw.strip())
        if t.byte_length() == 0 or t.startswith("#") or t.startswith("//"):
            continue

        var gp = t.find("Graph(")
        if gp >= 0:
            var q1 = t.find("\"", gp + 6)
            var q2 = t.find("\"", q1 + 1) if q1 >= 0 else -1
            if q1 >= 0 and q2 > q1 + 1:
                graph_name = "Graph(\"" + String(t[byte=q1 + 1 : q2]) + "\")"

        # Scan all `ops.<name>(` occurrences on this line
        var search_from = 0
        while search_from < t.byte_length():
            var op_pos = t.find("ops.", search_from)
            if op_pos < 0:
                break
            var name_start = op_pos + 4
            var bs = t.as_bytes()
            var cur = name_start
            while cur < len(bs):
                var c = Int(bs[cur])
                if (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 95:
                    cur += 1
                else:
                    break
            if cur > name_start and cur < len(bs) and (Int(bs[cur]) == 40 or Int(bs[cur]) == 91):
                var op_nm = String(t[byte=name_start:cur])
                var prev_gemm = len(ops_found) > 0 and (
                    ops_found[len(ops_found) - 1].kind == 0 or ops_found[len(ops_found) - 1].kind == 1
                )
                var cls = _classify_max_op(op_nm, t, prev_gemm)
                ops_found.append(_GraphOp(op_nm, cls[1], cls[0], line_no, t))
            search_from = cur + 1

    var out = List[String]()
    if len(ops_found) == 0:
        out.append("MAX Graph Kernel Fusion Visualizer")
        out.append("  (no `ops.*` graph operations detected in current buffer)")
        return out^

    # Partition ops into fused kernel groups
    var groups = List[List[_GraphOp]]()
    var i = 0
    while i < len(ops_found):
        var grp = List[_GraphOp]()
        var first = ops_found[i].copy()
        grp.append(first.copy())
        i += 1
        if first.kind == 0:
            # Anchor matmul/conv absorbs all trailing elementwise epilogue ops
            while i < len(ops_found) and ops_found[i].kind == 1:
                grp.append(ops_found[i].copy())
                i += 1
        elif first.kind == 1:
            # Consecutive elementwise ops fuse into a single elementwise kernel
            while i < len(ops_found) and ops_found[i].kind == 1:
                grp.append(ops_found[i].copy())
                i += 1
        elif first.kind == 2:
            # Reduction/norm kernel can absorb trailing elementwise scale/cast epilogue
            while i < len(ops_found) and ops_found[i].kind == 1:
                grp.append(ops_found[i].copy())
                i += 1
        groups.append(grp^)

    var saved_roundtrips = len(ops_found) - len(groups)
    out.append(
        "MAX Graph Kernel Fusion Plan — "
        + graph_name
        + "  ("
        + String(len(ops_found))
        + " ops → "
        + String(len(groups))
        + " kernel(s), "
        + String(saved_roundtrips)
        + " HBM round-trip(s) saved)"
    )
    out.append("")

    for gi in range(len(groups)):
        var grp = groups[gi].copy()
        var chain_names = List[String]()
        for oi in range(len(grp)):
            chain_names.append(grp[oi].display_op)
        var chain_txt = " + ".join(chain_names)

        var ktype = String("Standalone Kernel")
        if len(grp) > 1 and grp[0].kind == 0:
            ktype = "Fused Epilogue Kernel"
        elif len(grp) > 1 and grp[0].kind == 1:
            ktype = "Fused Elementwise Kernel"
        elif grp[0].kind == 2:
            ktype = "Fused Reduction Kernel"

        var hdr_core = "─ " + ktype + ": " + chain_txt + " ─"
        var box_inner_w = max(54, hdr_core.byte_length())
        var extra_dashes = box_inner_w - hdr_core.byte_length()
        var top_bar = "╭" + hdr_core
        for _ in range(extra_dashes):
            top_bar += "─"
        top_bar += "╮"
        out.append(top_bar)

        for oi in range(len(grp)):
            var op = grp[oi].copy()
            var row_txt = "  [L" + String(op.line_no) + "] ops." + op.raw_op + "  (" + op.display_op + ")"
            out.append("│" + pad_right(row_txt, box_inner_w) + "│")
            if oi + 1 < len(grp):
                out.append(
                    "│"
                    + pad_right("    ↳ fused in Tensor/RF registers (0 HBM round-trips)", box_inner_w)
                    + "│"
                )

        if len(grp) > 1:
            var sv = len(grp) - 1
            out.append(
                "│"
                + pad_right(
                    "  ✓ Saved " + String(sv) + " intermediate HBM global read/write round-trip(s)",
                    box_inner_w,
                )
                + "│"
            )

        var bot_bar = String("╰")
        for _ in range(box_inner_w):
            bot_bar += "─"
        bot_bar += "╯"
        out.append(bot_bar)

        if gi + 1 < len(groups):
            out.append("     │  ▼ HBM Tensor Materialization (Global Memory)")

    return out^
