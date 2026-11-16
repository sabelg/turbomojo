"""Structural refactorings & One-Click Mojo 1.2 Migration Assistant.

Provides:
- `migrate_mojo12_buffer(buf)`: syntax-highlighted, comment- & string-safe migration of
  legacy Mojo constructs (`fn`, `let`, `alias`, `@parameter` `if`/`for`, `inout`, `owned`,
  `borrowed`, `@value` + `(Copyable, Movable)` on `struct`, and bare stdlib imports) into
  clean non-overlapping `LspEdit`s ready for `offer_edit()` / 1-step Undo.
- `extract_variable_edits(...)`: Extract Variable refactoring on the active selection.
- `extract_function_edits(...)`: Extract Function refactoring on the active selection,
  inferring free local variables (and `mut` conventions in Mojo) plus single-variable
  return values when referenced after the extracted block.
"""
from std.collections import List
from buffer import TextBuffer
from highlight import Highlighter, HL_MOJO, HL_PYTHON, C_CMT, C_STR
from lsp import LspEdit, col_to_utf16
from mojocst import (
    CstSpan,
    CstParam,
    CstDefNode,
    CstStructNode,
    CstCallSite,
    _split_top_level_commas,
    parse_cst_param,
    format_cst_param,
    parse_mojo_cst,
    find_enclosing_call,
    find_all_calls_to,
)
from util import decode, to_str, slice_str, is_alpha, is_ident, is_digit


def is_valid_ident(name: String) -> Bool:
    var cps = decode(name)
    if len(cps) == 0 or not is_alpha(cps[0]):
        return False
    for i in range(1, len(cps)):
        if not is_ident(cps[i]):
            return False
    for kw in [
        "def", "fn", "var", "let", "comptime", "alias", "struct", "trait", "class",
        "return", "if", "elif", "else", "for", "while", "in", "import", "from",
        "raises", "True", "False", "None", "and", "or", "not", "mut", "out",
    ]:
        if name == String(kw):
            return False
    return True


def _is_code_at(cls: List[Int], idx: Int) -> Bool:
    if idx < 0 or idx >= len(cls):
        return False
    return cls[idx] != C_CMT and cls[idx] != C_STR


def _first_code_col(cps: List[Int], cls: List[Int]) -> Int:
    var n = len(cps)
    var i = 0
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    if i >= n or not _is_code_at(cls, i):
        return -1
    return i


def _code_end_col(cps: List[Int], cls: List[Int]) -> Int:
    """Exclusive end column of non-comment code on a line (before trailing `# ...`)."""
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


def _is_stdlib_mod(mod: String) -> Bool:
    for m in [
        "collections", "testing", "memory", "sys", "os", "math", "algorithm",
        "time", "utils", "random", "pathlib", "tempfile", "ffi", "io", "hashlib",
        "logger", "subprocess", "complex", "bit", "benchmark", "compile",
        "python", "atomic", "iter", "base64",
    ]:
        if mod == String(m):
            return True
    return False


def _match_word_at(cps: List[Int], cls: List[Int], pos: Int, word: String) -> Bool:
    var wcps = decode(word)
    var wn = len(wcps)
    var n = len(cps)
    if pos < 0 or pos + wn > n:
        return False
    if pos > 0 and is_ident(cps[pos - 1]):
        return False
    if pos + wn < n and is_ident(cps[pos + wn]):
        return False
    for k in range(wn):
        if cps[pos + k] != wcps[k] or not _is_code_at(cls, pos + k):
            return False
    return True


def _next_code_ident(cps: List[Int], cls: List[Int], from_col: Int) -> String:
    var n = len(cps)
    var i = from_col
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    if i >= n or not _is_code_at(cls, i) or not is_alpha(cps[i]):
        return ""
    var j = i
    while j < n and _is_code_at(cls, j) and is_ident(cps[j]):
        j += 1
    return slice_str(cps, i, j)


@fieldwise_init
struct _SpanRep(Copyable, Movable):
    var c1: Int
    var c2: Int
    var repl: String


def _apply_line_reps(cps: List[Int], reps: List[_SpanRep]) -> String:
    if len(reps) == 0:
        return to_str(cps)
    var out = String("")
    var cur = 0
    for rp in reps:
        if rp.c1 >= cur:
            out += slice_str(cps, cur, rp.c1)
            out += rp.repl
            cur = rp.c2
    if cur < len(cps):
        out += slice_str(cps, cur, len(cps))
    return out


def _struct_colon_without_traits(cps: List[Int], cls: List[Int], start_col: Int) -> Int:
    """If line starts with `struct Name[...]:` (no `(Traits)` list before `:`), return
    the codepoint column of `:`; otherwise return -1."""
    if not _match_word_at(cps, cls, start_col, "struct"):
        return -1
    var n = len(cps)
    var i = start_col + 6
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    if i >= n or not _is_code_at(cls, i) or not is_alpha(cps[i]):
        return -1
    while i < n and _is_code_at(cls, i) and is_ident(cps[i]):
        i += 1
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    if i < n and _is_code_at(cls, i) and cps[i] == 91:
        var bdepth = 1
        i += 1
        while i < n and bdepth > 0:
            if _is_code_at(cls, i):
                if cps[i] == 91:
                    bdepth += 1
                elif cps[i] == 93:
                    bdepth -= 1
            i += 1
        while i < n and (cps[i] == 32 or cps[i] == 9):
            i += 1
    if i < n and _is_code_at(cls, i) and cps[i] == 58:
        return i
    return -1


