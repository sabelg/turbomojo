"""Pure-Mojo Concrete Syntax Tree (CST) parser for Mojo 1.2+.

Built directly over `Highlighter` codepoint classifications (`C_CMT`, `C_STR`) so strings,
triple-quoted docstrings, and comments never confuse structural analysis. Parses:
- `struct` declarations (`[comptime_params]`, `(Trait1, Trait2)`, `var` fields, methods)
- `trait` declarations and required method signatures
- `def` functions & methods (`@decorator`s, `[comptime_params]`, `(name: mut/var/out Type = default)`,
  `raises`, `abi(...)`, `-> ReturnType`, header/parameter/body spans)
- Single- and multi-line call expressions with exact per-argument spans and keyword labels
- Concentric syntax-aware `cst_selection_ranges` for Expand/Shrink Selection
"""
from std.collections import List
from buffer import TextBuffer
from highlight import Highlighter, HL_MOJO, C_CMT, C_STR
from util import decode, to_str, slice_str, is_alpha, is_ident


@fieldwise_init
struct CstSpan(Copyable, Movable):
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int


@fieldwise_init
struct CstParam(Copyable, Movable):
    var name: String
    var convention: String      # "", "mut", "var", "out", "ref"
    var type_expr: String
    var default_expr: String
    var is_self: Bool
    var raw_text: String


@fieldwise_init
struct CstField(Copyable, Movable):
    var name: String
    var type_expr: String
    var row: Int


@fieldwise_init
struct CstDefNode(Copyable, Movable):
    var name: String
    var decorators: List[String]
    var comptime_params: List[CstParam]
    var params: List[CstParam]
    var is_raises: Bool
    var abi_attr: String
    var return_type: String
    var deco_start_row: Int
    var header_span: CstSpan
    var params_span: CstSpan    # inside `(` .. `)` exclusive of parens
    var body_span: CstSpan
    var indent: Int


@fieldwise_init
struct CstStructNode(Copyable, Movable):
    var name: String
    var comptime_params: String
    var traits: List[String]
    var fields: List[CstField]
    var methods: List[CstDefNode]
    var deco_start_row: Int
    var header_span: CstSpan
    var body_span: CstSpan
    var indent: Int


@fieldwise_init
struct CstTraitNode(Copyable, Movable):
    var name: String
    var methods: List[CstDefNode]
    var header_span: CstSpan
    var body_span: CstSpan
    var indent: Int


@fieldwise_init
struct CstCallSite(Copyable, Movable):
    var ok: Bool
    var callee: String
    var span: CstSpan           # callee start .. closing `)` inclusive
    var open_r: Int
    var open_c: Int             # column of `(`
    var close_r: Int
    var close_c: Int            # column of `)`
    var arg_spans: List[CstSpan]
    var arg_texts: List[String]
    var arg_kw_names: List[String]


struct MojoCst(Copyable, Movable):
    var structs: List[CstStructNode]
    var traits: List[CstTraitNode]
    var defs: List[CstDefNode]  # all defs (top-level and methods)

    def __init__(out self):
        self.structs = List[CstStructNode]()
        self.traits = List[CstTraitNode]()
        self.defs = List[CstDefNode]()


def _is_code(cls: List[Int], col: Int) -> Bool:
    if col < 0 or col >= len(cls):
        return False
    return cls[col] != C_CMT and cls[col] != C_STR


def _line_indent(cps: List[Int], cls: List[Int]) -> Int:
    var n = len(cps)
    var i = 0
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    if i >= n or not _is_code(cls, i):
        return -1
    return i


def _code_end(cps: List[Int], cls: List[Int]) -> Int:
    var n = len(cps)
    for i in range(n):
        if cls[i] == C_CMT:
            var e = i
            while e > 0 and (cps[e - 1] == 32 or cps[e - 1] == 9):
                e -= 1
            return e
    var e = n
    while e > 0 and (cps[e - 1] == 32 or cps[e - 1] == 9):
        e -= 1
    return e


