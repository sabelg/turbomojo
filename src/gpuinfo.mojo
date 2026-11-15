"""Which GPU will the program run on? (P11-10a) Mojo programs that use a GPU take the
first one the driver lists (CUDA_VISIBLE_DEVICES / HIP_VISIBLE_DEVICES change which),
so TurboMojo asks the vendor's tool once - nvidia-smi for NVIDIA, rocm-smi for AMD -
and shows the answer in `tmide --caps` and, when `ui.gpu_status` is on, on the status
line. The question runs in the background (it can take a second on a busy server).

This module has the command and reads its output; the IDE runs it (app_gpu.mojo)."""
from std.collections import List
from util import bytes_to_str, shell_quote

# one shell command for every machine: the first line says which tool answered
comptime GPU_QUERY = "if command -v nvidia-smi >/dev/null 2>&1; then echo nvidia; nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null; elif command -v rocm-smi >/dev/null 2>&1; then echo rocm; rocm-smi --showproductname --csv 2>/dev/null; else echo none; fi"


struct GpuInfo(Copyable, Movable):
    var name: String
    var memory: String          # "81559 MiB", or "" when the driver does not say (unified memory)
    var driver: String

    def __init__(out self, name: String, memory: String = "", driver: String = ""):
        self.name = name
        self.memory = memory
        self.driver = driver


def csv_cells(line: String) -> List[String]:
    var out = List[String]()
    for c in line.split(","):
        out.append(String(String(c).strip()))
    return out^


def unknown(v: String) -> Bool:
    return v.byte_length() == 0 or v.startswith("[N/A]") or v == "N/A" or v.startswith("[Not Supported]")


def parse_gpus(output: String) -> List[GpuInfo]:
    """The GPUs in GPU_QUERY's output, in the driver's order (empty: none, or no tool)."""
    var gpus = List[GpuInfo]()
    var lines = List[String]()
    for l in output.split("\n"):
        var s = String(String(l).strip())
        if s.byte_length() > 0:
            lines.append(s)
    if len(lines) == 0:
        return gpus^
    if lines[0] == "nvidia":
        # "NVIDIA H100 80GB HBM3, 81559 MiB, 570.86.15" per GPU
        for k in range(1, len(lines)):
            var c = csv_cells(lines[k])
            if len(c) == 0 or c[0].byte_length() == 0 or c[0].find("NVIDIA-SMI has failed") >= 0:
                continue
            gpus.append(GpuInfo(c[0], c[1] if len(c) > 1 and not unknown(c[1]) else String(""), c[2] if len(c) > 2 and not unknown(c[2]) else String("")))
    elif lines[0] == "rocm":
        # a CSV table: a header with "Card series" (or "Card Series"), then one row per GPU
        var col = -1
        for k in range(1, len(lines)):
            var c = csv_cells(lines[k])
            if col < 0:
                for j in range(len(c)):
                    if c[j].lower() == "card series":
                        col = j
                continue
            if col < len(c) and not unknown(c[col]):
                gpus.append(GpuInfo(c[col]))
    return gpus^


def gpu_line(gpus: List[GpuInfo]) -> String:
    """For `tmide --caps`: the one a program uses first, and how many there are."""
    if len(gpus) == 0:
        return "none found (nvidia-smi or rocm-smi)"
    var g = gpus[0].copy()
    var s = g.name
    if g.memory.byte_length() > 0:
        s += ", " + g.memory
    if g.driver.byte_length() > 0:
        s += ", driver " + g.driver
    if len(gpus) > 1:
        s += "  (the first of " + String(len(gpus)) + ")"
    return s


def gpu_short(gpus: List[GpuInfo]) -> String:
    """For the status line: "GPU GB10", "GPU H100 80GB HBM3 ×8"; "" with none."""
    if len(gpus) == 0:
        return ""
    var name = gpus[0].name
    for p in ["NVIDIA ", "AMD ", "Radeon "]:
        if name.startswith(String(p)):
            var rest = String(name[byte=String(p).byte_length():])
            name = rest
    var s = "GPU " + name
    if len(gpus) > 1:
        s += " ×" + String(len(gpus))
    return s


