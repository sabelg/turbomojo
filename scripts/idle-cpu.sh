#!/usr/bin/env bash
# Measure how much CPU the idle IDE uses: prints CPU milliseconds consumed over N seconds.
set -euo pipefail
cd "$(dirname "$0")/.."
N="${1:-10}"
S=scripts/tui-test.sh
trap '$S stop' EXIT
$S start examples/hello.mojo
pid=$(pgrep -n -f "build/tmide examples/hello.mojo" || true)
[ -n "$pid" ] || { echo "IDE process not found"; exit 1; }
tck=$(getconf CLK_TCK)
t0=$(awk '{print $14+$15}' /proc/$pid/stat)
sw0=$(awk '/ctxt_switches/ {s+=$2} END {print s}' /proc/$pid/status)
sleep "$N"
t1=$(awk '{print $14+$15}' /proc/$pid/stat)
sw1=$(awk '/ctxt_switches/ {s+=$2} END {print s}' /proc/$pid/status)
echo "idle ${N}s: cpu $(( (t1 - t0) * 1000 / tck )) ms, wakeups $(( sw1 - sw0 )) ($(( (sw1 - sw0) / N ))/s)"