def _tokenize_buffer(buf: TextBuffer) -> Tuple[List[List[Int]], List[List[Int]]]:
    var lines_cps = List[List[Int]]()
    var lines_cls = List[List[Int]]()
    var hl = Highlighter()
    var st = 0
    for r in range(buf.count()):
        var cps = buf.line(r)
        var cls = List[Int]()
        st = hl.line(cps, st, cls, HL_MOJO)
        lines_cps.append(cps^)
        lines_cls.append(cls^)
    return (lines_cps^, lines_cls^)


def _split_top_level_commas(text: String) -> List[String]:
    var parts = List[String]()
    var cps = decode(text)
    var n = len(cps)
    var pdepth = 0
    var bdepth = 0
    var cdepth = 0
    var in_q = 0
    var start = 0
    var i = 0
    while i < n:
        var c = cps[i]
        if in_q != 0:
            if c == 92:
                i += 2
                continue
            if c == in_q:
                in_q = 0
            i += 1
            continue
        if c == 34 or c == 39:
            in_q = c
        elif c == 40:
            pdepth += 1
        elif c == 41:
            pdepth = max(0, pdepth - 1)
        elif c == 91:
            bdepth += 1
        elif c == 93:
            bdepth = max(0, bdepth - 1)
        elif c == 123:
            cdepth += 1
        elif c == 125:
            cdepth = max(0, cdepth - 1)
        elif c == 44 and pdepth == 0 and bdepth == 0 and cdepth == 0:
            var item = String(slice_str(cps, start, i).strip())
            if item.byte_length() > 0:
                parts.append(item)
            start = i + 1
        i += 1
    var tail = String(slice_str(cps, start, n).strip())
    if tail.byte_length() > 0:
        parts.append(tail)
    return parts^


def parse_cst_param(raw_item: String) -> CstParam:
    """Parse a single Mojo 1.2 parameter item such as `mut self`, `out self`,
    `x: Int = 0`, `mut buf: TextBuffer`, or `var items: List[String]`."""
    var s = String(raw_item.strip())
    if s.byte_length() == 0 or s == "*" or s == "/":
        return CstParam(s, "", "", "", False, s)

    # Split top-level `=` default value first
    var cps = decode(s)
    var n = len(cps)
    var pdepth = 0
    var bdepth = 0
    var eq_idx = -1
    var colon_idx = -1
    var in_q = 0
    var i = 0
    while i < n:
        var c = cps[i]
        if in_q != 0:
            if c == 92:
                i += 2
                continue
            if c == in_q:
                in_q = 0
            i += 1
            continue
        if c == 34 or c == 39:
            in_q = c
        elif c == 40:
            pdepth += 1
        elif c == 41:
            pdepth = max(0, pdepth - 1)
        elif c == 91:
            bdepth += 1
        elif c == 93:
            bdepth = max(0, bdepth - 1)
        elif pdepth == 0 and bdepth == 0:
            if c == 58 and colon_idx < 0 and eq_idx < 0:
                colon_idx = i
            elif c == 61 and eq_idx < 0:
                eq_idx = i
        i += 1

    var def_val = String("")
    var left_part = s
    if eq_idx >= 0:
        def_val = String(slice_str(cps, eq_idx + 1, n).strip())
        left_part = String(slice_str(cps, 0, eq_idx).strip())

    var lcps = decode(left_part)
    var ln = len(lcps)
    var conv = String("")
    var pname = left_part
    var ptype = String("")

    if colon_idx >= 0 and colon_idx < ln:
        var head = String(slice_str(lcps, 0, colon_idx).strip())
        var tail = String(slice_str(lcps, colon_idx + 1, ln).strip())
        # Convention can appear either before name (`mut x: Int`) or before type (`x: mut Int`)
        for cv in ["mut ", "var ", "out ", "ref ", "read "]:
            var cvs = String(cv)
            if head.startswith(cvs):
                conv = String(cvs.strip())
                var hsub = String(head[byte=cvs.byte_length() :].strip())
                head = hsub
                break
        for cv in ["mut ", "var ", "out ", "ref ", "read "]:
            var cvs = String(cv)
            if tail.startswith(cvs):
                conv = String(cvs.strip())
                var tsub = String(tail[byte=cvs.byte_length() :].strip())
                tail = tsub
                break
        pname = head
        ptype = tail
    else:
        for cv in ["mut ", "var ", "out ", "ref ", "read "]:
            var cvs = String(cv)
            if pname.startswith(cvs):
                conv = String(cvs.strip())
                var psub = String(pname[byte=cvs.byte_length() :].strip())
                pname = psub
                break

    var is_s = pname == "self"
    return CstParam(pname, conv, ptype, def_val, is_s, s)