def migrate_mojo12_buffer(buf: TextBuffer) -> List[LspEdit]:
    """Produce consolidated non-overlapping `LspEdit`s migrating legacy Mojo syntax in `buf`
    to Mojo 1.2 while leaving comments and single-/triple-quoted strings untouched."""
    var edits = List[LspEdit]()
    var count = buf.count()
    if count <= 0:
        return edits^

    var hl = Highlighter()
    var lines_cps = List[List[Int]]()
    var lines_cls = List[List[Int]]()
    var st = 0
    for r in range(count):
        var cps = buf.line(r)
        var cls = List[Int]()
        st = hl.line(cps, st, cls, HL_MOJO)
        lines_cps.append(cps^)
        lines_cls.append(cls^)

    # Track `@value` decorator waiting to add `(Copyable, Movable)` on its `struct` header
    var pending_value_struct = False
    # Track multi-line `def` / `fn` parameter lists for `inout` / `owned` / `borrowed`
    var waiting_sig_paren = False
    var sig_bdepth = 0
    var sig_pdepth = 0
    var sig_is_init = False

    var r = 0
    while r < count:
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var fc = _first_code_col(cps, cls)
        var ce = _code_end_col(cps, cls)

        # Check 2-line `@parameter\n<indent>if/for ...`
        if fc >= 0 and slice_str(cps, fc, ce) == "@parameter" and r + 1 < count:
            var cps2 = lines_cps[r + 1].copy()
            var cls2 = lines_cls[r + 1].copy()
            var fc2 = _first_code_col(cps2, cls2)
            if fc2 >= 0 and (
                _match_word_at(cps2, cls2, fc2, "if") or _match_word_at(cps2, cls2, fc2, "for")
            ):
                var merged = slice_str(cps2, 0, fc2) + "comptime " + slice_str(cps2, fc2, len(cps2))
                edits.append(LspEdit(r, 0, r + 1, col_to_utf16(cps2, len(cps2)), merged))
                r += 2
                continue

        var reps = List[_SpanRep]()
        var scan_from = 0

        if fc >= 0 and sig_pdepth == 0 and not waiting_sig_paren:
            var code_trim = slice_str(cps, fc, ce)
            # 1. `@value` -> `@fieldwise_init` (+ remember to add `(Copyable, Movable)` to struct)
            if code_trim == "@value" or code_trim.startswith("@value("):
                reps.append(_SpanRep(fc, fc + 6, "@fieldwise_init"))
                pending_value_struct = True
                scan_from = len(cps)
            # 2. Inline `@parameter if` / `@parameter for` -> `comptime if` / `comptime for`
            elif code_trim.startswith("@parameter ") and (
                _match_word_at(cps, cls, fc + 11, "if") or _match_word_at(cps, cls, fc + 11, "for")
            ):
                reps.append(_SpanRep(fc, fc + 10, "comptime"))
                scan_from = fc + 11
            # 3. Bare stdlib imports: `from <mod> import ...` / `import <mod>`
            elif _match_word_at(cps, cls, fc, "from") or _match_word_at(cps, cls, fc, "import"):
                var is_from = _match_word_at(cps, cls, fc, "from")
                var kw_len = 4 if is_from else 6
                var mcol = fc + kw_len
                while mcol < len(cps) and (cps[mcol] == 32 or cps[mcol] == 9):
                    mcol += 1
                if mcol < len(cps) and _is_code_at(cls, mcol) and is_alpha(cps[mcol]):
                    var mend = mcol
                    while mend < len(cps) and _is_code_at(cls, mend) and is_ident(cps[mend]):
                        mend += 1
                    var mod_name = slice_str(cps, mcol, mend)
                    # Only bare module (not `std.x` and not relative `.x`)
                    if (mcol == 0 or cps[mcol - 1] != 46) and _is_stdlib_mod(mod_name):
                        var ok_follow: Bool
                        if is_from:
                            # `from math.foo import ...` or `from math import ...` both move under `std.`
                            ok_follow = True
                        else:
                            # `import math` / `import math as m` / `import math.foo`
                            ok_follow = mend == ce or cps[mend] == 32 or cps[mend] == 9 or cps[mend] == 46 or cps[mend] == 44
                        if ok_follow:
                            reps.append(_SpanRep(mcol, mcol, "std."))
                scan_from = len(cps)
            # 4. `let ` -> `var `
            elif _match_word_at(cps, cls, fc, "let"):
                reps.append(_SpanRep(fc, fc + 3, "var"))
                scan_from = fc + 3
            # 5. `alias ` -> `comptime `
            elif _match_word_at(cps, cls, fc, "alias"):
                reps.append(_SpanRep(fc, fc + 5, "comptime"))
                scan_from = fc + 5
            # 6. `fn ` / `async fn ` / `def ` / `async def `
            elif (
                _match_word_at(cps, cls, fc, "fn")
                or _match_word_at(cps, cls, fc, "def")
                or _match_word_at(cps, cls, fc, "async")
            ):
                pending_value_struct = False
                var fn_kw_col = fc
                if _match_word_at(cps, cls, fc, "async"):
                    var k2 = fc + 5
                    while k2 < len(cps) and (cps[k2] == 32 or cps[k2] == 9):
                        k2 += 1
                    fn_kw_col = k2
                if _match_word_at(cps, cls, fn_kw_col, "fn"):
                    reps.append(_SpanRep(fn_kw_col, fn_kw_col + 2, "def"))
                    var fname = _next_code_ident(cps, cls, fn_kw_col + 2)
                    sig_is_init = fname == "__init__"
                    waiting_sig_paren = True
                    sig_bdepth = 0
                    scan_from = fn_kw_col + 2
                elif _match_word_at(cps, cls, fn_kw_col, "def"):
                    var fname = _next_code_ident(cps, cls, fn_kw_col + 3)
                    sig_is_init = fname == "__init__"
                    waiting_sig_paren = True
                    sig_bdepth = 0
                    scan_from = fn_kw_col + 3
            # 7. `struct` following `@value`
            elif _match_word_at(cps, cls, fc, "struct"):
                if pending_value_struct:
                    var colon_col = _struct_colon_without_traits(cps, cls, fc)
                    if colon_col >= 0:
                        reps.append(_SpanRep(colon_col, colon_col, "(Copyable, Movable)"))
                    pending_value_struct = False
                scan_from = len(cps)
            elif not code_trim.startswith("@"):
                pending_value_struct = False

        # Scan signature tokens (`inout`, `owned`, `borrowed`) across single- or multi-line headers
        if waiting_sig_paren or sig_pdepth > 0:
            var i = max(scan_from, 0)
            var n = len(cps)
            while i < n:
                if not _is_code_at(cls, i):
                    i += 1
                    continue
                var ch = cps[i]
                if waiting_sig_paren:
                    if ch == 91:
                        sig_bdepth += 1
                    elif ch == 93 and sig_bdepth > 0:
                        sig_bdepth -= 1
                    elif ch == 40 and sig_bdepth == 0:
                        waiting_sig_paren = False
                        sig_pdepth = 1
                    elif ch == 58 and sig_bdepth == 0:
                        waiting_sig_paren = False
                    i += 1
                    continue
                # Inside `sig_pdepth > 0`
                if ch == 40:
                    sig_pdepth += 1
                    i += 1
                    continue
                if ch == 41:
                    sig_pdepth -= 1
                    i += 1
                    if sig_pdepth <= 0:
                        sig_pdepth = 0
                        sig_is_init = False
                        break
                    continue
                if sig_pdepth == 1 and is_alpha(ch) and (i == 0 or not is_ident(cps[i - 1])):
                    var j = i
                    while j < n and _is_code_at(cls, j) and is_ident(cps[j]):
                        j += 1
                    var tok = slice_str(cps, i, j)
                    if tok == "inout":
                        var nxt = _next_code_ident(cps, cls, j)
                        if sig_is_init and nxt == "self":
                            reps.append(_SpanRep(i, j, "out"))
                        else:
                            reps.append(_SpanRep(i, j, "mut"))
                    elif tok == "owned":
                        reps.append(_SpanRep(i, j, "var"))
                    elif tok == "borrowed":
                        var del_end = j
                        if del_end < n and cps[del_end] == 32:
                            del_end += 1
                        reps.append(_SpanRep(i, del_end, ""))
                        i = del_end
                        continue
                    i = j
                    continue
                i += 1

        if len(reps) > 0:
            var new_ln = _apply_line_reps(cps, reps)
            var orig_ln = to_str(cps)
            if new_ln != orig_ln:
                edits.append(LspEdit(r, 0, r, col_to_utf16(cps, len(cps)), new_ln))
        r += 1

    return edits^


# ===========================================================================
# Extract Variable & Extract Function
# ===========================================================================

