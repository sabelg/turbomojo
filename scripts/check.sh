#!/usr/bin/env bash
# Single gate for the roadmap runner and CI: build, run every test file, smoke-test the TUI,
# check the performance budgets (scripts/perf.sh; SKIP_PERF=1 leaves them out).
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
FROZEN=""
[ -f pixi.lock ] && FROZEN="--frozen"
PIXI_RUN="pixi run $FROZEN"
if [ -n "${TM_ENV:-}" ]; then
  PIXI_RUN="pixi run $FROZEN -e $TM_ENV"
elif [ -n "${TM_MANIFEST:-}" ]; then
  PIXI_RUN="pixi run --manifest-path $TM_MANIFEST"
fi

# the environment's mojo and standard library, asked once (not a `pixi run` per file)
if [ -z "${TM_ENV:-}" ] && [ -z "${TM_MANIFEST:-}" ] && ! $PIXI_RUN which mojo >/dev/null 2>&1 && command -v mojo >/dev/null 2>&1 && [ -f .pixi/envs/default/lib/libghostty-vt.a ]; then
  MOJO="$(command -v mojo)"
  if [ -z "${MODULAR_HOME:-}" ] && [ -d .pixi/envs/default/share/max ]; then
    export MODULAR_HOME="$(pwd)/.pixi/envs/default/share/max"
  fi
  VT_LINK="-Xlinker $(pwd)/.pixi/envs/default/lib/libghostty-vt.a"
  echo "== toolchain: $("$MOJO" --version 2>/dev/null | tail -1)"
else
  echo "== toolchain: $($PIXI_RUN mojo --version 2>/dev/null | tail -1)"
  MOJO="$($PIXI_RUN which mojo)"
  export PATH="$(dirname "$MOJO"):$PATH"     # tests that use the toolchain (mojo-lsp-server)
  export MODULAR_HOME="$($PIXI_RUN printenv MODULAR_HOME)"
  # the terminal emulator library is linked in statically (no run-time dependency)
  VT_LINK="-Xlinker $($PIXI_RUN printenv CONDA_PREFIX)/lib/libghostty-vt.a"
fi
export MOJO VT_LINK

echo "== build"
"$MOJO" build -D "TURBOMOJO_MOJO=$("$MOJO" --version)" -I src src/main.mojo -o build/tmide $VT_LINK 2> >(grep -v Crashpad >&2)

JOBS="${TM_JOBS:-$(( $(nproc) / 2 ))}"
[ "$JOBS" -ge 1 ] || JOBS=1
SRC_SIG="$({ "$MOJO" --version; sha256sum src/*.mojo; } | sha256sum | awk '{print $1}')"
export SRC_SIG
echo "== compiling the tests ($JOBS at a time)"
# each one's messages go to build/tests/<name>.log; unchanged test binaries use build/tests/<name>.sha256
compile_one() {
  local t="$1" name sig
  name="$(basename "$t" .mojo)"
  sig="$({ printf '%s\n' "$SRC_SIG"; sha256sum "$t"; } | sha256sum | awk '{print $1}')"
  if [ "${TM_FORCE_REBUILD:-0}" != "1" ] && [ -x "build/tests/$name" ] && [ -f "build/tests/$name.sha256" ] && [ "$(cat "build/tests/$name.sha256")" = "$sig" ]; then
    echo "cached $t"
    return 0
  fi
  if "$MOJO" build -I src "$t" -o "build/tests/$name" $VT_LINK > "build/tests/$name.log" 2>&1; then
    printf '%s\n' "$sig" > "build/tests/$name.sha256"
    echo "built $t"
  else
    rm -f "build/tests/$name.sha256"
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
# the tests get a configuration, state and cache of their own, empty at the start - as on
# a machine where TurboMojo never ran - and never touch yours
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/turbomojo-check.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT
mkdir -m 700 "$TEST_HOME/tmux"
export XDG_CONFIG_HOME="$TEST_HOME/config" XDG_STATE_HOME="$TEST_HOME/state" XDG_CACHE_HOME="$TEST_HOME/cache" TMUX_TMPDIR="$TEST_HOME/tmux"
if [ -z "${TERM:-}" ] || [ "$TERM" = "dumb" ]; then
  export TERM="xterm-256color"
fi
unset TURBOMOJO_SCREEN_READER NO_COLOR
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

# performance budgets (start-up, key to frame, 1M-line open, idle CPU): after the tests,
# when the machine is quiet again
if [ "${SKIP_PERF:-0}" != "1" ] && command -v tmux >/dev/null; then
  echo "== perf"
  scripts/perf.sh
fi

# a short soak: a minute of scripted editing, the memory watched (scripts/soak.sh 30 for a
# long run); SKIP_SOAK=1 leaves it out
if [ "${SKIP_SOAK:-0}" != "1" ] && command -v tmux >/dev/null; then
  echo "== soak"
  scripts/soak.sh 1
fi

echo "CHECK OK"
