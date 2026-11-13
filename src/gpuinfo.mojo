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
