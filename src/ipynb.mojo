"""Jupyter `.ipynb` (nbformat v4) bidirectional converter for TurboMojo `# %%` Terminal Notebooks.

Converts `.ipynb` notebooks into `# %%` / `# %% [markdown]` / `# %% [raw]` text buffers
(auto-detecting Mojo vs Python kernels from `metadata.kernelspec` and `metadata.language_info`)
and serializes `# %%` buffers back to valid nbformat v4 `.ipynb` JSON while preserving
top-level notebook metadata.
"""
from std.collections import List
from json import json_parse, Json, JsonWriter, J_ARR, J_OBJ, J_STR
from util import lower_str, basename
from highlight import HL_MOJO, HL_PYTHON


@fieldwise_init
struct IpynbDocument(Copyable, Movable):
    var ok: Bool
    var error: String
    var text: String
    var is_mojo: Bool
    var nbformat: Int
    var nbformat_minor: Int

    def lang_id(self) -> Int:
        return HL_MOJO if self.is_mojo else HL_PYTHON


def is_ipynb_path(path: String) -> Bool:
    if path.byte_length() == 0:
        return False
    return lower_str(basename(path)).endswith(".ipynb")


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


def _detect_mojo_kernel(doc: Json, cells_node: Int) -> Bool:
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
    # Heuristic fallback when metadata is empty: look for Mojo-specific syntax in code cells
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
    return False


def ipynb_to_percent_text(raw_json: String) -> IpynbDocument:
    """Convert an nbformat v4 `.ipynb` JSON string to `# %%` / `# %% [markdown]` text."""
    var doc = json_parse(raw_json)
    if not doc.ok or doc.kind(0) != J_OBJ:
        return IpynbDocument(False, doc.error if doc.error.byte_length() > 0 else "Invalid .ipynb JSON root", "", False, 4, 5)
    var cells_node = doc.get(0, "cells")
    if doc.kind(cells_node) != J_ARR:
        return IpynbDocument(False, "Missing 'cells' array in .ipynb", "", False, 4, 5)

    var nbf = doc.int(doc.get(0, "nbformat"), 4)
    var nbf_min = doc.int(doc.get(0, "nbformat_minor"), 5)
    var is_mj = _detect_mojo_kernel(doc, cells_node)

    var blocks = List[String]()
    for c in doc.children(cells_node):
        var ctype = doc.str(doc.get(c, "cell_type"), "code")
        var src = _extract_source(doc, doc.get(c, "source")).replace("\r\n", "\n")
        if src.endswith("\n"):
            var trimmed = String(src[byte=0:src.byte_length() - 1])
            src = trimmed
        var title = doc.str(doc.path(c, "metadata/title"), doc.str(doc.path(c, "metadata/name"), ""))
        if ctype == "markdown" or ctype == "raw":
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
            blocks.append("\n".join(md_lines))
        else:
            var hdr = String("# %%") + ((" " + title) if title.byte_length() > 0 else String(""))
            if src.byte_length() > 0:
                blocks.append(hdr + "\n" + src)
            else:
                blocks.append(hdr)

    var full = "\n".join(blocks)
    if full.byte_length() > 0 and not full.endswith("\n"):
        full += "\n"
    return IpynbDocument(True, "", full, is_mj, nbf, nbf_min)


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


def percent_text_to_ipynb(text: String, is_mojo: Bool, existing_raw_json: String = "") -> String:
    """Serialize `# %%` / `# %% [markdown]` buffer text to nbformat v4 `.ipynb` JSON."""
    var norm = text.replace("\r\n", "\n")
    if norm.endswith("\n"):
        var trimmed = String(norm[byte=0:norm.byte_length() - 1])
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

    var prev_doc = json_parse(existing_raw_json) if existing_raw_json.byte_length() > 0 else Json()
    var has_prev_meta = (
        existing_raw_json.byte_length() > 0
        and prev_doc.ok
        and prev_doc.kind(0) == J_OBJ
        and prev_doc.kind(prev_doc.get(0, "metadata")) == J_OBJ
    )
    var nbf = prev_doc.int(prev_doc.get(0, "nbformat"), 4) if has_prev_meta else 4
    var nbf_min = prev_doc.int(prev_doc.get(0, "nbformat_minor"), 5) if has_prev_meta else 5

    var w = JsonWriter()
    w.begin_obj()
    w.key("cells")
    w.begin_arr()
    for idx in range(len(cells)):
        w.begin_obj()
        w.kv_str("cell_type", cells[idx].cell_type)
        w.kv_str("id", "tm-cell-" + String(idx + 1))
        if cells[idx].cell_type == "code":
            w.key("execution_count")
            w.null()
        w.key("metadata")
        w.begin_obj()
        if cells[idx].title.byte_length() > 0:
            w.kv_str("name", cells[idx].title)
            w.kv_str("title", cells[idx].title)
        w.end_obj()
        if cells[idx].cell_type == "code":
            w.key("outputs")
            w.begin_arr()
            w.end_arr()
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
