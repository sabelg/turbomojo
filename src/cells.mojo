"""Interactive `# %%` code cells ("Terminal Notebook" mode) for Mojo and Python.

Splits an editor buffer on `# %% [title]` markers and synthesizes a self-contained
runner source for any target cell so imports, structs, helper functions, and top-level
bindings from earlier cells remain in scope while only the active cell's output prints.
"""
from std.collections import List
from std.python import Python, PythonObject
from buffer import TextBuffer
from util import decode, to_str, is_ident

comptime CELL_SUCCESS = 0
comptime CELL_ERROR = 1
comptime CELL_INTERRUPTED = 2
comptime CELL_SK_STRUCT = 23
comptime CELL_SK_CELL = 26


@fieldwise_init
struct CodeCell(Copyable, Movable):
    var index: Int
    var title: String
    var header_row: Int
    var start_row: Int
    var end_row: Int


def is_cell_marker_str(s: String) -> Bool:
    var t = String(s.lstrip())
    return t == "# %%" or t.startswith("# %% ") or t.startswith("# %%\t") or t == "#%%" or t.startswith("#%% ")


def cell_marker_title(s: String, fallback_num: Int) -> String:
    var t = String(s.lstrip())
    var rest = String("")
    if t.startswith("# %%"):
        rest = String(t[byte=4:].strip())
    elif t.startswith("#%%"):
        rest = String(t[byte=3:].strip())
    if rest.byte_length() > 0:
        return rest
    return "Cell " + String(fallback_num)


def parse_cells(buf: TextBuffer) -> List[CodeCell]:
    """Parse `# %%` cells in `buf`. Buffers with no markers form a single whole-buffer cell."""
    var out = List[CodeCell]()
    var n = buf.count()
    if n <= 0:
        return out^
    var markers = List[Int]()
    var titles = List[String]()
    for r in range(n):
        var s = to_str(buf.line(r))
        if is_cell_marker_str(s):
            markers.append(r)
            titles.append(cell_marker_title(s, len(markers)))
    if len(markers) == 0:
        out.append(CodeCell(0, "Cell 1", -1, 0, n - 1))
        return out^
    var idx = 0
    if markers[0] > 0:
        var has_pre = False
        for r in range(markers[0]):
            if String(to_str(buf.line(r)).strip()).byte_length() > 0:
                has_pre = True
                break
        if has_pre:
            out.append(CodeCell(idx, "Preamble", -1, 0, markers[0] - 1))
            idx += 1
    for m in range(len(markers)):
        var hr = markers[m]
        var sr = min(hr + 1, n - 1)
        var er = (markers[m + 1] - 1) if m + 1 < len(markers) else (n - 1)
        if er < sr:
            er = sr
        out.append(CodeCell(idx, titles[m], hr, sr, er))
        idx += 1
    return out^


def cell_at_row(cells: List[CodeCell], row: Int) -> Int:
    """Return index in `cells` containing 0-based `row` (or 0 if before first marker)."""
    if len(cells) == 0:
        return -1
    for i in range(len(cells)):
        if cells[i].header_row == row:
            return i
        if row >= cells[i].start_row and row <= cells[i].end_row:
            return i
    return 0


def _leading_spaces(s: String) -> Int:
    var bs = s.as_bytes()
    var k = 0
    while k < len(bs):
        if bs[k] == 32:
            k += 1
        elif bs[k] == 9:
            k += 4
        else:
            break
    return k


def _is_mojo_top_decl(trimmed: String) -> Bool:
    if (
        trimmed.startswith("struct ")
        or trimmed.startswith("trait ")
        or trimmed.startswith("def ")
        or trimmed.startswith("__extension ")
    ):
        return True
    if trimmed.startswith("comptime "):
        if (
            trimmed.startswith("comptime if ")
            or trimmed.startswith("comptime for ")
            or trimmed.startswith("comptime assert")
        ):
            return False
        return True
    return False


