#!/usr/bin/env bash
# Single gate for the roadmap runner and CI: build, run every test file, smoke-test the TUI.
# Ends with "CHECK OK" only if everything passed.
#
# The test programs are compiled in parallel (TM_JOBS at a time, default half the CPUs:
# compiling is most of the time) and then run one after another (several start tmux,
# agents or language servers, which must not disturb each other).
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

# the environment's mojo and standard library, asked once (not a `pixi run` per file)
MOJO="$($PIXI_RUN which mojo)"
export PATH="$(dirname "$MOJO"):$PATH"     # tests that use the toolchain (mojo-lsp-server)
export MODULAR_HOME="$($PIXI_RUN printenv MODULAR_HOME)"
# the terminal emulator library is linked in statically (no run-time dependency)
VT_LINK="-Xlinker $($PIXI_RUN printenv CONDA_PREFIX)/lib/libghostty-vt.a"
export MOJO VT_LINK

echo "== build"
"$MOJO" build -I src src/main.mojo -o build/tmide $VT_LINK 2> >(grep -v Crashpad >&2)

JOBS="${TM_JOBS:-$(( $(nproc) / 2 ))}"
[ "$JOBS" -ge 1 ] || JOBS=1
echo "== compiling the tests ($JOBS at a time)"
# each one's messages go to build/tests/<name>.log; a failure is shown below
compile_one() {
  local t="$1" name
  name="$(basename "$t" .mojo)"
  if "$MOJO" build -I src "$t" -o "build/tests/$name" $VT_LINK > "build/tests/$name.log" 2>&1; then
    echo "built $t"
  else
    echo "DID NOT BUILD: $t"
  fi
}
export -f compile_one
rm -f build/tests/*.log
ls tests/test_*.mojo | xargs -P "$JOBS" -I{} bash -c 'compile_one "$@"' _ {} | sort > build/tests/compile.txt
if grep -q "DID NOT BUILD" build/tests/compile.txt; then
  for t in $(grep "DID NOT BUILD" build/tests/compile.txt | sed 's/DID NOT BUILD: //'); do
    echo "FAILED: $t (compile)"
    grep -v -e Crashpad -e warning -e '^ ' -e '^Included' "build/tests/$(basename "$t" .mojo).log" | head -40
  done
  exit 1
fi

echo "== tests"
count=0
for t in tests/test_*.mojo; do
  [ -e "$t" ] || continue
  echo "-- $t"
  "build/tests/$(basename "$t" .mojo)" | grep -v "    PASS" || { echo "FAILED: $t"; exit 1; }
  count=$((count + 1))
done
echo "$count test file(s) passed"

if [ "${SKIP_SMOKE:-0}" != "1" ] && command -v tmux >/dev/null; then
  echo "== smoke"
  scripts/smoke.sh
fi

echo "CHECK OK"
