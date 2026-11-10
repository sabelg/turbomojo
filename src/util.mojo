"""Small helpers: UTF-8 codecs, byte buffers, processes and the filesystem."""
from std.ffi import external_call
from std.collections import List


def decode_list(b: List[UInt8]) -> List[Int]:
    """Decode UTF-8 bytes into codepoints (invalid bytes become U+FFFD)."""
    var out = List[Int]()
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            out.append(c)
            i += 1
        elif c >= 0xF0 and c < 0xF8 and i + 3 < n:
            out.append(
                ((c & 0x07) << 18)
                | ((Int(b[i + 1]) & 0x3F) << 12)
                | ((Int(b[i + 2]) & 0x3F) << 6)
                | (Int(b[i + 3]) & 0x3F)
            )
            i += 4
        elif c >= 0xE0 and c < 0xF0 and i + 2 < n:
            out.append(
                ((c & 0x0F) << 12)
                | ((Int(b[i + 1]) & 0x3F) << 6)
                | (Int(b[i + 2]) & 0x3F)
            )
            i += 3
        elif c >= 0xC0 and c < 0xE0 and i + 1 < n:
            out.append(((c & 0x1F) << 6) | (Int(b[i + 1]) & 0x3F))
            i += 2
        else:
            out.append(0xFFFD)
            i += 1
    return out^


def str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def decode(s: String) -> List[Int]:
    return decode_list(str_bytes(s))


def encode_cp(cp: Int, mut out: List[UInt8]):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | ((cp >> 18) & 0x07)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def bytes_to_str(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def to_str(cps: List[Int]) -> String:
    var b = List[UInt8]()
    for c in cps:
        encode_cp(c, b)
    return bytes_to_str(b)


def slice_str(cps: List[Int], a: Int, b: Int) -> String:
    var out = List[UInt8]()
    var lo = max(0, a)
    var hi = min(len(cps), b)
    for i in range(lo, hi):
        encode_cp(cps[i], out)
    return bytes_to_str(out)


def append_str(mut out: List[UInt8], s: String):
    for b in s.as_bytes():
        out.append(b)


def append_int(mut out: List[UInt8], v: Int):
    append_str(out, String(v))


def in_ranges(cp: Int, r: List[Int]) -> Bool:
    var i = 0
    while i + 1 < len(r):
        if cp < r[i]:
            return False
        if cp <= r[i + 1]:
            return True
        i += 2
    return False


def char_width(cp: Int) -> Int:
    """Terminal column width of a codepoint: 0 (combining), 1 or 2 (wide/emoji)."""
    if cp < 0x300:
        return 1
    if cp <= 0x36F:
        return 0
    if cp < 0x1100:
        if (cp >= 0x483 and cp <= 0x489) or (cp >= 0x591 and cp <= 0x5BD) or (cp >= 0x610 and cp <= 0x61A) or (cp >= 0x64B and cp <= 0x65F) or (cp >= 0x900 and cp <= 0x903) or (cp >= 0x93A and cp <= 0x94F):
            return 0
        return 1
    # zero width: ZW space/joiners, variation selectors, combining blocks
    if (cp >= 0x200B and cp <= 0x200F) or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x20D0 and cp <= 0x20FF) or (cp >= 0xFE20 and cp <= 0xFE2F) or (cp >= 0xE0100 and cp <= 0xE01EF):
        return 0
    if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0x3041 and cp <= 0x33FF) or (cp >= 0x1F600 and cp <= 0x1F64F):
        return 2
    if cp < 0x2300 or (cp >= 0x2C00 and cp < 0x2E80) or (cp >= 0xA4D0 and cp < 0xA960) or (cp >= 0xD7A4 and cp < 0xF900):
        return 1
    var wide: List[Int] = [
        0x1100, 0x115F, 0x231A, 0x231B, 0x2329, 0x232A, 0x23E9, 0x23EC, 0x23F0, 0x23F0, 0x23F3, 0x23F3,
        0x25FD, 0x25FE, 0x2614, 0x2615, 0x2648, 0x2653, 0x267F, 0x267F, 0x2693, 0x2693, 0x26A1, 0x26A1,
        0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26CE, 0x26D4, 0x26D4, 0x26EA, 0x26EA,
        0x26F2, 0x26F3, 0x26F5, 0x26F5, 0x26FA, 0x26FA, 0x26FD, 0x26FD, 0x2705, 0x2705, 0x270A, 0x270B,
        0x2728, 0x2728, 0x274C, 0x274C, 0x274E, 0x274E, 0x2753, 0x2755, 0x2757, 0x2757, 0x2795, 0x2797,
        0x27B0, 0x27B0, 0x27BF, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B50, 0x2B55, 0x2B55,
        0x2E80, 0x303E, 0x3041, 0x33FF, 0x3400, 0x4DBF, 0x4E00, 0x9FFF, 0xA000, 0xA4CF, 0xA960, 0xA97F,
        0xAC00, 0xD7A3, 0xF900, 0xFAFF, 0xFE10, 0xFE19, 0xFE30, 0xFE6F, 0xFF00, 0xFF60, 0xFFE0, 0xFFE6,
        0x16FE0, 0x16FE4, 0x17000, 0x18CFF, 0x1B000, 0x1B2FF, 0x1F004, 0x1F004, 0x1F0CF, 0x1F0CF,
        0x1F18E, 0x1F18E, 0x1F191, 0x1F19A, 0x1F200, 0x1F2FF, 0x1F300, 0x1F320, 0x1F32D, 0x1F335,
        0x1F337, 0x1F37C, 0x1F37E, 0x1F393, 0x1F3A0, 0x1F3CA, 0x1F3CF, 0x1F3D3, 0x1F3E0, 0x1F3F0,
        0x1F3F4, 0x1F3F4, 0x1F3F8, 0x1F43E, 0x1F440, 0x1F440, 0x1F442, 0x1F4FC, 0x1F4FF, 0x1F53D,
        0x1F54B, 0x1F54E, 0x1F550, 0x1F567, 0x1F57A, 0x1F57A, 0x1F595, 0x1F596, 0x1F5A4, 0x1F5A4,
        0x1F5FB, 0x1F64F, 0x1F680, 0x1F6C5, 0x1F6CC, 0x1F6CC, 0x1F6D0, 0x1F6D2, 0x1F6D5, 0x1F6D7,
        0x1F6DC, 0x1F6DF, 0x1F6EB, 0x1F6EC, 0x1F6F4, 0x1F6FC, 0x1F7E0, 0x1F7EB, 0x1F7F0, 0x1F7F0,
        0x1F90C, 0x1F93A, 0x1F93C, 0x1F945, 0x1F947, 0x1F9FF, 0x1FA70, 0x1FAFF, 0x20000, 0x2FFFD,
        0x30000, 0x3FFFD,
    ]
    if in_ranges(cp, wide):
        return 2
    return 1


