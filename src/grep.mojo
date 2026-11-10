"""Find in files: walks a folder and searches every text file, a little at a time so the
editor stays responsive (call `step` from the event loop until `done`).

What is skipped: hidden files and folders (names starting with "."), node_modules and
__pycache__, names listed in the folder's .gitignore (simple entries only: "name",
"name/", "/name", "*.ext"), symbolic links to folders, binary files (a NUL byte in the
first 4 KB) and files larger than 5 MB. Files are read from disk: unsaved changes in open
windows are not seen."""
from std.collections import List
from std.os import listdir
from std.os.path import isdir, islink
from std.time import perf_counter_ns
from search import Search
from util import decode, decode_list, to_str, read_file, join_path, slice_str

comptime MAX_HITS = 5000
comptime MAX_FILE_BYTES = 5 * 1024 * 1024
comptime MAX_DEPTH = 40
comptime MAX_TEXT = 200          # characters of a matching line kept for display


struct Hit(Copyable, Movable):
    var path: String      # as walked: root joined with the relative path
    var row: Int          # 1-based
    var col: Int          # 1-based, start of the first match on the line
    var text: String      # the line, without leading blanks, cut to MAX_TEXT

    def __init__(out self, path: String, row: Int, col: Int, text: String):
        self.path = path
        self.row = row
        self.col = col
        self.text = text


def sort_names(mut names: List[String]):
    """Plain insertion sort by bytes: directory listings arrive in no particular order."""
    for i in range(1, len(names)):
        var j = i
        while j > 0 and names[j] < names[j - 1]:
            var t = names[j - 1]
            names[j - 1] = names[j]
            names[j] = t
            j -= 1


def is_binary(data: List[UInt8]) -> Bool:
    for i in range(min(len(data), 4096)):
        if data[i] == 0:
            return True
    return False