def extract_variable_edits(
    buf: TextBuffer,
    r1: Int,
    c1: Int,
    r2: Int,
    c2: Int,
    var_name: String,
    is_mojo: Bool,
) -> Tuple[String, List[LspEdit]]:
    """Build `LspEdit`s extracting selected single-line expression `(r1, c1)..(r2, c2)`
    into `var <var_name> = <expr>` (Mojo) or `<var_name> = <expr>` (Python)."""
    var edits = List[LspEdit]()
    var clean_name = String(var_name.strip())
    if not is_valid_ident(clean_name):
        return ("Invalid variable name: " + clean_name, edits^)
    if r1 < 0 or r1 >= buf.count() or r1 != r2:
        return ("Select a single-line expression to extract into a variable", edits^)
    var ln = buf.line(r1)
    var sc1 = max(0, min(c1, len(ln)))
    var sc2 = max(0, min(c2, len(ln)))
    while sc1 < sc2 and (ln[sc1] == 32 or ln[sc1] == 9):
        sc1 += 1
    while sc2 > sc1 and (ln[sc2 - 1] == 32 or ln[sc2 - 1] == 9):
        sc2 -= 1
    if sc2 <= sc1:
        return ("Select a non-empty expression to extract", edits^)
    var expr = slice_str(ln, sc1, sc2)
    var ind = 0
    while ind < len(ln) and (ln[ind] == 32 or ln[ind] == 9):
        ind += 1
    var indent = slice_str(ln, 0, ind)
    var decl = indent + ("var " if is_mojo else "") + clean_name + " = " + expr
    var updated = slice_str(ln, 0, sc1) + clean_name + slice_str(ln, sc2, len(ln))
    edits.append(LspEdit(r1, 0, r1, col_to_utf16(ln, len(ln)), decl + "\n" + updated))
    return ("", edits^)


@fieldwise_init
struct _VarDecl(Copyable, Movable):
    var name: String
    var ty: String


def _lookup_var_type(vars: List[_VarDecl], name: String) -> String:
    for i in range(len(vars) - 1, -1, -1):
        if vars[i].name == name:
            return vars[i].ty
    return ""


def _has_var(vars: List[_VarDecl], name: String) -> Bool:
    for v in vars:
        if v.name == name:
            return True
    return False


def _has_str(items: List[String], s: String) -> Bool:
    for it in items:
        if it == s:
            return True
    return False


def _infer_mojo_type(rhs_raw: String, known: List[_VarDecl]) -> String:
    var rhs = String(rhs_raw.strip())
    # Strip trailing inline `# ...` comment if outside quotes
    var cps = decode(rhs)
    var hl = Highlighter()
    var cls = List[Int]()
    _ = hl.line(cps, 0, cls, HL_MOJO)
    var ce = _code_end_col(cps, cls)
    rhs = String(slice_str(cps, 0, ce).strip())
    if rhs.byte_length() == 0:
        return "Int"
    if rhs == "True" or rhs == "False" or rhs.startswith("Bool("):
        return "Bool"
    if rhs.startswith("\"") or rhs.startswith("'") or rhs.startswith("String("):
        return "String"
    if rhs.startswith("Float64(") or rhs.startswith("Float32("):
        return "Float64" if rhs.startswith("Float64(") else "Float32"
    if rhs.startswith("Int(") or rhs.startswith("len(") or rhs.startswith("atol("):
        return "Int"
    if rhs.startswith("List[") and rhs.endswith("()"):
        var p = rhs.rfind("(")
        if p > 0:
            return String(rhs[byte=0:p])
    # Pure numeric literal?
    var rcps = decode(rhs)
    var start_d = 1 if (len(rcps) > 1 and rcps[0] == 45) else 0
    if start_d < len(rcps) and is_digit(rcps[start_d]):
        var all_num = True
        var has_dot = False
        for k in range(start_d, len(rcps)):
            var c = rcps[k]
            if c == 46:
                has_dot = True
            elif not is_digit(c) and c != 95:
                all_num = False
                break
        if all_num:
            return "Float64" if has_dot else "Int"
    # Scan identifiers in expression: if any known Float64 -> Float64, String -> String, Bool comparison -> Bool
    var rc_cls = List[Int]()
    _ = hl.line(rcps, 0, rc_cls, HL_MOJO)
    if rhs.find("==") >= 0 or rhs.find("!=") >= 0 or rhs.find("<=") >= 0 or rhs.find(">=") >= 0:
        return "Bool"
    var seen_type = String("")
    var k = 0
    while k < len(rcps):
        if _is_code_at(rc_cls, k) and is_alpha(rcps[k]) and (k == 0 or not is_ident(rcps[k - 1])):
            var j = k
            while j < len(rcps) and _is_code_at(rc_cls, j) and is_ident(rcps[j]):
                j += 1
            var id = slice_str(rcps, k, j)
            var kt = _lookup_var_type(known, id)
            if kt == "Float64":
                return "Float64"
            if kt == "String":
                return "String"
            if kt.byte_length() > 0 and seen_type.byte_length() == 0:
                seen_type = kt
            k = j
        else:
            k += 1
    if seen_type.byte_length() > 0:
        return seen_type
    return "Int"


def _leading_ws_cols(cps: List[Int]) -> Int:
    var i = 0
    while i < len(cps) and (cps[i] == 32 or cps[i] == 9):
        i += 1
    return i


def _leading_indent_width(cps: List[Int]) -> Int:
    var w = 0
    for c in cps:
        if c == 32:
            w += 1
        elif c == 9:
            w += 4
        else:
            break
    return w


def _parse_sig_params(buf: TextBuffer, def_row: Int, mut out: List[_VarDecl]):
    """Extract parameter `(name, type)` declarations from enclosing `def` / `fn` header."""
    var joined = String("")
    var r = def_row
    while r < buf.count() and r <= def_row + 12:
        var ln = to_str(buf.line(r))
        joined += " " + ln
        if ln.find("):") >= 0 or ln.find(") ->") >= 0 or ln.find(") raises") >= 0:
            break
        r += 1
    var lp = joined.find("(")
    if lp < 0:
        return
    # Match closing `)`
    var cps = decode(joined)
    var p_start = -1
    for idx in range(len(cps)):
        if cps[idx] == 40:
            p_start = idx
            break
    if p_start < 0:
        return
    var depth = 1
    var p_end = -1
    var cur = p_start + 1
    while cur < len(cps) and depth > 0:
        if cps[cur] == 40:
            depth += 1
        elif cps[cur] == 41:
            depth -= 1
            if depth == 0:
                p_end = cur
                break
        cur += 1
    if p_end < 0:
        return
    # Split top-level commas inside `p_start + 1 .. p_end`
    var seg_start = p_start + 1
    var bdepth = 0
    for idx in range(p_start + 1, p_end + 1):
        var at_end = idx == p_end
        var ch = cps[idx] if not at_end else 44
        if not at_end:
            if ch == 91 or ch == 40:
                bdepth += 1
            elif (ch == 93 or ch == 41) and bdepth > 0:
                bdepth -= 1
        if at_end or (ch == 44 and bdepth == 0):
            var raw_p = String(slice_str(cps, seg_start, idx).strip())
            seg_start = idx + 1
            if raw_p.byte_length() == 0:
                continue
            # Strip parameter convention prefix (`mut `, `var `, `out `, `imm `, `inout `, `owned `, `borrowed `)
            for conv in ["mut ", "var ", "out ", "imm ", "inout ", "owned ", "borrowed "]:
                var cs = String(conv)
                if raw_p.startswith(cs):
                    var stripped_p = String(raw_p[byte=cs.byte_length():].lstrip())
                    raw_p = stripped_p
                    break
            if raw_p == "self":
                out.append(_VarDecl("self", "Self"))
                continue
            var colon = raw_p.find(":")
            if colon > 0:
                var pname = String(raw_p[byte=0:colon].strip())
                var ptype = String(raw_p[byte=colon + 1:].strip())
                var eq = ptype.find("=")
                if eq > 0:
                    var trimmed_pt = String(ptype[byte=0:eq].strip())
                    ptype = trimmed_pt
                if pname.byte_length() > 0:
                    out.append(_VarDecl(pname, ptype if ptype.byte_length() > 0 else String("Int")))
            else:
                var eq = raw_p.find("=")
                var pname = String(raw_p[byte=0:eq].strip()) if eq > 0 else raw_p
                if pname.byte_length() > 0 and pname != "*":
                    out.append(_VarDecl(pname, "Int"))


