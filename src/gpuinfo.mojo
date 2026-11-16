"""Which GPU will the program run on? (P11-10a) Mojo programs that use a GPU take the
first one the driver lists (CUDA_VISIBLE_DEVICES / HIP_VISIBLE_DEVICES change which),
so TurboMojo asks the vendor's tool once - nvidia-smi for NVIDIA, rocm-smi for AMD -
and shows the answer in `tmide --caps` and, when `ui.gpu_status` is on, on the status
line. The question runs in the background (it can take a second on a busy server).

This module has the command and reads its output; the IDE runs it (app_gpu.mojo)."""
from std.collections import List
from util import bytes_to_str, shell_quote

# one shell command for every machine: the first line says which tool answered
comptime GPU_QUERY = "if command -v nvidia-smi >/dev/null 2>&1; then echo nvidia; nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null; elif command -v rocm-smi >/dev/null 2>&1; then echo rocm; rocm-smi --showproductname --csv 2>/dev/null; elif [ \"$(uname -s)\" = \"Darwin\" ]; then echo metal; system_profiler SPDisplaysDataType 2>/dev/null; sysctl -n hw.memsize 2>/dev/null || true; else echo none; fi"


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


@fieldwise_init
struct _MetalEntry(Copyable, Movable):
    var chipset: String
    var cores: String
    var metal_ver: String


def _parse_uint_exact(text: String) -> Int:
    var t = String(text.strip())
    if t.byte_length() == 0:
        return -1
    var n = 0
    for b in t.as_bytes():
        var c = Int(b)
        if c < 48 or c > 57:
            return -1
        n = n * 10 + (c - 48)
    return n


def _parse_metal_lines(lines: List[String]) -> Tuple[List[_MetalEntry], Int]:
    var entries = List[_MetalEntry]()
    var mem_bytes = -1
    var cur_chipset = String("")
    var cur_cores = String("")
    var cur_metal = String("")
    for k in range(1, len(lines)):
        var ln = lines[k]
        if ln.startswith("Chipset Model:"):
            if cur_chipset.byte_length() > 0:
                entries.append(_MetalEntry(cur_chipset, cur_cores, cur_metal))
                cur_cores = ""
                cur_metal = ""
            cur_chipset = String(String(ln[byte=14:]).strip())
        elif ln.startswith("Total Number of Cores:"):
            cur_cores = String(String(ln[byte=22:]).strip())
        elif ln.startswith("Metal Support:"):
            cur_metal = String(String(ln[byte=14:]).strip())
        elif ln.startswith("Metal Family:") and cur_metal.byte_length() == 0:
            cur_metal = String(String(ln[byte=13:]).strip())
        elif ln.find(":") < 0 and ln.byte_length() >= 7:
            var mb = _parse_uint_exact(ln)
            if mb >= 1048576:
                mem_bytes = mb
    if cur_chipset.byte_length() > 0:
        entries.append(_MetalEntry(cur_chipset, cur_cores, cur_metal))
    return (entries^, mem_bytes)


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
    elif lines[0] == "metal":
        var parsed_metal = _parse_metal_lines(lines)
        var mem_txt = String("")
        if parsed_metal[1] > 0:
            var gib = (parsed_metal[1] + 536870912) // 1073741824
            mem_txt = String(gib) + " GiB unified"
        for i in range(len(parsed_metal[0])):
            var e = parsed_metal[0][i].copy()
            var drv = String("")
            if e.metal_ver.byte_length() > 0 and e.cores.byte_length() > 0:
                drv = e.metal_ver + " (" + e.cores + " cores)"
            elif e.metal_ver.byte_length() > 0:
                drv = e.metal_ver
            elif e.cores.byte_length() > 0:
                drv = e.cores + " cores"
            gpus.append(GpuInfo(e.chipset, mem_txt, drv))
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
    """For the status line: "GPU GB10", "GPU H100 80GB HBM3 ×8", "GPU M3 Max"; "" with none."""
    if len(gpus) == 0:
        return ""
    var name = gpus[0].name
    for p in ["NVIDIA ", "AMD ", "Radeon ", "Apple "]:
        if name.startswith(String(p)):
            var rest = String(name[byte=String(p).byte_length():])
            name = rest
    var s = "GPU " + name
    if len(gpus) > 1:
        s += " ×" + String(len(gpus))
    return s


