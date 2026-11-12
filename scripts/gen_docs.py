#!/usr/bin/env python3
"""Make the documents that are made from the project's own records, so they cannot drift:

- CHANGELOG.md from docs/BACKLOG.md (the finished tasks of each phase, under the version
  the roadmap gives that phase) and docs/JOURNAL.md (the day each task was done);
- docs/SOURCE.md from the first line of each src/*.mojo module's docstring.

docs/KEYMAP.md is made by the program itself: build/tmide --keys.

Usage: gen_docs.py            write them
       gen_docs.py --check    exit 1 if one is not what it would be written as
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()


def version():
    return re.search(r'TURBOMOJO_VERSION = "([^"]+)"', read("src/version.mojo")).group(1)


def task_days():
    """task id -> the day of its first journal entry."""
    days = {}
    for m in re.finditer(r"^## (\d{4}-\d{2}-\d{2}) · ([^\n]*)$", read("docs/JOURNAL.md"), re.M):
        for t in re.findall(r"\bP\d+-\d+[a-z]?\b", m.group(2)):
            days.setdefault(t, m.group(1))
    return days


def changelog():
    days = task_days()
    phases = []
    cur = None
    for line in read("docs/BACKLOG.md").splitlines():
        m = re.match(r"^## Phase (\d+): (.+?) \((?:v)?([\d.]+)\)", line)
        if m:
            cur = {"n": int(m.group(1)), "name": m.group(2), "version": m.group(3), "done": [], "open": 0}
            phases.append(cur)
            continue
        m = re.match(r"^- \[( |x)\] (P\d+-\d+[a-z]?) (.*)$", line)
        if m and cur is not None:
            if m.group(1) == "x":
                cur["done"].append((m.group(2), m.group(3)))
            else:
                cur["open"] += 1
    out = ["# Changelog", "",
           "What each version brought, made from the roadmap's finished tasks (docs/BACKLOG.md) and the",
           "day each was done (docs/JOURNAL.md) by `scripts/gen_docs.py`. The current version is " + version() + ";",
           "docs/JOURNAL.md has, for every task, what changed, how it was checked and what is not done.", ""]
    for ph in reversed(phases):
        if not ph["done"]:
            continue
        dates = sorted(days[t] for t, _ in ph["done"] if t in days)
        state = (" (in progress: %d task%s to go)" % (ph["open"], "" if ph["open"] == 1 else "s")) if ph["open"] else ""
        when = (" - " + dates[-1]) if dates and not ph["open"] else ""
        out.append("## %s: %s%s%s" % (ph["version"], ph["name"], state, when))
        out.append("")
        for t, text in ph["done"]:
            out.append("- %s (%s)" % (text, t))
        out.append("")
    out += ["## 1.0: the Turbo C++ tribute", "",
            "Overlapping windows, the menu bar and dialogs of Turbo C++ 3.0, the editor with undo,",
            "syntax colours, mouse, build and run - before the roadmap.", ""]
    return "\n".join(out)


def source_layout():
    rows = []
    for p in sorted(glob.glob(os.path.join(ROOT, "src", "*.mojo"))):
        name = os.path.basename(p)
        text = open(p, encoding="utf-8").read()
        m = re.match(r'\s*"""(.*?)"""', text, re.S)
        para = " ".join(m.group(1).strip().split("\n\n")[0].split()) if m else ""
        first = re.split(r"(?<=\.)\s", para)[0] if para else ""
        if first.endswith(":"):
            first = first[:-1] + "."
        rows.append("| `src/%s` | %s |" % (name, first.replace("|", "\\|") or "-"))
    head = ["# Source layout", "",
            "Every module of TurboMojo, with the first line of its own description (made by",
            "`scripts/gen_docs.py`). All Mojo; the only library linked in is libghostty-vt, the",
            "terminal emulator of the integrated terminal. `app_*.mojo` files extend the `App`",
            "struct of `appstate.mojo`, one area each.", "",
            "| File | What it is |", "|---|---|"]
    return "\n".join(head + rows) + "\n"


def main():
    files = {"CHANGELOG.md": changelog(), "docs/SOURCE.md": source_layout()}
    check = "--check" in sys.argv
    stale = []
    for name, text in files.items():
        path = os.path.join(ROOT, name)
        old = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if old != text:
            if check:
                stale.append(name)
            else:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text)
                print("wrote", name)
    if stale:
        print("out of date (run scripts/gen_docs.py):", ", ".join(stale))
        sys.exit(1)


main()
