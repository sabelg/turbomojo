#!/usr/bin/env python3
"""Generate sharded Mojo test runner entrypoints in build/tests/.

Compiling 137+ standalone `tests/test_*.mojo` files builds `App` over a hundred times.
Grouping tests into a lightweight pure-module shard (`shard_0`) plus `N` balanced `App`
shards (`shard_1..shard_N`) cuts cold AOT compile work by ~20x while still running each
suite in its own isolated OS process via `TURBOMOJO_TEST_SUITE=tests/test_<name>.mojo`.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re

APP_IMPORT_RE = re.compile(r"^\s*(?:from|import)\s+app(?:[_\s.]|$)", re.MULTILINE)


def write_if_changed(path: Path, text: str) -> None:
    if path.exists():
        try:
            if path.read_text(encoding="utf-8") == text:
                return
        except OSError:
            pass
    path.write_text(text, encoding="utf-8")


def render_shard(shard_name: str, tests: list[Path]) -> str:
    lines = [
        f'"""Auto-generated test runner for {shard_name} (scripts/gen_test_runner.py)."""',
        "from std.ffi import external_call",
        "from util import env_or",
    ]
    for t in tests:
        mod = t.stem
        lines.append(f"import {mod}")
    lines.append("")
    lines.append("")
    lines.append("def main() raises:")
    lines.append('    var suite = env_or("TURBOMOJO_TEST_SUITE", "")')
    lines.append('    if suite == "--list":')
    if not tests:
        lines.append("        return")
    else:
        for t in tests:
            rel = f"tests/{t.name}"
            lines.append(f'        print("{rel}")')
        lines.append("        return")
    for t in tests:
        mod = t.stem
        rel = f"tests/{t.name}"
        lines.append(f'    if suite == "{rel}" or suite == "{mod}":')
        lines.append(f"        {mod}.main()")
        lines.append("        return")
    lines.append(f'    print("unknown test suite for {shard_name}: " + suite)')
    lines.append('    external_call["exit", NoneType](Int32(2))')
    lines.append("")
    return "\n".join(lines)


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="build/tests", help="Output directory for shard sources")
    ap.add_argument("--app-shards", type=int, default=8, help="Number of shards for App-importing tests")
    ap.add_argument("--src-sig", default="", help="Base signature of toolchain + src/*.mojo")
    args = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    tests_dir = repo / "tests"
    out_dir = (repo / args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    all_tests = sorted(tests_dir.glob("test_*.mojo"))
    unit_tests: list[Path] = []
    app_tests: list[Path] = []
    for t in all_tests:
        src = t.read_text(encoding="utf-8", errors="replace")
        if APP_IMPORT_RE.search(src):
            app_tests.append(t)
        else:
            unit_tests.append(t)

    n_app = max(1, args.app_shards)
    shards: list[tuple[str, list[Path]]] = []
    if unit_tests:
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
        shard_src = render_shard(shard_name, group)
        shard_mojo = out_dir / f"{shard_name}.mojo"
        write_if_changed(shard_mojo, shard_src)

        sig_hasher = hashlib.sha256()
        sig_hasher.update(args.src_sig.encode("utf-8"))
        sig_hasher.update(b"\n")
        sig_hasher.update(shard_src.encode("utf-8"))
        sig_hasher.update(b"\n")
        for t in group:
            sig_hasher.update(f"{t.name}:{file_sha256(t)}\n".encode("utf-8"))
        write_if_changed(out_dir / f"{shard_name}.want_sha256", sig_hasher.hexdigest() + "\n")

        for t in group:
            map_lines.append(f"tests/{t.name}\t{shard_name}")

    # Keep execution order sorted by test filename
    map_lines.sort(key=lambda line: line.split("\t", 1)[0])
    write_if_changed(out_dir / "shard_map.tsv", "\n".join(map_lines) + ("\n" if map_lines else ""))
    write_if_changed(out_dir / "shards.txt", "\n".join(shard_names) + ("\n" if shard_names else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
