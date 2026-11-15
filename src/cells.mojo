"""Interactive `# %%` code cells ("Terminal Notebook" mode) for Mojo and Python.

Provides:
- `# %% [title]` cell parsing (`parse_cells`, `cell_at_row`)
- Persistent kernel wire framing & output/error line-remapping for `mojo repl` and `python3`
- Cumulative standalone runner synthesis (`build_cell_runner_source`, `build_cell_runner_mapped`)
  with full FD-level stdout suppression for prior Mojo & Python cells
- Live Mojo `# %%` notebook virtualization (`NotebookVirtualDoc`) for `mojo-lsp-server`
- Outline symbol integration (`scan_outline_with_cells`) and folding (`CellFoldState`)
"""
from std.collections import List
from std.python import Python, PythonObject
from buffer import TextBuffer
from outline import scan_outline, SK_STRUCT, SK_CELL
from util import decode, to_str, is_digit, slice_str

comptime CELL_SUCCESS = 0
comptime CELL_ERROR = 1
comptime CELL_INTERRUPTED = 2
comptime CELL_SK_STRUCT = SK_STRUCT
comptime CELL_SK_CELL = SK_CELL

comptime PYTHON_CELL_DAEMON_SCRIPT = (
    "import os as __tm_os, sys as __tm_sys, traceback as __tm_tb\n"
    "__tm_os.environ.setdefault('MPLBACKEND', 'Agg')\n"
    "__tm_ns = {'__name__': '__main__'}\n"
    "__tm_failed = -1\n"
    "while True:\n"
    "    __tm_hdr = __tm_sys.stdin.readline()\n"
    "    if not __tm_hdr:\n"
    "        break\n"
    "    if not (__tm_hdr.startswith('__TM_RUN__ ') or __tm_hdr.startswith('__TM_PRE__ ')):\n"
    "        continue\n"
    "    __tm_is_pre = __tm_hdr.startswith('__TM_PRE__ ')\n"
    "    __tm_parts = __tm_hdr.rstrip('\\r\\n').split(' ', 4)\n"
    "    __tm_seq = int(__tm_parts[1])\n"
    "    __tm_n = int(__tm_parts[2])\n"
    "    __tm_off = int(__tm_parts[3])\n"
    "    __tm_fp = __tm_parts[4] if len(__tm_parts) > 4 else '<cell>'\n"
    "    __tm_lns = [__tm_sys.stdin.readline() for _ in range(__tm_n)]\n"
    "    if __tm_seq == __tm_failed:\n"
    "        continue\n"
    "    __tm_src = ('\\n' * __tm_off) + ''.join(__tm_lns)\n"
    "    __tm_ns['__file__'] = __tm_fp\n"
    "    if __tm_is_pre:\n"
    "        __tm_saved = __tm_sys.stdout\n"
    "        __tm_devnull = open(__tm_os.devnull, 'w')\n"
    "        __tm_err = ''\n"
    "        try:\n"
    "            __tm_sys.stdout = __tm_devnull\n"
    "            exec(compile(__tm_src, __tm_fp, 'exec'), __tm_ns)\n"
    "        except BaseException:\n"
    "            __tm_err = __tm_tb.format_exc()\n"
    "        finally:\n"
    "            __tm_sys.stdout = __tm_saved\n"
    "            __tm_devnull.close()\n"
    "        if __tm_err:\n"
    "            __tm_failed = __tm_seq\n"
    "            __tm_sys.stdout.write(__tm_err + f'\\n__TM_PRE_ERR_{__tm_seq}__\\n__TM_CELL_END_{__tm_seq}_1__\\n')\n"
    "            __tm_sys.stdout.flush()\n"
    "        continue\n"
    "    __tm_st = 0\n"
    "    try:\n"
    "        exec(compile(__tm_src, __tm_fp, 'exec'), __tm_ns)\n"
    "        if 'matplotlib.pyplot' in __tm_sys.modules:\n"
    "            __tm_plt = __tm_sys.modules['matplotlib.pyplot']\n"
    "            for __tm_fn in list(__tm_plt.get_fignums()):\n"
    "                __tm_fig = __tm_plt.figure(__tm_fn)\n"
    "                __tm_pp = f'{__tm_os.environ.get(\"TMPDIR\", \"/tmp\")}/turbomojo-plot-{__tm_os.getpid()}-{__tm_seq}-{__tm_fn}.png'\n"
    "                __tm_fig.savefig(__tm_pp, dpi=100, bbox_inches='tight')\n"
    "                __tm_sys.stdout.write(f'\\n__TM_PLOT__ {__tm_pp}\\n')\n"
    "            __tm_plt.close('all')\n"
    "    except BaseException:\n"
    "        __tm_st = 1\n"
    "        __tm_tb.print_exc(file=__tm_sys.stdout)\n"
    "    __tm_sys.stdout.write(f'\\n__TM_CELL_END_{__tm_seq}_{__tm_st}__\\n')\n"
    "    __tm_sys.stdout.flush()\n"
)


