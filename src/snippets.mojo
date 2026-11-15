"""Mojo 1.2 tab-stop snippet engine and IDE-synthesized quick-fix rules.

Provides LSP-compatible snippet expansion with numbered tabstops ($1, $2, ..., $0 and
${1:placeholder} defaults) plus built-in Mojo 1.2 code templates and diagnostic-aware
quick fixes for removed syntax, argument conventions, missing `var`, missing `raises`,
and explicit `.copy()` / `^` ownership transfers."""
from std.collections import List
from buffer import TextBuffer, Pos
from util import decode, to_str, is_ident, is_alpha, lower_str, slice_str, path_exists, read_file, bytes_to_str, stem
from toml import toml_parse
from json import json_parse, J_OBJ, J_STR, J_ARR


@fieldwise_init
struct SnippetStop(Copyable, Movable):
    """A numbered tabstop span [start, end) in codepoint offsets from insertion origin."""
    var num: Int
    var start: Int
    var end: Int


struct SnippetExpansion(Copyable, Movable):
    var text: String
    var stops: List[SnippetStop]

    def __init__(out self):
        self.text = ""
        self.stops = List[SnippetStop]()


@fieldwise_init
struct SnippetTemplate(Copyable, Movable):
    var trigger: String
    var label: String
    var detail: String
    var body: String
    var doc: String


@fieldwise_init
struct QuickFixEdit(Copyable, Movable):
    var title: String
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int
    var new_text: String
    var preferred: Bool


def pos_after_offset(base_row: Int, base_col: Int, cps: List[Int], off: Int) -> Pos:
    """Buffer (row, col) reached by advancing `off` codepoints through `cps` from `(base_row, base_col)`."""
    var r = base_row
    var c = base_col
    var limit = min(max(0, off), len(cps))
    for i in range(limit):
        if cps[i] == 10:
            r += 1
            c = 0
        else:
            c += 1
    return Pos(r, c)


def stop_rank(num: Int) -> Int:
    """Sort rank for snippet tabstops: 1, 2, ... come first; 0 ($0 final position) comes last."""
    return 1000000 if num == 0 else num


def expand_snippet_full(raw: String, line_indent: String = "") -> SnippetExpansion:
    """Expand an LSP / built-in snippet body into plain text and ordered tabstop spans."""
    var cps = decode(raw)
    var ind_cps = decode(line_indent)
    var out = List[Int]()
    var raw_stops = List[SnippetStop]()
    var n = len(cps)
    var i = 0
    while i < n:
        var c = cps[i]
        if c == 10:
            out.append(10)
            for ic in ind_cps:
                out.append(ic)
            i += 1
            continue
        if c == 92 and i + 1 < n:
            out.append(cps[i + 1])
            i += 2
            continue
        if c == 36 and i + 1 < n:
            if cps[i + 1] == 36:
                out.append(36)
                i += 2
                continue
            if cps[i + 1] >= 48 and cps[i + 1] <= 57:
                var j = i + 1
                var num = 0
                while j < n and cps[j] >= 48 and cps[j] <= 57:
                    num = num * 10 + (cps[j] - 48)
                    j += 1
                var pos = len(out)
                raw_stops.append(SnippetStop(num, pos, pos))
                i = j
                continue
            if cps[i + 1] == 123:
                var j = i + 2
                var num = -1
                if j < n and cps[j] >= 48 and cps[j] <= 57:
                    num = 0
                    while j < n and cps[j] >= 48 and cps[j] <= 57:
                        num = num * 10 + (cps[j] - 48)
                        j += 1
                var st = len(out)
                if j < n and cps[j] == 124:
                    j += 1
                    var choice_first = List[Int]()
                    while j < n and cps[j] != 124 and cps[j] != 44 and cps[j] != 125:
                        if cps[j] == 92 and j + 1 < n:
                            choice_first.append(cps[j + 1])
                            j += 2
                            continue
                        choice_first.append(cps[j])
                        j += 1
                    while j < n and not (cps[j] == 124 and j + 1 < n and cps[j + 1] == 125) and cps[j] != 125:
                        if cps[j] == 92 and j + 1 < n:
                            j += 2
                            continue
                        j += 1
                    if j + 1 < n and cps[j] == 124 and cps[j + 1] == 125:
                        j += 2
                    elif j < n and cps[j] == 125:
                        j += 1
                    for ch in choice_first:
                        out.append(ch)
                    if num >= 0:
                        raw_stops.append(SnippetStop(num, st, len(out)))
                    i = j
                    continue
                if j < n and cps[j] == 58:
                    j += 1
                    var depth = 1
                    while j < n and depth > 0:
                        if cps[j] == 92 and j + 1 < n:
                            out.append(cps[j + 1])
                            j += 2
                            continue
                        if cps[j] == 123:
                            depth += 1
                        elif cps[j] == 125:
                            depth -= 1
                            if depth == 0:
                                j += 1
                                break
                        out.append(cps[j])
                        j += 1
                    if num >= 0:
                        raw_stops.append(SnippetStop(num, st, len(out)))
                    i = j
                    continue
                while j < n and cps[j] != 125:
                    j += 1
                if j < n and cps[j] == 125:
                    j += 1
                if num >= 0:
                    raw_stops.append(SnippetStop(num, st, st))
                i = j
                continue
        out.append(c)
        i += 1

    # Retain all tabstops (including mirrored $N occurrences), ordered by rank
    var ordered = List[SnippetStop]()
    for s in raw_stops:
        var at = len(ordered)
        for k in range(len(ordered)):
            if stop_rank(s.num) < stop_rank(ordered[k].num):
                at = k
                break
        ordered.insert(at, s.copy())

    var res = SnippetExpansion()
    res.text = to_str(out)
    res.stops = ordered^
    return res^


