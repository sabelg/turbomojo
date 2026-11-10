#!/usr/bin/env bash
# TUI smoke test in a private tmux server: start, check the screen, open a menu, type, quit.
set -euo pipefail
cd "$(dirname "$0")/.."
S=scripts/tui-test.sh
trap '$S stop' EXIT

fail() { echo "SMOKE FAIL: $1"; $S shot || true; exit 1; }

$S start examples/hello.mojo
$S shot | grep -q "File" || fail "menu bar missing"
$S shot | grep -q "hello.mojo" || fail "window title missing"
$S shot | grep -q "def main" || fail "file content missing"

$S keys F10
$S shot | grep -q "Open" || fail "File menu did not open"
$S keys Escape

$S keys C-End
$S keys -l "# smoke"
$S shot | grep -q "# smoke" || fail "typing did not appear"

$S keys M-x            # quit -> asks to save
$S shot | grep -q "Save?" || fail "no save prompt on quit"
$S keys n
sleep 0.5
if $S shot | grep -q "hello.mojo"; then fail "did not exit"; fi
grep -q "# smoke" examples/hello.mojo && fail "file was modified on disk"
# ---- crash safety: inject failures and check the terminal comes back and a log exists
T="tmux -L turbomojo-test"
ST="${TMPDIR:-/tmp}/turbomojo-smoke-state-$$"
crash_run() {   # $1 = fault kind
  $T kill-server 2>/dev/null && sleep 0.5 || true
  rm -rf "$ST"
  $T new-session -d -s ide -x 100 -y 30 \
    "XDG_STATE_HOME=$ST TURBOMOJO_FAULT=$1 pixi run ./build/tmide examples/hello.mojo; echo EXIT=\$?; stty -a | grep -q ' icanon' && echo TTY-COOKED; sleep 60"
  sleep 3
}
crash_run index
[ "$($T display -p -t ide '#{alternate_on}#{mouse_any_flag}')" = "00" ] || fail "crash left alternate screen or mouse mode on"
$S shot | grep -q "TurboMojo crashed" || fail "no crash notice shown"
$S shot | grep -q "TTY-COOKED" || fail "terminal not back in cooked mode after crash"
$S shot | grep -q "EXIT=0" && fail "crash exited with status 0"
grep -q "=== crash ===" "$ST/turbomojo/crash.log" || fail "crash log has no crash header"
grep -q "App::run" "$ST/turbomojo/crash.log" || fail "crash log has no stack trace"

crash_run raise
[ "$($T display -p -t ide '#{alternate_on}#{mouse_any_flag}')" = "00" ] || fail "error exit left alternate screen or mouse mode on"
$S shot | grep -q "internal error: injected failure" || fail "no error message shown"
$S shot | grep -q "TTY-COOKED" || fail "terminal not back in cooked mode after error"
$S shot | grep -q "EXIT=1" || fail "error exit status is not 1"
grep -q "fatal: injected failure" "$ST/turbomojo/crash.log" || fail "error not logged"
rm -rf "$ST"
echo "smoke ok"
