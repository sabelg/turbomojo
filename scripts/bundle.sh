#!/usr/bin/env bash
# A copy-to-the-server bundle (P11-11): tmide and the libraries it loads from the pixi
# environment (the Mojo runtime, libstdc++, libgcc_s) in one tar file, which runs after
# unpacking on another Linux machine of the same architecture with a new enough glibc -
# no pixi, no Mojo, nothing installed.
#
#   pixi run bundle                         (builds first; writes build/turbomojo-<version>-linux-<arch>.tar.gz)
#   scripts/bundle.sh [--tmide FILE] [--out DIR]
#
# The binary's library path (RUNPATH, the environment's absolute lib folder) becomes
# $ORIGIN/../lib; the libraries' own already start with $ORIGIN. The system's libraries
# (libc, libm, libdl, the loader) are not copied: README.txt in the bundle names the glibc
# it needs (the newest GLIBC_ symbol version any file asks for).
set -euo pipefail
cd "$(dirname "$0")/.."

TMIDE=build/tmide
OUT=build
while [ $# -gt 0 ]; do
    case "$1" in
        --tmide) TMIDE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "usage: scripts/bundle.sh [--tmide FILE] [--out DIR]" >&2; exit 2 ;;
    esac
done
[ -x "$TMIDE" ] || { echo "bundle: no $TMIDE - build it first (pixi run build)" >&2; exit 1; }

VERSION=$(sed -n 's/^comptime TURBOMOJO_VERSION = "\(.*\)".*/\1/p' src/version.mojo)
ARCH=$(uname -m)
NAME="turbomojo-$VERSION-linux-$ARCH"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/turbomojo-bundle.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$NAME/bin" "$WORK/$NAME/lib"
cp "$TMIDE" "$WORK/$NAME/bin/tmide"

# the libraries: what the loader finds for tmide outside the system's folders
ldd "$TMIDE" | awk '/=> \// {print $3}' | while read -r lib; do
    case "$lib" in
        /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*) ;;            # the system's own
        *) cp -L "$lib" "$WORK/$NAME/lib/$(basename "$lib")" ;;
    esac
done
if ldd "$TMIDE" | grep -q "not found"; then
    echo "bundle: tmide needs a library that is not found here:" >&2
    ldd "$TMIDE" | grep "not found" >&2
    exit 1
fi

# RUNPATH: the absolute folder becomes $ORIGIN/../lib (written over the old text, which is
# longer, and padded with NULs - the dynamic section keeps pointing at the same place)
OLD=$(readelf -d "$TMIDE" | sed -n 's/.*Library runpath: \[\(.*\)\]/\1/p')
python3 - "$WORK/$NAME/bin/tmide" "$OLD" <<'EOF'
import sys
path, old = sys.argv[1], sys.argv[2].encode()
new = b"$ORIGIN/../lib"
data = bytearray(open(path, "rb").read())
if not old:
    sys.exit("bundle: tmide has no RUNPATH to change")
if len(new) > len(old):
    sys.exit("bundle: the RUNPATH %r is shorter than %r" % (old, new))
at = data.find(old + b"\0")
if at < 0 or data.find(old + b"\0", at + 1) >= 0:
    sys.exit("bundle: the RUNPATH text is not found once in tmide")
data[at:at + len(old)] = new + b"\0" * (len(old) - len(new))
open(path, "wb").write(bytes(data))
EOF

# the glibc it needs: the newest version any of its files asks for
GLIBC=$(for f in "$WORK/$NAME/bin/tmide" "$WORK/$NAME"/lib/*; do objdump -T "$f" 2>/dev/null; done \
    | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/GLIBC_//' | sort -V | tail -1)
cat > "$WORK/$NAME/README.txt" <<EOF
TurboMojo $VERSION for Linux $ARCH - a terminal IDE for Mojo.

Unpack anywhere and run bin/tmide (or put bin/ on your PATH). Nothing else is needed
to start it: the libraries it uses are in lib/. It needs glibc $GLIBC or newer
(\`ldd --version\` says which you have).

To build and run Mojo programs, the machine needs Mojo itself (pixi, or the Modular
conda channel); TurboMojo finds it on the PATH or as tools.compiler in
~/.config/turbomojo/config.toml. tmide --caps shows what your terminal can do.
EOF

TAR="$OUT/$NAME.tar.gz"
tar -C "$WORK" -czf "$TAR" "$NAME"
echo "bundle: $TAR ($(du -h "$TAR" | cut -f1), glibc $GLIBC or newer)"
