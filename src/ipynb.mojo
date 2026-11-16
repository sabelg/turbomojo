"""Jupyter `.ipynb` (nbformat v4) bidirectional converter for TurboMojo `# %%` Terminal Notebooks.

Converts `.ipynb` notebooks into `# %%` / `# %% [markdown]` / `# %% [raw]` text buffers
(auto-detecting Mojo vs Python kernels from `metadata.kernelspec` and `metadata.language_info`),
restores persisted cell `outputs` (`stream`, `execute_result`, `display_data`, `error`, and
base64 `image/png` plots) + `execution_count`, and serializes `# %%` buffers and live cell
outputs back to valid nbformat v4 `.ipynb` JSON while preserving top-level notebook metadata.
"""
from std.collections import List
from json import json_parse, Json, JsonWriter, J_ARR, J_OBJ, J_STR
from util import lower_str, basename, decode, to_str, strip_ansi


@fieldwise_init
struct IpynbCellOutput(Copyable, Movable):
    var code_ordinal: Int
    var header_row: Int
    var execution_count: Int
    var text: String
    var is_error: Bool
    var png_b64: List[String]


struct IpynbDocument(Copyable, Movable):
    var ok: Bool
    var error: String
    var text: String
    var is_mojo: Bool
    var nbformat: Int
    var nbformat_minor: Int
    var outputs: List[IpynbCellOutput]

    def __init__(
        out self,
        ok: Bool,
        error: String,
        text: String,
        is_mojo: Bool,
        nbformat: Int,
        nbformat_minor: Int,
        var outputs: List[IpynbCellOutput] = List[IpynbCellOutput](),
    ):
        self.ok = ok
        self.error = error
        self.text = text
        self.is_mojo = is_mojo
        self.nbformat = nbformat
        self.nbformat_minor = nbformat_minor
        self.outputs = outputs^

    def lang_id(self) -> Int:
        from highlight import HL_MOJO, HL_PYTHON
        return HL_MOJO if self.is_mojo else HL_PYTHON


def is_ipynb_path(path: String) -> Bool:
    if path.byte_length() == 0:
        return False
    return lower_str(basename(path)).endswith(".ipynb")


def ipynb_b64_decode(text: String) -> List[UInt8]:
    """Decode base64 `image/png` payload from `.ipynb` `display_data`."""
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
            continue
        acc = (acc << 6) | v
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append(UInt8((acc >> bits) & 255))
    return out^


def _extract_source(doc: Json, node: Int) -> String:
    var k = doc.kind(node)
    if k == J_STR:
        return doc.str(node, "")
    if k == J_ARR:
        var parts = List[String]()
        for ch in doc.children(node):
            parts.append(doc.str(ch, ""))
        return "".join(parts)
    return ""


def _strip_ansi_str(s: String) -> String:
    if s.find("\x1b") < 0:
        return s
    return to_str(strip_ansi(decode(s)))


def _count_lines_in_block(s: String) -> Int:
    if s.byte_length() == 0:
        return 1
    var n = 1
    for b in s.as_bytes():
        if b == 10:
            n += 1
    return n


def _detect_mojo_kernel(doc: Json, cells_node: Int, default_mojo: Bool = False) -> Bool:
    for p in [
        "metadata/kernelspec/language",
        "metadata/kernelspec/name",
        "metadata/kernelspec/display_name",
        "metadata/language_info/name",
        "metadata/language_info/file_extension",
    ]:
        var val = lower_str(doc.str(doc.path(0, String(p)), ""))
        if val.find("mojo") >= 0 or val.find("🔥") >= 0:
            return True
    var lang_name = lower_str(doc.str(doc.path(0, "metadata/language_info/name"), ""))
    var k_name = lower_str(doc.str(doc.path(0, "metadata/kernelspec/name"), ""))
    if lang_name.find("python") >= 0 or k_name.find("python") >= 0:
        return False
    for c in doc.children(cells_node):
        if doc.str(doc.get(c, "cell_type"), "code") != "code":
            continue
        var src = _extract_source(doc, doc.get(c, "source"))
        if (
            src.find("comptime ") >= 0
            or src.find("@fieldwise_init") >= 0
            or src.find("from std.") >= 0
            or src.find("struct ") >= 0
            or src.find("fn ") >= 0
        ):
            return True
    return default_mojo


