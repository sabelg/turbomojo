"""CST-powered structural Vim text objects, 2-char Flash jump labels, surround edits, Harpoon marks, and change list.

Provides Phase 22 modal editing primitives built purely in Mojo 1.2:
- `resolve_cst_text_object`: structural `af`/`if` (`def`/`async def`), `ac`/`ic` (`struct`/`trait`/`class`),
  `aa`/`ia` (call arguments & `def` parameters with clean comma/whitespace handling), and `aj`/`ij` (`# %%` cells)
- `find_flash_targets_in_lines` & `assign_flash_labels`: 2-character smartcase screen search with conflict-free
  home-row jump beacons
- `surround_pair`, `find_enclosing_surround`, `apply_surround_add`, `apply_surround_delete`, `apply_surround_change`:
  `vim-surround` / `nvim-surround` compatible delimiter editing (`ys`, `ds`, `cs`)
- `HarpoonList` & `VimChangeList`: persistent 1..9 quick-marks and 64-entry `g;` / `g,` edit position history
"""
from std.collections import List
from buffer import TextBuffer, Pos
from cells import parse_cells, cell_at_row
from highlight import Highlighter, HL_MOJO, C_CMT, C_STR
from mojocst import parse_mojo_cst
from util import decode, to_str, slice_str

comptime HARPOON_MAX_SLOTS = 9
comptime HARPOON_PRIMARY_SLOTS = 4
comptime CHANGE_LIST_MAX = 64

comptime FLASH_LABEL_ORDER = "sdfjklagheruiowcvnmtypbxqzSDFJKLAGHERUIOWCVNMTYPBXQZ"


@fieldwise_init
struct CstTextObjectSpan(Copyable, Movable):
    var ok: Bool
    var linewise: Bool
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int


@fieldwise_init
struct _BlockDecl(Copyable, Movable):
    var deco_start_row: Int
    var header_start_row: Int
    var colon_row: Int
    var body_end_row: Int
    var indent: Int


def no_cst_object_span() -> CstTextObjectSpan:
    return CstTextObjectSpan(False, False, 0, 0, 0, 0)


def _is_code_cls(cls: List[Int], col: Int) -> Bool:
    if col < 0 or col >= len(cls):
        return False
    return cls[col] != C_CMT and cls[col] != C_STR


def _line_code_indent(cps: List[Int], cls: List[Int]) -> Int:
    var n = len(cps)
    var i = 0
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    if i >= n or not _is_code_cls(cls, i):
        return -1
    return i


def _line_code_end(cps: List[Int], cls: List[Int]) -> Int:
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


def _tokenize_buf(buf: TextBuffer) -> Tuple[List[List[Int]], List[List[Int]]]:
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


def _is_blank_row(buf: TextBuffer, r: Int) -> Bool:
    if r < 0 or r >= buf.count():
        return True
    var cps = buf.line(r)
    for c in cps:
        if c != 32 and c != 9:
            return False
    return True


def _effective_last_row(buf: TextBuffer) -> Int:
    var n = buf.count()
    if n <= 0:
        return -1
    if n > 1 and buf.eol_at_eof and buf.llen(n - 1) == 0:
        return n - 2
    return n - 1


def _find_header_colon_row(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    start_r: Int,
    start_c: Int,
) -> Int:
    var nlines = len(lines_cps)
    var pdepth = 0
    var bdepth = 0
    var cdepth = 0
    var limit_r = min(nlines, start_r + 32)
    for r in range(start_r, limit_r):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var c0 = start_c if r == start_r else 0
        var ce = _line_code_end(cps, cls)
        for c in range(c0, ce):
            if not _is_code_cls(cls, c):
                continue
            var ch = cps[c]
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
            elif ch == 58 and pdepth == 0 and bdepth == 0 and cdepth == 0:
                return r
    return start_r


def _find_indented_block_end(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    colon_row: Int,
    decl_indent: Int,
) -> Int:
    var nlines = len(lines_cps)
    var last_body = colon_row
    var r = colon_row + 1
    while r < nlines:
        var ind = _line_code_indent(lines_cps[r], lines_cls[r])
        if ind >= 0:
            if ind <= decl_indent:
                break
            last_body = r
        r += 1
    return last_body


def _starts_decl_kw(code: String, kw: String) -> Bool:
    if not code.startswith(kw):
        return False
    var kw_len = kw.byte_length()
    if code.byte_length() <= kw_len:
        return False
    var next_b = Int(code.as_bytes()[kw_len])
    return next_b == 32 or next_b == 9 or next_b == 40 or next_b == 91 or next_b == 58


