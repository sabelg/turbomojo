#!/usr/bin/env bash
# Single gate for the roadmap runner and CI: build, run every test file, smoke-test the TUI.
# Ends with "CHECK OK" only if everything passed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build build/tests

# Other toolchains: TM_ENV=nightly uses that pixi environment of this project (the canary);
# TM_MANIFEST=path/to/pixi.toml uses a different project file altogether.
PIXI_RUN="pixi run"
if [ -n "${TM_ENV:-}" ]; then
  PIXI_RUN="pixi run -e $TM_ENV"
elif [ -n "${TM_MANIFEST:-}" ]; then
  PIXI_RUN="pixi run --manifest-path $TM_MANIFEST"
fi
echo "== toolchain: $($PIXI_RUN mojo --version 2>/dev/null | tail -1)"

echo "== build"
# the terminal emulator library is linked in statically (no run-time dependency)
VT_LINK="-Xlinker $($PIXI_RUN printenv CONDA_PREFIX)/lib/libghostty-vt.a"
$PIXI_RUN mojo build -I src src/main.mojo -o build/tmide $VT_LINK 2> >(grep -v Crashpad >&2)

echo "== tests"
# tests that talk to the real toolchain (mojo-lsp-server) need it on PATH
export PATH="$(dirname "$($PIXI_RUN which mojo)"):$PATH"
# ...and its standard library, not the one of whatever environment started this script
export MODULAR_HOME="$($PIXI_RUN printenv MODULAR_HOME)"
count=0
for t in tests/test_*.mojo; do
  [ -e "$t" ] || continue
  echo "-- $t"
  # compile, then run: far faster than `mojo run` for tests that pull in the whole app
  bin="build/tests/$(basename "$t" .mojo)"
  $PIXI_RUN mojo build -I src "$t" -o "$bin" $VT_LINK 2> >(grep -v -e Crashpad -e warning -e '^ ' -e '^Included' >&2)
  "$bin" | grep -v "    PASS" || { echo "FAILED: $t"; exit 1; }
  count=$((count + 1))
done
echo "$count test file(s) passed"

if [ "${SKIP_SMOKE:-0}" != "1" ] && command -v tmux >/dev/null; then
  echo "== smoke"
  scripts/smoke.sh
fi

echo "CHECK OK"
