"""Live Tensor, SIMD & DataFrame inspector for `# %%` notebooks and the DAP debugger.

Detects and summarizes:
- Mojo `SIMD[DType.*, N]`, `List[...]`, `LayoutTensor`, and MAX `Tensor` values
- Python `numpy.ndarray`, `torch.Tensor`, `pandas.DataFrame`, and `polars.DataFrame` objects
  (via lightweight introspection in `PYTHON_TENSOR_INSPECT_HELPER` without importing unused packages)
- Numeric distribution stats (`min`, `max`, `mean`) and explicit `NaN` / `Inf` anomaly warnings
"""
from std.collections import List
from util import decode, to_str, slice_str, lower_str


# Embedded into PYTHON_CELL_DAEMON_SCRIPT: inspects already-loaded array/tensor/DataFrame types
# without importing numpy/torch/pandas/polars if the user hasn't imported them.
comptime PYTHON_TENSOR_INSPECT_HELPER = (
    "import math as __tm_math, ast as __tm_ast\n"
    "def __tm_fmt_num(v):\n"
    "    try:\n"
    "        fv = float(v)\n"
    "        if __tm_math.isnan(fv): return 'nan'\n"
    "        if __tm_math.isinf(fv): return 'inf' if fv > 0 else '-inf'\n"
    "        av = abs(fv)\n"
    "        if av != 0.0 and (av >= 1e5 or av < 1e-3): return f'{fv:.3g}'\n"
    "        return f'{fv:.4g}'\n"
    "    except BaseException:\n"
    "        return str(v)\n"
    "def __tm_inspect_obj(obj):\n"
    "    try:\n"
    "        tp = type(obj)\n"
    "        mod = getattr(tp, '__module__', '') or ''\n"
    "        tname = getattr(tp, '__name__', '') or ''\n"
    "        if tname == 'DataFrame' and ('pandas' in mod or 'polars' in mod or (hasattr(obj, 'columns') and hasattr(obj, 'shape'))):\n"
    "            sh = getattr(obj, 'shape', (0, 0))\n"
    "            cols = list(getattr(obj, 'columns', []))[:5]\n"
    "            dtypes = getattr(obj, 'dtypes', None)\n"
    "            cparts = []\n"
    "            for idx, c in enumerate(cols):\n"
    "                dt_s = ''\n"
    "                try:\n"
    "                    dt_v = dtypes[c] if hasattr(dtypes, '__getitem__') and 'pandas' in mod else (dtypes[idx] if dtypes is not None else '')\n"
    "                    dt_s = f'({dt_v})' if dt_v != '' else ''\n"
    "                except BaseException:\n"
    "                    dt_s = ''\n"
    "                cparts.append(f'{c}{dt_s}')\n"
    "            more = f', +{int(sh[1]) - len(cols)} more' if int(sh[1]) > len(cols) else ''\n"
    "            nulls = 0\n"
    "            try:\n"
    "                if 'polars' in mod: nulls = int(sum(obj.null_count().row(0)))\n"
    "                elif hasattr(obj, 'isna'): nulls = int(obj.isna().sum().sum())\n"
    "            except BaseException:\n"
    "                nulls = 0\n"
    "            ntag = f' · ⚠ {nulls} null' if nulls > 0 else ' · 0 null'\n"
    "            lib = 'Polars' if 'polars' in mod else 'DataFrame'\n"
    "            return f'[{lib} {sh[0]}×{sh[1]} · cols: {\", \".join(cparts)}{more}{ntag}]'\n"
    "        if hasattr(obj, 'shape') and hasattr(obj, 'dtype') and not isinstance(obj, (str, bytes, dict, list, tuple)):\n"
    "            sh = [int(d) for d in getattr(obj, 'shape', ())]\n"
    "            dt = str(getattr(obj, 'dtype', '')).replace('torch.', '').replace('numpy.', '')\n"
    "            dev = str(getattr(obj, 'device', '')) if hasattr(obj, 'device') else ''\n"
    "            dev_s = f' · {dev}' if dev and dev != 'cpu' else (' · cuda:0' if 'cuda' in dev else '')\n"
    "            st_s = ''\n"
    "            try:\n"
    "                if callable(getattr(obj, 'stride', None)):\n"
    "                    st_s = f' · stride={list(obj.stride())}'\n"
    "                elif hasattr(obj, 'strides') and getattr(obj, 'strides') is not None:\n"
    "                    itsz = int(getattr(obj, 'itemsize', 1)) or 1\n"
    "                    st_s = f' · stride={[int(s)//itsz for s in obj.strides]}'\n"
    "            except BaseException:\n"
    "                st_s = ''\n"
    "            stats = ''\n"
    "            try:\n"
    "                if 'torch' in mod:\n"
    "                    t_det = obj.detach()\n"
    "                    n_el = int(t_det.numel())\n"
    "                    if n_el > 0 and (t_det.is_floating_point() or not t_det.is_complex()):\n"
    "                        tf = t_det.float()\n"
    "                        nans = int(tf.isnan().sum().item())\n"
    "                        infs = int(tf.isinf().sum().item())\n"
    "                        valid = tf[~(tf.isnan() | tf.isinf())]\n"
    "                        if int(valid.numel()) > 0:\n"
    "                            stats = f' · min={__tm_fmt_num(valid.min().item())} max={__tm_fmt_num(valid.max().item())} mean={__tm_fmt_num(valid.mean().item())}'\n"
    "                        anom = []\n"
    "                        if nans > 0: anom.append(f'⚠ {nans} NaN')\n"
    "                        if infs > 0: anom.append(f'⚠ {infs} Inf')\n"
    "                        stats += (' · ' + ' · '.join(anom)) if anom else ' · 0 NaN'\n"
    "                elif 'numpy' in mod or hasattr(obj, 'ravel'):\n"
    "                    np_m = __tm_sys.modules.get('numpy')\n"
    "                    n_el = int(getattr(obj, 'size', 0))\n"
    "                    if np_m is not None and n_el > 0 and getattr(obj.dtype, 'kind', '') in ('f', 'i', 'u'):\n"
    "                        arr_f = np_m.asarray(obj, dtype=float).ravel()\n"
    "                        nans = int(np_m.isnan(arr_f).sum())\n"
    "                        infs = int(np_m.isinf(arr_f).sum())\n"
    "                        fin = arr_f[np_m.isfinite(arr_f)]\n"
    "                        if fin.size > 0:\n"
    "                            stats = f' · min={__tm_fmt_num(fin.min())} max={__tm_fmt_num(fin.max())} mean={__tm_fmt_num(fin.mean())}'\n"
    "                        anom = []\n"
    "                        if nans > 0: anom.append(f'⚠ {nans} NaN')\n"
    "                        if infs > 0: anom.append(f'⚠ {infs} Inf')\n"
    "                        stats += (' · ' + ' · '.join(anom)) if anom else ' · 0 NaN'\n"
    "            except BaseException:\n"
    "                pass\n"
    "            kind_lbl = 'Tensor' if ('torch' in mod or 'max' in mod or 'Tensor' in tname) else 'Array'\n"
    "            sh_str = ', '.join(str(d) for d in sh)\n"
    "            return f'[{kind_lbl} {dt}[{sh_str}]{dev_s}{st_s}{stats}]'\n"
    "    except BaseException:\n"
    "        return ''\n"
    "    return ''\n"
)


