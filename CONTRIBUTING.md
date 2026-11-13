# Contributing to TurboMojo

Thank you for wanting to help. TurboMojo is written in Mojo (1.2), and everything you need
comes through [pixi](https://pixi.sh): the Mojo toolchain and the one C library it links.

## Reporting a problem

**Help > Report a problem...** in the IDE writes a ready-to-file issue text - the
versions, what your terminal can do, the last crash, your settings without secrets - and
copies it. Read it, then paste it into a [new issue](https://github.com/sabelg/turbomojo/issues/new/choose).
Nothing is sent by the IDE itself. If the IDE does not start, `tmide --caps` and
`tmide --version` give the same facts.

## Building and running

```bash
pixi run build                          # -> build/tmide
pixi run ./build/tmide examples/hello.mojo
```

Linux (x86-64 or aarch64, glibc 2.34+) only for now; see the README for macOS.
`pixi run macos-link` compiles and links the macOS build (it downloads the osx-arm64
packages once); a call of a Linux-only C function makes its link fail - give macOS its
own way in `src/platform.mojo`.

## The gate

Every change ends with the gate passing:

```bash
pixi run check                          # scripts/check.sh: ends with CHECK OK
```

It builds the IDE, compiles and runs every `tests/test_*.mojo`, starts the real program
in tmux (scripts/smoke.sh), checks the performance budgets (scripts/perf.sh) and runs a
short soak test of editing while the memory is watched. Most of the time goes into
compiling the tests, half as many at a time as there are cores (`TM_JOBS=4` sets it):
about 16 minutes on a 20-core machine, about an hour on GitHub's 4-core runners. While you
work, build and run one test file:

```bash
pixi run mojo build -I src tests/test_window.mojo -o build/tests/test_window -Xlinker .pixi/envs/default/lib/libghostty-vt.a
build/tests/test_window
```

The tests never touch your own settings: the gate gives them an empty config, state and
cache folder, and a test that writes files does so under `$TMPDIR`. Please keep it that
way. `SKIP_SMOKE=1`, `SKIP_PERF=1` and `SKIP_SOAK=1` leave those parts out while you
work; `pixi run canary` runs the gate against the nightly Mojo.

## Finding your way

- **docs/SOURCE.md** lists every source file with what it does (generated from the
  files' first docstrings by `scripts/gen_docs.py`).
- **docs/JOURNAL.md** records how every part was built and verified, task by task, with
  what was left out and what went wrong. It is long and unusually detailed: search it for
  a feature's name before changing it.
- **docs/BACKLOG.md** is the list of tasks, done and to do; **docs/ROADMAP.md** the
  reasons behind them.
- **docs/USER_GUIDE.md**, **docs/KEYMAP.md** and **help/** are what users read.

## Conventions

- A change comes with tests in the same commit. A good test fails without the change:
  try it (replace the new line with `pass` and see the test fail).
- User-visible changes go into README.md or the user guide, and into help/whats-new.md;
  `src/helpbook.mojo` embeds whats-new.md and `tests/test_help.mojo` checks that the
  two agree. Run `python3 scripts/gen_docs.py` (CHANGELOG.md, docs/SOURCE.md) and, when
  keys change, `build/tmide --keys > docs/KEYMAP.md`; `tests/test_docs_files.mojo`
  checks both are current.
- Write for people who read English as a second language: short sentences, plain words.
- Nothing is sent over the network unless the user asked for it (the docs download, an
  agent they started).

## Licence

By contributing you agree that your contribution is released under the MIT licence
(LICENSE).
