"""Breakpoints: where the debugger is to stop.

A breakpoint is on a line of a file or on a function (by name). It can have a condition
(stop only when it is true), a hit count (stop only from the n-th time on, as the
adapter understands it) and a log message (do not stop: write the message). The list is
kept per project in a small text file, so breakpoints survive closing the IDE.
"""
from std.collections import List
from json import JsonWriter
from util import basename, bytes_to_str

comptime BV_UNKNOWN = 0      # no debugger has been asked
comptime BV_OK = 1           # the debugger placed it
comptime BV_NOT = 2          # the debugger could not place it


struct Breakpoint(Copyable, Movable):
    var path: String        # the file ('' for a function breakpoint)
    var line: Int           # 1-based
    var name: String        # the function, for a function breakpoint
    var enabled: Bool
    var condition: String
    var hit: String
    var log: String
    var verified: Int       # what the running debugger said (BV_...)
    var actual: Int         # the line the debugger really uses (0: as asked)
    var id: Int             # the debugger's number for it (-1: none)

    def __init__(out self, path: String, line: Int, name: String = ""):
        self.path = path
        self.line = line
        self.name = name
        self.enabled = True
        self.condition = ""
        self.hit = ""
        self.log = ""
        self.verified = BV_UNKNOWN
        self.actual = 0
        self.id = -1

    def is_function(self) -> Bool:
        return self.path.byte_length() == 0

    def plain(self) -> Bool:
        return self.condition.byte_length() == 0 and self.hit.byte_length() == 0 and self.log.byte_length() == 0

    def look(self) -> Int:
        """How the gutter shows it: 1 ●, 2 ○ (off), 3 ◆ (with a condition, a count or a
        message), 4 ◌ (the running debugger could not place it)."""
        if not self.enabled:
            return 2
        if self.verified == BV_NOT:
            return 4
        return 1 if self.plain() else 3

    def describe(self) -> String:
        var s = (self.name + "()") if self.is_function() else (basename(self.path) + ":" + String(self.line))
        if self.condition.byte_length() > 0:
            s += "  when " + self.condition
        if self.hit.byte_length() > 0:
            s += "  hits " + self.hit
        if self.log.byte_length() > 0:
            s += "  log \"" + self.log + "\""
        if not self.enabled:
            s += "  (off)"
        elif self.verified == BV_NOT:
            s += "  (not placed by the debugger)"
        elif self.actual > 0 and self.actual != self.line and not self.is_function():
            s += "  (the debugger uses line " + String(self.actual) + ")"
        return s


def bp_escape(s: String) -> String:
    """A text as one field of a line: tabs, line ends and backslashes written out."""
    var out = List[UInt8]()
    for c in s.as_bytes():
        if c == 92:
            out.append(92)
            out.append(92)
        elif c == 9:
            out.append(92)
            out.append(116)
        elif c == 10:
            out.append(92)
            out.append(110)
        elif c != 13:
            out.append(c)
    return bytes_to_str(out)


def bp_unescape(s: String) -> String:
    var out = List[UInt8]()
    var esc = False
    for c in s.as_bytes():
        if esc:
            if c == 116:
                out.append(9)
            elif c == 110:
                out.append(10)
            else:
                out.append(c)
            esc = False
        elif c == 92:
            esc = True
        else:
            out.append(c)
    return bytes_to_str(out)


