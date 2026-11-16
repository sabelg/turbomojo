"""What the Debug window shows: the call stack of the stopped program and the variables
of the chosen frame, as a tree that opens on request.

Values come from Mojo's debugger the way LLDB sees them, which is not how a Mojo
programmer writes them (verified with mojo-lldb-dap of Mojo 1.2):

- scalars carry their raw bytes first: `0400000000000000  4`, `01 True`;
- their type is the compiler's: "__mlir_type.`!kgen.scalar<index>`" is an Int;
- a scalar has one child, "[0]", with the same value again.

`nice_value` / `nice_type` turn these into `4`, `True`, `Int`; scalars are shown as leaves.
The debugger cannot set a value of these types (setVariable answers "Invalid c-string
value string."), but it can write memory, so `encode_value` turns a typed value into the
bytes to write (`writeMemory`, base64).
"""
from std.collections import List
from std.memory import bitcast
from breakpoints import DataBreakpoint
from tensor_inspect import summarize_mojo_value
from util import basename

comptime VK_HEAD = 0         # a title line
comptime VK_FRAME = 1        # a frame of the call stack
comptime VK_VAR = 2          # a variable
comptime VK_NOTE = 3         # an explanation ("no variables", "loading")
comptime VK_WATCH = 4        # a watched expression


def watch_text(expr: String, ok: Bool, value: String, type: String, error: String) -> String:
    """One watch as the Debug window shows it."""
    if not ok:
        var why = error
        if why == "error: invalid value object" or why.byte_length() == 0:
            # what Mojo 1.2's debugger answers for anything but a name or a field
            why = "cannot be evaluated (only names and fields: a, a.b)"
        return expr + ": " + why
    var card = summarize_mojo_value("", type, value)
    if card.byte_length() > 0:
        return expr + " = " + card
    var t = nice_type(type)
    var v = nice_value(value)
    if v == t:
        return expr + ": " + t
    return expr + " = " + v + (("   " + t) if t.byte_length() > 0 else String(""))


def console_command(text: String) -> String:
    """What the console sends: a leading ':' (as the debugger's welcome text suggests)
    becomes the backquote that makes LLDB take the line as a command."""
    var t = String(text.strip())
    if t.startswith(":"):
        return "`" + String(t[byte=1:])
    return t


def parse_xyz_triple(text: String) -> Tuple[Int, Int, Int]:
    """Parse `x,y,z` or `x y z` or `x` into non-negative 3D coordinates."""
    var nums = List[Int]()
    var cur = 0
    var have = False
    for b in text.as_bytes():
        var c = Int(b)
        if c >= 48 and c <= 57:
            cur = cur * 10 + (c - 48)
            have = True
        else:
            if have:
                nums.append(cur)
                cur = 0
                have = False
    if have:
        nums.append(cur)
    var x = nums[0] if len(nums) > 0 else 0
    var y = nums[1] if len(nums) > 1 else 0
    var z = nums[2] if len(nums) > 2 else 0
    return (x, y, z)


def format_gpu_focus_command(adapter: String, block_xyz: String, thread_xyz: String) -> String:
    """Build the debugger REPL command that switches focus to a GPU block/thread or lane
    across `cuda-gdb`, `rocgdb`, and `mojo-lldb-dap` / `lldb-dap`."""
    var b = parse_xyz_triple(block_xyz)
    var t = parse_xyz_triple(thread_xyz)
    var low = adapter.lower()
    if low.find("cuda-gdb") >= 0:
        return (
            "cuda block ("
            + String(b[0]) + "," + String(b[1]) + "," + String(b[2])
            + ") thread ("
            + String(t[0]) + "," + String(t[1]) + "," + String(t[2])
            + ")"
        )
    if low.find("rocgdb") >= 0:
        return "lane " + String(t[0])
    return "`thread select " + String(max(1, t[0]))


def console_result(text: String) -> String:
    """A console answer for one value, "(String)  = \"mojo\"", as "\"mojo\"   String";
    anything else (several lines, command output) stays as it is."""
    if not text.startswith("(") or text.find("\n") >= 0:
        return text
    var close = text.find(")  = ")
    if close < 0:
        return text
    var t = nice_type(String(text[byte=1:close]))
    var v = nice_value(String(text[byte=close + 5:]))
    return v + "   " + t


