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
from util import decode, decode_list, to_str, read_file, join_path, slice_str, basename, path_exists, bytes_to_str

comptime MAX_HITS = 5000
comptime MAX_FILE_BYTES = 5 * 1024 * 1024
comptime MAX_DEPTH = 40
comptime MAX_TEXT = 200          # characters of a matching line kept for display


@fieldwise_init
struct IgnoreRule(Copyable, Movable):
    var base_dir: String
    var pattern: String
    var negated: Bool
    var dir_only: Bool
    var anchored: Bool


def trim_gitignore_line(raw: String) -> String:
    var s = raw
    if s.endswith("\r"):
        var trimmed_cr = String(s[byte=0:s.byte_length() - 1])
        s = trimmed_cr
    var n = s.byte_length()
    var bytes = s.as_bytes()
    while n > 0 and Int(bytes[n - 1]) == 32:
        if n >= 2 and Int(bytes[n - 2]) == 92:
            return String(s[byte=0:n - 2]) + " "
        n -= 1
    return String(s[byte=0:n])


def parse_gitignore_rules(base_dir: String, text: String, mut out: List[IgnoreRule]):
    """Parse `.gitignore` lines (supporting `*`, `**`, `?`, nested `/` paths, trailing `/`, and `!` negations)."""
    for raw_part in text.split("\n"):
        var line = trim_gitignore_line(String(raw_part))
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var negated = False
        if line.startswith("!"):
            negated = True
            var after_bang = String(line[byte=1:])
            line = after_bang
        elif line.startswith("\\#") or line.startswith("\\!"):
            var unesc = String(line[byte=1:])
            line = unesc
        if line.byte_length() == 0:
            continue
        var dir_only = False
        if line.endswith("/"):
            dir_only = True
            while line.endswith("/"):
                var no_trail = String(line[byte=0:line.byte_length() - 1])
                line = no_trail
        if line.byte_length() == 0:
            continue
        var had_lead = False
        if line.startswith("/"):
            had_lead = True
            while line.startswith("/"):
                var no_lead = String(line[byte=1:])
                line = no_lead
        if line.byte_length() == 0:
            continue
        var anchored = had_lead or (line.find("/") >= 0)
        out.append(IgnoreRule(base_dir, line, negated, dir_only, anchored))


def glob_match_from(pat: List[Int], pi_in: Int, text: List[Int], ti_in: Int, slash_stops: Bool) -> Bool:
    """Iterative/backtracking glob matcher supporting `*`, `**`, and `?`."""
    var pi = pi_in
    var ti = ti_in
    var pn = len(pat)
    var tn = len(text)
    var star_pi = -1
    var star_ti = -1
    var star_cross_slash = False
    while ti < tn:
        if pi < pn and pat[pi] == 42:
            var cross = False
            while pi < pn and pat[pi] == 42:
                if pi + 1 < pn and pat[pi + 1] == 42:
                    cross = True
                pi += 1
            if cross:
                if pi < pn and pat[pi] == 47 and glob_match_from(pat, pi + 1, text, ti, slash_stops):
                    return True
                var k = ti
                while k <= tn:
                    if glob_match_from(pat, pi, text, k, slash_stops):
                        return True
                    k += 1
                return False
            star_pi = pi
            star_ti = ti
            star_cross_slash = not slash_stops
            continue
        if pi < pn and ((pat[pi] == 63 and (not slash_stops or text[ti] != 47)) or pat[pi] == text[ti]):
            pi += 1
            ti += 1
            continue
        if star_pi >= 0 and (star_cross_slash or text[star_ti] != 47):
            star_ti += 1
            ti = star_ti
            pi = star_pi
            continue
        return False
    while pi < pn and pat[pi] == 42:
        pi += 1
    return pi == pn


