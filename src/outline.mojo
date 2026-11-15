"""The outline of a file: its functions, structs, traits and constants as a tree.
Two sources: the language server's documentSymbol answer, and a scan of the text that
needs no server."""
from std.collections import List
from buffer import TextBuffer
from json import Json
from util import decode, to_str, is_ident, slice_str


# LSP SymbolKind values used here
comptime SK_MODULE = 2
comptime SK_CLASS = 5
comptime SK_METHOD = 6
comptime SK_PROPERTY = 7
comptime SK_FIELD = 8
comptime SK_INTERFACE = 11
comptime SK_FUNCTION = 12
comptime SK_VARIABLE = 13
comptime SK_CONSTANT = 14
comptime SK_STRUCT = 23
comptime SK_CELL = 26


@fieldwise_init
struct OutlineItem(Copyable, Movable):
    var name: String
    var kind: Int           # an LSP SymbolKind
    var row: Int            # where the name is (0-based row, character column)
    var col: Int
    var depth: Int          # nesting: 0 = top level
    var traits: List[String]

    def __init__(out self, name: String, kind: Int, row: Int, col: Int, depth: Int):
        self.name = name
        self.kind = kind
        self.row = row
        self.col = col
        self.depth = depth
        self.traits = List[String]()


def parse_struct_traits(line: String) -> List[String]:
    """Extract trait conformance names from `struct Foo(TraitA, TraitB):` or `struct Foo[T: AnyType](TraitA):`."""
    var out = List[String]()
    var cps = decode(line)
    var n = len(cps)
    var i = 0
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    var rest = slice_str(cps, i, n)
    if not rest.startswith("struct "):
        return out^
    i += 7
    while i < n and cps[i] == 32:
        i += 1
    while i < n and is_ident(cps[i]):
        i += 1
    while i < n and cps[i] == 32:
        i += 1
    # Skip optional compile-time parameter list `[...]`
    if i < n and cps[i] == 91:
        var bdepth = 1
        i += 1
        while i < n and bdepth > 0:
            if cps[i] == 91:
                bdepth += 1
            elif cps[i] == 93:
                bdepth -= 1
            i += 1
    while i < n and cps[i] == 32:
        i += 1
    if i >= n or cps[i] != 40:
        return out^
    var p_start = i + 1
    var pdepth = 1
    var j = p_start
    var in_str = 0
    while j < n and pdepth > 0:
        var c = cps[j]
        if in_str == 0 and c == 35:
            break
        if (c == 34 or c == 39) and (j == 0 or cps[j - 1] != 92):
            if in_str == 0:
                in_str = c
            elif in_str == c:
                in_str = 0
        elif in_str == 0:
            if c == 40:
                pdepth += 1
            elif c == 41:
                pdepth -= 1
                if pdepth == 0:
                    break
        j += 1
    if pdepth != 0:
        return out^
    # Split `[p_start, j)` by top-level commas
    var seg_start = p_start
    var depth_inner = 0
    for k in range(p_start, j + 1):
        var at_end = k == j
        var ch = 0 if at_end else cps[k]
        if not at_end:
            if ch == 91 or ch == 40:
                depth_inner += 1
            elif ch == 93 or ch == 41:
                depth_inner = max(0, depth_inner - 1)
        if at_end or (ch == 44 and depth_inner == 0):
            var raw_tok = String(slice_str(cps, seg_start, k).strip())
            var brk = raw_tok.find("[")
            if brk > 0:
                var trimmed_brk = String(raw_tok[byte=0:brk].strip())
                raw_tok = trimmed_brk
            var dot = raw_tok.rfind(".")
            if dot >= 0 and dot + 1 < raw_tok.byte_length():
                var trimmed_dot = String(raw_tok[byte=dot + 1:].strip())
                raw_tok = trimmed_dot
            var tcps = decode(raw_tok)
            var valid = len(tcps) > 0
            for tc in tcps:
                if not is_ident(tc):
                    valid = False
                    break
            if valid and not (raw_tok in out):
                out.append(raw_tok)
            seg_start = k + 1
    return out^


