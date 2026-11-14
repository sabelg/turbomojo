"""The Problems page's model: problems from every source (the language server, the last
build, the test explorer's failed tests) in one list, and the filter that chooses which
are shown (kinds, only the current file, a text).

A row is in compiler format, `path:line:col: error: message`, so it reads like the
build's output; problems from a build or a test say so at the end.
"""
from std.collections import List, Dict
from util import lower_str, str_contains

comptime PS_SERVER = 0
comptime PS_BUILD = 1
comptime PS_TEST = 2

comptime SEV_ERROR = 1
comptime SEV_WARNING = 2
comptime SEV_INFO = 3       # information and notes
comptime SEV_HINT = 4


struct Problem(Copyable, Movable):
    var source: Int
    var severity: Int
    var path: String        # absolute
    var line: Int           # 1-based (0: the file as a whole)
    var col: Int            # 1-based, in characters
    var message: String     # its first line
    var more: List[String]  # further lines of the message

    def __init__(out self, source: Int, severity: Int, path: String, line: Int, col: Int, message: String):
        self.source = source
        self.severity = severity
        self.path = path
        self.line = line
        self.col = col
        self.message = message
        self.more = List[String]()


def severity_name(sev: Int) -> String:
    if sev == SEV_ERROR:
        return "error"
    if sev == SEV_WARNING:
        return "warning"
    if sev == SEV_HINT:
        return "hint"
    return "note"


def source_tag(src: Int) -> String:
    if src == PS_BUILD:
        return "  [build]"
    if src == PS_TEST:
        return "  [test]"
    return ""


def problem_row(p: Problem) -> String:
    return (p.path + ":" + String(p.line) + ":" + String(p.col) + ": " + severity_name(p.severity) + ": "
        + p.message + source_tag(p.source))


def parse_compiler_output(output: String, base: String) -> List[Problem]:
    """The `path:line:col: error|warning|note: message` lines of a compiler's output
    (relative paths are taken from `base`). Fix-it lines right below a caret are attached."""
    var out = List[Problem]()
    var saw_caret = False
    for raw in output.split("\n"):
        var l = String(String(raw).rstrip("\r"))
        var sev = 0
        var at = -1
        for pair in [(": error: ", SEV_ERROR), (": warning: ", SEV_WARNING), (": note: ", SEV_INFO)]:
            var k = l.find(pair[0])
            if k > 0 and (at < 0 or k < at):
                at = k
                sev = pair[1]
        if at < 0:
            var trimmed = String(l.strip())
            if len(out) > 0 and trimmed.startswith("^"):
                saw_caret = True
            elif saw_caret and len(out) > 0:
                saw_caret = False
                if l.startswith(" ") and trimmed.byte_length() > 0:
                    out[len(out) - 1].more.append("fix-it: " + trimmed)
            else:
                saw_caret = False
            continue
        saw_caret = False
        var loc = String(l[byte=0:at])
        var parts = loc.split(":")
        var n = len(parts)
        if n < 3:
            continue
        var line: Int
        var col: Int
        try:
            line = atol(String(parts[n - 2]))
            col = atol(String(parts[n - 1]))
        except:
            continue
        var path = String("")
        for k in range(n - 2):
            path += (":" if k > 0 else "") + String(parts[k])
        if not path.startswith("/") and base.byte_length() > 0:
            path = base + "/" + path
        var word_len = 9 if sev == SEV_ERROR else (11 if sev == SEV_WARNING else 8)
        out.append(Problem(PS_BUILD, sev, path, line, col, String(l[byte=at + word_len:])))
    return out^


struct ProblemFilter(Copyable, Movable):
    var errors: Bool
    var warnings: Bool
    var infos: Bool         # notes, information and hints
    var this_file: Bool     # only the current file's
    var text: String        # only problems whose row contains this (any case)

    def __init__(out self):
        self.errors = True
        self.warnings = True
        self.infos = True
        self.this_file = False
        self.text = ""

    def active(self) -> Bool:
        return not (self.errors and self.warnings and self.infos) or self.this_file or self.text.byte_length() > 0

    def keep(self, p: Problem, current: String) -> Bool:
        if p.severity == SEV_ERROR and not self.errors:
            return False
        if p.severity == SEV_WARNING and not self.warnings:
            return False
        if p.severity > SEV_WARNING and not self.infos:
            return False
        if self.this_file and p.path != current:
            return False
        if self.text.byte_length() > 0 and not str_contains(lower_str(problem_row(p)), lower_str(self.text)):
            return False
        return True

    def describe(self) -> String:
        """The filter line at the top of the page."""
        var kinds = String("")
        if self.errors:
            kinds += "errors "
        if self.warnings:
            kinds += "warnings "
        if self.infos:
            kinds += "notes "
        if kinds.byte_length() == 0:
            kinds = "nothing "
        var s = "Shown: " + kinds + ("in this file" if self.this_file else "in all files")
        if self.text.byte_length() > 0:
            s += ", containing \"" + self.text + "\""
        return s + "   (E W N kinds, F this file, / text, C all)"