def format_cst_param(p: CstParam) -> String:
    """Format a `CstParam` in canonical Mojo 1.2 syntax."""
    if p.name == "*" or p.name == "/":
        return p.name
    if p.is_self and p.type_expr.byte_length() == 0:
        return (p.convention + " self") if p.convention.byte_length() > 0 else String("self")
    var conv_prefix = (p.convention + " ") if p.convention.byte_length() > 0 else String("")
    var out_s = conv_prefix + p.name
    if p.type_expr.byte_length() > 0:
        out_s += ": " + p.type_expr
    if p.default_expr.byte_length() > 0:
        out_s += " = " + p.default_expr
    return out_s


def _find_matching_delim(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    open_r: Int,
    open_c: Int,
    open_cp: Int,
    close_cp: Int,
) -> Tuple[Int, Int]:
    var depth = 0
    var nlines = len(lines_cps)
    for r in range(open_r, nlines):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var start_c = open_c if r == open_r else 0
        for c in range(start_c, len(cps)):
            if not _is_code(cls, c):
                continue
            if cps[c] == open_cp:
                depth += 1
            elif cps[c] == close_cp:
                depth -= 1
                if depth == 0:
                    return (r, c)
    return (-1, -1)


def _find_block_end_row(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    after_header_row: Int,
    decl_indent: Int,
) -> Int:
    var nlines = len(lines_cps)
    var last_body_row = after_header_row
    var r = after_header_row + 1
    while r < nlines:
        var ind = _line_indent(lines_cps[r], lines_cls[r])
        if ind >= 0:
            if ind <= decl_indent:
                break
            last_body_row = r
        r += 1
    return last_body_row


def _extract_span_text(lines_cps: List[List[Int]], lines_cls: List[List[Int]], sp: CstSpan) -> String:
    if sp.r1 < 0 or sp.r2 < sp.r1 or sp.r2 >= len(lines_cps):
        return ""
    if sp.r1 == sp.r2:
        return slice_str(lines_cps[sp.r1], sp.c1, sp.c2)
    var parts = List[String]()
    for r in range(sp.r1, sp.r2 + 1):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var ce = _code_end(cps, cls)
        var c1 = sp.c1 if r == sp.r1 else 0
        var c2 = sp.c2 if r == sp.r2 else ce
        if c2 > c1:
            parts.append(String(slice_str(cps, c1, c2).strip()))
    return " ".join(parts)