def _scan_block_decls(buf: TextBuffer, want_func: Bool) -> List[_BlockDecl]:
    var out = List[_BlockDecl]()
    if buf.count() <= 0:
        return out^

    # Seed from Mojo CST first
    var cst = parse_mojo_cst(buf)
    if want_func:
        for d in cst.defs:
            out.append(
                _BlockDecl(
                    d.deco_start_row,
                    d.header_span.r1,
                    d.header_span.r2,
                    d.body_span.r2,
                    d.indent,
                )
            )
    else:
        for s in cst.structs:
            out.append(
                _BlockDecl(
                    s.deco_start_row,
                    s.header_span.r1,
                    s.header_span.r2,
                    s.body_span.r2,
                    s.indent,
                )
            )
        for tr in cst.traits:
            out.append(
                _BlockDecl(
                    tr.header_span.r1,
                    tr.header_span.r1,
                    tr.header_span.r2,
                    tr.body_span.r2,
                    tr.indent,
                )
            )

    # Fallback/augmentation pass for Python `async def`, `class`, decorated `trait`, and nested types
    var tok = _tokenize_buf(buf)
    var lines_cps = tok[0].copy()
    var lines_cls = tok[1].copy()
    var nlines = len(lines_cps)
    var deco_start = -1
    var deco_indent = -1

    for r in range(nlines):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var ind = _line_code_indent(cps, cls)
        if ind < 0:
            continue
        var ce = _line_code_end(cps, cls)
        var code = slice_str(cps, ind, ce)

        if code.startswith("@"):
            if deco_start < 0 or deco_indent != ind:
                deco_start = r
                deco_indent = ind
            continue

        var matched = False
        if want_func:
            if _starts_decl_kw(code, "def") or _starts_decl_kw(code, "async def"):
                matched = True
        else:
            if (
                _starts_decl_kw(code, "struct")
                or _starts_decl_kw(code, "trait")
                or _starts_decl_kw(code, "class")
            ):
                matched = True

        if matched:
            var d_row = deco_start if (deco_start >= 0 and deco_indent == ind) else r
            var colon_r = _find_header_colon_row(lines_cps, lines_cls, r, ind)
            var end_r = _find_indented_block_end(lines_cps, lines_cls, colon_r, ind)
            # Replace existing entry at same header_start_row if fallback found wider decorator/header span
            var found_idx = -1
            for k in range(len(out)):
                if out[k].header_start_row == r:
                    found_idx = k
                    break
            var decl = _BlockDecl(d_row, r, colon_r, end_r, ind)
            if found_idx >= 0:
                if d_row < out[found_idx].deco_start_row or colon_r > out[found_idx].colon_row:
                    out[found_idx] = decl^
            else:
                out.append(decl^)

        deco_start = -1
        deco_indent = -1

    return out^


def _pick_innermost_decl(decls: List[_BlockDecl], cr: Int) -> Tuple[Bool, _BlockDecl]:
    var best = _BlockDecl(0, 0, 0, 0, -1)
    var found = False
    for d in decls:
        if cr >= d.deco_start_row and cr <= d.body_end_row:
            if not found:
                best = d.copy()
                found = True
            else:
                var cur_span = d.body_end_row - d.deco_start_row
                var best_span = best.body_end_row - best.deco_start_row
                if d.indent > best.indent or (d.indent == best.indent and cur_span < best_span):
                    best = d.copy()
    return (found, best^)


def _pos_lt(r1: Int, c1: Int, r2: Int, c2: Int) -> Bool:
    return r1 < r2 or (r1 == r2 and c1 < c2)


def _pos_le(r1: Int, c1: Int, r2: Int, c2: Int) -> Bool:
    return r1 < r2 or (r1 == r2 and c1 <= c2)


def _trim_arg_forward(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    r0: Int,
    c0: Int,
    lim_r: Int,
    lim_c: Int,
) -> Pos:
    var r = r0
    var c = c0
    while _pos_lt(r, c, lim_r, lim_c):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var ce = _line_code_end(cps, cls)
        var row_lim = min(ce, lim_c) if r == lim_r else ce
        if c >= row_lim:
            if r == lim_r:
                return Pos(lim_r, lim_c)
            r += 1
            c = 0
            continue
        if cps[c] == 32 or cps[c] == 9:
            c += 1
            continue
        break
    return Pos(r, c)


def _trim_arg_backward(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    r0: Int,
    c0: Int,
    lim_r: Int,
    lim_c: Int,
) -> Pos:
    var r = r0
    var c = c0
    while _pos_lt(lim_r, lim_c, r, c):
        if c <= 0:
            r -= 1
            c = _line_code_end(lines_cps[r], lines_cls[r])
            continue
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var ce = _line_code_end(cps, cls)
        if c > ce:
            c = max(lim_c if r == lim_r else 0, ce)
            continue
        if cps[c - 1] == 32 or cps[c - 1] == 9:
            c -= 1
            continue
        break
    return Pos(r, c)


def _find_matching_code_paren(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    open_r: Int,
    open_c: Int,
) -> Pos:
    var depth = 0
    var nlines = len(lines_cps)
    for r in range(open_r, nlines):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var c0 = open_c if r == open_r else 0
        for c in range(c0, len(cps)):
            if not _is_code_cls(cls, c):
                continue
            if cps[c] == 40:
                depth += 1
            elif cps[c] == 41:
                depth -= 1
                if depth == 0:
                    return Pos(r, c)
    return Pos(-1, -1)


