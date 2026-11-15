"""An index of the symbols (functions, structs, traits, constants) of every Mojo file of
the project, built a slice at a time so the editor never waits for it."""
from std.collections import List
from std.time import perf_counter_ns
from buffer import TextBuffer
from grep import FileSearch
from search import Search
from outline import (
    OutlineItem, scan_outline, outline_tag, scope_path,
    SK_MODULE, SK_FUNCTION, SK_METHOD, SK_STRUCT, SK_INTERFACE, SK_CELL,
)
from util import read_file, is_ident, is_alpha, slice_str

comptime INDEX_MAX_SYMBOLS = 50000
comptime INDEX_MAX_BYTES = 2 * 1024 * 1024


@fieldwise_init
struct IndexedSymbol(Copyable, Movable):
    var name: String
    var kind: Int           # an LSP SymbolKind (see outline.mojo)
    var path: String
    var row: Int            # 0-based
    var col: Int
    var owner: String       # the struct or trait it is in ('' at top level)
    var traits: List[String]

    def __init__(
        out self,
        name: String,
        kind: Int,
        path: String,
        row: Int,
        col: Int,
        owner: String,
    ):
        self.name = name
        self.kind = kind
        self.path = path
        self.row = row
        self.col = col
        self.owner = owner
        self.traits = List[String]()


def _is_decl_header(cps: List[Int], tok_start: Int) -> Bool:
    var j = tok_start - 1
    while j >= 0 and (cps[j] == 32 or cps[j] == 9):
        j -= 1
    if j < 0:
        return False
    var e = j + 1
    while j >= 0 and is_ident(cps[j]):
        j -= 1
    var kw = slice_str(cps, j + 1, e)
    return kw == "def" or kw == "fn" or kw == "struct" or kw == "trait"


def _followed_by_call_paren(cps: List[Int], tok_end: Int) -> Bool:
    var n = len(cps)
    var i = tok_end
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    if i < n and cps[i] == 91:
        var depth = 1
        i += 1
        while i < n and depth > 0:
            if cps[i] == 91:
                depth += 1
            elif cps[i] == 93:
                depth -= 1
            i += 1
        while i < n and (cps[i] == 32 or cps[i] == 9):
            i += 1
    return i < n and cps[i] == 40


def _is_non_call_kw(tok: String) -> Bool:
    return (
        tok == "if"
        or tok == "elif"
        or tok == "while"
        or tok == "for"
        or tok == "return"
        or tok == "raise"
        or tok == "with"
        or tok == "except"
        or tok == "assert"
        or tok == "match"
        or tok == "case"
        or tok == "not"
        or tok == "and"
        or tok == "or"
    )


def is_mojo_file(path: String) -> Bool:
    return path.endswith(".mojo") or path.endswith(".🔥")


def owners_of(items: List[OutlineItem]) -> List[String]:
    """For each item of an outline the name of the item it is nested in ('' if none)."""
    var out = List[String]()
    var open = List[String]()           # names by depth
    for it in items:
        while len(open) > it.depth:
            _ = open.pop()
        out.append(open[len(open) - 1] if len(open) > 0 else String(""))
        if it.kind != SK_CELL:
            open.append(it.name)
    return out^