@fieldwise_init
struct NumericStats(Copyable, Movable):
    var count: Int
    var finite_count: Int
    var nan_count: Int
    var inf_count: Int
    var min_val: Float64
    var max_val: Float64
    var mean_val: Float64


def _fmt_float_compact(v: Float64) -> String:
    var iv = Int(v)
    if Float64(iv) == v and iv >= -999999 and iv <= 999999:
        return String(iv) + ".0"
    var neg = v < 0.0
    var av = -v if neg else v
    var scaled = Int(av * 100.0 + 0.5)
    var whole = scaled // 100
    var frac = scaled % 100
    var sign = String("-") if neg else String("")
    var frac_s = ("0" + String(frac)) if frac < 10 else String(frac)
    if frac_s.endswith("0"):
        var fsub = String(frac_s[byte=0:1])
        frac_s = fsub
    return sign + String(whole) + "." + frac_s


def _is_num_token_char(c: Int) -> Bool:
    return (
        (c >= 48 and c <= 57)
        or c == 46
        or c == 45
        or c == 43
        or c == 101
        or c == 69
    )


def parse_numeric_elements(raw: String) -> NumericStats:
    """Scan numeric vector/brace/bracket values (including `nan`, `inf`, `-inf`, `[0] = 1.25`)
    and compute count, finite min/max/mean, NaN count, and Inf count."""
    var cleaned = raw
    # Strip LLDB `[idx] = ` indices so `[0] = 1.5, [1] = nan` doesn't count indices `0, 1` as elements
    var stripped_parts = List[String]()
    var i = 0
    var n_bytes = cleaned.byte_length()
    while i < n_bytes:
        if cleaned[byte=i : i + 1] == "[":
            var close_b = cleaned.find("]", i + 1)
            if close_b > i + 1 and close_b - i <= 8:
                var idx_txt = String(cleaned[byte=i + 1 : close_b].strip())
                var all_dig = idx_txt.byte_length() > 0
                for b in idx_txt.as_bytes():
                    if b < 48 or b > 57:
                        all_dig = False
                        break
                if all_dig:
                    var after = String(cleaned[byte=close_b + 1 :].lstrip())
                    if after.startswith("="):
                        var eq_pos = cleaned.find("=", close_b + 1)
                        i = eq_pos + 1
                        continue
        stripped_parts.append(String(cleaned[byte=i : i + 1]))
        i += 1
    var body = "".join(stripped_parts)

    var count = 0
    var fin_count = 0
    var nan_n = 0
    var inf_n = 0
    var mn = 0.0
    var mx = 0.0
    var total = 0.0

    var norm = body.replace("{", " ").replace("}", " ").replace("[", " ").replace("]", " ").replace(",", " ").replace("(", " ").replace(")", " ")
    for tok_s in norm.split(" "):
        var tok = lower_str(String(tok_s.strip()))
        if tok.byte_length() == 0:
            continue
        if tok == "nan" or tok == "-nan" or tok == "+nan":
            count += 1
            nan_n += 1
            continue
        if tok == "inf" or tok == "+inf" or tok == "-inf" or tok == "infinity" or tok == "-infinity":
            count += 1
            inf_n += 1
            continue
        var cps = decode(tok)
        var has_digit = False
        var valid = True
        for cp in cps:
            if cp >= 48 and cp <= 57:
                has_digit = True
            elif not _is_num_token_char(cp):
                valid = False
                break
        if not valid or not has_digit:
            continue
        try:
            var fv = atof(tok)
            count += 1
            if fin_count == 0:
                mn = fv
                mx = fv
            else:
                if fv < mn:
                    mn = fv
                if fv > mx:
                    mx = fv
            total += fv
            fin_count += 1
        except:
            pass

    var mean_v = (total / Float64(fin_count)) if fin_count > 0 else 0.0
    return NumericStats(count, fin_count, nan_n, inf_n, mn, mx, mean_v)