def _resolve_arg_text_object(
    buf: TextBuffer, cr: Int, cc: Int, around: Bool
) -> CstTextObjectSpan:
    var tok = _tokenize_buf(buf)
    var lines_cps = tok[0].copy()
    var lines_cls = tok[1].copy()
    var nlines = len(lines_cps)
    if cr < 0 or cr >= nlines:
        return no_cst_object_span()

    # Find innermost enclosing code `(` .. `)` (covers both call sites and `def` parameter lists)
    var best_open = Pos(-1, -1)
    var best_close = Pos(-1, -1)
    for r in range(0, cr + 1):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var c_lim = min(len(cps), cc + 1) if r == cr else len(cps)
        for c in range(c_lim):
            if _is_code_cls(cls, c) and cps[c] == 40:
                var cl = _find_matching_code_paren(lines_cps, lines_cls, r, c)
                if cl.r >= 0 and _pos_le(cr, cc, cl.r, cl.c):
                    best_open = Pos(r, c)
                    best_close = cl^

    if best_open.r < 0:
        return no_cst_object_span()

    # Partition top-level `,` inside `(best_open .. best_close)`
    var commas = List[Pos]()
    var pdepth = 0
    var bdepth = 0
    var cdepth = 0
    for r in range(best_open.r, best_close.r + 1):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var c0 = (best_open.c + 1) if r == best_open.r else 0
        var c1 = best_close.c if r == best_close.r else _line_code_end(cps, cls)
        for c in range(c0, c1):
            if not _is_code_cls(cls, c):
                continue
            var ch = cps[c]
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
                commas.append(Pos(r, c))

    var raw_starts = List[Pos]()
    var raw_ends = List[Pos]()
    var n_slots = len(commas) + 1
    for j in range(n_slots):
        var rs = Pos(best_open.r, best_open.c + 1) if j == 0 else Pos(commas[j - 1].r, commas[j - 1].c + 1)
        var re = best_close.copy() if j == n_slots - 1 else commas[j].copy()
        raw_starts.append(rs^)
        raw_ends.append(re^)

    var trim_starts = List[Pos]()
    var trim_ends = List[Pos]()
    var has_trailing_comma = False
    for j in range(n_slots):
        var ts = _trim_arg_forward(
            lines_cps, lines_cls, raw_starts[j].r, raw_starts[j].c, raw_ends[j].r, raw_ends[j].c
        )
        var te = _trim_arg_backward(
            lines_cps, lines_cls, raw_ends[j].r, raw_ends[j].c, ts.r, ts.c
        )
        if _pos_lt(ts.r, ts.c, te.r, te.c):
            trim_starts.append(ts^)
            trim_ends.append(te^)
        elif j == n_slots - 1 and len(commas) > 0:
            has_trailing_comma = True

    var n_args = len(trim_starts)
    if n_args == 0:
        return no_cst_object_span()

    # Determine which argument index `arg_idx` encloses `(cr, cc)`
    var arg_idx: Int
    if cr == best_open.r and cc == best_open.c:
        arg_idx = 0
    elif cr == best_close.r and cc == best_close.c:
        arg_idx = n_args - 1
    else:
        var slot_idx = n_slots - 1
        for j in range(n_slots):
            if _pos_le(cr, cc, raw_ends[j].r, raw_ends[j].c):
                slot_idx = j
                break
        arg_idx = min(slot_idx, n_args - 1)

    var s_pos = trim_starts[arg_idx].copy()
    var e_pos = trim_ends[arg_idx].copy()
    if not around:
        return CstTextObjectSpan(True, False, s_pos.r, s_pos.c, e_pos.r, e_pos.c)

    # `aa`: include separator comma + whitespace cleanly so `daa` leaves valid syntax
    if n_args == 1:
        if has_trailing_comma and len(commas) > 0:
            var c_after = Pos(commas[0].r, commas[0].c + 1)
            var ln0 = lines_cps[c_after.r].copy()
            var lim0 = best_close.c if c_after.r == best_close.r else len(ln0)
            while c_after.c < lim0 and (ln0[c_after.c] == 32 or ln0[c_after.c] == 9):
                c_after.c += 1
            return CstTextObjectSpan(True, False, s_pos.r, s_pos.c, c_after.r, c_after.c)
        return CstTextObjectSpan(True, False, s_pos.r, s_pos.c, e_pos.r, e_pos.c)

    if arg_idx < n_args - 1:
        var next_s = trim_starts[arg_idx + 1].copy()
        return CstTextObjectSpan(True, False, s_pos.r, s_pos.c, next_s.r, next_s.c)

    # Last argument (`arg_idx == n_args - 1` and `n_args > 1`)
    var prev_e = trim_ends[arg_idx - 1].copy()
    if has_trailing_comma and len(commas) >= n_args:
        var trail_c = commas[n_args - 1].copy()
        if prev_e.r == trail_c.r:
            var end_c = trail_c.c + 1
            var ln_t = lines_cps[trail_c.r].copy()
            var lim_t = best_close.c if trail_c.r == best_close.r else len(ln_t)
            while end_c < lim_t and (ln_t[end_c] == 32 or ln_t[end_c] == 9):
                end_c += 1
            return CstTextObjectSpan(True, False, prev_e.r, prev_e.c, trail_c.r, end_c)
    return CstTextObjectSpan(True, False, prev_e.r, prev_e.c, e_pos.r, e_pos.c)


def resolve_cst_text_object(
    buf: TextBuffer, cr: Int, cc: Int, around: Bool, obj_ch: Int
) -> CstTextObjectSpan:
    """Resolve CST structural Vim text objects.

    Supports:
    - `'f'` (`102`): Mojo/Python `def` / `async def` (`af` includes `@decorator`s + trailing blank line; `if` body)
    - `'c'` (`99`): `struct`, `trait`, or Python `class` (`ac` includes `@decorator`s; `ic` body)
    - `'a'` (`97`): call argument or `def` parameter (`aa` includes separator `,` & spaces; `ia` inner item)
    - `'j'` (`106`): `# %%` notebook cell (`aj` header..end; `ij` code lines after `# %%` trimmed of trailing blanks)
    """
    if buf.count() <= 0 or cr < 0 or cr >= buf.count():
        return no_cst_object_span()

    if obj_ch == 102:  # 'f'
        var decls = _scan_block_decls(buf, True)
        var picked = _pick_innermost_decl(decls, cr)
        if not picked[0]:
            return no_cst_object_span()
        var d = picked[1].copy()
        if around:
            var end_r = d.body_end_row
            var eff_last = _effective_last_row(buf)
            if end_r + 1 <= eff_last and _is_blank_row(buf, end_r + 1):
                end_r += 1
            return CstTextObjectSpan(True, True, d.deco_start_row, 0, end_r, buf.llen(end_r))
        if d.body_end_row <= d.colon_row:
            return no_cst_object_span()
        var b_r1 = d.colon_row + 1
        return CstTextObjectSpan(True, True, b_r1, 0, d.body_end_row, buf.llen(d.body_end_row))

    if obj_ch == 99:  # 'c'
        var decls = _scan_block_decls(buf, False)
        var picked = _pick_innermost_decl(decls, cr)
        if not picked[0]:
            return no_cst_object_span()
        var cnode = picked[1].copy()
        if around:
            return CstTextObjectSpan(
                True, True, cnode.deco_start_row, 0, cnode.body_end_row, buf.llen(cnode.body_end_row)
            )
        if cnode.body_end_row <= cnode.colon_row:
            return no_cst_object_span()
        var b_r1 = cnode.colon_row + 1
        return CstTextObjectSpan(True, True, b_r1, 0, cnode.body_end_row, buf.llen(cnode.body_end_row))

    if obj_ch == 97:  # 'a'
        return _resolve_arg_text_object(buf, cr, cc, around)

    if obj_ch == 106:  # 'j'
        var cells = parse_cells(buf)
        if len(cells) == 0:
            return no_cst_object_span()
        var ci = cell_at_row(cells, cr)
        if ci < 0 or ci >= len(cells):
            return no_cst_object_span()
        var cell = cells[ci].copy()
        if around:
            var r1 = cell.header_row if cell.header_row >= 0 else cell.start_row
            var r2 = cell.end_row
            return CstTextObjectSpan(True, True, r1, 0, r2, buf.llen(r2))
        if cell.header_row >= 0 and cell.start_row <= cell.header_row:
            return no_cst_object_span()
        var sr = cell.start_row
        var er = cell.end_row
        var last_nb = -1
        var r = er
        while r >= sr:
            if not _is_blank_row(buf, r):
                last_nb = r
                break
            r -= 1
        var final_r2 = last_nb if last_nb >= sr else er
        return CstTextObjectSpan(True, True, sr, 0, final_r2, buf.llen(final_r2))

    return no_cst_object_span()