struct SymbolIndex(Movable):
    var walk: FileSearch                # used for its folder walk and ignore rules
    var root: String
    var building: Bool
    var built: Bool                     # at least one pass has finished
    var built_ns: Int                   # when the last pass finished
    var syms: List[IndexedSymbol]       # the finished index
    var fresh: List[IndexedSymbol]      # the pass under way
    var files_done: Int
    var truncated: Bool

    def __init__(out self):
        self.walk = FileSearch()
        self.root = ""
        self.building = False
        self.built = False
        self.built_ns = 0
        self.syms = List[IndexedSymbol]()
        self.fresh = List[IndexedSymbol]()
        self.files_done = 0
        self.truncated = False

    def start(mut self, root: String):
        """Begin a pass over the project (the finished index stays usable meanwhile)."""
        self.root = root
        self.walk.start(root, Search())
        self.walk.active = False        # we drive the walk ourselves
        self.fresh.clear()
        self.files_done = 0
        self.truncated = False
        self.building = True

    def add_items(mut self, path: String, items: List[OutlineItem], mut into: List[IndexedSymbol]):
        var owners = owners_of(items)
        for k in range(len(items)):
            if items[k].kind == SK_CELL:
                continue
            if len(into) >= INDEX_MAX_SYMBOLS:
                self.truncated = True
                return
            into.append(IndexedSymbol(
                items[k].name,
                items[k].kind,
                path,
                items[k].row,
                items[k].col,
                owners[k],
                items[k].traits.copy(),
            ))

    def scan_file(mut self, path: String, mut into: List[IndexedSymbol]):
        var data = read_file(path)
        if len(data) == 0 or len(data) > INDEX_MAX_BYTES:
            return
        var b = TextBuffer()
        b.load_bytes(data)
        self.add_items(path, scan_outline(b), into)

    def step(mut self, budget_ms: Int):
        """Do some of the pass: at least one file or folder, then more until about
        `budget_ms` milliseconds have passed."""
        if not self.building:
            return
        var t0 = Int(perf_counter_ns())
        while True:
            if len(self.walk.files) > 0:
                var path = self.walk.files.pop()
                if is_mojo_file(path):
                    var into = List[IndexedSymbol]()
                    self.scan_file(path, into)
                    for s in into:
                        if len(self.fresh) < INDEX_MAX_SYMBOLS:
                            self.fresh.append(s.copy())
                        else:
                            self.truncated = True
                    self.files_done += 1
            elif len(self.walk.dirs) > 0:
                self.walk.list_next_dir()
            else:
                self.syms = self.fresh.copy()
                self.fresh.clear()
                self.building = False
                self.built = True
                self.built_ns = Int(perf_counter_ns())
                return
            if (Int(perf_counter_ns()) - t0) // 1000000 >= budget_ms:
                return

    def replace_file(mut self, path: String, items: List[OutlineItem]):
        """Put the symbols of one file (as just scanned from an editor or after a save)
        in place of what the index has for it."""
        var kept = List[IndexedSymbol]()
        for s in self.syms:
            if s.path != path:
                kept.append(s.copy())
        self.add_items(path, items, kept)
        self.syms = kept^

    def summary(self) -> String:
        var last = String("")
        var n_files = 0
        for s in self.syms:
            if s.path != last:
                n_files += 1
                last = s.path
        return String(len(self.syms)) + (" symbol" if len(self.syms) == 1 else " symbols") + " in " + String(n_files) + (" file" if n_files == 1 else " files") + (" (list cut off)" if self.truncated else "")

    def supertypes_of(self, struct_name: String) -> List[IndexedSymbol]:
        """Traits that `struct_name` conforms to in the index (resolving trait definitions when present)."""
        var out = List[IndexedSymbol]()
        if struct_name.byte_length() == 0:
            return out^
        var wanted = List[String]()
        var fallback_path = String("")
        var fallback_row = 0
        var fallback_col = 0
        for s in self.syms:
            if s.kind == SK_STRUCT and s.name == struct_name:
                if fallback_path.byte_length() == 0:
                    fallback_path = s.path
                    fallback_row = s.row
                    fallback_col = s.col
                for tr in s.traits:
                    if not (tr in wanted):
                        wanted.append(tr)
        for tr in wanted:
            var found = False
            for s in self.syms:
                if s.kind == SK_INTERFACE and s.name == tr:
                    out.append(s.copy())
                    found = True
            if not found:
                out.append(IndexedSymbol(tr, SK_INTERFACE, fallback_path, fallback_row, fallback_col, ""))
        return out^

    def subtypes_of(self, trait_name: String) -> List[IndexedSymbol]:
        """Structs in the index whose conformance list contains `trait_name`."""
        var out = List[IndexedSymbol]()
        if trait_name.byte_length() == 0:
            return out^
        for s in self.syms:
            if s.kind == SK_STRUCT and (trait_name in s.traits):
                out.append(s.copy())
        return out^

    def incoming_calls_of(self, func_name: String) -> List[IndexedSymbol]:
        """Scan indexed project files for call sites of `func_name(...)`, returning caller symbols at call sites."""
        var out = List[IndexedSymbol]()
        if func_name.byte_length() == 0:
            return out^
        var paths = List[String]()
        for s in self.syms:
            if s.path.byte_length() > 0 and not (s.path in paths):
                paths.append(s.path)
        for path in paths:
            var data = read_file(path)
            if len(data) == 0 or len(data) > INDEX_MAX_BYTES:
                continue
            var buf = TextBuffer()
            buf.load_bytes(data)
            var items = scan_outline(buf)
            var owners = owners_of(items)
            var in_doc = 0
            for r in range(buf.count()):
                var cps = buf.line(r)
                var n = len(cps)
                var started_doc = in_doc != 0
                var dq = 0
                while dq + 2 < n:
                    if (
                        (cps[dq] == 34 or cps[dq] == 39)
                        and cps[dq + 1] == cps[dq]
                        and cps[dq + 2] == cps[dq]
                        and (in_doc == 0 or in_doc == cps[dq])
                    ):
                        in_doc = cps[dq] if in_doc == 0 else 0
                        dq += 3
                    else:
                        dq += 1
                if started_doc:
                    continue
                var in_str = 0
                var i = 0
                while i < n:
                    var c = cps[i]
                    if in_str == 0 and c == 35:
                        break
                    if (c == 34 or c == 39) and (i == 0 or cps[i - 1] != 92):
                        if in_str == 0:
                            in_str = c
                        elif in_str == c:
                            in_str = 0
                        i += 1
                        continue
                    if in_str != 0:
                        i += 1
                        continue
                    if is_alpha(c) or c == 95:
                        var j = i + 1
                        while j < n and is_ident(cps[j]):
                            j += 1
                        var tok = slice_str(cps, i, j)
                        if (
                            tok == func_name
                            and not _is_decl_header(cps, i)
                            and _followed_by_call_paren(cps, j)
                        ):
                            var sp = scope_path(items, r)
                            var caller_name = String("<module>")
                            var caller_kind = SK_MODULE
                            var caller_owner = String("")
                            for sk in sp:
                                var ik = items[sk].kind
                                if ik == SK_FUNCTION or ik == SK_METHOD:
                                    caller_name = items[sk].name
                                    caller_kind = ik
                                    caller_owner = owners[sk]
                            out.append(IndexedSymbol(caller_name, caller_kind, path, r, i, caller_owner))
                        i = j
                    else:
                        i += 1
        return out^

    def outgoing_calls_of(self, path: String, func_name: String) -> List[IndexedSymbol]:
        """Scan `func_name`'s body in `path` for outgoing calls `callee(...)`, resolving against the index."""
        var out = List[IndexedSymbol]()
        if func_name.byte_length() == 0:
            return out^
        var target_path = path
        var data = read_file(target_path) if target_path.byte_length() > 0 else List[UInt8]()
        if len(data) == 0:
            for s in self.syms:
                if s.name == func_name and (s.kind == SK_FUNCTION or s.kind == SK_METHOD):
                    target_path = s.path
                    data = read_file(target_path)
                    if len(data) > 0:
                        break
        if len(data) == 0 or len(data) > INDEX_MAX_BYTES:
            return out^
        var buf = TextBuffer()
        buf.load_bytes(data)
        var items = scan_outline(buf)
        var seen_callees = List[String]()
        for idx in range(len(items)):
            if items[idx].name != func_name or (items[idx].kind != SK_FUNCTION and items[idx].kind != SK_METHOD):
                continue
            var head_row = items[idx].row
            var head_cps = buf.line(head_row)
            var base_ind = 0
            while base_ind < len(head_cps) and (head_cps[base_ind] == 32 or head_cps[base_ind] == 9):
                base_ind += 1
            var end_row = buf.count()
            for r in range(head_row + 1, buf.count()):
                var ln = buf.line(r)
                var ind = 0
                while ind < len(ln) and (ln[ind] == 32 or ln[ind] == 9):
                    ind += 1
                if ind >= len(ln) or ln[ind] == 35:
                    continue
                if ind <= base_ind:
                    end_row = r
                    break
            for r in range(head_row, end_row):
                var cps = buf.line(r)
                var n = len(cps)
                var start_i = 0
                if r == head_row:
                    # Only scan inline body after `:` on header line (e.g. `def ping(): pong()`)
                    var pdepth = 0
                    var colon_at = -1
                    for hi in range(n):
                        if cps[hi] == 40 or cps[hi] == 91:
                            pdepth += 1
                        elif cps[hi] == 41 or cps[hi] == 93:
                            pdepth = max(0, pdepth - 1)
                        elif cps[hi] == 58 and pdepth == 0:
                            colon_at = hi
                            break
                    if colon_at < 0:
                        continue
                    start_i = colon_at + 1
                var in_str = 0
                var i = start_i
                while i < n:
                    var c = cps[i]
                    if in_str == 0 and c == 35:
                        break
                    if (c == 34 or c == 39) and (i == 0 or cps[i - 1] != 92):
                        if in_str == 0:
                            in_str = c
                        elif in_str == c:
                            in_str = 0
                        i += 1
                        continue
                    if in_str != 0:
                        i += 1
                        continue
                    if is_alpha(c) or c == 95:
                        var j = i + 1
                        while j < n and is_ident(cps[j]):
                            j += 1
                        var tok = slice_str(cps, i, j)
                        if (
                            not _is_non_call_kw(tok)
                            and _followed_by_call_paren(cps, j)
                            and not (tok in seen_callees)
                        ):
                            seen_callees.append(tok)
                            var resolved = False
                            # Prefer target in same file first, then any indexed symbol
                            for pass_idx in range(2):
                                if resolved:
                                    break
                                for s in self.syms:
                                    if (
                                        s.name == tok
                                        and (s.kind == SK_FUNCTION or s.kind == SK_METHOD or s.kind == SK_STRUCT)
                                        and ((pass_idx == 0 and s.path == target_path) or pass_idx == 1)
                                    ):
                                        out.append(s.copy())
                                        resolved = True
                                        break
                            if not resolved:
                                out.append(IndexedSymbol(tok, SK_FUNCTION, target_path, r, i, ""))
                        i = j
                    else:
                        i += 1
        return out^