def _normalize_mojo_dtype(raw_dt: String) -> String:
    var s = String(raw_dt.strip())
    if s.startswith("DType."):
        var sub = String(s[byte=6:])
        s = sub
    return s


def summarize_mojo_value(name: String, type_name: String, raw_value: String) -> String:
    """Inspect a Mojo / LLDB variable `(type_name, raw_value)` and return a compact summary card
    (e.g. `[SIMD float32[4] · min=1.0 max=4.0 mean=2.5 · ⚠ 1 NaN]`), or `""` for scalar/non-tensor values."""
    var t = String(type_name.strip())
    var v = String(raw_value.strip())
    var low_t = lower_str(t)

    var is_simd = low_t.startswith("simd[") or low_t.find("::simd<") >= 0 or low_t.find("simd[") >= 0
    var is_tensor = (
        low_t.find("layouttensor") >= 0
        or low_t.find("tensor[") >= 0
        or low_t.find("ndbuffer") >= 0
        or low_t.find("devicebuffer") >= 0
    )
    if not is_simd and not is_tensor:
        # Check if raw_value itself starts with `SIMD[` or `Tensor(`
        if v.startswith("SIMD[") or v.startswith("LayoutTensor[") or v.startswith("Tensor["):
            t = v
            low_t = lower_str(t)
            is_simd = low_t.startswith("simd[")
        else:
            return ""

    var dtype_lbl = String("float32")
    var shape_lbl = String("?")
    var lb = t.find("[")
    var rb = t.find("]", lb + 1) if lb >= 0 else -1
    if lb >= 0 and rb > lb + 1:
        var params = String(t[byte=lb + 1 : rb])
        var comma = params.find(",")
        if comma >= 0:
            dtype_lbl = _normalize_mojo_dtype(String(params[byte=0:comma]))
            shape_lbl = String(params[byte=comma + 1 :].strip())
        else:
            dtype_lbl = _normalize_mojo_dtype(params)

    var val_body = v
    var eq_brace = v.find("{")
    if eq_brace >= 0:
        val_body = String(v[byte=eq_brace:])
    elif v.find("[") >= 0 and not v.startswith("SIMD[") and not v.startswith("Tensor[") and not v.startswith("LayoutTensor["):
        val_body = String(v[byte=v.find("["):])

    var st = parse_numeric_elements(val_body)
    if shape_lbl == "?" and st.count > 0:
        shape_lbl = String(st.count)

    var kind_lbl = String("SIMD") if is_simd else String("Tensor")
    var dev_part = String("")
    if low_t.find("cuda") >= 0 or v.find("cuda:") >= 0:
        dev_part = " · cuda:0"
    elif low_t.find("devicebuffer") >= 0 or low_t.find("gpu") >= 0:
        dev_part = " · gpu"

    var stats_part = String("")
    if st.count > 0:
        if st.finite_count > 0:
            stats_part += (
                " · min="
                + _fmt_float_compact(st.min_val)
                + " max="
                + _fmt_float_compact(st.max_val)
                + " mean="
                + _fmt_float_compact(st.mean_val)
            )
        var anoms = List[String]()
        if st.nan_count > 0:
            anoms.append("⚠ " + String(st.nan_count) + " NaN")
        if st.inf_count > 0:
            anoms.append("⚠ " + String(st.inf_count) + " Inf")
        if len(anoms) > 0:
            stats_part += " · " + " · ".join(anoms)
        else:
            stats_part += " · 0 NaN"

    var prefix = (name + ": ") if name.byte_length() > 0 else String("")
    return prefix + "[" + kind_lbl + " " + dtype_lbl + "[" + shape_lbl + "]" + dev_part + stats_part + "]"


