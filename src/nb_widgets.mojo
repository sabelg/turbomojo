"""Interactive notebook parameter widgets, virtualized DataGrid & heatmap state, GIF89a LZW encoder, LaTeX/Mermaid renderers, and Jupyter ipykernel bridge.

Provides:
- `NbWidget` parsing, terminal control bars, stepping/dragging, and source-line rewriting
- `DataGridState` & `DataGridColStats` for CSV/TSV/JSON/matrix inspection, sorting, filtering, heatmaps, and RFC-4180 export
- Pure-Mojo multi-frame `encode_gif89a` (variable-width LZW) and `save_png_frames_as_gif`
- Inline LaTeX math (`render_latex_inline`) and fenced Mermaid diagrams (`render_mermaid_diagram`)
- External Jupyter `ipykernel` bridge script generator (`build_ipykernel_bridge_daemon`)
"""
from std.collections import List
from buffer import TextBuffer
from json import json_parse, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ
from png import Picture, png_decode
from util import (
    decode,
    to_str,
    slice_str,
    lower_str,
    pad_right,
    cp_len,
    read_file,
    write_file,
    encode_cp,
    bytes_to_str,
)

# ---------------------------------------------------------------------------
# 1. Interactive Notebook Parameter Widgets (`NbWidget`)
# ---------------------------------------------------------------------------

comptime WIDGET_SLIDER = 0
comptime WIDGET_BOOL = 1
comptime WIDGET_SELECT = 2


@fieldwise_init
struct NbWidget(Copyable, Movable):
    var line_row: Int
    var var_name: String
    var kind: Int
    var num_val: Float64
    var min_val: Float64
    var max_val: Float64
    var step_val: Float64
    var is_int: Bool
    var bool_val: Bool
    var str_val: String
    var options: List[String]


def _round_i64(x: Float64) -> Int:
    if x >= 0.0:
        return Int(x + 0.5)
    return -Int(-x + 0.5)


def _parse_float_strict(raw: String) -> Tuple[Bool, Float64, Bool]:
    """Parse an integer or floating-point literal.
    Returns `(ok, value, looks_int)` where `looks_int` is True iff there is no `.` or exponent."""
    var s = String(raw.strip())
    var n = s.byte_length()
    if n == 0:
        return (False, 0.0, False)
    var bs = s.as_bytes()
    var i = 0
    var neg = False
    if bs[i] == 45:
        neg = True
        i += 1
    elif bs[i] == 43:
        i += 1
    if i >= n:
        return (False, 0.0, False)

    var has_digit = False
    var has_dot = False
    var has_exp = False
    var int_part: Float64 = 0.0
    while i < n and ((bs[i] >= 48 and bs[i] <= 57) or bs[i] == 95):
        if bs[i] != 95:
            int_part = int_part * 10.0 + Float64(Int(bs[i]) - 48)
            has_digit = True
        i += 1

    var frac_part: Float64 = 0.0
    var frac_div: Float64 = 1.0
    if i < n and bs[i] == 46:
        has_dot = True
        i += 1
        while i < n and ((bs[i] >= 48 and bs[i] <= 57) or bs[i] == 95):
            if bs[i] != 95:
                frac_part = frac_part * 10.0 + Float64(Int(bs[i]) - 48)
                frac_div *= 10.0
                has_digit = True
            i += 1

    if not has_digit:
        return (False, 0.0, False)

    var exp_sign = 1
    var exp_val = 0
    if i < n and (bs[i] == 101 or bs[i] == 69):
        has_exp = True
        i += 1
        if i < n and bs[i] == 45:
            exp_sign = -1
            i += 1
        elif i < n and bs[i] == 43:
            i += 1
        var exp_digits = False
        while i < n and bs[i] >= 48 and bs[i] <= 57:
            exp_val = exp_val * 10 + (Int(bs[i]) - 48)
            exp_digits = True
            i += 1
        if not exp_digits or exp_val > 308:
            return (False, 0.0, False)

    if i != n:
        return (False, 0.0, False)

    var val = int_part + (frac_part / frac_div)
    if has_exp and exp_val > 0:
        var pow10: Float64 = 1.0
        for _ in range(exp_val):
            pow10 *= 10.0
        if exp_sign > 0:
            val *= pow10
        else:
            val /= pow10
    if neg:
        val = -val
    return (True, val, not has_dot and not has_exp)


def _format_float_clean(val: Float64) -> String:
    """Format a Float64 cleanly without IEEE-754 tail noise, always retaining `.` (e.g. `0.05`, `1.0`)."""
    var v = val
    if v > -1e-12 and v < 1e-12:
        v = 0.0
    var neg = v < 0.0
    var av = -v if neg else v
    if av >= 1e11:
        return ("-" if neg else "") + String(Int(av)) + ".0"
    var scaled = Int(av * 1_000_000.0 + 0.5)
    var whole = scaled // 1_000_000
    var frac = scaled % 1_000_000
    var sign = String("-") if neg and (whole > 0 or frac > 0) else String("")
    if frac == 0:
        return sign + String(whole) + ".0"
    var digits = String(frac)
    while digits.byte_length() < 6:
        digits = "0" + digits
    var keep = digits.byte_length()
    var dbs = digits.as_bytes()
    while keep > 1 and dbs[keep - 1] == 48:
        keep -= 1
    var trimmed_frac = String(digits[byte=0:keep])
    return sign + String(whole) + "." + trimmed_frac


def _find_comment_hash(line: String) -> Int:
    """Return byte index of `#` outside string quotes, or -1 if none."""
    var bs = line.as_bytes()
    var n = len(bs)
    var quote: UInt8 = 0
    var i = 0
    while i < n:
        var b = bs[i]
        if quote != 0:
            if b == 92 and i + 1 < n:
                i += 2
                continue
            if b == quote:
                quote = 0
        else:
            if b == 34 or b == 39:
                quote = b
            elif b == 35:
                return i
        i += 1
    return -1


def _find_assign_eq(code_part: String) -> Int:
    """Return byte index of top-level assignment `=` in `code_part` (not `==`, `!=`, `<=`, `>=`), or -1."""
    var bs = code_part.as_bytes()
    var n = len(bs)
    var quote: UInt8 = 0
    var depth = 0
    var i = 0
    while i < n:
        var b = bs[i]
        if quote != 0:
            if b == 92 and i + 1 < n:
                i += 2
                continue
            if b == quote:
                quote = 0
        else:
            if b == 34 or b == 39:
                quote = b
            elif b == 40 or b == 91 or b == 123:
                depth += 1
            elif b == 41 or b == 93 or b == 125:
                if depth > 0:
                    depth -= 1
            elif b == 61 and depth == 0:
                var prev_b: UInt8 = bs[i - 1] if i > 0 else 0
                var next_b: UInt8 = bs[i + 1] if i + 1 < n else 0
                if next_b != 61 and prev_b != 33 and prev_b != 60 and prev_b != 62 and prev_b != 61:
                    return i
        i += 1
    return -1


def _is_ident_byte(b: UInt8) -> Bool:
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or b == 95


def _parse_lhs_var_and_type(lhs: String) -> Tuple[String, String]:
    """Extract `(var_name, type_annotation)` from Mojo/Python LHS (`var lr: Float64`, `steps`, `comptime N: Int`)."""
    var s = String(lhs.strip())
    if s.startswith("var "):
        var sub = String(s[byte=4:].strip())
        s = sub
    elif s.startswith("comptime "):
        var sub = String(s[byte=9:].strip())
        s = sub
    var colon = s.find(":")
    var vname = s
    var tname = String("")
    if colon >= 0:
        vname = String(s[byte=0:colon].strip())
        tname = String(s[byte=colon + 1 :].strip())
    if vname.byte_length() == 0:
        return ("", "")
    var vbs = vname.as_bytes()
    if vbs[0] >= 48 and vbs[0] <= 57:
        return ("", "")
    for b in vbs:
        if not _is_ident_byte(b):
            return ("", "")
    return (vname, tname)


def _unquote_str(raw: String) -> Tuple[Bool, String]:
    var s = String(raw.strip())
    var n = s.byte_length()
    if n >= 2:
        var bs = s.as_bytes()
        var q = bs[0]
        if (q == 34 or q == 39) and bs[n - 1] == q:
            var out = List[UInt8]()
            var i = 1
            while i < n - 1:
                if bs[i] == 92 and i + 1 < n - 1:
                    var nxt = bs[i + 1]
                    if nxt == 110:
                        out.append(10)
                    elif nxt == 116:
                        out.append(9)
                    elif nxt == 114:
                        out.append(13)
                    else:
                        out.append(nxt)
                    i += 2
                else:
                    out.append(bs[i])
                    i += 1
            return (True, bytes_to_str(out))
    return (False, s)


def _split_top_level(s: String, delim: UInt8) -> List[String]:
    """Split `s` on byte `delim` at bracket/paren/brace depth 0 outside quotes."""
    var out = List[String]()
    var bs = s.as_bytes()
    var n = len(bs)
    var quote: UInt8 = 0
    var depth = 0
    var start = 0
    var i = 0
    while i < n:
        var b = bs[i]
        if quote != 0:
            if b == 92 and i + 1 < n:
                i += 2
                continue
            if b == quote:
                quote = 0
        else:
            if b == 34 or b == 39:
                quote = b
            elif b == 40 or b == 91 or b == 123:
                depth += 1
            elif b == 41 or b == 93 or b == 125:
                if depth > 0:
                    depth -= 1
            elif b == delim and depth == 0:
                out.append(String(s[byte=start:i]))
                start = i + 1
        i += 1
    out.append(String(s[byte=start:n]))
    return out^


def _parse_bracket_options(spec: String) -> List[String]:
    """Parse `["flat", "phong", "ray"]` or `('a', 'b')` into a list of strings."""
    var out = List[String]()
    var s = String(spec.strip())
    var n = s.byte_length()
    if n < 2:
        return out^
    var bs = s.as_bytes()
    if not ((bs[0] == 91 and bs[n - 1] == 93) or (bs[0] == 40 and bs[n - 1] == 41)):
        return out^
    var inner = String(s[byte=1 : n - 1].strip())
    if inner.byte_length() == 0:
        return out^
    for part in _split_top_level(inner, 44):
        var tok = String(part.strip())
        if tok.byte_length() == 0:
            continue
        var uq = _unquote_str(tok)
        out.append(uq[1])
    return out^


def _parse_param_spec_dict(spec: String) -> Tuple[String, Bool, Float64, Bool, Float64, Bool, Float64, List[String]]:
    """Parse `{type:"slider", min:0.0, max:1.0, step:0.05, options:[...]}` (loose JS/Colab object syntax).
    Returns `(wtype, has_min, min_v, has_max, max_v, has_step, step_v, options)`."""
    var wtype = String("")
    var has_min = False
    var min_v: Float64 = 0.0
    var has_max = False
    var max_v: Float64 = 1.0
    var has_step = False
    var step_v: Float64 = 0.0
    var opts = List[String]()

    var s = String(spec.strip())
    var n = s.byte_length()
    if n < 2:
        return (wtype, has_min, min_v, has_max, max_v, has_step, step_v, opts^)
    var bs = s.as_bytes()
    if bs[0] != 123 or bs[n - 1] != 125:
        return (wtype, has_min, min_v, has_max, max_v, has_step, step_v, opts^)
    var inner = String(s[byte=1 : n - 1].strip())
    if inner.byte_length() == 0:
        return (wtype, has_min, min_v, has_max, max_v, has_step, step_v, opts^)

    for entry in _split_top_level(inner, 44):
        var kv = String(entry.strip())
        var colon = kv.find(":")
        if colon < 0:
            continue
        var raw_k = String(kv[byte=0:colon].strip())
        var raw_v = String(kv[byte=colon + 1 :].strip())
        var k = lower_str(_unquote_str(raw_k)[1])
        if k == "type":
            wtype = lower_str(_unquote_str(raw_v)[1])
        elif k == "min":
            var pf = _parse_float_strict(raw_v)
            if pf[0]:
                has_min = True
                min_v = pf[1]
        elif k == "max":
            var pf = _parse_float_strict(raw_v)
            if pf[0]:
                has_max = True
                max_v = pf[1]
        elif k == "step":
            var pf = _parse_float_strict(raw_v)
            if pf[0]:
                has_step = True
                step_v = pf[1]
        elif k == "options" or k == "choices" or k == "values":
            opts = _parse_bracket_options(raw_v)
    return (wtype, has_min, min_v, has_max, max_v, has_step, step_v, opts^)


def _type_forces_int(tname: String) -> Int:
    """Return 1 if type annotation forces Int, -1 if forces Float, 0 if unspecified."""
    var low = lower_str(tname)
    if low == "int" or low == "int64" or low == "int32" or low == "int16" or low == "int8" or low == "uint":
        return 1
    if low == "float" or low == "float64" or low == "float32" or low == "float16":
        return -1
    return 0