def _scan_line_decl(
    cps: List[Int],
    cls: List[Int],
    mut decls: List[_VarDecl],
    mut assigned: List[String],
):
    """Detect `var x[: T] = rhs`, `for x in ...`, or `x = rhs` / `x += rhs` on one line."""
    var fc = _first_code_col(cps, cls)
    if fc < 0:
        return
    var ce = _code_end_col(cps, cls)
    var code = slice_str(cps, fc, ce)
    if code.startswith("var ") or code.startswith("let "):
        var rest = String(code[byte=4:].lstrip())
        var rcps = decode(rest)
        var j = 0
        while j < len(rcps) and is_ident(rcps[j]):
            j += 1
        if j > 0:
            var vname = slice_str(rcps, 0, j)
            var after = String(slice_str(rcps, j, len(rcps)).lstrip())
            var vtype = String("Int")
            if after.startswith(":"):
                var tpart = String(after[byte=1:].lstrip())
                var eq = tpart.find("=")
                if eq >= 0:
                    vtype = String(tpart[byte=0:eq].strip())
                else:
                    vtype = String(tpart.strip())
            elif after.startswith("="):
                vtype = _infer_mojo_type(String(after[byte=1:]), decls)
            if not _has_var(decls, vname):
                decls.append(_VarDecl(vname, vtype))
            if not _has_str(assigned, vname):
                assigned.append(vname)
        return
    if code.startswith("for "):
        var rest = String(code[byte=4:].lstrip())
        var rcps = decode(rest)
        var j = 0
        while j < len(rcps) and is_ident(rcps[j]):
            j += 1
        if j > 0:
            var vname = slice_str(rcps, 0, j)
            if not _has_var(decls, vname):
                decls.append(_VarDecl(vname, "Int"))
        return
    # Check assignment `ident = ...` or `ident += ...`
    if is_alpha(cps[fc]):
        var j = fc
        while j < ce and _is_code_at(cls, j) and is_ident(cps[j]):
            j += 1
        var vname = slice_str(cps, fc, j)
        var k = j
        while k < ce and (cps[k] == 32 or cps[k] == 9):
            k += 1
        var is_assign = False
        var rhs_col = -1
        if k < ce and cps[k] == 61 and (k + 1 >= ce or cps[k + 1] != 61):
            is_assign = True
            rhs_col = k + 1
        elif k + 1 < ce and (cps[k] == 43 or cps[k] == 45 or cps[k] == 42 or cps[k] == 47) and cps[k + 1] == 61:
            is_assign = True
            rhs_col = k + 2
        elif k + 2 < ce and cps[k] == 47 and cps[k + 1] == 47 and cps[k + 2] == 61:
            is_assign = True
            rhs_col = k + 3
        if is_assign and is_valid_ident(vname):
            if not _has_str(assigned, vname):
                assigned.append(vname)
            if not _has_var(decls, vname) and rhs_col >= 0:
                decls.append(_VarDecl(vname, _infer_mojo_type(slice_str(cps, rhs_col, ce), decls)))


def _collect_used_idents(
    lines_cps: List[List[Int]],
    lines_cls: List[List[Int]],
    r_from: Int,
    r_to: Int,
) -> List[String]:
    var used = List[String]()
    for r in range(max(0, r_from), min(len(lines_cps), r_to + 1)):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var n = len(cps)
        var i = 0
        while i < n:
            if _is_code_at(cls, i) and is_alpha(cps[i]) and (i == 0 or not is_ident(cps[i - 1])):
                var prev_dot = i > 0 and cps[i - 1] == 46 and _is_code_at(cls, i - 1)
                var j = i
                while j < n and _is_code_at(cls, j) and is_ident(cps[j]):
                    j += 1
                if not prev_dot:
                    var tok = slice_str(cps, i, j)
                    if not _has_str(used, tok):
                        used.append(tok)
                i = j
            else:
                i += 1
    return used^


