#!/usr/bin/env bash
# Make the README's pictures of TurboMojo (docs/images/*.svg) with `tmide --screenshot`.
# Runs with a home, config and state of its own (not yours), from a copy of the examples
# in a folder of its own, so no one's settings or paths end up in the pictures.
# Usage: scripts/screenshots.sh   (after `pixi run build`)
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
out=$root/docs/images
work=$(mktemp -d "${TMPDIR:-/tmp}/turbomojo-shots.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$out" "$work/home" "$work/demo"
cp examples/hello.mojo examples/test_fib.mojo "$work/demo/"
shot() {
    (cd "$work/demo" && HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" \
        XDG_STATE_HOME="$work/home/.local/state" "$root/build/tmide" --screenshot "$@")
}
shot "$out/turbo-classic.svg" --size 100x30 hello.mojo
shot "$out/midnight-tiled.svg" --size 120x34 --theme midnight \
    --command window.tiledLayout --command window.explorer --command window.outline hello.mojo test_fib.mojo
shot "$out/command-palette.svg" --size 100x30 --theme light --command view.commandPalette hello.mojo
ls -l "$out"/*.svg