def _parse_assignment_line_value(line: String) -> Tuple[Bool, String, String, String]:
    """Return `(ok, var_name, type_annot, rhs_trimmed)` for a simple assignment line."""
    var hpos = _find_comment_hash(line)
    var code = String(line[byte=0:hpos]) if hpos >= 0 else line
    var eq = _find_assign_eq(code)
    if eq < 0:
        return (False, "", "", "")
    var lhs = String(code[byte=0:eq])
    var rhs = String(code[byte=eq + 1 :].strip())
    var vt = _parse_lhs_var_and_type(lhs)
    if vt[0].byte_length() == 0 or rhs.byte_length() == 0:
        return (False, "", "", "")
    return (True, vt[0], vt[1], rhs)


def _build_slider_widget(
    row: Int,
    vname: String,
    tname: String,
    val_str: String,
    has_min: Bool,
    min_in: Float64,
    has_max: Bool,
    max_in: Float64,
    has_step: Bool,
    step_in: Float64,
    spec_text: String,
    force_int_hint: Bool,
) -> NbWidget:
    var pf = _parse_float_strict(val_str)
    var cur_v = pf[1] if pf[0] else (min_in if has_min else 0.0)
    var tf = _type_forces_int(tname)
    var is_int: Bool
    if tf == 1 or force_int_hint:
        is_int = True
    elif tf == -1:
        is_int = False
    else:
        var val_looks_int = pf[2] if pf[0] else True
        var spec_has_dot = spec_text.find(".") >= 0
        is_int = val_looks_int and not spec_has_dot

    var mn = min_in if has_min else (0.0 if cur_v >= 0.0 else cur_v * 2.0)
    var mx = max_in if has_max else (100.0 if (is_int and cur_v <= 100.0) else (1.0 if (not is_int and cur_v >= 0.0 and cur_v <= 1.0) else max(10.0, cur_v * 2.0)))
    if mx < mn:
        var tmp = mn
        mn = mx
        mx = tmp
    var st = step_in if (has_step and step_in > 0.0) else (1.0 if is_int else max(0.001, (mx - mn) / 20.0))
    if cur_v < mn:
        cur_v = mn
    if cur_v > mx:
        cur_v = mx
    if is_int:
        cur_v = Float64(_round_i64(cur_v))
    return NbWidget(row, vname, WIDGET_SLIDER, cur_v, mn, mx, st, is_int, False, "", List[String]())


def _parse_interact_tuple_or_spec(
    row: Int, vname: String, tname: String, val_override: String, rhs_spec: String
) -> Tuple[Bool, NbWidget]:
    var empty_w = NbWidget(row, vname, WIDGET_SLIDER, 0.0, 0.0, 1.0, 0.1, False, False, "", List[String]())
    var sp = String(rhs_spec.strip())
    var low_sp = lower_str(sp)
    if low_sp == "true" or low_sp == "false":
        var bv = low_sp == "true"
        if val_override.byte_length() > 0:
            var low_ov = lower_str(val_override)
            if low_ov == "true" or low_ov == "false":
                bv = low_ov == "true"
        return (True, NbWidget(row, vname, WIDGET_BOOL, 0.0, 0.0, 1.0, 1.0, False, bv, "", List[String]()))

    if sp.startswith("["):
        var opts = _parse_bracket_options(sp)
        if len(opts) == 0:
            return (False, empty_w^)
        var sv = opts[0]
        if val_override.byte_length() > 0:
            var uq = _unquote_str(val_override)
            if uq[0] or uq[1].byte_length() > 0:
                sv = uq[1]
        return (True, NbWidget(row, vname, WIDGET_SELECT, 0.0, 0.0, 1.0, 1.0, False, False, sv, opts^))

    if sp.startswith("(") and sp.endswith(")"):
        var inner = String(sp[byte=1 : sp.byte_length() - 1].strip())
        var parts = _split_top_level(inner, 44)
        if len(parts) >= 2:
            var p0 = _parse_float_strict(parts[0])
            var p1 = _parse_float_strict(parts[1])
            if p0[0] and p1[0]:
                var has_st = False
                var st_v: Float64 = 1.0
                var st_int = True
                if len(parts) >= 3:
                    var p2 = _parse_float_strict(parts[2])
                    if p2[0]:
                        has_st = True
                        st_v = p2[1]
                        st_int = p2[2]
                var all_int = p0[2] and p1[2] and st_int
                var init_str = val_override if val_override.byte_length() > 0 else String(parts[0].strip())
                var w = _build_slider_widget(
                    row, vname, tname, init_str, True, p0[1], True, p1[1], has_st, st_v, sp, False
                )
                if _type_forces_int(tname) == 0:
                    w.is_int = all_int
                return (True, w^)
    return (False, empty_w^)


def parse_cell_widgets(buf: TextBuffer, start_row: Int, end_row: Int) -> List[NbWidget]:
    """Parse `# @param` and `# @interact` parameter widget annotations in `buf[start_row .. end_row]`."""
    var out = List[NbWidget]()
    var n_lines = buf.count()
    if n_lines <= 0 or end_row < start_row:
        return out^
    var lo = max(0, start_row)
    var hi = min(n_lines - 1, end_row)

    for r in range(lo, hi + 1):
        var ln = to_str(buf.line(r))
        var hpos = _find_comment_hash(ln)
        if hpos < 0:
            continue
        var comment_body = String(ln[byte=hpos + 1 :].strip())

        if comment_body.startswith("@param"):
            var after_tag = String(comment_body[byte=6:].strip())
            var asgn = _parse_assignment_line_value(ln)
            if not asgn[0]:
                continue
            var vname = asgn[1]
            var tname = asgn[2]
            var rhs = asgn[3]
            var low_rhs = lower_str(rhs)
            var low_t = lower_str(tname)

            if after_tag.startswith("["):
                var opts = _parse_bracket_options(after_tag)
                var cur_s = _unquote_str(rhs)[1]
                if len(opts) == 0 and cur_s.byte_length() > 0:
                    opts.append(cur_s)
                out.append(NbWidget(r, vname, WIDGET_SELECT, 0.0, 0.0, 1.0, 1.0, False, False, cur_s, opts^))
                continue

            var d = _parse_param_spec_dict(after_tag)
            var wtype = d[0]
            var d_opts = d[7].copy()

            if (
                wtype == "boolean"
                or wtype == "bool"
                or wtype == "checkbox"
                or (wtype == "" and (low_rhs == "true" or low_rhs == "false" or low_t == "bool"))
            ):
                var bval = low_rhs == "true"
                out.append(NbWidget(r, vname, WIDGET_BOOL, 0.0, 0.0, 1.0, 1.0, False, bval, "", List[String]()))
                continue

            if wtype == "dropdown" or wtype == "select" or len(d_opts) > 0:
                var cur_s = _unquote_str(rhs)[1]
                if len(d_opts) == 0 and cur_s.byte_length() > 0:
                    d_opts.append(cur_s)
                out.append(NbWidget(r, vname, WIDGET_SELECT, 0.0, 0.0, 1.0, 1.0, False, False, cur_s, d_opts^))
                continue

            var force_int = wtype == "integer" or wtype == "int"
            out.append(
                _build_slider_widget(
                    r, vname, tname, rhs, d[1], d[2], d[3], d[4], d[5], d[6], after_tag, force_int
                )
            )
            continue

        if comment_body.startswith("@interact"):
            var after_int = String(comment_body[byte=9:].strip())
            var inline_asgn = _parse_assignment_line_value(ln)
            if inline_asgn[0]:
                var spec_part = after_int
                var eq_i = _find_assign_eq(after_int)
                if eq_i >= 0:
                    spec_part = String(after_int[byte=eq_i + 1 :].strip())
                var pw = _parse_interact_tuple_or_spec(r, inline_asgn[1], inline_asgn[2], inline_asgn[3], spec_part)
                if pw[0]:
                    out.append(pw[1].copy())
                continue

            # Standalone `# @interact x=(0, 10, 1)` (supports comma/space separated specs if single-tuple)
            for item in _split_top_level(after_int, 59):
                var seg = String(item.strip())
                var eq_i = _find_assign_eq(seg)
                if eq_i < 0:
                    continue
                var vn = String(seg[byte=0:eq_i].strip())
                var sp = String(seg[byte=eq_i + 1 :].strip())
                if vn.byte_length() == 0:
                    continue
                # Look ahead in cell for an assignment `vn = ...` or `var vn... = ...`
                var target_row = r
                var target_type = String("")
                var target_val = String("")
                for r2 in range(r + 1, hi + 1):
                    var ln2 = to_str(buf.line(r2))
                    var h2 = _find_comment_hash(ln2)
                    if h2 >= 0:
                        var cb2 = String(ln2[byte=h2 + 1 :].strip())
                        if cb2.startswith("@param") or cb2.startswith("@interact"):
                            continue
                    var a2 = _parse_assignment_line_value(ln2)
                    if a2[0] and a2[1] == vn:
                        target_row = r2
                        target_type = a2[2]
                        target_val = a2[3]
                        break
                var pw = _parse_interact_tuple_or_spec(target_row, vn, target_type, target_val, sp)
                if pw[0]:
                    out.append(pw[1].copy())

    return out^


def format_widget_bar(w: NbWidget, bar_cols: Int = 18) -> String:
    """Render terminal widget control bar:
    - Slider: `⚙ steps: [◀ ━━━━●━━━━━━━ ▶] 32`
    - Bool:   `⚙ use_shadows: [✓ ON]` / `⚙ use_shadows: [  OFF]`
    - Select: `⚙ mode: [◀ phong ▾ ▶] (2/3)`
    """
    if w.kind == WIDGET_BOOL:
        var state_lbl = "[✓ ON]" if w.bool_val else "[  OFF]"
        return "⚙ " + w.var_name + ": " + state_lbl

    if w.kind == WIDGET_SELECT:
        var n_opts = len(w.options)
        var pos = 0
        for i in range(n_opts):
            if w.options[i] == w.str_val:
                pos = i + 1
                break
        if pos == 0 and n_opts > 0:
            pos = 1
        var val_disp = w.str_val if w.str_val.byte_length() > 0 else (w.options[0] if n_opts > 0 else "")
        return (
            "⚙ "
            + w.var_name
            + ": [◀ "
            + val_disp
            + " ▾ ▶] ("
            + String(pos)
            + "/"
            + String(n_opts)
            + ")"
        )

    # WIDGET_SLIDER: `[◀ ` (3 cols) + track + ` ▶]` (3 cols) = `bar_cols` total when `bar_cols >= 9`
    var track_len = max(3, bar_cols - 6)
    var span = w.max_val - w.min_val
    var ratio: Float64 = 0.0
    if span > 1e-12:
        ratio = (w.num_val - w.min_val) / span
    if ratio < 0.0:
        ratio = 0.0
    if ratio > 1.0:
        ratio = 1.0
    var knob = _round_i64(ratio * Float64(track_len - 1))
    if knob < 0:
        knob = 0
    if knob > track_len - 1:
        knob = track_len - 1

    var track = String("")
    for i in range(track_len):
        track += "●" if i == knob else "━"

    var val_s = String(_round_i64(w.num_val)) if w.is_int else _format_float_clean(w.num_val)
    return "⚙ " + w.var_name + ": [◀ " + track + " ▶] " + val_s


def _snap_and_clamp_slider(mut w: NbWidget, raw_val: Float64):
    var lo = w.min_val
    var hi = w.max_val
    if hi < lo:
        var tmp = lo
        lo = hi
        hi = tmp
    var st = w.step_val
    var v = raw_val
    if st > 1e-12:
        var steps = _round_i64((v - lo) / st)
        v = lo + Float64(steps) * st
    if v < lo:
        v = lo
    if v > hi:
        v = hi
    if w.is_int:
        v = Float64(_round_i64(v))
    elif v > -1e-12 and v < 1e-12:
        v = 0.0
    w.num_val = v


def step_widget_value(mut w: NbWidget, delta: Int):
    """Increment/decrement `w` by `delta` steps (clamping sliders, toggling booleans, cycling options)."""
    if delta == 0:
        return
    if w.kind == WIDGET_BOOL:
        w.bool_val = not w.bool_val
        return
    if w.kind == WIDGET_SELECT:
        var n = len(w.options)
        if n == 0:
            return
        var cur = 0
        for i in range(n):
            if w.options[i] == w.str_val:
                cur = i
                break
        var nxt = ((cur + delta) % n + n) % n
        w.str_val = w.options[nxt]
        return
    var st = w.step_val if w.step_val > 1e-12 else (1.0 if w.is_int else 0.01)
    _snap_and_clamp_slider(w, w.num_val + Float64(delta) * st)