def extract_function_edits(
    buf: TextBuffer,
    sel_r1: Int,
    sel_c1: Int,
    sel_r2: Int,
    sel_c2: Int,
    fn_name: String,
    is_mojo: Bool,
) -> Tuple[String, List[LspEdit]]:
    """Build `LspEdit`s extracting selected lines into a helper `def <fn_name>(...)`
    immediately above the enclosing `def` (or above the selection at top-level),
    inferring parameters, `mut` conventions, and single-variable return values."""
    var edits = List[LspEdit]()
    var clean_name = String(fn_name.strip())
    if not is_valid_ident(clean_name):
        return ("Invalid function name: " + clean_name, edits^)
    var count = buf.count()
    if count <= 0 or sel_r1 < 0 or sel_r1 >= count:
        return ("Select one or more statement lines to extract", edits^)

    var r_start = sel_r1
    var r_end = min(count - 1, sel_r2)
    if sel_r2 > sel_r1 and sel_c2 == 0:
        r_end = sel_r2 - 1
    _ = sel_c1
    while r_start <= r_end and String(to_str(buf.line(r_start)).strip()).byte_length() == 0:
        r_start += 1
    while r_end >= r_start and String(to_str(buf.line(r_end)).strip()).byte_length() == 0:
        r_end -= 1
    if r_start > r_end:
        return ("Selected lines contain no statements to extract", edits^)

    var hl = Highlighter()
    var lang = HL_MOJO if is_mojo else HL_PYTHON
    var lines_cps = List[List[Int]]()
    var lines_cls = List[List[Int]]()
    var st = 0
    for r in range(count):
        var cps = buf.line(r)
        var cls = List[Int]()
        st = hl.line(cps, st, cls, lang)
        lines_cps.append(cps^)
        lines_cls.append(cls^)

    # Minimum indentation across non-empty extracted lines
    var min_ws_cols = 999999
    var min_ind_w = 999999
    for r in range(r_start, r_end + 1):
        if String(to_str(lines_cps[r]).strip()).byte_length() == 0:
            continue
        var wc = _leading_ws_cols(lines_cps[r])
        var iw = _leading_indent_width(lines_cps[r])
        if iw < min_ind_w:
            min_ind_w = iw
            min_ws_cols = wc
    if min_ws_cols == 999999:
        min_ws_cols = 0
        min_ind_w = 0
    var stmt_indent = slice_str(lines_cps[r_start], 0, _leading_ws_cols(lines_cps[r_start]))

    # Locate enclosing `def` / `fn` above `r_start` (with strictly smaller indent)
    var def_row = -1
    var def_ind_w = 0
    var up = r_start - 1
    while up >= 0:
        var fc = _first_code_col(lines_cps[up], lines_cls[up])
        if fc >= 0:
            var iw = _leading_indent_width(lines_cps[up])
            if iw < min_ind_w and (
                _match_word_at(lines_cps[up], lines_cls[up], fc, "def")
                or _match_word_at(lines_cps[up], lines_cls[up], fc, "fn")
                or _match_word_at(lines_cps[up], lines_cls[up], fc, "async")
            ):
                def_row = up
                def_ind_w = iw
                break
        up -= 1

    var insert_row = r_start
    var fn_indent = String("")
    var enclosing_end = r_end
    if def_row >= 0:
        fn_indent = slice_str(lines_cps[def_row], 0, _leading_ws_cols(lines_cps[def_row]))
        insert_row = def_row
        while insert_row > 0:
            var pfc = _first_code_col(lines_cps[insert_row - 1], lines_cls[insert_row - 1])
            if pfc >= 0 and lines_cps[insert_row - 1][pfc] == 64:
                insert_row -= 1
            else:
                break
        enclosing_end = count - 1
        for r in range(r_end + 1, count):
            var fc = _first_code_col(lines_cps[r], lines_cls[r])
            if fc >= 0 and _leading_indent_width(lines_cps[r]) <= def_ind_w:
                enclosing_end = r - 1
                break

    # 1. Outer variables in scope before `r_start`
    var outer_vars = List[_VarDecl]()
    var dummy_assigned = List[String]()
    if def_row >= 0:
        _parse_sig_params(buf, def_row, outer_vars)
        for r in range(def_row + 1, r_start):
            _scan_line_decl(lines_cps[r], lines_cls[r], outer_vars, dummy_assigned)
    else:
        for r in range(0, r_start):
            _scan_line_decl(lines_cps[r], lines_cls[r], outer_vars, dummy_assigned)

    # 2. Declarations, mutations, and identifier uses inside `r_start .. r_end`
    var inner_vars = outer_vars.copy()
    var inner_only_decls = List[_VarDecl]()
    var inner_assigned = List[String]()
    for r in range(r_start, r_end + 1):
        var before_len = len(inner_vars)
        _scan_line_decl(lines_cps[r], lines_cls[r], inner_vars, inner_assigned)
        for k in range(before_len, len(inner_vars)):
            inner_only_decls.append(inner_vars[k].copy())

    var used_in_sel = _collect_used_idents(lines_cps, lines_cls, r_start, r_end)
    var used_after = _collect_used_idents(lines_cps, lines_cls, r_end + 1, enclosing_end)

    # Detect return variable: an inner-declared variable referenced after `r_end`
    var ret_var = String("")
    var ret_type = String("")
    var ret_is_new_decl = False
    for vd in inner_only_decls:
        if _has_str(used_after, vd.name):
            ret_var = vd.name
            ret_type = vd.ty
            ret_is_new_decl = True
            break

    # Build signature parameters & call arguments from referenced `outer_vars`
    var sig_params = List[String]()
    var call_args = List[String]()
    for ov in outer_vars:
        if _has_str(used_in_sel, ov.name):
            var is_mut = _has_str(inner_assigned, ov.name)
            if ov.name == "self":
                sig_params.append(("mut self" if is_mut else "self") if is_mojo else "self")
            else:
                if is_mojo:
                    sig_params.append(("mut " if is_mut else "") + ov.name + ": " + ov.ty)
                else:
                    sig_params.append(ov.name)
                call_args.append(ov.name)

    # Check if extracted body contains `raise ` or calls something when enclosing `def` has `raises`
    var needs_raises = False
    if is_mojo:
        if def_row >= 0 and to_str(lines_cps[def_row]).find("raises") >= 0:
            for r in range(r_start, r_end + 1):
                var fc = _first_code_col(lines_cps[r], lines_cls[r])
                if fc >= 0 and _match_word_at(lines_cps[r], lines_cls[r], fc, "raise"):
                    needs_raises = True
                    break

    var sig = fn_indent + "def " + clean_name + "(" + ", ".join(sig_params) + ")"
    if is_mojo and needs_raises:
        sig += " raises"
    if is_mojo and ret_var.byte_length() > 0:
        sig += " -> " + (ret_type if ret_type.byte_length() > 0 else String("Int"))
    sig += ":"

    var body_lines = List[String]()
    body_lines.append(sig)
    for r in range(r_start, r_end + 1):
        var cps = lines_cps[r].copy()
        if String(to_str(cps).strip()).byte_length() == 0:
            body_lines.append("")
        else:
            var strip_c = min(min_ws_cols, _leading_ws_cols(cps))
            body_lines.append(fn_indent + "    " + slice_str(cps, strip_c, len(cps)))
    if ret_var.byte_length() > 0:
        body_lines.append(fn_indent + "    return " + ret_var)

    var fn_block = "\n".join(body_lines)
    var call_expr = clean_name + "(" + ", ".join(call_args) + ")"
    var call_line: String
    if ret_var.byte_length() > 0:
        if ret_is_new_decl:
            call_line = stmt_indent + ("var " if is_mojo else "") + ret_var + " = " + call_expr
        else:
            call_line = stmt_indent + ret_var + " = " + call_expr
    else:
        call_line = stmt_indent + call_expr

    var end_u16 = col_to_utf16(lines_cps[r_end], len(lines_cps[r_end]))
    if insert_row < r_start:
        edits.append(LspEdit(insert_row, 0, insert_row, 0, fn_block + "\n\n"))
        edits.append(LspEdit(r_start, 0, r_end, end_u16, call_line))
    else:
        edits.append(LspEdit(r_start, 0, r_end, end_u16, fn_block + "\n\n" + call_line))
    return ("", edits^)


# ============================================================ Phase 17 CST Refactorings

def _span_to_lsp_edit(buf: TextBuffer, sp: CstSpan, new_text: String) -> LspEdit:
    var l1 = buf.line(sp.r1)
    var l2 = buf.line(sp.r2)
    return LspEdit(sp.r1, col_to_utf16(l1, sp.c1), sp.r2, col_to_utf16(l2, sp.c2), new_text)


def _needs_expr_parens(expr: String) -> Bool:
    """True when `expr` contains top-level binary operators / spaces that need `(expr)` when inlined."""
    var s = String(expr.strip())
    var cps = decode(s)
    if len(cps) == 0:
        return False
    var depth = 0
    var in_q = 0
    var esc = False
    for i in range(len(cps)):
        var ch = cps[i]
        if in_q != 0:
            if esc:
                esc = False
            elif ch == 92:
                esc = True
            elif ch == in_q:
                in_q = 0
            continue
        if ch == 34 or ch == 39:
            in_q = ch
            continue
        if ch == 40 or ch == 91 or ch == 123:
            depth += 1
            continue
        if (ch == 41 or ch == 93 or ch == 125) and depth > 0:
            depth -= 1
            continue
        if depth == 0:
            if ch == 43 or ch == 42 or ch == 47 or ch == 37 or ch == 60 or ch == 62 or ch == 61 or ch == 38 or ch == 124 or ch == 94 or ch == 32:
                return True
            if ch == 45 and i > 0:
                return True
    return False


