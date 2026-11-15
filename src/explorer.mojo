"""The file explorer's model: the project folder as a tree of which only the opened
folders are listed, and the file operations (create, rename, move, delete to trash)."""
from util import lower_str, str_contains
from platform import IS_MACOS
from glyphs import nerd_file_icon
from std.collections import List
from std.os import listdir
from std.os.path import isdir, islink
from grep import FileSearch, sort_names
from util import (
    decode, to_str, join_path, dirname, basename, path_exists, is_dir, shell_quote, run_system,
    run_capture, bytes_to_str, write_file, env_or, str_bytes,
)

comptime EX_MAX_ROWS = 5000


@fieldwise_init
struct ExRow(Copyable, Movable):
    var path: String
    var name: String
    var depth: Int
    var dir: Bool
    var open: Bool          # a folder whose content is listed below it


struct ExplorerTree(Movable):
    var root: String
    var rows: List[ExRow]           # what is visible, top to bottom
    var opened: List[String]        # folders that are open (the root always is)
    var show_all: Bool              # also what .gitignore and the dot rule hide (never .git)
    var rules: FileSearch           # used for its ignore rules
    var cut: Bool                   # more rows than EX_MAX_ROWS: the list was cut
    var filter: String              # only names containing this (any case), with their folders
    var hidden_rows: Int            # rows the filter left out

    def __init__(out self):
        self.root = ""
        self.rows = List[ExRow]()
        self.opened = List[String]()
        self.show_all = False
        self.rules = FileSearch()
        self.cut = False
        self.filter = ""
        self.hidden_rows = 0

    def set_root(mut self, root: String):
        self.root = root
        self.opened.clear()
        self.rules.load_gitignore(root)
        self.rebuild()

    def is_open(self, path: String) -> Bool:
        return path in self.opened

    def hidden(self, name: String) -> Bool:
        if name == ".git":
            return True
        if self.show_all:
            return False
        return self.rules.ignored(name)

    def hidden_path(self, path: String, name: String, is_dir: Bool) -> Bool:
        if name == ".git":
            return True
        if self.show_all:
            return False
        return self.rules.ignored_path(path, is_dir)

    def list_folder(mut self, dir: String, depth: Int):
        if dir != self.root:
            self.rules.load_subdir_gitignore(dir)
        var names = List[String]()
        try:
            for n in listdir(dir):
                names.append(String(n))
        except:
            return                          # unreadable: shown as empty
        sort_names(names)
        var dirs = List[String]()
        var files = List[String]()
        for n in names:
            var p = join_path(dir, n)
            var is_d = isdir(p)
            if self.hidden_path(p, n, is_d):
                continue
            if is_d:
                dirs.append(n)
            else:
                files.append(n)
        for n in dirs:
            if len(self.rows) >= EX_MAX_ROWS:
                self.cut = True
                return
            var p = join_path(dir, n)
            # a link to a folder is shown but not followed (it could lead in a circle)
            var open = self.is_open(p) and not islink(p)
            self.rows.append(ExRow(p, n, depth, True, open))
            if open:
                self.list_folder(p, depth + 1)
        for n in files:
            if len(self.rows) >= EX_MAX_ROWS:
                self.cut = True
                return
            self.rows.append(ExRow(join_path(dir, n), n, depth, False, False))

    def rebuild(mut self):
        """List the root and every open folder again."""
        self.rows.clear()
        self.cut = False
        var r0 = self.root
        self.rules.load_gitignore(r0)
        if self.root.byte_length() > 0:
            var root = self.root
            self.list_folder(root, 0)
        # folders that are gone are no longer open
        var kept = List[String]()
        for o in self.opened:
            if is_dir(o):
                kept.append(o)
        self.opened = kept^
        self.apply_filter()

    def apply_filter(mut self):
        """Keep the rows whose name contains the filter, and the folders above them
        (a folder whose name matches keeps its listed content too)."""
        self.hidden_rows = 0
        if self.filter.byte_length() == 0:
            return
        var f = lower_str(self.filter)
        var n = len(self.rows)
        var keep = List[Bool](length=n, fill=False)
        var below = List[Bool]()            # by depth: a kept row under the folder being closed
        for _ in range(66):
            below.append(False)
        # a matching folder keeps what is listed inside it: mark those first
        var inside = -1                     # depth of the matching folder we are in (-1 none)
        for k in range(n):
            var d = self.rows[k].depth
            if inside >= 0 and d <= inside:
                inside = -1
            if inside >= 0:
                keep[k] = True
            elif str_contains(lower_str(self.rows[k].name), f):
                keep[k] = True
                if self.rows[k].dir:
                    inside = d
        # folders with something kept below them, from the bottom up
        var k = n - 1
        while k >= 0:
            var d = min(self.rows[k].depth, 64)
            if self.rows[k].dir and below[d + 1]:
                keep[k] = True
            below[d + 1] = False
            if keep[k]:
                below[d] = True
            k -= 1
        var out = List[ExRow]()
        for j in range(n):
            if keep[j]:
                out.append(self.rows[j].copy())
        self.hidden_rows = n - len(out)
        self.rows = out^

    def toggle(mut self, k: Int):
        """Open or close the folder on row k."""
        if k < 0 or k >= len(self.rows) or not self.rows[k].dir:
            return
        var p = self.rows[k].path
        if self.is_open(p):
            var kept = List[String]()
            for o in self.opened:
                if o != p:
                    kept.append(o)
            self.opened = kept^
        else:
            self.opened.append(p)
        self.rebuild()

    def reveal(mut self, path: String) -> Int:
        """Open the folders that lead to `path` (inside the root) and return its row
        (-1 if it is not shown, for instance because it is ignored)."""
        var prefix = self.root + "/"
        if not path.startswith(prefix):
            return -1
        var d = dirname(path)
        var changed = False
        while d.byte_length() > len(self.root.as_bytes()) and d.startswith(prefix):
            if not self.is_open(d):
                self.opened.append(d)
                changed = True
            d = dirname(d)
        if changed:
            self.rebuild()
        return self.row_of(path)

    def row_of(self, path: String) -> Int:
        for k in range(len(self.rows)):
            if self.rows[k].path == path:
                return k
        return -1

    def parent_row(self, k: Int) -> Int:
        if k < 0 or k >= len(self.rows):
            return -1
        var j = k - 1
        while j >= 0:
            if self.rows[j].depth < self.rows[k].depth:
                return j
            j -= 1
        return -1

    def folder_for(self, k: Int) -> String:
        """Where something new goes when row k is marked: into that folder if it is an
        open one, else beside it."""
        if k < 0 or k >= len(self.rows):
            return self.root
        if self.rows[k].dir and self.rows[k].open:
            return self.rows[k].path
        return dirname(self.rows[k].path)

    def line(self, k: Int, icons: Bool = False) -> String:
        """Row k as shown: indented, an arrow on a folder; with `icons` (ui.glyphs =
        "nerd") a Nerd Font icon before the name."""
        var s = String("")
        for _ in range(self.rows[k].depth):
            s += "  "
        if self.rows[k].dir:
            s += ("▾ " if self.rows[k].open else "▸ ")
        else:
            s += "  "
        if icons:
            s += chr(nerd_file_icon(self.rows[k].name, self.rows[k].dir, self.rows[k].open)) + " "
        return s + self.rows[k].name