def _parse_cell_outputs(
    doc: Json, cell_node: Int, code_ord: Int, hdr_row: Int
) -> Tuple[Bool, IpynbCellOutput]:
    var exec_cnt = doc.int(doc.get(cell_node, "execution_count"), 0)
    var outs_node = doc.get(cell_node, "outputs")
    var pngs = List[String]()
    var chunks = List[String]()
    var is_err = False

    if doc.kind(outs_node) == J_ARR:
        for o in doc.children(outs_node):
            var otype = doc.str(doc.get(o, "output_type"), "")
            if otype == "stream":
                var stxt = _strip_ansi_str(_extract_source(doc, doc.get(o, "text")).replace("\r\n", "\n"))
                while stxt.endswith("\n"):
                    var sub_stxt = String(stxt[byte=0 : stxt.byte_length() - 1])
                    stxt = sub_stxt
                if stxt.byte_length() > 0:
                    chunks.append(stxt)
            elif otype == "execute_result" or otype == "display_data":
                var data_n = doc.get(o, "data")
                if doc.kind(data_n) == J_OBJ:
                    var png_raw = _extract_source(doc, doc.get(data_n, "image/png"))
                    var png_clean = png_raw.replace("\n", "").replace("\r", "").replace(" ", "")
                    if png_clean.byte_length() > 0:
                        pngs.append(png_clean)
                    var plain_raw = _strip_ansi_str(_extract_source(doc, doc.get(data_n, "text/plain")).replace("\r\n", "\n"))
                    while plain_raw.endswith("\n"):
                        var sub_plain = String(plain_raw[byte=0 : plain_raw.byte_length() - 1])
                        plain_raw = sub_plain
                    if plain_raw.byte_length() > 0 and not (png_clean.byte_length() > 0 and plain_raw.startswith("<Figure")):
                        chunks.append(plain_raw)
            elif otype == "error":
                is_err = True
                var ename = doc.str(doc.get(o, "ename"), "Error")
                var evalue = doc.str(doc.get(o, "evalue"), "")
                var tb_node = doc.get(o, "traceback")
                var tb_lines = List[String]()
                if doc.kind(tb_node) == J_ARR:
                    for tl in doc.children(tb_node):
                        var clean_tl = _strip_ansi_str(doc.str(tl, "").replace("\r\n", "\n"))
                        while clean_tl.endswith("\n"):
                            var sub_tl = String(clean_tl[byte=0 : clean_tl.byte_length() - 1])
                            clean_tl = sub_tl
                        if clean_tl.byte_length() > 0:
                            tb_lines.append(clean_tl)
                if len(tb_lines) > 0:
                    chunks.append("\n".join(tb_lines))
                else:
                    chunks.append(ename + ((": " + evalue) if evalue.byte_length() > 0 else String("")))

    var full_out = "\n".join(chunks)
    var has_any = exec_cnt > 0 or full_out.byte_length() > 0 or len(pngs) > 0 or is_err
    return (has_any, IpynbCellOutput(code_ord, hdr_row, exec_cnt, full_out, is_err, pngs^))


def strip_utf8_bom(s: String) -> String:
    """Strip a leading 3-byte UTF-8 BOM (`0xEF 0xBB 0xBF`) if present."""
    var b = s.as_bytes()
    if len(b) >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF:
        return String(s[byte=3:])
    return s


