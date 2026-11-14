"""Interactive `# %%` code cells ("Terminal Notebook" mode) for Mojo and Python.

Splits an editor buffer on `# %% [title]` markers and synthesizes a self-contained
runner source for any target cell so imports, structs, helper functions, and top-level
bindings from earlier cells remain in scope while only the active cell's output prints.
"""
from std.collections import List
from buffer import TextBuffer
from util import to_str


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
