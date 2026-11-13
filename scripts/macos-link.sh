#!/usr/bin/env bash
# macOS, first part (P11-12): build tmide for macOS on Apple silicon here, on Linux -
# compile it for arm64-apple-macosx14.0 and link it with the Mach-O linker that comes
# with Mojo (lld as ld64.lld) against the osx-arm64 packages pixi.lock names (the Mojo
# runtime, libc++, libghostty-vt). It cannot be run here; this checks what can be
# checked without a Mac: that it compiles, that every function it needs is found, and
# that the result is an arm64 Mach-O executable.
#
#   scripts/macos-link.sh [--cache DIR]          (writes build/macos/tmide)
#
# Apple's SDK is not here, so libSystem is a text stub (a .tbd) with the functions in
# scripts/macos/libSystem.symbols: a Linux-only function makes the link fail.
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${TMPDIR:-/tmp}/turbomojo-macos"
while [ $# -gt 0 ]; do
    case "$1" in
        --cache) CACHE="$2"; shift 2 ;;
        *) echo "usage: scripts/macos-link.sh [--cache DIR]" >&2; exit 2 ;;
    esac
done
ENV="$PWD/.pixi/envs/default"
MOJO="$ENV/bin/mojo"
LLD="$ENV/bin/lld"
[ -x "$MOJO" ] && [ -x "$LLD" ] || { echo "macos-link: run pixi install first" >&2; exit 1; }
export MODULAR_HOME="$ENV/share/max"
TRIPLE=arm64-apple-macosx14.0

# 1. the osx-arm64 packages, as pixi.lock has them (downloaded once into the cache)
mkdir -p "$CACHE/pkgs" "$CACHE/root"
URLS=$(grep -oE 'https://\S+/osx-arm64/(mojo-compiler|libghostty-vt|libcxx)-[^ ]+\.conda' pixi.lock | grep -v max-nightly | sort -u)
[ "$(echo "$URLS" | grep -c .)" -eq 3 ] || { echo "macos-link: pixi.lock lacks the osx-arm64 packages (pixi lock)" >&2; exit 1; }
for u in $URLS; do
    f="$CACHE/pkgs/$(basename "$u")"
    if [ ! -s "$f" ]; then
        curl -sSfL -o "$f.part" "$u" && mv "$f.part" "$f"
    fi
    if [ ! -e "$f.unpacked" ]; then
        d=$(mktemp -d "$CACHE/x.XXXXXX")
        (cd "$d" && unzip -oq "$f" && for t in pkg-*.tar.zst; do zstd -dqc "$t" | tar -x -C "$CACHE/root"; done)
        rm -rf "$d"
        touch "$f.unpacked"
    fi
done

# 2. compile
mkdir -p build/macos
"$MOJO" build --target-triple "$TRIPLE" --target-cpu apple-m1 --emit object \
    -D "TURBOMOJO_MOJO=$("$MOJO" --version)" -I src src/main.mojo -o build/macos/tmide.o \
    > build/macos/compile.log 2>&1 || { grep -A3 "error:" build/macos/compile.log >&2; echo "macos-link: compiling failed" >&2; exit 1; }
[ -s build/macos/tmide.o ] || { echo "macos-link: no object" >&2; exit 1; }

# 3. libSystem as a stub with the functions macOS has
STUB="$CACHE/stub"
mkdir -p "$STUB"
{
    echo "--- !tapi-tbd"
    echo "tbd-version: 4"
    echo "targets: [ arm64-macos ]"
    echo "install-name: '/usr/lib/libSystem.B.dylib'"
    echo "current-version: 1351"
    echo "exports:"
    echo "  - targets: [ arm64-macos ]"
    echo "    symbols: [ $(grep -v '^#' scripts/macos/libSystem.symbols | grep . | paste -sd, - | sed 's/,/, /g') ]"
    echo "..."
} > "$STUB/libSystem.tbd"

# 4. link (lld signs arm64 executables ad hoc, as macOS requires)
ln -sf "$LLD" "$CACHE/ld64.lld"
"$CACHE/ld64.lld" --error-limit=0 -arch arm64 -platform_version macos 14.0 14.0 \
    -o build/macos/tmide build/macos/tmide.o "$CACHE/root/lib/libghostty-vt.a" \
    -L "$CACHE/root/lib" -lKGENCompilerRTShared -L "$STUB" -lSystem \
    -rpath @executable_path/../lib -rpath @executable_path 2> build/macos/link.log || {
    echo "macos-link: the link failed - functions not found:" >&2
    grep -oE "undefined symbol: \S+" build/macos/link.log | sort -u >&2
    exit 1
}
echo "macos-link: build/macos/tmide ($(file -b build/macos/tmide | cut -d, -f1))"