@fieldwise_init
struct CodeCell(Copyable, Movable):
    var index: Int
    var title: String
    var header_row: Int
    var start_row: Int
    var end_row: Int


@fieldwise_init
struct CellRunnerMapped(Copyable, Movable):
    var source: String
    var line_map: List[Int]


struct NotebookVirtualDoc(Copyable, Movable):
    var active: Bool
    var text: String
    var v2b_row: List[Int]
    var v2b_col: List[Int]
    var b2v_row: List[Int]
    var b2v_col: List[Int]

    def __init__(out self):
        self.active = False
        self.text = ""
        self.v2b_row = List[Int]()
        self.v2b_col = List[Int]()
        self.b2v_row = List[Int]()
        self.b2v_col = List[Int]()


def is_cell_marker_str(s: String) -> Bool:
    var t = String(s.lstrip())
    return (
        t == "# %%"
        or t.startswith("# %% ")
        or t.startswith("# %%\t")
        or t == "#%%"
        or t.startswith("#%% ")
        or t.startswith("#%%\t")
    )


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
        or trimmed.startswith("fn ")
        or trimmed.startswith("__extension ")
    ):
        return True
    if trimmed.startswith("comptime ") or trimmed.startswith("alias "):
        if (
            trimmed.startswith("comptime if ")
            or trimmed.startswith("comptime for ")
            or trimmed.startswith("comptime assert")
        ):
            return False
        return True
    return False


def _advance_triple_quote(ln: String, in_doc: Int) -> Int:
    var cps = decode(ln)
    var n = len(cps)
    var cur = in_doc
    var q = 0
    while q + 2 < n:
        var c = cps[q]
        if cur == 0 and c == 35:
            break
        if (c == 34 or c == 39) and cps[q + 1] == c and cps[q + 2] == c and (cur == 0 or cur == c):
            cur = c if cur == 0 else 0
            q += 3
        else:
            q += 1
    return cur


def is_mojo_notebook(buf: TextBuffer) -> Bool:
    """Return True iff `buf` has at least one `# %%` marker AND at least one bare top-level
    executable statement (which standard `mojo-lsp-server` file-scope parsing rejects)."""
    var n = buf.count()
    var has_marker = False
    var has_top_stmt = False
    var in_doc = 0
    var in_paren_import = False
    var after_decorator = False
    for r in range(n):
        var ln = to_str(buf.line(r))
        var started_in_doc = in_doc != 0
        in_doc = _advance_triple_quote(ln, in_doc)
        if started_in_doc:
            continue
        if is_cell_marker_str(ln):
            has_marker = True
            continue
        var tr = String(ln.strip())
        if tr.byte_length() == 0 or tr.startswith("#"):
            continue
        if in_paren_import:
            if ln.find(")") >= 0:
                in_paren_import = False
            continue
        var ind = _leading_spaces(ln)
        if ind > 0:
            after_decorator = False
            continue
        if tr.startswith("@"):
            after_decorator = True
            continue
        if after_decorator:
            after_decorator = False
            continue
        if tr.startswith("import ") or tr.startswith("from "):
            if ln.find("(") >= 0 and ln.find(")") < 0:
                in_paren_import = True
            continue
        if _is_mojo_top_decl(tr):
            continue
        has_top_stmt = True
    return has_marker and has_top_stmt


