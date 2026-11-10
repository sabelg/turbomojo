#!/usr/bin/env bash
# Single gate for the roadmap runner and CI: build, run every test file, smoke-test the TUI.
# Ends with "CHECK OK" only if everything passed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build build/tests

echo "== build"
pixi run mojo build -I src src/main.mojo -o build/tmide 2> >(grep -v Crashpad >&2)

echo "== tests"
# tests that talk to the real toolchain (mojo-lsp-server) need it on PATH
export PATH="$PWD/.pixi/envs/default/bin:$PATH"
count=0
for t in tests/test_*.mojo; do
  [ -e "$t" ] || continue
  echo "-- $t"
  # compile, then run: far faster than `mojo run` for tests that pull in the whole app
  bin="build/tests/$(basename "$t" .mojo)"
  pixi run mojo build -I src "$t" -o "$bin" 2> >(grep -v -e Crashpad -e warning -e '^ ' -e '^Included' >&2)
  "$bin" | grep -v "    PASS" || { echo "FAILED: $t"; exit 1; }
  count=$((count + 1))
done
echo "$count test file(s) passed"

if [ "${SKIP_SMOKE:-0}" != "1" ] && command -v tmux >/dev/null; then
  echo "== smoke"
  scripts/smoke.sh
fi

echo "CHECK OK"