comptime GPU_TELEMETRY_QUERY = "if command -v nvidia-smi >/dev/null 2>&1; then echo nvidia; nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null; echo __PROCS__; nvidia-smi --query-compute-apps=gpu_bus_id,pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null || true; elif command -v rocm-smi >/dev/null 2>&1; then echo rocm; rocm-smi --showuse --showmeminfo vram --showtemp --showpower --csv 2>/dev/null; else echo none; fi"


@fieldwise_init
struct GpuSample(Copyable, Movable):
    var index: Int
    var name: String
    var util_pct: Int           # -1 when not reported
    var mem_used_mib: Int       # -1 when unified / not reported
    var mem_total_mib: Int      # -1 when unified / not reported
    var temp_c: Int             # -1 when not reported
    var power_w: String         # "" when not reported


def parse_int_or(text: String, fallback: Int = -1) -> Int:
    var t = String(text.strip())
    if unknown(t) or t.byte_length() == 0:
        return fallback
    var n = 0
    var got = False
    for b in t.as_bytes():
        var c = Int(b)
        if c >= 48 and c <= 57:
            n = n * 10 + c - 48
            got = True
        else:
            break
    return n if got else fallback


def parse_gpu_samples(output: String) -> Tuple[List[GpuSample], List[String]]:
    """Parse GPU_TELEMETRY_QUERY output into (per-GPU samples, active compute process lines)."""
    var samples = List[GpuSample]()
    var procs = List[String]()
    var lines = List[String]()
    for l in output.split("\n"):
        var s = String(String(l).strip())
        if s.byte_length() > 0:
            lines.append(s)
    if len(lines) == 0 or lines[0] == "none":
        return (samples^, procs^)
    if lines[0] == "nvidia":
        var in_procs = False
        for k in range(1, len(lines)):
            if lines[k] == "__PROCS__":
                in_procs = True
                continue
            var c = csv_cells(lines[k])
            if len(c) == 0 or c[0].find("NVIDIA-SMI has failed") >= 0:
                continue
            if in_procs:
                if len(c) >= 3 and c[1].byte_length() > 0:
                    var mem_note = String("")
                    if len(c) > 3 and not unknown(c[3]):
                        var cu3 = c[3].upper()
                        var has_mib = cu3.endswith("MIB") or cu3.endswith("MB") or cu3.endswith("B")
                        mem_note = "  " + c[3] + ("" if has_mib else " MiB")
                    procs.append("PID " + c[1] + "  " + c[2] + mem_note)
                continue
            if len(c) < 2:
                continue
            var idx = parse_int_or(c[0], len(samples))
            var nm = c[1]
            var util = parse_int_or(c[2], -1) if len(c) > 2 else -1
            var mu = parse_int_or(c[3], -1) if len(c) > 3 else -1
            var mt = parse_int_or(c[4], -1) if len(c) > 4 else -1
            var tc = parse_int_or(c[5], -1) if len(c) > 5 else -1
            var pw = c[6] if (len(c) > 6 and not unknown(c[6])) else String("")
            samples.append(GpuSample(idx, nm, util, mu, mt, tc, pw))
    elif lines[0] == "rocm":
        var hdr = List[String]()
        for k in range(1, len(lines)):
            var c = csv_cells(lines[k])
            if len(hdr) == 0:
                for cell in c:
                    hdr.append(cell.lower())
                continue
            var nm = c[0] if len(c) > 0 else String("AMD GPU")
            var util = -1
            var mu = -1
            var mt = -1
            var tc = -1
            var pw = String("")
            for j in range(min(len(hdr), len(c))):
                if hdr[j].find("gpu use") >= 0:
                    util = parse_int_or(c[j], -1)
                elif hdr[j].find("vram total used") >= 0:
                    var b_used = parse_int_or(c[j], -1)
                    if b_used >= 0:
                        mu = b_used // (1024 * 1024)
                elif hdr[j].find("vram total memory") >= 0:
                    var b_tot = parse_int_or(c[j], -1)
                    if b_tot >= 0:
                        mt = b_tot // (1024 * 1024)
                elif hdr[j].find("temperature") >= 0 and tc < 0:
                    tc = parse_int_or(c[j], -1)
                elif hdr[j].find("power") >= 0 and pw.byte_length() == 0 and not unknown(c[j]):
                    pw = c[j]
            samples.append(GpuSample(len(samples), nm, util, mu, mt, tc, pw))
    return (samples^, procs^)