def build_mojo_notebook_virtual_doc(buf: TextBuffer) -> NotebookVirtualDoc:
    """Synthesize a valid Mojo module for `mojo-lsp-server` from a `# %%` notebook buffer,
    recording exact bidirectional `(row, col)` mappings between buffer and virtual source."""
    var vdoc = NotebookVirtualDoc()
    var n = buf.count()
    for _ in range(n):
        vdoc.b2v_row.append(-1)
        vdoc.b2v_col.append(0)
    if not is_mojo_notebook(buf):
        return vdoc^
    vdoc.active = True
    var cells = parse_cells(buf)
    var decl_lines = List[String]()
    var decl_rows = List[Int]()
    var stmt_lines = List[String]()
    var stmt_rows = List[Int]()
    var stmt_cols = List[Int]()

    for ci in range(len(cells)):
        var c = cells[ci].copy()
        var lines = List[String]()
        var rows = List[Int]()
        for r in range(c.start_row, c.end_row + 1):
            if r == c.header_row:
                continue
            lines.append(to_str(buf.line(r)))
            rows.append(r)
        var i = 0
        var m = len(lines)
        while i < m:
            var ln = lines[i]
            var br = rows[i]
            var tr = String(ln.strip())
            if tr.byte_length() == 0 or tr.startswith("#"):
                i += 1
                continue
            var ind = _leading_spaces(ln)
            if ind == 0 and (tr.startswith("import ") or tr.startswith("from ")):
                decl_lines.append(ln)
                decl_rows.append(br)
                i += 1
                if ln.find("(") >= 0 and ln.find(")") < 0:
                    while i < m:
                        decl_lines.append(lines[i])
                        decl_rows.append(rows[i])
                        if lines[i].find(")") >= 0:
                            i += 1
                            break
                        i += 1
                continue
            if ind == 0 and (tr.startswith("@") or _is_mojo_top_decl(tr)):
                var block_l = List[String]()
                var block_r = List[Int]()
                while i < m and String(lines[i].strip()).startswith("@"):
                    block_l.append(lines[i])
                    block_r.append(rows[i])
                    i += 1
                if i < m:
                    var head = lines[i]
                    var head_tr = String(head.strip())
                    block_l.append(head)
                    block_r.append(rows[i])
                    i += 1
                    var doc_st = _advance_triple_quote(head, 0)
                    if head_tr.endswith(":") or doc_st != 0:
                        while i < m:
                            var bl = lines[i]
                            var btr = String(bl.strip())
                            var was_doc = doc_st != 0
                            doc_st = _advance_triple_quote(bl, doc_st)
                            if was_doc or doc_st != 0 or btr.byte_length() == 0 or _leading_spaces(bl) > 0:
                                block_l.append(bl)
                                block_r.append(rows[i])
                                i += 1
                            else:
                                break
                    if head_tr.startswith("def main(") or head_tr.startswith("def main ("):
                        for bi in range(1, len(block_l)):
                            var body_ln = block_l[bi]
                            if body_ln.startswith("    "):
                                stmt_lines.append(String(body_ln[byte=4:]))
                                stmt_rows.append(block_r[bi])
                                stmt_cols.append(0)
                            elif String(body_ln.strip()).byte_length() > 0:
                                stmt_lines.append(String(body_ln.lstrip()))
                                stmt_rows.append(block_r[bi])
                                stmt_cols.append(4)
                    else:
                        for bi in range(len(block_l)):
                            decl_lines.append(block_l[bi])
                            decl_rows.append(block_r[bi])
                        decl_lines.append("")
                        decl_rows.append(-1)
                continue
            # Top-level executable statement (and any indented block/multiline continuation)
            stmt_lines.append(ln)
            stmt_rows.append(br)
            stmt_cols.append(4)
            var doc_st2 = _advance_triple_quote(ln, 0)
            i += 1
            if tr.endswith(":") or doc_st2 != 0:
                while i < m:
                    var sl = lines[i]
                    var str_s = String(sl.strip())
                    var was_doc2 = doc_st2 != 0
                    doc_st2 = _advance_triple_quote(sl, doc_st2)
                    if was_doc2 or doc_st2 != 0 or str_s.byte_length() == 0 or _leading_spaces(sl) > ind:
                        stmt_lines.append(sl)
                        stmt_rows.append(rows[i])
                        stmt_cols.append(4)
                        i += 1
                    else:
                        break

    var out_lines = List[String]()
    for k in range(len(decl_lines)):
        var vr = len(out_lines)
        var br = decl_rows[k]
        out_lines.append(decl_lines[k])
        vdoc.v2b_row.append(br)
        vdoc.v2b_col.append(0)
        if br >= 0 and br < n:
            vdoc.b2v_row[br] = vr
            vdoc.b2v_col[br] = 0
    out_lines.append("def __tm_notebook__() raises:")
    vdoc.v2b_row.append(-1)
    vdoc.v2b_col.append(0)
    if len(stmt_lines) == 0:
        out_lines.append("    pass")
        vdoc.v2b_row.append(-1)
        vdoc.v2b_col.append(0)
    else:
        for k in range(len(stmt_lines)):
            var vr = len(out_lines)
            var br = stmt_rows[k]
            var c_off = stmt_cols[k]
            var st = stmt_lines[k]
            if String(st.strip()).byte_length() == 0:
                out_lines.append("")
            else:
                out_lines.append("    " + st)
            vdoc.v2b_row.append(br)
            vdoc.v2b_col.append(c_off)
            if br >= 0 and br < n:
                vdoc.b2v_row[br] = vr
                vdoc.b2v_col[br] = c_off
    vdoc.text = "\n".join(out_lines) + "\n"
    return vdoc^