def mojo_snippets() -> List[SnippetTemplate]:
    """Built-in Mojo 1.2 code templates offered in completion on .mojo / .🔥 buffers."""
    var out = List[SnippetTemplate]()
    out.append(SnippetTemplate(
        "struct",
        "struct (snippet)",
        "@fieldwise_init struct",
        "@fieldwise_init\nstruct ${1:Name}(Copyable, Movable):\n    var ${2:field}: ${3:Int}$0",
        "Mojo 1.2 struct with `@fieldwise_init` and explicit `Copyable, Movable` conformance.",
    ))
    out.append(SnippetTemplate(
        "def",
        "def (snippet)",
        "def name(...) -> T:",
        "def ${1:name}(${2:x: Int}) -> ${3:Int}:\n    ${0:...}",
        "Mojo 1.2 function definition (`def` replaces the removed `fn` keyword).",
    ))
    out.append(SnippetTemplate(
        "main",
        "main (snippet)",
        "def main() raises:",
        "def main() raises:\n    ${0:pass}",
        "Mojo 1.2 program entry point marked `raises`.",
    ))
    out.append(SnippetTemplate(
        "test",
        "test (snippet)",
        "std.testing TestSuite",
        "from std.testing import assert_equal, assert_true, TestSuite\n\n\ndef test_${1:case}() raises:\n    ${0:assert_true(True)}\n\n\ndef main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run()",
        "Mojo 1.2 unit test scaffold using `std.testing.TestSuite.discover_tests`.",
    ))
    out.append(SnippetTemplate(
        "gpu",
        "gpu (snippet)",
        "MAX GPU kernel + DeviceContext",
        "from max.gpu import global_idx\nfrom max.gpu.host import DeviceContext\n\n\ndef ${1:kernel}(out_ptr: MutPointer[Float32, MutAnyOrigin], n: Int):\n    var tid = global_idx.x\n    if tid < n:\n        ${0:out_ptr[tid] = Float32(tid)}",
        "Mojo 1.2 GPU kernel using `max.gpu.global_idx` and `MutPointer`.",
    ))
    out.append(SnippetTemplate(
        "pymod",
        "pymod (snippet)",
        "PyInit Python extension module",
        "from std.python import PythonObject\nfrom std.python.bindings import PythonModuleBuilder\nfrom std.os import abort\n\n\n@export\ndef PyInit_${1:mymodule}() abi(\"C\") -> PythonObject:\n    try:\n        var m = PythonModuleBuilder(\"${1:mymodule}\")\n        $0\n        return m.finalize()\n    except e:\n        abort(String(\"error creating module: \", e))",
        "Mojo 1.2 CPython extension entry point (`@export def PyInit_<name>() abi(\"C\")`).",
    ))
    out.append(SnippetTemplate(
        "trait",
        "trait (snippet)",
        "trait Name:",
        "trait ${1:Name}:\n    def ${2:method}(self) -> ${3:None}:\n        ...",
        "Mojo 1.2 trait declaration.",
    ))
    out.append(SnippetTemplate(
        "comptime",
        "comptime (snippet)",
        "comptime NAME = ...",
        "comptime ${1:NAME} = ${0:0}",
        "Mojo 1.2 compile-time constant (`comptime` replaces `alias`).",
    ))
    out.append(SnippetTemplate(
        "writable",
        "writable (snippet)",
        "def write_to(self, mut writer: Some[Writer]):",
        "def write_to(self, mut writer: Some[Writer]):\n    writer.write(${0:self.value})",
        "Mojo 1.2 `Writable` formatting method (`write_to` replaces `__str__`).",
    ))
    out.append(SnippetTemplate(
        "bench",
        "bench (snippet)",
        "std.benchmark Bencher",
        "from std.benchmark import run, Bencher, BenchmarkConfig\n\n\ndef bench_${1:name}(mut b: Bencher) raises:\n    ${0:pass}\n\n\ndef main() raises:\n    var report = run[bench_${1:name}](BenchmarkConfig())\n    report.print()",
        "Mojo 1.2 microbenchmark scaffold using `std.benchmark.run` and `Bencher`.",
    ))
    return out^