# ---------------------------------------------------------------------------
# 2. 2-Character Flash / Leap Screen Target Engine
# ---------------------------------------------------------------------------


@fieldwise_init
struct FlashTarget(Copyable, Movable):
    var win_idx: Int
    var row: Int
    var col: Int
    var screen_x: Int
    var screen_y: Int
    var label: Int


def _is_ascii_upper(cp: Int) -> Bool:
    return cp >= 65 and cp <= 90


def _ascii_lower(cp: Int) -> Int:
    if cp >= 65 and cp <= 90:
        return cp + 32
    return cp


def _ascii_upper(cp: Int) -> Int:
    if cp >= 97 and cp <= 122:
        return cp - 32
    return cp


def _int_list_contains(items: List[Int], val: Int) -> Bool:
    for x in items:
        if x == val:
            return True
    return False


def assign_flash_labels(
    mut targets: List[FlashTarget], next_chars: List[Int] = List[Int]()
):
    """Assign unique deterministic single-letter jump labels (`a..z`, `A..Z`) to `targets`,
    prioritizing ergonomic home-row keys and avoiding any continuation characters in `next_chars`."""
    var n = len(targets)
    if n == 0:
        return

    var blocked = List[Int]()
    for nc in next_chars:
        if nc > 0:
            if not _int_list_contains(blocked, nc):
                blocked.append(nc)
            var lo = _ascii_lower(nc)
            if lo != nc and not _int_list_contains(blocked, lo):
                blocked.append(lo)
            var up = _ascii_upper(nc)
            if up != nc and not _int_list_contains(blocked, up):
                blocked.append(up)

    var pool_cps = decode(String(FLASH_LABEL_ORDER))
    var avail = List[Int]()
    for ch in pool_cps:
        if not _int_list_contains(blocked, ch):
            avail.append(ch)
    # Fallback pass only when > non-colliding labels are needed (unavoidable collision)
    for ch in pool_cps:
        if _int_list_contains(blocked, ch):
            avail.append(ch)

    for i in range(n):
        targets[i].label = avail[i] if i < len(avail) else 0


def find_flash_targets_in_lines(
    win_idx: Int,
    lines: List[String],
    base_row: Int,
    ch1: Int,
    ch2: Int,
    case_sensitive: Bool = False,
) -> List[FlashTarget]:
    """Scan `lines` for 2-codepoint sequence `(ch1, ch2)` with `flash.nvim` smartcase
    (case-insensitive unless `case_sensitive` or either query char is uppercase ASCII `'A'..'Z'`),
    returning labeled `FlashTarget` beacons whose labels avoid continuation characters."""
    var targets = List[FlashTarget]()
    if ch1 <= 0 or ch2 <= 0:
        return targets^

    var smart_cs = case_sensitive or _is_ascii_upper(ch1) or _is_ascii_upper(ch2)
    var q1 = ch1 if smart_cs else _ascii_lower(ch1)
    var q2 = ch2 if smart_cs else _ascii_lower(ch2)
    var next_chars = List[Int]()

    for line_idx in range(len(lines)):
        var cps = decode(lines[line_idx])
        var m = len(cps)
        if m < 2:
            continue
        for col in range(m - 1):
            var c1 = cps[col] if smart_cs else _ascii_lower(cps[col])
            var c2 = cps[col + 1] if smart_cs else _ascii_lower(cps[col + 1])
            if c1 == q1 and c2 == q2:
                targets.append(
                    FlashTarget(win_idx, base_row + line_idx, col, col, line_idx, 0)
                )
                var third = cps[col + 2] if col + 2 < m else 0
                next_chars.append(third)

    assign_flash_labels(targets, next_chars)
    return targets^


# ---------------------------------------------------------------------------
# 3. Pure-Mojo Vim Surround Operations (`ys`, `ds`, `cs`)
# ---------------------------------------------------------------------------


