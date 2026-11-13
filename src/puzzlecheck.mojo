"""Check my answer for the Mojo GPU Puzzles (P11-10c), as Help > Exercise done? does for
the exercises. O in the documentation reader opens your own copy of a puzzle's program
(practice/mojo-gpu-puzzles/problems/pNN/...); Help > Exercise done? with that copy in
front runs it the way the course's own test runner (solutions/run.sh) runs a puzzle:
`mojo run -I <the course's folder> <file> [--flag]`, once for each mode the program
compares its first argument with (`argv()[1] == "--simple"`, or a variable holding it;
"--demo..." modes left out), and the answer is right when every run ends with status 0 -
the puzzles check their results themselves (assert_equal, "Puzzle NN complete ✅").

A puzzle with no check of its own (one about reading a debugger's output) and the
Python ones are said to be so; nothing is run for them."""
from std.collections import List

comptime PUZZLES_DIR = "mojo-gpu-puzzles"


def puzzle_rel(practice_root: String, path: String) -> String:
    """"problems/p01/p01.mojo" for your copy of that puzzle under `practice_root`
    (the practice folder); "" for any other file."""
    var head = practice_root + "/" + PUZZLES_DIR + "/"
    if not path.startswith(head) or not path.endswith(".mojo"):
        return ""
    var rel = String(path[byte=head.byte_length():])
    if not rel.startswith("problems/p") or len(rel.split("/")) != 3:
        return ""           # (not the packages of the Python puzzles: problems/p17/op/...)
    return rel


def puzzle_name(rel: String) -> String:
    """"Puzzle 01" for "problems/p01/p01.mojo"."""
    var parts = rel.split("/")
    if len(parts) < 2:
        return "The puzzle"
    var p = String(parts[1])
    if p.startswith("p"):
        return "Puzzle " + String(p[byte=1:])
    return "Puzzle " + p


def puzzle_mojo(root: String) -> String:
    """The Mojo of the puzzles' own pixi environment (it has MAX, which they import)."""
    return root + "/.pixi/envs/default/bin/mojo"


def puzzle_runner(root: String) -> String:
    """How to call that Mojo: with its environment's MODULAR_HOME (where its standard
    library is), as `pixi run` would set it."""
    return "env MODULAR_HOME='" + (root + "/.pixi/envs/default/share/max").replace("'", "'\\''") + "' '" + puzzle_mojo(root).replace("'", "'\\''") + "'"


def puzzle_flags(source: String) -> List[String]:
    """The modes a puzzle program runs in: each "--flag" its source compares a value
    with (`== "--flag"`), sorted, once each, without "--demo..."; empty for one mode."""
    var found = List[String]()
    var rest = source
    while True:
        var k = rest.find("== \"--")
        if k < 0:
            break
        var after = String(rest[byte=k + 4:])
        var end = after.find("\"")
        if end < 0:
            break
        var flag = String(after[byte=0:end])
        if not flag.startswith("--demo") and flag not in found:
            found.append(flag)
        rest = String(after[byte=end + 1:])
    sort_strings(found)
    return found^


def puzzle_checks_itself(source: String) -> Bool:
    """Does the program check its own result (so that status 0 means right)?"""
    return source.find("assert_") >= 0 or source.find("✅") >= 0


def puzzle_command(mojo: String, root: String, file: String, flags: List[String], limit: String) -> String:
    """The shell text that runs every mode in turn, each under a heading line, and
    stops at the first that fails (its status is the command's)."""
    var runs = List[String]()
    if len(flags) == 0:
        runs.append("")
    for f in flags:
        runs.append(f)
    var out = String("")
    for r in runs:
        if out.byte_length() > 0:
            out += " && "
        var q = "'" + r.replace("'", "'\\''") + "'"
        var fq = "'" + file.replace("'", "'\\''") + "'"
        var rq = "'" + root.replace("'", "'\\''") + "'"
        out += "echo " + ("'== " + r + "'" if r.byte_length() > 0 else String("'== (no flag)'")) + " && "
        out += limit + mojo + " run -I " + rq + " " + fq + ((" " + q) if r.byte_length() > 0 else String(""))
    return out


def sort_strings(mut xs: List[String]):
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j] < xs[j - 1]:
            var t = xs[j]
            xs[j] = xs[j - 1]
            xs[j - 1] = t
            j -= 1