def find_kw_token(cps: List[Int], kw: String) -> Int:
    """First whole-identifier occurrence of `kw` in `cps`, or -1."""
    var kc = decode(kw)
    var n = len(cps)
    var m = len(kc)
    if m == 0 or n < m:
        return -1
    var in_str = 0
    for i in range(n - m + 1):
        var c = cps[i]
        if c == 35 and in_str == 0:
            break
        if (c == 34 or c == 39) and (i == 0 or cps[i - 1] != 92):
            if in_str == 0:
                in_str = c
            elif in_str == c:
                in_str = 0
        if in_str != 0:
            continue
        if i > 0 and is_ident(cps[i - 1]):
            continue
        if i + m < n and is_ident(cps[i + m]):
            continue
        var ok = True
        for k in range(m):
            if cps[i + k] != kc[k]:
                ok = False
                break
        if ok:
            return i
    return -1


def find_enclosing_def_row(buf: TextBuffer, cr: Int) -> Int:
    """Row of the `def ...` header enclosing `cr`, or -1."""
    var cur_cps = buf.line(cr)
    var cur_ind = 0
    while cur_ind < len(cur_cps) and (cur_cps[cur_ind] == 32 or cur_cps[cur_ind] == 9):
        cur_ind += 1
    var r = cr
    while r >= 0 and cr - r <= 300:
        var ln = buf.line(r)
        var ind = 0
        while ind < len(ln) and (ln[ind] == 32 or ln[ind] == 9):
            ind += 1
        var rest = slice_str(ln, ind, len(ln))
        if (rest.startswith("def ") or rest.startswith("fn ")) and (r == cr or ind < cur_ind or cur_ind == 0):
            return r
        r -= 1
    return -1


def def_declares_ident(buf: TextBuffer, def_row: Int, upto_row: Int, ident: String) -> Bool:
    """Whether `ident` is already declared via parameter or `var` between `def_row` and `upto_row`."""
    var start = max(0, def_row)
    for r in range(start, upto_row):
        var s = to_str(buf.line(r))
        if r == def_row and (s.find("(" + ident + ":") >= 0 or s.find(" " + ident + ":") >= 0 or s.find("," + ident + ":") >= 0 or s.find(" " + ident + " ") >= 0):
            return True
        var trimmed = String(s.lstrip())
        if trimmed.startswith("var " + ident + " ") or trimmed.startswith("var " + ident + ":") or trimmed.startswith("var " + ident + "="):
            return True
        if trimmed.startswith("for " + ident + " in "):
            return True
    return False


