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
from std.time import perf_counter_ns
from platform import stat_size_mtime
from util import (
    path_exists, run_system, run_capture, shell_quote,
    write_file, read_file, bytes_to_str, str_bytes,
)

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


def test_stem(src_path: String) -> String:
    var slash = src_path.rfind("/")
    var file_part: String
    if slash >= 0:
        file_part = String(src_path[byte=slash + 1:])
    else:
        file_part = src_path
    var dot = file_part.find(".")
    if dot >= 0:
        return String(file_part[byte=0:dot])
    return file_part


def file_size(path: String) -> Int:
    var st = stat_size_mtime(path)
    if not st[0]:
        return -1
    return st[1]


def file_mtime_ns(path: String) -> Int:
    var st = stat_size_mtime(path)
    if not st[0]:
        return -1
    return st[2] * 1000000000 + st[3]


struct TestBinaryCache(Copyable, Movable):
    var state_dir: String

    def __init__(out self, state_dir: String):
        self.state_dir = state_dir

    def cache_dir(self) -> String:
        return self.state_dir + "/testbin"

    def binary_path(self, src_path: String) -> String:
        return self.cache_dir() + "/bin_" + test_stem(src_path)

    def sig_path(self, src_path: String) -> String:
        return self.binary_path(src_path) + ".sig"

    def is_valid_binary(self, bin_path: String) -> Bool:
        if not path_exists(bin_path):
            return False
        var sz = file_size(bin_path)
        return sz > 0

    def binary_size(self, src_path: String) -> Int:
        return file_size(self.binary_path(src_path))

    def is_cache_valid(self, src_path: String) -> Bool:
        var bp = self.binary_path(src_path)
        if not self.is_valid_binary(bp):
            return False
        var sp = self.sig_path(src_path)
        if not path_exists(sp):
            return False
        var saved_sig = bytes_to_str(read_file(sp)).strip()
        var cur_mtime = String(file_mtime_ns(src_path))
        return saved_sig == cur_mtime

    def invalidate(self, src_path: String):
        var bp = self.binary_path(src_path)
        var sp = self.sig_path(src_path)
        _ = run_system("rm -f " + shell_quote(bp) + " " + shell_quote(sp))

    def build_cache(self, src_path: String) raises -> Tuple[Bool, String]:
        _ = run_system("mkdir -p " + shell_quote(self.cache_dir()))
        var bp = self.binary_path(src_path)
        var sp = self.sig_path(src_path)

        var cmd = "mojo build -o " + shell_quote(bp) + " " + shell_quote(src_path) + " 2>&1"
        var res = run_capture(cmd)
        var out_text = bytes_to_str(res.out)

        if res.status != 0 or not self.is_valid_binary(bp):
            self.invalidate(src_path)
            return (False, out_text)

        var cur_mtime = String(file_mtime_ns(src_path))
        _ = write_file(sp, str_bytes(cur_mtime))
        return (True, out_text)

    def run_cached(self, src_path: String, only: String = "") raises -> Tuple[Int, String, Float64]:
        if not self.is_cache_valid(src_path):
            var built = self.build_cache(src_path)
            if not built[0]:
                return (-1, built[1], 0.0)

        var bp = self.binary_path(src_path)
        var cmd = shell_quote(bp)
        if only.byte_length() > 0:
            cmd += " --only " + shell_quote(only)
        cmd += " 2>&1"

        var t0 = perf_counter_ns()
        var res = run_capture(cmd)
        var t1 = perf_counter_ns()
        var elapsed_ms = Float64(t1 - t0) / 1000000.0
        return (res.status, bytes_to_str(res.out), elapsed_ms)


struct WatchOnSaveManager(Copyable, Movable):
    var enabled: Bool

    def __init__(out self, enabled: Bool = False):
        self.enabled = enabled

    def toggle(mut self) -> Bool:
        self.enabled = not self.enabled
        return self.enabled

    def should_trigger(self, path: String, is_modified: Bool, content: String = "") -> Bool:
        if not self.enabled:
            return False
        if not is_modified:
            return False
        if not (path.endswith(".mojo") or path.endswith(".🔥")):
            return False
        if path.find("test") >= 0:
            return True
        if content.byte_length() > 0 and is_test_source(content):
            return True
        return False

    def on_save(self, path: String, is_modified: Bool, content: String = "") -> List[String]:
        var out = List[String]()
        if self.should_trigger(path, is_modified, content):
            out.append(path)
        return out^


struct ParallelJob(Copyable, Movable):
    var shard_id: Int
    var files: List[String]
    var active: Bool
    var cancelled: Bool

    def __init__(out self, shard_id: Int, files: List[String]):
        self.shard_id = shard_id
        self.files = files.copy()
        self.active = True
        self.cancelled = False


struct ParallelTestRunner(Copyable, Movable):
    var max_pipes: Int

    def __init__(out self, max_pipes: Int = 4):
        self.max_pipes = max_pipes

    def partition(self, files: List[String]) -> List[List[String]]:
        var out = List[List[String]]()
        var count = min(self.max_pipes, len(files))
        if count <= 0:
            return out^
        for _ in range(count):
            out.append(List[String]())
        for i in range(len(files)):
            out[i % count].append(files[i])
        return out^

    def cancel(self, mut jobs: List[ParallelJob]):
        for i in range(len(jobs)):
            jobs[i].active = False
            jobs[i].cancelled = True


def clamp_coverage_line(line: Int, total_lines: Int) -> Int:
    """Clamps a 0-based coverage line within [0, total_lines - 1]. Returns -1 if invalid."""
    if total_lines <= 0:
        return -1
    if line < 0:
        return 0
    if line >= total_lines:
        return total_lines - 1
    return line


def render_coverage_gutter(total_lines: Int, covered_lines: List[Int]) -> List[String]:
    """Renders gutter markers: '✓' for covered lines, '·' for uncovered lines."""
    var out = List[String]()
    if total_lines <= 0:
        return out^
    for r in range(total_lines):
        var is_cov = False
        for cl in covered_lines:
            if clamp_coverage_line(cl, total_lines) == r:
                is_cov = True
                break
        out.append("✓" if is_cov else "·")
    return out^