def surround_pair(ch: Int) -> Tuple[String, String]:
    """Return `(open_str, close_str)` for surround key `ch`:
    - `'('`, `'['`, `'{'`, `'<'` add inner space padding `("( ", " )")`, etc.
    - `')'`, `']'`, `'}'`, `'>'`, `'b'`, `'B'`, `'r'`, `'a'` use tight no-space brackets
    - Quotes `'"'`, `'\\''`, `` '`' `` (and other single-char delimiters) are symmetric."""
    if ch <= 0:
        return ("", "")
    if ch == 40:  # '('
        return ("( ", " )")
    if ch == 41 or ch == 98:  # ')' or 'b'
        return ("(", ")")
    if ch == 91:  # '['
        return ("[ ", " ]")
    if ch == 93 or ch == 114:  # ']' or 'r'
        return ("[", "]")
    if ch == 123:  # '{'
        return ("{ ", " }")
    if ch == 125 or ch == 66:  # '}' or 'B'
        return ("{", "}")
    if ch == 60:  # '<'
        return ("< ", " >")
    if ch == 62 or ch == 97:  # '>' or 'a'
        return ("<", ">")
    var sym = chr(ch)
    return (sym, sym)


def _surround_bracket_cps(ch: Int) -> Tuple[Bool, Int, Int]:
    if ch == 40 or ch == 41 or ch == 98:  # ( ) b
        return (True, 40, 41)
    if ch == 91 or ch == 93 or ch == 114:  # [ ] r
        return (True, 91, 93)
    if ch == 123 or ch == 125 or ch == 66:  # { } B
        return (True, 123, 125)
    if ch == 60 or ch == 62 or ch == 97:  # < > a
        return (True, 60, 62)
    return (False, ch, ch)


def _is_spaced_opener(ch: Int) -> Bool:
    return ch == 40 or ch == 91 or ch == 123 or ch == 60


def _match_delim_fwd_mode(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    open_r: Int,
    open_c: Int,
    open_cp: Int,
    close_cp: Int,
    code_only: Bool,
) -> Pos:
    var depth = 0
    for r in range(open_r, len(lines_cps)):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var c0 = open_c if r == open_r else 0
        for c in range(c0, len(cps)):
            if code_only and not _is_code_cls(cls, c):
                continue
            if cps[c] == open_cp:
                depth += 1
            elif cps[c] == close_cp:
                depth -= 1
                if depth == 0:
                    return Pos(r, c)
    return Pos(-1, -1)


def _match_delim_back_mode(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    close_r: Int,
    close_c: Int,
    open_cp: Int,
    close_cp: Int,
    code_only: Bool,
) -> Pos:
    var depth = 0
    var r = close_r
    while r >= 0:
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var c_start = min(close_c, len(cps) - 1) if r == close_r else (len(cps) - 1)
        var c = c_start
        while c >= 0:
            if not (code_only and not _is_code_cls(cls, c)):
                if cps[c] == close_cp:
                    depth += 1
                elif cps[c] == open_cp:
                    depth -= 1
                    if depth == 0:
                        return Pos(r, c)
            c -= 1
        r -= 1
    return Pos(-1, -1)


def find_enclosing_surround(
    buf: TextBuffer, cr: Int, cc: Int, target_ch: Int
) -> Tuple[Bool, Int, Int, Int, Int]:
    """Find nearest enclosing pair `(open_r, open_c, close_r, close_c)` matching `target_ch`
    across single or multiple lines."""
    var nlines = buf.count()
    if nlines <= 0 or cr < 0 or cr >= nlines or target_ch <= 0:
        return (False, 0, 0, 0, 0)

    var br = _surround_bracket_cps(target_ch)
    if br[0]:
        var open_cp = br[1]
        var close_cp = br[2]
        var tok = _tokenize_buf(buf)
        var lines_cps = tok[0].copy()
        var lines_cls = tok[1].copy()
        var cur_cps = lines_cps[cr].copy()
        var cur_cls = lines_cls[cr].copy()
        var cur_col = max(0, min(cc, max(0, len(cur_cps) - 1)))
        var code_only = len(cur_cps) == 0 or _is_code_cls(cur_cls, cur_col)

        # Case 1: Cursor directly on `open_cp` or `close_cp`
        if cur_col < len(cur_cps) and (not code_only or _is_code_cls(cur_cls, cur_col)):
            if cur_cps[cur_col] == open_cp:
                var cl = _match_delim_fwd_mode(
                    lines_cps, lines_cls, cr, cur_col, open_cp, close_cp, code_only
                )
                if cl.r >= 0:
                    return (True, cr, cur_col, cl.r, cl.c)
            elif cur_cps[cur_col] == close_cp:
                var op = _match_delim_back_mode(
                    lines_cps, lines_cls, cr, cur_col, open_cp, close_cp, code_only
                )
                if op.r >= 0:
                    return (True, op.r, op.c, cr, cur_col)

        # Case 2: Scan backward from `(cr, cc)` for nearest unmatched `open_cp` enclosing `(cr, cc)`
        var depth = 0
        var r = cr
        while r >= 0:
            var cps = lines_cps[r].copy()
            var cls = lines_cls[r].copy()
            var c = (min(cc, len(cps)) - 1) if r == cr else (len(cps) - 1)
            while c >= 0:
                if not (code_only and not _is_code_cls(cls, c)):
                    if cps[c] == close_cp:
                        depth += 1
                    elif cps[c] == open_cp:
                        if depth == 0:
                            var cl2 = _match_delim_fwd_mode(
                                lines_cps, lines_cls, r, c, open_cp, close_cp, code_only
                            )
                            if cl2.r >= 0 and _pos_le(cr, cc, cl2.r, cl2.c):
                                return (True, r, c, cl2.r, cl2.c)
                        else:
                            depth -= 1
                c -= 1
            r -= 1

        # Case 3: Forward seek on current line `cr` (e.g. `ds(` from before `(` on the line)
        for fc in range(max(0, cc), len(cur_cps)):
            if code_only and not _is_code_cls(cur_cls, fc):
                continue
            if cur_cps[fc] == open_cp:
                var cl3 = _match_delim_fwd_mode(
                    lines_cps, lines_cls, cr, fc, open_cp, close_cp, code_only
                )
                if cl3.r >= 0:
                    return (True, cr, fc, cl3.r, cl3.c)
        return (False, 0, 0, 0, 0)

    # Symmetric quote/delimiter search (`"`, `'`, `` ` ``, etc.)
    var q_cp = target_ch
    var ln_cps = buf.line(cr)
    var qcols = List[Int]()
    var idx = 0
    while idx < len(ln_cps):
        if ln_cps[idx] == 92 and (q_cp == 34 or q_cp == 39 or q_cp == 96):
            idx += 2
            continue
        if ln_cps[idx] == q_cp:
            qcols.append(idx)
        idx += 1

    var p = 0
    while p + 1 < len(qcols):
        if qcols[p] <= cc and cc <= qcols[p + 1]:
            return (True, cr, qcols[p], cr, qcols[p + 1])
        p += 2

    # Multi-line quote pair fallback across buffer
    var in_open = False
    var open_r = 0
    var open_c = 0
    for mr in range(nlines):
        var mcps = buf.line(mr)
        var mi = 0
        while mi < len(mcps):
            if mcps[mi] == 92 and (q_cp == 34 or q_cp == 39 or q_cp == 96):
                mi += 2
                continue
            if mcps[mi] == q_cp:
                if not in_open:
                    in_open = True
                    open_r = mr
                    open_c = mi
                else:
                    if _pos_le(open_r, open_c, cr, cc) and _pos_le(cr, cc, mr, mi):
                        return (True, open_r, open_c, mr, mi)
                    in_open = False
            mi += 1

    # Forward-seek quote pair on current line if cursor precedes it
    if len(qcols) >= 2 and cc < qcols[0]:
        return (True, cr, qcols[0], cr, qcols[1])

    return (False, 0, 0, 0, 0)


