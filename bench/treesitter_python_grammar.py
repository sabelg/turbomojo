"""Spike (P1-20): how well does tree-sitter's *Python* grammar parse Mojo source?

There is no Mojo grammar in the project's conda channels, so this measures the nearest
one. To repeat it, in an empty folder with a pixi.toml that has conda-forge and the
dependencies python, tree_sitter, tree-sitter-python and libtree-sitter:

    pixi run python treesitter_python_grammar.py /path/to/this/repository

Result on 2026-11-10 (81 files, 27,394 lines of this repository): every file had errors,
40.0% of all lines lay inside ERROR nodes. See docs/JOURNAL.md, P1-20."""
import glob, sys
import tree_sitter_python as tsp
from tree_sitter import Language, Parser

parser = Parser(Language(tsp.language()))
files = sorted(glob.glob(sys.argv[1] + "/src/*.mojo") + glob.glob(sys.argv[1] + "/tests/*.mojo") + glob.glob(sys.argv[1] + "/examples/*.mojo"))
tot_lines = tot_err_lines = tot_nodes = tot_err = bad_files = 0
causes = {}
for f in files:
    src = open(f, "rb").read()
    tree = parser.parse(src)
    lines = src.count(b"\n") + 1
    err_rows = set()
    n_err = n_nodes = 0
    stack = [tree.root_node]
    while stack:
        n = stack.pop()
        n_nodes += 1
        if n.type == "ERROR" or n.is_missing:
            n_err += 1
            for r in range(n.start_point[0], n.end_point[0] + 1):
                err_rows.add(r)
            first = src.splitlines()[n.start_point[0]].strip()[:40].decode("utf8", "replace")
            key = first.split(" ")[0] if first else "(blank)"
            causes[key] = causes.get(key, 0) + 1
        stack.extend(n.children)
    tot_lines += lines; tot_err_lines += len(err_rows); tot_nodes += n_nodes; tot_err += n_err
    if n_err: bad_files += 1
print("files", len(files), "with errors", bad_files)
print("lines", tot_lines, "inside error nodes", tot_err_lines, "= %.1f%%" % (100.0 * tot_err_lines / tot_lines))
print("nodes", tot_nodes, "error/missing nodes", tot_err)
print("most common first words of error lines:", sorted(causes.items(), key=lambda kv: -kv[1])[:12])