def _parse_def_at(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    def_r: Int,
    ind: Int,
    decos: List[String],
    deco_start_r: Int,
) -> CstDefNode:
    var cps = lines_cps[def_r].copy()
    var cls = lines_cls[def_r].copy()
    var n = len(cps)
    var i = ind + 3
    if i < n and is_ident(cps[i]):
        i += 1
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    var name_start = i
    while i < n and _is_code(cls, i) and is_ident(cps[i]):
        i += 1
    var fn_name = slice_str(cps, name_start, i)
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1

    var ct_params = List[CstParam]()
    var cur_r = def_r
    var cur_c = i
    if cur_c < len(lines_cps[cur_r]) and _is_code(lines_cls[cur_r], cur_c) and lines_cps[cur_r][cur_c] == 91:
        var br_end = _find_matching_delim(lines_cps, lines_cls, cur_r, cur_c, 91, 93)
        if br_end[0] >= 0:
            var ct_txt = _extract_span_text(
                lines_cps, lines_cls, CstSpan(cur_r, cur_c + 1, br_end[0], br_end[1])
            )
            for item in _split_top_level_commas(ct_txt):
                ct_params.append(parse_cst_param(item))
            cur_r = br_end[0]
            cur_c = br_end[1] + 1
            while cur_c < len(lines_cps[cur_r]) and (lines_cps[cur_r][cur_c] == 32 or lines_cps[cur_r][cur_c] == 9):
                cur_c += 1

    var rt_params = List[CstParam]()
    var p_span = CstSpan(cur_r, cur_c, cur_r, cur_c)
    var hdr_end_r = cur_r
    if cur_c < len(lines_cps[cur_r]) and _is_code(lines_cls[cur_r], cur_c) and lines_cps[cur_r][cur_c] == 40:
        var pr_end = _find_matching_delim(lines_cps, lines_cls, cur_r, cur_c, 40, 41)
        if pr_end[0] >= 0:
            p_span = CstSpan(cur_r, cur_c + 1, pr_end[0], pr_end[1])
            var rt_txt = _extract_span_text(lines_cps, lines_cls, p_span)
            for item in _split_top_level_commas(rt_txt):
                rt_params.append(parse_cst_param(item))
            hdr_end_r = pr_end[0]
            cur_r = pr_end[0]
            cur_c = pr_end[1] + 1

    # Scan from `)` to header `:` for `raises`, `abi(...)`, and `-> ReturnType`
    var suffix_parts = List[String]()
    var colon_r = hdr_end_r
    var colon_c = _code_end(lines_cps[hdr_end_r], lines_cls[hdr_end_r])
    var found_colon = False
    var bdepth = 0
    var pdepth = 0
    for sr in range(cur_r, min(len(lines_cps), cur_r + 6)):
        var scps = lines_cps[sr].copy()
        var scls = lines_cls[sr].copy()
        var sc_start = cur_c if sr == cur_r else 0
        var sc_end = _code_end(scps, scls)
        for sc in range(sc_start, sc_end):
            if not _is_code(scls, sc):
                continue
            if scps[sc] == 91:
                bdepth += 1
            elif scps[sc] == 93:
                bdepth = max(0, bdepth - 1)
            elif scps[sc] == 40:
                pdepth += 1
            elif scps[sc] == 41:
                pdepth = max(0, pdepth - 1)
            elif scps[sc] == 58 and bdepth == 0 and pdepth == 0:
                colon_r = sr
                colon_c = sc + 1
                suffix_parts.append(slice_str(scps, sc_start, sc))
                found_colon = True
                break
        if found_colon:
            break
        suffix_parts.append(slice_str(scps, sc_start, sc_end))

    var suffix = String(" ".join(suffix_parts).strip())
    var has_raises = False
    var ret_type = String("")
    var abi_s = String("")

    var arrow = suffix.find("->")
    var effects_part = String(suffix[byte=0:arrow].strip()) if arrow >= 0 else suffix
    if arrow >= 0:
        ret_type = String(suffix[byte=arrow + 2 :].strip())
    if effects_part == "raises" or effects_part.startswith("raises ") or effects_part.endswith(" raises") or effects_part.find(" raises ") >= 0:
        has_raises = True
    var abi_pos = effects_part.find("abi(")
    if abi_pos >= 0:
        var abi_end = effects_part.find(")", abi_pos)
        if abi_end > abi_pos:
            abi_s = String(effects_part[byte=abi_pos : abi_end + 1])

    var body_end_r = _find_block_end_row(lines_cps, lines_cls, colon_r, ind)
    var body_end_c = len(lines_cps[body_end_r]) if body_end_r < len(lines_cps) else 0
    return CstDefNode(
        fn_name,
        decos.copy(),
        ct_params^,
        rt_params^,
        has_raises,
        abi_s,
        ret_type,
        deco_start_r,
        CstSpan(def_r, ind, colon_r, colon_c),
        p_span.copy(),
        CstSpan(min(len(lines_cps) - 1, colon_r + 1), 0, body_end_r, body_end_c),
        ind,
    )