def gpu_bar(pct: Int, width: Int = 16) -> String:
    """Visual bar for 0..100% (`[████████░░░░░░░░]`)."""
    if pct < 0:
        return "[n/a]"
    var clamped = 0 if pct < 0 else (100 if pct > 100 else pct)
    var filled = (clamped * width + 50) // 100
    var out = String("[")
    for k in range(width):
        out += "█" if k < filled else "░"
    return out + "]"


def gpu_sparkline(hist: List[Int]) -> String:
    """Compact Unicode sparkline over recent utilization samples (0..100)."""
    if len(hist) == 0:
        return ""
    var blocks = List[String]()
    for b in ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]:
        blocks.append(String(b))
    var out = String("")
    for v in hist:
        if v < 0:
            out += "·"
        else:
            var c = 0 if v < 0 else (100 if v > 100 else v)
            var idx = (c * 7 + 50) // 100
            out += blocks[idx]
    return out


def format_gpu_monitor(samples: List[GpuSample], procs: List[String], hist: List[List[Int]]) -> List[String]:
    """Lines shown in Window > GPU monitor (WK_GPU)."""
    var out = List[String]()
    out.append("GPU Telemetry   (r: refresh now, Esc: close)")
    out.append("")
    if len(samples) == 0:
        out.append("  No GPU telemetry available (nvidia-smi / rocm-smi did not report a device).")
        return out^
    for i in range(len(samples)):
        var s = samples[i].copy()
        out.append("GPU " + String(s.index) + ": " + s.name)
        var util_txt = (String(s.util_pct) + "%") if s.util_pct >= 0 else String("n/a")
        var spark = gpu_sparkline(hist[i]) if i < len(hist) else String("")
        out.append("  Compute: " + gpu_bar(s.util_pct, 16) + " " + util_txt + (("  " + spark) if spark.byte_length() > 0 else String("")))
        if s.mem_used_mib >= 0 and s.mem_total_mib > 0:
            var mpct = (s.mem_used_mib * 100) // s.mem_total_mib
            out.append("  VRAM:    " + gpu_bar(mpct, 16) + " " + String(s.mem_used_mib) + " / " + String(s.mem_total_mib) + " MiB (" + String(mpct) + "%)")
        else:
            out.append("  VRAM:    unified / shared host memory")
        var meta = String("")
        if s.temp_c >= 0:
            meta += "Temp " + String(s.temp_c) + "°C"
        if s.power_w.byte_length() > 0:
            var pwu = s.power_w.upper()
            var pw_unit = "" if pwu.endswith("W") else " W"
            meta += ("  ·  " if meta.byte_length() > 0 else String("")) + "Power " + s.power_w + pw_unit
        if meta.byte_length() > 0:
            out.append("  Sensors: " + meta)
        out.append("")
    out.append("Active Compute Processes")
    if len(procs) == 0:
        out.append("  (none)")
    else:
        for p in procs:
            out.append("  " + p)
    return out^


@fieldwise_init
struct KernelStat(Copyable, Movable):
    var pct: Int
    var time_txt: String
    var calls: String
    var name: String


def _ws_tokens(line: String) -> List[String]:
    var out = List[String]()
    var cur = String("")
    for ch in line.codepoint_slices():
        var s = String(ch)
        if s == " " or s == "\t" or s == "|":
            if cur.byte_length() > 0:
                out.append(cur)
                cur = ""
        else:
            cur += s
    if cur.byte_length() > 0:
        out.append(cur)
    return out^