def synthesize_mojo_quickfixes(
    buf: TextBuffer,
    cr: Int,
    cc: Int,
    diag_msgs: List[String],
    diag_c1: List[Int],
    diag_c2: List[Int],
) -> List[QuickFixEdit]:
    """Synthesize Mojo 1.2 quick fixes for line `cr` from syntax patterns and diagnostics."""
    var out = List[QuickFixEdit]()
    if cr < 0 or cr >= buf.count():
        return out^
    var raw_cps = buf.line(cr)
    var n = len(raw_cps)
    var raw = to_str(raw_cps)
    var ind = 0
    while ind < n and (raw_cps[ind] == 32 or raw_cps[ind] == 9):
        ind += 1
    var prefix = slice_str(raw_cps, 0, ind)
    var rest = slice_str(raw_cps, ind, n)

    # 1. Stdlib & MAX GPU module import prefixing
    var std_mods = [
        "collections", "testing", "memory", "sys", "os", "math", "algorithm",
        "time", "utils", "random", "pathlib", "tempfile", "ffi", "io", "hashlib",
        "logger", "subprocess", "complex", "bit", "benchmark", "compile",
        "python", "atomic", "iter", "base64",
    ]
    if rest.startswith("from ") or rest.startswith("import "):
        var is_from = rest.startswith("from ")
        var after_kw = String(rest[byte=5:] if is_from else rest[byte=7:])
        var trimmed_after = String(after_kw.lstrip())
        var mod_end = trimmed_after.byte_length()
        for k in range(trimmed_after.byte_length()):
            var b = Int(trimmed_after.as_bytes()[k])
            if b == 46 or b == 32 or b == 44 or b == 9:
                mod_end = k
                break
        var mod = String(trimmed_after[byte=0:mod_end])
        var is_std = False
        for m in std_mods:
            if mod == String(m):
                is_std = True
                break
        if is_std:
            var kw = String("from std.") if is_from else String("import std.")
            out.append(QuickFixEdit("Prefix stdlib module with 'std.' (" + kw + mod + ")", cr, 0, cr, n, prefix + kw + trimmed_after, True))
        elif mod == "gpu":
            var kw_max = String("from max.") if is_from else String("import max.")
            out.append(QuickFixEdit("Import GPU module from MAX (" + kw_max + mod + ")", cr, 0, cr, n, prefix + kw_max + trimmed_after, True))

    # 2. Removed Mojo keywords & decorators
    if rest.startswith("fn "):
        out.append(QuickFixEdit("Replace removed 'fn' with 'def' (Mojo 1.2)", cr, 0, cr, n, prefix + "def " + String(rest[byte=3:]), True))
    elif rest.startswith("alias "):
        out.append(QuickFixEdit("Replace removed 'alias' with 'comptime' (Mojo 1.2)", cr, 0, cr, n, prefix + "comptime " + String(rest[byte=6:]), True))
    elif rest.startswith("let "):
        out.append(QuickFixEdit("Replace removed 'let' with 'var' (Mojo 1.2)", cr, 0, cr, n, prefix + "var " + String(rest[byte=4:]), True))
    elif rest == "@value" or rest.startswith("@value "):
        out.append(QuickFixEdit("Replace removed '@value' with '@fieldwise_init' (Mojo 1.2)", cr, 0, cr, n, prefix + "@fieldwise_init" + String(rest[byte=6:]), True))
    elif rest.startswith("@parameter if ") or rest.startswith("@parameter for "):
        out.append(QuickFixEdit("Replace removed '@parameter' with 'comptime' (Mojo 1.2)", cr, 0, cr, n, prefix + "comptime " + String(rest[byte=11:]), True))

    # 3. Removed argument conventions (`inout self` in __init__ -> `out self`, `inout` -> `mut`, `owned` -> `var`, `borrowed` -> drop)
    var io_at = find_kw_token(raw_cps, "inout")
    if io_at >= 0:
        var after_io = slice_str(raw_cps, io_at + 5, n)
        if rest.find("__init__") >= 0 and String(after_io.lstrip()).startswith("self"):
            out.append(QuickFixEdit("Replace 'inout self' in __init__ with 'out self' (Mojo 1.2)", cr, io_at, cr, io_at + 5, "out", True))
        else:
            out.append(QuickFixEdit("Replace removed 'inout' convention with 'mut' (Mojo 1.2)", cr, io_at, cr, io_at + 5, "mut", True))
    var ow_at = find_kw_token(raw_cps, "owned")
    if ow_at >= 0:
        out.append(QuickFixEdit("Replace removed 'owned' convention with 'var' (Mojo 1.2)", cr, ow_at, cr, ow_at + 5, "var", True))
    var bo_at = find_kw_token(raw_cps, "borrowed")
    if bo_at >= 0:
        var end_bo = bo_at + 8
        if end_bo < n and raw_cps[end_bo] == 32:
            end_bo += 1
        out.append(QuickFixEdit("Remove obsolete 'borrowed' convention (imm is default in Mojo 1.2)", cr, bo_at, cr, end_bo, "", True))

    # Combine lower-cased diagnostic messages on this line
    var all_diag = String("")
    for m in diag_msgs:
        all_diag += " " + lower_str(m)

    # 4. Missing `var` on bare variable declaration (`x = expr` where `x` is undeclared)
    var id_end = ind
    if id_end < n and is_alpha(raw_cps[id_end]):
        while id_end < n and is_ident(raw_cps[id_end]):
            id_end += 1
        var ident = slice_str(raw_cps, ind, id_end)
        var k = id_end
        while k < n and raw_cps[k] == 32:
            k += 1
        var is_bare_assign = k < n and raw_cps[k] == 61 and (k + 1 >= n or raw_cps[k + 1] != 61)
        if not is_bare_assign and k < n and raw_cps[k] == 58:
            # `x: Int = 5` without `var`
            var eq = raw.find("=")
            if eq > 0 and ident != "def" and ident != "if" and ident != "elif" and ident != "while" and ident != "for" and ident != "struct" and ident != "trait":
                is_bare_assign = True
        if is_bare_assign and ident != "self":
            var diag_undecl = all_diag.find("unknown declaration") >= 0 or all_diag.find("undeclared") >= 0 or all_diag.find("use of unknown") >= 0
            var def_r = find_enclosing_def_row(buf, cr)
            if diag_undecl or (def_r >= 0 and not def_declares_ident(buf, def_r, cr, ident)):
                out.append(QuickFixEdit("Declare variable with 'var' (var " + ident + " ...)", cr, ind, cr, ind, "var ", True))

    # 5. Missing `raises` on enclosing `def` header
    var needs_raises = all_diag.find("raises") >= 0 or all_diag.find("error is not handled") >= 0 or all_diag.find("cannot call function that may raise") >= 0 or rest.startswith("raise ")
    if needs_raises:
        var def_r = find_enclosing_def_row(buf, cr)
        if def_r >= 0:
            var def_cps = buf.line(def_r)
            var def_str = to_str(def_cps)
            if find_kw_token(def_cps, "raises") < 0:
                var arrow = def_str.find("->")
                var fn_name = String("def")
                var lp = def_str.find("(")
                var df = def_str.find("def ")
                if df >= 0 and lp > df + 4:
                    fn_name = String(def_str[byte=df + 4:lp].strip())
                if arrow > 0:
                    # Convert byte index of `->` to codepoint col
                    var col_arrow = len(decode(String(def_str[byte=0:arrow])))
                    var ins = String("raises ") if col_arrow > 0 and def_cps[col_arrow - 1] == 32 else String(" raises ")
                    out.append(QuickFixEdit("Add 'raises' to enclosing def '" + fn_name + "'", def_r, col_arrow, def_r, col_arrow, ins, True))
                else:
                    var colon = -1
                    for q in range(len(def_cps) - 1, -1, -1):
                        if def_cps[q] == 35:
                            continue
                        if def_cps[q] == 58:
                            colon = q
                            break
                    if colon > 0:
                        out.append(QuickFixEdit("Add 'raises' to enclosing def '" + fn_name + "'", def_r, colon, def_r, colon, " raises", True))

    # 6. Implicit copy error -> `.copy()` or `^` move transfer
    if all_diag.find("implicitly copied") >= 0 or all_diag.find("implicitlycopyable") >= 0 or all_diag.find("cannot be copied") >= 0:
        var expr_c1 = -1
        var expr_c2 = -1
        for di in range(len(diag_msgs)):
            var dm = lower_str(diag_msgs[di])
            if (dm.find("implicitly copied") >= 0 or dm.find("implicitlycopyable") >= 0) and diag_c2[di] > diag_c1[di] and diag_c2[di] <= n:
                expr_c1 = diag_c1[di]
                expr_c2 = diag_c2[di]
                break
        if expr_c1 < 0:
            # Fallback: identifier at cursor or RHS of `=`
            var a = min(cc, n)
            var b = a
            while a > 0 and (is_ident(raw_cps[a - 1]) or raw_cps[a - 1] == 46):
                a -= 1
            while b < n and (is_ident(raw_cps[b]) or raw_cps[b] == 46):
                b += 1
            if b > a:
                expr_c1 = a
                expr_c2 = b
            else:
                var eq = -1
                for q in range(n):
                    if raw_cps[q] == 61 and (q + 1 >= n or raw_cps[q + 1] != 61):
                        eq = q
                        break
                if eq >= 0:
                    var s1 = eq + 1
                    while s1 < n and raw_cps[s1] == 32:
                        s1 += 1
                    var s2 = n
                    for q in range(s1, n):
                        if raw_cps[q] == 35:
                            s2 = q
                            break
                    while s2 > s1 and raw_cps[s2 - 1] == 32:
                        s2 -= 1
                    if s2 > s1:
                        expr_c1 = s1
                        expr_c2 = s2
        if expr_c2 > expr_c1:
            var expr = slice_str(raw_cps, expr_c1, expr_c2)
            out.append(QuickFixEdit("Explicitly copy '" + expr + "' with .copy() (Mojo 1.2)", cr, expr_c1, cr, expr_c2, expr + ".copy()", True))
            out.append(QuickFixEdit("Transfer ownership of '" + expr + "' with ^ (Mojo 1.2)", cr, expr_c1, cr, expr_c2, expr + "^", False))

    # 7. `len(s)` on UTF-8 String -> `s.byte_length()`
    var len_at = raw.find("len(")
    if len_at >= 0 and (all_diag.find("string") >= 0 or all_diag.find("byte_length") >= 0 or all_diag.find("sized") >= 0 or all_diag.find("'len'") >= 0):
        var c_len = len(decode(String(raw[byte=0:len_at])))
        var depth = 1
        var p = c_len + 4
        while p < n and depth > 0:
            if raw_cps[p] == 40:
                depth += 1
            elif raw_cps[p] == 41:
                depth -= 1
                if depth == 0:
                    break
            p += 1
        if p < n and raw_cps[p] == 41 and p > c_len + 4:
            var inner = slice_str(raw_cps, c_len + 4, p)
            out.append(QuickFixEdit("Replace len(" + inner + ") with " + inner + ".byte_length() (Mojo 1.2 UTF-8)", cr, c_len, cr, p + 1, inner + ".byte_length()", True))

    return out^