def build_cell_runner_mapped(
    buf: TextBuffer, cells: List[CodeCell], target_idx: Int, is_python: Bool
) -> CellRunnerMapped:
    """Synthesize runnable `.mojo` or `.py` source executing `cells[target_idx]` with
    declarations and state from `cells[0 .. target_idx - 1]` in scope, suppressing ALL
    stdout from prior cells and returning a 0-based buffer `line_map` per generated line."""
    var empty_map = List[Int]()
    if target_idx < 0 or target_idx >= len(cells):
        return CellRunnerMapped("", empty_map^)
    var out_lines = List[String]()
    var lmap = List[Int]()
    if is_python:
        if target_idx > 0:
            out_lines.append("import os as __tm_os, sys as __tm_sys")
            lmap.append(-1)
            out_lines.append("__tm_stdout = __tm_sys.stdout")
            lmap.append(-1)
            out_lines.append("__tm_sys.stdout = open(__tm_os.devnull, 'w')")
            lmap.append(-1)
            for ci in range(target_idx):
                var c = cells[ci].copy()
                if c.header_row >= 0 and c.start_row == c.header_row:
                    continue
                for r in range(c.start_row, c.end_row + 1):
                    if r == c.header_row:
                        continue
                    out_lines.append(to_str(buf.line(r)))
                    lmap.append(r)
            out_lines.append("__tm_sys.stdout.close()")
            lmap.append(-1)
            out_lines.append("__tm_sys.stdout = __tm_stdout")
            lmap.append(-1)
        var tc = cells[target_idx].copy()
        for r in range(tc.start_row, tc.end_row + 1):
            if r == tc.header_row:
                continue
            out_lines.append(to_str(buf.line(r)))
            lmap.append(r)
        return CellRunnerMapped("\n".join(out_lines) + "\n", lmap^)

    # Mojo 1.2 cell runner: hoist imports & top-level declarations, redirect FD 1 for prior
    # cells so loops/helper calls in cells[0 .. target_idx - 1] never leak stdout.
    var decls = List[String]()
    var decl_rows = List[Int]()
    var prior_stmts = List[String]()
    var prior_rows = List[Int]()
    var target_stmts = List[String]()
    var target_rows = List[Int]()

    for ci in range(target_idx + 1):
        var c = cells[ci].copy()
        var lines = List[String]()
        var rows = List[Int]()
        for r in range(c.start_row, c.end_row + 1):
            if r == c.header_row:
                continue
            lines.append(to_str(buf.line(r)))
            rows.append(r)
        var i = 0
        var m = len(lines)
        while i < m:
            var ln = lines[i]
            var br = rows[i]
            var tr = String(ln.strip())
            if tr.byte_length() == 0 or tr.startswith("#"):
                i += 1
                continue
            var ind = _leading_spaces(ln)
            if ind == 0 and (tr.startswith("import ") or tr.startswith("from ")):
                decls.append(ln)
                decl_rows.append(br)
                i += 1
                if ln.find("(") >= 0 and ln.find(")") < 0:
                    while i < m:
                        decls.append(lines[i])
                        decl_rows.append(rows[i])
                        if lines[i].find(")") >= 0:
                            i += 1
                            break
                        i += 1
                continue
            if ind == 0 and (tr.startswith("@") or _is_mojo_top_decl(tr)):
                var block = List[String]()
                var brows = List[Int]()
                while i < m and String(lines[i].strip()).startswith("@"):
                    block.append(lines[i])
                    brows.append(rows[i])
                    i += 1
                if i < m:
                    var head = lines[i]
                    var head_tr = String(head.strip())
                    block.append(head)
                    brows.append(rows[i])
                    i += 1
                    var doc_st = _advance_triple_quote(head, 0)
                    if head_tr.endswith(":") or doc_st != 0:
                        while i < m:
                            var bl = lines[i]
                            var btr = String(bl.strip())
                            var was_doc = doc_st != 0
                            doc_st = _advance_triple_quote(bl, doc_st)
                            if was_doc or doc_st != 0 or btr.byte_length() == 0 or _leading_spaces(bl) > 0:
                                block.append(bl)
                                brows.append(rows[i])
                                i += 1
                            else:
                                break
                    if head_tr.startswith("def main(") or head_tr.startswith("def main ("):
                        if ci == target_idx:
                            for bi in range(1, len(block)):
                                var body_ln = block[bi]
                                if body_ln.startswith("    "):
                                    target_stmts.append(String(body_ln[byte=4:]))
                                    target_rows.append(brows[bi])
                                elif String(body_ln.strip()).byte_length() > 0:
                                    target_stmts.append(String(body_ln.lstrip()))
                                    target_rows.append(brows[bi])
                    else:
                        for bi in range(len(block)):
                            decls.append(block[bi])
                            decl_rows.append(brows[bi])
                        decls.append("")
                        decl_rows.append(-1)
                continue
            var stmt_block = List[String]()
            var srows = List[Int]()
            stmt_block.append(ln)
            srows.append(br)
            var doc_st2 = _advance_triple_quote(ln, 0)
            i += 1
            if tr.endswith(":") or doc_st2 != 0:
                while i < m:
                    var sl = lines[i]
                    var str_s = String(sl.strip())
                    var was_doc2 = doc_st2 != 0
                    doc_st2 = _advance_triple_quote(sl, doc_st2)
                    if was_doc2 or doc_st2 != 0 or str_s.byte_length() == 0 or _leading_spaces(sl) > ind:
                        stmt_block.append(sl)
                        srows.append(rows[i])
                        i += 1
                    else:
                        break
            if ci < target_idx:
                if len(stmt_block) == 1 and tr.startswith("print("):
                    continue
                for si in range(len(stmt_block)):
                    prior_stmts.append(stmt_block[si])
                    prior_rows.append(srows[si])
            else:
                for si in range(len(stmt_block)):
                    target_stmts.append(stmt_block[si])
                    target_rows.append(srows[si])

    if len(prior_stmts) > 0:
        out_lines.append("from std.ffi import external_call as __tm_ext_call")
        lmap.append(-1)
    for k in range(len(decls)):
        out_lines.append(decls[k])
        lmap.append(decl_rows[k])
    out_lines.append("")
    lmap.append(-1)
    out_lines.append("def main() raises:")
    lmap.append(cells[target_idx].start_row)
    if len(prior_stmts) == 0 and len(target_stmts) == 0:
        out_lines.append("    pass")
        lmap.append(cells[target_idx].start_row)
    else:
        if len(prior_stmts) > 0:
            out_lines.append("    var __tm_devnull = \"/dev/null\"")
            lmap.append(-1)
            out_lines.append("    var __tm_null = __tm_ext_call[\"open\", Int32](__tm_devnull.as_c_string_span(), Int32(1))")
            lmap.append(-1)
            out_lines.append("    var __tm_saved = __tm_ext_call[\"dup\", Int32](Int32(1))")
            lmap.append(-1)
            out_lines.append("    if __tm_null >= 0 and __tm_saved >= 0:")
            lmap.append(-1)
            out_lines.append("        _ = __tm_ext_call[\"dup2\", Int32](__tm_null, Int32(1))")
            lmap.append(-1)
            out_lines.append("        _ = __tm_ext_call[\"close\", Int32](__tm_null)")
            lmap.append(-1)
            for k in range(len(prior_stmts)):
                var pst = prior_stmts[k]
                if String(pst.strip()).byte_length() == 0:
                    out_lines.append("")
                else:
                    out_lines.append("    " + pst)
                lmap.append(prior_rows[k])
            out_lines.append("    if __tm_saved >= 0:")
            lmap.append(-1)
            out_lines.append("        _ = __tm_ext_call[\"dup2\", Int32](__tm_saved, Int32(1))")
            lmap.append(-1)
            out_lines.append("        _ = __tm_ext_call[\"close\", Int32](__tm_saved)")
            lmap.append(-1)
        if len(target_stmts) == 0:
            out_lines.append("    pass")
            lmap.append(cells[target_idx].start_row)
        else:
            for k in range(len(target_stmts)):
                var tst = target_stmts[k]
                if String(tst.strip()).byte_length() == 0:
                    out_lines.append("")
                else:
                    out_lines.append("    " + tst)
                lmap.append(target_rows[k])
    return CellRunnerMapped("\n".join(out_lines) + "\n", lmap^)