def is_hex(s: String) -> Bool:
    if s.byte_length() == 0:
        return False
    for c in s.as_bytes():
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)):
            return False
    return True


def nice_value(value: String) -> String:
    """A value without the raw bytes LLDB puts before a scalar ("0400000000000000  4"
    → "4", "01 True" → "True"). Other values stay as they are."""
    var sp = value.find(" ")
    if sp < 2 or sp > 16 or sp % 2 != 0:
        return value
    var head = String(value[byte=0:sp])
    if not is_hex(head):
        return value
    var rest = String(String(value[byte=sp:]).strip())
    if rest.byte_length() == 0:
        return value
    return rest


def scalar_kind(type: String) -> String:
    """The element kind of a compiler scalar type ("index", "si64", "f64", "bool", ...;
    '' if the type is not one)."""
    var t = String(type[byte=12:]) if type.startswith("__mlir_type.") else type
    if t.startswith("`") and t.endswith("`") and t.byte_length() >= 2:
        var inner = String(t[byte=1:t.byte_length() - 1])
        t = inner
    if t.startswith("!kgen.scalar<") and t.endswith(">"):
        return String(t[byte=13:t.byte_length() - 1])
    for k in ["index", "si64", "ui64", "si32", "ui32", "si16", "ui16", "si8", "ui8", "i64", "i32", "i16", "i8", "i1", "f64", "f32", "f16", "bf16", "bool"]:
        if t == k:
            return t
    return ""


def nice_type(type: String) -> String:
    """A Mojo name for a compiler type ("__mlir_type.`!kgen.scalar<index>`" → "Int")."""
    var k = scalar_kind(type)
    if k.byte_length() == 0:
        if type.startswith("__mlir_type."):
            return String(type[byte=12:])
        return type
    if k == "index":
        return "Int"
    if k == "bool" or k == "i1":
        return "Bool"
    if k.startswith("si") or k.startswith("i"):
        return "Int" + String(k[byte=2:] if k.startswith("si") else k[byte=1:])
    if k.startswith("ui"):
        return "UInt" + String(k[byte=2:])
    if k == "bf16":
        return "BFloat16"
    if k.startswith("f"):
        return "Float" + String(k[byte=1:])
    return k


def value_width(type: String) -> Int:
    """Bytes of a scalar of this type (0: not a scalar that can be written)."""
    var k = scalar_kind(type)
    if k == "index" or k == "si64" or k == "ui64" or k == "i64" or k == "f64":
        return 8
    if k == "si32" or k == "ui32" or k == "i32" or k == "f32":
        return 4
    if k == "si16" or k == "ui16" or k == "i16" or k == "f16" or k == "bf16":
        return 2
    if k == "si8" or k == "ui8" or k == "i8" or k == "bool" or k == "i1":
        return 1
    return 0


def encode_value(type: String, text: String) -> Tuple[List[UInt8], String]:
    """The bytes (little-endian) for `text` as a value of `type`, or a reason why not."""
    var out = List[UInt8]()
    var k = scalar_kind(type)
    var n = value_width(type)
    var t = String(text.strip())
    if n == 0:
        return (out^, "values of type " + nice_type(type) + " cannot be set here")
    if k == "f16" or k == "bf16":
        var fh: Float64
        try:
            fh = Float64(t)
        except:
            return (out^, "not a number: " + t)
        var bits16: UInt16
        if k == "f16":
            bits16 = bitcast[DType.uint16](Float16(fh))
        else:
            bits16 = bitcast[DType.uint16](BFloat16(fh))
        out.append(UInt8(bits16 & 0xFF))
        out.append(UInt8((bits16 >> 8) & 0xFF))
        return (out^, "")
    if k == "bool" or k == "i1":
        var low = t.lower()
        if low == "true" or t == "1":
            out.append(1)
        elif low == "false" or t == "0":
            out.append(0)
        else:
            return (out^, "a Bool is True or False")
        return (out^, "")
    if k == "f64" or k == "f32":
        var f: Float64
        try:
            f = Float64(t)
        except:
            return (out^, "not a number: " + t)
        var bits: UInt64
        if k == "f64":
            bits = bitcast[DType.uint64](f)
        else:
            bits = UInt64(bitcast[DType.uint32](Float32(f)))
        for i in range(n):
            out.append(UInt8((bits >> UInt64(8 * i)) & 255))
        return (out^, "")
    var v: Int
    try:
        v = atol(t)
    except:
        return (out^, "not a whole number: " + t)
    var unsigned = k.startswith("ui")
    if n < 8:
        var lo = 0 if unsigned else -(1 << (8 * n - 1))
        var hi = ((1 << (8 * n)) - 1) if unsigned else ((1 << (8 * n - 1)) - 1)
        if v < lo or v > hi:
            return (out^, String(v) + " does not fit in " + nice_type(type))
    elif unsigned and v < 0:
        return (out^, String(v) + " does not fit in " + nice_type(type))
    var u: UInt64
    if v >= 0:
        u = UInt64(v)
    else:
        u = ~UInt64(-(v + 1))       # two's complement
    for i in range(n):
        out.append(UInt8((u >> UInt64(8 * i)) & 255))
    return (out^, "")