def _strip_quotes(s: String) -> String:
    var t = String(s.strip())
    if t.byte_length() >= 2 and ((t.startswith("\"") and t.endswith("\"")) or (t.startswith("'") and t.endswith("'"))):
        return String(t[byte=1:t.byte_length() - 1])
    return t


def _looks_numeric(s: String) -> Bool:
    var t = _strip_quotes(s)
    if t.endswith("%"):
        var sub = String(t[byte=0:t.byte_length() - 1])
        t = sub
    if t.byte_length() == 0:
        return False
    var digits = 0
    for b in t.as_bytes():
        var c = Int(b)
        if c >= 48 and c <= 57:
            digits += 1
        elif c != 44 and c != 46:
            return False
    return digits > 0


def parse_kernel_profile(output: String) -> List[String]:
    """Extract a concise Top-GPU-Kernels summary from `nsys profile --stats=true`,
    `rocprofv3 --kernel-trace --stats` / `rocprof --stats`, or `compute-sanitizer`."""
    var stats = List[KernelStat]()
    var sanitizer_notes = List[String]()
    var in_nsys_kern = False
    var roc_hdr = List[String]()
    var roc_name_col = -1
    var roc_calls_col = -1
    var roc_dur_col = -1
    var roc_pct_col = -1

    for raw in output.split("\n"):
        var line = String(String(raw).strip())
        if line.byte_length() == 0:
            if in_nsys_kern and len(stats) > 0:
                in_nsys_kern = False
            continue
        if line.startswith("========="):
            var body = String(String(line[byte=9:]).strip())
            if body.startswith("ERROR SUMMARY:") or body.find("in kernel") >= 0 or body.startswith("Invalid ") or body.startswith("Race reported"):
                sanitizer_notes.append(body)
            continue
        var low = line.lower()
        # Detect nsys GPU kernel summary table header
        if low.find("time (%)") >= 0 and low.find("instances") >= 0 and low.find("name") >= 0:
            in_nsys_kern = True
            continue
        if in_nsys_kern:
            if line.startswith("---"):
                continue
            var toks = _ws_tokens(line)
            if len(toks) >= 4 and _looks_numeric(toks[0]) and _looks_numeric(toks[1]) and _looks_numeric(toks[2]):
                var pct = parse_int_or(toks[0].replace(",", ""), 0)
                var total_ns = toks[1] + " ns"
                var inst = toks[2]
                # Kernel name is the trailing non-numeric token(s) after the numeric stat columns
                var name_start = 3
                while name_start < len(toks) - 1 and _looks_numeric(toks[name_start]):
                    name_start += 1
                var kname = String("")
                for j in range(name_start, len(toks)):
                    kname += (" " if kname.byte_length() > 0 else "") + toks[j]
                stats.append(KernelStat(pct, total_ns, inst, _strip_quotes(kname)))
                continue
            else:
                in_nsys_kern = False

        # Detect rocprof / rocprofv3 CSV or pipe table
        if line.find(",") >= 0 and (low.find("kernel") >= 0 or low.find("name") >= 0) and (low.find("duration") >= 0 or low.find("totalduration") >= 0 or low.find("calls") >= 0):
            roc_hdr.clear()
            var cells = csv_cells(line)
            for j in range(len(cells)):
                var h = _strip_quotes(cells[j]).lower()
                roc_hdr.append(h)
                if h == "name" or h == "kernelname" or h == "kernel_name":
                    roc_name_col = j
                elif h == "calls" or h == "instances" or h == "dispatch_count":
                    roc_calls_col = j
                elif h.find("totalduration") >= 0 or h == "durationns" or h == "total_duration_ns" or h == "duration_ns":
                    roc_dur_col = j
                elif h.find("percent") >= 0 or h == "pct":
                    roc_pct_col = j
            continue
        if len(roc_hdr) > 0 and line.find(",") >= 0 and roc_name_col >= 0:
            var cells = csv_cells(line)
            if roc_name_col < len(cells):
                var kname = _strip_quotes(cells[roc_name_col])
                var calls = _strip_quotes(cells[roc_calls_col]) if roc_calls_col >= 0 and roc_calls_col < len(cells) else String("1")
                var dur = (_strip_quotes(cells[roc_dur_col]) + " ns") if roc_dur_col >= 0 and roc_dur_col < len(cells) else String("")
                var pct = parse_int_or(_strip_quotes(cells[roc_pct_col]), -1) if roc_pct_col >= 0 and roc_pct_col < len(cells) else -1
                if kname.byte_length() > 0 and _looks_numeric(calls):
                    stats.append(KernelStat(pct, dur, calls, kname))

    var out = List[String]()
    if len(stats) == 0 and len(sanitizer_notes) == 0:
        return out^
    out.append("=== GPU Kernel Profile Summary ===")
    if len(stats) > 0:
        for k in range(min(10, len(stats))):
            var st = stats[k].copy()
            var bar = gpu_bar(st.pct, 12) + " " + (String(st.pct) + "%" if st.pct >= 0 else String("n/a"))
            var meta = ("  " + st.time_txt) if st.time_txt.byte_length() > 0 else String("")
            if st.calls.byte_length() > 0:
                meta += "  (" + st.calls + "x)"
            out.append("  " + bar + meta + "  " + st.name)
    for note in sanitizer_notes:
        out.append("  [sanitizer] " + note)
    return out^


