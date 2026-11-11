#!/usr/bin/env bash
# Benchmark: how long the editor takes to open a big file and draw the first screen.
# Generates a 1,000,000-line Mojo-like file (about 21 MB) and a 60 MB text file under
# build/big/, then times the editor's own loading code on them (bench/open_bench.mojo).
# "old" is the loader used before P1-05 (bytes -> codepoints -> bytes), kept for comparison.
# Exits 1 if opening the 1M-line file takes 1 s or more.
set -euo pipefail
cd "$(dirname "$0")/.."
ENVN="${TM_ENV:-default}"
mkdir -p build/big
if [ ! -f build/big/1m.mojo ]; then
  python3 - <<'PY'
lines = ["def f%d(x: Int) -> Int:", "    var total = x * %d  # comment", "    for i in range(%d):",
         "        total += i", "    return total", "", "    s = \"text %d\"", "struct S%d:"]
with open("build/big/1m.mojo", "w") as f:
    for i in range(1000000):
        f.write(lines[i % 8].replace("%d", str(i)) + "\n")
line = "x = compute(alpha, beta, gamma)  # some filler text for the line\n"
with open("build/big/60mb.txt", "w") as f:
    for i in range(60 * 1024 * 1024 // len(line) + 1):
        f.write(line)
PY
fi
pixi run -e "$ENVN" mojo build -I src bench/open_bench.mojo -o build/open_bench -Xlinker "$(pixi run -e "$ENVN" printenv CONDA_PREFIX)/lib/libghostty-vt.a" 2>/dev/null
echo "== 1,000,000 lines, old loader"
./build/open_bench build/big/1m.mojo old
echo "== 1,000,000 lines"
out=$(./build/open_bench build/big/1m.mojo)
echo "$out"
echo "== 60 MB"
./build/open_bench build/big/60mb.txt
total=$(echo "$out" | sed -n 's/.*open total \([0-9]*\)\..*/\1/p')
if [ "${total:-9999}" -ge 1000 ]; then
  echo "FAIL: opening 1M lines took ${total} ms (limit 1000)"
  exit 1
fi
echo "BENCH OK"
