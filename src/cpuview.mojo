"""What the CPU window shows: the machine code around the instruction the program is
stopped at, the general purpose registers, and a piece of memory.

As Mojo 1.2's debugger answers (verified on linux-aarch64): `disassemble` gives
addresses like "0xAAAAAAAA0F20", the instruction text padded with blanks (calls carry
"; function at file:line"), the bytes, and - on the first instruction of a line - the
line and its file. The Registers scope has sets ("General Purpose Registers", "Floating
Point Registers", ...); the general set lists x0..x28, fp, lr, sp, pc, cpsr and then
the 32-bit views w0..w28, values like "0x0000ffffffffde5c" (sometimes followed by a
symbol). `readMemory` answers base64 data, or `unreadableBytes`.
"""
from std.collections import List
from util import basename


def address_value(text: String) -> Int:
    """The number of a "0x..." text (-1 if it is not one)."""
    var t = String(text.strip())
    if not (t.startswith("0x") or t.startswith("0X")) or t.byte_length() < 3 or t.byte_length() > 18:
        return -1
    var v = 0
    var bs = t.as_bytes()
    for i in range(2, len(bs)):
        var c = Int(bs[i])
        var d: Int
        if c >= 48 and c <= 57:
            d = c - 48
        elif c >= 97 and c <= 102:
            d = c - 87
        elif c >= 65 and c <= 70:
            d = c - 55
        else:
            return -1
        v = (v << 4) | d
    return v


def hex_text(v: Int, digits: Int = 16) -> String:
    """`v` as "0x" and upper-case hex digits (at least `digits` of them, as the
    debugger writes addresses)."""
    var abc = "0123456789ABCDEF"
    var out = String("")
    var u = UInt64(v)
    var n = 0
    while u > 0 or n < digits:
        var d = Int(u & 15)
        out = String(abc[byte=d:d + 1]) + out
        u = u >> 4
        n += 1
        if n >= 16:
            break
    return "0x" + out