def parse_mojo_cst(buf: TextBuffer) -> MojoCst:
    """Parse `buf` into a Mojo 1.2 Concrete Syntax Tree (`structs`, `traits`, `defs`)."""
    var cst = MojoCst()
    if buf.count() <= 0:
        return cst^
    var tok = _tokenize_buffer(buf)
    var lines_cps = tok[0].copy()
    var lines_cls = tok[1].copy()
    var nlines = len(lines_cps)

    var pending_decos = List[String]()
    var deco_start_row = -1
    var active_struct_idx = -1
    var active_trait_idx = -1

    var r = 0
    while r < nlines:
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var ind = _line_indent(cps, cls)
        if ind < 0:
            r += 1
            continue
        var ce = _code_end(cps, cls)
        var line_code = slice_str(cps, ind, ce)

        if active_struct_idx >= 0 and ind <= cst.structs[active_struct_idx].indent and not line_code.startswith("@"):
            active_struct_idx = -1
        if active_trait_idx >= 0 and ind <= cst.traits[active_trait_idx].indent and not line_code.startswith("@"):
            active_trait_idx = -1

        if line_code.startswith("@"):
            if len(pending_decos) == 0:
                deco_start_row = r
            pending_decos.append(line_code)
            r += 1
            continue

        var d_start = deco_start_row if len(pending_decos) > 0 else r

        if line_code.startswith("struct ") and ind == 0:
            active_trait_idx = -1
            var rest = String(line_code[byte=7:].strip())
            var i_end = 0
            var rcps = decode(rest)
            while i_end < len(rcps) and is_ident(rcps[i_end]):
                i_end += 1
            var sname = slice_str(rcps, 0, i_end)
            var after_name = String(slice_str(rcps, i_end, len(rcps)).strip())
            var ct_str = String("")
            if after_name.startswith("["):
                var rb = after_name.find("]")
                if rb > 0:
                    ct_str = String(after_name[byte=1:rb].strip())
                    var asub = String(after_name[byte=rb + 1 :].strip())
                    after_name = asub
            var traits = List[String]()
            if after_name.startswith("("):
                var rp = after_name.find(")")
                if rp > 0:
                    var t_inner = String(after_name[byte=1:rp])
                    for tp in _split_top_level_commas(t_inner):
                        traits.append(String(tp.strip()))
            var b_end = _find_block_end_row(lines_cps, lines_cls, r, ind)
            var b_end_c = len(lines_cps[b_end]) if b_end < nlines else 0
            cst.structs.append(
                CstStructNode(
                    sname,
                    ct_str,
                    traits^,
                    List[CstField](),
                    List[CstDefNode](),
                    d_start,
                    CstSpan(r, ind, r, ce),
                    CstSpan(min(nlines - 1, r + 1), 0, b_end, b_end_c),
                    ind,
                )
            )
            active_struct_idx = len(cst.structs) - 1
            pending_decos.clear()
            deco_start_row = -1
            r += 1
            continue

        if line_code.startswith("trait ") and ind == 0:
            active_struct_idx = -1
            var rest = String(line_code[byte=6:].strip())
            var rcps = decode(rest)
            var i_end = 0
            while i_end < len(rcps) and is_ident(rcps[i_end]):
                i_end += 1
            var tname = slice_str(rcps, 0, i_end)
            var b_end = _find_block_end_row(lines_cps, lines_cls, r, ind)
            var b_end_c = len(lines_cps[b_end]) if b_end < nlines else 0
            cst.traits.append(
                CstTraitNode(
                    tname,
                    List[CstDefNode](),
                    CstSpan(r, ind, r, ce),
                    CstSpan(min(nlines - 1, r + 1), 0, b_end, b_end_c),
                    ind,
                )
            )
            active_trait_idx = len(cst.traits) - 1
            pending_decos.clear()
            deco_start_row = -1
            r += 1
            continue

        if line_code.startswith("def ") or line_code.startswith("fn "):
            var dnode = _parse_def_at(lines_cps, lines_cls, r, ind, pending_decos, d_start)
            if active_struct_idx >= 0 and ind > cst.structs[active_struct_idx].indent:
                cst.structs[active_struct_idx].methods.append(dnode.copy())
            elif active_trait_idx >= 0 and ind > cst.traits[active_trait_idx].indent:
                cst.traits[active_trait_idx].methods.append(dnode.copy())
            cst.defs.append(dnode^)
            pending_decos.clear()
            deco_start_row = -1
            r += 1
            continue

        # Struct `var field: Type` member declaration
        if active_struct_idx >= 0 and ind == cst.structs[active_struct_idx].indent + 4 and line_code.startswith("var "):
            var fbody = String(line_code[byte=4:].strip())
            var eq = fbody.find("=")
            if eq > 0:
                var fsub = String(fbody[byte=0:eq].strip())
                fbody = fsub
            var colon = fbody.find(":")
            if colon > 0:
                var fname = String(fbody[byte=0:colon].strip())
                var ftype = String(fbody[byte=colon + 1 :].strip())
                if fname.byte_length() > 0:
                    cst.structs[active_struct_idx].fields.append(CstField(fname, ftype, r))

        pending_decos.clear()
        deco_start_row = -1
        r += 1

    return cst^