def ipynb_to_percent_text(raw_json: String, default_mojo: Bool = False) -> IpynbDocument:
    """Convert an nbformat v3/v4 `.ipynb` JSON string to `# %%` / `# %% [markdown]` text + cell outputs."""
    var cleaned = strip_utf8_bom(raw_json)
    var stripped = String(cleaned.strip())
    if stripped.byte_length() == 0 or stripped == "{}":
        return IpynbDocument(True, "", "# %%\n\n", default_mojo, 4, 5)
    var doc = json_parse(cleaned)
    if not doc.ok or doc.kind(0) != J_OBJ:
        return IpynbDocument(False, doc.error if doc.error.byte_length() > 0 else "Invalid .ipynb JSON root", "", default_mojo, 4, 5)
    var cells_node = doc.get(0, "cells")
    if doc.kind(cells_node) != J_ARR:
        # nbformat v3 fallback: worksheets[0].cells
        var ws_node = doc.get(0, "worksheets")
        if doc.kind(ws_node) == J_ARR and doc.size(ws_node) > 0:
            cells_node = doc.get(doc.at(ws_node, 0), "cells")
    if doc.kind(cells_node) != J_ARR:
        if doc.size(0) == 0 or (doc.has(0, "metadata") and not doc.has(0, "cells")):
            var is_mj_empty = _detect_mojo_kernel(doc, -1, default_mojo)
            return IpynbDocument(True, "", "# %%\n\n", is_mj_empty, 4, 5)
        return IpynbDocument(False, "Missing 'cells' array in .ipynb", "", default_mojo, 4, 5)

    var nbf = doc.int(doc.get(0, "nbformat"), 4)
    var nbf_min = doc.int(doc.get(0, "nbformat_minor"), 5)
    var is_mj = _detect_mojo_kernel(doc, cells_node, default_mojo)

    var blocks = List[String]()
    var outputs = List[IpynbCellOutput]()
    var cur_row = 0
    var code_ord = 0

    for c in doc.children(cells_node):
        var ctype = doc.str(doc.get(c, "cell_type"), "code")
        var src_node = doc.get(c, "source")
        if src_node < 0:
            src_node = doc.get(c, "input")      # nbformat v3 code cell field
        var src = _extract_source(doc, src_node).replace("\r\n", "\n")
        if src.endswith("\n"):
            var trimmed = String(src[byte=0 : src.byte_length() - 1])
            src = trimmed
        var title = doc.str(doc.path(c, "metadata/title"), doc.str(doc.path(c, "metadata/name"), ""))
        var blk: String
        if ctype == "heading":
            var lvl = max(1, min(6, doc.int(doc.get(c, "level"), 1)))
            var hashes = String("")
            for _ in range(lvl):
                hashes += "#"
            blk = "# %% [markdown]\n# " + hashes + " " + src
        elif ctype == "markdown" or ctype == "raw":
            var hdr = "# %% [" + ctype + "]" + ((" " + title) if title.byte_length() > 0 else String(""))
            var md_lines = List[String]()
            md_lines.append(hdr)
            if src.byte_length() > 0:
                for ln_s in src.split("\n"):
                    var ln = String(ln_s)
                    if ln.byte_length() > 0:
                        md_lines.append("# " + ln)
                    else:
                        md_lines.append("#")
            blk = "\n".join(md_lines)
        else:
            var hdr = String("# %%") + ((" " + title) if title.byte_length() > 0 else String(""))
            blk = (hdr + "\n" + src) if src.byte_length() > 0 else hdr
            var parsed_out = _parse_cell_outputs(doc, c, code_ord, cur_row)
            if parsed_out[0]:
                outputs.append(parsed_out[1].copy())
            code_ord += 1
        blocks.append(blk)
        cur_row += _count_lines_in_block(blk)

    if len(blocks) == 0:
        blocks.append("# %%\n")
    var full = "\n".join(blocks)
    if full.byte_length() > 0 and not full.endswith("\n"):
        full += "\n"
    return IpynbDocument(True, "", full, is_mj, nbf, nbf_min, outputs^)


@fieldwise_init
struct _ParsedPercentCell(Copyable, Movable):
    var cell_type: String
    var title: String
    var lines: List[String]