def set_widget_ratio(mut w: NbWidget, ratio_0_to_1: Float64):
    """Set `w` from a normalized `[0.0, 1.0]` drag ratio, snapping to `step_val`."""
    var r = ratio_0_to_1
    if r < 0.0:
        r = 0.0
    if r > 1.0:
        r = 1.0
    if w.kind == WIDGET_BOOL:
        w.bool_val = r >= 0.5
        return
    if w.kind == WIDGET_SELECT:
        var n = len(w.options)
        if n == 0:
            return
        var idx = _round_i64(r * Float64(n - 1))
        if idx < 0:
            idx = 0
        if idx >= n:
            idx = n - 1
        w.str_val = w.options[idx]
        return
    var raw = w.min_val + r * (w.max_val - w.min_val)
    _snap_and_clamp_slider(w, raw)


def _format_widget_literal(w: NbWidget, old_val_trimmed: String) -> String:
    if w.kind == WIDGET_BOOL:
        return "True" if w.bool_val else "False"
    if w.kind == WIDGET_SELECT:
        var use_single = old_val_trimmed.startswith("'") and old_val_trimmed.endswith("'")
        var q = "'" if use_single else "\""
        var esc = String("")
        for cp in decode(w.str_val):
            if cp == 92:
                esc += "\\\\"
            elif cp == 34 and not use_single:
                esc += "\\\""
            elif cp == 39 and use_single:
                esc += "\\'"
            else:
                var b = List[UInt8]()
                encode_cp(cp, b)
                esc += bytes_to_str(b)
        return q + esc + q
    if w.is_int:
        return String(_round_i64(w.num_val))
    return _format_float_clean(w.num_val)


def rewrite_widget_line(orig_line: String, w: NbWidget) -> String:
    """Update the literal assignment value on `orig_line`, preserving indentation, type annotation,
    spacing, and any trailing `# @param ...` / `# @interact ...` comment."""
    var hpos = _find_comment_hash(orig_line)
    var code_part = String(orig_line[byte=0:hpos]) if hpos >= 0 else orig_line
    var comment_part = String(orig_line[byte=hpos:]) if hpos >= 0 else String("")

    var eq = _find_assign_eq(code_part)
    if eq < 0:
        return orig_line

    var prefix_with_eq = String(code_part[byte=0 : eq + 1])
    var after_eq = String(code_part[byte=eq + 1 :])
    var ab = after_eq.as_bytes()
    var n_ab = len(ab)

    var lead_ws = 0
    while lead_ws < n_ab and (ab[lead_ws] == 32 or ab[lead_ws] == 9):
        lead_ws += 1
    var trail_start = n_ab
    while trail_start > lead_ws and (ab[trail_start - 1] == 32 or ab[trail_start - 1] == 9):
        trail_start -= 1

    var lead_str = String(after_eq[byte=0:lead_ws]) if lead_ws > 0 else String(" ")
    var old_val = String(after_eq[byte=lead_ws:trail_start])
    var trail_str = String(after_eq[byte=trail_start:n_ab])
    var new_lit = _format_widget_literal(w, old_val)
    return prefix_with_eq + lead_str + new_lit + trail_str + comment_part


# ---------------------------------------------------------------------------
# 2. Virtualized DataGrid & 2D Tensor Heatmap State (`DataGridState`)
# ---------------------------------------------------------------------------

@fieldwise_init
struct DataGridColStats(Copyable, Movable):
    var name: String
    var is_numeric: Bool
    var count: Int
    var nan_count: Int
    var min_val: Float64
    var max_val: Float64
    var mean_val: Float64
    var sparkline: String


@fieldwise_init
struct DataGridState(Copyable, Movable):
    var title: String
    var headers: List[String]
    var rows: List[List[String]]
    var filtered_indices: List[Int]
    var col_widths: List[Int]
    var col_stats: List[DataGridColStats]
    var cursor_row: Int
    var cursor_col: Int
    var scroll_row: Int
    var scroll_col: Int
    var sort_col: Int
    var sort_asc: Bool
    var filter_query: String
    var heatmap_mode: Bool

    def __init__(out self):
        self.title = ""
        self.headers = List[String]()
        self.rows = List[List[String]]()
        self.filtered_indices = List[Int]()
        self.col_widths = List[Int]()
        self.col_stats = List[DataGridColStats]()
        self.cursor_row = 0
        self.cursor_col = 0
        self.scroll_row = 0
        self.scroll_col = 0
        self.sort_col = -1
        self.sort_asc = True
        self.filter_query = ""
        self.heatmap_mode = False

    def set_filter(mut self, query: String):
        """Filter `filtered_indices` case-insensitively across all row cells, preserving active sort."""
        self.filter_query = query
        var q = lower_str(String(query.strip()))
        self.filtered_indices.clear()
        for r in range(len(self.rows)):
            if q.byte_length() == 0:
                self.filtered_indices.append(r)
            else:
                var matched = False
                for c in range(len(self.rows[r])):
                    if lower_str(self.rows[r][c]).find(q) >= 0:
                        matched = True
                        break
                if matched:
                    self.filtered_indices.append(r)
        if self.sort_col >= 0 and self.sort_col < len(self.headers):
            self._sort_filtered_in_place()
        var max_r = max(0, len(self.filtered_indices) - 1)
        if self.cursor_row > max_r:
            self.cursor_row = max_r
        if self.scroll_row > max_r:
            self.scroll_row = max_r

    def sort_by_column(mut self, col: Int):
        """Toggle ascending/descending if already sorted on `col`, else sort ascending on `col`.
        Pushes `NaN` / empty cells to the bottom in both directions."""
        if col < 0 or col >= len(self.headers):
            return
        if self.sort_col == col:
            self.sort_asc = not self.sort_asc
        else:
            self.sort_col = col
            self.sort_asc = True
        self._sort_filtered_in_place()
        self.cursor_row = 0
        self.scroll_row = 0

    def _sort_filtered_in_place(mut self):
        var n = len(self.filtered_indices)
        if n <= 1 or self.sort_col < 0 or self.sort_col >= len(self.headers):
            return
        var is_num = self.sort_col < len(self.col_stats) and self.col_stats[self.sort_col].is_numeric
        var col = self.sort_col
        var asc = self.sort_asc

        var tmp = List[Int](length=n, fill=0)
        var width = 1
        while width < n:
            var left = 0
            while left < n:
                var mid = min(left + width, n)
                var right = min(left + 2 * width, n)
                var i = left
                var j = mid
                var k = left
                while i < mid and j < right:
                    var ri = self.filtered_indices[i]
                    var rj = self.filtered_indices[j]
                    var ci = self.rows[ri][col] if col < len(self.rows[ri]) else String("")
                    var cj = self.rows[rj][col] if col < len(self.rows[rj]) else String("")
                    if _grid_cell_comes_first(ci, cj, is_num, asc):
                        tmp[k] = ri
                        i += 1
                    else:
                        tmp[k] = rj
                        j += 1
                    k += 1
                while i < mid:
                    tmp[k] = self.filtered_indices[i]
                    i += 1
                    k += 1
                while j < right:
                    tmp[k] = self.filtered_indices[j]
                    j += 1
                    k += 1
                for p in range(left, right):
                    self.filtered_indices[p] = tmp[p]
                left += 2 * width
            width *= 2

    def heatmap_cell_rgb(self, view_row: Int, col: Int) -> Tuple[Bool, Int, Int, Int]:
        """Map normalized `(v - min)/(max - min)` onto a perceptual dark-friendly Viridis-inspired
        RGB ramp when `heatmap_mode` is active; highlight `NaN`/`Inf` in crimson `(170, 35, 55)`."""
        if (
            not self.heatmap_mode
            or view_row < 0
            or view_row >= len(self.filtered_indices)
            or col < 0
            or col >= len(self.col_stats)
        ):
            return (False, 0, 0, 0)
        if not self.col_stats[col].is_numeric:
            return (False, 0, 0, 0)
        var r_idx = self.filtered_indices[view_row]
        var raw = self.rows[r_idx][col] if col < len(self.rows[r_idx]) else String("")
        var cls = _classify_grid_num(raw)
        if cls[0] == 2 or cls[0] == 3:
            # NaN or Inf anomaly -> crimson
            return (True, 170, 35, 55)
        if cls[0] != 1:
            return (False, 0, 0, 0)
        var mn = self.col_stats[col].min_val
        var mx = self.col_stats[col].max_val
        var t: Float64 = 0.5
        if mx > mn + 1e-12:
            t = (cls[1] - mn) / (mx - mn)
        if t < 0.0:
            t = 0.0
        if t > 1.0:
            t = 1.0
        var rgb = _viridis_dark_rgb(t)
        return (True, rgb[0], rgb[1], rgb[2])

    def export_csv(self) -> String:
        """Serialize headers + currently visible (`filtered_indices`) rows to valid RFC-4180 CSV."""
        var lines = List[String]()
        var n_cols = len(self.headers)
        if n_cols > 0:
            var hparts = List[String]()
            for c in range(n_cols):
                hparts.append(_csv_escape_field(self.headers[c]))
            lines.append(",".join(hparts))
        for vi in range(len(self.filtered_indices)):
            var r_idx = self.filtered_indices[vi]
            var rparts = List[String]()
            for c in range(n_cols):
                var cell = self.rows[r_idx][c] if c < len(self.rows[r_idx]) else String("")
                rparts.append(_csv_escape_field(cell))
            lines.append(",".join(rparts))
        return "\n".join(lines) + "\n"

    def render_summary_lines(self, max_cols: Int, max_rows: Int) -> List[String]:
        """Render virtualized Unicode box table with sort arrows (`▲`/`▼`), sparklines, and status footer."""
        var out = List[String]()
        var n_cols = len(self.headers)
        if n_cols == 0:
            out.append("(empty grid)")
            return out^

        var start_c = max(0, min(self.scroll_col, n_cols - 1))
        var budget = max(16, max_cols)
        var vis_cols = List[Int]()
        var vis_widths = List[Int]()
        var used_w = 1
        for c in range(start_c, n_cols):
            var base_w = self.col_widths[c] if c < len(self.col_widths) else 8
            var w = max(8, min(28, base_w + 2))
            if len(vis_cols) > 0 and used_w + w + 3 > budget:
                break
            if len(vis_cols) == 0 and used_w + w + 3 > budget:
                w = max(6, budget - 4)
            vis_cols.append(c)
            vis_widths.append(w)
            used_w += w + 3

        var has_sparks = False
        for k in range(len(vis_cols)):
            var c = vis_cols[k]
            if c < len(self.col_stats) and self.col_stats[c].sparkline.byte_length() > 0:
                has_sparks = True
                break

        # Top border
        var top = String("┌")
        var mid = String("├")
        var bot = String("└")
        for k in range(len(vis_cols)):
            var seg = String("")
            for _ in range(vis_widths[k] + 2):
                seg += "─"
            top += seg + ("┬" if k + 1 < len(vis_cols) else "┐")
            mid += seg + ("┼" if k + 1 < len(vis_cols) else "┤")
            bot += seg + ("┴" if k + 1 < len(vis_cols) else "┘")
        out.append(top)

        # Header row with sort indicator ▲ / ▼
        var hline = String("│")
        for k in range(len(vis_cols)):
            var c = vis_cols[k]
            var arrow = String("")
            if c == self.sort_col:
                arrow = " ▲" if self.sort_asc else " ▼"
            var htxt = pad_right(self.headers[c] + arrow, vis_widths[k])
            hline += " " + htxt + " │"
        out.append(hline)

        # Sparkline distribution row
        if has_sparks:
            var sline = String("│")
            for k in range(len(vis_cols)):
                var c = vis_cols[k]
                var sp = self.col_stats[c].sparkline if c < len(self.col_stats) else String("")
                sline += " " + pad_right(sp, vis_widths[k]) + " │"
            out.append(sline)

        out.append(mid)

        # Virtualized body rows
        var chrome_rows = len(out) + 2
        var body_budget = max(1, max_rows - chrome_rows)
        var n_vis = len(self.filtered_indices)
        var start_r = max(0, min(self.scroll_row, max(0, n_vis - 1)))
        var end_r = min(n_vis, start_r + body_budget)
        for vr in range(start_r, end_r):
            var r_idx = self.filtered_indices[vr]
            var rline = String("│")
            for k in range(len(vis_cols)):
                var c = vis_cols[k]
                var val = self.rows[r_idx][c] if c < len(self.rows[r_idx]) else String("")
                rline += " " + pad_right(val, vis_widths[k]) + " │"
            out.append(rline)

        out.append(bot)

        # Status footer
        var total_nans = 0
        for c in range(len(self.col_stats)):
            total_nans += self.col_stats[c].nan_count
        var footer = (
            (self.title + " · ") if self.title.byte_length() > 0 else String("")
        ) + String(n_vis) + "/" + String(len(self.rows)) + " rows · " + String(n_cols) + " cols"
        if self.filter_query.byte_length() > 0:
            footer += " · filter=\"" + self.filter_query + "\""
        if self.heatmap_mode:
            footer += " · [heatmap]"
        if total_nans > 0:
            footer += " · ⚠ " + String(total_nans) + " NaN/Inf"
        out.append(footer)
        return out^


