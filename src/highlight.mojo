"""Polyglot syntax highlighter (Mojo, Python, C/C++/CUDA, TOML, JSON, Shell/YAML, Markdown).

Line-based lexer with multi-line state tracking (`0` normal, `1` `\"\"\"`, `2` `'''`,
`3` `/* ... */` block comment, `4` Markdown fenced code block). `line_state` runs directly
on UTF-8 bytes and always agrees with `Highlighter.line` on end-of-line states."""
from std.collections import List, Dict
from util import is_digit, is_alpha, is_ident, slice_str, lower_str, basename

comptime C_TEXT = 0
comptime C_KW = 1
comptime C_TYPE = 2
comptime C_CMT = 3
comptime C_STR = 4
comptime C_NUM = 5
comptime C_DECO = 6
comptime C_SYM = 7
comptime C_BUILTIN = 8
comptime C_SELF = 9
comptime C_DEF = 10
comptime C_PARAM = 11      # the three below come only from the language server
comptime C_PROP = 12
comptime C_NS = 13
comptime C_COUNT = 14

comptime HL_MOJO = 0
comptime HL_PYTHON = 1
comptime HL_C_CUDA = 2
comptime HL_TOML = 3
comptime HL_JSON = 4
comptime HL_SHELL_YAML = 5
comptime HL_MARKDOWN = 6


