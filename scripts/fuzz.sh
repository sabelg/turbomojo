#!/usr/bin/env bash
# Long fuzz runs (tests/test_fuzz.mojo) with new seeds: the key parser, JSON, the rope
# and the VT parser. Usage: scripts/fuzz.sh [rounds] [iterations]  (default 10 x 20000).
# A failure prints the seed; replay it with
#   FUZZ_SEED=<seed> FUZZ_ITERS=<iterations> build/tests/test_fuzz
set -euo pipefail
cd "$(dirname "$0")/.."
ROUNDS="${1:-10}"
ITERS="${2:-20000}"
mkdir -p build/tests
MOJO="$(pixi run which mojo)"
export MODULAR_HOME="$(pixi run printenv MODULAR_HOME)"
"$MOJO" build -I src tests/test_fuzz.mojo -o build/tests/test_fuzz -Xlinker "$(pixi run printenv CONDA_PREFIX)/lib/libghostty-vt.a" 2> >(grep -v -e Crashpad -e warning -e '^ ' -e '^Included' >&2)
for r in $(seq 1 "$ROUNDS"); do
  seed=$(( $(date +%s%N) % 2147483647 ))
  echo "== round $r of $ROUNDS: seed $seed, $ITERS iterations"
  if ! FUZZ_SEED=$seed FUZZ_ITERS=$ITERS build/tests/test_fuzz | grep -v "    PASS"; then
    echo "FUZZ FAILED with seed $seed (FUZZ_SEED=$seed FUZZ_ITERS=$ITERS build/tests/test_fuzz)"
    exit 1
  fi
done
echo "FUZZ OK: $ROUNDS rounds of $ITERS"