def _next_surround_group(buf: TextBuffer) -> Int:
    var base = 60000 + buf.version
    if len(buf.undos) > 0:
        var prev = buf.undos[len(buf.undos) - 1].group
        if prev < 0:
            prev = -prev
        if prev >= base:
            base = prev + 1
    return base


def apply_surround_add(
    mut buf: TextBuffer,
    r1: Int,
    c1: Int,
    r2: Int,
    c2: Int,
    ch: Int,
    linewise: Bool = False,
) -> Pos:
    """Wrap span `(r1, c1)..(r2, c2)` (or lines `r1..r2` when `linewise`) with `surround_pair(ch)`."""
    if buf.count() <= 0 or r1 < 0 or r2 < r1 or r2 >= buf.count():
        return Pos(max(0, r1), max(0, c1))
    var pair = surround_pair(ch)
    var open_s = pair[0]
    var close_s = pair[1]
    if open_s.byte_length() == 0:
        return Pos(r1, c1)

    var grp = _next_surround_group(buf)
    if linewise:
        var first_ln = buf.line(r1)
        var ind_cps = List[Int]()
        for cp in first_ln:
            if cp == 32 or cp == 9:
                ind_cps.append(cp)
            else:
                break
        var indent_s = to_str(ind_cps)
        var open_line = indent_s + String(open_s.strip()) + "\n"
        var close_line = "\n" + indent_s + String(close_s.strip())
        _ = buf.insert(r2, buf.llen(r2), decode(close_line), r1, 0, grp)
        _ = buf.insert(r1, 0, decode(open_line), r1, 0, grp)
        return Pos(r1, len(ind_cps))

    _ = buf.insert(r2, c2, decode(close_s), r1, c1, grp)
    _ = buf.insert(r1, c1, decode(open_s), r1, c1, grp)
    return Pos(r1, c1)


def _compute_delimiter_delete_spans(
    buf: TextBuffer, open_r: Int, open_c: Int, close_r: Int, close_c: Int, ch: Int
) -> Tuple[Int, Int]:
    """Return `(open_del_end_col, close_del_start_col)` accounting for inner space padding on
    spaced opening bracket keys (`(`, `[`, `{`, `<`)."""
    var open_end = open_c + 1
    var close_start = close_c
    if _is_spaced_opener(ch):
        var open_ln = buf.line(open_r)
        var close_ln = buf.line(close_r)
        if open_c + 1 < len(open_ln) and open_ln[open_c + 1] == 32:
            if open_r < close_r or open_c + 1 < close_c:
                open_end = open_c + 2
        if close_c - 1 >= 0 and close_c - 1 < len(close_ln) and close_ln[close_c - 1] == 32:
            if open_r < close_r or close_c - 1 >= open_end:
                close_start = close_c - 1
    return (open_end, close_start)


def apply_surround_delete(
    mut buf: TextBuffer, cr: Int, cc: Int, target_ch: Int
) -> Tuple[Bool, Pos]:
    """Delete nearest enclosing delimiter `target_ch` (`ds<target>`)."""
    var enc = find_enclosing_surround(buf, cr, cc, target_ch)
    if not enc[0]:
        return (False, Pos(cr, cc))
    var open_r = enc[1]
    var open_c = enc[2]
    var close_r = enc[3]
    var close_c = enc[4]
    var bounds = _compute_delimiter_delete_spans(buf, open_r, open_c, close_r, close_c, target_ch)
    var open_end = bounds[0]
    var close_start = bounds[1]
    var grp = _next_surround_group(buf)
    _ = buf.delete(close_r, close_start, close_r, close_c + 1, cr, cc, grp)
    _ = buf.delete(open_r, open_c, open_r, open_end, cr, cc, grp)
    return (True, Pos(open_r, open_c))


