#!/usr/bin/env bash
# Drive TurboMojo inside a private tmux server for smoke testing.
#   scripts/tui-test.sh start [file...]   launch the IDE (100x30)
#   scripts/tui-test.sh keys <tmux keys>  send keys (tmux send-keys syntax)
#   scripts/tui-test.sh shot              print the screen
#   scripts/tui-test.sh stop              kill the private tmux server
# The IDE's state files (crash log, recovered buffers) go to build/state, not your home,
# and it reads no user config unless TM_CONFIG_HOME points to one.
set -euo pipefail
cd "$(dirname "$0")/.."
T="tmux -L turbomojo-test"
ENV_PATH="$PWD/.pixi/envs/default/bin:$PATH"
case "${1:-}" in
  start) shift; $T kill-server 2>/dev/null && sleep 0.5 || true
         $T new-session -d -s ide -x "${COLS:-100}" -y "${ROWS:-30}" "PATH=\"$ENV_PATH\" MODULAR_HOME=\"$PWD/.pixi/envs/default/share/max\" XDG_STATE_HOME=$PWD/build/state XDG_CONFIG_HOME=${TM_CONFIG_HOME:-$PWD/build/config-none} ./build/tmide $*; sleep 60"
         sleep 2 ;;
  keys)  shift; $T send-keys -t ide "$@"; sleep "${WAIT:-0.6}" ;;
  shot)  $T capture-pane -t ide -p ;;
  stop)  $T kill-server 2>/dev/null || true ;;
  *) echo "usage: $0 start|keys|shot|stop"; exit 1 ;;
esac