def build_cell_runner_source(
    buf: TextBuffer, cells: List[CodeCell], target_idx: Int, is_python: Bool
) -> String:
    """Synthesize runnable `.mojo` or `.py` source executing `cells[target_idx]` with
    declarations and state from `cells[0 .. target_idx - 1]` in scope."""
    return build_cell_runner_mapped(buf, cells, target_idx, is_python).source


def extract_cell_body_text(buf: TextBuffer, cell: CodeCell) -> Tuple[String, Int, Int]:
    """Return `(joined_lines, code_start_row, line_count)` for `cell` (excluding `# %%` header)."""
    if cell.header_row >= 0 and cell.start_row == cell.header_row:
        return ("", cell.start_row, 0)
    var lines = List[String]()
    var first_r = cell.start_row
    var got_first = False
    for r in range(cell.start_row, cell.end_row + 1):
        if r == cell.header_row:
            continue
        if not got_first:
            first_r = r
            got_first = True
        lines.append(to_str(buf.line(r)))
    return ("\n".join(lines), first_r, len(lines))


def format_python_cell_packet(
    buf: TextBuffer, cell: CodeCell, seq: Int, fpath: String, is_preamble: Bool = False
) -> Tuple[String, Int]:
    """Format a length-framed `__TM_RUN__` / `__TM_PRE__` packet for `PYTHON_CELL_DAEMON_SCRIPT`."""
    var body = extract_cell_body_text(buf, cell)
    var tag = "__TM_PRE__ " if is_preamble else "__TM_RUN__ "
    var clean_fp = fpath.replace("\n", " ").replace("\r", " ")
    if clean_fp.byte_length() == 0:
        clean_fp = "<cell>"
    if body[2] == 0:
        var hdr0 = tag + String(seq) + " 1 " + String(body[1]) + " " + clean_fp + "\npass\n"
        return (hdr0, body[1])
    var hdr = (
        tag
        + String(seq)
        + " "
        + String(body[2])
        + " "
        + String(body[1])
        + " "
        + clean_fp
        + "\n"
        + body[0]
        + "\n"
    )
    return (hdr, body[1])


