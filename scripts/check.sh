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
if [ -z "${TM_ENV:-}" ] && [ -z "${TM_MANIFEST:-}" ] && ! $PIXI_RUN which mojo >/dev/null 2>&1 && { command -v mojo >/dev/null 2>&1 || [ -x .pixi/envs/default/bin/mojo ]; } && [ -f .pixi/envs/default/lib/libghostty-vt.a ]; then
  if command -v mojo >/dev/null 2>&1; then
    MOJO="$(command -v mojo)"
  else
    MOJO="$(pwd)/.pixi/envs/default/bin/mojo"
  fi
  export PATH="$(dirname "$MOJO"):$PATH"
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
"$MOJO" build -D "TURBOMOJO_MOJO=$("$MOJO" --version)" -I src src/main.mojo -o build/tmide $VT_LINK > build/build.log 2>&1 || { grep -v Crashpad build/build.log >&2; exit 1; }
grep -v Crashpad build/build.log >&2 || true
if grep -q "warning:" build/build.log; then
  echo "FAILED: build/tmide produced compiler warning(s)"
  exit 1
fi

if [ -n "${TM_JOBS:-}" ]; then
  JOBS="$TM_JOBS"
else
  CPU_JOBS=$(( $(nproc) / 2 ))
  [ "$CPU_JOBS" -ge 1 ] || CPU_JOBS=1
  JOBS="$CPU_JOBS"
  if [ -r /proc/meminfo ]; then
    MEM_AVAIL_KB="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)"
    if [ -n "${MEM_AVAIL_KB:-}" ] && [ "$MEM_AVAIL_KB" -gt 0 ] 2>/dev/null; then
      # ~5 GiB per parallel Mojo shard compiler keeps 8-32 GiB hosts out of swap/OOM
      MEM_JOBS=$(( MEM_AVAIL_KB / 5242880 ))
      [ "$MEM_JOBS" -ge 1 ] || MEM_JOBS=1
      [ "$MEM_JOBS" -lt "$JOBS" ] && JOBS="$MEM_JOBS"
    fi
  fi
fi
[ "$JOBS" -ge 1 ] || JOBS=1
MOJO_VER="$("$MOJO" --version)"
SRC_SIG="$({ printf '%s\n' "$MOJO_VER"; sha256sum src/*.mojo; } | sha256sum | awk '{print $1}')"
export MOJO_VER SRC_SIG
rm -f build/tests/*.log

if [ "${TM_SINGLE_TESTS:-0}" = "1" ]; then
  echo "== compiling the tests individually ($JOBS at a time)"
  compile_one() {
    local t="$1" name sig
    name="$(basename "$t" .mojo)"
    sig="$({ printf '%s\n' "$SRC_SIG"; sha256sum "$t"; } | sha256sum | awk '{print $1}')"
    if [ "${TM_FORCE_REBUILD:-0}" != "1" ] && [ -x "build/tests/$name" ] && [ -f "build/tests/$name.sha256" ] && [ "$(cat "build/tests/$name.sha256")" = "$sig" ]; then
      echo "cached $t"
      return 0
    fi
    if "$MOJO" build -I src -I tests -I tests/e2e "$t" -o "build/tests/$name" $VT_LINK > "build/tests/$name.log" 2>&1; then
      if grep -q "warning:" "build/tests/$name.log"; then
        rm -f "build/tests/$name.sha256"
        echo "WARNED: $t"
      else
        printf '%s\n' "$sig" > "build/tests/$name.sha256"
        echo "built $t"
      fi
    else
      rm -f "build/tests/$name.sha256"
      echo "DID NOT BUILD: $t"
    fi
  }
  export -f compile_one
  ls tests/test_*.mojo tests/e2e/test_*.mojo 2>/dev/null | xargs -P "$JOBS" -I{} bash -c 'compile_one "$@"' _ {} | sort > build/tests/compile.txt
  if grep -q -E "DID NOT BUILD|WARNED" build/tests/compile.txt; then
    for t in $(grep -E "DID NOT BUILD|WARNED" build/tests/compile.txt | sed -E 's/(DID NOT BUILD|WARNED): //'); do
      echo "FAILED: $t (compile/warnings)"
      grep -v -e Crashpad -e '^Included' "build/tests/$(basename "$t" .mojo).log" | head -40
    done
    exit 1
  fi
else
  python3 scripts/gen_test_runner.py --out build/tests --app-shards "${TM_TEST_SHARDS:-8}" --src-sig "$MOJO_VER"
  SHARD_COUNT="$(wc -l < build/tests/shards.txt | tr -d ' ')"
  echo "== compiling $SHARD_COUNT test shard(s) ($JOBS at a time)"
  compile_shard() {
    local s="$1" want
    want="$(cat "build/tests/$s.want_sha256")"
    if [ "${TM_FORCE_REBUILD:-0}" != "1" ] && [ -x "build/tests/$s" ] && [ -f "build/tests/$s.sha256" ] && [ "$(cat "build/tests/$s.sha256")" = "$want" ]; then
      echo "cached $s"
      return 0
    fi
    if "$MOJO" build -I src -I tests -I tests/e2e "build/tests/$s.mojo" -o "build/tests/$s" $VT_LINK > "build/tests/$s.log" 2>&1; then
      if grep -q "warning:" "build/tests/$s.log"; then
        rm -f "build/tests/$s.sha256"
        echo "WARNED: $s"
      else
        printf '%s\n' "$want" > "build/tests/$s.sha256"
        echo "built $s"
      fi
    else
      rm -f "build/tests/$s.sha256"
      echo "DID NOT BUILD: $s"
    fi
  }
  export -f compile_shard
  cat build/tests/shards.txt | xargs -P "$JOBS" -I{} bash -c 'compile_shard "$@"' _ {} | sort > build/tests/compile.txt
  if grep -q -E "DID NOT BUILD|WARNED" build/tests/compile.txt; then
    for s in $(grep -E "DID NOT BUILD|WARNED" build/tests/compile.txt | sed -E 's/(DID NOT BUILD|WARNED): //'); do
      echo "FAILED: $s (compile/warnings)"
      grep -v -e Crashpad -e '^Included' "build/tests/$s.log" | head -40
    done
    exit 1
  fi
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
if [ "${TM_SINGLE_TESTS:-0}" = "1" ]; then
  for t in tests/test_*.mojo tests/e2e/test_*.mojo; do
    [ -e "$t" ] || continue
    echo "-- $t"
    "build/tests/$(basename "$t" .mojo)" | grep -v "    PASS" || { echo "FAILED: $t"; exit 1; }
    count=$((count + 1))
  done
else
  while IFS=$'\t' read -r t shard; do
    [ -n "$t" ] || continue
    echo "-- $t"
    TURBOMOJO_TEST_SUITE="$t" "build/tests/$shard" | grep -v "    PASS" || { echo "FAILED: $t"; exit 1; }
    count=$((count + 1))
  done < build/tests/shard_map.tsv
fi
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
