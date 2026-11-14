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
from util import join_path, dirname, path_exists, shell_quote, decode

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
    """The file as it is in the index (staged), or stage 2 (ours) during an unmerged
    conflict, with the work tree's line-end and filter conversions applied."""
    var q = shell_quote(root)
    var c0 = "git -C " + q + " --no-optional-locks cat-file --filters " + shell_quote(":" + rel)
    var c2 = "git -C " + q + " --no-optional-locks cat-file --filters " + shell_quote(":2:" + rel)
    return sh_script(c0 + " 2>/dev/null || " + c2 + " 2>/dev/null")


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
    var ahead: Int
    var behind: Int
    var files: Dict[String, Int]    # absolute path -> GS_*
    var dirs: Dict[String, Int]     # folders with changes in them -> the most urgent
    var untracked_dirs: List[String]  # folders nothing in which is tracked (absolute, no /)
    var staged: List[String]        # files with changes in the index (absolute)

    def __init__(out self):
        self.root = ""
        self.branch = ""
        self.ahead = 0
        self.behind = 0
        self.files = Dict[String, Int]()
        self.dirs = Dict[String, Int]()
        self.untracked_dirs = List[String]()
        self.staged = List[String]()

    def clear(mut self):
        self.branch = ""
        self.ahead = 0
        self.behind = 0
        self.files = Dict[String, Int]()
        self.dirs = Dict[String, Int]()
        self.untracked_dirs.clear()
        self.staged.clear()

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
            if e.startswith("# branch.ab "):
                var ab = String(e[byte=12:]).split(" ")
                for tok in ab:
                    var t = String(tok)
                    if t.startswith("+"):
                        try:
                            self.ahead = atol(String(t[byte=1:]))
                        except:
                            pass
                    elif t.startswith("-"):
                        try:
                            self.behind = atol(String(t[byte=1:]))
                        except:
                            pass
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
            if (kind == "1" or kind == "2") and String(e[byte=2:3]) != ".":
                self.staged.append(p)
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

    def untracked_count(self) -> Int:
        var n = len(self.untracked_dirs)
        for entry in self.files.items():
            if entry.value == GS_UNTRACKED:
                n += 1
        return n


def head_command(root: String, rel: String) -> String:
    """The file as in the last commit (fails for a file the commit does not have)."""
    return "git -C " + shell_quote(root) + " --no-optional-locks cat-file --filters " + shell_quote("HEAD:" + rel)


# ------------------------------------------------------------ commit, branches, blame
def sh_script(script: String) -> String:
    """A command line that runs `script` with sh (for Proc.start, which execs)."""
    return "sh -c " + shell_quote(script)


def commit_script(root: String, msg_file: String, amend: Bool, all: Bool, add_untracked: Bool = False) -> String:
    """`git commit` with the message in `msg_file` (removed afterwards); what git (and
    the hooks) print goes to the output, error messages too."""
    var opts = String("")
    if msg_file.byte_length() == 0:
        opts += " --no-edit"          # (amending, keeping the message)
    else:
        opts += " -F " + shell_quote(msg_file)
    if amend:
        opts += " --amend"
    if all and not add_untracked:
        opts += " --all"
    var pre = String("git add -A && ") if add_untracked else String("")
    var rm = ("; rm -f " + shell_quote(msg_file)) if msg_file.byte_length() > 0 else String("")
    return sh_script("cd " + shell_quote(root) + " && " + pre + "git commit --cleanup=strip" + opts
        + " </dev/null 2>&1; rc=$?" + rm + "; exit $rc")


def commit_message(summary: String, details: String) -> String:
    var m = String(summary.strip())
    var d = String(details.strip())
    if d.byte_length() > 0:
        m += "\n\n" + d
    return m + "\n"


def branches_command(root: String) -> String:
    return ("git -C " + shell_quote(root) + " for-each-ref --sort=-committerdate"
        + " --format='%(HEAD)%(refname:short)' refs/heads refs/remotes/origin")


def parse_branches(output: String) -> Tuple[List[String], String]:
    """(branch names, the current one) from branches_command's output."""
    var locals = List[String]()
    var remotes = List[String]()
    var current = String("")
    for l in output.split("\n"):
        var t = String(String(l).rstrip("\r"))
        if t.byte_length() < 2:
            continue
        var name = String(t[byte=1:])
        if name == "origin" or name == "origin/HEAD":
            continue
        if t.startswith("*"):
            current = name
        if name.startswith("origin/"):
            if not (name in remotes):
                remotes.append(name)
        else:
            if not (name in locals):
                locals.append(name)
    for r in remotes:
        var short_name = String(r[byte=7:])
        if not (short_name in locals):
            locals.append(r)
    return (locals^, current)


