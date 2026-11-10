"""Swap files: periodic copies of unsaved buffers, used to recover work after a crash,
a power cut or `kill -9`.

One file per modified buffer lives in the state directory. It starts with a small text
header and then holds the buffer exactly as it would be saved:

    TURBOMOJO-SWAP 1
    path: /abs/path/of/the/file        (empty for a buffer that was never saved)
    title: name shown in the window
    pid: 12345                         (the IDE process that owns the swap file)
    time: 2026-11-10 04:30:00
    ---
    <buffer bytes>

A swap file whose owner is still running belongs to another open IDE and is left alone."""
from std.ffi import external_call
from std.collections import List
from util import decode, to_str, slice_str, str_bytes, bytes_to_str, path_exists, run_capture, shell_quote, decode_list

comptime SWAP_MAGIC = "TURBOMOJO-SWAP 1"
comptime SWAP_SUFFIX = ".swp"
comptime SWAP_INTERVAL_MS = 2000


def swap_name(path: String, title: String, pid: Int, number: Int) -> String:
    """File name (not path) of the swap file for a buffer. A saved file maps to a name
    derived from its path, so the same file always uses the same swap file."""
    if path.byte_length() == 0:
        return "untitled-" + String(pid) + "-" + String(number) + SWAP_SUFFIX
    var out = List[Int]()
    for c in decode(path):
        if c == 47:
            out.append(37)          # '/' -> '%'
        elif c == 37:
            out.append(37)
            out.append(37)
        else:
            out.append(c)
    return to_str(out) + SWAP_SUFFIX


struct SwapInfo(Copyable, Movable):
    var ok: Bool
    var file: String        # path of the swap file itself
    var path: String        # file the buffer belongs to ('' if never saved)
    var title: String
    var pid: Int
    var time: String
    var content: List[UInt8]

    def __init__(out self):
        self.ok = False
        self.file = ""
        self.path = ""
        self.title = ""
        self.pid = 0
        self.time = ""
        self.content = List[UInt8]()


def swap_encode(path: String, title: String, pid: Int, time: String, content: List[UInt8]) -> List[UInt8]:
    var out = str_bytes(
        String(SWAP_MAGIC) + "\npath: " + path + "\ntitle: " + title + "\npid: " + String(pid) + "\ntime: " + time + "\n---\n"
    )
    for b in content:
        out.append(b)
    return out^


def swap_decode(data: List[UInt8]) -> SwapInfo:
    """Parse swap file bytes. `ok` is False for anything that is not a complete swap file."""
    var info = SwapInfo()
    var n = len(data)
    var pos = 0
    var line_no = 0
    while pos < n:
        var e = pos
        while e < n and data[e] != 10:
            e += 1
        if e >= n:
            return info^            # header not terminated
        var raw = List[UInt8]()
        for k in range(pos, e):
            raw.append(data[k])
        var line = bytes_to_str(raw)
        pos = e + 1
        if line_no == 0:
            if line != SWAP_MAGIC:
                return info^
        elif line == "---":
            for k in range(pos, n):
                info.content.append(data[k])
            info.ok = info.pid > 0
            return info^
        elif line.startswith("path: "):
            info.path = after(line, 6)
        elif line.startswith("title: "):
            info.title = after(line, 7)
        elif line.startswith("pid: "):
            try:
                info.pid = atol(after(line, 5))
            except:
                info.pid = 0
        elif line.startswith("time: "):
            info.time = after(line, 6)
        line_no += 1
        if line_no > 16:
            return info^
    return info^


def after(line: String, n: Int) -> String:
    var c = decode(line)
    return slice_str(c, n, len(c))


def read_bytes(path: String) -> List[UInt8]:
    """Whole file as bytes (empty if it cannot be read)."""
    var out = List[UInt8]()
    var p = String(path)
    var mode = String("rb")
    var fp = external_call["fopen", Int](p.as_c_string_span(), mode.as_c_string_span())
    if fp == 0:
        return out^
    var chunk = List[UInt8](length=65536, fill=0)
    while True:
        var n = external_call["fread", Int](chunk.unsafe_ptr(), Int(1), Int(65536), fp)
        if n <= 0:
            break
        for i in range(n):
            out.append(chunk[i])
    _ = external_call["fclose", Int32](fp)
    return out^


def write_bytes_atomic(path: String, data: List[UInt8]) -> Bool:
    """Write to a temporary file and rename it into place, so a crash while writing never
    leaves a half-written file under the real name."""
    var tmp = path + ".tmp"
    var t = String(tmp)
    var mode = String("wb")
    var fp = external_call["fopen", Int](t.as_c_string_span(), mode.as_c_string_span())
    if fp == 0:
        return False
    var n = len(data)
    var written = n
    if n > 0:
        written = external_call["fwrite", Int](data.unsafe_ptr(), Int(1), n, fp)
    var closed = Int(external_call["fclose", Int32](fp))
    if written != n or closed != 0:
        delete_file(tmp)
        return False
    var dst = String(path)
    return Int(external_call["rename", Int32](t.as_c_string_span(), dst.as_c_string_span())) == 0


def delete_file(path: String):
    var p = String(path)
    _ = external_call["unlink", Int32](p.as_c_string_span())


def pid_alive(pid: Int) -> Bool:
    """True if a process with this id exists (signal 0 only checks, it sends nothing)."""
    if pid <= 0:
        return False
    return Int(external_call["kill", Int32](Int32(pid), Int32(0))) == 0


def list_swap_files(dir: String) -> List[String]:
    """Paths of the *.swp files in a directory."""
    var out = List[String]()
    if not path_exists(dir):
        return out^
    var r = run_capture("ls -1A " + shell_quote(dir) + " 2>/dev/null")
    var cur = List[Int]()
    var all = decode_list(r.out)
    all.append(10)
    for c in all:
        if c == 10:
            var name = to_str(cur)
            cur.clear()
            if name.endswith(SWAP_SUFFIX):
                out.append(dir + "/" + name)
        else:
            cur.append(c)
    return out^
