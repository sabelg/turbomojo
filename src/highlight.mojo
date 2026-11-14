"""Mojo syntax highlighter (line-based with triple-quoted string state)."""
from std.collections import List, Dict
from util import is_digit, is_alpha, is_ident, slice_str

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


def line_state(b: List[UInt8], start: Int, end: Int, state: Int) -> Int:
    # Lexer state after the line stored in b[start:end] (no newline), given the state at
    # its start: 0 = normal, 1 = inside a triple-double-quoted string, 2 = inside a
    # triple-single-quoted string.
    #
    # This is Highlighter.line reduced to the only things that can change the state:
    # comments, quotes and backslashes. All of them are ASCII, so it can run on raw UTF-8
    # bytes. It must always agree with Highlighter.line (the tests compare the two).
    var i = start
    var st = state
    if st != 0:
        var q = 34 if st == 1 else 39
        var found = -1
        var j = start
        while j + 2 < end:
            if Int(b[j]) == 92:
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
                    if Int(b[j]) == 92:
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
    return 0


def scan_states(b: List[UInt8], state: Int, mut out: List[UInt8]) -> Int:
    """Run `line_state` over a block of whole lines (each ending in a newline) and append
    the state at the start of every following line to `out`. Returns the final state."""
    var st = state
    var start = 0
    var n = len(b)
    for i in range(n):
        if b[i] == 10:
            st = line_state(b, start, i, st)
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

    def has(self, lst: List[String], w: String) -> Bool:
        for x in lst:
            if x == w:
                return True
        return False

    def classify(self, w: String) -> Int:
        return self.class_map.get(w, C_TEXT)

    def line(self, cps: List[Int], state: Int, mut cls: List[Int]) -> Int:
        """Fill `cls` with a class per codepoint; returns the state for the next line.
        state: 0 = normal, 1 = inside \"\"\" string, 2 = inside ''' string."""
        cls.clear()
        var n = len(cps)
        for _ in range(n):
            cls.append(C_TEXT)
        var i = 0
        var st = state
        if st != 0:
            var q = 34 if st == 1 else 39
            var j = 0
            var found = -1
            while j + 2 < n + 0:
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
                var k = self.classify(w)
                if k == C_TEXT and (prev_word == "def" or prev_word == "struct" or prev_word == "trait" or prev_word == "fn" or prev_word == "comptime"):
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