def apply_surround_change(
    mut buf: TextBuffer, cr: Int, cc: Int, old_ch: Int, new_ch: Int
) -> Tuple[Bool, Pos]:
    """Change nearest enclosing delimiter `old_ch` to `surround_pair(new_ch)` (`cs<old><new>`)."""
    var enc = find_enclosing_surround(buf, cr, cc, old_ch)
    if not enc[0]:
        return (False, Pos(cr, cc))
    var pair = surround_pair(new_ch)
    if pair[0].byte_length() == 0:
        return (False, Pos(cr, cc))

    var open_r = enc[1]
    var open_c = enc[2]
    var close_r = enc[3]
    var close_c = enc[4]

    # When changing between any bracket variants (e.g. `cs(]` or `cs([`), strip existing single
    # inner padding space if both sides are padded so `"( x )"` -> `"[x]"` or `"[ x ]"` cleanly.
    var strip_ch = old_ch
    var old_br = _surround_bracket_cps(old_ch)
    if old_br[0] and not _is_spaced_opener(old_ch):
        var open_ln = buf.line(open_r)
        var close_ln = buf.line(close_r)
        var has_open_sp = open_c + 1 < len(open_ln) and open_ln[open_c + 1] == 32
        var has_close_sp = close_c - 1 > open_c and close_c - 1 < len(close_ln) and close_ln[close_c - 1] == 32
        if has_open_sp and has_close_sp and _is_spaced_opener(new_ch):
            strip_ch = old_br[1]

    var bounds = _compute_delimiter_delete_spans(buf, open_r, open_c, close_r, close_c, strip_ch)
    var open_end = bounds[0]
    var close_start = bounds[1]
    var grp = _next_surround_group(buf)

    _ = buf.delete(close_r, close_start, close_r, close_c + 1, cr, cc, grp)
    _ = buf.insert(close_r, close_start, decode(pair[1]), cr, cc, grp)
    _ = buf.delete(open_r, open_c, open_r, open_end, cr, cc, grp)
    _ = buf.insert(open_r, open_c, decode(pair[0]), cr, cc, grp)
    return (True, Pos(open_r, open_c))


# ---------------------------------------------------------------------------
# 4. Harpoon Quick-Marks (`HarpoonList`) & Change-List (`VimChangeList`)
# ---------------------------------------------------------------------------


@fieldwise_init
struct HarpoonEntry(Copyable, Movable):
    var path: String
    var row: Int
    var col: Int
    var label: String


def _path_basename(path: String) -> String:
    var bs = path.as_bytes()
    var last_sep = -1
    for i in range(len(bs)):
        if bs[i] == 47 or bs[i] == 92:
            last_sep = i
    if last_sep >= 0 and last_sep + 1 < path.byte_length():
        return String(path[byte=last_sep + 1 :])
    return path


def _toml_escape(s: String) -> String:
    var out = String("")
    var cps = decode(s)
    for cp in cps:
        if cp == 92:
            out += "\\\\"
        elif cp == 34:
            out += "\\\""
        elif cp == 10:
            out += "\\n"
        elif cp == 9:
            out += "\\t"
        else:
            out += chr(cp)
    return out


def _toml_unescape(raw: String) -> String:
    var s = String(raw.strip())
    if s.byte_length() >= 2 and s.startswith("\"") and s.endswith("\""):
        var inner = String(s[byte=1 : s.byte_length() - 1])
        s = inner
    var cps = decode(s)
    var out = String("")
    var i = 0
    while i < len(cps):
        if cps[i] == 92 and i + 1 < len(cps):
            var nx = cps[i + 1]
            if nx == 110:
                out += "\n"
            elif nx == 116:
                out += "\t"
            else:
                out += chr(nx)
            i += 2
            continue
        out += chr(cps[i])
        i += 1
    return out


def _parse_nonneg_int(raw: String) -> Int:
    var s = String(raw.strip())
    if s.byte_length() == 0:
        return 0
    var bs = s.as_bytes()
    var val = 0
    for i in range(len(bs)):
        var b = Int(bs[i])
        if b >= 48 and b <= 57:
            val = val * 10 + (b - 48)
        else:
            break
    return val