def _replace_ident_tokens(text: String, names: List[String], values: List[String]) -> String:
    """Substitute identifier tokens matching `names[k]` with `values[k]` outside strings & `.attr`."""
    var cps = decode(text)
    var n = len(cps)
    var out = String("")
    var i = 0
    var in_q = 0
    var esc = False
    while i < n:
        var ch = cps[i]
        if in_q != 0:
            out += chr(ch)
            if esc:
                esc = False
            elif ch == 92:
                esc = True
            elif ch == in_q:
                in_q = 0
            i += 1
            continue
        if ch == 34 or ch == 39:
            in_q = ch
            out += chr(ch)
            i += 1
            continue
        if is_alpha(ch):
            var prev_dot = i > 0 and cps[i - 1] == 46
            var j = i + 1
            while j < n and is_ident(cps[j]):
                j += 1
            var word = slice_str(cps, i, j)
            var matched = -1
            if not prev_dot:
                for k in range(len(names)):
                    if names[k] == word:
                        matched = k
                        break
            if matched >= 0:
                var repl = values[matched]
                var adj_op = (i > 0 and cps[i - 1] != 40 and cps[i - 1] != 44 and cps[i - 1] != 61) or (j < n and cps[j] != 41 and cps[j] != 44)
                if adj_op and _needs_expr_parens(repl):
                    out += "(" + repl + ")"
                else:
                    out += repl
            else:
                out += word
            i = j
            continue
        out += chr(ch)
        i += 1
    return out^


def swap_call_arguments_edits(
    buf: TextBuffer, row: Int, col: Int, right: Bool = True
) -> Tuple[String, List[LspEdit]]:
    """Swap the call argument at `(row, col)` with its adjacent neighbor."""
    var edits = List[LspEdit]()
    var call = find_enclosing_call(buf, row, col)
    if not call.ok or len(call.arg_spans) < 2:
        return ("Place cursor inside a call expression with at least 2 arguments", edits^)
    var n_args = len(call.arg_spans)
    var cur_idx = 0
    for k in range(n_args):
        var sp = call.arg_spans[k].copy()
        if (row > sp.r1 or (row == sp.r1 and col >= sp.c1)) and (row < sp.r2 or (row == sp.r2 and col <= sp.c2)):
            cur_idx = k
            break
        if row > sp.r2 or (row == sp.r2 and col > sp.c2):
            cur_idx = min(k + 1, n_args - 1)
    var idx_a = cur_idx
    var idx_b = cur_idx + 1 if right else cur_idx - 1
    if idx_b >= n_args:
        idx_a = n_args - 2
        idx_b = n_args - 1
    elif idx_b < 0:
        idx_a = 0
        idx_b = 1
    if idx_a > idx_b:
        var tmp = idx_a
        idx_a = idx_b
        idx_b = tmp
    edits.append(_span_to_lsp_edit(buf, call.arg_spans[idx_a], call.arg_texts[idx_b]))
    edits.append(_span_to_lsp_edit(buf, call.arg_spans[idx_b], call.arg_texts[idx_a]))
    return ("", edits^)


def enclosing_def_signature_info(buf: TextBuffer, row: Int) -> Tuple[String, Int, String]:
    """Return `(fn_name, def_header_row, non_self_or_full_params_spec)` for the `def` enclosing `row`."""
    var cst = parse_mojo_cst(buf)
    var best_idx = -1
    for i in range(len(cst.defs)):
        var d = cst.defs[i].copy()
        if d.header_span.r1 <= row and row <= d.body_span.r2:
            best_idx = i
    if best_idx < 0:
        return ("", -1, "")
    var d = cst.defs[best_idx].copy()
    var parts = List[String]()
    for p in d.params:
        parts.append(format_cst_param(p))
    return (d.name, d.header_span.r1, ", ".join(parts))


def _rewrite_calls_for_sig(
    buf: TextBuffer,
    fn_name: String,
    old_non_self: List[CstParam],
    new_non_self: List[CstParam],
) -> List[LspEdit]:
    var out = List[LspEdit]()
    var calls = find_all_calls_to(buf, fn_name)
    for ci in range(len(calls)):
        var call = calls[ci].copy()
        # Map old param name -> provided argument expression at this call site
        var old_vals = List[String]()
        for op in old_non_self:
            old_vals.append(op.default_expr)
        var pos_i = 0
        for ai in range(len(call.arg_texts)):
            var kw = call.arg_kw_names[ai]
            var raw_arg = call.arg_texts[ai]
            if kw.byte_length() > 0:
                var eq = raw_arg.find("=")
                var val_only = String(raw_arg[byte=eq + 1:].strip()) if eq >= 0 else raw_arg
                for oi in range(len(old_non_self)):
                    if old_non_self[oi].name == kw:
                        old_vals[oi] = val_only
                        break
            else:
                if pos_i < len(old_vals):
                    old_vals[pos_i] = raw_arg
                    pos_i += 1
        var new_args = List[String]()
        for np in new_non_self:
            var mapped = String("")
            for oi in range(len(old_non_self)):
                if old_non_self[oi].name == np.name:
                    mapped = old_vals[oi]
                    break
            if mapped.byte_length() == 0:
                mapped = np.default_expr if np.default_expr.byte_length() > 0 else String("0")
            new_args.append(mapped)
        var inner_span = CstSpan(call.open_r, call.open_c + 1, call.close_r, call.close_c)
        out.append(_span_to_lsp_edit(buf, inner_span, ", ".join(new_args)))
    return out^


def change_function_signature_edits(
    target_path: String,
    target_buf: TextBuffer,
    def_row: Int,
    new_params_spec: String,
    extra_paths: List[String],
    extra_bufs: List[TextBuffer],
) -> Tuple[String, List[String], List[List[LspEdit]]]:
    """Rewrite a `def` parameter signature and update all matching call sites across project files."""
    var res_paths = List[String]()
    var res_edits = List[List[LspEdit]]()
    var cst = parse_mojo_cst(target_buf)
    var best_idx = -1
    for i in range(len(cst.defs)):
        if cst.defs[i].header_span.r1 <= def_row and def_row <= cst.defs[i].body_span.r2:
            best_idx = i
    if best_idx < 0:
        return ("Place cursor inside a `def` function or method to change its signature", res_paths^, res_edits^)
    var d = cst.defs[best_idx].copy()
    var raw_parts = _split_top_level_commas(new_params_spec)
    var parsed_new = List[CstParam]()
    var has_new_self = False
    for rp in raw_parts:
        if String(rp.strip()).byte_length() == 0:
            continue
        var cp = parse_cst_param(rp)
        if cp.is_self:
            has_new_self = True
        parsed_new.append(cp^)
    if len(d.params) > 0 and d.params[0].is_self and not has_new_self:
        parsed_new.insert(0, d.params[0].copy())

    var old_non_self = List[CstParam]()
    for op in d.params:
        if not op.is_self:
            old_non_self.append(op.copy())
    var new_non_self = List[CstParam]()
    var formatted_params = List[String]()
    for np in parsed_new:
        formatted_params.append(format_cst_param(np))
        if not np.is_self:
            new_non_self.append(np.copy())

    var self_edits = List[LspEdit]()
    self_edits.append(_span_to_lsp_edit(target_buf, d.params_span, ", ".join(formatted_params)))
    for ce in _rewrite_calls_for_sig(target_buf, d.name, old_non_self, new_non_self):
        # Skip overlap if any call span were inside header (impossible for normal calls)
        if ce.r1 > d.header_span.r2 or ce.r2 < d.header_span.r1:
            self_edits.append(ce.copy())
    res_paths.append(target_path)
    res_edits.append(self_edits^)

    for k in range(min(len(extra_paths), len(extra_bufs))):
        if extra_paths[k] == target_path:
            continue
        var f_edits = _rewrite_calls_for_sig(extra_bufs[k], d.name, old_non_self, new_non_self)
        if len(f_edits) > 0:
            res_paths.append(extra_paths[k])
            res_edits.append(f_edits^)
    return ("", res_paths^, res_edits^)