def load_toml_snippets(path: String) raises -> List[SnippetTemplate]:
    """Load snippet templates from a TOML configuration file."""
    var out = List[SnippetTemplate]()
    if not path_exists(path):
        return out^
    var raw_bytes = read_file(path)
    if len(raw_bytes) == 0:
        return out^
    var text = bytes_to_str(raw_bytes)
    var doc = toml_parse(text)
    # Collect unique table names
    var tables = List[String]()
    for k in doc.keys:
        var dot = k.find(".")
        if dot > 0:
            var tbl = String(k[byte=0:dot])
            var found = False
            for t in tables:
                if t == tbl:
                    found = True
                    break
            if not found:
                tables.append(tbl)

    for tbl in tables:
        var trigger = String("")
        var label = tbl
        var detail = String("")
        var body = String("")
        var doc_text = String("")

        var i_trig = doc.find(tbl + ".trigger")
        if i_trig >= 0:
            trigger = doc.vals[i_trig].s
        var i_lbl = doc.find(tbl + ".label")
        if i_lbl >= 0:
            label = doc.vals[i_lbl].s
        var i_det = doc.find(tbl + ".detail")
        if i_det >= 0:
            detail = doc.vals[i_det].s
        var i_body = doc.find(tbl + ".body")
        if i_body >= 0:
            body = doc.vals[i_body].s
        var i_doc = doc.find(tbl + ".doc")
        if i_doc >= 0:
            doc_text = doc.vals[i_doc].s

        if trigger.byte_length() > 0 or body.byte_length() > 0:
            out.append(SnippetTemplate(
                trigger if trigger.byte_length() > 0 else tbl,
                label,
                detail,
                body,
                doc_text
            ))
    return out^