def lang_for_path(path: String, title: String = "") -> Int:
    """Syntax highlighter mode for `path` (falling back to `title` for unsaved windows)."""
    var target = path if path.byte_length() > 0 else title
    if target.byte_length() == 0:
        return HL_MOJO
    var low = lower_str(basename(target))
    if low.endswith(".mojo") or target.endswith(".🔥"):
        return HL_MOJO
    if low.endswith(".py") or low.endswith(".pyi") or low.endswith(".pyw"):
        return HL_PYTHON
    for ext in [".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".hxx", ".cu", ".cuh", ".rs", ".go", ".js", ".ts", ".jsx", ".tsx", ".java", ".zig"]:
        if low.endswith(String(ext)):
            return HL_C_CUDA
    if low.endswith(".toml") or low.endswith(".ini") or low.endswith(".cfg") or low == ".editorconfig":
        return HL_TOML
    if low.endswith(".json") or low.endswith(".jsonl") or low.endswith(".jsonc"):
        return HL_JSON
    for ext in [".sh", ".bash", ".zsh", ".yaml", ".yml", ".env", ".conf"]:
        if low.endswith(String(ext)):
            return HL_SHELL_YAML
    if low == "dockerfile" or low == "makefile" or low.startswith("dockerfile."):
        return HL_SHELL_YAML
    if low.endswith(".md") or low.endswith(".mdx") or low.endswith(".markdown"):
        return HL_MARKDOWN
    return HL_MOJO


def comment_prefix_for_lang(lang: Int) -> String:
    """Line-comment prefix for `Toggle comment`."""
    if lang == HL_C_CUDA or lang == HL_JSON:
        return "//"
    return "#"


def is_md_fence_bytes(b: List[UInt8], start: Int, end: Int) -> Bool:
    var i = start
    while i < end and (Int(b[i]) == 32 or Int(b[i]) == 9):
        i += 1
    return i + 2 < end and Int(b[i]) == 96 and Int(b[i + 1]) == 96 and Int(b[i + 2]) == 96


def is_md_fence_cps(cps: List[Int]) -> Bool:
    var i = 0
    var n = len(cps)
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    return i + 2 < n and cps[i] == 96 and cps[i + 1] == 96 and cps[i + 2] == 96


def line_state_c(b: List[UInt8], start: Int, end: Int, state: Int) -> Int:
    """Multi-line `/* ... */` state (3) for C/C++/CUDA."""
    var i = start
    var st = 3 if state == 3 else 0
    while i < end:
        if st == 3:
            if i + 1 < end and Int(b[i]) == 42 and Int(b[i + 1]) == 47:
                st = 0
                i += 2
                continue
            i += 1
            continue
        var c = Int(b[i])
        if c == 47 and i + 1 < end:
            var nx = Int(b[i + 1])
            if nx == 47:
                return 0
            if nx == 42:
                st = 3
                i += 2
                continue
        if c == 34 or c == 39:
            var j = i + 1
            while j < end:
                if Int(b[j]) == 92:
                    j += 2
                    continue
                if Int(b[j]) == c:
                    j += 1
                    break
                j += 1
            i = j
            continue
        i += 1
    return st


def line_state(b: List[UInt8], start: Int, end: Int, state: Int, lang: Int = HL_MOJO) -> Int:
    """Lexer state after the line stored in b[start:end] (no newline), given `state` at start."""
    if lang == HL_JSON or lang == HL_SHELL_YAML:
        return 0
    if lang == HL_MARKDOWN:
        var st_md = 4 if state == 4 else 0
        if is_md_fence_bytes(b, start, end):
            return 0 if st_md == 4 else 4
        return st_md
    if lang == HL_C_CUDA:
        return line_state_c(b, start, end, state)

    # HL_MOJO, HL_PYTHON, HL_TOML: triple-quoted string states 1 (""") and 2 (''')
    var i = start
    var st = state if (state == 1 or state == 2) else 0
    if st != 0:
        var q = 34 if st == 1 else 39
        var found = -1
        var j = start
        while j + 2 < end:
            if Int(b[j]) == 92 and (lang != HL_TOML or st == 1):
                j += 2
                continue
            if Int(b[j]) == q and Int(b[j + 1]) == q and Int(b[j + 2]) == q:
                found = j
                break
            j += 1
        if found < 0:
            return st
        i = found + 3
    while i < end:
        var c = Int(b[i])
        if c == 35:
            return 0
        if c == 34 or c == 39:
            if i + 2 < end and Int(b[i + 1]) == c and Int(b[i + 2]) == c:
                var j = i + 3
                var found = -1
                while j + 2 < end:
                    if Int(b[j]) == 92 and (lang != HL_TOML or c == 34):
                        j += 2
                        continue
                    if Int(b[j]) == c and Int(b[j + 1]) == c and Int(b[j + 2]) == c:
                        found = j
                        break
                    j += 1
                if found < 0:
                    return 1 if c == 34 else 2
                i = found + 3
                continue
            var j = i + 1
            while j < end:
                if Int(b[j]) == 92 and (lang != HL_TOML or c == 34):
                    j += 2
                    continue
                if Int(b[j]) == c:
                    j += 1
                    break
                j += 1
            i = j
            continue
        i += 1
    return 0


def scan_states(b: List[UInt8], state: Int, mut out: List[UInt8], lang: Int = HL_MOJO) -> Int:
    """Run `line_state` over a block of whole lines (each ending in a newline) and append
    the state at the start of every following line to `out`. Returns the final state."""
    var st = state
    var start = 0
    var n = len(b)
    for i in range(n):
        if b[i] == 10:
            st = line_state(b, start, i, st, lang)
            out.append(UInt8(st))
            start = i + 1
    return st


def words(s: String) -> List[String]:
    var out = List[String]()
    for w in s.split(" "):
        var t = String(w)
        if t.byte_length() > 0:
            out.append(t)
    return out^


struct Highlighter(Movable):
    var kws: List[String]
    var types: List[String]
    var builtins: List[String]
    var class_map: Dict[String, Int]
    var py_map: Dict[String, Int]
    var c_map: Dict[String, Int]
    var sh_map: Dict[String, Int]

    def __init__(out self):
        self.kws = words(
            "def fn struct trait var let alias comptime if elif else for while in return raises raise"
            " try except finally with as import from pass break continue and or not is True False None"
            " out mut owned read ref inout borrowed deinit lambda yield async await del global nonlocal"
            " assert class match case where capturing escaping unsafe"
        )
        self.types = words(
            "Int Int8 Int16 Int32 Int64 Int128 Int256 UInt UInt8 UInt16 UInt32 UInt64 UInt128 UInt256"
            " Float16 Float32 Float64 BFloat16 Bool String StringLiteral StringSlice List Dict Set"
            " Optional Variant Tuple SIMD DType Scalar Pointer UnsafePointer OpaquePointer Span Error"
            " Copyable Movable ImplicitlyCopyable Writable Stringable Representable Hashable EqualityComparable"
            " Comparable Sized Boolable Intable Absable AnyType NoneType Self Codepoint InlineArray"
            " LayoutTensor Layout IndexList Writer Origin MutOrigin ImmutOrigin Iterator ArcPointer OwnedPointer"
            " TileTensor DeviceContext Allocation OptionalPointer Equatable TrivialRegisterPassable RegisterPassable"
            " MutPointer ImmPointer MutAnyOrigin ImmutAnyOrigin Some"
        )
        self.builtins = words(
            "print len range min max abs round String Int str ord chr isinstance input open rebind"
            " constrained debug_assert external_call parallelize vectorize sizeof alignof bitcast"
            " atol atof hash iter next enumerate zip reversed sorted sum any all dealloc alloc"
        )
        self.class_map = Dict[String, Int]()
        for w in self.builtins:
            self.class_map[w] = C_BUILTIN
        for w in self.types:
            self.class_map[w] = C_TYPE
        for w in self.kws:
            self.class_map[w] = C_KW
        self.class_map["self"] = C_SELF

        self.py_map = Dict[String, Int]()
        for w in words(
            "print len range min max abs round str int float bool bytes list dict set tuple ord chr"
            " isinstance issubclass getattr setattr hasattr open iter next enumerate zip reversed"
            " sorted sum any all super repr id type callable vars dir"
        ):
            self.py_map[w] = C_BUILTIN
        for w in words(
            "Any Optional Union Callable Sequence Mapping MutableMapping Iterable Iterator Tuple List"
            " Dict Set Type Final ClassVar Protocol TypedDict Path Exception ValueError TypeError"
            " RuntimeError KeyError IndexError OSError"
        ):
            self.py_map[w] = C_TYPE
        for w in words(
            "def class if elif else for while in return raise try except finally with as import from"
            " pass break continue and or not is True False None lambda yield async await del global"
            " nonlocal assert match case"
        ):
            self.py_map[w] = C_KW
        self.py_map["self"] = C_SELF
        self.py_map["cls"] = C_SELF

        self.c_map = Dict[String, Int]()
        for w in words(
            "printf fprintf snprintf malloc calloc realloc free memcpy memset memcmp strlen strcmp"
            " cudaMalloc cudaFree cudaMemcpy cudaDeviceSynchronize __syncthreads __syncwarp atomicAdd"
            " sizeof alignof static_assert"
        ):
            self.c_map[w] = C_BUILTIN
        for w in words(
            "void bool char short int long float double signed unsigned size_t ssize_t ptrdiff_t"
            " int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t uintptr_t FILE"
            " dim3 cudaError_t cudaStream_t half __half __nv_bfloat16 string vector map unordered_map"
            " span optional unique_ptr shared_ptr str usize isize u8 u16 u32 u64 i8 i16 i32 i64 f32 f64"
        ):
            self.c_map[w] = C_TYPE
        for w in words(
            "if else for while do switch case default break continue return goto struct class enum"
            " union typedef namespace template typename using const constexpr consteval static extern"
            " inline virtual override final public private protected friend new delete try catch throw"
            " noexcept auto register volatile restrict __restrict__ __global__ __device__ __host__"
            " __shared__ __constant__ __launch_bounds__ true false nullptr NULL fn let mut pub impl"
            " trait match mod use crate where async await func package var defer go chan select interface"
            " export import from const function"
        ):
            self.c_map[w] = C_KW
        for w in words("this self Self threadIdx blockIdx blockDim gridDim warpSize"):
            self.c_map[w] = C_SELF

        self.sh_map = Dict[String, Int]()
        for w in words("echo printf cd pwd ls rm cp mv mkdir cat grep sed awk find xargs test"):
            self.sh_map[w] = C_BUILTIN
        for w in words(
            "if then else elif fi for in do done while until case esac function return exit"
            " export local readonly declare typeset set unset shift trap source true false null yes no"
        ):
            self.sh_map[w] = C_KW

    def has(self, lst: List[String], w: String) -> Bool:
        for x in lst:
            if x == w:
                return True
        return False

    def classify(self, w: String, lang: Int = HL_MOJO) -> Int:
        if lang == HL_PYTHON:
            return self.py_map.get(w, C_TEXT)
        if lang == HL_C_CUDA:
            return self.c_map.get(w, C_TEXT)
        if lang == HL_SHELL_YAML:
            return self.sh_map.get(w, C_TEXT)
        return self.class_map.get(w, C_TEXT)

    def line_c_cuda(self, cps: List[Int], state: Int, mut cls: List[Int]) -> Int:
        var n = len(cps)
        var i = 0
        var st = 3 if state == 3 else 0
        if st == 0:
            var p = 0
            while p < n and (cps[p] == 32 or cps[p] == 9):
                p += 1
            if p < n and cps[p] == 35:
                # Preprocessor directive (#include, #define, #pragma, ...)
                var q = p + 1
                while q < n and (cps[q] == 32 or cps[q] == 9):
                    q += 1
                while q < n and is_ident(cps[q]):
                    q += 1
                for k in range(p, q):
                    cls[k] = C_DECO
                i = q
        var prev_word = String("")
        while i < n:
            if st == 3:
                var j = i
                var closed = -1
                while j + 1 < n:
                    if cps[j] == 42 and cps[j + 1] == 47:
                        closed = j + 2
                        break
                    j += 1
                if closed < 0:
                    for k in range(i, n):
                        cls[k] = C_CMT
                    return 3
                for k in range(i, closed):
                    cls[k] = C_CMT
                st = 0
                i = closed
                continue
            var c = cps[i]
            if c == 47 and i + 1 < n:
                if cps[i + 1] == 47:
                    for k in range(i, n):
                        cls[k] = C_CMT
                    return 0
                if cps[i + 1] == 42:
                    cls[i] = C_CMT
                    cls[i + 1] = C_CMT
                    st = 3
                    i += 2
                    continue
            if c == 34 or c == 39:
                var j = i + 1
                while j < n:
                    if cps[j] == 92:
                        j += 2
                        continue
                    if cps[j] == c:
                        j += 1
                        break
                    j += 1
                for k in range(i, min(j, n)):
                    cls[k] = C_STR
                i = j
                continue
            if is_digit(c) and (i == 0 or not is_ident(cps[i - 1])):
                var j = i
                while j < n and (is_ident(cps[j]) or cps[j] == 46):
                    j += 1
                for k in range(i, j):
                    cls[k] = C_NUM
                i = j
                continue
            if is_alpha(c):
                var j = i
                while j < n and is_ident(cps[j]):
                    j += 1
                var w = slice_str(cps, i, j)
                var k = self.classify(w, HL_C_CUDA)
                if k == C_TEXT and (prev_word == "struct" or prev_word == "class" or prev_word == "namespace" or prev_word == "fn" or prev_word == "func"):
                    k = C_DEF
                elif k == C_TEXT and j < n and cps[j] == 40:
                    k = C_DEF
                for q in range(i, j):
                    cls[q] = k
                prev_word = w
                i = j
                continue
            if c != 32 and c != 9:
                cls[i] = C_SYM
                prev_word = ""
            i += 1
        return st

    def line_toml(self, cps: List[Int], state: Int, mut cls: List[Int]) -> Int:
        var n = len(cps)
        var i = 0
        var st = state if (state == 1 or state == 2) else 0
        if st != 0:
            var q = 34 if st == 1 else 39
            var j = 0
            var found = -1
            while j + 2 < n:
                if cps[j] == 92 and st == 1:
                    j += 2
                    continue
                if cps[j] == q and cps[j + 1] == q and cps[j + 2] == q:
                    found = j
                    break
                j += 1
            if found < 0:
                for k in range(n):
                    cls[k] = C_STR
                return st
            for k in range(found + 3):
                cls[k] = C_STR
            i = found + 3
        # Section header [section] or key = value at start of line
        if i == 0:
            var p = 0
            while p < n and (cps[p] == 32 or cps[p] == 9):
                p += 1
            if p < n and cps[p] == 91:
                var rb = -1
                for k in range(p, n):
                    if cps[k] == 35:
                        break
                    if cps[k] == 93:
                        rb = k
                if rb > p:
                    for k in range(p, rb + 1):
                        cls[k] = C_DECO
                    i = rb + 1
            elif p < n and cps[p] != 35:
                var eq = -1
                for k in range(p, n):
                    if cps[k] == 35:
                        break
                    if cps[k] == 61:
                        eq = k
                        break
                if eq > p:
                    for k in range(p, eq):
                        if cps[k] != 32 and cps[k] != 9:
                            cls[k] = C_DEF
                    cls[eq] = C_SYM
                    i = eq + 1
        while i < n:
            var c = cps[i]
            if c == 35:
                for k in range(i, n):
                    cls[k] = C_CMT
                return 0
            if c == 34 or c == 39:
                if i + 2 < n and cps[i + 1] == c and cps[i + 2] == c:
                    var j = i + 3
                    var found = -1
                    while j + 2 < n:
                        if cps[j] == 92 and c == 34:
                            j += 2
                            continue
                        if cps[j] == c and cps[j + 1] == c and cps[j + 2] == c:
                            found = j
                            break
                        j += 1
                    if found < 0:
                        for k in range(i, n):
                            cls[k] = C_STR
                        return 1 if c == 34 else 2
                    for k in range(i, found + 3):
                        cls[k] = C_STR
                    i = found + 3
                    continue
                var j = i + 1
                while j < n:
                    if cps[j] == 92 and c == 34:
                        j += 2
                        continue
                    if cps[j] == c:
                        j += 1
                        break
                    j += 1
                for k in range(i, min(j, n)):
                    cls[k] = C_STR
                i = j
                continue
            if is_digit(c) or (c == 45 and i + 1 < n and is_digit(cps[i + 1])):
                var j = i + 1
                while j < n and (is_ident(cps[j]) or cps[j] == 46 or cps[j] == 45 or cps[j] == 58 or cps[j] == 43):
                    j += 1
                for k in range(i, j):
                    cls[k] = C_NUM
                i = j
                continue
            if is_alpha(c):
                var j = i
                while j < n and is_ident(cps[j]):
                    j += 1
                var w = slice_str(cps, i, j)
                var k = C_KW if (w == "true" or w == "false") else C_TEXT
                for q in range(i, j):
                    cls[q] = k
                i = j
                continue
            if c != 32 and c != 9:
                cls[i] = C_SYM
            i += 1
        return 0

    def line_json(self, cps: List[Int], mut cls: List[Int]) -> Int:
        var n = len(cps)
        var i = 0
        while i < n:
            var c = cps[i]
            if c == 47 and i + 1 < n and cps[i + 1] == 47:
                for k in range(i, n):
                    cls[k] = C_CMT
                break
            if c == 34:
                var j = i + 1
                while j < n:
                    if cps[j] == 92:
                        j += 2
                        continue
                    if cps[j] == 34:
                        j += 1
                        break
                    j += 1
                var p = j
                while p < n and (cps[p] == 32 or cps[p] == 9):
                    p += 1
                var kind = C_DEF if (p < n and cps[p] == 58) else C_STR
                for k in range(i, min(j, n)):
                    cls[k] = kind
                i = j
                continue
            if is_digit(c) or (c == 45 and i + 1 < n and is_digit(cps[i + 1])):
                var j = i + 1
                while j < n and (is_digit(cps[j]) or cps[j] == 46 or cps[j] == 101 or cps[j] == 69 or cps[j] == 43 or cps[j] == 45):
                    j += 1
                for k in range(i, j):
                    cls[k] = C_NUM
                i = j
                continue
            if is_alpha(c):
                var j = i
                while j < n and is_ident(cps[j]):
                    j += 1
                var w = slice_str(cps, i, j)
                var kind = C_KW if (w == "true" or w == "false" or w == "null") else C_TEXT
                for k in range(i, j):
                    cls[k] = kind
                i = j
                continue
            if c != 32 and c != 9:
                cls[i] = C_SYM
            i += 1
        return 0

    def line_shell_yaml(self, cps: List[Int], mut cls: List[Int]) -> Int:
        var n = len(cps)
        var i = 0
        var p = 0
        while p < n and (cps[p] == 32 or cps[p] == 9 or cps[p] == 45):
            if cps[p] == 45:
                cls[p] = C_SYM
            p += 1
        # YAML key `name:` at start of line
        if p < n and (is_alpha(cps[p]) or cps[p] == 46):
            var q = p
            while q < n and (is_ident(cps[q]) or cps[q] == 45 or cps[q] == 46):
                q += 1
            if q < n and cps[q] == 58 and (q + 1 >= n or cps[q + 1] == 32 or cps[q + 1] == 9):
                for k in range(p, q):
                    cls[k] = C_DEF
                cls[q] = C_SYM
                i = q + 1
        while i < n:
            var c = cps[i]
            if c == 35 and (i == 0 or cps[i - 1] == 32 or cps[i - 1] == 9):
                for k in range(i, n):
                    cls[k] = C_CMT
                break
            if c == 34 or c == 39:
                var j = i + 1
                while j < n:
                    if cps[j] == 92 and c == 34:
                        j += 2
                        continue
                    if cps[j] == c:
                        j += 1
                        break
                    j += 1
                for k in range(i, min(j, n)):
                    cls[k] = C_STR
                i = j
                continue
            if c == 36 and i + 1 < n:
                var j = i + 1
                if cps[j] == 123:
                    while j < n and cps[j] != 125:
                        j += 1
                    if j < n:
                        j += 1
                else:
                    while j < n and (is_ident(cps[j]) or cps[j] == 63 or cps[j] == 64 or cps[j] == 35):
                        j += 1
                for k in range(i, min(j, n)):
                    cls[k] = C_SELF
                i = j
                continue
            if is_digit(c) and (i == 0 or not is_ident(cps[i - 1])):
                var j = i
                while j < n and (is_digit(cps[j]) or cps[j] == 46):
                    j += 1
                for k in range(i, j):
                    cls[k] = C_NUM
                i = j
                continue
            if is_alpha(c):
                var j = i
                while j < n and (is_ident(cps[j]) or cps[j] == 45):
                    j += 1
                var w = slice_str(cps, i, j)
                var kind = self.classify(w, HL_SHELL_YAML)
                for k in range(i, j):
                    cls[k] = kind
                i = j
                continue
            if c != 32 and c != 9:
                cls[i] = C_SYM
            i += 1
        return 0

    def line_markdown(self, cps: List[Int], state: Int, mut cls: List[Int]) -> Int:
        var n = len(cps)
        var st = 4 if state == 4 else 0
        if is_md_fence_cps(cps):
            for k in range(n):
                cls[k] = C_DECO
            return 0 if st == 4 else 4
        if st == 4:
            # Inside fenced code block: highlight Mojo/Python tokens, keep state 4
            _ = self.line(cps, 0, cls, HL_MOJO)
            return 4
        var p = 0
        while p < n and (cps[p] == 32 or cps[p] == 9):
            p += 1
        if p < n and cps[p] == 35:
            for k in range(p, n):
                cls[k] = C_DEF
            return 0
        if p < n and cps[p] == 62:
            for k in range(p, n):
                cls[k] = C_CMT
            return 0
        if p + 1 < n and (cps[p] == 45 or cps[p] == 42 or cps[p] == 43) and cps[p + 1] == 32:
            cls[p] = C_KW
        var i = 0
        while i < n:
            var c = cps[i]
            if c == 96:
                var j = i + 1
                while j < n and cps[j] != 96:
                    j += 1
                if j < n:
                    j += 1
                for k in range(i, min(j, n)):
                    cls[k] = C_STR
                i = j
                continue
            if c == 91:
                var rb = -1
                for k in range(i + 1, n):
                    if cps[k] == 93:
                        rb = k
                        break
                if rb > i and rb + 1 < n and cps[rb + 1] == 40:
                    var rp = -1
                    for k in range(rb + 2, n):
                        if cps[k] == 41:
                            rp = k
                            break
                    if rp > rb:
                        for k in range(i, rb + 1):
                            cls[k] = C_TYPE
                        for k in range(rb + 1, rp + 1):
                            cls[k] = C_STR
                        i = rp + 1
                        continue
            if c == 42 and i + 1 < n and cps[i + 1] == 42:
                var end_b = -1
                for k in range(i + 2, n - 1):
                    if cps[k] == 42 and cps[k + 1] == 42:
                        end_b = k + 2
                        break
                if end_b > i:
                    for k in range(i, end_b):
                        cls[k] = C_KW
                    i = end_b
                    continue
            i += 1
        return 0

    def line(self, cps: List[Int], state: Int, mut cls: List[Int], lang: Int = HL_MOJO) -> Int:
        """Fill `cls` with a class per codepoint; returns the state for the next line."""
        cls.clear()
        var n = len(cps)
        for _ in range(n):
            cls.append(C_TEXT)
        if lang == HL_C_CUDA:
            return self.line_c_cuda(cps, state, cls)
        if lang == HL_TOML:
            return self.line_toml(cps, state, cls)
        if lang == HL_JSON:
            return self.line_json(cps, cls)
        if lang == HL_SHELL_YAML:
            return self.line_shell_yaml(cps, cls)
        if lang == HL_MARKDOWN:
            return self.line_markdown(cps, state, cls)

        var i = 0
        var st = state if (state == 1 or state == 2) else 0
        if st != 0:
            var q = 34 if st == 1 else 39
            var j = 0
            var found = -1
            while j + 2 < n:
                if cps[j] == 92:
                    j += 2
                    continue
                if cps[j] == q and cps[j + 1] == q and cps[j + 2] == q:
                    found = j
                    break
                j += 1
            if found < 0:
                for k in range(n):
                    cls[k] = C_STR
                return st
            for k in range(found + 3):
                cls[k] = C_STR
            i = found + 3
            st = 0
        var prev_word = String("")
        while i < n:
            var c = cps[i]
            if c == 35:
                for k in range(i, n):
                    cls[k] = C_CMT
                break
            if c == 34 or c == 39:
                if i + 2 < n and cps[i + 1] == c and cps[i + 2] == c:
                    var j = i + 3
                    var found = -1
                    while j + 2 < n:
                        if cps[j] == 92:
                            j += 2
                            continue
                        if cps[j] == c and cps[j + 1] == c and cps[j + 2] == c:
                            found = j
                            break
                        j += 1
                    if found < 0:
                        for k in range(i, n):
                            cls[k] = C_STR
                        return 1 if c == 34 else 2
                    for k in range(i, found + 3):
                        cls[k] = C_STR
                    i = found + 3
                    continue
                var j = i + 1
                while j < n:
                    if cps[j] == 92:
                        j += 2
                        continue
                    if cps[j] == c:
                        j += 1
                        break
                    j += 1
                for k in range(i, min(j, n)):
                    cls[k] = C_STR
                i = j
                continue
            if is_digit(c) and (i == 0 or not is_ident(cps[i - 1])):
                var j = i
                while j < n and (is_ident(cps[j]) or cps[j] == 46):
                    j += 1
                for k in range(i, j):
                    cls[k] = C_NUM
                i = j
                continue
            if c == 64:
                var j = i + 1
                while j < n and (is_ident(cps[j]) or cps[j] == 46):
                    j += 1
                for k in range(i, j):
                    cls[k] = C_DECO
                i = j
                continue
            if is_alpha(c):
                var j = i
                while j < n and is_ident(cps[j]):
                    j += 1
                var w = slice_str(cps, i, j)
                var k = self.classify(w, lang)
                if k == C_TEXT and (prev_word == "def" or prev_word == "class" or (lang == HL_MOJO and (prev_word == "struct" or prev_word == "trait" or prev_word == "fn" or prev_word == "comptime"))):
                    k = C_DEF
                # string prefixes like r"..." / f"..."
                if j < n and (cps[j] == 34 or cps[j] == 39) and j - i == 1:
                    k = C_STR
                for q in range(i, j):
                    cls[q] = k
                prev_word = w
                i = j
                continue
            if c != 32:
                cls[i] = C_SYM
                prev_word = ""
            i += 1
        return st
