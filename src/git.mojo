"""Git, as the editor sees it: which repository a file is in, what `git status` says
about the files (for the explorer), and the commands that ask git for them.

Everything comes from `git` subprocesses with machine-readable output; nothing here
runs one (the app does, in the background). `git status --porcelain=v2 -z` lines
(verified with git 2.4x):

    # branch.head main
    1 .M N... 100644 100644 100644 <hash> <hash> src/a.mojo
    1 A. N... 000000 100644 100644 <hash> <hash> new.mojo
    2 R. N... 100644 100644 100644 <hash> <hash> R100 b.mojo<NUL>old_b.mojo
    u UU N... 100644 100644 100644 100644 <h1> <h2> <h3> c.mojo
    ? notes.txt
    ? build/            (a folder nothing in which is tracked)
"""
from std.collections import List, Dict
from util import join_path, dirname, path_exists, shell_quote

comptime GS_NONE = 0
comptime GS_UNTRACKED = 1
comptime GS_ADDED = 2
comptime GS_RENAMED = 3
comptime GS_MODIFIED = 4
comptime GS_DELETED = 5
comptime GS_CONFLICT = 6     # the most urgent: a folder shows the most urgent of its files

# what TextBuffer.git_state says about the file's version in the index
comptime GB_UNKNOWN = 0      # not asked yet (or to be asked again)
comptime GB_ASKED = 1
comptime GB_KNOWN = 2        # git_base holds it
comptime GB_NONE = 3         # not in a repository, or not tracked: no markers


def find_repo(path: String) -> String:
    """The work tree `path` (a file or folder) is in: the nearest folder upwards that has
    a `.git` (a folder, or a file in a linked work tree). '' if there is none."""
    var d = path
    for _ in range(256):
        if d.byte_length() == 0:
            return ""
        if path_exists(join_path(d, ".git")):
            return d
        var up = dirname(d)
        if up == d or up.byte_length() == 0:
            return ""
        d = up
    return ""


def rel_to(root: String, path: String) -> String:
    """`path` relative to `root` ('' if it is not inside it)."""
    if root.byte_length() == 0 or not path.startswith(root):
        return ""
    var rest = String(path[byte=root.byte_length():])
    if rest.startswith("/"):
        return String(rest[byte=1:])
    if root.endswith("/"):
        return rest
    return ""


def status_command(root: String) -> String:
    return ("git -C " + shell_quote(root) + " -c core.fsmonitor=false --no-optional-locks status --porcelain=v2 -z --branch"
            + " --untracked-files=normal")


def base_command(root: String, rel: String) -> String:
    """The file as it is in the index (staged), with the work tree's line-end and filter
    conversions applied so it compares with the file on disk."""
    return "git -C " + shell_quote(root) + " --no-optional-locks cat-file --filters " + shell_quote(":" + rel)


def code_of_xy(kind: String, xy: String) -> Int:
    if kind == "u":
        return GS_CONFLICT
    if kind == "2":
        return GS_RENAMED
    var x = String(xy[byte=0:1])
    var y = String(xy[byte=1:2])
    if x == "D" or y == "D":
        return GS_DELETED
    if x == "A":
        return GS_ADDED
    return GS_MODIFIED


def status_letter(code: Int) -> String:
    if code == GS_UNTRACKED:
        return "U"
    if code == GS_ADDED:
        return "A"
    if code == GS_RENAMED:
        return "R"
    if code == GS_MODIFIED:
        return "M"
    if code == GS_DELETED:
        return "D"
    if code == GS_CONFLICT:
        return "C"
    return ""


def after_fields(entry: String, n: Int) -> String:
    """What follows the first n space-separated fields (a path may contain spaces)."""
    var at = 0
    for _ in range(n):
        var sp = entry.find(" ", at)
        if sp < 0:
            return ""
        at = sp + 1
    return String(entry[byte=at:])


struct GitStatus(Copyable, Movable):
    var root: String
    var branch: String              # '' when not known; "(detached)" off a branch
    var files: Dict[String, Int]    # absolute path -> GS_*
    var dirs: Dict[String, Int]     # folders with changes in them -> the most urgent
    var untracked_dirs: List[String]  # folders nothing in which is tracked (absolute, no /)

    def __init__(out self):
        self.root = ""
        self.branch = ""
        self.files = Dict[String, Int]()
        self.dirs = Dict[String, Int]()
        self.untracked_dirs = List[String]()

    def clear(mut self):
        self.branch = ""
        self.files = Dict[String, Int]()
        self.dirs = Dict[String, Int]()
        self.untracked_dirs.clear()

    def note_dirs(mut self, path: String, code: Int):
        """Every folder from `path`'s up to the root has at least `code`."""
        var d = dirname(path)
        for _ in range(256):
            if d.byte_length() <= self.root.byte_length() or d == self.root:
                return
            var have = self.dirs.get(d, GS_NONE)
            if have >= code:
                # its folders above have it too (they were given it with it)
                return
            self.dirs[d] = code
            d = dirname(d)

    def parse(mut self, data: String):
        """Take in `git status --porcelain=v2 -z --branch` output."""
        self.clear()
        var parts = data.split("\0")
        var k = 0
        var n = len(parts)
        while k < n:
            var e = String(parts[k])
            k += 1
            if e.byte_length() < 2:
                continue
            if e.startswith("# branch.head "):
                self.branch = String(e[byte=14:])
                continue
            if e.startswith("#") or e.startswith("! "):
                continue
            var kind = String(e[byte=0:1])
            var rel: String
            var code: Int
            if kind == "?":
                rel = String(e[byte=2:])
                code = GS_UNTRACKED
            elif kind == "1" or kind == "2" or kind == "u":
                var xy = String(e[byte=2:4])
                code = code_of_xy(kind, xy)
                rel = after_fields(e, 8 if kind == "1" else (9 if kind == "2" else 10))
                if kind == "2":
                    k += 1          # the name it had before follows
            else:
                continue
            if rel.byte_length() == 0:
                continue
            if rel.endswith("/"):
                var d = join_path(self.root, String(rel[byte=0:rel.byte_length() - 1]))
                self.untracked_dirs.append(d)
                self.dirs[d] = max(self.dirs.get(d, GS_NONE), GS_UNTRACKED)
                self.note_dirs(d, GS_UNTRACKED)
                continue
            var p = join_path(self.root, rel)
            self.files[p] = code
            self.note_dirs(p, code)

    def code_of(self, path: String) -> Int:
        """GS_* for a file or folder (a folder: the most urgent thing in it)."""
        var c = self.files.get(path, GS_NONE)
        if c != GS_NONE:
            return c
        c = self.dirs.get(path, GS_NONE)
        if c != GS_NONE:
            return c
        for d in self.untracked_dirs:
            if path.startswith(d + "/"):
                return GS_UNTRACKED
        return GS_NONE

    def changed_count(self) -> Int:
        return len(self.files)


def head_command(root: String, rel: String) -> String:
    """The file as in the last commit (fails for a file the commit does not have)."""
    return "git -C " + shell_quote(root) + " --no-optional-locks cat-file --filters " + shell_quote("HEAD:" + rel)