def load_vscode_snippets(path: String) raises -> List[SnippetTemplate]:
    """Load snippet templates from a VSCode .code-snippets JSON file."""
    var out = List[SnippetTemplate]()
    if not path_exists(path):
        return out^
    var raw_bytes = read_file(path)
    if len(raw_bytes) == 0:
        return out^
    var text = bytes_to_str(raw_bytes)
    var doc = json_parse(text)
    if not doc.ok or len(doc.kinds) == 0:
        return out^

    # Root must be object
    if doc.kinds[0] != J_OBJ:
        return out^

    var child = doc.first[0]
    while child >= 0:
        var name = doc.keys[child]
        var prefix = String("")
        var body = String("")
        var desc = String("")

        var pref_idx = doc.path(child, "prefix")
        if pref_idx >= 0 and doc.kinds[pref_idx] == J_STR:
            prefix = doc.strs[pref_idx]

        var desc_idx = doc.path(child, "description")
        if desc_idx >= 0 and doc.kinds[desc_idx] == J_STR:
            desc = doc.strs[desc_idx]

        var body_idx = doc.path(child, "body")
        if body_idx >= 0:
            if doc.kinds[body_idx] == J_STR:
                body = doc.strs[body_idx]
            elif doc.kinds[body_idx] == J_ARR:
                var line_idx = doc.first[body_idx]
                var first_line = True
                while line_idx >= 0:
                    if doc.kinds[line_idx] == J_STR:
                        if not first_line:
                            body += "\n"
                        body += doc.strs[line_idx]
                        first_line = False
                    line_idx = doc.next[line_idx]

        if prefix.byte_length() > 0 or body.byte_length() > 0:
            out.append(SnippetTemplate(
                prefix if prefix.byte_length() > 0 else name,
                name,
                desc,
                body,
                desc
            ))
        child = doc.next[child]
    return out^