def _parse_percent_header(line: String) -> Tuple[Bool, String, String]:
    """If `line` is a `# %%` cell header, return `(True, cell_type, title)`."""
    var s = String(line.lstrip())
    if not s.startswith("#"):
        return (False, "", "")
    var after_hash = String(s[byte=1:].lstrip())
    if not after_hash.startswith("%%"):
        return (False, "", "")
    var rest = String(after_hash[byte=2:].strip())
    var low = lower_str(rest)
    if low.startswith("[markdown]") or low.startswith("[md]"):
        var close_b = rest.find("]")
        var t = String(rest[byte=close_b + 1:].strip()) if close_b >= 0 else String("")
        return (True, "markdown", t)
    if low.startswith("[raw]"):
        var close_b = rest.find("]")
        var t = String(rest[byte=close_b + 1:].strip()) if close_b >= 0 else String("")
        return (True, "raw", t)
    return (True, "code", rest)


def _uncomment_markdown_line(line: String) -> String:
    var s = String(line.lstrip())
    if s == "#":
        return ""
    if s.startswith("# "):
        return String(s[byte=2:])
    if s.startswith("#"):
        return String(s[byte=1:])
    return line


def _write_multiline_array(mut w: JsonWriter, key_name: String, text: String):
    w.key(key_name)
    w.begin_arr()
    var lines = List[String]()
    for s in text.split("\n"):
        lines.append(String(s))
    var n = len(lines)
    for i in range(n):
        if i + 1 < n:
            w.str(lines[i] + "\n")
        else:
            w.str(lines[i] + "\n")
    w.end_arr()


def _write_source_array(mut w: JsonWriter, lines: List[String]):
    w.key("source")
    w.begin_arr()
    var n = len(lines)
    for i in range(n):
        if i + 1 < n:
            w.str(lines[i] + "\n")
        else:
            if lines[i].byte_length() > 0 or n > 1:
                w.str(lines[i])
    w.end_arr()


def _write_cell_outputs_json(mut w: JsonWriter, cell_out: IpynbCellOutput):
    w.key("outputs")
    w.begin_arr()
    if cell_out.is_error:
        w.begin_obj()
        w.kv_str("output_type", "error")
        var ename = String("Error")
        var evalue = String("")
        var tb = List[String]()
        for s in cell_out.text.split("\n"):
            tb.append(String(s))
        if len(tb) > 0:
            var last_ln = String(tb[len(tb) - 1].strip())
            var colon = last_ln.find(":")
            if colon > 0 and colon < 48 and last_ln.find(" ") < 0 or (colon > 0 and colon < 40):
                ename = String(last_ln[byte=0:colon].strip())
                evalue = String(last_ln[byte=colon + 1 :].strip())
            else:
                evalue = last_ln
        w.kv_str("ename", ename)
        w.kv_str("evalue", evalue)
        w.key("traceback")
        w.begin_arr()
        for tl in tb:
            w.str(tl)
        w.end_arr()
        w.end_obj()
    elif cell_out.text.byte_length() > 0:
        w.begin_obj()
        w.kv_str("name", "stdout")
        w.kv_str("output_type", "stream")
        _write_multiline_array(w, "text", cell_out.text)
        w.end_obj()

    for b64 in cell_out.png_b64:
        if b64.byte_length() == 0:
            continue
        w.begin_obj()
        w.key("data")
        w.begin_obj()
        w.kv_str("image/png", b64)
        w.key("text/plain")
        w.begin_arr()
        w.str("<Figure>")
        w.end_arr()
        w.end_obj()
        w.key("metadata")
        w.begin_obj()
        w.end_obj()
        w.kv_str("output_type", "display_data")
        w.end_obj()
    w.end_arr()


