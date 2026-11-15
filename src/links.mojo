"""Hyperlinks on file:line references (OSC 8).

`find_refs` finds `path:line` and `path:line:column` in a row of text - compiler
output, search hits, problems, the agent's messages; the caller keeps those whose
file exists. `link_uri` makes the link from `ui.hyperlink_format`, as ripgrep's
--hyperlink-format: {host}, {path} (absolute, percent-encoded), {line} and {column};
the default `file://{host}{path}` opens the file in the system's handler, and e.g.
`vscode://file{path}:{line}:{column}` or `turbomojo://...` an editor at the line.
"""
from std.collections import List
from std.ffi import external_call
from util import encode_cp, bytes_to_str, decode

comptime DEFAULT_LINK_FORMAT = "file://{host}{path}"


struct FileRef(Copyable, Movable):
    var start: Int          # code points [start, end) of the row: the reference as shown
    var end: Int
    var path: String        # as written (relative or absolute)
    var line: Int
    var col: Int            # 0 if not given

    def __init__(out self, start: Int, end: Int, path: String, line: Int, col: Int):
        self.start = start
        self.end = end
        self.path = path
        self.line = line
        self.col = col


def path_char(c: Int) -> Bool:
    return (
        (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
        or c == 46 or c == 47 or c == 95 or c == 45 or c == 126 or c == 43 or c == 64
        or c > 127
    )


def is_digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def find_refs(cps: List[Int]) -> List[FileRef]:
    """Every `path:line[:column]` in the row: a path of file-name characters with a
    dot or a slash in it, a colon, digits, and optionally a colon and digits."""
    var out = List[FileRef]()
    var n = len(cps)
    var i = 0
    while i < n:
        if not path_char(cps[i]) or (i > 0 and path_char(cps[i - 1])):
            i += 1
            continue
        var j = i
        var dotted = False
        while j < n and path_char(cps[j]):
            if cps[j] == 46 or cps[j] == 47:
                dotted = True
            j += 1
        # a path, then ":digits"
        if not dotted or j + 1 >= n or cps[j] != 58 or not is_digit(cps[j + 1]):
            i = j
            continue
        var path_end = j
        # a sentence's full stop before the colon is not part of the path
        while path_end > i and cps[path_end - 1] == 46:
            path_end -= 1
        if path_end == i:
            i = j
            continue
        var k = j + 1
        var line = 0
        while k < n and is_digit(cps[k]):
            line = line * 10 + cps[k] - 48
            k += 1
        var col = 0
        if k + 1 < n and cps[k] == 58 and is_digit(cps[k + 1]):
            k += 1
            while k < n and is_digit(cps[k]):
                col = col * 10 + cps[k] - 48
                k += 1
        var p = List[Int]()
        for q in range(i, path_end):
            p.append(cps[q])
        var b = List[UInt8]()
        for c in p:
            encode_cp(c, b)
        if line > 0:
            out.append(FileRef(i, k, bytes_to_str(b), line, col))
        i = k
    return out^


def percent_encode_path(path: String) -> String:
    """A path for a URI: everything but letters, digits, `/-._~` percent-encoded."""
    var out = String("")
    var hex = "0123456789ABCDEF"
    for b in path.as_bytes():
        var c = Int(b)
        if (
            (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
            or c == 47 or c == 45 or c == 46 or c == 95 or c == 126
        ):
            out += chr(c)
        else:
            out += "%" + String(hex[byte=c >> 4]) + String(hex[byte=c & 15])
    return out


def host_name() -> String:
    var buf = List[UInt8](length=256, fill=0)
    if external_call["gethostname", Int32](buf.unsafe_ptr(), Int(255)) != 0:
        return ""
    var n = 0
    while n < 255 and buf[n] != 0:
        n += 1
    return bytes_to_str(List[UInt8](buf[0:n]))


def link_uri(format: String, host: String, abs_path: String, line: Int, col: Int) -> String:
    var f = format if format.byte_length() > 0 else String(DEFAULT_LINK_FORMAT)
    return (
        f.replace("{host}", host).replace("{path}", percent_encode_path(abs_path))
        .replace("{line}", String(max(1, line))).replace("{column}", String(max(1, col)))
    )


def parse_ssh_host(conn: String) -> String:
    """Extracts remote host/server from SSH_CONNECTION ('client_ip c_port server_ip s_port')
    with resilience against irregular whitespace, or falls back to system hostname."""
    if conn.byte_length() == 0:
        return host_name()
    var parts = List[String]()
    var cur = String("")
    for i in range(conn.byte_length()):
        var c = conn[byte=i]
        if c == " " or c == "\t":
            if cur.byte_length() > 0:
                parts.append(cur)
                cur = ""
        else:
            cur += String(c)
    if cur.byte_length() > 0:
        parts.append(cur)
    if len(parts) >= 3:
        return parts[2]
    return host_name()


def format_ssh_pill(host: String) -> String:
    """Formats [ssh:<host>] status pill for the IDE status line."""
    if host.byte_length() == 0:
        return ""
    return "[ssh:" + host + "]"


def parse_port_forward(line: String, host: String, is_ssh: Bool) -> String:
    """Scans terminal output line for localhost binds (127.0.0.1:, localhost:, [::1]:)
    and constructs 'ssh -L <port>:127.0.0.1:<port> <host>' command when running over SSH."""
    if not is_ssh or host.byte_length() == 0:
        return ""
    var patterns = List[String]()
    patterns.append("127.0.0.1:")
    patterns.append("localhost:")
    patterns.append("[::1]:")

    for k in range(len(patterns)):
        var pat = patterns[k]
        var idx = line.find(pat)
        if idx >= 0:
            var start = idx + pat.byte_length()
            var port_str = String("")
            var i = start
            while i < line.byte_length():
                var c = line[byte=i]
                if c >= "0" and c <= "9":
                    port_str += String(c)
                    i += 1
                else:
                    break
            if port_str.byte_length() > 0:
                return "ssh -L " + port_str + ":127.0.0.1:" + port_str + " " + host
    return ""