def format_mojo_repl_packet(
    buf: TextBuffer, cell: CodeCell, seq: Int, is_preamble: Bool = False
) -> Tuple[String, Int]:
    """Format a line-preserving expression + completion sentinel for `mojo repl`.
    Blank lines inside the cell become `#` (or `' '` inside multiline strings) so `mojo repl`
    evaluates the whole cell as one unit while keeping `Expression [N]:line:col` 1-to-1."""
    var sentinel = ("__TM_PRE_END_" if is_preamble else "__TM_CELL_END_") + String(seq) + "__"
    if cell.header_row >= 0 and cell.start_row == cell.header_row:
        return ("print(\"" + sentinel + "\")\n\n", cell.start_row)
    var out_lines = List[String]()
    var first_r = cell.start_row
    var got_first = False
    var in_doc = 0
    var has_non_empty = False
    var defines_main = False
    var calls_main = False
    for r in range(cell.start_row, cell.end_row + 1):
        if r == cell.header_row:
            continue
        if not got_first:
            first_r = r
            got_first = True
        var ln = to_str(buf.line(r))
        var tr = String(ln.strip())
        var was_doc = in_doc != 0
        in_doc = _advance_triple_quote(ln, in_doc)
        if not was_doc and _leading_spaces(ln) == 0:
            if tr.startswith("def main(") or tr.startswith("def main ("):
                defines_main = True
            elif tr == "main()" or tr.startswith("main("):
                calls_main = True
        if tr.byte_length() == 0:
            out_lines.append(" " if (was_doc or in_doc != 0) else "#")
        else:
            if not tr.startswith("#"):
                has_non_empty = True
            out_lines.append(ln)
    if not has_non_empty:
        return ("print(\"" + sentinel + "\")\n\n", first_r)
    if defines_main and not calls_main and not is_preamble:
        out_lines.append("main()")
    var payload = "\n".join(out_lines) + "\n\nprint(\"" + sentinel + "\")\n\n"
    return (payload, first_r)


def _rewrite_mojo_expr_loc(line: String, target_path: String, code_start_row: Int) -> String:
    """Rewrite `[User] error: Expression [k]:L:C: msg` -> `target_path:(code_start_row+L):C: error: msg`."""
    var s = line
    var sev: String
    var expr_pos: Int
    var ep_err = s.find("error: Expression [")
    var ep_warn = s.find("warning: Expression [")
    if ep_err >= 0:
        sev = "error"
        expr_pos = ep_err + 19
    elif ep_warn >= 0:
        sev = "warning"
        expr_pos = ep_warn + 21
    else:
        return s
    var cps = decode(s)
    # Find `]:` after `Expression [`
    var rb = s.find("]:", expr_pos)
    if rb < 0:
        return s
    var rest = String(s[byte=rb + 2:])
    var rcps = decode(rest)
    var n = len(rcps)
    var i = 0
    var lnum = 0
    while i < n and is_digit(rcps[i]):
        lnum = lnum * 10 + (rcps[i] - 48)
        i += 1
    if i == 0 or i >= n or rcps[i] != 58:
        return s
    i += 1
    var col_start = i
    var cnum = 0
    while i < n and is_digit(rcps[i]):
        cnum = cnum * 10 + (rcps[i] - 48)
        i += 1
    if i == col_start or i >= n or rcps[i] != 58:
        return s
    var msg = String(slice_str(rcps, i + 1, n).lstrip())
    var mapped_row = max(1, code_start_row + lnum)
    var loc_name = target_path if target_path.byte_length() > 0 else String("<cell>")
    _ = cps
    return loc_name + ":" + String(mapped_row) + ":" + String(max(1, cnum)) + ": " + sev + ": " + msg