struct HarpoonList(Copyable, Movable):
    var entries: List[HarpoonEntry]

    def __init__(out self):
        self.entries = List[HarpoonEntry]()

    def count(self) -> Int:
        return len(self.entries)

    def toggle_pin(
        mut self, path: String, row: Int, col: Int, label: String = ""
    ) -> Int:
        """Pin `path` into slots `1..9` (returning 1-based slot) or unpin if already present
        (returning `0`)."""
        if path.byte_length() == 0:
            return 0
        for i in range(len(self.entries)):
            if self.entries[i].path == path:
                _ = self.entries.pop(i)
                return 0
        var eff_label = label if label.byte_length() > 0 else _path_basename(path)
        var entry = HarpoonEntry(path, max(0, row), max(0, col), eff_label)
        if len(self.entries) < HARPOON_MAX_SLOTS:
            self.entries.append(entry^)
            return len(self.entries)
        self.entries[HARPOON_MAX_SLOTS - 1] = entry^
        return HARPOON_MAX_SLOTS

    def update_position(mut self, path: String, row: Int, col: Int) -> Bool:
        """Update stored `(row, col)` if `path` is currently pinned."""
        for i in range(len(self.entries)):
            if self.entries[i].path == path:
                self.entries[i].row = max(0, row)
                self.entries[i].col = max(0, col)
                return True
        return False

    def slot_at(self, idx_1based: Int) -> Tuple[Bool, HarpoonEntry]:
        """Look up 1-based quick-mark slot (`1..9`)."""
        if idx_1based < 1 or idx_1based > len(self.entries):
            return (False, HarpoonEntry("", 0, 0, ""))
        return (True, self.entries[idx_1based - 1].copy())

    def format_menu_lines(self) -> List[String]:
        """Format quick-mark slots (`1..9`, highlighting primary `1..4`) for picker/menu display."""
        var lines = List[String]()
        for i in range(len(self.entries)):
            var slot_num = i + 1
            var e = self.entries[i].copy()
            var star = "*" if slot_num <= HARPOON_PRIMARY_SLOTS else " "
            var lbl = e.label if e.label.byte_length() > 0 else _path_basename(e.path)
            lines.append(
                "["
                + String(slot_num)
                + "]"
                + star
                + " "
                + lbl
                + "  ("
                + e.path
                + ":"
                + String(e.row + 1)
                + ":"
                + String(e.col + 1)
                + ")"
            )
        return lines^

    def serialize_toml(self) -> String:
        """Serialize pinned Harpoon slots to TOML."""
        var out = String("")
        for i in range(len(self.entries)):
            var e = self.entries[i].copy()
            if i > 0:
                out += "\n"
            out += "[[harpoon]]\n"
            out += "path = \"" + _toml_escape(e.path) + "\"\n"
            out += "row = " + String(e.row) + "\n"
            out += "col = " + String(e.col) + "\n"
            out += "label = \"" + _toml_escape(e.label) + "\"\n"
        return out

    @staticmethod
    def parse_serialized(text: String) -> HarpoonList:
        """Parse `HarpoonList` from TOML serialized text."""
        var h = HarpoonList()
        var in_item = False
        var cur_path = String("")
        var cur_row = 0
        var cur_col = 0
        var cur_label = String("")

        for raw_ln in text.split("\n"):
            var ln = String(raw_ln.strip())
            if ln.byte_length() == 0 or ln.startswith("#"):
                continue
            if ln == "[[harpoon]]":
                if in_item and cur_path.byte_length() > 0 and len(h.entries) < HARPOON_MAX_SLOTS:
                    var lbl = cur_label if cur_label.byte_length() > 0 else _path_basename(cur_path)
                    h.entries.append(HarpoonEntry(cur_path, cur_row, cur_col, lbl))
                in_item = True
                cur_path = ""
                cur_row = 0
                cur_col = 0
                cur_label = ""
                continue
            if ln.startswith("["):
                if in_item and cur_path.byte_length() > 0 and len(h.entries) < HARPOON_MAX_SLOTS:
                    var lbl2 = cur_label if cur_label.byte_length() > 0 else _path_basename(cur_path)
                    h.entries.append(HarpoonEntry(cur_path, cur_row, cur_col, lbl2))
                in_item = False
                continue
            if not in_item:
                continue
            var eq = ln.find("=")
            if eq <= 0:
                continue
            var key = String(ln[byte=0:eq].strip())
            var val = String(ln[byte=eq + 1 :].strip())
            if key == "path":
                cur_path = _toml_unescape(val)
            elif key == "row":
                cur_row = _parse_nonneg_int(val)
            elif key == "col":
                cur_col = _parse_nonneg_int(val)
            elif key == "label":
                cur_label = _toml_unescape(val)

        if in_item and cur_path.byte_length() > 0 and len(h.entries) < HARPOON_MAX_SLOTS:
            var lbl_last = cur_label if cur_label.byte_length() > 0 else _path_basename(cur_path)
            h.entries.append(HarpoonEntry(cur_path, cur_row, cur_col, lbl_last))

        return h^


def parse_serialized(text: String) -> HarpoonList:
    """Module-level convenience wrapper for `HarpoonList.parse_serialized`."""
    return HarpoonList.parse_serialized(text)


struct VimChangeList(Copyable, Movable):
    var rows: List[Int]
    var cols: List[Int]
    var index: Int

    def __init__(out self):
        self.rows = List[Int]()
        self.cols = List[Int]()
        self.index = 0

    def count(self) -> Int:
        return len(self.rows)

    def record(mut self, row: Int, col: Int):
        """Record an edit position `(row, col)` (up to 64 entries) and reset browse pointer."""
        var r = max(0, row)
        var c = max(0, col)
        var n = len(self.rows)
        if n > 0 and self.rows[n - 1] == r and self.cols[n - 1] == c:
            self.index = n
            return
        if n >= CHANGE_LIST_MAX:
            _ = self.rows.pop(0)
            _ = self.cols.pop(0)
        self.rows.append(r)
        self.cols.append(c)
        self.index = len(self.rows)

    def jump_older(mut self, cur_r: Int, cur_c: Int) -> Tuple[Bool, Int, Int]:
        """Jump backward (`g;`) to an older edit position."""
        var n = len(self.rows)
        if n == 0:
            return (False, cur_r, cur_c)
        if self.index >= n:
            if n >= 2 and self.rows[n - 1] == cur_r and self.cols[n - 1] == cur_c:
                self.index = n - 2
            else:
                self.index = n - 1
            return (True, self.rows[self.index], self.cols[self.index])
        if self.index <= 0:
            return (False, self.rows[0], self.cols[0])
        self.index -= 1
        return (True, self.rows[self.index], self.cols[self.index])

    def jump_newer(mut self) -> Tuple[Bool, Int, Int]:
        """Jump forward (`g,`) to a newer edit position."""
        var n = len(self.rows)
        if n == 0 or self.index >= n - 1:
            if n > 0 and self.index < n:
                return (False, self.rows[self.index], self.cols[self.index])
            return (False, 0, 0)
        self.index += 1
        return (True, self.rows[self.index], self.cols[self.index])


comptime ChangeList = VimChangeList
