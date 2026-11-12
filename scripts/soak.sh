#!/usr/bin/env bash
# Soak test: scripted editing for a long run, with a memory (leak) check.
# Usage: scripts/soak.sh [minutes]   (default 10; needs tmux and build/tmide)
set -euo pipefail
cd "$(dirname "$0")/.."
command -v tmux >/dev/null || { echo "soak: tmux is needed"; exit 1; }
[ -x build/tmide ] || { echo "soak: build the IDE first (pixi run build)"; exit 1; }
python3 scripts/soak.py "$PWD/build/tmide" "${1:-10}"
