#!/usr/bin/env bash
# Drive TurboMojo inside a private tmux server for smoke testing.
#   scripts/tui-test.sh start [file...]   launch the IDE (100x30)
#   scripts/tui-test.sh keys <tmux keys>  send keys (tmux send-keys syntax)
#   scripts/tui-test.sh shot              print the screen
#   scripts/tui-test.sh stop              kill the private tmux server
set -euo pipefail
cd "$(dirname "$0")/.."
T="tmux -L turbomojo-test"
case "${1:-}" in
  start) shift; $T kill-server 2>/dev/null && sleep 0.5 || true
         $T new-session -d -s ide -x "${COLS:-100}" -y "${ROWS:-30}" "pixi run ./build/tmide $*; sleep 60"
         sleep 2 ;;
  keys)  shift; $T send-keys -t ide "$@"; sleep "${WAIT:-0.6}" ;;
  shot)  $T capture-pane -t ide -p ;;
  stop)  $T kill-server 2>/dev/null || true ;;
  *) echo "usage: $0 start|keys|shot|stop"; exit 1 ;;
esac