# ---------------------------------------------------------------------------
# Single-Kernel GPU Roofline Deep Dive (F09)
# ---------------------------------------------------------------------------

@fieldwise_init
struct GpuStallReason(Copyable, Movable):
    var reason: String
    var pct: Float64


@fieldwise_init
struct GpuRooflineData(Copyable, Movable):
    var kernel_name: String
    var sm_compute_pct: Float64
    var dram_bw_pct: Float64
    var occupancy_pct: Float64
    var registers_per_thread: Int
    var stalls: List[GpuStallReason]
    var bound_classification: String

    def __init__(out self, kernel_name: String):
        self.kernel_name = kernel_name
        self.sm_compute_pct = 0.0
        self.dram_bw_pct = -1.0  # -1.0 denotes N/A / not available
        self.occupancy_pct = 0.0
        self.registers_per_thread = 0
        self.stalls = List[GpuStallReason]()
        self.bound_classification = "Latency-Bound"


def classify_kernel_bound(sm_pct: Float64, dram_pct: Float64, occ_pct: Float64) -> String:
    """Classify kernel into Compute-Bound, Memory-Bound, or Latency-Bound."""
    _ = occ_pct
    if dram_pct < 0.0:
        return "Compute-Bound" if sm_pct > 30.0 else "Latency-Bound"
    if sm_pct < 30.0 and dram_pct < 30.0:
        return "Latency-Bound"
    if sm_pct >= dram_pct:
        return "Compute-Bound"
    return "Memory-Bound"


def parse_csv_cells(line: String) -> List[String]:
    """Parse a single CSV row into a list of unquoted cell strings."""
    var out = List[String]()
    var cur = List[UInt8]()
    var inside_quotes = False
    var b = line.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == 34:  # quote "
            inside_quotes = not inside_quotes
        elif c == 44 and not inside_quotes:  # comma ,
            out.append(String(bytes_to_str(cur).strip()))
            cur = List[UInt8]()
        else:
            cur.append(c)
    out.append(String(bytes_to_str(cur).strip()))
    return out^


def parse_float_val(tok: String) -> Float64:
    """Parse float from string, handling N/A as -1.0."""
    var s = String(tok.strip())
    if s == "N/A" or s == "n/a" or s.byte_length() == 0:
        return -1.0
    var dot = s.find(".")
    var neg = s.startswith("-")
    var start_idx = 1 if neg else 0
    var int_part: Float64 = 0.0
    var end_int = dot if dot >= 0 else s.byte_length()
    var b = s.as_bytes()
    for i in range(start_idx, end_int):
        if b[i] >= 48 and b[i] <= 57:
            int_part = int_part * 10.0 + Float64(Int(b[i]) - 48)
    var frac_part: Float64 = 0.0
    if dot >= 0:
        var div: Float64 = 10.0
        for i in range(dot + 1, s.byte_length()):
            if b[i] >= 48 and b[i] <= 57:
                frac_part += Float64(Int(b[i]) - 48) / div
                div *= 10.0
    var res = int_part + frac_part
    return -res if neg else res