def remap_cell_runner_output(
    raw: String, tmp_path: String, target_path: String, line_map: List[Int]
) -> String:
    """Rewrite `<tmp_path>:<gen_line>:<col>:` compiler diagnostics back to `<target_path>:<buf_line>:<col>:`."""
    if tmp_path.byte_length() == 0 or raw.find(tmp_path) < 0:
        return raw
    var loc_name = target_path if target_path.byte_length() > 0 else String("<cell>")
    var prefix = tmp_path + ":"
    var out_lines = List[String]()
    for ln_slice in raw.split("\n"):
        var ln = String(ln_slice)
        if ln.startswith(prefix):
            var rest = String(ln[byte=prefix.byte_length():])
            var rcps = decode(rest)
            var n = len(rcps)
            var i = 0
            var gl = 0
            while i < n and is_digit(rcps[i]):
                gl = gl * 10 + (rcps[i] - 48)
                i += 1
            if i > 0 and i < n and rcps[i] == 58:
                var mapped = gl
                if gl >= 1 and gl - 1 < len(line_map) and line_map[gl - 1] >= 0:
                    mapped = line_map[gl - 1] + 1
                out_lines.append(loc_name + ":" + String(mapped) + slice_str(rcps, i, n))
                continue
        out_lines.append(ln.replace(tmp_path, loc_name))
    return "\n".join(out_lines)


def _is_lldb_var_dump_line(ln: String) -> Bool:
    """True for LLDB's automatic `(Type) name = ...` post-expression variable summary lines."""
    var lstr = String(ln.lstrip())
    if lstr.startswith("(") and lstr.find(") ") > 1 and lstr.find(" = ") > 2:
        return True
    if lstr == "}" or lstr == "},":
        return True
    return False