def _try_parse_lldb_dump_card(block: String) -> String:
    """Parse an LLDB variable dump `(SIMD[DType.float32, 4]) x = { ... }` into a summary card."""
    var tr = String(block.lstrip())
    if not tr.startswith("("):
        return ""
    var close_p = tr.find(") ")
    if close_p <= 1:
        return ""
    var tp = String(tr[byte=1:close_p])
    var rest = String(tr[byte=close_p + 2:])
    var eq = rest.find(" = ")
    if eq <= 0:
        return ""
    var vname = String(rest[byte=0:eq].strip())
    var vval = String(rest[byte=eq + 3:])
    return summarize_mojo_value(vname, tp, vval)


def extract_tensor_cards(text: String) -> Tuple[String, List[String]]:
    """Extract `__TM_CARD__ <card>` markers (Python kernel) and synthesize cards for
    Mojo REPL `(SIMD[...])` / `(LayoutTensor[...])` variable dumps.
    Returns `(formatted_display_text, cards)`."""
    var cards = List[String]()
    if (
        text.find("__TM_CARD__ ") < 0
        and text.find("(SIMD[") < 0
        and text.find("(LayoutTensor[") < 0
        and text.find("(Tensor[") < 0
    ):
        return (text, cards^)

    var raw_lines = List[String]()
    for ln_s in text.split("\n"):
        raw_lines.append(String(ln_s))

    var out_lines = List[String]()
    var i = 0
    var n = len(raw_lines)
    while i < n:
        var ln = raw_lines[i]
        var tr = String(ln.strip())
        if tr.startswith("__TM_CARD__ "):
            var card = String(tr[byte=12:].strip())
            if card.byte_length() > 0:
                cards.append(card)
                out_lines.append(card)
            i += 1
            continue
        if tr.startswith("(SIMD[") or tr.startswith("(LayoutTensor[") or tr.startswith("(Tensor["):
            var accum = List[String]()
            accum.append(ln)
            if ln.find("{") >= 0 and ln.find("}") < 0:
                var j = i + 1
                while j < n:
                    accum.append(raw_lines[j])
                    if String(raw_lines[j].strip()) == "}":
                        j += 1
                        break
                    j += 1
                var card = _try_parse_lldb_dump_card("\n".join(accum))
                if card.byte_length() > 0:
                    cards.append(card)
                    out_lines.append(card)
                    i = j
                    continue
            else:
                var card = _try_parse_lldb_dump_card(ln)
                if card.byte_length() > 0:
                    cards.append(card)
                    out_lines.append(card)
                    i += 1
                    continue
        out_lines.append(ln)
        i += 1
    return ("\n".join(out_lines), cards^)
