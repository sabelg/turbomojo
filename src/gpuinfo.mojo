"""Which GPU will the program run on? (P11-10a) Mojo programs that use a GPU take the
first one the driver lists (CUDA_VISIBLE_DEVICES / HIP_VISIBLE_DEVICES change which),
so TurboMojo asks the vendor's tool once - nvidia-smi for NVIDIA, rocm-smi for AMD -
and shows the answer in `tmide --caps` and, when `ui.gpu_status` is on, on the status
line. The question runs in the background (it can take a second on a busy server).

This module has the command and reads its output; the IDE runs it (app_gpu.mojo)."""
from std.collections import List

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
    if unknown(t):
        return fallback
    var dot = t.find(".")
    if dot >= 0:
        var t_dot = String(t[byte=0:dot])
        t = t_dot
    var pct = t.find("%")
    if pct >= 0:
        var t_pct = String(t[byte=0:pct])
        t = t_pct
    var t_clean = String(t.strip())
    t = t_clean
    if t.byte_length() == 0:
        return fallback
    var n = 0
    for b in t.as_bytes():
        var c = Int(b)
        if c < 48 or c > 57:
            return fallback
        n = n * 10 + c - 48
    return n


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
                    var mem_note = ("  " + c[3] + " MiB") if (len(c) > 3 and not unknown(c[3])) else String("")
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
            meta += ("  ·  " if meta.byte_length() > 0 else String("")) + "Power " + s.power_w + " W"
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