def base64(data: List[UInt8]) -> String:
    var abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(data):
        var b0 = Int(data[i])
        var b1 = Int(data[i + 1]) if i + 1 < len(data) else 0
        var b2 = Int(data[i + 2]) if i + 2 < len(data) else 0
        out.append(abc[b0 >> 2])
        out.append(abc[((b0 & 3) << 4) | (b1 >> 4)])
        out.append(abc[((b1 & 15) << 2) | (b2 >> 6)] if i + 1 < len(data) else 61)
        out.append(abc[b2 & 63] if i + 2 < len(data) else 61)
        i += 3
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def encode_tensor_value(dtype_str: String, text: String) -> Tuple[List[UInt8], String]:
    """Encode scalar f16, bf16, f32, or f64 value to little-endian bytes."""
    var out = List[UInt8]()
    var t = String(text.strip())
    var dt = dtype_str.lower()

    if dt == "f16" or dt.find("scalar<f16>") >= 0 or dt == "float16":
        return encode_value("f16", t)
    if dt == "bf16" or dt.find("scalar<bf16>") >= 0 or dt == "bfloat16":
        return encode_value("bf16", t)
    if dt == "f32" or dt.find("scalar<f32>") >= 0 or dt == "float32":
        return encode_value("f32", t)
    if dt == "f64" or dt.find("scalar<f64>") >= 0 or dt == "float64":
        return encode_value("f64", t)
    return (out^, "unsupported tensor dtype: " + dtype_str)


def _dbg_hex16(v: Int) -> String:
    var abc = "0123456789ABCDEF"
    var out = String("")
    var u = UInt64(v)
    var n = 0
    while u > 0 or n < 16:
        var d = Int(u & 15)
        out = String(abc[byte=d:d + 1]) + out
        u = u >> 4
        n += 1
        if n >= 16:
            break
    return "0x" + out


def build_dap_write_memory_request(address: Int, raw_bytes: List[UInt8]) -> String:
    """Build a DAP writeMemory request payload with 16-hex address and base64 data."""
    var addr_str = _dbg_hex16(address)
    var b64_str = base64(raw_bytes)
    return '{"command":"writeMemory","arguments":{"memoryReference":"' + addr_str + '","data":"' + b64_str + '"}}'


def address_in(text: String) -> String:
    """The first "0x..." address in a text (LLDB names list elements by their address:
    "(*( (!kgen.scalar<index> *)0x50353fe04000))"); '' if there is none."""
    var at = text.find("0x")
    if at < 0:
        return ""
    var end = at + 2
    var bs = text.as_bytes()
    while end < len(bs) and ((bs[end] >= 48 and bs[end] <= 57) or (bs[end] >= 97 and bs[end] <= 102) or (bs[end] >= 65 and bs[end] <= 70)):
        end += 1
    if end == at + 2:
        return ""
    return String(text[byte=at:end])


@fieldwise_init
struct FrameRow(Copyable, Movable):
    var id: Int
    var name: String
    var path: String        # '' when the source is not on this machine
    var line: Int