def parse_int_val(tok: String) -> Int:
    var s = String(tok.strip())
    var val = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] >= 48 and b[i] <= 57:
            val = val * 10 + Int(b[i]) - 48
    return val


def format_stall_reason(metric_name: String) -> String:
    """Convert stall metric suffix to readable title."""
    if metric_name.find("long_scoreboard") >= 0:
        return "Long Scoreboard"
    elif metric_name.find("wait") >= 0:
        return "Wait"
    elif metric_name.find("barrier") >= 0:
        return "Barrier"
    elif metric_name.find("math_pipe_throttle") >= 0:
        return "Math Pipe Throttle"
    elif metric_name.find("short_scoreboard") >= 0:
        return "Short Scoreboard"
    return metric_name


def parse_rocprofv3_csv_output(csv_text: String) -> List[GpuRooflineData]:
    """Parse AMD rocprofv3 CSV format: KernelName, VALUUtilization, VRAMBandwidth, WavefrontOccupancy, VGPRs."""
    var out = List[GpuRooflineData]()
    var is_first = True
    for line_slice in csv_text.split("\n"):
        var raw_line = String(line_slice)
        var t = String(raw_line.strip())
        if t.byte_length() == 0:
            continue
        var cells = parse_csv_cells(t)
        if is_first:
            is_first = False
            continue
        if len(cells) >= 5:
            var name = cells[0]
            var valu = parse_float_val(cells[1])
            var vram = parse_float_val(cells[2])
            var occ = parse_float_val(cells[3])
            var vgpr = parse_int_val(cells[4])
            var item = GpuRooflineData(name)
            item.sm_compute_pct = valu
            item.dram_bw_pct = vram
            item.occupancy_pct = occ
            item.registers_per_thread = vgpr
            item.bound_classification = classify_kernel_bound(valu, vram, occ)
            out.append(item^)
    return out^


def parse_ncu_csv_output(csv_text: String) -> List[GpuRooflineData]:
    """Parse Nsight Compute (ncu) or AMD rocprofv3 CSV metrics."""
    if csv_text.find("VALUUtilization") >= 0 or csv_text.find("VRAMBandwidth") >= 0:
        return parse_rocprofv3_csv_output(csv_text)

    var out = List[GpuRooflineData]()
    var kernel_names = List[String]()

    for line_slice in csv_text.split("\n"):
        var raw_line = String(line_slice)
        var t = String(raw_line.strip())
        if t.byte_length() == 0 or t.startswith("ID") or t.startswith("\"ID\""):
            continue
        var cells = parse_csv_cells(t)
        if len(cells) < 4:
            continue
        var kname = cells[1]
        var metric_name = cells[2]
        var metric_val = cells[3]

        var kidx = -1
        for idx in range(len(kernel_names)):
            if kernel_names[idx] == kname:
                kidx = idx
                break
        if kidx < 0:
            kernel_names.append(kname)
            out.append(GpuRooflineData(kname))
            kidx = len(out) - 1

        if metric_name.find("sm__throughput") >= 0:
            out[kidx].sm_compute_pct = parse_float_val(metric_val)
        elif metric_name.find("gpu__dram_throughput") >= 0:
            out[kidx].dram_bw_pct = parse_float_val(metric_val)
        elif metric_name.find("sm__warps_active") >= 0:
            out[kidx].occupancy_pct = parse_float_val(metric_val)
        elif metric_name.find("launch__registers_per_thread") >= 0:
            out[kidx].registers_per_thread = parse_int_val(metric_val)
        elif metric_name.find("smsp__warp_issue_stalled_") >= 0:
            var pct = parse_float_val(metric_val)
            var reason = format_stall_reason(metric_name)
            out[kidx].stalls.append(GpuStallReason(reason, pct))

    for idx in range(len(out)):
        out[idx].bound_classification = classify_kernel_bound(
            out[idx].sm_compute_pct, out[idx].dram_bw_pct, out[idx].occupancy_pct
        )

    return out^


