"""Virtualized 16-byte/row Hex + ASCII Inspector (WK_HEX) and Binary File Safety Guard.

Supports auto-detection of binary files (NUL and control bytes), read-only protection,
virtualized rendering of 16 bytes per row with 8-byte hex offsets, synced hex and ASCII cursor
coordinates, and hex pattern searching."""
from std.collections import List
from util import decode, to_str, chr


def is_binary_data(data: List[UInt8], max_check: Int = 4096) -> Bool:
    """Detect if byte stream represents binary data by scanning for NUL and control bytes."""
    var limit = min(len(data), max_check)
    for i in range(limit):
        var b = Int(data[i])
        # NUL byte is definitive binary marker
        if b == 0:
            return True
        # Non-text control characters (excluding \t=9, \n=10, \r=13)
        if b < 9 or b == 11 or b == 12 or (b >= 14 and b < 32):
            return True
    return False


@fieldwise_init
struct BinaryGuard(Copyable, Movable):
    var is_binary: Bool
    var read_only: Bool
    var status_msg: String

    def __init__(out self, data: List[UInt8]):
        var bin = is_binary_data(data)
        self.is_binary = bin
        self.read_only = bin
        self.status_msg = "Binary file detected: opened read-only in hex inspector" if bin else "Text file"

    def can_modify(self) -> Bool:
        return not self.read_only


def byte_to_hex(b: UInt8) -> String:
    """Format single byte as 2 hex digits."""
    var hex_chars = decode("0123456789abcdef")
    var v = Int(b)
    var hi = (v >> 4) & 0x0F
    var lo = v & 0x0F
    return chr(hex_chars[hi]) + chr(hex_chars[lo])


def format_hex_offset(offset: Int) -> String:
    """Format row byte offset as 8 hex digits."""
    var hex_chars = decode("0123456789abcdef")
    var out = String("")
    var v = offset
    for _ in range(8):
        var nibble = v & 0x0F
        out = chr(hex_chars[nibble]) + out
        v = v >> 4
    return out


def render_hex_row_bytes(bytes: List[UInt8], row: Int) -> String:
    """Render a single virtualized 16-byte row directly from `bytes` without copying."""
    var total_bytes = len(bytes)
    var total_rows = (total_bytes + 15) // 16 if total_bytes > 0 else 0
    if row < 0 or row >= total_rows:
        return ""
    var start = row * 16
    var end = min(start + 16, total_bytes)
    var row_len = end - start

    var out = format_hex_offset(start) + "  "

    # Hex bytes area (16 columns with middle gap)
    for i in range(16):
        if i < row_len:
            out += byte_to_hex(bytes[start + i])
        else:
            out += "  "
        if i == 7:
            out += "  "
        else:
            out += " "

    out += " |"

    # ASCII representation area
    for i in range(16):
        if i < row_len:
            var b = Int(bytes[start + i])
            if b >= 32 and b <= 126:
                out += chr(b)
            else:
                out += "."
        else:
            out += " "

    out += "|"
    return out


def render_hex_rows(bytes: List[UInt8], start_row: Int, num_rows: Int) -> List[String]:
    """Render up to `num_rows` 16-byte hex + ASCII lines starting at `start_row`."""
    var out = List[String]()
    if num_rows <= 0 or len(bytes) == 0:
        return out^
    var total_rows = (len(bytes) + 15) // 16
    var r0 = max(0, start_row)
    var r1 = min(total_rows, r0 + num_rows)
    for r in range(r0, r1):
        out.append(render_hex_row_bytes(bytes, r))
    return out^


struct VirtualHexView(Copyable, Movable):
    var data: List[UInt8]
    var total_bytes: Int
    var total_rows: Int
    var cursor_offset: Int
    var in_ascii_column: Bool

    def __init__(out self, data: List[UInt8]):
        self.data = data.copy()
        self.total_bytes = len(data)
        self.total_rows = (self.total_bytes + 15) // 16 if self.total_bytes > 0 else 0
        self.cursor_offset = 0
        self.in_ascii_column = False

    def row_count(self) -> Int:
        return self.total_rows

    def render_row(self, row: Int) -> String:
        """Render a single virtualized 16-byte row with 8-byte hex offset, hex pairs, and ASCII."""
        return render_hex_row_bytes(self.data, row)

    def get_cursor_coords(self) -> Tuple[Int, Int, Int]:
        """Return (row, hex_screen_col, ascii_screen_col) for cursor_offset."""
        if self.total_bytes == 0:
            return (0, 10, 61)
        var clamped = max(0, min(self.cursor_offset, self.total_bytes - 1))
        var r = clamped // 16
        var col_in_row = clamped % 16

        var hex_col = 10 + col_in_row * 3 + (1 if col_in_row >= 8 else 0)
        var ascii_col = 61 + col_in_row
        return (r, hex_col, ascii_col)

    def set_cursor_from_hex(mut self, row: Int, col_in_row: Int):
        """Update cursor from hex pane coordinates."""
        var off = row * 16 + max(0, min(col_in_row, 15))
        self.cursor_offset = max(0, min(off, self.total_bytes - 1))
        self.in_ascii_column = False

    def set_cursor_from_ascii(mut self, row: Int, col_in_row: Int):
        """Update cursor from ascii pane coordinates."""
        var off = row * 16 + max(0, min(col_in_row, 15))
        self.cursor_offset = max(0, min(off, self.total_bytes - 1))
        self.in_ascii_column = True


def parse_hex_query(q: String) -> List[UInt8]:
    """Parse space-separated or contiguous hex string into bytes."""
    var out = List[UInt8]()
    var qc = decode(q)
    var clean = List[Int]()
    for i in range(len(qc)):
        var c = qc[i]
        if (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102):
            clean.append(c)

    var n = len(clean)
    var i = 0
    while i + 1 < n:
        var b1 = clean[i]
        var b2 = clean[i + 1]
        var v1 = (b1 - 48) if (b1 <= 57) else ((b1 - 65 + 10) if (b1 <= 70) else (b1 - 97 + 10))
        var v2 = (b2 - 48) if (b2 <= 57) else ((b2 - 65 + 10) if (b2 <= 70) else (b2 - 97 + 10))
        out.append(UInt8((v1 << 4) | v2))
        i += 2
    return out^


def search_hex(data: List[UInt8], query: String) -> List[Int]:
    """Search for byte pattern in binary data and return all matching byte offsets."""
    var matches = List[Int]()
    var pat = parse_hex_query(query)
    var m = len(pat)
    var n = len(data)
    if m == 0 or n < m:
        return matches^

    for i in range(n - m + 1):
        var found = True
        for j in range(m):
            if data[i + j] != pat[j]:
                found = False
                break
        if found:
            matches.append(i)
    return matches^