struct VarNode(Copyable, Movable):
    var name: String
    var type: String
    var value: String
    var handle: Int            # the adapter's handle for its children (0: none)
    var memory: String      # where it is, when the adapter says
    var eval_name: String
    var depth: Int
    var open: Bool
    var path: String        # names from the top, joined with "\t" (to reopen after a step)

    def __init__(out self, name: String, type: String, value: String, handle: Int, memory: String, eval_name: String, depth: Int, path: String):
        self.name = name
        self.type = type
        self.value = value
        self.handle = handle
        self.memory = memory
        self.eval_name = eval_name
        self.depth = depth
        self.open = False
        self.path = path

    def scalar(self) -> Bool:
        return scalar_kind(self.type).byte_length() > 0

    def has_children(self) -> Bool:
        """Children worth opening: not the "[0]" a scalar repeats itself in."""
        return self.handle > 0 and not self.scalar()

    def address(self) -> String:
        if self.memory.byte_length() > 0:
            return self.memory
        return address_in(self.eval_name)

    def settable(self) -> Bool:
        return self.scalar() and value_width(self.type) > 0 and self.address().byte_length() > 0

    def line(self) -> String:
        var s = String("")
        for _ in range(self.depth):
            s += "  "
        if self.has_children():
            s += "▾ " if self.open else "▸ "
        else:
            s += "  "
        var card = summarize_mojo_value("", self.type, self.value)
        if card.byte_length() > 0:
            return s + self.name + " = " + card
        var t = nice_type(self.type)
        var v = nice_value(self.value)
        if self.has_children() and (v == t or v.byte_length() == 0):
            return s + self.name + ": " + t
        s += self.name + " = " + v
        if t.byte_length() > 0:
            s += "   " + t
        return s


def format_varnode_with_watchpoint(node: VarNode, bp: DataBreakpoint) -> String:
    """Format variable display row with hardware watchpoint badge."""
    var base = node.line()
    if bp.data_id.byte_length() == 0 or bp.access_type.byte_length() == 0:
        return base
    return base + "   [" + bp.badge() + " W:" + bp.access_type + "]"