def parse_ncu_source_stall_lines(source_csv: String) -> List[Tuple[Int, String, Float64]]:
    """Parse ncu --page source CSV output attributing stalls to source lines."""
    var out = List[Tuple[Int, String, Float64]]()
    for line_slice in source_csv.split("\n"):
        var raw_line = String(line_slice)
        var t = String(raw_line.strip())
        if t.byte_length() == 0 or t.find("Source Line") >= 0 or t.find("Line") == 0:
            continue
        var cells = parse_csv_cells(t)
        if len(cells) >= 3:
            var line_no = parse_int_val(cells[0])
            var reason = cells[1]
            var count = parse_float_val(cells[2])
            out.append((line_no, reason, count))
    return out^


def filter_valid_source_stall_lines(stalls: List[Tuple[Int, String, Float64]], max_lines: Int) -> List[Tuple[Int, String, Float64]]:
    """Filter out line numbers outside the active buffer bounds."""
    var out = List[Tuple[Int, String, Float64]]()
    for s in stalls:
        var l = s[0]
        if l > 0 and l <= max_lines:
            out.append(s)
    return out^


def check_profiler_permissions(stderr: String) -> String:
    """Inspect profiler output for missing GPU hardware counter permissions."""
    if stderr.find("ERR_NVGPUCTRPERM") >= 0 or stderr.find("Permission denied to access GPU performance counters") >= 0:
        return "GPU profiling permission denied: set options nvidia NVreg_RestrictProfilingToAdminUsers=0 in /etc/modprobe.d/"
    return ""


def build_roofline_cli_command(tool: String, mojo_bin: String, src_path: String, out_exe: String, out_csv: String) -> String:
    """Build the deep-dive profiler CLI command."""
    var build_step = mojo_bin + " build -O3 --debug-level=line-tables " + shell_quote(src_path) + " -o " + shell_quote(out_exe)
    if tool == "rocprofv3":
        var run_step = "rocprofv3 --kernel-trace --stats " + shell_quote(out_exe) + " > " + shell_quote(out_csv)
        return build_step + " && " + run_step
    var ncu_step = "ncu --csv --set basic --page raw " + shell_quote(out_exe) + " > " + shell_quote(out_csv)
    return build_step + " && " + ncu_step


def _roofline_1dp(val: Float64) -> String:
    var neg = val < 0.0
    var v = -val if neg else val
    var i_part = Int(v)
    var frac = Int((v - Float64(i_part)) * 10.0 + 0.5)
    if frac >= 10:
        i_part += 1
        frac = 0
    return ("-" if neg else "") + String(i_part) + "." + String(frac)


def format_roofline_report(data: GpuRooflineData) -> List[String]:
    """Format a human-readable GPU kernel roofline summary block."""
    var out = List[String]()
    out.append("Kernel Roofline: " + data.kernel_name + "  [" + data.bound_classification + "]")
    out.append("  SM Compute:  " + gpu_bar(Int(data.sm_compute_pct + 0.5), 16) + " " + _roofline_1dp(data.sm_compute_pct) + "%")
    if data.dram_bw_pct >= 0.0:
        out.append("  DRAM BW:     " + gpu_bar(Int(data.dram_bw_pct + 0.5), 16) + " " + _roofline_1dp(data.dram_bw_pct) + "%")
    else:
        out.append("  DRAM BW:     [n/a] N/A (unified memory)")
    out.append("  Occupancy:   " + gpu_bar(Int(data.occupancy_pct + 0.5), 16) + " " + _roofline_1dp(data.occupancy_pct) + "%")
    if data.registers_per_thread > 0:
        out.append("  Registers:   " + String(data.registers_per_thread) + " regs/thread")
    if len(data.stalls) > 0:
        out.append("  Top Warp Stalls:")
        for st in data.stalls:
            out.append("    - " + st.reason + ": " + _roofline_1dp(st.pct) + "%")
    return out^