def percent_text_to_ipynb(
    text: String,
    is_mojo: Bool,
    existing_raw_json: String = "",
    live_outputs: List[IpynbCellOutput] = List[IpynbCellOutput](),
) -> String:
    """Serialize `# %%` / `# %% [markdown]` buffer text and live outputs to nbformat v4 `.ipynb` JSON."""
    var norm = text.replace("\r\n", "\n")
    if norm.endswith("\n"):
        var trimmed = String(norm[byte=0 : norm.byte_length() - 1])
        norm = trimmed

    var cells = List[_ParsedPercentCell]()
    var cur_type = String("code")
    var cur_title = String("")
    var cur_lines = List[String]()
    var seen_header = False

    if norm.byte_length() > 0:
        for ln_s in norm.split("\n"):
            var ln = String(ln_s)
            var hdr = _parse_percent_header(ln)
            if hdr[0]:
                if seen_header:
                    cells.append(_ParsedPercentCell(cur_type, cur_title, cur_lines^))
                else:
                    var has_pre = False
                    for pl in cur_lines:
                        if String(pl.strip()).byte_length() > 0:
                            has_pre = True
                            break
                    if has_pre:
                        cells.append(_ParsedPercentCell("code", "", cur_lines^))
                cur_lines = List[String]()
                cur_type = hdr[1]
                cur_title = hdr[2]
                seen_header = True
            else:
                if seen_header and (cur_type == "markdown" or cur_type == "raw"):
                    cur_lines.append(_uncomment_markdown_line(ln))
                else:
                    cur_lines.append(ln)

    if seen_header or len(cur_lines) > 0:
        cells.append(_ParsedPercentCell(cur_type, cur_title, cur_lines^))

    var prev_clean = strip_utf8_bom(existing_raw_json)
    var prev_doc = json_parse(prev_clean) if prev_clean.byte_length() > 0 else Json()
    var has_prev_meta = (
        prev_clean.byte_length() > 0
        and prev_doc.ok
        and prev_doc.kind(0) == J_OBJ
        and prev_doc.kind(prev_doc.get(0, "metadata")) == J_OBJ
    )
    var prev_nbf = prev_doc.int(prev_doc.get(0, "nbformat"), 4) if has_prev_meta else 4
    var nbf = max(4, prev_nbf)
    var nbf_min = (prev_doc.int(prev_doc.get(0, "nbformat_minor"), 5) if prev_nbf >= 4 else 5) if has_prev_meta else 5

    var w = JsonWriter()
    w.begin_obj()
    w.key("cells")
    w.begin_arr()
    var code_ord = 0
    for idx in range(len(cells)):
        w.begin_obj()
        w.kv_str("cell_type", cells[idx].cell_type)
        w.kv_str("id", "tm-cell-" + String(idx + 1))
        var matched_idx = -1
        if cells[idx].cell_type == "code":
            for oi in range(len(live_outputs)):
                if live_outputs[oi].code_ordinal == code_ord:
                    matched_idx = oi
                    break
            w.key("execution_count")
            if matched_idx >= 0 and live_outputs[matched_idx].execution_count > 0:
                w.int(live_outputs[matched_idx].execution_count)
            else:
                w.null()
        w.key("metadata")
        w.begin_obj()
        if cells[idx].title.byte_length() > 0:
            w.kv_str("name", cells[idx].title)
            w.kv_str("title", cells[idx].title)
        w.end_obj()
        if cells[idx].cell_type == "code":
            if matched_idx >= 0:
                _write_cell_outputs_json(w, live_outputs[matched_idx])
            else:
                w.key("outputs")
                w.begin_arr()
                w.end_arr()
            code_ord += 1
        _write_source_array(w, cells[idx].lines)
        w.end_obj()
    w.end_arr()

    w.key("metadata")
    if has_prev_meta:
        prev_doc.dump_into(prev_doc.get(0, "metadata"), w)
    else:
        w.begin_obj()
        w.key("kernelspec")
        w.begin_obj()
        if is_mojo:
            w.kv_str("display_name", "Mojo")
            w.kv_str("language", "mojo")
            w.kv_str("name", "mojo")
        else:
            w.kv_str("display_name", "Python 3")
            w.kv_str("language", "python")
            w.kv_str("name", "python3")
        w.end_obj()
        w.key("language_info")
        w.begin_obj()
        if is_mojo:
            w.kv_str("file_extension", ".mojo")
            w.kv_str("name", "mojo")
        else:
            w.kv_str("file_extension", ".py")
            w.kv_str("name", "python")
        w.end_obj()
        w.end_obj()

    w.kv_int("nbformat", nbf)
    w.kv_int("nbformat_minor", nbf_min)
    w.end_obj()
    return w.text() + "\n"