def str_width(cps: List[Int]) -> Int:
    var w = 0
    for c in cps:
        w += char_width(c)
    return w


def cp_len(s: String) -> Int:
    """Display width (terminal columns) of a string."""
    return str_width(decode(s))


def pad_right(s: String, w: Int) -> String:
    """Pad or truncate to exactly `w` display columns."""
    var cps = decode(s)
    var out = List[Int]()
    var n = 0
    for c in cps:
        var cw = char_width(c)
        if n + cw > w:
            break
        out.append(c)
        n += cw
    while n < w:
        out.append(32)
        n += 1
    return to_str(out)


def is_digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def is_alpha(c: Int) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 0xC0


def is_ident(c: Int) -> Bool:
    return is_alpha(c) or is_digit(c)


def lower(c: Int) -> Int:
    if c >= 65 and c <= 90:
        return c + 32
    return c


def lower_str(s: String) -> String:
    var cps = decode(s)
    for i in range(len(cps)):
        cps[i] = lower(cps[i])
    return to_str(cps)


def lower_to_upper(s: String) -> String:
    var cps = decode(s)
    for i in range(len(cps)):
        if cps[i] >= 97 and cps[i] <= 122:
            cps[i] -= 32
    return to_str(cps)


def str_contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def fuzzy_score(text: String, pattern: String) -> Int:
    """Return -1 when pattern is not a (case-insensitive) subsequence of text.
    Higher score = better: contiguous substrings and early matches win."""
    if pattern.byte_length() == 0:
        return 1
    var t = lower_str(text)
    var p = lower_str(pattern)
    var pos = t.find(p)
    if pos >= 0:
        return 1000 - pos
    var tc = decode(t)
    var pc = decode(p)
    var j = 0
    var score = 500
    var last = -1
    for i in range(len(tc)):
        if j < len(pc) and tc[i] == pc[j]:
            if last >= 0 and i - last > 1:
                score -= i - last
            last = i
            j += 1
    if j < len(pc):
        return -1
    return max(score, 2)


def shell_quote(s: String) -> String:
    var out = String("'")
    for cp in decode(s):
        if cp == 39:
            out += "'\\''"
        else:
            var b = List[UInt8]()
            encode_cp(cp, b)
            out += bytes_to_str(b)
    out += "'"
    return out


def strip_ansi(line: List[Int]) -> List[Int]:
    var out = List[Int]()
    var i = 0
    var n = len(line)
    while i < n:
        if line[i] == 27 and i + 1 < n and line[i + 1] == 91:
            i += 2
            while i < n and not (line[i] >= 0x40 and line[i] <= 0x7E):
                i += 1
            i += 1
            continue
        if line[i] == 13:
            i += 1
            continue
        out.append(line[i])
        i += 1
    return out^


struct CmdResult(Movable):
    var out: List[UInt8]
    var status: Int

    def __init__(out self, var out_bytes: List[UInt8], status: Int):
        self.out = out_bytes^
        self.status = status


def run_capture(cmd: String) -> CmdResult:
    """Run a shell command, capturing stdout (callers add 2>&1)."""
    var c = String(cmd)
    var mode = String("r")
    var fp = external_call["popen", Int](c.as_c_string_span(), mode.as_c_string_span())
    var data = List[UInt8]()
    if fp == 0:
        append_str(data, "failed to start: " + cmd)
        return CmdResult(data^, -1)
    var chunk = List[UInt8](length=8192, fill=0)
    while True:
        var n = external_call["fread", Int](chunk.unsafe_ptr(), Int(1), Int(8192), fp)
        if n <= 0:
            break
        for i in range(n):
            data.append(chunk[i])
    var st = Int(external_call["pclose", Int32](fp))
    return CmdResult(data^, st)