struct FileSearch(Movable):
    var s: Search
    var root: String
    var active: Bool           # a search has been started and is not finished
    var truncated: Bool        # stopped at MAX_HITS
    var cancelled: Bool
    var dirs: List[String]     # folders still to list (a stack)
    var depths: List[Int]
    var files: List[String]    # files of the folder being worked on, still to search
    var hits: List[Hit]
    var files_done: Int
    var files_matched: Int
    var files_skipped: Int
    var ignore_names: List[String]
    var ignore_exts: List[String]

    def __init__(out self):
        self.s = Search()
        self.root = ""
        self.active = False
        self.truncated = False
        self.cancelled = False
        self.dirs = List[String]()
        self.depths = List[Int]()
        self.files = List[String]()
        self.hits = List[Hit]()
        self.files_done = 0
        self.files_matched = 0
        self.files_skipped = 0
        self.ignore_names = List[String]()
        self.ignore_exts = List[String]()

    def load_gitignore(mut self, root: String):
        """Take the simple entries of root/.gitignore; anything with other wildcards,
        nested paths or negation is left out (those files are then searched)."""
        self.ignore_names.clear()
        self.ignore_exts.clear()
        self.ignore_names.append("node_modules")
        self.ignore_names.append("__pycache__")
        var data = decode_list(read_file(join_path(root, ".gitignore")))
        data.append(10)
        var cur = List[Int]()
        for c in data:
            if c != 10:
                if c != 13:
                    cur.append(c)
                continue
            var a = 0
            var b = len(cur)
            while b > a and cur[b - 1] == 32:
                b -= 1
            if b > a and cur[a] == 47:
                a += 1
            if b > a and cur[b - 1] == 47:
                b -= 1
            var ok = b > a and cur[a] != 35 and cur[a] != 33
            var ext = False
            if ok and b - a > 2 and cur[a] == 42 and cur[a + 1] == 46:
                ext = True
                a += 1                      # keep ".ext"
            if ok:
                for k in range(a, b):
                    if cur[k] == 47 or cur[k] == 42 or cur[k] == 63 or cur[k] == 91:
                        ok = False
            if ok:
                if ext:
                    self.ignore_exts.append(slice_str(cur, a, b))
                else:
                    self.ignore_names.append(slice_str(cur, a, b))
            cur.clear()

    def ignored(self, name: String) -> Bool:
        if name.startswith("."):
            return True
        for n in self.ignore_names:
            if n == name:
                return True
        for e in self.ignore_exts:
            if name.endswith(e):
                return True
        return False

    def start(mut self, root: String, s: Search):
        self.s = s.copy()
        self.root = root
        self.truncated = False
        self.cancelled = False
        self.dirs.clear()
        self.depths.clear()
        self.files.clear()
        self.hits.clear()
        self.files_done = 0
        self.files_matched = 0
        self.files_skipped = 0
        self.load_gitignore(root)
        self.dirs.append(root)
        self.depths.append(0)
        self.active = s.ok

    def cancel(mut self):
        if self.active:
            self.active = False
            self.cancelled = True

    def done(self) -> Bool:
        return not self.active

    def list_next_dir(mut self):
        var dir = self.dirs.pop()
        var depth = self.depths.pop()
        var names = List[String]()
        try:
            for n in listdir(dir):
                names.append(String(n))
        except:
            return                          # unreadable folder
        sort_names(names)
        var subdirs = List[String]()
        var files = List[String]()
        for n in names:
            if self.ignored(n):
                continue
            var p = join_path(dir, n)
            if isdir(p):
                if not islink(p) and depth < MAX_DEPTH:
                    subdirs.append(p)
            else:
                files.append(p)
        # files of this folder first, then its subfolders in name order
        var i = len(subdirs) - 1
        while i >= 0:
            self.dirs.append(subdirs[i])
            self.depths.append(depth + 1)
            i -= 1
        i = len(files) - 1
        while i >= 0:
            self.files.append(files[i])     # popped from the end: keep name order
            i -= 1

    def search_file(mut self, path: String):
        var data = read_file(path)
        if len(data) > MAX_FILE_BYTES or is_binary(data):
            self.files_skipped += 1
            return
        self.files_done += 1
        var n = len(data)
        var start = 0
        var row = 1
        var matched = False
        var i = 0
        while i <= n:
            if i < n and data[i] != 10:
                i += 1
                continue
            var end = i
            if end > start and data[end - 1] == 13:
                end -= 1
            if end > start:
                var bytes = List[UInt8]()
                for k in range(start, end):
                    bytes.append(data[k])
                var ln = decode_list(bytes)
                var m = self.s.caps_in(ln, 0)
                if len(m) > 0:
                    matched = True
                    var a = 0
                    while a < len(ln) and (ln[a] == 32 or ln[a] == 9):
                        a += 1
                    self.hits.append(Hit(path, row, m[0] + 1, slice_str(ln, a, min(len(ln), a + MAX_TEXT))))
                    if len(self.hits) >= MAX_HITS:
                        self.truncated = True
                        self.active = False
                        break
            start = i + 1
            row += 1
            i += 1
        if matched:
            self.files_matched += 1

    def step(mut self, budget_ms: Int):
        """Do some of the work: at least one file or folder, then more until about
        `budget_ms` milliseconds have passed."""
        if not self.active:
            return
        var t0 = Int(perf_counter_ns())
        while self.active:
            if len(self.files) > 0:
                self.search_file(self.files.pop())
            elif len(self.dirs) > 0:
                self.list_next_dir()
            else:
                self.active = False
                break
            if (Int(perf_counter_ns()) - t0) // 1000000 >= budget_ms:
                break

    def summary(self) -> String:
        var n = len(self.hits)
        var s = String(n) + (" matching line" if n == 1 else " matching lines")
        s += " in " + String(self.files_matched) + (" file" if self.files_matched == 1 else " files")
        s += " (" + String(self.files_done) + " searched"
        if self.files_skipped > 0:
            s += ", " + String(self.files_skipped) + " binary or too large"
        s += ")"
        if self.truncated:
            s += " - stopped after " + String(MAX_HITS)
        elif self.cancelled:
            s += " - cancelled"
        return s