struct ProblemView(Movable):
    """What the page shows: its rows, and for each the problem it is (-1: none)."""
    var rows: List[String]
    var of: List[Int]
    var errors: Int
    var warnings: Int
    var infos: Int
    var shown: Int
    var files: Int

    def __init__(out self):
        self.rows = List[String]()
        self.of = List[Int]()
        self.errors = 0
        self.warnings = 0
        self.infos = 0
        self.shown = 0
        self.files = 0


def order_problems(probs: List[Problem], current: String) -> List[Int]:
    """The current file's problems first, then each file's in the order the files first
    appear; within a file by line and column. Build `: note:` entries stay attached right
    after the build error/warning they explain. Repeats are left out."""
    var parent_of = List[Int](length=len(probs), fill=-1)
    for k in range(len(probs)):
        if probs[k].source == PS_BUILD and probs[k].severity == SEV_INFO:
            var j = k - 1
            while j >= 0 and probs[j].source == PS_BUILD:
                if probs[j].severity != SEV_INFO:
                    parent_of[k] = j
                    break
                j -= 1
    var files = List[String]()
    if current.byte_length() > 0:
        files.append(current)
    for k in range(len(probs)):
        if parent_of[k] < 0 and probs[k].path not in files:
            files.append(probs[k].path)
    for k in range(len(probs)):
        if probs[k].path not in files:
            files.append(probs[k].path)
    var out = List[Int]()
    var seen = Dict[String, Bool]()
    for f in files:
        var idx = List[Int]()
        for k in range(len(probs)):
            if parent_of[k] < 0 and probs[k].path == f:
                idx.append(k)
        # insertion sort by (line, col): stable, the lists are short
        for a in range(1, len(idx)):
            var v = idx[a]
            var b = a
            while b > 0 and (probs[idx[b - 1]].line > probs[v].line or (probs[idx[b - 1]].line == probs[v].line and probs[idx[b - 1]].col > probs[v].col)):
                idx[b] = idx[b - 1]
                b -= 1
            idx[b] = v
        for k in idx:
            var key = probs[k].path + ":" + String(probs[k].line) + ":" + String(probs[k].col) + ":" + String(probs[k].severity) + ":" + probs[k].message
            if key in seen:
                continue
            seen[key] = True
            out.append(k)
            for c in range(len(probs)):
                if parent_of[c] == k:
                    var ckey = probs[c].path + ":" + String(probs[c].line) + ":" + String(probs[c].col) + ":" + String(probs[c].severity) + ":" + probs[c].message
                    if ckey not in seen:
                        seen[ckey] = True
                        out.append(c)
    return out^


def view_problems(probs: List[Problem], filter: ProblemFilter, current: String) -> ProblemView:
    var v = ProblemView()
    var files = List[String]()
    for k in order_problems(probs, current):
        ref p = probs[k]
        if p.severity == SEV_ERROR:
            v.errors += 1
        elif p.severity == SEV_WARNING:
            v.warnings += 1
        else:
            v.infos += 1
        if not filter.keep(p, current):
            continue
        v.shown += 1
        if p.path not in files:
            files.append(p.path)
        v.rows.append(problem_row(p))
        v.of.append(k)
        for m in p.more:
            v.rows.append("    " + m)
            v.of.append(k)
    v.files = len(files)
    return v^


def filter_lines(lines: List[String], text: String) -> List[Int]:
    """The lines (by index) that contain `text`, in any case."""
    var out = List[Int]()
    var t = lower_str(text)
    for k in range(len(lines)):
        if str_contains(lower_str(lines[k]), t):
            out.append(k)
    return out^
