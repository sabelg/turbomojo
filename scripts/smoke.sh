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
echo "smoke ok"