comptime FILES_MAX = 50000


struct FileIndex(Movable):
    """Every file of the project (what the ignore rules let through), listed a slice at
    a time."""
    var walk: FileSearch
    var root: String
    var building: Bool
    var built: Bool
    var built_ns: Int
    var files: List[String]
    var fresh: List[String]
    var truncated: Bool

    def __init__(out self):
        self.walk = FileSearch()
        self.root = ""
        self.building = False
        self.built = False
        self.built_ns = 0
        self.files = List[String]()
        self.fresh = List[String]()
        self.truncated = False

    def start(mut self, root: String):
        self.root = root
        self.walk.start(root, Search())
        self.walk.active = False
        self.fresh.clear()
        self.truncated = False
        self.building = True

    def step(mut self, budget_ms: Int):
        if not self.building:
            return
        var t0 = Int(perf_counter_ns())
        while True:
            if len(self.walk.files) > 0:
                var path = self.walk.files.pop()
                if len(self.fresh) < FILES_MAX:
                    self.fresh.append(path)
                else:
                    self.truncated = True
            elif len(self.walk.dirs) > 0:
                self.walk.list_next_dir()
            else:
                self.files = self.fresh.copy()
                self.fresh.clear()
                self.building = False
                self.built = True
                self.built_ns = Int(perf_counter_ns())
                return
            if (Int(perf_counter_ns()) - t0) // 1000000 >= budget_ms:
                return