def inline_symbol_edits(buf: TextBuffer, row: Int, col: Int) -> Tuple[String, List[LspEdit]]:
    """Inline either a local `var name = expr` binding or a single-`return` helper function call."""
    var edits = List[LspEdit]()
    var nlines = buf.count()
    if row < 0 or row >= nlines:
        return ("Invalid cursor line", edits^)
    var cst = parse_mojo_cst(buf)

    # 1. Check if cursor is on a call site `fn(args)` of a single-return helper in `cst.defs`
    var call = find_enclosing_call(buf, row, col)
    if call.ok and call.callee.find(".") < 0:
        for di in range(len(cst.defs)):
            var d = cst.defs[di].copy()
            if d.name == call.callee and (len(d.params) == 0 or not d.params[0].is_self):
                var ret_expr = String("")
                var stmt_count = 0
                for r in range(d.header_span.r2 + 1, min(nlines, d.body_span.r2 + 1)):
                    var st = String(to_str(buf.line(r)).strip())
                    if st.byte_length() == 0 or st.startswith("#") or st.startswith('"""'):
                        continue
                    stmt_count += 1
                    if st.startswith("return "):
                        ret_expr = String(st[byte=7:].strip())
                if stmt_count == 1 and ret_expr.byte_length() > 0:
                    var pnames = List[String]()
                    var pvals = List[String]()
                    for pi in range(len(d.params)):
                        pnames.append(d.params[pi].name)
                        if pi < len(call.arg_texts):
                            var raw_a = call.arg_texts[pi]
                            if call.arg_kw_names[pi].byte_length() > 0:
                                var eq = raw_a.find("=")
                                if eq >= 0:
                                    var v_only = String(raw_a[byte=eq + 1:].strip())
                                    raw_a = v_only
                            pvals.append(raw_a)
                        else:
                            pvals.append(d.params[pi].default_expr)
                    var inlined = _replace_ident_tokens(ret_expr, pnames, pvals)
                    edits.append(_span_to_lsp_edit(buf, call.span, inlined))
                    return ("", edits^)

    # 2. Inline Variable: identify identifier under cursor (or `var x = ...` on `row`)
    var hl = Highlighter()
    var lines_cps = List[List[Int]]()
    var lines_cls = List[List[Int]]()
    var st = 0
    for r in range(nlines):
        var cps = buf.line(r)
        var cls = List[Int]()
        st = hl.line(cps, st, cls, HL_MOJO)
        lines_cps.append(cps^)
        lines_cls.append(cls^)

    var scope_start = 0
    var scope_end = nlines - 1
    for di in range(len(cst.defs)):
        if cst.defs[di].header_span.r1 <= row and row <= cst.defs[di].body_span.r2:
            scope_start = cst.defs[di].header_span.r2 + 1
            scope_end = min(nlines - 1, cst.defs[di].body_span.r2)

    var target_var = String("")
    var cur_ln = lines_cps[row].copy()
    var cc = min(col, len(cur_ln))
    var a = cc
    var b = cc
    while a > 0 and is_ident(cur_ln[a - 1]):
        a -= 1
    while b < len(cur_ln) and is_ident(cur_ln[b]):
        b += 1
    if a < b:
        var cand = slice_str(cur_ln, a, b)
        if cand != "var" and cand != "let" and is_valid_ident(cand):
            target_var = cand
    if target_var.byte_length() == 0:
        var fc0 = _first_code_col(cur_ln, lines_cls[row])
        if fc0 >= 0:
            var code0 = slice_str(cur_ln, fc0, _code_end_col(cur_ln, lines_cls[row]))
            if code0.startswith("var ") or code0.startswith("let "):
                var rest0 = String(code0[byte=4:].lstrip())
                var rc0 = decode(rest0)
                var j0 = 0
                while j0 < len(rc0) and is_ident(rc0[j0]):
                    j0 += 1
                if j0 > 0:
                    target_var = slice_str(rc0, 0, j0)
    if target_var.byte_length() == 0:
        return ("Place cursor on a local variable or single-return function call to inline", edits^)

    var decl_row = -1
    var rhs_expr = String("")
    for r in range(scope_start, scope_end + 1):
        var fc = _first_code_col(lines_cps[r], lines_cls[r])
        if fc < 0:
            continue
        var code = slice_str(lines_cps[r], fc, _code_end_col(lines_cps[r], lines_cls[r]))
        if code.startswith("var ") or code.startswith("let "):
            var rest = String(code[byte=4:].lstrip())
            var rc = decode(rest)
            var j = 0
            while j < len(rc) and is_ident(rc[j]):
                j += 1
            if j > 0 and slice_str(rc, 0, j) == target_var:
                var eq = rest.find("=")
                if eq > 0:
                    decl_row = r
                    rhs_expr = String(rest[byte=eq + 1:].strip())
                    break
    if decl_row < 0 or rhs_expr.byte_length() == 0:
        return ("Could not find single-line `var " + target_var + " = ...` initializer in scope", edits^)

    # Ensure `target_var` is not mutated after `decl_row`
    for r in range(decl_row + 1, scope_end + 1):
        var fc = _first_code_col(lines_cps[r], lines_cls[r])
        if fc < 0:
            continue
        var code = String(slice_str(lines_cps[r], fc, _code_end_col(lines_cps[r], lines_cls[r])).strip())
        if code.startswith(target_var):
            var tail = String(code[byte=target_var.byte_length():].lstrip())
            if (tail.startswith("=") and not tail.startswith("==")) or tail.startswith("+=") or tail.startswith("-=") or tail.startswith("*=") or tail.startswith("/="):
                return ("Cannot inline '" + target_var + "' because it is reassigned later", edits^)

    # Delete `decl_row` line
    if decl_row + 1 < nlines:
        edits.append(LspEdit(decl_row, 0, decl_row + 1, 0, ""))
    else:
        edits.append(LspEdit(decl_row, 0, decl_row, col_to_utf16(lines_cps[decl_row], len(lines_cps[decl_row])), ""))

    var names = List[String]()
    names.append(target_var)
    var vals = List[String]()
    vals.append(rhs_expr)
    var uses = 0
    for r in range(decl_row + 1, scope_end + 1):
        var cps = lines_cps[r].copy()
        var cls = lines_cls[r].copy()
        var i = 0
        while i < len(cps):
            if _is_code_at(cls, i) and is_alpha(cps[i]):
                var prev_dot = i > 0 and cps[i - 1] == 46
                var j = i + 1
                while j < len(cps) and is_ident(cps[j]):
                    j += 1
                if not prev_dot and slice_str(cps, i, j) == target_var:
                    var adj_op = (i > 0 and cps[i - 1] != 40 and cps[i - 1] != 44 and cps[i - 1] != 61 and cps[i - 1] != 32) or True
                    var prev_non_ws = -1
                    var p = i - 1
                    while p >= 0 and (cps[p] == 32 or cps[p] == 9):
                        p -= 1
                    if p >= 0:
                        prev_non_ws = cps[p]
                    var next_non_ws = -1
                    var q = j
                    while q < len(cps) and (cps[q] == 32 or cps[q] == 9):
                        q += 1
                    if q < len(cps) and _is_code_at(cls, q):
                        next_non_ws = cps[q]
                    var bare_ok = (prev_non_ws == 40 or prev_non_ws == 44 or prev_non_ws == 61 or prev_non_ws == 91 or prev_non_ws < 0) and (next_non_ws == 41 or next_non_ws == 44 or next_non_ws == 93 or next_non_ws < 0)
                    # Note: `return <expr>` has `prev_non_ws == 110 ('n')` and `next_non_ws < 0`: Check `return ` too!
                    var prefix_str = String(slice_str(cps, 0, i).strip())
                    if prefix_str == "return":
                        bare_ok = next_non_ws < 0
                    _ = adj_op
                    var repl = ("(" + rhs_expr + ")") if (_needs_expr_parens(rhs_expr) and not bare_ok) else rhs_expr
                    edits.append(LspEdit(r, col_to_utf16(cps, i), r, col_to_utf16(cps, j), repl))
                    uses += 1
                i = j
                continue
            i += 1
    if uses == 0:
        return ("No references to '" + target_var + "' found below its declaration", List[LspEdit]())
    return ("", edits^)