def _parse_call_from_open_paren(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    open_r: Int,
    open_c: Int,
) -> CstCallSite:
    """Given `(` at `(open_r, open_c)` preceded by a callee identifier, parse its full argument list."""
    var empty = CstCallSite(
        False,
        "",
        CstSpan(0, 0, 0, 0),
        0,
        0,
        0,
        0,
        List[CstSpan](),
        List[String](),
        List[String](),
    )
    var ocps = lines_cps[open_r].copy()
    var ocls = lines_cls[open_r].copy()

    # Walk backwards over optional `[...]` comptime args and dotted/plain callee identifier
    var c = open_c - 1
    while c >= 0 and (ocps[c] == 32 or ocps[c] == 9):
        c -= 1
    if c >= 0 and _is_code(ocls, c) and ocps[c] == 93:
        var bd = 1
        c -= 1
        while c >= 0 and bd > 0:
            if _is_code(ocls, c):
                if ocps[c] == 93:
                    bd += 1
                elif ocps[c] == 91:
                    bd -= 1
            c -= 1
        while c >= 0 and (ocps[c] == 32 or ocps[c] == 9):
            c -= 1
    if c < 0 or not _is_code(ocls, c) or not is_ident(ocps[c]):
        return empty^

    var id_end = c + 1
    var id_start = c
    while id_start > 0 and _is_code(ocls, id_start - 1) and is_ident(ocps[id_start - 1]):
        id_start -= 1
    var callee_name = slice_str(ocps, id_start, id_end)
    for kw in ["def", "fn", "struct", "trait", "if", "elif", "while", "for", "return", "match"]:
        if callee_name == String(kw):
            return empty^
    # Reject `def foo(...)` declaration lines where `def ` precedes `foo`
    var pre = id_start - 1
    while pre >= 0 and (ocps[pre] == 32 or ocps[pre] == 9):
        pre -= 1
    if pre >= 2 and slice_str(ocps, max(0, pre - 2), pre + 1) == "def":
        return empty^
    if pre >= 1 and slice_str(ocps, max(0, pre - 1), pre + 1) == "fn":
        return empty^

    # Include dotted receiver (`obj.method`) in full call span
    var call_c1 = id_start
    while call_c1 >= 2 and ocps[call_c1 - 1] == 46 and is_ident(ocps[call_c1 - 2]):
        call_c1 -= 2
        while call_c1 > 0 and is_ident(ocps[call_c1 - 1]):
            call_c1 -= 1

    var close_pos = _find_matching_delim(lines_cps, lines_cls, open_r, open_c, 40, 41)
    if close_pos[0] < 0:
        return empty^
    var close_r = close_pos[0]
    var close_c = close_pos[1]

    # Partition arguments by top-level `,` inside `(open_r, open_c + 1) .. (close_r, close_c)`
    var arg_spans = List[CstSpan]()
    var arg_texts = List[String]()
    var arg_kws = List[String]()

    var pdepth = 0
    var bdepth = 0
    var cdepth = 0
    var seg_r1 = open_r
    var seg_c1 = open_c + 1

    for r in range(open_r, close_r + 1):
        var rcps = lines_cps[r].copy()
        var rcls = lines_cls[r].copy()
        var c_from = (open_c + 1) if r == open_r else 0
        var c_to = close_c if r == close_r else _code_end(rcps, rcls)
        for col in range(c_from, c_to):
            if not _is_code(rcls, col):
                continue
            var ch = rcps[col]
            if ch == 40:
                pdepth += 1
            elif ch == 41:
                pdepth = max(0, pdepth - 1)
            elif ch == 91:
                bdepth += 1
            elif ch == 93:
                bdepth = max(0, bdepth - 1)
            elif ch == 123:
                cdepth += 1
            elif ch == 125:
                cdepth = max(0, cdepth - 1)
            elif ch == 44 and pdepth == 0 and bdepth == 0 and cdepth == 0:
                _append_trimmed_arg(lines_cps, lines_cls, seg_r1, seg_c1, r, col, arg_spans, arg_texts, arg_kws)
                seg_r1 = r
                seg_c1 = col + 1
    _append_trimmed_arg(lines_cps, lines_cls, seg_r1, seg_c1, close_r, close_c, arg_spans, arg_texts, arg_kws)

    return CstCallSite(
        True,
        callee_name,
        CstSpan(open_r, call_c1, close_r, close_c + 1),
        open_r,
        open_c,
        close_r,
        close_c,
        arg_spans^,
        arg_texts^,
        arg_kws^,
    )