def build_cell_runner_source(
    buf: TextBuffer, cells: List[CodeCell], target_idx: Int, is_python: Bool
) -> String:
    """Synthesize runnable `.mojo` or `.py` source executing `cells[target_idx]` with
    declarations and state from `cells[0 .. target_idx - 1]` in scope."""
    if target_idx < 0 or target_idx >= len(cells):
        return ""
    if is_python:
        var py = String("")
        if target_idx > 0:
            py += "import os as __tm_os, sys as __tm_sys\n"
            py += "__tm_stdout = __tm_sys.stdout\n"
            py += "__tm_sys.stdout = open(__tm_os.devnull, 'w')\n"
            for ci in range(target_idx):
                var c = cells[ci].copy()
                if c.header_row >= 0 and c.start_row == c.header_row:
                    continue
                for r in range(c.start_row, c.end_row + 1):
                    if r == c.header_row:
                        continue
                    py += to_str(buf.line(r)) + "\n"
            py += "__tm_sys.stdout.close()\n"
            py += "__tm_sys.stdout = __tm_stdout\n"
        var tc = cells[target_idx].copy()
        for r in range(tc.start_row, tc.end_row + 1):
            if r == tc.header_row:
                continue
            py += to_str(buf.line(r)) + "\n"
        return py

    # Mojo 1.2 cell runner: hoist imports & top-level declarations, wrap statements in `def main() raises:`
    var decls = List[String]()
    var stmts = List[String]()
    for ci in range(target_idx + 1):
        var c = cells[ci].copy()
        var lines = List[String]()
        for r in range(c.start_row, c.end_row + 1):
            if r == c.header_row:
                continue
            lines.append(to_str(buf.line(r)))
        var i = 0
        var m = len(lines)
        while i < m:
            var ln = lines[i]
            var tr = String(ln.strip())
            if tr.byte_length() == 0 or tr.startswith("#"):
                i += 1
                continue
            var ind = _leading_spaces(ln)
            if ind == 0 and (tr.startswith("import ") or tr.startswith("from ")):
                decls.append(ln)
                i += 1
                # Multi-line parenthesized import continuation
                if ln.find("(") >= 0 and ln.find(")") < 0:
                    while i < m:
                        decls.append(lines[i])
                        if lines[i].find(")") >= 0:
                            i += 1
                            break
                        i += 1
                continue
            if ind == 0 and (tr.startswith("@") or _is_mojo_top_decl(tr)):
                var block = List[String]()
                # Collect any leading `@decorator` lines
                while i < m and String(lines[i].strip()).startswith("@"):
                    block.append(lines[i])
                    i += 1
                if i < m:
                    var head = lines[i]
                    var head_tr = String(head.strip())
                    block.append(head)
                    i += 1
                    if head_tr.endswith(":"):
                        while i < m:
                            var bl = lines[i]
                            var btr = String(bl.strip())
                            if btr.byte_length() == 0:
                                block.append(bl)
                                i += 1
                                continue
                            if _leading_spaces(bl) > 0:
                                block.append(bl)
                                i += 1
                            else:
                                break
                    if head_tr.startswith("def main(") or head_tr.startswith("def main ("):
                        if ci == target_idx:
                            # Unwrap `def main` body into active statements
                            for bi in range(1, len(block)):
                                var body_ln = block[bi]
                                if body_ln.startswith("    "):
                                    stmts.append(String(body_ln[byte=4:]))
                                elif String(body_ln.strip()).byte_length() > 0:
                                    stmts.append(String(body_ln.lstrip()))
                    else:
                        for bln in block:
                            decls.append(bln)
                        decls.append("")
                continue
            # Executable top-level statement (plus any indented body if it opens a block)
            var stmt_block = List[String]()
            stmt_block.append(ln)
            i += 1
            if tr.endswith(":"):
                while i < m:
                    var sl = lines[i]
                    var str_s = String(sl.strip())
                    if str_s.byte_length() == 0:
                        stmt_block.append(sl)
                        i += 1
                        continue
                    if _leading_spaces(sl) > ind:
                        stmt_block.append(sl)
                        i += 1
                    else:
                        break
            if ci < target_idx and len(stmt_block) == 1 and tr.startswith("print("):
                continue
            for sln in stmt_block:
                stmts.append(sln)

    var out = String("")
    for d in decls:
        out += d + "\n"
    out += "\ndef main() raises:\n"
    if len(stmts) == 0:
        out += "    pass\n"
    else:
        for st in stmts:
            if String(st.strip()).byte_length() == 0:
                out += "\n"
            else:
                out += "    " + st + "\n"
    return out


struct CellResult(Copyable, Movable):
    var status: Int
    var output: String
    var error: String
    var duration_ms: Int

    def __init__(out self, status: Int, output: String, error: String, duration_ms: Int = 0):
        self.status = status
        self.output = output
        self.error = error
        self.duration_ms = duration_ms