def expand_variables(
    raw: String,
    filename: String,
    filename_base: String,
    line_number: Int,
    line_index: Int,
    selected_text: String,
    clipboard: String,
) -> String:
    """Expand $TM_* and $CLIPBOARD variables in snippet text with explicit editor context."""
    var cps = decode(raw)
    var out = List[Int]()
    var n = len(cps)
    var i = 0
    while i < n:
        if cps[i] == 92 and i + 1 < n and cps[i + 1] == 36:
            var esc_rest = slice_str(cps, i + 1, n)
            if esc_rest.startswith("$TM_") or esc_rest.startswith("$CLIPBOARD"):
                out.append(36)
            else:
                out.append(92)
                out.append(36)
            i += 2
            continue
        if cps[i] == 36 and i + 1 < n:
            var rest = slice_str(cps, i, n)
            if rest.startswith("$TM_FILENAME_BASE"):
                for c in decode(filename_base):
                    out.append(c)
                i += 17
                continue
            if rest.startswith("$TM_FILENAME"):
                for c in decode(filename):
                    out.append(c)
                i += 12
                continue
            if rest.startswith("$TM_LINE_NUMBER"):
                for c in decode(String(line_number)):
                    out.append(c)
                i += 15
                continue
            if rest.startswith("$TM_LINE_INDEX"):
                for c in decode(String(max(0, line_index))):
                    out.append(c)
                i += 14
                continue
            if rest.startswith("$TM_SELECTED_TEXT"):
                for c in decode(selected_text):
                    out.append(c)
                i += 17
                continue
            if rest.startswith("$CLIPBOARD"):
                for c in decode(clipboard):
                    out.append(c)
                i += 10
                continue
        out.append(cps[i])
        i += 1
    return to_str(out)


def expand_variables(
    raw: String,
    filename: String = "",
    line_number: Int = 1,
    selected_text: String = "",
    clipboard: String = "",
) -> String:
    """Expand $TM_* and $CLIPBOARD variables in snippet text."""
    var base = stem(filename) if filename.byte_length() > 0 else String("")
    return expand_variables(
        raw,
        filename,
        base,
        line_number,
        max(0, line_number - 1),
        selected_text,
        clipboard,
    )


def expand_choice_and_tabstops(raw: String, line_indent: String = "") -> SnippetExpansion:
    """Expand choice tabstops ${1|opt1,opt2|} and standard tabstops (preserving mirrored $N stops)."""
    return expand_snippet_full(raw, line_indent)