def parse_cell_kernel_output(
    raw: String, seq: Int, is_py: Bool, target_path: String, cell_code_start: Int
) -> Tuple[Bool, Int, String, String]:
    """Check whether sentinel for `seq` has arrived in `raw`.
    Returns `(done, status, display_text, badge_preview)`."""
    var norm = raw.replace("\r\n", "\n").replace("\r", "\n")
    if is_py:
        var mk_ok = "__TM_CELL_END_" + String(seq) + "_0__"
        var mk_err = "__TM_CELL_END_" + String(seq) + "_1__"
        var pos = norm.find(mk_ok)
        var st = CELL_SUCCESS
        if pos < 0:
            pos = norm.find(mk_err)
            if pos < 0:
                return (False, CELL_SUCCESS, norm, "")
            st = CELL_ERROR
        var body = String(norm[byte=0:pos])
        body = body.replace("\n__TM_PRE_ERR_" + String(seq) + "__", "")
        while body.endswith("\n"):
            var trimmed_body = String(body[byte=0:body.byte_length() - 1])
            body = trimmed_body
        var preview = String("")
        if st == CELL_ERROR:
            var blines = body.split("\n")
            var k = len(blines) - 1
            while k >= 0:
                var cand = String(blines[k].strip())
                if cand.byte_length() > 0:
                    preview = cand
                    break
                k -= 1
        else:
            preview = String(body.strip())
        return (True, st, body, preview)

    var mk_end = "__TM_CELL_END_" + String(seq) + "__"
    var end_pos = norm.find(mk_end)
    if end_pos < 0:
        return (False, CELL_SUCCESS, norm, "")

    var pre_mk = "__TM_PRE_END_" + String(seq) + "__"
    var pre_pos = norm.find(pre_mk)
    var active_slice = String(norm[byte=0:end_pos])
    var eff_start = cell_code_start
    if pre_pos >= 0 and pre_pos < end_pos:
        var pre_slice = String(norm[byte=0:pre_pos])
        if (
            pre_slice.find("error: Expression [") >= 0
            or pre_slice.find("[User] Unhandled exception") >= 0
        ):
            active_slice = pre_slice
            eff_start = 0
        else:
            var after_pre = pre_pos + pre_mk.byte_length()
            if after_pre < end_pos and norm[byte=after_pre : after_pre + 1] == "\n":
                after_pre += 1
            active_slice = String(norm[byte=after_pre:end_pos])

    var st = CELL_SUCCESS
    var out_lines = List[String]()
    var user_lines = List[String]()
    var dump_lines = List[String]()
    var err_summary = String("")
    var last_err_detail = String("")
    var loc_name = target_path if target_path.byte_length() > 0 else String("<cell>")

    for raw_ln in active_slice.split("\n"):
        var ln = String(raw_ln)
        if ln == "(null)":
            continue
        if ln.find("error: Expression [") >= 0 or ln.find("warning: Expression [") >= 0:
            var rewritten = _rewrite_mojo_expr_loc(ln, loc_name, eff_start)
            if ln.find("error: Expression [") >= 0:
                st = CELL_ERROR
                if err_summary.byte_length() == 0:
                    var eidx = rewritten.find(": error: ")
                    err_summary = String(rewritten[byte=eidx + 9:]) if eidx >= 0 else rewritten
            out_lines.append(rewritten)
            continue
        if ln.find("[User] Unhandled exception caught during execution") >= 0:
            st = CELL_ERROR
            var msg = "Unhandled exception" + ((": " + last_err_detail) if last_err_detail.byte_length() > 0 else String(""))
            if err_summary.byte_length() == 0:
                err_summary = last_err_detail if last_err_detail.byte_length() > 0 else String("Unhandled exception")
            out_lines.append(loc_name + ":" + String(max(1, eff_start + 1)) + ":1: error: " + msg)
            continue
        if String(ln.strip()).startswith("Error:"):
            last_err_detail = String(ln.strip())
        out_lines.append(ln)
        var tr = String(ln.strip())
        if tr.byte_length() > 0:
            if _is_lldb_var_dump_line(ln):
                dump_lines.append(tr)
            else:
                user_lines.append(tr)

    while len(out_lines) > 0 and String(out_lines[len(out_lines) - 1].strip()).byte_length() == 0:
        _ = out_lines.pop()

    var display = "\n".join(out_lines)
    var preview = String("")
    if st == CELL_ERROR:
        preview = err_summary if err_summary.byte_length() > 0 else display
    elif len(user_lines) > 0:
        preview = "\n".join(user_lines)
    elif len(dump_lines) > 0:
        preview = dump_lines[0]
    return (True, st, display, preview)


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


def extract_cell_plots(text: String) -> Tuple[String, List[String]]:
    """Extract `__TM_PLOT__ <png_path>` markers from cell output into `(clean_text, plot_paths)`."""
    var plots = List[String]()
    if text.find("__TM_PLOT__ ") < 0:
        return (text, plots^)
    var out_lines = List[String]()
    for ln_s in text.split("\n"):
        var ln = String(ln_s)
        var tr = String(ln.strip())
        if tr.startswith("__TM_PLOT__ "):
            var pp = String(tr[byte=12:].strip())
            if pp.byte_length() > 0:
                plots.append(pp)
                out_lines.append("[📊 plot saved: " + pp + "]")
        else:
            out_lines.append(ln)
    return ("\n".join(out_lines), plots^)


def format_cell_divider_badge(status: Int, duration_ms: Int, preview: String, plot_count: Int = 0) -> String:
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
    var cps = decode(trimmed)
    if len(cps) > 40:
        trimmed = slice_str(cps, 0, 37) + "…"

    var plot_tag = String("")
    if plot_count == 1:
        plot_tag = "📊 plot | "
    elif plot_count > 1:
        plot_tag = "📊 " + String(plot_count) + " plots | "
    return "[" + mark + " " + String(duration_ms) + "ms | " + plot_tag + trimmed + "]"


@fieldwise_init
struct CellOutlineItem(Copyable, Movable):
    var name: String
    var kind: Int
    var row: Int
    var col: Int
    var depth: Int


def scan_outline_with_cells(buf: TextBuffer) -> List[CellOutlineItem]:
    """Scan outline items from `buf` via `outline.scan_outline`, including `# %%` code cells."""
    var items = List[CellOutlineItem]()
    for it in scan_outline(buf):
        items.append(CellOutlineItem(it.name, it.kind, it.row, it.col, it.depth))
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
                if c.header_row >= 0 and row > c.header_row and row <= c.end_row:
                    return True
        return False

    def apply_to_buffer(self, cells: List[CodeCell], mut buf: TextBuffer):
        for c in cells:
            if c.header_row >= 0:
                _ = buf.set_fold(c.header_row, self.is_folded(c.index))
