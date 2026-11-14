"""An index of the symbols (functions, structs, traits, constants) of every Mojo file of
the project, built a slice at a time so the editor never waits for it."""
from std.collections import List
from std.time import perf_counter_ns
from buffer import TextBuffer
from grep import FileSearch
from search import Search
from outline import OutlineItem, scan_outline, outline_tag
from util import read_file

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
            if len(into) >= INDEX_MAX_SYMBOLS:
                self.truncated = True
                return
            into.append(IndexedSymbol(items[k].name, items[k].kind, path, items[k].row, items[k].col, owners[k]))

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