struct DebugView(Copyable, Movable):
    var frames: List[FrameRow]
    var sel: Int                    # the frame whose variables are shown
    var nodes: List[VarNode]
    var opened: List[String]        # paths of open nodes, kept across stops
    var note: String                # instead of variables ("loading", "none", an error)
    var rows_kind: List[Int]        # what each line of the window is (VK_...)
    var rows_index: List[Int]       # ... and which frame or node
    var watches: List[String]       # watched expressions
    var watch_shown: List[String]   # how each is shown now
    var data_bps: List[DataBreakpoint]
    var scope_handle: Int

    def __init__(out self):
        self.frames = List[FrameRow]()
        self.sel = 0
        self.nodes = List[VarNode]()
        self.opened = List[String]()
        self.note = ""
        self.rows_kind = List[Int]()
        self.rows_index = List[Int]()
        self.watches = List[String]()
        self.watch_shown = List[String]()
        self.data_bps = List[DataBreakpoint]()
        self.scope_handle = 0

    def clear(mut self):
        self.frames.clear()
        self.sel = 0
        self.nodes.clear()
        self.note = ""
        self.scope_handle = 0

    def parent_handle_of(self, idx: Int) -> Int:
        if idx < 0 or idx >= len(self.nodes):
            return 0
        var d = self.nodes[idx].depth
        if d <= 0:
            return self.scope_handle
        var j = idx - 1
        while j >= 0:
            if self.nodes[j].depth < d:
                return self.nodes[j].handle
            j -= 1
        return self.scope_handle

    def find(self, path: String) -> Int:
        for k in range(len(self.nodes)):
            if self.nodes[k].path == path:
                return k
        return -1

    def subtree_end(self, k: Int) -> Int:
        """The index after node k's descendants."""
        var j = k + 1
        while j < len(self.nodes) and self.nodes[j].depth > self.nodes[k].depth:
            j += 1
        return j

    def put_children(mut self, parent_path: String, var children: List[VarNode]):
        """The answer for a node's children ('' = the frame's variables). Returns
        nothing; nodes that were open before are marked open (their children are to
        be asked for: see `wanted`)."""
        var at = 0
        var depth = 0
        var end = len(self.nodes)
        if parent_path.byte_length() > 0:
            var p = self.find(parent_path)
            if p < 0:
                return
            at = p + 1
            depth = self.nodes[p].depth + 1
            end = self.subtree_end(p)
            self.nodes[p].open = True
        else:
            self.note = "" if len(children) > 0 else "(no variables)"
        # what was there is replaced
        var kept = List[VarNode]()
        for k in range(at):
            kept.append(self.nodes[k].copy())
        for i in range(len(children)):
            var c = children[i].copy()
            c.depth = depth
            c.path = (parent_path + "\t" + c.name) if parent_path.byte_length() > 0 else c.name
            c.open = False
            kept.append(c^)
        for k in range(end, len(self.nodes)):
            kept.append(self.nodes[k].copy())
        self.nodes = kept^

    def wanted(self) -> List[Int]:
        """Nodes that were open before (by path) and whose children are not there yet."""
        var out = List[Int]()
        for k in range(len(self.nodes)):
            var n = self.nodes[k].copy()
            if n.has_children() and not n.open and n.path in self.opened:
                out.append(k)
        return out^

    def close(mut self, k: Int):
        var end = self.subtree_end(k)
        var kept = List[VarNode]()
        for j in range(len(self.nodes)):
            if j <= k or j >= end:
                kept.append(self.nodes[j].copy())
        self.nodes = kept^
        self.nodes[k].open = False
        var p = self.nodes[k].path
        var left = List[String]()
        for o in self.opened:
            if o != p and not o.startswith(p + "\t"):
                left.append(o)
        self.opened = left^

    def mark_open(mut self, k: Int):
        if self.nodes[k].path not in self.opened:
            self.opened.append(self.nodes[k].path)

    def lines(mut self) -> List[String]:
        """The window's text, one entry per line; rows_kind / rows_index say what each
        line is."""
        var out = List[String]()
        self.rows_kind.clear()
        self.rows_index.clear()
        out.append("Call stack")
        self.rows_kind.append(VK_HEAD)
        self.rows_index.append(-1)
        if len(self.frames) == 0:
            out.append("  (the program is not stopped)")
            self.rows_kind.append(VK_NOTE)
            self.rows_index.append(-1)
        for k in range(len(self.frames)):
            var f = self.frames[k].copy()
            var place = (basename(f.path) + ":" + String(f.line)) if f.path.byte_length() > 0 else String("(no source)")
            out.append(("► " if k == self.sel else "  ") + f.name + "   " + place)
            self.rows_kind.append(VK_FRAME)
            self.rows_index.append(k)
        if len(self.watches) > 0:
            out.append("")
            self.rows_kind.append(VK_NOTE)
            self.rows_index.append(-1)
            out.append("Watches")
            self.rows_kind.append(VK_HEAD)
            self.rows_index.append(-1)
            for k in range(len(self.watches)):
                var shown = self.watch_shown[k] if k < len(self.watch_shown) else String("")
                out.append("  " + (shown if shown.byte_length() > 0 else self.watches[k] + ": ?"))
                self.rows_kind.append(VK_WATCH)
                self.rows_index.append(k)
        out.append("")
        self.rows_kind.append(VK_NOTE)
        self.rows_index.append(-1)
        var title = String("Variables")
        if self.sel < len(self.frames):
            title += " of " + self.frames[self.sel].name
        out.append(title)
        self.rows_kind.append(VK_HEAD)
        self.rows_index.append(-1)
        if self.note.byte_length() > 0 or len(self.nodes) == 0:
            out.append("  " + (self.note if self.note.byte_length() > 0 else String("(none)")))
            self.rows_kind.append(VK_NOTE)
            self.rows_index.append(-1)
        for k in range(len(self.nodes)):
            var nd = self.nodes[k].copy()
            var addr = nd.address()
            var line_str = nd.line()
            for bi in range(len(self.data_bps)):
                var bp = self.data_bps[bi].copy()
                var hit = False
                if addr.byte_length() > 0 and bp.address.byte_length() > 0:
                    hit = addr == bp.address
                elif nd.name.byte_length() > 0 and bp.name == nd.name:
                    hit = True
                if hit:
                    line_str = format_varnode_with_watchpoint(nd, bp)
                    break
            out.append(line_str)
            self.rows_kind.append(VK_VAR)
            self.rows_index.append(k)
        return out^