def switch_script(root: String, branch: String, create: Bool) -> String:
    # (no "--": `-c --` would make "--" the name; a branch name cannot start with -)
    if not create and branch.startswith("origin/"):
        return sh_script("cd " + shell_quote(root) + " && git switch --track "
            + shell_quote(branch) + " </dev/null 2>&1")
    return sh_script("cd " + shell_quote(root) + " && git switch " + ("-c " if create else "")
        + shell_quote(branch) + " </dev/null 2>&1")


def stash_script(root: String, pop: Bool) -> String:
    var sub = "pop" if pop else "push -u"
    return sh_script("cd " + shell_quote(root) + " && git stash " + sub + " </dev/null 2>&1")


def stage_file_script(root: String, rel: String, unstage: Bool) -> String:
    var q = shell_quote(rel)
    if unstage:
        return sh_script("cd " + shell_quote(root) + " && (git reset -q HEAD -- " + q + " || git rm --cached -q -- " + q + ") </dev/null 2>&1")
    return sh_script("cd " + shell_quote(root) + " && git add -- " + q + " </dev/null 2>&1")


def branch_name_problem(name: String) -> String:
    """'' if `name` can be a new branch's name (the common rules of git check-ref-format)."""
    if name.byte_length() == 0:
        return "A name is needed"
    if name.startswith("-") or name.startswith("/") or name.endswith("/") or name.endswith(".") or name.endswith(".lock"):
        return "A branch name cannot start with - or /, or end with /, . or .lock"
    if name.find("..") >= 0 or name.find("@{") >= 0 or name.find("//") >= 0 or name == "@":
        return "A branch name cannot contain .., @{ or //"
    for c in decode(name):
        if c <= 32 or c == 127 or c == 126 or c == 94 or c == 58 or c == 63 or c == 42 or c == 91 or c == 92:
            return "A branch name cannot contain spaces or any of ~ ^ : ? * [ \\"
    return ""


def blame_script(root: String, rel: String, contents: String) -> String:
    """Blame of the text in file `contents` (the buffer as edited; removed afterwards)
    as if it were `rel`."""
    return sh_script("cd " + shell_quote(root) + " && git blame --porcelain --contents " + shell_quote(contents)
        + " -- " + shell_quote(rel) + "; rc=$?; rm -f " + shell_quote(contents) + "; exit $rc")


@fieldwise_init
struct BlameLine(Copyable, Movable):
    var sha: String
    var author: String
    var time: Int           # seconds since 1970 (author time)
    var summary: String
    var line: String


def parse_blame(output: String) -> List[BlameLine]:
    """`git blame --porcelain`: per line a header "<sha> <orig> <final> [<count>]", the
    commit's details the first time it appears, and the line after a tab."""
    var res = List[BlameLine]()
    var authors = Dict[String, String]()
    var times = Dict[String, Int]()
    var summaries = Dict[String, String]()
    var sha = String("")
    for raw in output.split("\n"):
        var l = String(raw)
        if l.startswith("\t"):
            res.append(BlameLine(sha, authors.get(sha, ""), times.get(sha, 0), summaries.get(sha, ""), String(l[byte=1:])))
            continue
        var sp = l.find(" ")
        var key = String(l[byte=0:sp]) if sp > 0 else l
        var val = String(l[byte=sp + 1:]) if sp > 0 else String("")
        if key.byte_length() == 40 and is_hex(key):
            sha = key
        elif key == "author":
            authors[sha] = val
        elif key == "author-time":
            try:
                times[sha] = atol(val)
            except:
                pass
        elif key == "summary":
            summaries[sha] = val
    return res^


def is_hex(s: String) -> Bool:
    for c in s.as_bytes():
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
            return False
    return True


def is_uncommitted(sha: String) -> Bool:
    return sha.startswith("0000000000")


def ymd(t: Int) -> String:
    """The UTC date of a time in seconds since 1970, as YYYY-MM-DD."""
    var z = t // 86400 + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return String(y) + "-" + ("0" if m < 10 else "") + String(m) + "-" + ("0" if d < 10 else "") + String(d)
