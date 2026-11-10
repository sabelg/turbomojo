#!/usr/bin/env bash
# Download the Mojo documentation that TurboMojo's Help shows:
#   - the Mojo manual, language reference, cheat sheets and examples
#   - the standard library sources (their docstrings are the API reference)
#   - the MAX documentation
#   - Modular's courses (GPU puzzles, the LLM book, workshops, Advent of Mojo)
# Everything comes from Modular's public repositories on github.com/modular, as shallow
# git checkouts of only the folders that are needed - except Advent of Mojo, which is
# published only as a web site (advent.mojolang.org) and is downloaded page by page.
# Nothing about you or your project is sent. Run it again to update.
#
#   scripts/fetch-docs.sh [DEST]      DEST defaults to $XDG_DATA_HOME/turbomojo/docs
#                                     (~/.local/share/turbomojo/docs)
#   MOJO_DOCS_REF=main scripts/fetch-docs.sh    take the newest docs instead of the ones
#                                     that match the installed Mojo
set -u
DEST="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/turbomojo/docs}"
BASE="https://github.com/modular"
command -v git >/dev/null 2>&1 || { echo "error: git is needed to download the documentation"; exit 2; }
mkdir -p "$DEST" || { echo "error: cannot create $DEST"; exit 2; }
cd "$DEST" || exit 2
echo "Downloading into $DEST"

# the docs that match the installed Mojo, if Modular tagged that version
REF="${MOJO_DOCS_REF:-}"
if [ -z "$REF" ]; then
  VER=$(mojo --version 2>/dev/null | sed -n 's/^[Mm]ojo \([0-9][0-9.]*\).*/\1/p' | head -1)
  if [ -n "$VER" ] && git ls-remote --exit-code --tags "$BASE/modular.git" "refs/tags/mojo/v$VER" >/dev/null 2>&1; then
    REF="mojo/v$VER"
  else
    REF="main"
  fi
fi
echo "Mojo documentation version: $REF"

FAILED=0
# fetch NAME REF FOLDER...   (no folders: the whole repository)
fetch() {
  local name="$1" ref="$2"; shift 2
  echo "== $name ($ref)"
  rm -rf "$name.new"
  if [ "$#" -gt 0 ]; then
    git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$ref" "$BASE/$name.git" "$name.new" 2>&1 | tail -2 \
      && git -C "$name.new" sparse-checkout set --no-cone "$@" 2>&1 | tail -2
  else
    git clone --quiet --depth 1 --branch "$ref" "$BASE/$name.git" "$name.new" 2>&1 | tail -2
  fi
  if [ -d "$name.new/.git" ]; then
    git -C "$name.new" rev-parse HEAD > "$name.new/.fetched-commit" 2>/dev/null
    rm -rf "$name.new/.git" "$name" && mv "$name.new" "$name" && echo "   ok: $(du -sh "$name" 2>/dev/null | cut -f1)"
  else
    rm -rf "$name.new"; echo "   FAILED (kept what was there before, if anything)"; FAILED=$((FAILED + 1))
  fi
}
default_branch() {
  git ls-remote --symref "$BASE/$1.git" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\(.*\)\tHEAD$|\1|p' | head -1
}

fetch modular "$REF" '/Mojo/docs/site/**' '/Mojo/stdlib/std/**' '/Mojo/examples/**' '/max/docs/site/**' '/LICENSE' '/Licenses/**'
for course in mojo-gpu-puzzles max-llm-book workshops; do
  B=$(default_branch "$course")
  if [ -n "$B" ]; then fetch "$course" "$B"; else echo "== $course: not reachable"; FAILED=$((FAILED + 1)); fi
done
# the developer relations workshops (Mojo 101): the lessons only, not the slide decks
B=$(default_branch devrel-extras)
if [ -n "$B" ]; then fetch devrel-extras "$B" '/workshops/**' '/README.md' '/LICENSE'; else echo "== devrel-extras: not reachable"; FAILED=$((FAILED + 1)); fi

# Advent of Mojo: a book that exists only as a web site (made with mdBook). Its contents
# page lists the chapters; each is saved as it is, with the puzzle inputs it links to.
SITE="${ADVENT_OF_MOJO_URL:-https://advent.mojolang.org}"
get() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 60 "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -q -T 60 -O "$2" "$1"
  else return 127; fi
}
echo "== advent-of-mojo ($SITE)"
rm -rf advent-of-mojo.new && mkdir -p advent-of-mojo.new/downloads
if get "$SITE/toc.html" advent-of-mojo.new/toc.html && [ -s advent-of-mojo.new/toc.html ]; then
  PAGES=$(grep -o 'href="[A-Za-z0-9_./-]*\.html"' advent-of-mojo.new/toc.html | sed 's/^href="//; s/"$//' | sort -u)
  N=0
  for page in $PAGES; do
    case "$page" in */*|toc.html|print.html) continue ;; esac
    get "$SITE/$page" "advent-of-mojo.new/$page" && N=$((N + 1))
  done
  for file in $(cat advent-of-mojo.new/*.html | grep -o 'href="\(\./\)\{0,1\}downloads/[A-Za-z0-9_.-]*"' | sed 's/^href="//; s/"$//; s|^\./||' | sort -u); do
    get "$SITE/$file" "advent-of-mojo.new/$file" || true
  done
  if [ "$N" -gt 0 ]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > advent-of-mojo.new/.fetched-commit
    rm -rf advent-of-mojo && mv advent-of-mojo.new advent-of-mojo && echo "   ok: $N pages, $(du -sh advent-of-mojo 2>/dev/null | cut -f1)"
  else
    rm -rf advent-of-mojo.new; echo "   FAILED (no pages could be downloaded)"; FAILED=$((FAILED + 1))
  fi
else
  rm -rf advent-of-mojo.new; echo "   FAILED (the site was not reachable, or neither curl nor wget is there)"; FAILED=$((FAILED + 1))
fi

# the standard library reference: one JSON file made by `mojo doc` from the sources
if [ -d modular/Mojo/stdlib/std ] && command -v mojo >/dev/null 2>&1; then
  echo "== standard library reference (mojo doc)"
  if mojo doc modular/Mojo/stdlib/std -o std.docs.json.new 2>std.docs.log && [ -s std.docs.json.new ]; then
    mv std.docs.json.new std.docs.json; echo "   ok: $(du -sh std.docs.json | cut -f1)"
  else
    rm -f std.docs.json.new; echo "   not made (see $DEST/std.docs.log); the sources can still be read"
  fi
fi

{ echo "fetched $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "ref $REF"; for d in */; do [ -f "$d.fetched-commit" ] && echo "${d%/} $(cat "$d.fetched-commit")"; done; } > SOURCES.txt
echo
if [ "$FAILED" -gt 0 ]; then echo "Done, but $FAILED part(s) could not be downloaded."; exit 1; fi
echo "Done. In TurboMojo: Help > Mojo documentation."