comptime GPU_TELEMETRY_QUERY = "if command -v nvidia-smi >/dev/null 2>&1; then echo nvidia; nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null; echo __PROCS__; nvidia-smi --query-compute-apps=gpu_bus_id,pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null || true; elif command -v rocm-smi >/dev/null 2>&1; then echo rocm; rocm-smi --showuse --showmeminfo vram --showtemp --showpower --csv 2>/dev/null; elif [ \"$(uname -s)\" = \"Darwin\" ]; then echo metal; system_profiler SPDisplaysDataType 2>/dev/null; sysctl -n hw.memsize 2>/dev/null || true; else echo none; fi"


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
    elif lines[0] == "metal":
        var parsed_metal = _parse_metal_lines(lines)
        var total_mib = (parsed_metal[1] // (1024 * 1024)) if parsed_metal[1] > 0 else -1
        for i in range(len(parsed_metal[0])):
            var e = parsed_metal[0][i].copy()
            var extra = String("")
            if e.cores.byte_length() > 0 and e.metal_ver.byte_length() > 0:
                extra = " (" + e.cores + " cores, " + e.metal_ver + ")"
            elif e.cores.byte_length() > 0:
                extra = " (" + e.cores + " cores)"
            elif e.metal_ver.byte_length() > 0:
                extra = " (" + e.metal_ver + ")"
            samples.append(GpuSample(i, e.chipset + extra, -1, -1, total_mib, -1, ""))
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
        elif s.mem_total_mib > 0:
            out.append("  VRAM:    unified / shared host memory (" + String((s.mem_total_mib + 512) // 1024) + " GiB unified)")
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


# ---------------------------------------------------------------------------
# Multi-GPU Topology, Slurm Queue & Container Slice (Phase 19)
# ---------------------------------------------------------------------------

comptime GPU_CLUSTER_QUERY = "echo __TOPO__; if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi topo -m 2>/dev/null || true; fi; echo __SQUEUE__; if command -v squeue >/dev/null 2>&1; then squeue --me -o \"%.10i %.12P %.18j %.8T %.10M %.6D %R\" 2>/dev/null || true; fi; echo __CGROUP__; if [ -r /sys/fs/cgroup/memory.max ] && [ -r /sys/fs/cgroup/memory.current ]; then mx=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max); if [ \"$mx\" != \"max\" ] && [ -n \"$mx\" ]; then cat /sys/fs/cgroup/memory.current 2>/dev/null || true; echo \"$mx\"; fi; fi"


@fieldwise_init
struct SlurmJobRow(Copyable, Movable):
    var job_id: String
    var partition: String
    var name: String
    var state: String
    var elapsed: String
    var nodes: String
    var nodelist: String


def _strip_ansi_text(s: String) -> String:
    if s.find("\x1b") < 0:
        return s
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    var n = len(b)
    while i < n:
        if Int(b[i]) == 27 and i + 1 < n and Int(b[i + 1]) == 91:
            i += 2
            while i < n and not (Int(b[i]) >= 64 and Int(b[i]) <= 126):
                i += 1
            i += 1
            continue
        out.append(b[i])
        i += 1
    return bytes_to_str(out)


def _pad_cell(s: String, w: Int) -> String:
    var out = s
    var cur = s.byte_length()
    while cur < w:
        out += " "
        cur += 1
    return out


def _is_gpu_col_token(tok: String) -> Bool:
    if not tok.startswith("GPU") or tok.byte_length() < 4:
        return False
    var tail = String(tok[byte=3:])
    return _parse_uint_exact(tail) >= 0


def _is_pcie_hop(cell: String) -> Bool:
    return cell == "PIX" or cell == "PXB" or cell == "PHB" or cell == "NODE" or cell == "SYS"


def parse_nvidia_topo_matrix(raw: String) -> List[String]:
    """Parse `nvidia-smi topo -m` output into aligned GPU-to-GPU interconnect rows and a
    summary highlighting NVLink (`NV12`, `NV18`, `NV4`) vs PCIe (`PIX`, `PHB`, `SYS`)."""
    var out = List[String]()
    var gpu_cols = List[String]()
    var matrix_rows = List[String]()
    var nv_links = List[String]()
    var pcie_links = List[String]()

    for raw_ln in raw.split("\n"):
        var clean = String(_strip_ansi_text(String(raw_ln)).strip())
        if clean.byte_length() == 0 or clean == "__TOPO__":
            continue
        if clean.startswith("Legend:"):
            break
        var toks = _ws_tokens(clean)
        if len(toks) == 0:
            continue
        if len(gpu_cols) == 0:
            var found_hdr = False
            for t in toks:
                if _is_gpu_col_token(t):
                    gpu_cols.append(t)
                    found_hdr = True
                elif found_hdr:
                    break
            continue
        if _is_gpu_col_token(toks[0]):
            var ngpu = len(gpu_cols)
            var row_txt = "  " + _pad_cell(toks[0], 7)
            var limit = min(len(toks) - 1, ngpu)
            for j in range(limit):
                var cell = toks[j + 1]
                row_txt += _pad_cell(cell, 7)
                if cell.startswith("NV") and cell != "N/A":
                    if not (cell in nv_links):
                        nv_links.append(cell)
                elif _is_pcie_hop(cell):
                    if not (cell in pcie_links):
                        pcie_links.append(cell)
            matrix_rows.append(String(row_txt.rstrip()))

    if len(gpu_cols) == 0 or len(matrix_rows) == 0:
        return out^

    var hdr_txt = "  " + _pad_cell("", 7)
    for g in gpu_cols:
        hdr_txt += _pad_cell(g, 7)
    out.append(String(hdr_txt.rstrip()))
    for r in matrix_rows:
        out.append(r)

    if len(nv_links) > 0 and len(pcie_links) == 0:
        out.append("  Interconnect: NVLink (" + ", ".join(nv_links) + ") — direct peer-to-peer mesh")
    elif len(nv_links) > 0 and len(pcie_links) > 0:
        out.append("  Interconnect: Hybrid NVLink (" + ", ".join(nv_links) + ") + PCIe (" + ", ".join(pcie_links) + ")")
    elif len(pcie_links) > 0:
        out.append("  Interconnect: PCIe (" + ", ".join(pcie_links) + ") — no NVLink bridge")
    else:
        out.append("  Interconnect: Single GPU (X)")
    return out^


def parse_squeue_rows(raw: String) -> List[SlurmJobRow]:
    """Parse `squeue` tabular output into `SlurmJobRow` items."""
    var out = List[SlurmJobRow]()
    for raw_ln in raw.split("\n"):
        var ln = String(String(raw_ln).strip())
        if ln.byte_length() == 0 or ln == "__SQUEUE__":
            continue
        var toks = _ws_tokens(ln)
        if len(toks) < 6:
            continue
        if toks[0].upper() == "JOBID":
            continue
        var tail = String("")
        for j in range(6, len(toks)):
            tail += (" " if tail.byte_length() > 0 else String("")) + toks[j]
        out.append(
            SlurmJobRow(
                toks[0],
                toks[1],
                toks[2],
                toks[3],
                toks[4],
                toks[5],
                tail,
            )
        )
    return out^


def parse_cgroup_memory_slice(mem_current: String, mem_max: String) -> String:
    """Format container cgroup v2 memory slice (`Container RAM: 12.4 / 64.0 GiB (19%)`),
    or return `""` when `mem_max` is `"max"` / unlimited / bare-metal."""
    var cur_s = String(mem_current.strip())
    var max_s = String(mem_max.strip())
    if cur_s.byte_length() == 0 or max_s.byte_length() == 0 or max_s.lower() == "max":
        return ""
    var cur_b = _parse_uint_exact(cur_s)
    var max_b = _parse_uint_exact(max_s)
    # 1 << 58 (~256 PiB) guards against kernel unlimited-memory sentinel values
    if cur_b < 0 or max_b <= 0 or max_b >= (1 << 58):
        return ""
    var gib_unit: Float64 = 1073741824.0
    var cur_gib = Float64(cur_b) / gib_unit
    var max_gib = Float64(max_b) / gib_unit
    var pct = (cur_b * 100) // max_b
    return "Container RAM: " + _roofline_1dp(cur_gib) + " / " + _roofline_1dp(max_gib) + " GiB (" + String(pct) + "%)"


def parse_cluster_query_sections(raw: String) -> Tuple[String, String, String, String]:
    """Split `GPU_CLUSTER_QUERY` output into `(topo_raw, squeue_raw, cgroup_cur, cgroup_max)`."""
    var section = 0
    var topo_lines = List[String]()
    var sq_lines = List[String]()
    var cg_lines = List[String]()
    for raw_ln in raw.split("\n"):
        var ln = String(raw_ln)
        var st = String(ln.strip())
        if st == "__TOPO__":
            section = 1
            continue
        if st == "__SQUEUE__":
            section = 2
            continue
        if st == "__CGROUP__":
            section = 3
            continue
        if section == 1:
            topo_lines.append(ln)
        elif section == 2:
            sq_lines.append(ln)
        elif section == 3 and st.byte_length() > 0:
            cg_lines.append(st)
    var cg_cur = cg_lines[0] if len(cg_lines) >= 2 else String("")
    var cg_max = cg_lines[1] if len(cg_lines) >= 2 else String("")
    return ("\n".join(topo_lines), "\n".join(sq_lines), cg_cur, cg_max)


def format_cluster_topology_section(
    topo_raw: String,
    squeue_raw: String,
    cgroup_cur: String,
    cgroup_max: String,
) -> List[String]:
    """Format a multi-line cluster/topology/container report block for `WK_GPU`."""
    var out = List[String]()
    var cg = parse_cgroup_memory_slice(cgroup_cur, cgroup_max)
    var topo = parse_nvidia_topo_matrix(topo_raw)
    var jobs = parse_squeue_rows(squeue_raw)

    if cg.byte_length() == 0 and len(topo) == 0 and len(jobs) == 0:
        return out^

    if cg.byte_length() > 0:
        out.append("Container Slice")
        out.append("  " + cg)

    if len(topo) > 0:
        if len(out) > 0:
            out.append("")
        out.append("Multi-GPU Topology")
        for ln in topo:
            out.append(ln)

    if len(jobs) > 0:
        if len(out) > 0:
            out.append("")
        out.append("Slurm Queue (" + String(len(jobs)) + (" job)" if len(jobs) == 1 else " jobs)"))
        for j in jobs:
            out.append(
                "  #" + j.job_id + "  " + j.name + "  [" + j.state + "]  "
                + j.partition + "  " + j.elapsed + "  " + j.nodes + "n  " + j.nodelist
            )
    return out^