struct Breakpoints(Copyable, Movable):
    var items: List[Breakpoint]

    def __init__(out self):
        self.items = List[Breakpoint]()

    def find(self, path: String, line: Int) -> Int:
        for k in range(len(self.items)):
            if self.items[k].path == path and self.items[k].line == line and not self.items[k].is_function():
                return k
        return -1

    def find_function(self, name: String) -> Int:
        for k in range(len(self.items)):
            if self.items[k].is_function() and self.items[k].name == name:
                return k
        return -1

    def toggle(mut self, path: String, line: Int) -> Bool:
        """Set a breakpoint on the line, or remove the one that is there. True if one
        was set."""
        var k = self.find(path, line)
        if k >= 0:
            _ = self.items.pop(k)
            return False
        self.items.append(Breakpoint(path, line))
        return True

    def add_function(mut self, name: String) -> Bool:
        """False if there is one for this function already."""
        if name.byte_length() == 0 or self.find_function(name) >= 0:
            return False
        self.items.append(Breakpoint("", 0, name))
        return True

    def of_file(self, path: String) -> List[Int]:
        """The breakpoints of a file, by line (indices into items)."""
        var out = List[Int]()
        for k in range(len(self.items)):
            if self.items[k].path == path and not self.items[k].is_function():
                var at = len(out)
                while at > 0 and self.items[out[at - 1]].line > self.items[k].line:
                    at -= 1
                out.insert(at, k)
        return out^

    def files(self) -> List[String]:
        var out = List[String]()
        for b in self.items:
            if not b.is_function() and b.path not in out:
                out.append(b.path)
        return out^

    def ordered(self) -> List[Int]:
        """Everything in the order a list shows it: file by file, by line, then the
        function breakpoints."""
        var out = List[Int]()
        for f in self.files():
            for k in self.of_file(f):
                out.append(k)
        for k in range(len(self.items)):
            if self.items[k].is_function():
                out.append(k)
        return out^

    def sent(self, path: String) -> List[Int]:
        """The breakpoints of a file that go to the debugger (the enabled ones), in the
        order they are sent."""
        var out = List[Int]()
        for k in self.of_file(path):
            if self.items[k].enabled:
                out.append(k)
        return out^

    def sent_functions(self) -> List[Int]:
        var out = List[Int]()
        for k in range(len(self.items)):
            if self.items[k].is_function() and self.items[k].enabled:
                out.append(k)
        return out^

    def set_rows(mut self, path: String, rows: List[Int]) -> Bool:
        """The lines the breakpoints of a file are on now (0-based rows, in the order of
        of_file) - they move with the text. Two that end up on one line become one.
        True if anything changed."""
        var idx = self.of_file(path)
        if len(idx) != len(rows):
            return False
        var changed = False
        for j in range(len(idx)):
            if self.items[idx[j]].line != rows[j] + 1:
                self.items[idx[j]].line = rows[j] + 1
                changed = True
        if changed:
            var drop = List[Int]()
            for j in range(1, len(idx)):
                if rows[j] == rows[j - 1]:
                    drop.append(idx[j])
            # remove from the highest index down, so the others keep their places
            while len(drop) > 0:
                var hi = 0
                for d in range(len(drop)):
                    if drop[d] > drop[hi]:
                        hi = d
                _ = self.items.pop(drop[hi])
                _ = drop.pop(hi)
        return changed

    def forget_debugger(mut self):
        """The session is over: what its debugger said no longer holds."""
        for k in range(len(self.items)):
            self.items[k].verified = BV_UNKNOWN
            self.items[k].actual = 0
            self.items[k].id = -1

    # ---------------------------------------------------------- the file
    def encode(self) -> String:
        var s = String("turbomojo breakpoints 1\n")
        for k in self.ordered():
            var b = self.items[k].copy()
            s += ("F" if b.is_function() else "S") + "\t" + ("1" if b.enabled else "0") + "\t" + String(b.line) + "\t"
            s += bp_escape(b.name if b.is_function() else b.path) + "\t" + bp_escape(b.condition) + "\t" + bp_escape(b.hit) + "\t" + bp_escape(b.log) + "\n"
        return s

    def decode(mut self, text: String):
        """Read a breakpoint file; lines that make no sense are left out."""
        self.items.clear()
        var first = True
        for l in text.split("\n"):
            if first:
                first = False
                if not l.startswith("turbomojo breakpoints "):
                    return
                continue
            var p = l.split("\t")
            if len(p) != 7:
                continue
            var line = 0
            try:
                line = atol(String(p[2]))
            except:
                continue
            var what = bp_unescape(String(p[3]))
            if what.byte_length() == 0:
                continue
            var kind = String(p[0])
            var b = Breakpoint("", 0, what)
            if kind == "S":
                if line < 1 or self.find(what, line) >= 0:
                    continue
                b = Breakpoint(what, line)
            elif kind != "F" or self.find_function(what) >= 0:
                continue
            b.enabled = String(p[1]) != "0"
            b.condition = bp_unescape(String(p[4]))
            b.hit = bp_unescape(String(p[5]))
            b.log = bp_unescape(String(p[6]))
            self.items.append(b^)

    # ------------------------------------------------- for the debugger
    def extras(self, k: Int, mut w: JsonWriter):
        if self.items[k].condition.byte_length() > 0:
            w.kv_str("condition", self.items[k].condition)
        if self.items[k].hit.byte_length() > 0:
            w.kv_str("hitCondition", self.items[k].hit)

    def source_request(self, path: String, extra_line: Int = 0) -> String:
        """The arguments of `setBreakpoints` for a file: all its enabled breakpoints
        (an empty list removes what the debugger had there). `extra_line` adds a
        plain one there, last (Run to cursor), unless a breakpoint is on that line."""
        var w = JsonWriter()
        w.begin_obj()
        w.key("source")
        w.begin_obj()
        w.kv_str("name", basename(path))
        w.kv_str("path", path)
        w.end_obj()
        w.key("breakpoints")
        w.begin_arr()
        for k in self.sent(path):
            w.begin_obj()
            w.kv_int("line", self.items[k].line)
            self.extras(k, w)
            if self.items[k].log.byte_length() > 0:
                w.kv_str("logMessage", self.items[k].log)
            w.end_obj()
        if extra_line > 0 and self.find(path, extra_line) < 0:
            w.begin_obj()
            w.kv_int("line", extra_line)
            w.end_obj()
        w.end_arr()
        w.end_obj()
        return w.text()

    def function_request(self) -> String:
        var w = JsonWriter()
        w.begin_obj()
        w.key("breakpoints")
        w.begin_arr()
        for k in self.sent_functions():
            w.begin_obj()
            w.kv_str("name", self.items[k].name)
            self.extras(k, w)
            w.end_obj()
        w.end_arr()
        w.end_obj()
        return w.text()

    def apply_report(mut self, path: String, verified: List[Bool], lines: List[Int], ids: List[Int]):
        """What the debugger answered for a file's breakpoints ('' = the function
        breakpoints), in the order they were sent."""
        var idx = self.sent(path) if path.byte_length() > 0 else self.sent_functions()
        for j in range(min(len(idx), len(verified))):
            self.items[idx[j]].verified = BV_OK if verified[j] else BV_NOT
            self.items[idx[j]].actual = lines[j]
            self.items[idx[j]].id = ids[j]

    def apply_change(mut self, id: Int, verified: Bool, line: Int):
        """The debugger changed its mind about one breakpoint (it does when the
        program's code is loaded)."""
        for k in range(len(self.items)):
            if self.items[k].id == id and id >= 0:
                self.items[k].verified = BV_OK if verified else BV_NOT
                if line > 0:
                    self.items[k].actual = line
