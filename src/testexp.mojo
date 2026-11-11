"""The test explorer's model: test files of the project, their tests, and what a run of
them reported.

Mojo 1.2 has no `mojo test`: a test file is a program whose main() runs
`TestSuite.discover_tests[__functions_in_module()]().run()`, which runs every function
named test_*. Such a program takes `--skip-all`, `--only <names>` and `--skip <names>`
and prints (verified):

    Running 3 tests for /abs/path/test_bad.mojo
        PASS [ 0.001 ] test_good
        FAIL [ 0.013 ] test_bad
          At /abs/path/test_bad.mojo:9:17: AssertionError: `left == right` comparison failed:
             left: 4
        SKIP [ 0.001 ] test_raises
    --------
    Summary [ 0.013 ] 3 tests run: 1 passed , 1 failed , 1 skipped

A failure that is not an assertion (an error raised) has no "At ..." line, only its
message; the explorer then goes to the test's def.
"""
from std.collections import List
from util import basename

comptime TS_UNKNOWN = 0      # not run yet
comptime TS_RUNNING = 1
comptime TS_PASS = 2
comptime TS_FAIL = 3
comptime TS_SKIP = 4


def is_test_source(text: String) -> Bool:
    return text.find("TestSuite") >= 0 and text.find("discover_tests") >= 0


def test_names(text: String) -> List[String]:
    """The tests a TestSuite file has, as `discover_tests` finds them: top-level
    functions whose names start with test_."""
    var out = List[String]()
    for l in text.split("\n"):
        var line = String(l)
        if not line.startswith("def test_"):
            continue
        var end = line.find("(")
        if end > 4:
            var name = String(line[byte=4:end].strip())
            if name not in out:
                out.append(name)
    return out^


def def_line(text: String, name: String) -> Int:
    """1-based line of `def <name>(` (0 if not found)."""
    var n = 1
    for l in text.split("\n"):
        if String(l).startswith("def " + name + "("):
            return n
        n += 1
    return 0


struct TestCase(Copyable, Movable):
    var name: String
    var state: Int
    var ms: String              # the time the run gave, as printed
    var message: List[String]   # the lines under a FAIL
    var path: String            # where the failure is ('' if not known)
    var line: Int
    var col: Int

    def __init__(out self, name: String):
        self.name = name
        self.state = TS_UNKNOWN
        self.ms = ""
        self.message = List[String]()
        self.path = ""
        self.line = 0
        self.col = 0


struct TestFile(Copyable, Movable):
    var path: String
    var tests: List[TestCase]
    var open: Bool
    var problem: List[String]   # the file did not run (it did not compile): what was said
    var listed: Bool            # the names come from the program (--skip-all), not the source

    def __init__(out self, path: String):
        self.path = path
        self.tests = List[TestCase]()
        self.open = True
        self.problem = List[String]()
        self.listed = False

    def find(self, name: String) -> Int:
        for k in range(len(self.tests)):
            if self.tests[k].name == name:
                return k
        return -1

    def counts(self) -> Tuple[Int, Int, Int]:
        var p = 0
        var f = 0
        var s = 0
        for t in self.tests:
            if t.state == TS_PASS:
                p += 1
            elif t.state == TS_FAIL:
                f += 1
            elif t.state == TS_SKIP:
                s += 1
        return (p, f, s)


def parse_location(line: String) -> Tuple[String, Int, Int]:
    """"At /path/f.mojo:9:17: ..." -> (path, 9, 17); ("", 0, 0) if it is not one."""
    var t = String(line.strip())
    if not t.startswith("At "):
        return ("", 0, 0)
    var rest = String(t[byte=3:])
    var colon = rest.find(".mojo:")
    var ext = 6
    if colon < 0:
        colon = rest.find(".🔥:")
        ext = ".🔥:".byte_length()
    if colon < 0:
        return ("", 0, 0)
    var path = String(rest[byte=0:colon + ext - 1])
    var nums = String(rest[byte=colon + ext:]).split(":")
    if len(nums) < 2:
        return ("", 0, 0)
    try:
        return (path, atol(String(nums[0])), atol(String(nums[1])))
    except:
        return ("", 0, 0)


struct RunReport(Copyable, Movable):
    """What one run said about one file."""
    var path: String
    var names: List[String]
    var states: List[Int]
    var times: List[String]
    var messages: List[List[String]]
    var summary: String

    def __init__(out self, path: String):
        self.path = path
        self.names = List[String]()
        self.states = List[Int]()
        self.times = List[String]()
        self.messages = List[List[String]]()
        self.summary = ""


def parse_run(output: String) -> List[RunReport]:
    """Every "Running N tests for <path>" section of a run's output."""
    var out = List[RunReport]()
    for raw in output.split("\n"):
        var l = String(String(raw).rstrip("\r"))
        var t = String(l.strip())
        if t.startswith("Running ") and t.find(" tests for ") > 0:
            var at = t.find(" tests for ")
            out.append(RunReport(String(t[byte=at + 11:].strip())))
            continue
        if len(out) == 0:
            continue
        var k = len(out) - 1
        var state = 0
        if t.startswith("PASS ["):
            state = TS_PASS
        elif t.startswith("FAIL ["):
            state = TS_FAIL
        elif t.startswith("SKIP ["):
            state = TS_SKIP
        if state != 0:
            var close = t.find("]")
            var name = String(t[byte=close + 1:].strip()) if close > 0 else String("")
            var ms = String(t[byte=6:close].strip()) if close > 6 else String("")
            out[k].names.append(name)
            out[k].states.append(state)
            out[k].times.append(ms)
            out[k].messages.append(List[String]())
            continue
        if t.startswith("Summary ["):
            out[k].summary = t
            continue
        if t.startswith("--------") or t.startswith("Test suite'"):
            continue
        # a message line belongs to the last FAIL of the section
        var n = len(out[k].states)
        if n > 0 and out[k].states[n - 1] == TS_FAIL and l.startswith("      "):
            out[k].messages[n - 1].append(String(l[byte=6:]))
    return out^


def apply_report(mut f: TestFile, r: RunReport, keep_skipped: Bool = False):
    """The results of a run into a file's tests (tests the run named but the list had
    not are added: the program is the authority). With `keep_skipped` (a run of some
    tests with --only) the tests the run skipped keep what they had."""
    for j in range(len(r.names)):
        var k = f.find(r.names[j])
        if k < 0:
            f.tests.append(TestCase(r.names[j]))
            k = len(f.tests) - 1
        elif keep_skipped and r.states[j] == TS_SKIP:
            continue
        f.tests[k].state = r.states[j]
        f.tests[k].ms = r.times[j]
        f.tests[k].message = r.messages[j].copy()
        f.tests[k].path = ""
        f.tests[k].line = 0
        f.tests[k].col = 0
        for m in r.messages[j]:
            var loc = parse_location(m)
            if loc[0].byte_length() > 0:
                f.tests[k].path = loc[0]
                f.tests[k].line = loc[1]
                f.tests[k].col = loc[2]
                break
    f.problem.clear()


def state_mark(state: Int) -> String:
    if state == TS_PASS:
        return "✓"
    if state == TS_FAIL:
        return "✗"
    if state == TS_SKIP:
        return "-"
    if state == TS_RUNNING:
        return "…"
    return "·"