# ------------------------------------------------------------ file operations
def name_problem(name: String) -> String:
    """'' if `name` can be the name of a file or folder, else what is wrong with it."""
    if name.byte_length() == 0:
        return "A name is needed"
    if name == "." or name == "..":
        return "That name is taken by the system"
    for c in decode(name):
        if c == 47 or c == 0 or c == 10:
            return "A name cannot contain a slash or a line break"
    return ""


def inside(root: String, path: String) -> Bool:
    return path == root or path.startswith(root + "/")


def make_file(dir: String, name: String) -> String:
    """Create an empty file. Returns '' or why not."""
    var bad = name_problem(name)
    if bad.byte_length() > 0:
        return bad
    var p = join_path(dir, name)
    if path_exists(p):
        return name + " exists already"
    if not write_file(p, List[UInt8]()):
        return "Cannot create " + name
    return ""


def make_folder(dir: String, name: String) -> String:
    var bad = name_problem(name)
    if bad.byte_length() > 0:
        return bad
    var p = join_path(dir, name)
    if path_exists(p):
        return name + " exists already"
    if run_system("mkdir -- " + shell_quote(p) + " 2>/dev/null") != 0:
        return "Cannot create the folder " + name
    return ""


def move_path(src: String, dst: String) -> String:
    """Rename or move a file or folder; never over something that exists."""
    if not path_exists(src):
        return basename(src) + " is no longer there"
    if path_exists(dst):
        return basename(dst) + " exists already"
    if inside(src, dst):
        return "A folder cannot be moved into itself"
    if not is_dir(dirname(dst)):
        return "The folder " + dirname(dst) + " does not exist"
    if run_system("mv -- " + shell_quote(src) + " " + shell_quote(dst) + " 2>/dev/null") != 0:
        return "Cannot move " + basename(src)
    return ""