def _classify_grid_num(raw: String) -> Tuple[Int, Float64]:
    """Classify a cell string:
    - `0`: empty / missing (`""`, `"null"`, `"none"`, `"na"`, `"n/a"`)
    - `1`: finite number `(1, val)`
    - `2`: NaN (`"nan"`, `"-nan"`, `"+nan"`)
    - `3`: Inf (`"inf"`, `"+inf"`, `"-inf"`, `"infinity"`, `"-infinity"`, with sign in `val`)
    - `-1`: non-numeric string
    """
    var s = lower_str(String(raw.strip()))
    if s.byte_length() == 0 or s == "null" or s == "none" or s == "na" or s == "n/a":
        return (0, 0.0)
    if s == "nan" or s == "-nan" or s == "+nan":
        return (2, 0.0)
    if s == "inf" or s == "+inf" or s == "infinity" or s == "+infinity":
        return (3, 1.0)
    if s == "-inf" or s == "-infinity":
        return (3, -1.0)
    var pf = _parse_float_strict(s)
    if pf[0]:
        return (1, pf[1])
    return (-1, 0.0)


def _grid_cell_comes_first(a: String, b: String, is_numeric: Bool, asc: Bool) -> Bool:
    """Comparison for stable merge sort; returns True if `a` should precede `b` (or tie, keeping stability).
    Pushes empty and `NaN` cells to the bottom in BOTH ascending and descending modes."""
    if is_numeric:
        var ca = _classify_grid_num(a)
        var cb = _classify_grid_num(b)
        var a_bottom = ca[0] == 0 or ca[0] == 2 or ca[0] == -1
        var b_bottom = cb[0] == 0 or cb[0] == 2 or cb[0] == -1
        if a_bottom and b_bottom:
            return True
        if a_bottom:
            return False
        if b_bottom:
            return True
        # Handle +/-Inf relative to finite numbers
        if ca[0] == 3 and cb[0] == 3:
            if ca[1] == cb[1]:
                return True
            return (ca[1] < cb[1]) if asc else (ca[1] > cb[1])
        if ca[0] == 3:
            return (ca[1] < 0.0) if asc else (ca[1] > 0.0)
        if cb[0] == 3:
            return (cb[1] > 0.0) if asc else (cb[1] < 0.0)
        if ca[1] == cb[1]:
            return True
        return (ca[1] < cb[1]) if asc else (ca[1] > cb[1])

    var ta = String(a.strip())
    var tb = String(b.strip())
    var a_empty = ta.byte_length() == 0 or lower_str(ta) == "nan"
    var b_empty = tb.byte_length() == 0 or lower_str(tb) == "nan"
    if a_empty and b_empty:
        return True
    if a_empty:
        return False
    if b_empty:
        return True
    var la = lower_str(ta)
    var lb = lower_str(tb)
    if la == lb:
        return True
    return (la < lb) if asc else (la > lb)


def _viridis_dark_rgb(t: Float64) -> Tuple[Int, Int, Int]:
    """Smooth 5-stop Viridis/Plasma-inspired perceptual dark-background RGB ramp."""
    # Stops: 0.00=(44,24,78), 0.25=(43,68,110), 0.50=(31,108,104), 0.75=(74,142,72), 1.00=(168,152,42)
    var rs: List[Int] = [44, 43, 31, 74, 168]
    var gs: List[Int] = [24, 68, 108, 142, 152]
    var bs: List[Int] = [78, 110, 104, 72, 42]
    var scaled = t * 4.0
    var seg = Int(scaled)
    if seg < 0:
        seg = 0
    if seg >= 4:
        return (rs[4], gs[4], bs[4])
    var frac = scaled - Float64(seg)
    var r = _round_i64(Float64(rs[seg]) + frac * Float64(rs[seg + 1] - rs[seg]))
    var g = _round_i64(Float64(gs[seg]) + frac * Float64(gs[seg + 1] - gs[seg]))
    var b = _round_i64(Float64(bs[seg]) + frac * Float64(bs[seg + 1] - bs[seg]))
    return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))


def _csv_escape_field(field: String) -> String:
    var needs_quote = (
        field.find(",") >= 0
        or field.find("\"") >= 0
        or field.find("\n") >= 0
        or field.find("\r") >= 0
    )
    if not needs_quote:
        return field
    return "\"" + field.replace("\"", "\"\"") + "\""


def _build_sparkline_8bin(vals: List[Float64], mn: Float64, mx: Float64) -> String:
    if len(vals) == 0:
        return ""
    var bars: List[String] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    if mx <= mn + 1e-12:
        return "▄▄▄▄▄▄▄▄"
    var bins = List[Int](length=8, fill=0)
    var span = mx - mn
    for i in range(len(vals)):
        var b = Int(((vals[i] - mn) / span) * 8.0)
        if b < 0:
            b = 0
        if b > 7:
            b = 7
        bins[b] += 1
    var max_c = 1
    for k in range(8):
        if bins[k] > max_c:
            max_c = bins[k]
    var out = String("")
    for k in range(8):
        if bins[k] == 0:
            out += bars[0]
        else:
            var idx = _round_i64((Float64(bins[k]) / Float64(max_c)) * 7.0)
            if idx < 1:
                idx = 1
            if idx > 7:
                idx = 7
            out += bars[idx]
    return out


def _compute_grid_stats_and_widths(
    headers: List[String], rows: List[List[String]]
) -> Tuple[List[DataGridColStats], List[Int]]:
    var stats = List[DataGridColStats]()
    var widths = List[Int]()
    var n_cols = len(headers)
    var n_rows = len(rows)

    for c in range(n_cols):
        var fin_vals = List[Float64]()
        var nan_cnt = 0
        var has_non_num = False
        var mn: Float64 = 0.0
        var mx: Float64 = 0.0
        var total: Float64 = 0.0
        var max_w = max(4, cp_len(headers[c]))

        for r in range(n_rows):
            var cell = rows[r][c] if c < len(rows[r]) else String("")
            var cw = cp_len(cell)
            if cw > max_w:
                max_w = cw
            var cls = _classify_grid_num(cell)
            if cls[0] == 1:
                var fv = cls[1]
                if len(fin_vals) == 0:
                    mn = fv
                    mx = fv
                else:
                    if fv < mn:
                        mn = fv
                    if fv > mx:
                        mx = fv
                total += fv
                fin_vals.append(fv)
            elif cls[0] == 2 or cls[0] == 3:
                nan_cnt += 1
            elif cls[0] == -1:
                has_non_num = True

        var is_num = not has_non_num and (len(fin_vals) > 0 or nan_cnt > 0)
        var mean_v = (total / Float64(len(fin_vals))) if len(fin_vals) > 0 else 0.0
        var spark = _build_sparkline_8bin(fin_vals, mn, mx) if is_num else String("")
        if spark.byte_length() > 0 and max_w < 8:
            max_w = 8
        stats.append(
            DataGridColStats(
                headers[c],
                is_num,
                len(fin_vals),
                nan_cnt,
                mn if is_num else 0.0,
                mx if is_num else 0.0,
                mean_v if is_num else 0.0,
                spark,
            )
        )
        widths.append(min(32, max_w))

    return (stats^, widths^)


def _finalize_grid_state(
    title: String, var headers: List[String], var rows: List[List[String]]
) -> DataGridState:
    var n_cols = len(headers)
    for r in range(len(rows)):
        while len(rows[r]) < n_cols:
            rows[r].append("")
        if len(rows[r]) > n_cols and n_cols > 0:
            rows[r].shrink(n_cols)
    var indices = List[Int]()
    for r in range(len(rows)):
        indices.append(r)
    var sw = _compute_grid_stats_and_widths(headers, rows)
    return DataGridState(
        title,
        headers^,
        rows^,
        indices^,
        sw[1].copy(),
        sw[0].copy(),
        0,
        0,
        0,
        0,
        -1,
        True,
        "",
        False,
    )


def _json_cell_to_str(doc_str: String, kind: Int, s_val: String, i_val: Int, f_val: Float64, whole: Bool) -> String:
    if kind == J_STR:
        return s_val
    if kind == J_BOOL:
        return "true" if i_val != 0 else "false"
    if kind == J_NUM:
        return String(i_val) if whole else _format_float_clean(f_val)
    if kind == J_ARR or kind == J_OBJ:
        return doc_str
    return ""


def _try_parse_json_objects_grid(title: String, trimmed: String) -> Tuple[Bool, DataGridState]:
    var doc = json_parse(trimmed)
    if not doc.ok or doc.kind(0) != J_ARR or doc.size(0) == 0:
        return (False, DataGridState())
    var first_el = doc.at(0, 0)
    if doc.kind(first_el) != J_OBJ:
        return (False, DataGridState())

    var headers = List[String]()
    var n_items = doc.size(0)
    for idx in range(n_items):
        var obj = doc.at(0, idx)
        if doc.kind(obj) != J_OBJ:
            return (False, DataGridState())
        for ch in doc.children(obj):
            var k = doc.key_of(ch)
            var seen = False
            for h in range(len(headers)):
                if headers[h] == k:
                    seen = True
                    break
            if not seen:
                headers.append(k)

    var rows = List[List[String]]()
    for idx in range(n_items):
        var obj = doc.at(0, idx)
        var row = List[String]()
        for h in range(len(headers)):
            var node = doc.get(obj, headers[h])
            if node < 0:
                row.append("")
            else:
                var kd = doc.kind(node)
                var dumped = doc.dump(node) if (kd == J_ARR or kd == J_OBJ) else String("")
                row.append(
                    _json_cell_to_str(
                        dumped,
                        kd,
                        doc.strs[node],
                        doc.ints[node],
                        doc.floats[node],
                        doc.whole[node],
                    )
                )
        rows.append(row^)

    return (True, _finalize_grid_state(title, headers^, rows^))


def _try_parse_bracket_matrix_grid(title: String, trimmed: String) -> Tuple[Bool, DataGridState]:
    """Parse 2D bracketed arrays/matrices such as `[[1.0, 2.0], [3.0, NaN]]`."""
    var n = trimmed.byte_length()
    if n < 4:
        return (False, DataGridState())
    var bs = trimmed.as_bytes()
    if bs[0] != 91 or bs[n - 1] != 93:
        return (False, DataGridState())
    var inner = String(trimmed[byte=1 : n - 1].strip())
    if not inner.startswith("["):
        return (False, DataGridState())

    var raw_rows = _split_top_level(inner, 44)
    # Also support newline/space separated `[...]\n[...]` without commas (NumPy style)
    if len(raw_rows) == 1 and inner.find("]") >= 0 and inner.find("[", 1) > inner.find("]"):
        raw_rows.clear()
        var ibs = inner.as_bytes()
        var depth = 0
        var rstart = -1
        for i in range(len(ibs)):
            if ibs[i] == 91:
                if depth == 0:
                    rstart = i
                depth += 1
            elif ibs[i] == 93:
                depth -= 1
                if depth == 0 and rstart >= 0:
                    raw_rows.append(String(inner[byte=rstart : i + 1]))
                    rstart = -1

    var rows = List[List[String]]()
    var max_cols = 0
    for r in range(len(raw_rows)):
        var rtxt = String(raw_rows[r].strip())
        if rtxt.byte_length() == 0:
            continue
        if not (rtxt.startswith("[") and rtxt.endswith("]")):
            return (False, DataGridState())
        var body = String(rtxt[byte=1 : rtxt.byte_length() - 1].strip())
        var row = List[String]()
        if body.byte_length() > 0:
            if body.find(",") >= 0:
                for cell_s in _split_top_level(body, 44):
                    row.append(_unquote_str(String(cell_s.strip()))[1])
            else:
                for ws_tok in body.split(" "):
                    var t = String(ws_tok.strip())
                    if t.byte_length() > 0:
                        row.append(_unquote_str(t)[1])
        if len(row) > max_cols:
            max_cols = len(row)
        rows.append(row^)

    if len(rows) == 0 or max_cols == 0:
        return (False, DataGridState())
    var headers = List[String]()
    for c in range(max_cols):
        headers.append("c" + String(c))
    return (True, _finalize_grid_state(title, headers^, rows^))