def rule_matches_rel(rule: IgnoreRule, rel: String, is_dir: Bool) -> Bool:
    if not rule.dir_only or is_dir:
        if rule.anchored:
            if glob_match(rule.pattern, rel):
                return True
        else:
            var base = basename(rel)
            if glob_match(rule.pattern, base) or glob_match(rule.pattern, rel):
                return True
    if not rule.negated and rel.find("/") >= 0:
        var pos = 0
        var n = rel.byte_length()
        while pos < n:
            var sl = rel.find("/", pos)
            if sl < 0:
                break
            var anc = String(rel[byte=0:sl])
            if rule.anchored:
                if glob_match(rule.pattern, anc):
                    return True
            else:
                if glob_match(rule.pattern, basename(anc)) or glob_match(rule.pattern, anc):
                    return True
            pos = sl + 1
    return False


def glob_match(pat: String, text: String) -> Bool:
    var pc = decode(pat)
    var tc = decode(text)
    var has_slash = 47 in pc
    return glob_match_from(pc, 0, tc, 0, has_slash)


def file_matches_filter(root: String, path: String, filter_glob: String) -> Bool:
    """True when `path` satisfies comma- or space-separated include/!exclude globs."""
    var fg = String(filter_glob.strip())
    if fg.byte_length() == 0:
        return True
    var rel = path
    var prefix = root + "/"
    if path.startswith(prefix):
        rel = String(path[byte=prefix.byte_length():])
    var base = basename(rel)
    var inc = List[String]()
    var exc = List[String]()
    var raw_parts = fg.split(",") if fg.find(",") >= 0 else fg.split(" ")
    for rp in raw_parts:
        var tok = String(String(rp).strip())
        if tok.byte_length() == 0:
            continue
        if tok.startswith("!"):
            var p = String(String(tok[byte=1:]).strip())
            if p.byte_length() > 0:
                exc.append(p)
        else:
            inc.append(tok)
    for p in exc:
        var pat = p
        if pat.startswith("./"):
            var t = String(pat[byte=2:])
            pat = t
        if pat.endswith("/"):
            if rel.startswith(pat) or rel.find("/" + pat) >= 0:
                return False
        elif pat.find("/") >= 0:
            if glob_match(pat, rel):
                return False
        else:
            if glob_match(pat, base) or glob_match(pat, rel):
                return False
    if len(inc) == 0:
        return True
    for p in inc:
        var pat = p
        if pat.startswith("./"):
            var t = String(pat[byte=2:])
            pat = t
        if pat.endswith("/"):
            if rel.startswith(pat) or rel.find("/" + pat) >= 0:
                return True
        elif pat.find("/") >= 0:
            if glob_match(pat, rel):
                return True
        else:
            if glob_match(pat, base) or glob_match(pat, rel):
                return True
    return False


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
    var filter_glob: String
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
    var ignore_root: String
    var ignore_rules: List[IgnoreRule]
    var loaded_gitignores: List[String]
    var overlay_paths: List[String]
    var overlay_bytes: List[List[UInt8]]

    def __init__(out self):
        self.s = Search()
        self.root = ""
        self.filter_glob = ""
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
        self.ignore_root = ""
        self.ignore_rules = List[IgnoreRule]()
        self.loaded_gitignores = List[String]()
        self.overlay_paths = List[String]()
        self.overlay_bytes = List[List[UInt8]]()

    def clear_overlays(mut self):
        self.overlay_paths.clear()
        self.overlay_bytes.clear()

    def set_overlay(mut self, path: String, var data: List[UInt8]):
        for i in range(len(self.overlay_paths)):
            if self.overlay_paths[i] == path:
                self.overlay_bytes[i] = data^
                return
        self.overlay_paths.append(path)
        self.overlay_bytes.append(data^)

    def load_subdir_gitignore(mut self, dir: String):
        """Load `<dir>/.gitignore` once if present, appending scoped rules for `dir`."""
        if dir.byte_length() == 0 or dir in self.loaded_gitignores:
            return
        self.loaded_gitignores.append(dir)
        var gi_path = join_path(dir, ".gitignore")
        if not path_exists(gi_path):
            return
        var txt = bytes_to_str(read_file(gi_path))
        parse_gitignore_rules(dir, txt, self.ignore_rules)

    def load_gitignore(mut self, root: String):
        """Reset and load root `.gitignore` rules (wildcards, nested paths, `!` negations)."""
        self.ignore_names.clear()
        self.ignore_exts.clear()
        self.ignore_names.append("node_modules")
        self.ignore_names.append("__pycache__")
        self.ignore_root = root
        self.ignore_rules.clear()
        self.loaded_gitignores.clear()
        self.load_subdir_gitignore(root)

    def ignored_path(self, full_path: String, is_dir: Bool) -> Bool:
        var name = basename(full_path)
        if name == ".git":
            return True
        var matched = name.startswith(".")
        for n in self.ignore_names:
            if n == name:
                matched = True
        for e in self.ignore_exts:
            if name.endswith(e):
                matched = True
        var root_base = self.ignore_root if self.ignore_root.byte_length() > 0 else self.root
        if root_base.byte_length() > 0 and full_path.startswith(root_base + "/"):
            var rel_root = String(full_path[byte=root_base.byte_length() + 1:])
            for seg_slice in rel_root.split("/"):
                var seg = String(seg_slice)
                if seg == ".git":
                    return True
                if seg.startswith(".") or seg == "node_modules" or seg == "__pycache__":
                    matched = True
        for i in range(len(self.ignore_rules)):
            ref rule = self.ignore_rules[i]
            var rel = full_path
            if rule.base_dir.byte_length() > 0:
                var prefix = rule.base_dir + "/"
                if not full_path.startswith(prefix):
                    continue
                rel = String(full_path[byte=prefix.byte_length():])
            if rule_matches_rel(rule, rel, is_dir):
                matched = not rule.negated
        return matched

    def ignored(self, name: String) -> Bool:
        if name == ".git":
            return True
        var root_base = self.ignore_root if self.ignore_root.byte_length() > 0 else self.root
        if root_base.byte_length() > 0 and not name.startswith("/"):
            return self.ignored_path(join_path(root_base, name), True)
        return self.ignored_path(name, True)

    def start(mut self, root: String, s: Search, filter_glob: String = ""):
        self.s = s.copy()
        self.root = root
        self.filter_glob = String(filter_glob.strip())
        self.truncated = False
        self.cancelled = False
        self.dirs.clear()
        self.depths.clear()
        self.files.clear()
        self.hits.clear()
        self.files_done = 0
        self.files_matched = 0
        self.files_skipped = 0
        self.clear_overlays()
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
        if dir != self.root:
            self.load_subdir_gitignore(dir)
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
            var p = join_path(dir, n)
            var is_d = isdir(p)
            if self.ignored_path(p, is_d):
                continue
            if is_d:
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
        if self.filter_glob.byte_length() > 0 and not file_matches_filter(self.root, path, self.filter_glob):
            return
        var data = List[UInt8]()
        var overlaid = False
        for oi in range(len(self.overlay_paths)):
            if self.overlay_paths[oi] == path:
                data = self.overlay_bytes[oi].copy()
                overlaid = True
                break
        if not overlaid:
            data = read_file(path)
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


def collect_search_files(root: String, filter_glob: String) -> List[String]:
    """Return non-ignored files under `root` matching `filter_glob` in deterministic order."""
    var fs = FileSearch()
    fs.root = root
    fs.filter_glob = String(filter_glob.strip())
    fs.load_gitignore(root)
    fs.dirs.append(root)
    fs.depths.append(0)
    var out = List[String]()
    var guard = 0
    while (len(fs.files) > 0 or len(fs.dirs) > 0) and guard < 200000:
        guard += 1
        if len(fs.files) > 0:
            var p = fs.files.pop()
            if fs.filter_glob.byte_length() == 0 or file_matches_filter(root, p, fs.filter_glob):
                out.append(p)
        elif len(fs.dirs) > 0:
            fs.list_next_dir()
    return out^