def outline_tag(kind: Int) -> String:
    """A one-character sign for a kind of symbol."""
    if kind == SK_FUNCTION or kind == SK_METHOD or kind == 9:        # 9: constructor
        return "ƒ"
    if kind == SK_STRUCT or kind == SK_CLASS or kind == 10:          # 10: enum
        return "◆"
    if kind == SK_INTERFACE:
        return "◇"
    if kind == SK_CONSTANT or kind == SK_VARIABLE:
        return "="
    if kind == SK_FIELD or kind == SK_PROPERTY or kind == 22:        # 22: enum member
        return "·"
    if kind == SK_MODULE or kind == 3 or kind == 4:                  # namespace, package
        return "▪"
    if kind == SK_CELL:
        return "⊞"
    return "•"


def outline_line(it: OutlineItem) -> String:
    var s = String("")
    for _ in range(it.depth):
        s += "  "
    return s + outline_tag(it.kind) + " " + it.name


def outline_current(items: List[OutlineItem], row: Int) -> Int:
    """The item the cursor row belongs to: the last one that starts at or above it
    (-1 above the first)."""
    var best = -1
    for k in range(len(items)):
        if items[k].row <= row:
            best = k
    return best


def scan_outline(buf: TextBuffer) -> List[OutlineItem]:
    """Find `def`, `fn`, `struct`, `trait` and top-level `comptime` / `alias` lines.
    Nesting follows indentation: an item is inside the nearest item above it that is
    indented less."""
    var items = List[OutlineItem]()
    var indents = List[Int]()           # indentation of the open items, outermost first
    var in_doc = 0                      # inside a triple-quoted string: its quote character
    var cell_num = 0
    for r in range(buf.count()):
        var line = buf.line(r)
        var n = len(line)
        var ind = 0
        while ind < n and (line[ind] == 32 or line[ind] == 9):
            ind += 1
        # docstrings can contain lines that look like code
        var started_inside = in_doc != 0
        var q = 0
        while q + 2 < n:
            if (line[q] == 34 or line[q] == 39) and line[q + 1] == line[q] and line[q + 2] == line[q] and (in_doc == 0 or in_doc == line[q]):
                in_doc = line[q] if in_doc == 0 else 0
                q += 3
            else:
                q += 1
        if started_inside:
            continue
        if ind >= n:
            continue
        if line[ind] == 35:
            var cmt = slice_str(line, ind, n)
            if (
                cmt == "# %%"
                or cmt.startswith("# %% ")
                or cmt.startswith("# %%\t")
                or cmt == "#%%"
                or cmt.startswith("#%% ")
                or cmt.startswith("#%%\t")
            ):
                cell_num += 1
                var title = String("")
                if cmt.startswith("# %%"):
                    title = String(cmt[byte=4:].strip())
                elif cmt.startswith("#%%"):
                    title = String(cmt[byte=3:].strip())
                if title.byte_length() == 0:
                    title = "Cell " + String(cell_num)
                items.append(OutlineItem(title, SK_CELL, r, ind, 0))
            continue
        var rest = List[Int]()
        for k in range(ind, n):
            rest.append(line[k])
        var text = to_str(rest)
        var kind = 0
        var skip = 0
        if text.startswith("def "):
            kind = SK_FUNCTION
            skip = 4
        elif text.startswith("fn "):
            kind = SK_FUNCTION
            skip = 3
        elif text.startswith("struct "):
            kind = SK_STRUCT
            skip = 7
        elif text.startswith("__extension "):
            kind = SK_STRUCT
            skip = 12
        elif text.startswith("trait "):
            kind = SK_INTERFACE
            skip = 6
        elif text.startswith("comptime ") and ind == 0:
            kind = SK_CONSTANT
            skip = 9
        elif text.startswith("alias ") and ind == 0:
            kind = SK_CONSTANT
            skip = 6
        if kind == 0:
            continue
        var s0 = ind + skip
        while s0 < n and line[s0] == 32:
            s0 += 1
        var e = s0
        while e < n and is_ident(line[e]):
            e += 1
        if e == s0:
            continue
        while len(indents) > 0 and indents[len(indents) - 1] >= ind:
            _ = indents.pop()
        var depth = len(indents)
        if kind == SK_FUNCTION and depth > 0:
            var parent = items_kind_at(items, depth - 1)
            if parent == SK_STRUCT or parent == SK_INTERFACE:
                kind = SK_METHOD
        var name = List[Int]()
        for k in range(s0, e):
            name.append(line[k])
        var st_traits = parse_struct_traits(text) if text.startswith("struct ") else List[String]()
        items.append(OutlineItem(to_str(name), kind, r, s0, depth, st_traits^))
        indents.append(ind)
    return items^