struct CellKernel(Movable):
    var session_id: Int
    var is_alive_flag: Bool
    var namespace: PythonObject
    var builtins: PythonObject
    var io: PythonObject
    var sys: PythonObject

    def __init__(out self) raises:
        self.session_id = 1
        self.is_alive_flag = True
        self.builtins = Python.import_module("builtins")
        self.io = Python.import_module("io")
        self.sys = Python.import_module("sys")
        self.namespace = Python.dict()

    def is_alive(self) -> Bool:
        return self.is_alive_flag

    def execute(mut self, code: String) -> CellResult:
        if not self.is_alive_flag:
            return CellResult(CELL_ERROR, "", "Kernel is dead", 0)

        var f: PythonObject
        var old_out: PythonObject
        try:
            f = self.io.StringIO()
            old_out = self.sys.stdout
            self.sys.stdout = f
        except e:
            return CellResult(CELL_ERROR, "", String(e), 0)

        var err_str = String("")
        var status = CELL_SUCCESS
        try:
            _ = self.builtins.exec(code, self.namespace)
        except e:
            status = CELL_ERROR
            err_str = String(e)

        var out_str = String("")
        try:
            self.sys.stdout = old_out
            out_str = String(f.getvalue())
        except _:
            pass

        return CellResult(status, out_str, err_str, 5)

    def restart(mut self) raises:
        self.session_id += 1
        self.namespace = Python.dict()
        self.is_alive_flag = True

    def interrupt(mut self) -> CellResult:
        return CellResult(CELL_INTERRUPTED, "", "KeyboardInterrupt", 1)


def format_cell_divider_badge(status: Int, duration_ms: Int, preview: String) -> String:
    """Format inline divider badge: [✓ <ms>ms | <preview>] or [✗ <ms>ms | <err>]."""
    var mark = "✓" if status == CELL_SUCCESS else "✗"
    var clean_prev = String(preview.strip())

    var prev_single = String("")
    for c in decode(clean_prev):
        if c == 10 or c == 13:
            prev_single += " "
        else:
            var l = List[Int]()
            l.append(c)
            prev_single += to_str(l)

    var trimmed = String(prev_single.strip())
    if trimmed.byte_length() > 40:
        var head = trimmed[byte=0:37]
        trimmed = String(head) + "…"

    return "[" + mark + " " + String(duration_ms) + "ms | " + trimmed + "]"


@fieldwise_init
struct CellOutlineItem(Copyable, Movable):
    var name: String
    var kind: Int
    var row: Int
    var col: Int
    var depth: Int


def scan_outline_with_cells(buf: TextBuffer) -> List[CellOutlineItem]:
    """Scan outline items from buffer, including # %% code cells as structural symbols."""
    var items = List[CellOutlineItem]()
    var n_lines = buf.count()
    for r in range(n_lines):
        var line = buf.line(r)
        var n = len(line)
        var ind = 0
        while ind < n and line[ind] == 32:
            ind += 1
        if ind == n or line[ind] == 35:
            continue
        var rest = List[Int]()
        for k in range(ind, min(n, ind + 16)):
            rest.append(line[k])
        var text = to_str(rest)
        var kind = 0
        var skip = 0
        if text.startswith("def "):
            kind = 12
            skip = 4
        elif text.startswith("struct "):
            kind = CELL_SK_STRUCT
            skip = 7
        elif text.startswith("__extension "):
            kind = CELL_SK_STRUCT
            skip = 12
        elif text.startswith("trait "):
            kind = 11
            skip = 6
        elif text.startswith("comptime ") and ind == 0:
            kind = 14
            skip = 9
        if kind == 0:
            continue
        var s0 = ind + skip
        while s0 < n and line[s0] == 32:
            s0 += 1
        var e = s0
        while e < n and is_ident(line[e]):
            e += 1
        if e == s0:
            continue
        var nm = List[Int]()
        for k in range(s0, e):
            nm.append(line[k])
        items.append(CellOutlineItem(to_str(nm), kind, r, s0, 0))
    var cells = parse_cells(buf)
    for c in cells:
        if c.header_row >= 0:
            items.append(CellOutlineItem(c.title, CELL_SK_CELL, c.header_row, 0, 0))
    return items^


struct CellFoldState(Copyable, Movable):
    var folded_cells: List[Int]

    def __init__(out self):
        self.folded_cells = List[Int]()

    def set_fold(mut self, cell_index: Int, on: Bool):
        var idx = -1
        for i in range(len(self.folded_cells)):
            if self.folded_cells[i] == cell_index:
                idx = i
                break
        if on and idx < 0:
            self.folded_cells.append(cell_index)
        elif not on and idx >= 0:
            _ = self.folded_cells.pop(idx)

    def is_folded(self, cell_index: Int) -> Bool:
        for i in range(len(self.folded_cells)):
            if self.folded_cells[i] == cell_index:
                return True
        return False

    def is_row_hidden(self, cells: List[CodeCell], row: Int) -> Bool:
        for c in cells:
            if self.is_folded(c.index):
                if row > c.header_row and row <= c.end_row:
                    return True
        return False