def base64_decode(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    var acc = 0
    var bits = 0
    for c in text.as_bytes():
        var v: Int
        if c >= 65 and c <= 90:
            v = Int(c) - 65
        elif c >= 97 and c <= 122:
            v = Int(c) - 71
        elif c >= 48 and c <= 57:
            v = Int(c) + 4
        elif c == 43:
            v = 62
        elif c == 47:
            v = 63
        else:
            continue            # padding, line ends
        acc = (acc << 6) | v
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append(UInt8((acc >> bits) & 255))
    return out^


def keep_register(name: String, value: String) -> Bool:
    """The registers worth a line: the full-width ones (and the flags), not the 32-bit
    views of the same registers."""
    if name == "cpsr" or name == "eflags" or name == "rflags" or name == "fpsr" or name == "fpcr":
        return True
    var v = String(value.split(" ")[0]) if value.byte_length() > 0 else String("")
    return v.startswith("0x") and v.byte_length() == 18


def is_vector_register(name: String, value: String) -> Bool:
    """SIMD / vector registers on x86-64 (xmm/ymm/zmm) and AArch64 (v0..v31, q0..q31, z0..z31)."""
    var low = name.lower()
    if low.startswith("xmm") or low.startswith("ymm") or low.startswith("zmm"):
        return value.byte_length() > 0
    if (low.startswith("v") or low.startswith("q") or low.startswith("z")) and low.byte_length() >= 2 and low.byte_length() <= 3:
        var rest = String(low[byte=1:])
        var all_digits = True
        for b in rest.as_bytes():
            if Int(b) < 48 or Int(b) > 57:
                all_digits = False
        if all_digits:
            return value.find("{") >= 0 or (value.startswith("0x") and value.byte_length() >= 34)
    return False


def hex_nibble(c: Int) -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1


def parse_vector_bytes(value: String) -> List[UInt8]:
    """Extract little-endian lane bytes from LLDB vector representations:
    either `{0x00 0x00 0x80 0x3f ...}` or a wide `0x...` hex literal."""
    var out = List[UInt8]()
    var brace = value.find("{")
    if brace >= 0:
        var close = value.find("}", brace)
        var body = String(value[byte=brace + 1 : close]) if close > brace else String(value[byte=brace + 1 :])
        for tok_s in body.replace(",", " ").split(" "):
            var tok = String(String(tok_s).strip())
            if tok.startswith("0x") or tok.startswith("0X"):
                var bs = tok.as_bytes()
                if len(bs) == 4:
                    var hi = hex_nibble(Int(bs[2]))
                    var lo = hex_nibble(Int(bs[3]))
                    if hi >= 0 and lo >= 0:
                        out.append(UInt8((hi << 4) | lo))
        return out^
    var head = String(value.split(" ")[0].strip())
    if (head.startswith("0x") or head.startswith("0X")) and head.byte_length() >= 10:
        var hex_part = String(head[byte=2:])
        if hex_part.byte_length() % 2 == 1:
            hex_part = "0" + hex_part
        # Big-endian hex number -> little-endian lane bytes (reverse byte order)
        var hb = hex_part.as_bytes()
        var k = len(hb) - 2
        while k >= 0:
            var hi = hex_nibble(Int(hb[k]))
            var lo = hex_nibble(Int(hb[k + 1]))
            if hi >= 0 and lo >= 0:
                out.append(UInt8((hi << 4) | lo))
            k -= 2
    return out^


def u32_to_i32_str(u: Int) -> String:
    var v = u & 0xFFFFFFFF
    if v >= 0x80000000:
        return String(v - 0x100000000)
    return String(v)


def u32_to_f32_str(u: Int) -> String:
    var v = u & 0xFFFFFFFF
    var sign = "-" if ((v >> 31) & 1) != 0 else ""
    var exp = (v >> 23) & 0xFF
    var frac = v & 0x7FFFFF
    if exp == 0xFF:
        return (sign + "inf") if frac == 0 else "nan"
    if exp == 0 and frac == 0:
        return sign + "0.0"
    var mant = Float64(frac) / Float64(1 << 23)
    var p = exp - 127
    if exp == 0:
        p = -126
    else:
        mant += 1.0
    var scale = Float64(1.0)
    if p >= 0:
        for _ in range(p):
            scale *= 2.0
    else:
        for _ in range(-p):
            scale *= 0.5
    var val = mant * scale
    if sign == "-":
        val = -val
    var s = String(val)
    if s.byte_length() > 10 and s.find("e") < 0 and s.find("E") < 0:
        var dot = s.find(".")
        if dot >= 0 and dot + 5 < s.byte_length():
            var trunc = String(s[byte=0 : dot + 5])
            s = trunc
    return s


def format_simd_lanes(value: String, simd_mode: Int) -> String:
    """Format a vector register as 32-bit lanes (`hex`, `f32`, or `i32`)."""
    var bs = parse_vector_bytes(value)
    if len(bs) < 4:
        return value
    var lanes = List[String]()
    var n_lanes = min(len(bs) // 4, 8)
    var abc = "0123456789abcdef"
    for i in range(n_lanes):
        var b0 = Int(bs[i * 4])
        var b1 = Int(bs[i * 4 + 1])
        var b2 = Int(bs[i * 4 + 2])
        var b3 = Int(bs[i * 4 + 3])
        var u = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        if simd_mode == 1:
            lanes.append(u32_to_f32_str(u))
        elif simd_mode == 2:
            lanes.append(u32_to_i32_str(u))
        else:
            var hx = String("0x")
            for shift in [28, 24, 20, 16, 12, 8, 4, 0]:
                var nib = (u >> shift) & 15
                hx += String(abc[byte=nib : nib + 1])
            lanes.append(hx)
    var tail = (" …+" + String(len(bs) // 4 - n_lanes)) if (len(bs) // 4 > n_lanes) else String("")
    return "[" + ", ".join(lanes) + tail + "]"


@fieldwise_init
struct Instr(Copyable, Movable):
    var address: String
    var text: String
    var path: String        # the source line it starts, when it starts one
    var line: Int


@fieldwise_init
struct Reg(Copyable, Movable):
    var name: String
    var value: String
    var changed: Bool


struct CpuView(Copyable, Movable):
    var ip: String
    var code: List[Instr]
    var regs: List[Reg]
    var vregs: List[Reg]
    var simd_mode: Int          # 0 hex32, 1 f32, 2 i32 (cycled with V)
    var mem_address: Int        # the first byte shown (-1: none chosen)
    var mem: List[UInt8]
    var mem_known: Int          # how many of those bytes could be read
    var note: String

    def __init__(out self):
        self.ip = ""
        self.code = List[Instr]()
        self.regs = List[Reg]()
        self.vregs = List[Reg]()
        self.simd_mode = 1
        self.mem_address = -1
        self.mem = List[UInt8]()
        self.mem_known = 0
        self.note = "(no program is stopped)"

    def set_regs(mut self, names: List[String], values: List[String]):
        """New register values; those that differ from the last stop are marked."""
        var old = self.regs.copy()
        self.regs.clear()
        for k in range(len(names)):
            if not keep_register(names[k], values[k]):
                continue
            var changed = False
            for o in old:
                if o.name == names[k] and o.value != values[k]:
                    changed = True
            self.regs.append(Reg(names[k], values[k], changed))

    def set_vregs(mut self, names: List[String], values: List[String]):
        """Vector / SIMD register values (xmm/ymm/zmm, v0..v31); avoids alias duplicates
        by keeping the widest view per register number."""
        var old = self.vregs.copy()
        self.vregs.clear()
        for k in range(len(names)):
            if not is_vector_register(names[k], values[k]):
                continue
            var low = names[k].lower()
            # Prefer zmm over ymm/xmm, ymm over xmm when both appear in the same set
            if low.startswith("xmm"):
                var idx_s = String(low[byte=3:])
                if ("ymm" + idx_s) in names or ("zmm" + idx_s) in names:
                    continue
            elif low.startswith("ymm"):
                var idx_s = String(low[byte=3:])
                if ("zmm" + idx_s) in names:
                    continue
            var changed = False
            for o in old:
                if o.name == names[k] and o.value != values[k]:
                    changed = True
            self.vregs.append(Reg(names[k], values[k], changed))
            if len(self.vregs) >= 16:
                break

    def cycle_simd_mode(mut self) -> String:
        self.simd_mode = (self.simd_mode + 1) % 3
        if self.simd_mode == 1:
            return "f32"
        if self.simd_mode == 2:
            return "i32"
        return "hex32"

    def register(self, name: String) -> Int:
        """A register's value as a number (-1 if it is not there)."""
        for r in self.regs:
            if r.name == name:
                return address_value(String(r.value.split(" ")[0]))
        return -1

    def lines(self) -> List[String]:
        var out = List[String]()
        out.append("Code")
        if len(self.code) == 0:
            out.append("  " + self.note)
        var last_path = String("")
        var last_line = -1
        for ins in self.code:
            if ins.line > 0 and (ins.line != last_line or ins.path != last_path):
                out.append("    " + (basename(ins.path) if ins.path.byte_length() > 0 else String("?")) + ":" + String(ins.line))
                last_path = ins.path
                last_line = ins.line
            out.append(("► " if ins.address == self.ip else "  ") + ins.address + "  " + String(ins.text.strip()))
        out.append("")
        out.append("Registers   (* changed since the last stop)")
        if len(self.regs) == 0:
            out.append("  " + self.note)
        var row = String("")
        var n = 0
        for r in self.regs:
            var cell = (("*" if r.changed else " ") + r.name + "      ")
            cell = String(cell[byte=0:6]) + " " + String(r.value.split(" ")[0])
            while cell.byte_length() < 26:
                cell += " "
            row += cell
            n += 1
            if n % 3 == 0:
                out.append(" " + String(row.rstrip()))
                row = ""
        if row.byte_length() > 0:
            out.append(" " + String(row.rstrip()))
        if len(self.vregs) > 0:
            var mname = "f32" if self.simd_mode == 1 else ("i32" if self.simd_mode == 2 else "hex32")
            out.append("")
            out.append("Vector / SIMD Registers   (lanes as " + mname + "; V: cycle f32 / i32 / hex32)")
            for vr in self.vregs:
                var tag = ("*" if vr.changed else " ") + vr.name
                while tag.byte_length() < 7:
                    tag += " "
                out.append(" " + tag + " " + format_simd_lanes(vr.value, self.simd_mode))
        out.append("")
        if self.mem_address < 0:
            out.append("Memory   (G: go to an address or a variable)")
            out.append("  (none chosen)")
            return out^
        out.append("Memory at " + hex_text(self.mem_address) + "   (G: go to, + / -: next / previous)")
        var k = 0
        while k < len(self.mem):
            var s = "  " + String(hex_text(self.mem_address + k)[byte=2:]) + "  "
            var asc = String("")
            for j in range(16):
                var i = k + j
                if i >= len(self.mem):
                    break
                if i >= self.mem_known:
                    s += "?? "
                    asc += "?"
                    continue
                var b = Int(self.mem[i])
                var digits = "0123456789abcdef"
                s += String(digits[byte=b // 16:b // 16 + 1]) + String(digits[byte=b % 16:b % 16 + 1]) + " "
                asc += chr(b) if (b >= 32 and b < 127) else "."
            out.append(s + " " + asc)
            k += 16
        return out^