def _parse_delimited_records(text: String, sep_byte: UInt8) -> List[List[String]]:
    """RFC-4180 CSV/TSV tokenizer supporting quoted multiline/comma fields and `""` escapes."""
    var records = List[List[String]]()
    var bs = text.as_bytes()
    var n = len(bs)
    var i = 0
    var cur_row = List[String]()
    var field = List[UInt8]()
    var in_quotes = False
    var field_started = False

    while i < n:
        var b = bs[i]
        if in_quotes:
            if b == 34:
                if i + 1 < n and bs[i + 1] == 34:
                    field.append(34)
                    i += 2
                    continue
                in_quotes = False
                i += 1
                continue
            field.append(b)
            i += 1
            continue

        if b == 34 and not field_started:
            in_quotes = True
            field_started = True
            i += 1
            continue
        if b == 32 and not field_started and sep_byte != 32:
            # Allow leading space right before opening quote in relaxed CSV (`a, "hello, world"`)
            var j = i
            while j < n and bs[j] == 32:
                j += 1
            if j < n and bs[j] == 34:
                in_quotes = True
                field_started = True
                i = j + 1
                continue

        if b == sep_byte:
            cur_row.append(bytes_to_str(field))
            field.clear()
            field_started = False
            i += 1
            continue

        if b == 13 or b == 10:
            if b == 13 and i + 1 < n and bs[i + 1] == 10:
                i += 1
            cur_row.append(bytes_to_str(field))
            field.clear()
            field_started = False
            if not (len(cur_row) == 1 and cur_row[0].byte_length() == 0):
                records.append(cur_row^)
                cur_row = List[String]()
            else:
                cur_row.clear()
            i += 1
            continue

        field.append(b)
        field_started = True
        i += 1

    if field_started or len(field) > 0 or len(cur_row) > 0:
        cur_row.append(bytes_to_str(field))
        if not (len(cur_row) == 1 and cur_row[0].byte_length() == 0):
            records.append(cur_row^)

    return records^


def parse_delimited_grid(title: String, text: String, sep: String = ",") -> DataGridState:
    """Parse CSV/TSV (with RFC-4180 quotes & header auto-detection), 2D bracketed matrices,
    or JSON array-of-objects into a `DataGridState`."""
    var trimmed = String(text.strip())
    if trimmed.byte_length() == 0:
        return DataGridState()

    if trimmed.startswith("["):
        var jo = _try_parse_json_objects_grid(title, trimmed)
        if jo[0]:
            return jo[1].copy()
        var bm = _try_parse_bracket_matrix_grid(title, trimmed)
        if bm[0]:
            return bm[1].copy()

    var sep_b: UInt8 = 44
    if sep.byte_length() > 0:
        sep_b = sep.as_bytes()[0]
    if sep == "," and trimmed.find(",") < 0 and trimmed.find("\t") >= 0:
        sep_b = 9

    var recs = _parse_delimited_records(text, sep_b)
    if len(recs) == 0:
        return DataGridState()

    # Header auto-detection: if row 0 contains any non-numeric text identifier, treat row 0 as headers;
    # if row 0 is purely numeric values, synthesize `c0, c1, ...` headers and keep row 0 as data.
    var row0_has_text = False
    var row0_has_num = False
    for c in range(len(recs[0])):
        var cell0 = String(recs[0][c].strip())
        var cls0 = _classify_grid_num(cell0)
        if cls0[0] == -1:
            row0_has_text = True
        elif cls0[0] == 1 or cls0[0] == 2 or cls0[0] == 3:
            row0_has_num = True

    var headers = List[String]()
    var rows = List[List[String]]()
    if row0_has_text or not row0_has_num:
        for c in range(len(recs[0])):
            var h = String(recs[0][c].strip())
            headers.append(h if h.byte_length() > 0 else ("c" + String(c)))
        for r in range(1, len(recs)):
            rows.append(recs[r].copy())
    else:
        for c in range(len(recs[0])):
            headers.append("c" + String(c))
        for r in range(len(recs)):
            rows.append(recs[r].copy())

    return _finalize_grid_state(title, headers^, rows^)


# ---------------------------------------------------------------------------
# 3. Pure-Mojo Animated GIF89a Multi-Frame Encoder (`encode_gif89a`)
# ---------------------------------------------------------------------------

