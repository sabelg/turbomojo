"""The project around the files being edited: where its `pixi.toml` is and which tasks
that file defines."""
from std.collections import List
from util import decode, to_str, join_path, dirname, path_exists

comptime FIND_UP_MAX = 24


def find_up(start: String, name: String) -> String:
    """The nearest folder at or above `start` that holds a file called `name`
    ('' if none)."""
    var d = start
    for _ in range(FIND_UP_MAX):
        if d.byte_length() == 0:
            return ""
        if path_exists(join_path(d, name)):
            return d
        var up = dirname(d)
        if up == d or up.byte_length() == 0:
            return ""
        d = up
    return ""


struct PixiTask(Copyable, Movable):
    var name: String
    var cmd: String             # what it runs ('' for a task that only depends on others)
    var depends: List[String]
    var description: String
    var feature: String         # the feature it belongs to ('' = the default one)

    def __init__(out self, name: String):
        self.name = name
        self.cmd = ""
        self.depends = List[String]()
        self.description = ""
        self.feature = ""


struct TomlCursor:
    """A position in one line of TOML."""
    var c: List[Int]
    var i: Int

    def __init__(out self, line: List[Int]):
        self.c = line.copy()
        self.i = 0

    def ws(mut self):
        while self.i < len(self.c) and (self.c[self.i] == 32 or self.c[self.i] == 9):
            self.i += 1

    def peek(self) -> Int:
        return self.c[self.i] if self.i < len(self.c) else 0

    def key(mut self) -> String:
        """A bare or quoted key (dotted keys come back whole, dots included)."""
        self.ws()
        var out = List[Int]()
        while self.i < len(self.c):
            var ch = self.c[self.i]
            if ch == 34 or ch == 39:
                var s = self.string()
                for x in decode(s):
                    out.append(x)
                continue
            if (ch >= 48 and ch <= 57) or (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95 or ch == 45 or ch == 46:
                out.append(ch)
                self.i += 1
            else:
                break
        return to_str(out)

    def string(mut self) -> String:
        """A "basic" or 'literal' string starting at the cursor ('' if there is none)."""
        var q = self.peek()
        if q != 34 and q != 39:
            return ""
        self.i += 1
        var out = List[Int]()
        while self.i < len(self.c) and self.c[self.i] != q:
            var ch = self.c[self.i]
            if q == 34 and ch == 92 and self.i + 1 < len(self.c):
                self.i += 1
                var e = self.c[self.i]
                if e == 110:
                    out.append(10)
                elif e == 116:
                    out.append(9)
                else:
                    out.append(e)       # \" \\ and anything else: the character itself
            else:
                out.append(ch)
            self.i += 1
        self.i += 1                     # the closing quote
        return to_str(out)

    def strings(mut self) -> List[String]:
        """A list of strings "[...]" at the cursor; other things in it (tables naming a
        task with arguments) give their "task" value."""
        var out = List[String]()
        if self.peek() != 91:
            return out^
        self.i += 1
        while self.i < len(self.c) and self.c[self.i] != 93:
            self.ws()
            var ch = self.peek()
            if ch == 34 or ch == 39:
                out.append(self.string())
            elif ch == 123:
                var t = PixiTask("")
                self.table(t)
                if t.name.byte_length() > 0:
                    out.append(t.name)
            elif ch == 0:
                break
            else:
                self.i += 1
        self.i += 1
        return out^

    def skip_value(mut self):
        """Step over a value we do not use."""
        self.ws()
        var ch = self.peek()
        if ch == 34 or ch == 39:
            _ = self.string()
        elif ch == 91:
            _ = self.strings()
        elif ch == 123:
            var t = PixiTask("")
            self.table(t)
        else:
            while self.i < len(self.c) and self.c[self.i] != 44 and self.c[self.i] != 125 and self.c[self.i] != 93:
                self.i += 1

    def field(mut self, name: String, mut t: PixiTask):
        """The value of key `name` of a task, at the cursor."""
        self.ws()
        if name == "cmd":
            if self.peek() == 91:
                var parts = self.strings()
                var s = String("")
                for p in parts:
                    s += (" " if s.byte_length() > 0 else "") + p
                t.cmd = s
            else:
                t.cmd = self.string()
        elif name == "depends-on" or name == "depends_on":
            if self.peek() == 91:
                t.depends = self.strings()
            else:
                var one = self.string()
                if one.byte_length() > 0:
                    t.depends.append(one)
        elif name == "description":
            t.description = self.string()
        elif name == "task":
            t.name = self.string()      # only inside depends-on tables
        else:
            self.skip_value()

    def table(mut self, mut t: PixiTask):
        """An inline table "{ key = value, ... }" at the cursor."""
        if self.peek() != 123:
            return
        self.i += 1
        while self.i < len(self.c):
            self.ws()
            if self.peek() == 125:
                self.i += 1
                return
            if self.peek() == 44:
                self.i += 1
                continue
            var k = self.key()
            self.ws()
            if self.peek() != 61 or k.byte_length() == 0:
                self.i += 1             # not something we understand: move on
                continue
            self.i += 1
            self.field(k, t)


def tasks_table(header: String) -> Tuple[Bool, String, String]:
    """Is a table header one that holds tasks? Returns (yes, feature, task): the task
    name is given when the table is one task ("[tasks.build]")."""
    var h = header
    if header.startswith("tool.pixi."):
        h = String(header[byte=10:])
    var feature = String("")
    if h.startswith("feature."):
        var rest = String(h[byte=8:])
        var dot = rest.find(".")
        if dot <= 0:
            return (False, String(""), String(""))
        feature = String(rest[byte=0:dot])
        h = String(rest[byte=dot + 1:])
    if h == "tasks":
        return (True, feature, String(""))
    if h.startswith("tasks."):
        return (True, feature, String(h[byte=6:]))
    return (False, String(""), String(""))


def parse_pixi_tasks(text: String) -> List[PixiTask]:
    """The tasks of a pixi.toml (or of the [tool.pixi] part of a pyproject.toml), in
    the order they are written: "name = "command"", "name = { cmd = ..., depends-on =
    [...] }", and "[tasks.name]" tables; also those of features."""
    var tasks = List[PixiTask]()
    var in_tasks = False
    var feature = String("")
    var one = -1                        # index of the task a "[tasks.name]" table fills
    for raw in text.split("\n"):
        var line = decode(String(raw))
        var cur = TomlCursor(line)
        cur.ws()
        var ch = cur.peek()
        if ch == 0 or ch == 35:
            continue
        if ch == 91:
            # a table header
            cur.i += 1
            if cur.peek() == 91:
                in_tasks = False        # an array of tables: not tasks
                one = -1
                continue
            var header = cur.key()
            var what = tasks_table(header)
            in_tasks = what[0]
            feature = what[1]
            one = -1
            if in_tasks and what[2].byte_length() > 0:
                var t = PixiTask(what[2])
                t.feature = feature
                tasks.append(t^)
                one = len(tasks) - 1
            continue
        if not in_tasks:
            continue
        var k = cur.key()
        cur.ws()
        if k.byte_length() == 0 or cur.peek() != 61:
            continue
        cur.i += 1
        cur.ws()
        if one >= 0:
            var t = tasks[one].copy()
            cur.field(k, t)
            t.name = tasks[one].name
            tasks[one] = t^
            continue
        var t = PixiTask(k)
        t.feature = feature
        if cur.peek() == 123:
            cur.table(t)
            t.name = k
        else:
            t.cmd = cur.string()
        tasks.append(t^)
    return tasks^


def pixi_project_name(text: String) -> String:
    """The name given in [workspace] or [project] ('' if none)."""
    var inside = False
    for raw in text.split("\n"):
        var cur = TomlCursor(decode(String(raw)))
        cur.ws()
        if cur.peek() == 91:
            cur.i += 1
            var h = cur.key()
            inside = h == "workspace" or h == "project" or h == "tool.pixi.workspace" or h == "tool.pixi.project"
            continue
        if not inside:
            continue
        var k = cur.key()
        cur.ws()
        if k == "name" and cur.peek() == 61:
            cur.i += 1
            cur.ws()
            return cur.string()
    return ""