def _append_trimmed_arg(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    r1_in: Int,
    c1_in: Int,
    r2_in: Int,
    c2_in: Int,
    mut arg_spans: List[CstSpan],
    mut arg_texts: List[String],
    mut arg_kws: List[String],
):
    var r1 = r1_in
    var c1 = c1_in
    var r2 = r2_in
    var c2 = c2_in
    while r1 < r2 or (r1 == r2 and c1 < c2):
        var ln = lines_cps[r1].copy()
        var cl = lines_cls[r1].copy()
        var ce = _code_end(ln, cl)
        if c1 >= ce:
            if r1 == r2:
                break
            r1 += 1
            c1 = 0
            continue
        if ln[c1] == 32 or ln[c1] == 9:
            c1 += 1
            continue
        break
    while r2 > r1 or (r2 == r1 and c2 > c1):
        var ln = lines_cps[r2].copy()
        if c2 == 0:
            r2 -= 1
            c2 = _code_end(lines_cps[r2], lines_cls[r2])
            continue
        if c2 > len(ln):
            c2 = len(ln)
            continue
        if ln[c2 - 1] == 32 or ln[c2 - 1] == 9:
            c2 -= 1
            continue
        break
    if r1 > r2 or (r1 == r2 and c1 >= c2):
        return
    var sp = CstSpan(r1, c1, r2, c2)
    var txt = _extract_span_text(lines_cps, lines_cls, sp)
    if txt.byte_length() == 0:
        return
    var kw = String("")
    var tcps = decode(txt)
    var k = 0
    while k < len(tcps) and is_ident(tcps[k]):
        k += 1
    if k > 0:
        var m = k
        while m < len(tcps) and tcps[m] == 32:
            m += 1
        if m < len(tcps) and tcps[m] == 61 and (m + 1 >= len(tcps) or tcps[m + 1] != 61):
            kw = slice_str(tcps, 0, k)
    arg_spans.append(sp^)
    arg_texts.append(txt)
    arg_kws.append(kw)


def _pos_in_span(r: Int, c: Int, sp: CstSpan) -> Bool:
    if r < sp.r1 or r > sp.r2:
        return False
    if r == sp.r1 and c < sp.c1:
        return False
    if r == sp.r2 and c > sp.c2:
        return False
    return True