def _build_gif_global_palette() -> List[UInt8]:
    """Build 768-byte (256 RGB entries) Global Color Table:
    - Entries `0..215`: `6×6×6` RGB color cube (`0, 51, 102, 153, 204, 255`)
    - Entries `216..255`: 40-step greyscale ramp (`0..255`)
    """
    var pal = List[UInt8](capacity=768)
    for r6 in range(6):
        for g6 in range(6):
            for b6 in range(6):
                pal.append(UInt8(r6 * 51))
                pal.append(UInt8(g6 * 51))
                pal.append(UInt8(b6 * 51))
    for k in range(40):
        var g = UInt8((k * 255 + 19) // 39)
        pal.append(g)
        pal.append(g)
        pal.append(g)
    return pal^


def _quantize_rgb_o1(r_in: Int, g_in: Int, b_in: Int, a_in: Int) -> UInt8:
    """O(1) perceptual palette lookup choosing the closer of the `6×6×6` RGB cube and 40-step greyscale ramp."""
    var r = (r_in * a_in + 127) // 255 if a_in < 255 else r_in
    var g = (g_in * a_in + 127) // 255 if a_in < 255 else g_in
    var b = (b_in * a_in + 127) // 255 if a_in < 255 else b_in

    var r6 = (r * 5 + 127) // 255
    var g6 = (g * 5 + 127) // 255
    var b6 = (b * 5 + 127) // 255
    var cr = r6 * 51
    var cg = g6 * 51
    var cb = b6 * 51
    var dr = r - cr
    var dg = g - cg
    var db = b - cb
    var dist_cube = dr * dr + dg * dg + db * db
    var cube_idx = r6 * 36 + g6 * 6 + b6

    var lum = (r + g + b + 1) // 3
    var gk = (lum * 39 + 127) // 255
    if gk < 0:
        gk = 0
    if gk > 39:
        gk = 39
    var gv = (gk * 255 + 19) // 39
    var gdr = r - gv
    var gdg = g - gv
    var gdb = b - gv
    var dist_grey = gdr * gdr + gdg * gdg + gdb * gdb

    if dist_grey < dist_cube:
        return UInt8(216 + gk)
    return UInt8(cube_idx)


struct _GifBitPacker(Movable):
    var bit_buf: Int
    var bit_count: Int
    var block: List[UInt8]

    def __init__(out self):
        self.bit_buf = 0
        self.bit_count = 0
        self.block = List[UInt8](capacity=255)

    def put_code(mut self, code: Int, width: Int, mut out: List[UInt8]):
        self.bit_buf |= (code & ((1 << width) - 1)) << self.bit_count
        self.bit_count += width
        while self.bit_count >= 8:
            self.block.append(UInt8(self.bit_buf & 0xFF))
            self.bit_buf >>= 8
            self.bit_count -= 8
            if len(self.block) == 255:
                out.append(UInt8(255))
                for i in range(255):
                    out.append(self.block[i])
                self.block.clear()

    def finish(mut self, mut out: List[UInt8]):
        if self.bit_count > 0:
            self.block.append(UInt8(self.bit_buf & 0xFF))
            self.bit_buf = 0
            self.bit_count = 0
        if len(self.block) > 0:
            out.append(UInt8(len(self.block)))
            for i in range(len(self.block)):
                out.append(self.block[i])
            self.block.clear()
        out.append(UInt8(0))


def gif_lzw_compress_into(indices: List[UInt8], min_code_size: Int, mut out: List[UInt8]):
    """Compress indexed pixels with standard GIF89a variable-width LZW (`min_code_size = 8`,
    Clear `256`, EOI `257`, codes `9..12` bits, auto-reset at `4096`, LSB-first `<=255`-byte sub-blocks)."""
    var mcs = max(2, min(8, min_code_size))
    out.append(UInt8(mcs))
    var clear_code = 1 << mcs
    var eoi_code = clear_code + 1
    var packer = _GifBitPacker()

    var code_size = mcs + 1
    var next_code = eoi_code + 1
    packer.put_code(clear_code, code_size, out)

    if len(indices) == 0:
        packer.put_code(eoi_code, code_size, out)
        packer.finish(out)
        return

    # Open-addressed hash table (size 8192 = power of 2 > 2 * 4096)
    comptime HT_SIZE = 8192
    comptime HT_MASK = 8191
    var ht_keys = List[Int32](length=HT_SIZE, fill=-1)
    var ht_vals = List[Int32](length=HT_SIZE, fill=0)

    var prefix = Int(indices[0])
    for i in range(1, len(indices)):
        var sym = Int(indices[i])
        var key = Int32((prefix << 8) | sym)
        var slot = ((prefix * 257) ^ sym) & HT_MASK
        var found_code = -1
        while True:
            var k_at = ht_keys[slot]
            if k_at < 0:
                break
            if k_at == key:
                found_code = Int(ht_vals[slot])
                break
            slot = (slot + 1) & HT_MASK

        if found_code >= 0:
            prefix = found_code
        else:
            packer.put_code(prefix, code_size, out)
            if next_code < 4096:
                ht_keys[slot] = key
                ht_vals[slot] = Int32(next_code)
                if next_code == (1 << code_size) and code_size < 12:
                    code_size += 1
                next_code += 1
            else:
                packer.put_code(clear_code, code_size, out)
                for s in range(HT_SIZE):
                    ht_keys[s] = -1
                code_size = mcs + 1
                next_code = eoi_code + 1
            prefix = sym

    packer.put_code(prefix, code_size, out)
    if next_code == (1 << code_size) and code_size < 12:
        code_size += 1
    packer.put_code(eoi_code, code_size, out)
    packer.finish(out)


def gif_lzw_decompress(data: List[UInt8], start_offset: Int) -> Tuple[Bool, List[UInt8], Int]:
    """Decompress one GIF Table-Based Image Data stream starting at `start_offset` (the `min_code_size` byte).
    Returns `(ok, decompressed_indices, next_byte_offset_after_terminator)`."""
    var empty = List[UInt8]()
    if start_offset < 0 or start_offset >= len(data):
        return (False, empty^, start_offset)
    var mcs = Int(data[start_offset])
    if mcs < 2 or mcs > 8:
        return (False, empty^, start_offset)

    var pos = start_offset + 1
    var raw_stream = List[UInt8]()
    while pos < len(data):
        var blk_len = Int(data[pos])
        pos += 1
        if blk_len == 0:
            break
        if pos + blk_len > len(data):
            return (False, empty^, pos)
        for k in range(blk_len):
            raw_stream.append(data[pos + k])
        pos += blk_len

    var clear_code = 1 << mcs
    var eoi_code = clear_code + 1
    var code_size = mcs + 1
    var next_code = eoi_code + 1

    var prefixes = List[Int](length=4096, fill=-1)
    var suffixes = List[UInt8](length=4096, fill=0)
    var lengths = List[Int](length=4096, fill=1)
    for c in range(clear_code):
        suffixes[c] = UInt8(c)

    var out = List[UInt8]()
    var bit_pos = 0
    var total_bits = len(raw_stream) * 8
    var prev_code = -1
    var stack = List[UInt8](capacity=4096)

    while bit_pos + code_size <= total_bits:
        var code = 0
        for b in range(code_size):
            var bp = bit_pos + b
            if (Int(raw_stream[bp >> 3]) & (1 << (bp & 7))) != 0:
                code |= 1 << b
        bit_pos += code_size

        if code == clear_code:
            code_size = mcs + 1
            next_code = eoi_code + 1
            prev_code = -1
            continue
        if code == eoi_code:
            return (True, out^, pos)

        var first_byte: UInt8
        if code < next_code:
            # Decode existing entry `code`
            stack.clear()
            var cur = code
            while cur >= clear_code:
                stack.append(suffixes[cur])
                cur = prefixes[cur]
            first_byte = suffixes[cur]
            stack.append(first_byte)
            for k in range(len(stack) - 1, -1, -1):
                out.append(stack[k])
        elif code == next_code and prev_code >= 0:
            # KwKwK special case
            stack.clear()
            var cur = prev_code
            while cur >= clear_code:
                stack.append(suffixes[cur])
                cur = prefixes[cur]
            first_byte = suffixes[cur]
            stack.append(first_byte)
            for k in range(len(stack) - 1, -1, -1):
                out.append(stack[k])
            out.append(first_byte)
        else:
            return (False, out^, pos)

        if prev_code >= 0 and next_code < 4096:
            prefixes[next_code] = prev_code
            suffixes[next_code] = first_byte
            lengths[next_code] = lengths[prev_code] + 1
            next_code += 1
            if next_code == (1 << code_size) and code_size < 12:
                code_size += 1
        prev_code = code

    return (False, out^, pos)


def _append_u16_le(mut out: List[UInt8], v: Int):
    out.append(UInt8(v & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))


def encode_gif89a(frames: List[Picture], fps: Int = 12, loop_count: Int = 0) -> List[UInt8]:
    """Encode one or more RGBA `Picture` frames into an animated `GIF89a` byte stream."""
    var out = List[UInt8]()
    if len(frames) == 0:
        return out^
    var w = frames[0].w
    var h = frames[0].h
    if w <= 0 or h <= 0 or w > 65535 or h > 65535:
        return out^

    # 1. GIF89a Header (6 bytes)
    for b in "GIF89a".as_bytes():
        out.append(b)

    # 2. Logical Screen Descriptor (7 bytes): GCT=1, ColorRes=7 (8-bit), Sort=0, GCTSize=7 (256 colors) -> 0xF7
    _append_u16_le(out, w)
    _append_u16_le(out, h)
    out.append(UInt8(0xF7))
    out.append(UInt8(0))
    out.append(UInt8(0))

    # 3. 768-byte Global Color Table
    var pal = _build_gif_global_palette()
    for i in range(len(pal)):
        out.append(pal[i])

    # 4. Netscape 2.0 Application Extension for looping animations
    if len(frames) > 1:
        out.append(UInt8(0x21))
        out.append(UInt8(0xFF))
        out.append(UInt8(0x0B))
        for b in "NETSCAPE2.0".as_bytes():
            out.append(b)
        out.append(UInt8(0x03))
        out.append(UInt8(0x01))
        _append_u16_le(out, max(0, min(65535, loop_count)))
        out.append(UInt8(0x00))

    var delay_cs = max(2, 100 // max(1, fps))

    # 5. Per-frame GCE + Image Descriptor + LZW stream
    for fi in range(len(frames)):
        var fw = frames[fi].w
        var fh = frames[fi].h
        var n_rgba = len(frames[fi].rgba)

        # Graphic Control Extension (8 bytes)
        out.append(UInt8(0x21))
        out.append(UInt8(0xF9))
        out.append(UInt8(0x04))
        out.append(UInt8(0x04))  # Disposal 1 (keep / overwrite), no transparency
        _append_u16_le(out, delay_cs)
        out.append(UInt8(0x00))
        out.append(UInt8(0x00))

        # Image Descriptor (10 bytes)
        out.append(UInt8(0x2C))
        _append_u16_le(out, 0)
        _append_u16_le(out, 0)
        _append_u16_le(out, w)
        _append_u16_le(out, h)
        out.append(UInt8(0x00))

        # Quantize frame pixels to 256-entry global palette in O(1) per pixel
        var indices = List[UInt8](length=w * h, fill=0)
        for y in range(h):
            var sy = min(y, fh - 1) if fh > 0 else 0
            for x in range(w):
                var sx = min(x, fw - 1) if fw > 0 else 0
                var off = (sy * fw + sx) * 4
                if off + 3 < n_rgba:
                    indices[y * w + x] = _quantize_rgb_o1(
                        Int(frames[fi].rgba[off]),
                        Int(frames[fi].rgba[off + 1]),
                        Int(frames[fi].rgba[off + 2]),
                        Int(frames[fi].rgba[off + 3]),
                    )

        gif_lzw_compress_into(indices, 8, out)

    # 6. GIF Trailer
    out.append(UInt8(0x3B))
    return out^


def save_png_frames_as_gif(png_paths: List[String], out_gif_path: String, fps: Int = 12) -> Bool:
    """Decode a sequence of PNG files on disk and write an animated `GIF89a` file to `out_gif_path`."""
    if len(png_paths) == 0 or out_gif_path.byte_length() == 0:
        return False
    var frames = List[Picture]()
    for i in range(len(png_paths)):
        var raw = read_file(png_paths[i])
        if len(raw) == 0:
            return False
        var pic = png_decode(raw)
        if not pic.ok or pic.w <= 0 or pic.h <= 0:
            return False
        frames.append(pic^)
    var gif_bytes = encode_gif89a(frames, fps=fps, loop_count=0)
    if len(gif_bytes) == 0:
        return False
    return write_file(out_gif_path, gif_bytes)


# ---------------------------------------------------------------------------
# 4. Inline LaTeX Math & Fenced Mermaid Renderer
# ---------------------------------------------------------------------------

def _latex_cmd_symbol(cmd: String) -> String:
    """Map a LaTeX command name (without leading `\\`) to its Unicode math symbol, or `""`."""
    if cmd == "alpha":
        return "α"
    if cmd == "beta":
        return "β"
    if cmd == "gamma":
        return "γ"
    if cmd == "delta":
        return "δ"
    if cmd == "epsilon" or cmd == "varepsilon":
        return "ε"
    if cmd == "zeta":
        return "ζ"
    if cmd == "eta":
        return "η"
    if cmd == "theta" or cmd == "vartheta":
        return "θ"
    if cmd == "iota":
        return "ι"
    if cmd == "kappa":
        return "κ"
    if cmd == "lambda":
        return "λ"
    if cmd == "mu":
        return "μ"
    if cmd == "nu":
        return "ν"
    if cmd == "xi":
        return "ξ"
    if cmd == "omicron":
        return "ο"
    if cmd == "pi" or cmd == "varpi":
        return "π"
    if cmd == "rho" or cmd == "varrho":
        return "ρ"
    if cmd == "sigma" or cmd == "varsigma":
        return "σ"
    if cmd == "tau":
        return "τ"
    if cmd == "upsilon":
        return "υ"
    if cmd == "phi" or cmd == "varphi":
        return "φ"
    if cmd == "chi":
        return "χ"
    if cmd == "psi":
        return "ψ"
    if cmd == "omega":
        return "ω"
    if cmd == "Gamma":
        return "Γ"
    if cmd == "Delta":
        return "Δ"
    if cmd == "Theta":
        return "Θ"
    if cmd == "Lambda":
        return "Λ"
    if cmd == "Xi":
        return "Ξ"
    if cmd == "Pi":
        return "Π"
    if cmd == "Sigma":
        return "Σ"
    if cmd == "Upsilon":
        return "Υ"
    if cmd == "Phi":
        return "Φ"
    if cmd == "Psi":
        return "Ψ"
    if cmd == "Omega":
        return "Ω"
    if cmd == "nabla":
        return "∇"
    if cmd == "partial":
        return "∂"
    if cmd == "infty":
        return "∞"
    if cmd == "sum":
        return "∑"
    if cmd == "prod":
        return "∏"
    if cmd == "int":
        return "∫"
    if cmd == "sqrt":
        return "√"
    if cmd == "approx":
        return "≈"
    if cmd == "neq" or cmd == "ne":
        return "≠"
    if cmd == "leq" or cmd == "le":
        return "≤"
    if cmd == "geq" or cmd == "ge":
        return "≥"
    if cmd == "pm":
        return "±"
    if cmd == "mp":
        return "∓"
    if cmd == "times":
        return "×"
    if cmd == "cdot":
        return "·"
    if cmd == "rightarrow" or cmd == "to":
        return "→"
    if cmd == "leftarrow":
        return "←"
    if cmd == "Rightarrow":
        return "⇒"
    if cmd == "Leftarrow":
        return "⇐"
    if cmd == "Leftrightarrow" or cmd == "iff":
        return "⇔"
    if cmd == "mapsto":
        return "↦"
    if cmd == "in":
        return "∈"
    if cmd == "notin":
        return "∉"
    if cmd == "subset":
        return "⊂"
    if cmd == "subseteq":
        return "⊆"
    if cmd == "cup":
        return "∪"
    if cmd == "cap":
        return "∩"
    if cmd == "emptyset":
        return "∅"
    if cmd == "forall":
        return "∀"
    if cmd == "exists":
        return "∃"
    if cmd == "equiv":
        return "≡"
    if cmd == "sim":
        return "∼"
    if cmd == "propto":
        return "∝"
    if cmd == "oplus":
        return "⊕"
    if cmd == "otimes":
        return "⊗"
    if cmd == "dots" or cmd == "ldots" or cmd == "cdots":
        return "…"
    return ""


def _mathbb_symbol(arg: String) -> String:
    var s = String(arg.strip())
    if s == "R":
        return "ℝ"
    if s == "N":
        return "ℕ"
    if s == "Z":
        return "ℤ"
    if s == "Q":
        return "ℚ"
    if s == "C":
        return "ℂ"
    if s == "E":
        return "𝔼"
    if s == "P":
        return "ℙ"
    return s


def _superscript_cp(cp: Int) -> Int:
    if cp == 48:
        return 0x2070  # ⁰
    if cp == 49:
        return 0x00B9  # ¹
    if cp == 50:
        return 0x00B2  # ²
    if cp == 51:
        return 0x00B3  # ³
    if cp == 52:
        return 0x2074  # ⁴
    if cp == 53:
        return 0x2075  # ⁵
    if cp == 54:
        return 0x2076  # ⁶
    if cp == 55:
        return 0x2077  # ⁷
    if cp == 56:
        return 0x2078  # ⁸
    if cp == 57:
        return 0x2079  # ⁹
    if cp == 43:
        return 0x207A  # ⁺
    if cp == 45:
        return 0x207B  # ⁻
    if cp == 61:
        return 0x207C  # ⁼
    if cp == 40:
        return 0x207D  # ⁽
    if cp == 41:
        return 0x207E  # ⁾
    if cp == 110:
        return 0x207F  # ⁿ
    if cp == 105:
        return 0x2071  # ⁱ
    if cp == 84:
        return 0x1D40  # ᵀ
    if cp == 107:
        return 0x1D4F  # ᵏ
    if cp == 106:
        return 0x02B2  # ʲ
    if cp == 120:
        return 0x02E3  # ˣ
    return -1


def _subscript_cp(cp: Int) -> Int:
    if cp >= 48 and cp <= 57:
        return 0x2080 + (cp - 48)  # ₀..₉
    if cp == 43:
        return 0x208A  # ₊
    if cp == 45:
        return 0x208B  # ₋
    if cp == 61:
        return 0x208C  # ₌
    if cp == 40:
        return 0x208D  # ₍
    if cp == 41:
        return 0x208E  # ₎
    if cp == 105:
        return 0x1D62  # ᵢ
    if cp == 106:
        return 0x2C7C  # ⱼ
    if cp == 107:
        return 0x2096  # ₖ
    if cp == 110:
        return 0x2099  # ₙ
    if cp == 97:
        return 0x2090  # ₐ
    if cp == 101:
        return 0x2091  # ₑ
    if cp == 111:
        return 0x2092  # ₒ
    if cp == 120:
        return 0x2093  # ₓ
    if cp == 109:
        return 0x2098  # ₘ
    if cp == 112:
        return 0x209A  # ₚ
    if cp == 115:
        return 0x209B  # ₛ
    if cp == 116:
        return 0x209C  # ₜ
    return -1


def _read_braced_group(cps: List[Int], pos: Int) -> Tuple[Bool, String, Int]:
    """If `cps[pos] == '{'`, read balanced `{...}` and return `(True, inner_str, next_pos)`."""
    var n = len(cps)
    var i = pos
    while i < n and cps[i] == 32:
        i += 1
    if i >= n or cps[i] != 123:
        return (False, "", pos)
    var depth = 1
    i += 1
    var start = i
    while i < n and depth > 0:
        if cps[i] == 123:
            depth += 1
        elif cps[i] == 125:
            depth -= 1
            if depth == 0:
                return (True, slice_str(cps, start, i), i + 1)
        i += 1
    return (False, "", pos)


def _convert_latex_math_body(expr: String) -> String:
    var cps = decode(expr)
    var n = len(cps)
    var out = String("")
    var i = 0

    while i < n:
        var c = cps[i]

        # LaTeX backslash command
        if c == 92 and i + 1 < n:
            var j = i + 1
            if (cps[j] >= 65 and cps[j] <= 90) or (cps[j] >= 97 and cps[j] <= 122):
                while j < n and ((cps[j] >= 65 and cps[j] <= 90) or (cps[j] >= 97 and cps[j] <= 122)):
                    j += 1
                var cmd = slice_str(cps, i + 1, j)
                if cmd == "frac":
                    var g1 = _read_braced_group(cps, j)
                    if g1[0]:
                        var g2 = _read_braced_group(cps, g1[2])
                        if g2[0]:
                            out += "(" + _convert_latex_math_body(g1[1]) + ")/(" + _convert_latex_math_body(g2[1]) + ")"
                            i = g2[2]
                            continue
                if cmd == "mathbb":
                    var gb = _read_braced_group(cps, j)
                    if gb[0]:
                        out += _mathbb_symbol(gb[1])
                        i = gb[2]
                        continue
                if cmd == "text" or cmd == "mathrm" or cmd == "mathbf" or cmd == "mathit":
                    var gt = _read_braced_group(cps, j)
                    if gt[0]:
                        out += gt[1]
                        i = gt[2]
                        continue
                if cmd == "left" or cmd == "right":
                    i = j
                    continue
                if cmd == "sqrt":
                    var gs = _read_braced_group(cps, j)
                    if gs[0]:
                        var inner_s = _convert_latex_math_body(gs[1])
                        var inner_cps = decode(inner_s)
                        if len(inner_cps) <= 1:
                            out += "√" + inner_s
                        else:
                            out += "√(" + inner_s + ")"
                        i = gs[2]
                        continue
                    out += "√"
                    i = j
                    continue

                var sym = _latex_cmd_symbol(cmd)
                if sym.byte_length() > 0:
                    out += sym
                    i = j
                    continue
                # Unknown command: keep command name without backslash
                out += cmd
                i = j
                continue
            else:
                # Escaped symbol (`\,`, `\;`, `\{`, `\}`, etc.)
                var esc = cps[j]
                if esc == 44 or esc == 59 or esc == 58 or esc == 32:
                    out += " "
                else:
                    var eb = List[UInt8]()
                    encode_cp(esc, eb)
                    out += bytes_to_str(eb)
                i = j + 1
                continue

        # Superscript `^x` or `^{...}`
        if c == 94 and i + 1 < n:
            if cps[i + 1] == 123:
                var gs = _read_braced_group(cps, i + 1)
                if gs[0]:
                    var conv = _convert_latex_math_body(gs[1])
                    var ccps = decode(conv)
                    var sup_cps = List[Int]()
                    var all_ok = len(ccps) > 0
                    for k in range(len(ccps)):
                        var sc = _superscript_cp(ccps[k])
                        if sc < 0:
                            all_ok = False
                            break
                        sup_cps.append(sc)
                    if all_ok:
                        out += to_str(sup_cps)
                    else:
                        out += "^(" + conv + ")"
                    i = gs[2]
                    continue
            else:
                var sc = _superscript_cp(cps[i + 1])
                if sc >= 0:
                    var sb = List[UInt8]()
                    encode_cp(sc, sb)
                    out += bytes_to_str(sb)
                    i += 2
                    continue

        # Subscript `_x` or `_{...}`
        if c == 95 and i + 1 < n:
            if cps[i + 1] == 123:
                var gsub = _read_braced_group(cps, i + 1)
                if gsub[0]:
                    var conv = _convert_latex_math_body(gsub[1])
                    var ccps = decode(conv)
                    var sub_cps = List[Int]()
                    var all_ok = len(ccps) > 0
                    for k in range(len(ccps)):
                        var sc = _subscript_cp(ccps[k])
                        if sc < 0:
                            all_ok = False
                            break
                        sub_cps.append(sc)
                    if all_ok:
                        out += to_str(sub_cps)
                    else:
                        out += "_(" + conv + ")"
                    i = gsub[2]
                    continue
            else:
                var sc = _subscript_cp(cps[i + 1])
                if sc >= 0:
                    var sb = List[UInt8]()
                    encode_cp(sc, sb)
                    out += bytes_to_str(sb)
                    i += 2
                    continue

        # Unwrap grouping braces `{...}` if leftover
        if c == 123 or c == 125:
            i += 1
            continue

        var cb = List[UInt8]()
        encode_cp(c, cb)
        out += bytes_to_str(cb)
        i += 1

    return out


def render_latex_inline(line: String) -> String:
    """Convert `$...$` and `$$...$$` math spans inside a Markdown line to Unicode math,
    leaving backtick code spans (`` `...` ``) untouched."""
    if line.find("$") < 0:
        return line
    var cps = decode(line)
    var n = len(cps)
    var out = String("")
    var i = 0

    while i < n:
        var c = cps[i]

        # Preserve inline code backtick spans (`...` or ``...``) verbatim
        if c == 96:
            var tick_n = 0
            while i + tick_n < n and cps[i + tick_n] == 96:
                tick_n += 1
            var j = i + tick_n
            var close_at = -1
            while j + tick_n <= n:
                var match_t = True
                for k in range(tick_n):
                    if cps[j + k] != 96:
                        match_t = False
                        break
                if match_t and (j + tick_n == n or cps[j + tick_n] != 96):
                    close_at = j + tick_n
                    break
                j += 1
            var end_tick = close_at if close_at >= 0 else n
            out += slice_str(cps, i, end_tick)
            i = end_tick
            continue

        # Escaped `\$`
        if c == 92 and i + 1 < n and cps[i + 1] == 36:
            out += "\\$"
            i += 2
            continue

        # Display math `$$...$$`
        if c == 36 and i + 1 < n and cps[i + 1] == 36:
            var j = i + 2
            var close_dd = -1
            while j + 1 < n:
                if cps[j] == 36 and cps[j + 1] == 36 and (j == i + 2 or cps[j - 1] != 92):
                    close_dd = j
                    break
                j += 1
            if close_dd > i + 2:
                var inner = String(slice_str(cps, i + 2, close_dd).strip())
                out += _convert_latex_math_body(inner)
                i = close_dd + 2
                continue

        # Inline math `$...$`
        if c == 36:
            var j = i + 1
            var close_d = -1
            while j < n:
                if cps[j] == 36 and cps[j - 1] != 92:
                    close_d = j
                    break
                j += 1
            if close_d > i + 1:
                var raw_inner = slice_str(cps, i + 1, close_d)
                # Guard against plain currency like "$5 and $10" (starts with digit, ends with space, no math markers)
                var is_currency = (
                    cps[i + 1] >= 48
                    and cps[i + 1] <= 57
                    and cps[close_d - 1] == 32
                    and raw_inner.find("\\") < 0
                    and raw_inner.find("^") < 0
                    and raw_inner.find("_") < 0
                    and raw_inner.find("=") < 0
                )
                if not is_currency:
                    out += _convert_latex_math_body(String(raw_inner.strip()))
                    i = close_d + 1
                    continue

        var b = List[UInt8]()
        encode_cp(c, b)
        out += bytes_to_str(b)
        i += 1

    return out


@fieldwise_init
struct _MermaidEdge(Copyable, Movable):
    var src: Int
    var dst: Int
    var label: String


def _register_mermaid_node(
    raw_spec: String, mut ids: List[String], mut labels: List[String]
) -> Int:
    """Parse `A["Label"]`, `A(Label)`, `A{Label}`, or bare `A` and register/update its label."""
    var s = String(raw_spec.strip())
    if s.byte_length() == 0:
        return -1
    var bs = s.as_bytes()
    var n = len(bs)
    var id_end = 0
    while id_end < n and _is_ident_byte(bs[id_end]):
        id_end += 1
    if id_end == 0:
        return -1

    var node_id = String(s[byte=0:id_end])
    var rest = String(s[byte=id_end:].strip())
    var explicit_lbl = String("")
    if rest.byte_length() >= 2:
        var rbs = rest.as_bytes()
        var rn = len(rbs)
        var open_b = rbs[0]
        var close_b = rbs[rn - 1]
        if (
            (open_b == 91 and close_b == 93)
            or (open_b == 40 and close_b == 41)
            or (open_b == 123 and close_b == 125)
        ):
            var inner = String(rest[byte=1 : rn - 1].strip())
            if inner.byte_length() >= 2 and inner.startswith("(") and inner.endswith(")"):
                var inner2 = String(inner[byte=1 : inner.byte_length() - 1].strip())
                inner = inner2
            explicit_lbl = _unquote_str(inner)[1]

    for k in range(len(ids)):
        if ids[k] == node_id:
            if explicit_lbl.byte_length() > 0:
                labels[k] = explicit_lbl
            return k

    ids.append(node_id)
    labels.append(explicit_lbl if explicit_lbl.byte_length() > 0 else node_id)
    return len(ids) - 1


def _find_mermaid_arrow(stmt: String, start_at: Int) -> Tuple[Int, Int, String]:
    """Find next Mermaid edge operator (`-->|lbl|`, `-- lbl -->`, `-.->`, `==>`, `-->`, `---`) outside quotes/brackets.
    Returns `(arrow_start, arrow_end, edge_label)` or `(-1, -1, "")`."""
    var bs = stmt.as_bytes()
    var n = len(bs)
    var quote: UInt8 = 0
    var depth = 0
    var i = start_at

    while i < n:
        var b = bs[i]
        if quote != 0:
            if b == 92 and i + 1 < n:
                i += 2
                continue
            if b == quote:
                quote = 0
            i += 1
            continue
        if b == 34 or b == 39:
            quote = b
            i += 1
            continue
        if b == 91 or b == 40 or b == 123:
            depth += 1
            i += 1
            continue
        if b == 93 or b == 41 or b == 125:
            if depth > 0:
                depth -= 1
            i += 1
            continue

        if depth == 0:
            # Check `-->`, `-.->`, `==>`, `---`, or `-- text -->`
            var arrow_end = -1
            var mid_lbl = String("")
            if i + 3 <= n and bs[i] == 45 and bs[i + 1] == 45 and bs[i + 2] == 62:
                arrow_end = i + 3
            elif i + 4 <= n and bs[i] == 45 and bs[i + 1] == 46 and bs[i + 2] == 45 and bs[i + 3] == 62:
                arrow_end = i + 4
            elif i + 3 <= n and bs[i] == 61 and bs[i + 1] == 61 and bs[i + 2] == 62:
                arrow_end = i + 3
            elif i + 3 <= n and bs[i] == 45 and bs[i + 1] == 45 and bs[i + 2] == 45:
                arrow_end = i + 3
            elif i + 2 < n and bs[i] == 45 and bs[i + 1] == 45 and bs[i + 2] == 32:
                var close_arr = stmt.find("-->", i + 2)
                if close_arr > i + 2:
                    mid_lbl = _unquote_str(String(stmt[byte=i + 2 : close_arr].strip()))[1]
                    arrow_end = close_arr + 3

            if arrow_end >= 0:
                var j = arrow_end
                while j < n and bs[j] == 32:
                    j += 1
                if j < n and bs[j] == 124:
                    var pipe_end = stmt.find("|", j + 1)
                    if pipe_end > j:
                        mid_lbl = _unquote_str(String(stmt[byte=j + 1 : pipe_end].strip()))[1]
                        arrow_end = pipe_end + 1
                return (i, arrow_end, mid_lbl)
        i += 1

    return (-1, -1, "")


def _repeat_str(ch: String, count: Int) -> String:
    var out = String("")
    for _ in range(max(0, count)):
        out += ch
    return out


def _center_pad(text: String, width: Int) -> String:
    var w = cp_len(text)
    if w >= width:
        return pad_right(text, width)
    var left = (width - w) // 2
    var right = width - w - left
    return _repeat_str(" ", left) + text + _repeat_str(" ", right)


def render_mermaid_diagram(source: String) -> List[String]:
    """Parse `graph TD`/`LR` and `flowchart TD`/`LR` Mermaid blocks and render Unicode
    rounded-box (`╭───╮` / `╰───╯`) + arrow (`───▶` / `│` + `▼`) diagrams."""
    var out = List[String]()
    var is_lr = False
    var ids = List[String]()
    var labels = List[String]()
    var edges = List[_MermaidEdge]()

    for raw_ln in source.split("\n"):
        var ln = String(raw_ln.strip())
        if ln.byte_length() == 0 or ln.startswith("```") or ln.startswith("%%"):
            continue
        for semi_part in _split_top_level(ln, 59):
            var stmt = String(semi_part.strip())
            if stmt.byte_length() == 0:
                continue
            var low = lower_str(stmt)
            if low.startswith("graph ") or low.startswith("flowchart ") or low == "graph" or low == "flowchart":
                if low.endswith(" lr") or low.find(" lr ") >= 0:
                    is_lr = True
                elif low.endswith(" td") or low.endswith(" tb"):
                    is_lr = False
                continue
            if low.startswith("subgraph ") or low == "end" or low.startswith("classdef ") or low.startswith("style "):
                continue

            var ar = _find_mermaid_arrow(stmt, 0)
            if ar[0] < 0:
                _ = _register_mermaid_node(stmt, ids, labels)
                continue

            var prev_idx = _register_mermaid_node(String(stmt[byte=0 : ar[0]]), ids, labels)
            var cur_pos = ar[1]
            var cur_lbl = ar[2]
            while True:
                var nxt_ar = _find_mermaid_arrow(stmt, cur_pos)
                var rhs_str = String(stmt[byte=cur_pos : nxt_ar[0]]) if nxt_ar[0] >= 0 else String(stmt[byte=cur_pos:])
                var dst_idx = _register_mermaid_node(rhs_str, ids, labels)
                if prev_idx >= 0 and dst_idx >= 0:
                    edges.append(_MermaidEdge(prev_idx, dst_idx, cur_lbl))
                if nxt_ar[0] < 0:
                    break
                prev_idx = dst_idx
                cur_pos = nxt_ar[1]
                cur_lbl = nxt_ar[2]

    var n_nodes = len(ids)
    if n_nodes == 0:
        return out^

    # Compute longest-path DAG layer for each node (bounded by n_nodes to stay cycle-safe)
    var layers = List[Int](length=n_nodes, fill=0)
    for _ in range(n_nodes - 1):
        var changed = False
        for e in range(len(edges)):
            var u = edges[e].src
            var v = edges[e].dst
            if u != v and layers[v] < layers[u] + 1 and layers[u] + 1 < n_nodes:
                layers[v] = layers[u] + 1
                changed = True
        if not changed:
            break

    var max_layer = 0
    for i in range(n_nodes):
        if layers[i] > max_layer:
            max_layer = layers[i]

    var layer_groups = List[List[Int]]()
    for lv in range(max_layer + 1):
        var grp = List[Int]()
        for i in range(n_nodes):
            if layers[i] == lv:
                grp.append(i)
        if len(grp) > 0:
            layer_groups.append(grp^)

    if is_lr:
        # Left-to-Right layout: render columns separated by `───▶` (or `── lbl ──▶`)
        var max_rows_in_col = 1
        var col_inner_w = List[Int]()
        var edge_strs = List[String]()

        for c in range(len(layer_groups)):
            if len(layer_groups[c]) > max_rows_in_col:
                max_rows_in_col = len(layer_groups[c])
            var cw = 3
            for k in range(len(layer_groups[c])):
                var lw = cp_len(labels[layer_groups[c][k]]) + 2
                if lw > cw:
                    cw = lw
            col_inner_w.append(cw)

            if c + 1 < len(layer_groups):
                var elbls = List[String]()
                for e in range(len(edges)):
                    if layers[edges[e].src] == c and layers[edges[e].dst] == c + 1 and edges[e].label.byte_length() > 0:
                        elbls.append(edges[e].label)
                if len(elbls) > 0:
                    edge_strs.append(" ── " + "/".join(elbls) + " ──▶ ")
                else:
                    edge_strs.append(" ───▶ ")

        for slot in range(max_rows_in_col):
            var r_top = String("")
            var r_mid = String("")
            var r_bot = String("")
            for c in range(len(layer_groups)):
                var cw = col_inner_w[c]
                if slot < len(layer_groups[c]):
                    var nd = layer_groups[c][slot]
                    r_top += "╭" + _repeat_str("─", cw) + "╮"
                    r_mid += "│" + _center_pad(labels[nd], cw) + "│"
                    r_bot += "╰" + _repeat_str("─", cw) + "╯"
                else:
                    var blank = _repeat_str(" ", cw + 2)
                    r_top += blank
                    r_mid += blank
                    r_bot += blank

                if c + 1 < len(layer_groups):
                    var estr = edge_strs[c]
                    var ew = cp_len(estr)
                    var show_arrow = slot < len(layer_groups[c]) and slot < len(layer_groups[c + 1])
                    var show_branch = slot == 0 or show_arrow
                    r_top += _repeat_str(" ", ew)
                    r_mid += estr if show_branch else _repeat_str(" ", ew)
                    r_bot += _repeat_str(" ", ew)

            out.append(String(r_top.rstrip()))
            out.append(String(r_mid.rstrip()))
            out.append(String(r_bot.rstrip()))
        return out^

    # Top-Down (`TD` / `TB`) layout
    var uniform_w = 5
    for i in range(n_nodes):
        var lw = cp_len(labels[i]) + 2
        if lw > uniform_w:
            uniform_w = lw
    if uniform_w % 2 == 0:
        uniform_w += 1  # Odd inner width centers `│` and `▼` cleanly

    for lv in range(len(layer_groups)):
        var grp = layer_groups[lv].copy()
        var r_top = String("")
        var r_mid = String("")
        var r_bot = String("")
        for k in range(len(grp)):
            var nd = grp[k]
            var sep_sp = "   " if k > 0 else ""
            r_top += sep_sp + "╭" + _repeat_str("─", uniform_w) + "╮"
            r_mid += sep_sp + "│" + _center_pad(labels[nd], uniform_w) + "│"
            var has_out = lv + 1 < len(layer_groups)
            if has_out:
                var half = uniform_w // 2
                r_bot += sep_sp + "╰" + _repeat_str("─", half) + "┬" + _repeat_str("─", uniform_w - half - 1) + "╯"
            else:
                r_bot += sep_sp + "╰" + _repeat_str("─", uniform_w) + "╯"
        out.append(r_top)
        out.append(r_mid)
        out.append(r_bot)

        if lv + 1 < len(layer_groups):
            var next_grp = layer_groups[lv + 1].copy()
            var n_pipes = max(len(grp), len(next_grp))
            var edge_lbls = List[String]()
            for e in range(len(edges)):
                if layers[edges[e].src] == lv and edges[e].label.byte_length() > 0:
                    edge_lbls.append(edges[e].label)
            var center_off = 1 + (uniform_w // 2)
            var pipe_line = String("")
            var arrow_line = String("")
            for p in range(n_pipes):
                var pad_before = center_off if p == 0 else (uniform_w + 4)
                pipe_line += _repeat_str(" ", pad_before if p == 0 else (pad_before - 1)) + "│"
                arrow_line += _repeat_str(" ", pad_before if p == 0 else (pad_before - 1)) + "▼"
            if len(edge_lbls) > 0:
                pipe_line += " " + ", ".join(edge_lbls)
            out.append(pipe_line)
            out.append(arrow_line)

    return out^


# ---------------------------------------------------------------------------
# 5. Optional External Jupyter `ipykernel` Client Bridge
# ---------------------------------------------------------------------------

def _py_escape_single_quoted(s: String) -> String:
    var out = String("")
    for cp in decode(s):
        if cp == 92:
            out += "\\\\"
        elif cp == 39:
            out += "\\'"
        elif cp == 10:
            out += "\\n"
        elif cp == 13:
            out += "\\r"
        else:
            var b = List[UInt8]()
            encode_cp(cp, b)
            out += bytes_to_str(b)
    return out


def build_ipykernel_bridge_daemon(conn_json_path: String) -> String:
    """Return a self-contained Python helper script bridging TurboMojo's stdin/stdout cell wire
    protocol (`RUN <seq> <lines> <filepath>` and `__TM_RUN__ <seq> <lines> <off> <filepath>` ->
    `__TM_CELL_END_<seq>_<status>__`) over `jupyter_client.BlockingKernelClient`."""
    var esc_conn = _py_escape_single_quoted(conn_json_path)
    var script = (
        "import base64 as _b64, os as _os, re as _re, sys as _sys\n"
        "_CONN_FILE = '" + esc_conn + "'\n"
        "_ANSI_RE = _re.compile(r'\\x1b\\[[0-9;]*[A-Za-z]')\n"
        "_kc = None\n"
        "_init_err = None\n"
        "try:\n"
        "    import zmq as _zmq\n"
        "    from jupyter_client import BlockingKernelClient as _BKC\n"
        "except ImportError as _exc:\n"
        "    _init_err = (\n"
        "        f'Error: External Jupyter ipykernel bridge requires jupyter_client and pyzmq ({_exc}).\\n'\n"
        "        'Install them in your Python environment with: pip install jupyter_client pyzmq'\n"
        "    )\n"
        "if _init_err is None:\n"
        "    if not _os.path.exists(_CONN_FILE):\n"
        "        _init_err = f'Error: Jupyter connection file not found: {_CONN_FILE}'\n"
        "    else:\n"
        "        try:\n"
        "            _kc = _BKC(connection_file=_CONN_FILE)\n"
        "            _kc.load_connection_file()\n"
        "            _kc.start_channels()\n"
        "            _kc.wait_for_ready(timeout=10)\n"
        "        except Exception as _ce:\n"
        "            _init_err = f'Error: Failed to connect to Jupyter kernel ({_CONN_FILE}): {_ce}'\n"
        "_failed_seq = -1\n"
        "try:\n"
        "    while True:\n"
        "        _hdr = _sys.stdin.readline()\n"
        "        if not _hdr:\n"
        "            break\n"
        "        _hs = _hdr.rstrip('\\r\\n')\n"
        "        _is_pre = False\n"
        "        _off = 0\n"
        "        if _hs.startswith('__TM_RUN__ ') or _hs.startswith('__TM_PRE__ '):\n"
        "            _is_pre = _hs.startswith('__TM_PRE__ ')\n"
        "            _ps = _hs.split(' ', 4)\n"
        "            _seq = int(_ps[1])\n"
        "            _nlines = int(_ps[2])\n"
        "            _off = int(_ps[3])\n"
        "            _fp = _ps[4] if len(_ps) > 4 else '<cell>'\n"
        "        elif _hs.startswith('RUN ') or _hs.startswith('PRE '):\n"
        "            _is_pre = _hs.startswith('PRE ')\n"
        "            _ps = _hs.split(' ', 3)\n"
        "            _seq = int(_ps[1])\n"
        "            _nlines = int(_ps[2])\n"
        "            _fp = _ps[3] if len(_ps) > 3 else '<cell>'\n"
        "        else:\n"
        "            continue\n"
        "        _lines = [_sys.stdin.readline() for _ in range(_nlines)]\n"
        "        if _seq == _failed_seq:\n"
        "            continue\n"
        "        if _init_err is not None:\n"
        "            _failed_seq = _seq\n"
        "            _pre_tag = f'\\n__TM_PRE_ERR_{_seq}__' if _is_pre else ''\n"
        "            _sys.stdout.write(f'{_init_err}{_pre_tag}\\n__TM_CELL_END_{_seq}_1__\\n')\n"
        "            _sys.stdout.flush()\n"
        "            continue\n"
        "        _code = ('\\n' * _off) + ''.join(_lines)\n"
        "        _msg_id = _kc.execute(_code, store_history=not _is_pre, allow_stdin=False)\n"
        "        _status = 0\n"
        "        _plot_idx = 0\n"
        "        while True:\n"
        "            try:\n"
        "                _msg = _kc.get_iopub_msg(timeout=30)\n"
        "            except Exception as _te:\n"
        "                _status = 1\n"
        "                _sys.stdout.write(f'Error: Timed out waiting for ipykernel iopub message: {_te}\\n')\n"
        "                break\n"
        "            if _msg.get('parent_header', {}).get('msg_id') != _msg_id:\n"
        "                continue\n"
        "            _mtype = _msg.get('msg_type', '')\n"
        "            _cnt = _msg.get('content', {}) or {}\n"
        "            if _mtype == 'status' and _cnt.get('execution_state') == 'idle':\n"
        "                break\n"
        "            if _mtype == 'stream':\n"
        "                if not _is_pre:\n"
        "                    _sys.stdout.write(_cnt.get('text', ''))\n"
        "            elif _mtype in ('display_data', 'execute_result', 'update_display_data'):\n"
        "                if not _is_pre:\n"
        "                    _mime = _cnt.get('data', {}) or {}\n"
        "                    if 'image/png' in _mime:\n"
        "                        _b64_png = _mime['image/png']\n"
        "                        _raw_png = _b64.b64decode(_b64_png) if isinstance(_b64_png, str) else bytes(_b64_png)\n"
        "                        _plot_idx += 1\n"
        "                        _pp = f'{_os.environ.get(\"TMPDIR\", \"/tmp\")}/turbomojo-ipy-{_os.getpid()}-{_seq}-{_plot_idx}.png'\n"
        "                        with open(_pp, 'wb') as _pf:\n"
        "                            _pf.write(_raw_png)\n"
        "                        _sys.stdout.write(f'\\n__TM_PLOT__ {_pp}\\n')\n"
        "                    elif 'text/plain' in _mime:\n"
        "                        _sys.stdout.write(str(_mime['text/plain']) + '\\n')\n"
        "            elif _mtype == 'error':\n"
        "                _status = 1\n"
        "                _tb_lines = _cnt.get('traceback') or [f\"{_cnt.get('ename', 'Error')}: {_cnt.get('evalue', '')}\"]\n"
        "                for _tbl in _tb_lines:\n"
        "                    _sys.stdout.write(_ANSI_RE.sub('', str(_tbl)).replace('<ipython-input', _fp) + '\\n')\n"
        "        if _is_pre:\n"
        "            if _status != 0:\n"
        "                _failed_seq = _seq\n"
        "                _sys.stdout.write(f'\\n__TM_PRE_ERR_{_seq}__\\n__TM_CELL_END_{_seq}_1__\\n')\n"
        "                _sys.stdout.flush()\n"
        "            continue\n"
        "        _sys.stdout.write(f'\\n__TM_CELL_END_{_seq}_{_status}__\\n')\n"
        "        _sys.stdout.flush()\n"
        "finally:\n"
        "    if _kc is not None:\n"
        "        try:\n"
        "            _kc.stop_channels()\n"
        "        except Exception:\n"
        "            pass\n"
    )
    return script
