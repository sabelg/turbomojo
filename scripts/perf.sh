#!/usr/bin/env bash
# Performance budgets: start-up, key to frame, opening 1,000,000 lines, idle CPU
# (scripts/perf.py has the budgets). Needs tmux and a built build/tmide.
# Results are appended to build/perf-history.csv. Exits 1 if one is over budget.
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
PY
fi
if [ ! -x build/open_bench ] || [ bench/open_bench.mojo -nt build/open_bench ] || [ src/buffer.mojo -nt build/open_bench ]; then
  if [ -n "${MOJO:-}" ] && [ -n "${VT_LINK:-}" ]; then
    "$MOJO" build -I src bench/open_bench.mojo -o build/open_bench $VT_LINK 2>/dev/null
  elif [ -x ".pixi/envs/$ENVN/bin/mojo" ] && [ -f ".pixi/envs/$ENVN/lib/libghostty-vt.a" ]; then
    ".pixi/envs/$ENVN/bin/mojo" build -I src bench/open_bench.mojo -o build/open_bench -Xlinker "$PWD/.pixi/envs/$ENVN/lib/libghostty-vt.a" 2>/dev/null
  else
    pixi run -e "$ENVN" mojo build -I src bench/open_bench.mojo -o build/open_bench -Xlinker "$(pixi run -e "$ENVN" printenv CONDA_PREFIX)/lib/libghostty-vt.a" 2>/dev/null
  fi
fi
python3 scripts/perf.py "$PWD/build/tmide" "$PWD/build/open_bench" "$PWD/build/big/1m.mojo"