def items_kind_at(items: List[OutlineItem], depth: Int) -> Int:
    """Kind of the innermost open item at `depth` (the last one listed with it)."""
    var k = len(items) - 1
    while k >= 0:
        if items[k].depth == depth:
            return items[k].kind
        k -= 1
    return 0


def add_symbol(doc: Json, node: Int, depth: Int, mut items: List[OutlineItem]):
    var name = doc.str(doc.get(node, "name"))
    var start = doc.path(node, "selectionRange/start")
    if start < 0:
        start = doc.path(node, "range/start")
    if start < 0:
        start = doc.path(node, "location/range/start")      # SymbolInformation
    if name.byte_length() > 0 and start >= 0 and depth < 12:
        items.append(OutlineItem(name, doc.int(doc.get(node, "kind"), 0), max(0, doc.int(doc.get(start, "line"), 0)), max(0, doc.int(doc.get(start, "character"), 0)), depth))
        var kids = doc.get(node, "children")
        if kids >= 0:
            for c in doc.children(kids):
                add_symbol(doc, c, depth + 1, items)


def parse_symbols(doc: Json, result: Int) -> List[OutlineItem]:
    """Read a documentSymbol answer: a tree of DocumentSymbols (children nested), or a
    flat list of SymbolInformation (nested one level when a container is named).
    Columns are the server's (UTF-16 units); the caller converts them."""
    var items = List[OutlineItem]()
    if result < 0 or doc.is_null(result):
        return items^
    var flat = False
    for node in doc.children(result):
        if doc.get(node, "location") >= 0:
            flat = True
        add_symbol(doc, node, 0, items)
        if flat and len(items) > 0 and doc.str(doc.get(node, "containerName")).byte_length() > 0:
            items[len(items) - 1].depth = 1
    if flat:
        # a flat list is not promised to be in file order
        for a in range(1, len(items)):
            var b = a
            while b > 0 and (items[b].row < items[b - 1].row or (items[b].row == items[b - 1].row and items[b].col < items[b - 1].col)):
                var tmp = items[b].copy()
                items[b] = items[b - 1].copy()
                items[b - 1] = tmp^
                b -= 1
    return items^


def scope_path(items: List[OutlineItem], row: Int) -> List[Int]:
    """The items (indices, outermost first) whose block holds line `row`: an item's block
    runs from its line to the line before the next item of the same or a lower depth."""
    var out = List[Int]()
    for k in range(len(items)):
        if items[k].row > row:
            break
        # where does item k's block end?
        var end = 1 << 40
        for j in range(k + 1, len(items)):
            if items[j].depth <= items[k].depth:
                end = items[j].row
                break
        if row < end:
            while len(out) > 0 and items[out[len(out) - 1]].depth >= items[k].depth:
                _ = out.pop()
            out.append(k)
    return out^


def breadcrumbs(items: List[OutlineItem], path: List[Int]) -> String:
    """" › Counter › add" for a path (empty for none)."""
    var s = String("")
    for k in path:
        s += " › " + items[k].name
    return s^


def sticky_rows(items: List[OutlineItem], path: List[Int], top: Int, cursor: Int, most: Int) -> List[Int]:
    """The header lines to pin at the top of the view: those of the scopes the top line
    is in whose own line has scrolled away (outermost first, at most `most`), and never
    so many that the cursor's line would be covered."""
    var out = List[Int]()
    for k in path:
        if items[k].row < top + len(out):
            out.append(items[k].row)
    while len(out) > most:
        _ = out.pop(0)
    while len(out) > 0 and cursor - top < len(out):
        _ = out.pop(0)
    return out^