def default_trash_dir() -> String:
    """The desktop's trash folder: ~/.Trash on macOS; $XDG_DATA_HOME/Trash
    (~/.local/share/Trash) on Linux."""
    var home = env_or("HOME", "")
    if home.byte_length() == 0:
        return ""
    comptime if IS_MACOS:
        return home + "/.Trash"
    else:
        var data = env_or("XDG_DATA_HOME", "")
        if data.byte_length() == 0:
            data = home + "/.local/share"
        return data + "/Trash"


def trash_path(path: String, trash: String) -> String:
    """Move a file or folder to the trash: on macOS (~/.Trash), moved directly;
    on Linux, into `trash`/files under a free name with `trash`/info/<name>.trashinfo.
    Returns '' or why not; nothing is ever deleted outright."""
    if not path_exists(path):
        return basename(path) + " is no longer there"
    if trash.byte_length() == 0:
        return "No trash folder is known (HOME is not set)"
    if inside(path, trash):
        return "The trash folder is inside what would be deleted"
    # macOS ~/.Trash layout: direct placement without files/ and info/ subdirectories
    if trash.endswith("/.Trash"):
        if run_system("mkdir -p -- " + shell_quote(trash) + " 2>/dev/null") != 0:
            return "Cannot use the trash folder " + trash
        var name = basename(path)
        var target = name
        var n = 1
        while path_exists(trash + "/" + target):
            n += 1
            target = name + "." + String(n)
        if run_system("mv -- " + shell_quote(path) + " " + shell_quote(trash + "/" + target) + " 2>/dev/null") != 0:
            return "Cannot move " + name + " to the trash"
        return ""
    # Linux freedesktop.org trash layout
    if run_system("mkdir -p -- " + shell_quote(trash + "/files") + " " + shell_quote(trash + "/info") + " 2>/dev/null") != 0:
        return "Cannot use the trash folder " + trash
    var name = basename(path)
    var target = name
    var n = 1
    while path_exists(trash + "/files/" + target) or path_exists(trash + "/info/" + target + ".trashinfo"):
        n += 1
        target = name + "." + String(n)
    var stamp = String(bytes_to_str(run_capture("date +%Y-%m-%dT%H:%M:%S").out).strip())
    var info = "[Trash Info]\nPath=" + path + "\nDeletionDate=" + stamp + "\n"
    if not write_file(trash + "/info/" + target + ".trashinfo", str_bytes(info)):
        return "Cannot write to the trash folder " + trash
    if run_system("mv -- " + shell_quote(path) + " " + shell_quote(trash + "/files/" + target) + " 2>/dev/null") != 0:
        _ = run_system("rm -f -- " + shell_quote(trash + "/info/" + target + ".trashinfo"))
        return "Cannot move " + name + " to the trash"
    return ""
