#!/usr/bin/env python3
"""Generate sharded Mojo test runner entrypoints in build/tests/.

Compiling 175+ standalone `tests/test_*.mojo` and `tests/e2e/test_*.mojo` files
individually builds `App` well over a hundred times. Grouping pure-module suites into
`shard_0` (or `shard_0a`/`shard_0b`) and `App`-importing suites into `N` balanced shards
(`shard_1..shard_N`) with transitive per-shard dependency hashing cuts cold and incremental
compile times dramatically while still running every suite in its own isolated OS process via
`TURBOMOJO_TEST_SUITE=<rel_path>`.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re

IMPORT_RE = re.compile(r"^\s*(?:from|import)\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)


def write_if_changed(path: Path, text: str) -> None:
    if path.exists():
        try:
            if path.read_text(encoding="utf-8") == text:
                return
        except OSError:
            pass
    path.write_text(text, encoding="utf-8")


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_module_index(search_dirs: list[Path]) -> dict[str, Path]:
    idx: dict[str, Path] = {}
    for d in search_dirs:
        if not d.exists():
            continue
        for p in sorted(d.glob("*.mojo")):
            idx.setdefault(p.stem, p)
    return idx


def direct_imports(path: Path) -> list[str]:
    src = path.read_text(encoding="utf-8", errors="replace")
    out: list[str] = []
    for m in IMPORT_RE.finditer(src):
        mod = m.group(1)
        if mod != "std" and mod not in out:
            out.append(mod)
    return out


def transitive_closure(entry_files: list[Path], mod_index: dict[str, Path]) -> list[Path]:
    seen_paths: dict[Path, None] = {}
    queue: list[Path] = []
    for p in entry_files:
        rp = p.resolve()
        if rp not in seen_paths:
            seen_paths[rp] = None
            queue.append(rp)
    i = 0
    while i < len(queue):
        cur = queue[i]
        i += 1
        for mod in direct_imports(cur):
            dep = mod_index.get(mod)
            if dep is not None:
                rdep = dep.resolve()
                if rdep not in seen_paths:
                    seen_paths[rdep] = None
                    queue.append(rdep)
    return sorted(seen_paths.keys())


def render_shard(repo: Path, shard_name: str, tests: list[Path]) -> str:
    lines = [
        f'"""Auto-generated test runner for {shard_name} (scripts/gen_test_runner.py)."""',
        "from std.ffi import external_call",
        "from util import env_or",
    ]
    for t in tests:
        lines.append(f"import {t.stem}")
    lines.append("")
    lines.append("")
    lines.append("def main() raises:")
    lines.append('    var suite = env_or("TURBOMOJO_TEST_SUITE", "")')
    lines.append('    if suite == "--list":')
    if not tests:
        lines.append("        return")
    else:
        for t in tests:
            rel = t.relative_to(repo).as_posix()
            lines.append(f'        print("{rel}")')
        lines.append("        return")
    for t in tests:
        mod = t.stem
        rel = t.relative_to(repo).as_posix()
        lines.append(f'    if suite == "{rel}" or suite == "{mod}":')
        lines.append(f"        {mod}.main()")
        lines.append("        return")
    lines.append(f'    print("unknown test suite for {shard_name}: " + suite)')
    lines.append('    external_call["exit", NoneType](Int32(2))')
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="build/tests", help="Output directory for shard sources")
    ap.add_argument("--app-shards", type=int, default=8, help="Number of shards for App-importing tests")
    ap.add_argument("--src-sig", default="", help="Toolchain signature (e.g. mojo --version)")
    args = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    src_dir = repo / "src"
    tests_dir = repo / "tests"
    e2e_dir = tests_dir / "e2e"
    out_dir = (repo / args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    mod_index = build_module_index([src_dir, tests_dir, e2e_dir])

    all_tests = sorted(tests_dir.glob("test_*.mojo"))
    if e2e_dir.exists():
        all_tests.extend(sorted(e2e_dir.glob("test_*.mojo")))

    unit_tests: list[Path] = []
    app_tests: list[Path] = []
    for t in all_tests:
        deps = transitive_closure([t], mod_index)
        dep_stems = {d.stem for d in deps}
        if "app" in dep_stems or "appstate" in dep_stems or any(s.startswith("app_") for s in dep_stems):
            app_tests.append(t)
        else:
            unit_tests.append(t)

    n_app = max(1, args.app_shards)
    shards: list[tuple[str, list[Path]]] = []
    if unit_tests:
        # Split pure unit tests into 2 shards when >80 suites so compilation parallelizes cleanly
        if len(unit_tests) > 80:
            shards.append(("shard_0a", unit_tests[0::2]))
            shards.append(("shard_0b", unit_tests[1::2]))
        else:
            shards.append(("shard_0", unit_tests))
    buckets: list[list[Path]] = [[] for _ in range(n_app)]
    for idx, t in enumerate(app_tests):
        buckets[idx % n_app].append(t)
    for idx, bucket in enumerate(buckets, start=1):
        if bucket:
            shards.append((f"shard_{idx}", bucket))

    map_lines: list[str] = []
    shard_names: list[str] = []
    for shard_name, group in shards:
        shard_names.append(shard_name)
        shard_src = render_shard(repo, shard_name, group)
        shard_mojo = out_dir / f"{shard_name}.mojo"
        write_if_changed(shard_mojo, shard_src)

        # Compute exact transitive dependency hash for this shard only
        closure = transitive_closure(group, mod_index)
        sig_hasher = hashlib.sha256()
        sig_hasher.update(args.src_sig.encode("utf-8"))
        sig_hasher.update(b"\n")
        sig_hasher.update(shard_src.encode("utf-8"))
        sig_hasher.update(b"\n")
        for dep in closure:
            rel_dep = dep.relative_to(repo).as_posix()
            sig_hasher.update(f"{rel_dep}:{file_sha256(dep)}\n".encode("utf-8"))
        write_if_changed(out_dir / f"{shard_name}.want_sha256", sig_hasher.hexdigest() + "\n")

        for t in group:
            rel = t.relative_to(repo).as_posix()
            map_lines.append(f"{rel}\t{shard_name}")

    # Keep execution order sorted: unit/integration tests first, then e2e tests
    map_lines.sort(key=lambda line: (line.startswith("tests/e2e/"), line.split("\t", 1)[0]))
    write_if_changed(out_dir / "shard_map.tsv", "\n".join(map_lines) + ("\n" if map_lines else ""))
    write_if_changed(out_dir / "shards.txt", "\n".join(shard_names) + ("\n" if shard_names else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
