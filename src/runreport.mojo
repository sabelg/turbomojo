"""After Ctrl-F9 (P11-10b): one line in the Message window with how the run ended, how
long it took and, for a program that uses the GPU, which GPU it ran on.

The time is the whole of `mojo run` - compiling included, as Mojo compiles before it
runs. The GPU is the one the driver gives a program first: the first GPU nvidia-smi or
rocm-smi lists, or the one CUDA_VISIBLE_DEVICES / HIP_VISIBLE_DEVICES names first. A
program "uses the GPU" when its source imports the `gpu` package or MAX, or makes a
DeviceContext - TurboMojo does not watch the driver while it runs."""
from std.collections import List
from gpuinfo import GpuInfo


def names_module(line: String, prefix: String, module: String) -> Bool:
    """`line` is "from <module>..." / "import <module>..." for this module or one of its
    submodules ("from gpu.host", not "from gpuinfo")."""
    var head = prefix + module
    if not line.startswith(head):
        return False
    if line.byte_length() == head.byte_length():
        return True
    var c = Int(line.as_bytes()[head.byte_length()])
    return c == 32 or c == 46 or c == 44 or c == 9      # a space, ".", "," or a tab


def uses_gpu(source: String) -> Bool:
    """Does this program use the GPU (its imports or a DeviceContext)?"""
    for raw in source.split("\n"):
        var l = String(String(raw).strip())
        if l.startswith("#"):
            continue
        for m in ["gpu", "max"]:
            if names_module(l, "from ", String(m)) or names_module(l, "import ", String(m)):
                return True
        if l.find("DeviceContext") >= 0:
            return True
    return False


def visible_gpu_index(cuda: String, hip: String) -> Int:
    """Which listed GPU a program gets first: 0, or the first number in
    CUDA_VISIBLE_DEVICES (else HIP_VISIBLE_DEVICES); -1 when they hide every GPU or name
    one in another way (a UUID)."""
    var v = String(cuda.strip())
    if v.byte_length() == 0:
        v = String(hip.strip())
    if v.byte_length() == 0:
        return 0
    var first = String(String(v.split(",")[0]).strip())
    if first.byte_length() == 0:
        return -1
    var n = 0
    for b in first.as_bytes():
        var c = Int(b)
        if c < 48 or c > 57:
            return -1
        n = n * 10 + c - 48
    return n


def run_gpu_name(gpus: List[GpuInfo], index: Int) -> String:
    """The GPU's name for the line ("" when it is not known)."""
    if index < 0 or index >= len(gpus):
        return ""
    return gpus[index].name


def duration_text(ns: Int) -> String:
    """"430 ms", "2.3 s", "1 min 12 s"."""
    var ms = ns // 1000000
    if ms < 1000:
        return String(ms) + " ms"
    if ms < 60000:
        var tenths = ms // 100
        return String(tenths // 10) + "." + String(tenths % 10) + " s"
    var s = ms // 1000
    return String(s // 60) + " min " + String(s % 60) + " s"


def run_summary(label: String, status: Int, ns: Int, wants_gpu: Bool, gpu: String) -> String:
    """The line: "mojo run hello.mojo: ended with status 0 after 2.3 s (compiling
    included), on the GPU NVIDIA GB10"."""
    var s = label + ": ended with status " + String(status) + " after " + duration_text(ns) + " (compiling included)"
    if wants_gpu:
        if gpu.byte_length() > 0:
            s += ", on the GPU " + gpu
        else:
            s += "; it uses the GPU, but which one is not known (no nvidia-smi or rocm-smi answer)"
    return s