def _struct_has_method(s: CstStructNode, mname: String) -> Bool:
    for m in s.methods:
        if m.name == mname:
            return True
    return False


def generate_trait_stubs_edits(buf: TextBuffer, row: Int) -> Tuple[String, String, List[LspEdit]]:
    """Synthesize missing Mojo 1.2 trait/boilerplate methods (`Writable`, `Equatable`, `Hashable`,
    `Copyable`, and custom `trait` declarations in the buffer) on the enclosing `struct`."""
    var edits = List[LspEdit]()
    var cst = parse_mojo_cst(buf)
    var si = -1
    for i in range(len(cst.structs)):
        if cst.structs[i].header_span.r1 <= row and row <= cst.structs[i].body_span.r2:
            si = i
    if si < 0:
        return ("Place cursor inside a `struct` to generate trait & boilerplate stubs", "", edits^)
    var s = cst.structs[si].copy()
    var pad = String("")
    for _ in range(s.indent + 4):
        pad += " "
    var pad2 = pad + "    "

    var blocks = List[String]()
    var generated_names = List[String]()
    var want_writable = ("Writable" in s.traits) or (len(s.traits) == 0 and not _struct_has_method(s, "write_to"))
    if want_writable and not _struct_has_method(s, "write_to"):
        var wlines = List[String]()
        wlines.append(pad + "def write_to(self, mut writer: Some[Writer]):")
        if len(s.fields) == 0:
            wlines.append(pad2 + 'writer.write("' + s.name + '()")')
        else:
            var args = List[String]()
            args.append('"' + s.name + '("')
            for fi in range(len(s.fields)):
                var prefix = (", " if fi > 0 else "") + s.fields[fi].name + "="
                args.append('"' + prefix + '"')
                args.append("self." + s.fields[fi].name)
            args.append('")"')
            wlines.append(pad2 + "writer.write(" + ", ".join(args) + ")")
        blocks.append("\n".join(wlines))
        generated_names.append("write_to")

    if ("Equatable" in s.traits) and not _struct_has_method(s, "__eq__"):
        var elines = List[String]()
        elines.append(pad + "def __eq__(self, other: Self) -> Bool:")
        if len(s.fields) == 0:
            elines.append(pad2 + "return True")
        else:
            var cmps = List[String]()
            for f in s.fields:
                cmps.append("self." + f.name + " == other." + f.name)
            elines.append(pad2 + "return " + " and ".join(cmps))
        blocks.append("\n".join(elines))
        generated_names.append("__eq__")

    if ("Hashable" in s.traits) and not _struct_has_method(s, "__hash__"):
        var hlines = List[String]()
        hlines.append(pad + "def __hash__[H: Hasher](self, mut hasher: H):")
        if len(s.fields) == 0:
            hlines.append(pad2 + "pass")
        else:
            for f in s.fields:
                hlines.append(pad2 + "hasher.update(self." + f.name + ")")
        blocks.append("\n".join(hlines))
        generated_names.append("__hash__")

    if ("Copyable" in s.traits) and not _struct_has_method(s, "__init__") and s.deco_start_row == s.header_span.r1:
        var clines = List[String]()
        clines.append(pad + "def __init__(out self, *, copy: Self):")
        if len(s.fields) == 0:
            clines.append(pad2 + "pass")
        else:
            for f in s.fields:
                clines.append(pad2 + "self." + f.name + " = copy." + f.name)
        blocks.append("\n".join(clines))
        generated_names.append("__init__(copy)")

    # Custom traits defined in this buffer
    for tr_name in s.traits:
        for ti in range(len(cst.traits)):
            if cst.traits[ti].name == tr_name:
                for tm in cst.traits[ti].methods:
                    if not _struct_has_method(s, tm.name) and not (tm.name in generated_names):
                        var p_strs = List[String]()
                        for p in tm.params:
                            p_strs.append(format_cst_param(p))
                        var cp_part = String("")
                        if len(tm.comptime_params) > 0:
                            var cps_l = List[String]()
                            for cp in tm.comptime_params:
                                cps_l.append(format_cst_param(cp))
                            cp_part = "[" + ", ".join(cps_l) + "]"
                        var hdr = pad + "def " + tm.name + cp_part + "(" + ", ".join(p_strs) + ")"
                        if tm.is_raises:
                            hdr += " raises"
                        if tm.return_type.byte_length() > 0:
                            hdr += " -> " + tm.return_type
                        hdr += ":"
                        var body_line = pad2 + ('raise Error("not implemented: ' + s.name + "." + tm.name + '")' if tm.is_raises else "pass")
                        blocks.append(hdr + "\n" + body_line)
                        generated_names.append(tm.name)

    if len(blocks) == 0:
        return ("All declared trait methods already exist on struct '" + s.name + "'", "", edits^)

    var end_r = min(buf.count() - 1, s.body_span.r2)
    var end_u16 = col_to_utf16(buf.line(end_r), len(buf.line(end_r)))
    var prefix_nl = "\n\n" if String(to_str(buf.line(end_r)).strip()).byte_length() > 0 else "\n"
    edits.append(LspEdit(end_r, end_u16, end_r, end_u16, prefix_nl + "\n\n".join(blocks)))
    var title = "Implement missing stubs on " + s.name + " (" + ", ".join(generated_names) + ")"
    return ("", title, edits^)
