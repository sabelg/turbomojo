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
    var mem_address: Int        # the first byte shown (-1: none chosen)
    var mem: List[UInt8]
    var mem_known: Int          # how many of those bytes could be read
    var note: String

    def __init__(out self):
        self.ip = ""
        self.code = List[Instr]()
        self.regs = List[Reg]()
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