def run_system(cmd: String) -> Int:
    var c = String(cmd)
    return Int(external_call["system", Int32](c.as_c_string_span()))


def getcwd() -> String:
    var buf = List[UInt8](length=4096, fill=0)
    _ = external_call["getcwd", Int](buf.unsafe_ptr(), Int(4096))
    var out = List[UInt8]()
    var i = 0
    while i < 4096 and buf[i] != 0:
        out.append(buf[i])
        i += 1
    return bytes_to_str(out)


def path_exists(path: String) -> Bool:
    var p = String(path)
    return Int(external_call["access", Int32](p.as_c_string_span(), Int32(0))) == 0


def is_dir(path: String) -> Bool:
    return path_exists(path + "/.")


def join_path(dir: String, name: String) -> String:
    if name.startswith("/"):
        return name
    if dir.byte_length() == 0:
        return name
    if dir.endswith("/"):
        return dir + name
    return dir + "/" + name


def dirname(path: String) -> String:
    var cps = decode(path)
    var i = len(cps) - 1
    while i >= 0 and cps[i] != 47:
        i -= 1
    if i < 0:
        return "."
    if i == 0:
        return "/"
    return slice_str(cps, 0, i)


def basename(path: String) -> String:
    var cps = decode(path)
    var i = len(cps) - 1
    while i >= 0 and cps[i] != 47:
        i -= 1
    return slice_str(cps, i + 1, len(cps))


def stem(path: String) -> String:
    var b = basename(path)
    var cps = decode(b)
    var i = len(cps) - 1
    while i > 0 and cps[i] != 46:
        i -= 1
    if i <= 0:
        return b
    return slice_str(cps, 0, i)


def normalize_path(path: String) -> String:
    """Collapse '.', '..' and duplicate slashes of an absolute path."""
    var parts = List[String]()
    for p in path.split("/"):
        var s = String(p)
        if s.byte_length() == 0 or s == ".":
            continue
        if s == "..":
            if len(parts) > 0:
                _ = parts.pop()
            continue
        parts.append(s)
    var out = String("")
    for p in parts:
        out += "/" + p
    if out.byte_length() == 0:
        return "/"
    return out


def abs_path(cwd: String, path: String) -> String:
    if path.startswith("/"):
        return normalize_path(path)
    return normalize_path(join_path(cwd, path))


def list_dir(dir: String) -> List[String]:
    """Directory entries, directories first (suffixed with '/')."""
    var r = run_capture("ls -1Ap " + shell_quote(dir) + " 2>/dev/null")
    var txt = decode_list(r.out)
    var dirs = List[String]()
    var files = List[String]()
    var cur = List[Int]()
    for c in txt:
        if c == 10:
            if len(cur) > 0:
                var s = to_str(cur)
                if s.endswith("/"):
                    dirs.append(s)
                else:
                    files.append(s)
            cur.clear()
        else:
            cur.append(c)
    var out = List[String]()
    if dir != "/":
        out.append("../")
    for d in dirs:
        out.append(d)
    for f in files:
        out.append(f)
    return out^


def clock_hm() -> String:
    var t = List[Int](length=1, fill=0)
    t[0] = external_call["time", Int](Int(0))
    var tm = List[Int32](length=32, fill=0)
    _ = external_call["localtime_r", Int](t.unsafe_ptr(), tm.unsafe_ptr())
    var h = Int(tm[2])
    var m = Int(tm[1])
    var s = String("")
    if h < 10:
        s += "0"
    s += String(h) + ":"
    if m < 10:
        s += "0"
    s += String(m)
    return s


def secs_to_next_minute() -> Int:
    """Seconds until the wall clock shows a new minute (1..60)."""
    var t = external_call["time", Int](Int(0))
    return 60 - (t % 60)


def base64(data: List[UInt8]) -> String:
    var tbl = str_bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    var out = List[UInt8]()
    var i = 0
    var n = len(data)
    while i < n:
        var b0 = Int(data[i])
        var b1 = Int(data[i + 1]) if i + 1 < n else 0
        var b2 = Int(data[i + 2]) if i + 2 < n else 0
        out.append(tbl[b0 >> 2])
        out.append(tbl[((b0 & 3) << 4) | (b1 >> 4)])
        if i + 1 < n:
            out.append(tbl[((b1 & 15) << 2) | (b2 >> 6)])
        else:
            out.append(61)
        if i + 2 < n:
            out.append(tbl[b2 & 63])
        else:
            out.append(61)
        i += 3
    return bytes_to_str(out)


def env_or(name: String, default: String) -> String:
    var n = String(name)
    var p = external_call["getenv", Int](n.as_c_string_span())
    if p == 0:
        return default
    var r = run_capture("printf '%s' \"$" + name + "\"")
    return bytes_to_str(r.out)