def find_enclosing_call(buf: TextBuffer, row: Int, col: Int) -> CstCallSite:
    """Find the innermost function/method call expression enclosing `(row, col)`."""
    var tok = _tokenize_buffer(buf)
    var lines_cps = tok[0].copy()
    var lines_cls = tok[1].copy()
    var best = CstCallSite(
        False,
        "",
        CstSpan(0, 0, 0, 0),
        0,
        0,
        0,
        0,
        List[CstSpan](),
        List[String](),
        List[String](),
    )
    var start_r = max(0, row - 25)
    var end_r = min(len(lines_cps) - 1, row)
    for r in range(start_r, end_r + 1):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        for c in range(len(cps)):
            if _is_code(cls, c) and cps[c] == 40:
                var call = _parse_call_from_open_paren(lines_cps, lines_cls, r, c)
                if call.ok and _pos_in_span(row, col, call.span):
                    best = call^
    return best^


def find_all_calls_to(buf: TextBuffer, fn_name: String) -> List[CstCallSite]:
    """Find all call sites of `fn_name` (excluding `def fn_name(...)` declarations) in `buf`."""
    var calls = List[CstCallSite]()
    if buf.count() <= 0 or fn_name.byte_length() == 0:
        return calls^
    var tok = _tokenize_buffer(buf)
    var lines_cps = tok[0].copy()
    var lines_cls = tok[1].copy()
    for r in range(len(lines_cps)):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        for c in range(len(cps)):
            if _is_code(cls, c) and cps[c] == 40:
                var call = _parse_call_from_open_paren(lines_cps, lines_cls, r, c)
                if call.ok and call.callee == fn_name:
                    calls.append(call^)
    return calls^


def cst_selection_ranges(buf: TextBuffer, row: Int, col: Int) -> List[CstSpan]:
    """Return concentric Mojo 1.2 CST spans enclosing `(row, col)` from innermost to outermost:
    call argument -> argument list -> call expression -> parameter list -> `def` signature ->
    `def` body -> full `def` (with `@decorator`s) -> `struct`/`trait` body -> full `struct`/`trait`."""
    var spans = List[CstSpan]()
    if buf.count() <= 0 or row < 0 or row >= buf.count():
        return spans^

    var call = find_enclosing_call(buf, row, col)
    if call.ok:
        for asp in call.arg_spans:
            if _pos_in_span(row, col, asp):
                spans.append(asp.copy())
        if call.open_r < call.close_r or call.open_c + 1 < call.close_c:
            spans.append(CstSpan(call.open_r, call.open_c + 1, call.close_r, call.close_c))
        spans.append(call.span.copy())

    var cst = parse_mojo_cst(buf)
    for d in cst.defs:
        var full_def = CstSpan(d.deco_start_row, 0, d.body_span.r2, d.body_span.c2)
        if _pos_in_span(row, col, full_def):
            if _pos_in_span(row, col, d.params_span) and (d.params_span.r1 < d.params_span.r2 or d.params_span.c1 < d.params_span.c2):
                spans.append(d.params_span.copy())
            if _pos_in_span(row, col, d.header_span):
                spans.append(d.header_span.copy())
            if _pos_in_span(row, col, d.body_span):
                spans.append(d.body_span.copy())
            spans.append(full_def^)

    for s in cst.structs:
        var full_s = CstSpan(s.deco_start_row, 0, s.body_span.r2, s.body_span.c2)
        if _pos_in_span(row, col, full_s):
            if _pos_in_span(row, col, s.body_span):
                spans.append(s.body_span.copy())
            spans.append(full_s^)

    for tr in cst.traits:
        var full_t = CstSpan(tr.header_span.r1, 0, tr.body_span.r2, tr.body_span.c2)
        if _pos_in_span(row, col, full_t):
            if _pos_in_span(row, col, tr.body_span):
                spans.append(tr.body_span.copy())
            spans.append(full_t^)

    return spans^
