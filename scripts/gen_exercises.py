#!/usr/bin/env python3
"""Make src/exercise_pages.mojo from help/exercises/ (in the order of ORDER). Run it
after changing an exercise; tests/test_exercises.mojo checks the built-in copies are
the files, that each exercise fails until fixed and that its solution
(tests/exercise_solutions/) prints the expected line."""
import json, os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "help", "exercises")
keys = open(os.path.join(src, "ORDER")).read().split()
out = ['"""The exercises of Help > Exercises, made from help/exercises/ by', 'scripts/gen_exercises.py - do not edit here."""', "", "comptime EX_COUNT = %d" % len(keys), ""]
for k in keys:
    t = open(os.path.join(src, k + ".mojo")).read()
    if "# expect: " not in t:
        sys.exit(k + ".mojo has no '# expect: ' line")
    out.append("comptime EX_%s = %s" % (k.upper().replace("-", "_"), json.dumps(t, ensure_ascii=False)))
out += ["", "", "def ex_key(i: Int) -> String:"]
for i, k in enumerate(keys):
    out.append('    %s i == %d:\n        return "%s"' % ("if" if i == 0 else "elif", i, k))
out += ['    return ""', "", "", "def ex_text(i: Int) -> String:"]
for i, k in enumerate(keys):
    out.append("    %s i == %d:\n        return EX_%s" % ("if" if i == 0 else "elif", i, k.upper().replace("-", "_")))
out += ['    return ""', ""]
open(os.path.join(root, "src", "exercise_pages.mojo"), "w").write("\n".join(out))
print("src/exercise_pages.mojo:", len(keys), "exercises")
